import Foundation
import ConnectionKit

/// What dropping items on a folder means.
public enum DropPlan: Sendable, Equatable {
    /// Rename within one file system.
    case move
    /// Queue a transfer (upload, download, relay, or a same-file-system copy).
    case copy
    case reject
}

public enum DropPlanner {
    /// `sameFileSystem`: source and destination pane use the same connection. `optionKey`: copy instead of move.
    public static func plan(
        items: [RemoteItem], destinationDirectory: String, sameFileSystem: Bool, optionKey: Bool
    ) -> DropPlan {
        guard !items.isEmpty else { return .reject }
        let dest = PathTools.normalize(destinationDirectory)
        if sameFileSystem {
            for item in items {
                let src = PathTools.normalize(item.path)
                if item.isDirectory, dest == src || dest.hasPrefix(src + "/") { return .reject }
                if RemotePath.parent(of: src) == dest { return .reject }
            }
            return optionKey ? .copy : .move
        }
        return .copy
    }
}
