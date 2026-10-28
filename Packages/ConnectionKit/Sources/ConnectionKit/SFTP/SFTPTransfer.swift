import Foundation

/// Pipelined transfers: up to `window` requests of `chunkSize` bytes are in flight at once, so
/// throughput is bounded by bandwidth rather than by one round trip per chunk.
enum SFTPTransfer {
    static let chunkSize = 32 * 1024
    static let window = 64

    /// Outstanding reads. Used from one `run` call at a time.
    private final class ReadPipeline: @unchecked Sendable {
        var nextOffset: UInt64
        let end: UInt64?
        var inflight: [UInt32: (offset: UInt64, length: Int)] = [:]
        var retries: [(offset: UInt64, length: Int)] = []
        var reachedEOF = false

        init(start: UInt64, end: UInt64?) {
            nextOffset = start
            self.end = end
        }

        func step(_ client: SFTPClient, handle: Data) throws -> (chunks: [(offset: UInt64, data: Data)], finished: Bool) {
            while inflight.count < SFTPTransfer.window {
                let request: (offset: UInt64, length: Int)
                if let retry = retries.popLast() {
                    request = retry
                } else if reachedEOF || end.map({ nextOffset >= $0 }) == true {
                    break
                } else {
                    request = (nextOffset, SFTPTransfer.chunkSize)
                    nextOffset += UInt64(SFTPTransfer.chunkSize)
                }
                let id = try client.submit(SFTPType.read) { $0.string(handle); $0.u64(request.offset); $0.u32(UInt32(request.length)) }
                inflight[id] = request
            }
            if inflight.isEmpty { return ([], true) }

            var chunks: [(UInt64, Data)] = []
            for (id, response) in try client.collect(Array(inflight.keys), waitForOne: true) {
                let request = inflight.removeValue(forKey: id)!
                switch response {
                case .data(let data) where !data.isEmpty:
                    chunks.append((request.offset, data))
                    if data.count < request.length {
                        retries.append((request.offset + UInt64(data.count), request.length - data.count))
                    }
                case .data:
                    reachedEOF = true
                case .status(let code, let message):
                    guard code == SFTPStatusError.Code.eof.rawValue else { throw SFTPStatusError(code: code, message: message) }
                    reachedEOF = true
                default:
                    throw RemoteError.protocolError("Unexpected SFTP response to read")
                }
            }
            return (chunks, false)
        }
    }

    private final class WritePipeline: @unchecked Sendable {
        var inflight: [UInt32: Int] = [:]

        func step(_ client: SFTPClient, handle: Data, batch: [(offset: UInt64, data: Data)]) throws -> Int {
            for chunk in batch {
                let id = try client.submit(SFTPType.write) { $0.string(handle); $0.u64(chunk.offset); $0.string(chunk.data) }
                inflight[id] = chunk.data.count
            }
            if inflight.isEmpty { return 0 }
            var acknowledged = 0
            for (id, response) in try client.collect(Array(inflight.keys), waitForOne: true) {
                acknowledged += inflight.removeValue(forKey: id) ?? 0
                guard case .status(let code, let message) = response else { throw RemoteError.protocolError("Unexpected SFTP response to write") }
                guard code == 0 else { throw SFTPStatusError(code: code, message: message) }
            }
            return acknowledged
        }
    }

    /// Returns the number of bytes now in the local file.
    static func download(
        _ client: SFTPClient, remote: String, to local: URL, resume: Bool, progress: Progress, onStart: (UInt64) -> Void
    ) async throws -> UInt64 {
        let handle = try await client.run { try $0.open(remote, .read) }
        do {
            let size = try await client.run { try $0.fstat(handle) }.size
            var offset: UInt64 = 0
            if resume, let existing = LocalFile.size(of: local), existing > 0 {
                if let size, existing == size {
                    progress.totalUnitCount = Int64(size)
                    progress.completedUnitCount = Int64(size)
                    try await client.run { try $0.closeHandle(handle) }
                    return size
                }
                if size == nil || existing < size! { offset = existing }
            }
            if offset == 0 { _ = FileManager.default.createFile(atPath: local.path, contents: nil) }
            let file = try FileHandle(forWritingTo: local)
            defer { try? file.close() }
            try file.truncate(atOffset: offset)

            progress.totalUnitCount = Int64(size ?? 0)
            progress.completedUnitCount = Int64(offset)
            onStart(offset)

            let pipeline = ReadPipeline(start: offset, end: size)
            var received = offset
            do {
                while true {
                    try Task.checkCancellation()
                    if progress.isCancelled { throw CancellationError() }
                    let step = try await client.run { try pipeline.step($0, handle: handle) }
                    for chunk in step.chunks {
                        try file.seek(toOffset: chunk.offset)
                        try file.write(contentsOf: chunk.data)
                        received += UInt64(chunk.data.count)
                    }
                    progress.completedUnitCount = Int64(received)
                    if step.finished { break }
                }
            } catch {
                let pending = Array(pipeline.inflight.keys)
                try? await client.run { $0.abandon(pending) }
                throw error
            }
            try await client.run { try $0.closeHandle(handle) }
            return received
        } catch {
            try? await client.run { try $0.closeHandle(handle) }
            throw error
        }
    }

    /// Returns the number of bytes now in the remote file. Sets the remote mtime to the local one.
    static func upload(
        _ client: SFTPClient, local: URL, remote: String, total: UInt64, resume: Bool, progress: Progress, onStart: (UInt64) -> Void
    ) async throws -> UInt64 {
        var offset: UInt64 = 0
        if resume, let existing = try? await client.run({ try $0.stat(remote, followLinks: true) }).size, existing > 0, existing <= total {
            offset = existing
        }
        progress.totalUnitCount = Int64(total)
        progress.completedUnitCount = Int64(offset)
        onStart(offset)

        let flags: SFTPOpenFlags = offset > 0 ? [.write] : [.write, .create, .truncate]
        let handle = try await client.run { try $0.open(remote, flags) }
        let pipeline = WritePipeline()
        do {
            let file = try FileHandle(forReadingFrom: local)
            defer { try? file.close() }
            try file.seek(toOffset: offset)

            var nextOffset = offset
            var acknowledged = offset
            while true {
                try Task.checkCancellation()
                if progress.isCancelled { throw CancellationError() }
                var batch: [(offset: UInt64, data: Data)] = []
                while pipeline.inflight.count + batch.count < window,
                      let chunk = try file.read(upToCount: chunkSize), !chunk.isEmpty {
                    batch.append((nextOffset, chunk))
                    nextOffset += UInt64(chunk.count)
                }
                if batch.isEmpty && pipeline.inflight.isEmpty { break }
                let sent = batch
                acknowledged += UInt64(try await client.run { try pipeline.step($0, handle: handle, batch: sent) })
                progress.completedUnitCount = Int64(acknowledged)
            }
            try await client.run { try $0.closeHandle(handle) }
            return acknowledged
        } catch {
            let pending = Array(pipeline.inflight.keys)
            try? await client.run {
                $0.abandon(pending)
                try $0.closeHandle(handle)
            }
            throw error
        }
    }
}
