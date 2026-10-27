import Foundation
import GRDB
import ConnectionKit

/// Folders pinned per connection (shown under the path bar, in the history popover and in ⌘K).
/// They live on the connection row, so deleting a connection removes its pins.
public final class PinnedFolderRepository: Sendable {
    public static let maxPins = 50

    private let db: DockyardDatabase
    public init(database: DockyardDatabase) { db = database }

    public func pins(for connectionId: UUID) async throws -> [PinnedFolder] {
        try await db.writer.read { try Connection.fetchOne($0, key: connectionId.uuidString)?.pinnedFolders ?? [] }
    }

    public func isPinned(_ path: String, on connectionId: UUID) async throws -> Bool {
        let normalized = Self.normalize(path)
        return try await pins(for: connectionId).contains { $0.path == normalized }
    }

    /// Adds a pin at the end. Pinning an already pinned folder only updates its label (when one is given).
    /// Returns false when the connection is gone or the cap is reached.
    @discardableResult
    public func pin(_ path: String, label: String? = nil, on connectionId: UUID) async throws -> Bool {
        let normalized = Self.normalize(path)
        return try await mutate(connectionId) { pins in
            if let index = pins.firstIndex(where: { $0.path == normalized }) {
                if let label { pins[index].label = label.isEmpty ? nil : label }
                return true
            }
            guard pins.count < Self.maxPins else { return false }
            pins.append(PinnedFolder(path: normalized, label: label?.isEmpty == true ? nil : label))
            return true
        }
    }

    @discardableResult
    public func unpin(_ path: String, on connectionId: UUID) async throws -> Bool {
        let normalized = Self.normalize(path)
        return try await mutate(connectionId) { pins in
            guard let index = pins.firstIndex(where: { $0.path == normalized }) else { return false }
            pins.remove(at: index)
            return true
        }
    }

    public func setLabel(_ label: String?, for path: String, on connectionId: UUID) async throws {
        let normalized = Self.normalize(path)
        _ = try await mutate(connectionId) { pins in
            guard let index = pins.firstIndex(where: { $0.path == normalized }) else { return false }
            pins[index].label = (label?.isEmpty ?? true) ? nil : label
            return true
        }
    }

    /// Moves the pin at `source` to position `destination` (indices as in the current list).
    public func move(from source: Int, to destination: Int, on connectionId: UUID) async throws {
        _ = try await mutate(connectionId) { pins in
            guard pins.indices.contains(source), destination >= 0, destination < pins.count else { return false }
            pins.insert(pins.remove(at: source), at: destination)
            return true
        }
    }

    public func observe(_ connectionId: UUID) -> AsyncStream<[PinnedFolder]> {
        let observation = ValueObservation.tracking { db in
            try Connection.fetchOne(db, key: connectionId.uuidString)?.pinnedFolders ?? []
        }
        let writer = db.writer
        let (stream, continuation) = AsyncStream<[PinnedFolder]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            do { for try await value in observation.values(in: writer) { continuation.yield(value) } } catch {}
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Trailing slashes are dropped so `/a/b/` and `/a/b` are the same pin. The root stays `/`.
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func mutate(_ connectionId: UUID, _ change: @escaping @Sendable (inout [PinnedFolder]) -> Bool) async throws -> Bool {
        try await db.writer.write { db in
            guard var connection = try Connection.fetchOne(db, key: connectionId.uuidString) else { return false }
            var pins = connection.pinnedFolders
            guard change(&pins) else { return false }
            connection.pinnedFolders = pins
            try connection.update(db)
            return true
        }
    }
}
