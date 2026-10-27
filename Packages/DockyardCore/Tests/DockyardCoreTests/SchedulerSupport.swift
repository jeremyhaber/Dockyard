@testable import DockyardCore
import Foundation
import ConnectionKit

/// Counts simultaneous operations across several servers.
final class Meter: Sendable {
    private let state = LockedBox((current: 0, peak: 0))
    func enter() { state.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) } }
    func leave() { state.withLock { $0.current -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
}

/// A fake server: one shared file store, a counted set of sessions and optional connection refusals.
final class FakeServer: Sendable {
    struct State {
        var live = 0
        var maxLive = 0
        var connects = 0
        var refusals = 0
        var connectTimes: [Date] = []
    }

    let files = FakeFileSystem()
    let state = LockedBox(State())
    let meter = Meter()
    let global: Meter?
    /// Connections beyond this many are refused, like a server with a per-user limit.
    let capacity: Int?
    let refuseFirst = LockedBox(0)
    let clock: any DockyardClock

    init(capacity: Int? = nil, refuseFirst: Int = 0, global: Meter? = nil, clock: any DockyardClock = SystemClock()) {
        self.capacity = capacity
        self.global = global
        self.clock = clock
        self.refuseFirst.withLock { $0 = refuseFirst }
    }

    var maxLive: Int { state.withLock { $0.maxLive } }
    var connects: Int { state.withLock { $0.connects } }
    var refusals: Int { state.withLock { $0.refusals } }
    var connectTimes: [Date] { state.withLock { $0.connectTimes } }

    func site(_ id: UUID = UUID(), label: String = "Site", max: Int = 3, delayMs: Int = 0) -> TransferSite {
        TransferSite(id: id, label: label, maxConnections: max, connectDelayMs: delayMs) { [self] in FakeSession(server: self) }
    }

    func endpoint(_ site: TransferSite) -> TransferEndpoint { site.endpoint(fs: files) }

    fileprivate func open() throws {
        let now = clock.now()
        try state.withLock { s in
            let forced = refuseFirst.withLock { n -> Bool in if n > 0 { n -= 1; return true }; return false }
            if forced || (capacity.map { s.live >= $0 } ?? false) {
                s.refusals += 1
                throw RemoteError.connectionRefused("421 Too many connections")
            }
            s.live += 1
            s.maxLive = max(s.maxLive, s.live)
            s.connects += 1
            s.connectTimes.append(now)
        }
    }

    fileprivate func close() { state.withLock { $0.live -= 1 } }
}

final class FakeSession: RemoteFileSystem {
    let server: FakeServer
    private let connected = LockedBox(false)
    init(server: FakeServer) { self.server = server }

    var logStream: AsyncStream<LogLine> { server.files.logStream }
    var supportsShell: Bool { false }

    func connect() async throws {
        try server.open()
        connected.withLock { $0 = true }
    }

    func disconnect() async {
        if connected.withLock({ let was = $0; $0 = false; return was }) { server.close() }
    }

    func homeDirectory() async throws -> String { "/" }
    func list(_ path: String) async throws -> [RemoteItem] { try await server.files.list(path) }
    func mkdir(_ path: String) async throws { try await server.files.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws { try await server.files.rename(from, to) }
    func delete(_ path: String, recursive: Bool) async throws { try await server.files.delete(path, recursive: recursive) }
    func chmod(_ path: String, mode: UInt16) async throws {}

    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        server.meter.enter(); server.global?.enter()
        defer { server.meter.leave(); server.global?.leave() }
        try await server.files.download(remote, to: local, progress: progress, resume: resume)
    }

    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        server.meter.enter(); server.global?.enter()
        defer { server.meter.leave(); server.global?.leave() }
        try await server.files.upload(local, to: remote, progress: progress, resume: resume)
    }
}

/// A file system with generated content and no per-file cost, for the 100,000-file tests.
final class GeneratedFileSystem: RemoteFileSystem {
    let folders: Int
    let filesPerFolder: Int
    let transfers = LockedBox(0)
    let firstTransfer = LockedBox<Date?>(nil)
    let live = LockedBox(0)

    /// `folders == 0`: all files directly in `/big`.
    init(folders: Int, filesPerFolder: Int) { self.folders = folders; self.filesPerFolder = filesPerFolder }

    var logStream: AsyncStream<LogLine> { AsyncStream { $0.finish() } }
    var supportsShell: Bool { false }
    func connect() async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/" }
    func mkdir(_ path: String) async throws {}
    func rename(_ from: String, _ to: String) async throws {}
    func delete(_ path: String, recursive: Bool) async throws {}
    func chmod(_ path: String, mode: UInt16) async throws {}

    func list(_ path: String) async throws -> [RemoteItem] {
        if path == "/big" && folders > 0 {
            return (0..<folders).map { RemoteItem(name: "d\($0)", path: "/big/d\($0)", isDirectory: true) }
        }
        let parent = path == "/big" ? path : path
        return (0..<(folders == 0 ? filesPerFolder : filesPerFolder)).map {
            RemoteItem(name: "f\($0)", path: "\(parent)/f\($0)", isDirectory: false, size: 4, modified: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    func stat(_ path: String) async throws -> RemoteItem? { nil }

    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws { record(progress) }
    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws { record(progress) }

    private func record(_ progress: Progress) {
        firstTransfer.withLock { if $0 == nil { $0 = Date() } }
        transfers.withLock { $0 += 1 }
        progress.totalUnitCount = 4
        progress.completedUnitCount = 4
    }
}

/// Current resident memory in bytes, or nil where it cannot be read.
func residentMemory() -> UInt64? {
    #if os(Linux)
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }),
          let kb = line.split(separator: " ").compactMap({ UInt64($0) }).first else { return nil }
    return kb * 1024
    #else
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.resident_size : nil
    #endif
}
