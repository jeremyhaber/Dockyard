import ConnectionKit
import DockyardCore
import Foundation

/// A queued copy whose destination did not exist; once it completes it becomes a journal entry.
struct PendingChange {
    var scope: UUID
    var sessionID: UUID
    var side: PaneSide
    var path: String
    var fs: any RemoteFileSystem
}

// MARK: - Recording

extension AppModel {
    func scope(for session: ConnectionSession, side: PaneSide) -> UUID { session.scope(side) }

    /// Journals a change. Moves and renames also show the toast with the Undo button.
    func recordChange(_ entry: ChangeEntry, session: ConnectionSession, side: PaneSide, toast: Bool = true) {
        let journal = self.journal
        let sessionID = session.id
        Task {
            guard let saved = try? await journal.record(entry) else { return }
            if toast, saved.kind == .move || saved.kind == .rename {
                showToast(saved.summary, symbol: "arrow.uturn.backward.circle", undo: UndoTarget(entry: saved, sessionID: sessionID, side: side))
            }
            await refreshUndoState()
        }
    }

    /// Server-to-server, upload and download copies all go through here so the queue and the journal see them.
    func transfer(
        _ items: [RemoteItem], from source: ConnectionSession, _ sourceSide: PaneSide,
        to destination: ConnectionSession, _ destinationSide: PaneSide, directory: String, move: Bool
    ) {
        guard !items.isEmpty else { return }
        let from = source.endpoint(sourceSide), to = destination.endpoint(destinationSide)
        let queue = self.queue
        let scope = destination.scope(destinationSide)
        let destinationID = destination.id
        Task {
            let existing = Set(((try? await to.fs.list(directory)) ?? []).map(\.name))
            if destinationSide == .server {
                guard await destination.authorize(.upload, paths: items.map { RemotePath.join(directory, $0.name) }) else { return }
                let clashes = items.filter { existing.contains($0.name) }.map { RemotePath.join(directory, $0.name) }
                if !clashes.isEmpty, !(await destination.authorize(.overwrite, paths: clashes)) { return }
            }
            let ids = await queue.enqueue(items: items, from: from, to: to, into: directory, move: move)
            for (id, item) in zip(ids, items) where !item.isDirectory && !existing.contains(item.name) {
                pendingJournal[id] = PendingChange(
                    scope: scope, sessionID: destinationID, side: destinationSide,
                    path: RemotePath.join(directory, item.name), fs: to.fs)
            }
        }
    }

    /// Turns finished copies that created a new file into journal entries.
    func journalCompletedTransfers(_ snapshot: TransferSnapshot) {
        guard !pendingJournal.isEmpty else { return }
        for job in snapshot.jobs where job.state.isFinished {
            guard let pending = pendingJournal.removeValue(forKey: job.id) else { continue }
            guard job.state == .completed else { continue }
            let journal = self.journal
            Task {
                guard let item = try? await pending.fs.stat(pending.path) else { return }
                let entry = ChangeEntry(
                    scope: pending.scope, kind: .upload, toPath: pending.path, createdSize: item.size, createdModified: item.modified)
                _ = try? await journal.record(entry)
                await refreshUndoState()
            }
        }
    }
}

// MARK: - Undo and redo

extension AppModel {
    private var focusedScope: (session: ConnectionSession, side: PaneSide)? {
        guard let session = activeSession else { return nil }
        let side: PaneSide = layoutMode == .sideBySide ? .server : focusedSide
        return (session, side)
    }

    /// Updates the Edit menu titles for the pane that has focus.
    func refreshUndoState() async {
        guard let target = focusedScope else {
            undoLabel = nil
            redoLabel = nil
            return
        }
        let scope = target.session.scope(target.side)
        let next = try? await journal.nextUndo(scope: scope)
        let again = try? await journal.nextRedo(scope: scope)
        undoLabel = next.map { "Undo \($0.title)" }
        redoLabel = again.map { "Redo \($0.title)" }
    }

    /// ⌘Z and ⇧⌘Z.
    func undoLast(redo: Bool = false) {
        guard let target = focusedScope else { return }
        let scope = target.session.scope(target.side)
        Task {
            var found: ChangeEntry?
            if redo { found = try? await journal.nextRedo(scope: scope) } else { found = try? await journal.nextUndo(scope: scope) }
            guard let entry = found else { return }
            await apply(entry, redo: redo, session: target.session, side: target.side)
        }
    }

    func undo(_ target: UndoTarget) {
        guard let session = sessions.first(where: { $0.id == target.sessionID }) else { return }
        Task { await apply(target.entry, redo: false, session: session, side: target.side) }
    }

    /// Checks the state, reverses the entry and updates the journal. A mismatch is explained; a taken path offers the conflict choices.
    func apply(
        _ entry: ChangeEntry, redo: Bool, session: ConnectionSession, side: PaneSide, resolution: UndoResolution? = nil
    ) async {
        guard let pane = session.pane(side), let id = entry.id else { return }
        guard await session.authorize(.move, paths: [entry.toPath], side: side) else { return }
        let undoer = ChangeUndoer(fs: pane.fs)
        let verb = redo ? "Redo" : "Undo"
        do {
            if redo { try await undoer.redo(entry, resolution: resolution) } else { try await undoer.undo(entry, resolution: resolution) }
            try? await journal.setUndone(id, !redo)
            session.log.append(.status, "\(verb): \(entry.title)")
            showToast("\(verb) done: \(entry.title)", symbol: "arrow.uturn.backward.circle")
            pane.invalidate()
            pane.reload()
        } catch let blocked as UndoBlockedError {
            if blocked.block.isConflict, resolution == nil {
                let choice = Dialogs.choose(
                    title: "Cannot \(verb.lowercased()) \(entry.title) as it was",
                    message: blocked.block.message + " Replace what is there, or keep both?",
                    buttons: ["Replace", "Keep Both", "Cancel"])
                switch choice {
                case 0: await apply(entry, redo: redo, session: session, side: side, resolution: .overwrite)
                case 1: await apply(entry, redo: redo, session: session, side: side, resolution: .keepBoth)
                default: break
                }
            } else {
                session.operationError = "Cannot \(verb.lowercased()) \(entry.title): \(blocked.block.message) Nothing was changed."
            }
        } catch {
            session.log.append(.error, "\(verb) failed: \(error.userMessage)")
            session.operationError = "\(verb) failed: \(error.userMessage)"
        }
        await refreshUndoState()
    }
}
