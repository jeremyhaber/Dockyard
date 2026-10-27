import Foundation
import ConnectionKit

/// Compress or extract on a server that has no shell (FTP, cloud): download, run the tool on this Mac,
/// upload the result. The legs are ordinary queue jobs, so they show up in the transfer bar, honour
/// connection limits and use the conflict policy. Show `summary` in the confirmation dialog.
public struct ArchiveRelayPlan: Sendable {
    public enum Operation: Sendable {
        case compress(directory: String, items: [RemoteItem], archiveName: String, format: ArchiveFormat)
        case extract(archive: RemoteItem, destination: String)
    }

    public enum Step: Sendable, Equatable {
        case download(String)
        case runLocally(String)
        case upload(String)

        public var description: String {
            switch self {
            case .download(let s), .runLocally(let s), .upload(let s): s
            }
        }
    }

    public let endpoint: TransferEndpoint
    public let operation: Operation
    public let steps: [Step]

    public init(endpoint: TransferEndpoint, operation: Operation) {
        self.endpoint = endpoint
        self.operation = operation
        switch operation {
        case .compress(let directory, let items, let archiveName, let format):
            let what = items.count == 1 ? items[0].name : "\(items.count) items"
            steps = [
                .download("Download \(what) from \(endpoint.label)"),
                .runLocally("Create \(archiveName) (.\(format.fileExtension)) on this Mac"),
                .upload("Upload \(archiveName) to \(directory)"),
            ]
        case .extract(let archive, let destination):
            steps = [
                .download("Download \(archive.name) from \(endpoint.label)"),
                .runLocally("Extract it on this Mac"),
                .upload("Upload the contents to \(destination)"),
            ]
        }
    }

    /// One sentence for the confirmation: states that the data is relayed through this Mac.
    public var summary: String {
        "\(endpoint.label) has no shell, so this will be relayed through this Mac: " + steps.map(\.description).joined(separator: ", then ") + "."
    }

    public struct Failure: Error, CustomStringConvertible {
        public var step: Int
        public var description: String
    }

    /// Runs the plan. Throws `Failure` when a transfer leg fails and `CancellationError` when cancelled.
    @discardableResult
    public func run(on queue: TransferQueue, service: ArchiveService, tempRoot: URL = FileManager.default.temporaryDirectory) async throws -> ArchiveResult {
        let work = tempRoot.appendingPathComponent("dockyard-archive-\(UUID().uuidString)")
        let incoming = work.appendingPathComponent("in"), outgoing = work.appendingPathComponent("out")
        for dir in [incoming, outgoing] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: work) }
        let mac = TransferEndpoint.thisMac()

        switch operation {
        case .compress(let directory, let items, let archiveName, let format):
            try await transfer(queue, 0, items.map { item in
                TransferRequest(source: endpoint, sourcePath: item.path, destination: mac,
                                destinationPath: incoming.appendingPathComponent(item.name).path,
                                isDirectory: item.isDirectory, size: item.size, modified: item.modified)
            })
            let archive = outgoing.appendingPathComponent(archiveName).path
            _ = try await service.compressLocally(CompressRequest(
                directory: incoming.path, names: items.map(\.name), destination: archive, format: format))
            try await transfer(queue, 2, [TransferRequest(
                source: mac, sourcePath: archive, destination: endpoint,
                destinationPath: RemotePath.join(directory, archiveName))])
            return ArchiveResult(placed: [RemotePath.join(directory, archiveName)], skipped: 0)

        case .extract(let archive, let destination):
            let local = incoming.appendingPathComponent(archive.name)
            try await transfer(queue, 0, [TransferRequest(
                source: endpoint, sourcePath: archive.path, destination: mac, destinationPath: local.path,
                size: archive.size, modified: archive.modified)])
            let fresh = ArchiveService(conflictPolicy: .overwrite)
            _ = try await fresh.extractLocally(ExtractRequest(archive: local.path, destination: outgoing.path))
            let top = try FileManager.default.contentsOfDirectory(atPath: outgoing.path).sorted()
            var requests: [TransferRequest] = []
            for name in top {
                let path = outgoing.appendingPathComponent(name).path
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                requests.append(TransferRequest(
                    source: mac, sourcePath: path, destination: endpoint,
                    destinationPath: RemotePath.join(destination, name), isDirectory: isDir.boolValue, createParents: true))
            }
            try await transfer(queue, 2, requests)
            return ArchiveResult(placed: requests.map(\.destinationPath), skipped: 0)
        }
    }

    private func transfer(_ queue: TransferQueue, _ step: Int, _ requests: [TransferRequest]) async throws {
        let ids = await queue.enqueue(requests)
        for id in ids {
            let state = await withTaskCancellationHandler {
                await queue.waitUntilFinished(id)
            } onCancel: {
                Task { await queue.cancel(id) }
            }
            try Task.checkCancellation()
            guard state == .completed || state == .skipped else {
                let info = await queue.job(id)
                throw Failure(step: step, description: info?.error ?? "The transfer \(state.map { "ended as \($0.rawValue)" } ?? "was lost")")
            }
        }
    }
}
