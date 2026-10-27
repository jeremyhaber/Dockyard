import ConnectionKit
import DockyardCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// The Finder side of "Mount in Finder" (HANDOFF 9): one domain per connection, files fetched on demand,
/// edits uploaded through the same `RemoteFileSystem` backends the app uses. PROD and read-only mounts refuse writes.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let context: MountContext

    required init(domain: NSFileProviderDomain) {
        context = MountContext(identifier: domain.identifier.rawValue, displayName: domain.displayName)
        super.init()
    }

    func invalidate() {
        let context = self.context
        Task { await context.shutdown() }
    }

    // MARK: Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        nonisolated(unsafe) let completion = completionHandler
        let context = self.context
        Task {
            do {
                if identifier == .rootContainer {
                    completion(await context.rootItem(), nil)
                    return
                }
                guard let path = await context.path(for: identifier),
                      let remote = try await context.perform({ try await $0.stat(path) }) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                completion(await context.item(remote), nil)
            } catch {
                completion(nil, ProviderErrors.map(error))
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return WorkingSetEnumerator(context: context) }
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        return FolderEnumerator(context: context, identifier: containerItemIdentifier)
    }

    // MARK: Downloads

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        nonisolated(unsafe) let completion = completionHandler
        let context = self.context
        Task {
            do {
                guard let path = await context.path(for: itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                let directory = await context.temporaryDirectory()
                let local = directory.appendingPathComponent(UUID().uuidString)
                context.log(.status, "Download \(path)")
                let remote = try await context.perform { fs -> RemoteItem? in
                    try await fs.download(path, to: local, progress: Progress(totalUnitCount: 0))
                    return try await fs.stat(path)
                }
                guard let remote else { throw NSFileProviderError(.noSuchItem) }
                context.log(.status, "Downloaded \(path)")
                progress.completedUnitCount = 1
                completion(local, await context.item(remote), nil)
            } catch {
                context.log(.error, "Download of \(itemIdentifier.rawValue) failed: \(error)")
                completion(nil, nil, ProviderErrors.map(error))
            }
        }
        return progress
    }

    // MARK: Writes

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        nonisolated(unsafe) let completion = completionHandler
        let context = self.context
        let name = itemTemplate.filename
        let parentID = itemTemplate.parentItemIdentifier
        let isFolder = itemTemplate.contentType == .folder
        Task {
            do {
                guard !(await context.isReadOnly()) else { throw MountContext.MountError.readOnly }
                guard let parent = await context.path(for: parentID) else { throw NSFileProviderError(.noSuchItem) }
                let target = RemotePath.join(parent, name)
                context.log(.status, isFolder ? "Create folder \(target)" : "Upload \(target)")
                let remote = try await context.perform { fs -> RemoteItem? in
                    if isFolder {
                        try await fs.mkdir(target)
                    } else if let url {
                        try await fs.upload(url, to: target, progress: Progress(totalUnitCount: 0))
                    }
                    return try await fs.stat(target)
                }
                guard let remote else { throw NSFileProviderError(.cannotSynchronize) }
                completion(await context.item(remote), [], false, nil)
            } catch {
                context.log(.error, "Create \(name) failed: \(error)")
                completion(nil, [], false, ProviderErrors.map(error))
            }
        }
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
        contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        nonisolated(unsafe) let completion = completionHandler
        let context = self.context
        let identifier = item.itemIdentifier
        let newName = item.filename
        let newParent = item.parentItemIdentifier
        let moved = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
        let hasContents = changedFields.contains(.contents)
        let base = ProviderItem.version(from: version.contentVersion)
        Task {
            do {
                guard !(await context.isReadOnly()) else { throw MountContext.MountError.readOnly }
                guard var path = await context.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
                if moved, let parent = await context.path(for: newParent) {
                    let target = RemotePath.join(parent, newName)
                    if target != path {
                        context.log(.status, "Rename \(path) to \(target)")
                        let from = path
                        try await context.perform { try await $0.rename(from, target) }
                        path = target
                    }
                }
                if hasContents, let newContents {
                    try await Self.uploadEdit(context: context, path: path, local: newContents, base: base)
                }
                let final = path
                guard let remote = try await context.perform({ try await $0.stat(final) }) else { throw NSFileProviderError(.noSuchItem) }
                completion(await context.item(remote), [], false, nil)
            } catch {
                context.log(.error, "Change of \(newName) failed: \(error)")
                completion(nil, [], false, ProviderErrors.map(error))
            }
        }
        return Progress()
    }

    /// Uploads an edit. When the server copy changed since Finder downloaded it, both copies are kept
    /// (`name (conflict YYYY-MM-DD).ext`) and a warning goes to the Log; nothing is overwritten silently.
    private static func uploadEdit(context: MountContext, path: String, local: URL, base: (size: UInt64?, modified: Date?)) async throws {
        let parent = RemotePath.parent(of: path)
        let name = RemotePath.lastComponent(of: path)
        let current = try await context.perform { try await $0.stat(path) }
        let siblings = Set(try await context.perform { try await $0.list(parent) }.map(\.name))
        let decision = MountConflict.decide(
            fileName: name, downloaded: RemoteVersion(modified: base.modified, size: base.size),
            currentRemote: current.map { RemoteVersion($0) }, locallyEdited: true, siblings: siblings, now: Date())
        switch decision {
        case .upload:
            context.log(.status, "Upload \(path)")
            try await context.perform { try await $0.upload(local, to: path, progress: Progress(totalUnitCount: 0)) }
        case .keepBoth(let conflictName):
            let copy = RemotePath.join(parent, conflictName)
            context.log(.warning, MountConflict.warning(for: name, conflictName: conflictName))
            try await context.perform { try await $0.upload(local, to: copy, progress: Progress(totalUnitCount: 0)) }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        nonisolated(unsafe) let completion = completionHandler
        let context = self.context
        Task {
            do {
                guard !(await context.isReadOnly()) else { throw MountContext.MountError.readOnly }
                guard let path = await context.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
                context.log(.status, "Delete \(path)")
                try await context.perform { fs in
                    guard let remote = try await fs.stat(path) else { return }
                    try await fs.delete(path, recursive: remote.isDirectory)
                }
                completion(nil)
            } catch {
                context.log(.error, "Delete \(identifier.rawValue) failed: \(error)")
                completion(ProviderErrors.map(error))
            }
        }
        return Progress()
    }
}
