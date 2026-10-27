import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

func makeTempDir(_ label: String = "dockyard") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeConn(
    _ name: String = "Site", host: String = "example.com", user: String = "root",
    proto: ConnectionProtocol = .sftp, port: Int? = nil, source: ConnectionSource = .manual,
    created: Date = Date(timeIntervalSince1970: 1_700_000_000), tags: [String] = [],
    client: UUID? = nil, favorite: Bool = false, lastConnected: Date? = nil
) -> Connection {
    Connection(name: name, clientFolderId: client, protocol: proto, host: host, port: port, username: user,
               favorite: favorite, tags: tags, source: source, lastConnectedAt: lastConnected, createdAt: created)
}

/// Collects the first `count` values of a stream with a timeout.
func firstValues<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeout: TimeInterval = 5) async -> [T] {
    await withTaskGroup(of: [T].self) { group in
        group.addTask {
            var out: [T] = []
            for await v in stream { out.append(v); if out.count >= count { break } }
            return out
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            return []
        }
        let r = await group.next() ?? []
        group.cancelAll()
        return r
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Returns the first value satisfying predicate, or nil on timeout.
func firstValue<T: Sendable>(_ stream: AsyncStream<T>, timeout: TimeInterval = 5, where predicate: @escaping @Sendable (T) -> Bool) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await v in stream where predicate(v) { return v }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            return nil
        }
        let r = await group.next() ?? nil
        group.cancelAll()
        return r
    }
}
