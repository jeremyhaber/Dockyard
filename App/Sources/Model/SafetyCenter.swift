import ConnectionKit
import DockyardCore
import Foundation
import Observation

/// UI state for pinned folders, remote search and the Versions sheet.
@MainActor @Observable
final class SafetyCenter {
    /// The session whose Versions sheet is open.
    var versionsSessionID: UUID?
    private(set) var pins: [UUID: [PinnedFolder]] = [:]
    @ObservationIgnored private var searches: [UUID: SearchModel] = [:]

    var pinRepository: PinnedFolderRepository { PinnedFolderRepository(database: AppModel.shared.database) }

    func setPins(_ value: [PinnedFolder], for connectionID: UUID) {
        if pins[connectionID] != value { pins[connectionID] = value }
    }

    func isPinned(_ path: String, on connectionID: UUID) -> Bool {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return pins[connectionID]?.contains { $0.path == normalized } ?? false
    }

    func togglePin(_ path: String, on connectionID: UUID) {
        let repository = pinRepository
        let pinned = isPinned(path, on: connectionID)
        Task {
            if pinned {
                _ = try? await repository.unpin(path, on: connectionID)
            } else if (try? await repository.pin(path, on: connectionID)) == false {
                AppModel.shared.showToast("A site can have up to \(PinnedFolderRepository.maxPins) pinned folders", symbol: "exclamationmark.circle", isError: true)
            }
        }
    }

    func search(for session: ConnectionSession) -> SearchModel {
        if let existing = searches[session.id] { return existing }
        let created = SearchModel()
        searches[session.id] = created
        return created
    }

    func forget(_ session: ConnectionSession) {
        searches.removeValue(forKey: session.id)?.cancel()
    }
}

/// One remote search: query options, streamed hits, progress and the final summary.
@MainActor @Observable
final class SearchModel {
    var isOpen = false
    var byContent = false
    var caseSensitive = false
    var text = ""
    private(set) var focusToken = 0
    private(set) var hits: [SearchHit] = []
    private(set) var isRunning = false
    private(set) var progress: SearchProgress?
    private(set) var summary: SearchSummary?
    private(set) var searchedRoot = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    var hasResults: Bool { summary != nil || isRunning }

    func open() {
        isOpen = true
        focusToken += 1
    }

    func close() {
        cancel()
        isOpen = false
        hits = []
        summary = nil
        progress = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func run(root: String, on fs: any RemoteFileSystem) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        cancel()
        hits = []
        summary = nil
        progress = nil
        searchedRoot = root
        isRunning = true
        let spec = SearchQuery(mode: byContent ? .content : .name, text: query, root: root, caseSensitive: caseSensitive)
        task = Task { [weak self] in
            for await event in RemoteSearch.search(spec, on: fs) {
                guard let self else { return }
                switch event {
                case .hit(let hit): hits.append(hit)
                case .progress(let value): progress = value
                case .finished(let result):
                    summary = result
                    isRunning = false
                }
            }
            guard let self, spec.mode == .content, !Task.isCancelled else { return }
            let head = Array(hits.prefix(300))
            let detailed = await RemoteSearch.details(for: head, on: fs)
            if !Task.isCancelled, detailed.count == head.count { hits.replaceSubrange(0..<head.count, with: detailed) }
        }
    }

    /// Demo mode: a finished search without a server.
    func seedDemo(root: String, hits seeded: [SearchHit], summary seededSummary: SearchSummary) {
        isOpen = true
        text = "wp-config"
        searchedRoot = root
        hits = seeded
        summary = seededSummary
    }
}
