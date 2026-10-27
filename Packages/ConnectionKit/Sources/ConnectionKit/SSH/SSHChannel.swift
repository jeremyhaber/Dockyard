#if canImport(CSSH)
import CSSH
#else
import CLibSSH2
#endif
import Foundation

struct ChannelChunk: Sendable {
    var stdout = Data()
    var stderr = Data()
    var isEOF = false
}

/// A libssh2 channel. Like the session it belongs to, it may only be used on the session queue.
final class SSHChannel: @unchecked Sendable {
    private let session: SSHSession
    private var handle: OpaquePointer?
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 8)

    init(session: SSHSession, handle: OpaquePointer) {
        self.session = session
        self.handle = handle
    }

    deinit { readBuffer.deallocate() }

    private func live() throws -> OpaquePointer {
        guard let handle else { throw RemoteError.notConnected }
        return handle
    }

    // MARK: Requests

    func exec(_ command: String) throws { try process("exec", command) }
    func startShell() throws { try process("shell", nil) }
    func startSubsystem(_ name: String) throws { try process("subsystem", name) }

    private func process(_ request: String, _ message: String?) throws {
        let handle = try live()
        try session.call("channel \(request)") {
            libssh2_channel_process_startup(
                handle, request, UInt32(request.utf8.count), message, UInt32(message?.utf8.count ?? 0)
            )
        }
    }

    func requestPTY(cols: Int, rows: Int, term: String = "xterm-256color") throws {
        let handle = try live()
        try session.call("request pty") {
            libssh2_channel_request_pty_ex(handle, term, UInt32(term.utf8.count), nil, 0, Int32(cols), Int32(rows), 0, 0)
        }
    }

    func resizePTY(cols: Int, rows: Int) throws {
        let handle = try live()
        try session.call("resize pty") { libssh2_channel_request_pty_size_ex(handle, Int32(cols), Int32(rows), 0, 0) }
    }

    // MARK: Data

    func write(_ data: Data) throws { try write([UInt8](data)) }

    func write(_ bytes: [UInt8]) throws {
        let handle = try live()
        var offset = 0
        var limit = session.deadline(session.options.operationTimeout)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                libssh2_channel_write_ex(handle, 0, $0.baseAddress! + offset, bytes.count - offset)
            }
            if written == Int(LIBSSH2_ERROR_EAGAIN) {
                try session.waitForSocket(until: limit, what: "channel write")
            } else if written < 0 {
                throw session.failure("channel write", Int32(written))
            } else {
                offset += written
                limit = session.deadline(session.options.operationTimeout)
            }
        }
    }

    /// Reads what is available now. Returns nil when nothing is pending (or on EOF, see `isEOF`).
    func readNow(stream: Int32 = 0) throws -> Data? {
        let handle = try live()
        let count = libssh2_channel_read_ex(handle, stream, readBuffer.baseAddress!.assumingMemoryBound(to: CChar.self), readBuffer.count)
        if count > 0 { return Data(bytes: readBuffer.baseAddress!, count: count) }
        if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) { return nil }
        throw session.failure("channel read", Int32(count))
    }

    var isEOF: Bool { handle.map { libssh2_channel_eof($0) == 1 } ?? true }

    /// Blocks up to `wait` seconds for output on either stream.
    func readSome(wait: TimeInterval) throws -> ChannelChunk {
        var chunk = ChannelChunk()
        let limit = session.deadline(wait)
        while true {
            while let data = try readNow(stream: 0) { chunk.stdout.append(data) }
            while let data = try readNow(stream: 1) { chunk.stderr.append(data) }
            chunk.isEOF = isEOF
            if !chunk.stdout.isEmpty || !chunk.stderr.isEmpty || chunk.isEOF { return chunk }
            guard DispatchTime.now().uptimeNanoseconds < limit else { return chunk }
            try session.waitForSocket(until: limit, what: "channel read")
        }
    }

    func sendEOF() throws {
        let handle = try live()
        try session.call("channel eof") { libssh2_channel_send_eof(handle) }
    }

    func closeAndExitStatus() throws -> Int32 {
        let handle = try live()
        defer { close() }
        _ = try? session.call("channel close", timeout: 10) { libssh2_channel_close(handle) }
        _ = try? session.call("channel close", timeout: 10) { libssh2_channel_wait_closed(handle) }
        return libssh2_channel_get_exit_status(handle)
    }

    func close() {
        guard handle != nil else { return }
        free()
        session.release(self)
    }

    /// Releases the libssh2 handle. Safe to call twice.
    func free() {
        guard let handle else { return }
        self.handle = nil
        let limit = session.deadline(2)
        while libssh2_channel_free(handle) == LIBSSH2_ERROR_EAGAIN {
            if (try? session.waitForSocket(until: limit, what: "channel free")) == nil { break }
        }
    }
}
