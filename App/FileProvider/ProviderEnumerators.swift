import ConnectionKit
import DockyardCore
import FileProvider
import Foundation

enum ProviderErrors {
    /// Maps backend errors to what Finder understands.
    static func map(_ error: Error) -> Error {
        if error is NSFileProviderError || error is CocoaError { return error }
        if let remote = error as? RemoteError {
            switch remote {
            case .notFound: return NSFileProviderError(.noSuchItem)
            case .authenticationFailed: return NSFileProviderError(.notAuthenticated)
            case .notConnected: return NSFileProviderError(.serverUnreachable)
            case .permissionDenied: return CocoaError(.fileWriteNoPermission)
            default: return NSFileProviderError(.cannotSynchronize)
            }
        }
        if case MountContext.MountError.readOnly = error { return CocoaError(.fileWriteNoPermission) }
        return NSFileProviderError(.cannotSynchronize)
    }
}

/// Lists one folder for Finder and registers it with the change poller.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let context: MountContext
    private let identifier: NSFileProviderItemIdentifier

    init(context: MountContext, identifier: NSFileProviderItemIdentifier) {
        self.context = context
        self.identifier = identifier
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observerBox = UncheckedSendable(observer)
        let context = self.context
        let identifier = self.identifier
        Task {
            let observer = observerBox.value
            do {
                guard let path = await context.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
                let list = try await context.perform { try await $0.list(path) }
                var items: [ProviderItem] = []
                for remote in list { items.append(await context.item(remote)) }
                await context.watch(path, snapshot: list)
                context.log(.status, "Listed \(path) (\(list.count) items)")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                context.log(.error, "Could not list \(identifier.rawValue): \(error)")
                observer.finishEnumeratingWithError(ProviderErrors.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }
}

/// Reports what the poller found since Finder last asked. Its sync anchor is the poller's change counter.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let context: MountContext

    init(context: MountContext) { self.context = context }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observerBox = UncheckedSendable(observer)
        let context = self.context
        let since = Int(String(decoding: anchor.rawValue, as: UTF8.self)) ?? 0
        Task {
            let observer = observerBox.value
            let result = await context.changes(since: since)
            var updated: [ProviderItem] = []
            var deleted: [NSFileProviderItemIdentifier] = []
            for polled in result.changes {
                for remote in polled.change.added + polled.change.modified { updated.append(await context.item(remote)) }
                for remote in polled.change.deleted { deleted.append(await context.identifier(forPath: remote.path)) }
            }
            if !updated.isEmpty {
                context.log(.status, "Server changed: \(updated.count) item(s) updated")
                observer.didUpdate(updated)
            }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(String(result.anchor).utf8)), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completionBox = UncheckedSendable(completionHandler)
        let context = self.context
        Task {
            let completion = completionBox.value
            let anchor = await context.currentAnchor()
            completion(NSFileProviderSyncAnchor(Data(String(anchor).utf8)))
        }
    }
}
