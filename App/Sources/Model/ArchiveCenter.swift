import ConnectionKit
import DockyardCore
import Foundation
import Observation

/// A compress or extract run shown in the transfer bar.
struct ArchiveJob: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var place: String
}

/// Compress and extract from the pane context menus (HANDOFF 10). SFTP runs the tools on the server over an
/// exec channel, local runs them on this Mac, FTP and cloud relay through this Mac after a confirmation.
@MainActor @Observable
final class ArchiveCenter {
    private(set) var running: [ArchiveJob] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    // MARK: Entry points

    func compress(_ items: [RemoteItem], in session: ConnectionSession, side: PaneSide, app: AppModel) {
        guard let pane = session.pane(side), !items.isEmpty else { return }
        let suggested = items.count == 1 ? items[0].name : RemotePath.lastComponent(of: pane.currentPath)
        var message = "Name of the archive, without an extension."
        if Self.relays(pane) {
            message += "\n\n\(session.endpoint(.server).label) has no shell, so this is relayed through this Mac: "
                + "the items are downloaded, compressed here and the archive is uploaded."
        }
        let formats = ArchiveFormat.creatable
        guard let answer = Dialogs.promptText(
            title: "Compress", message: message, initial: suggested,
            choiceLabel: "Format:", choices: formats.map { ".\($0.fileExtension)" }, confirm: "Compress"),
            !answer.text.isEmpty, formats.indices.contains(answer.choice) else { return }
        let format = formats[answer.choice]
        let archiveName = "\(answer.text).\(format.fileExtension)"
        let directory = pane.currentPath
        let request = CompressRequest(
            directory: directory, names: items.map(\.name), destination: RemotePath.join(directory, archiveName), format: format)
        run("Compressing \(archiveName)", session: session, side: side, app: app, paths: [request.destination], guarded: .compress) { service in
            if side == .local { return try await service.compressLocally(request) }
            if let remote = pane.fs as? (any RemoteFileSystem & RemoteCommandRunner) {
                return try await service.compress(request, on: remote)
            }
            let plan = ArchiveRelayPlan(
                endpoint: session.endpoint(.server), operation: .compress(directory: directory, items: items, archiveName: archiveName, format: format))
            return try await plan.run(on: app.queue, service: service)
        }
    }

    /// FTP and cloud panes have no shell, so archives are made and unpacked on this Mac.
    static func relays(_ pane: PaneModel) -> Bool {
        pane.side != .local && !(pane.fs is any RemoteCommandRunner)
    }

    /// For the one dialog that asks about an extraction relayed through this Mac.
    static func extractRelayNote(_ session: ConnectionSession) -> String {
        "\(session.endpoint(.server).label) has no shell, so this is relayed through this Mac: "
            + "the archive is downloaded, extracted here and its contents are uploaded."
    }

    /// `relayConfirmed` is true when the caller's dialog already said the work is relayed through this Mac.
    func extract(
        _ archive: RemoteItem, in session: ConnectionSession, side: PaneSide, to destination: String?, relayConfirmed: Bool = false, app: AppModel
    ) {
        guard let pane = session.pane(side), ArchiveFormat.detect(fileName: archive.name) != nil else { return }
        let target = destination ?? pane.currentPath
        let request = ExtractRequest(archive: archive.path, destination: target)
        run("Extracting \(archive.name)", session: session, side: side, app: app, paths: [target], guarded: .extract) { service in
            if side == .local { return try await service.extractLocally(request) }
            if let remote = pane.fs as? (any RemoteFileSystem & RemoteCommandRunner) {
                return try await service.extract(request, on: remote)
            }
            let plan = ArchiveRelayPlan(endpoint: session.endpoint(.server), operation: .extract(archive: archive, destination: target))
            guard relayConfirmed || Dialogs.confirm(title: "Extract through this Mac?", message: plan.summary, confirm: "Continue", destructive: false) else {
                throw CancellationError()
            }
            return try await plan.run(on: app.queue, service: service)
        }
    }

    // MARK: Running

    private func run(
        _ title: String, session: ConnectionSession, side: PaneSide, app: AppModel, paths: [String], guarded kind: OperationKind,
        _ body: @escaping (ArchiveService) async throws -> ArchiveResult
    ) {
        let job = ArchiveJob(title: title, place: side == .local ? "This Mac" : session.connection.name)
        let service = ArchiveService(conflictPolicy: .ask, resolver: { info in await app.prompts.askConflict(info) })
        let log = session.log
        let lines = log.attach(to: service.log.stream())
        tasks[job.id] = Task {
            guard await session.authorize(kind, paths: paths, side: side) else {
                lines.cancel()
                return
            }
            running.append(job)
            do {
                let result = try await body(service)
                app.showToast("\(title.replacingOccurrences(of: "ing ", with: "ed ")): \(result.placed.count) item\(result.placed.count == 1 ? "" : "s")", symbol: "archivebox")
            } catch is CancellationError {
                log.append(.status, "\(title) cancelled")
            } catch {
                log.append(.error, "\(title) failed: \(error.userMessage)")
                session.operationError = "\(title) failed: \(error.userMessage)"
            }
            lines.cancel()
            running.removeAll { $0.id == job.id }
            tasks.removeValue(forKey: job.id)
            session.pane(side)?.invalidate()
            session.pane(side)?.reload()
        }
    }
}
