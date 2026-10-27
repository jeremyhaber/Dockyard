import ConnectionKit
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// A remote file or folder as Finder sees it. Identifiers are remote paths (`p:/var/www/index.php`).
final class ProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let remote: RemoteItem
    private let id: NSFileProviderItemIdentifier
    private let parent: NSFileProviderItemIdentifier
    private let readOnly: Bool

    init(remote: RemoteItem, identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, readOnly: Bool) {
        self.remote = remote
        self.id = identifier
        self.parent = parent
        self.readOnly = readOnly
    }

    var itemIdentifier: NSFileProviderItemIdentifier { id }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parent }
    var filename: String { remote.name }

    var contentType: UTType {
        if remote.isDirectory { return .folder }
        let ext = (remote.name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if readOnly {
            return remote.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        }
        var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        if remote.isDirectory { caps.formUnion([.allowsContentEnumerating, .allowsAddingSubItems]) }
        return caps
    }

    var documentSize: NSNumber? { remote.isDirectory ? nil : remote.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { remote.modified }
    var creationDate: Date? { remote.modified }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Self.versionData(size: remote.size, modified: remote.modified),
            metadataVersion: Self.versionData(size: remote.size, modified: remote.modified))
    }

    /// `size-seconds`, compared later against the server's current listing to spot a remote change.
    static func versionData(size: UInt64?, modified: Date?) -> Data {
        Data("\(size ?? 0)-\(Int(modified?.timeIntervalSince1970 ?? 0))".utf8)
    }

    static func version(from data: Data) -> (size: UInt64?, modified: Date?) {
        let parts = String(decoding: data, as: UTF8.self).split(separator: "-")
        guard parts.count == 2, let size = UInt64(parts[0]), let seconds = TimeInterval(parts[1]) else { return (nil, nil) }
        return (size, seconds == 0 ? nil : Date(timeIntervalSince1970: seconds))
    }
}
