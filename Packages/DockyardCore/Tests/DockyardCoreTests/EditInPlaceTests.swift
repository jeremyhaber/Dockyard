import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct EditInPlaceTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let connA = UUID(), connB = UUID()

    struct Env {
        let root: URL
        let clock: ManualClock
        let coordinator: EditInPlaceCoordinator
        let server: FakeFileSystem
    }

    func env() throws -> Env {
        let root = try makeTempDir("edit")
        let clock = ManualClock()
        let server = FakeFileSystem()
        server.put("/www/index.php", "<?php echo 1;", modified: t0)
        return Env(root: root, clock: clock,
                   coordinator: EditInPlaceCoordinator(watcher: PollingFileWatcher(clock: clock, interval: 1), rootDirectory: root),
                   server: server)
    }

    func save(_ url: URL, _ text: String, mtime: Date) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    /// Two polls: the first sees the change, the second confirms it settled.
    func settle(_ clock: ManualClock, polls: Int = 2) async {
        for _ in 0..<polls {
            await clock.waitForSleepers(1)
            clock.advance(by: 1)
        }
    }

    @Test func openDownloadsToPerConnectionTempFolder() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        #expect(try String(contentsOf: s.localURL, encoding: .utf8) == "<?php echo 1;")
        #expect(s.localURL.lastPathComponent == "index.php")
        #expect(s.localURL.path.contains(connA.uuidString))
        // The local copy carries the server's mtime.
        let m = try FileManager.default.attributesOfItem(atPath: s.localURL.path)[.modificationDate] as! Date
        #expect(abs(m.timeIntervalSince(t0)) < 1)
        // Same file on another connection gets its own folder.
        let other = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connB, connectionName: "Staging")
        #expect(other.localURL != s.localURL && other.localURL.path.contains(connB.uuidString))
        await e.coordinator.stopAll(force: true)
    }

    @Test func reopeningReturnsRunningSession() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let a = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        let b = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        #expect(a == b)
        #expect(e.server.calls.filter { $0.hasPrefix("download") }.count == 1)
        #expect(await e.coordinator.sessions.count == 1)
        await e.coordinator.stopAll(force: true)
    }

    @Test func queuedTransfersShowInTheQueue() async throws {
        let root = try makeTempDir("edit"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualClock()
        let server = FakeFileSystem()
        server.put("/www/index.php", "<?php echo 1;", modified: t0)
        let queue = TransferQueue(conflictPolicy: .ask, tempDirectory: root.appendingPathComponent("relay"),
                                  progressInterval: 0.005, publishInterval: 0.005)
        let coordinator = EditInPlaceCoordinator(watcher: PollingFileWatcher(clock: clock, interval: 1), rootDirectory: root, queue: queue)
        let events = await coordinator.events()
        let s = try await coordinator.open(fs: server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        #expect(try String(contentsOf: s.localURL, encoding: .utf8) == "<?php echo 1;")
        let watcher = Task { await firstValue(events) { if case .uploaded = $0.kind { true } else { false } } }
        try save(s.localURL, "<?php echo 2;", mtime: t0.addingTimeInterval(30))
        await settle(clock)
        _ = try #require(await watcher.value)
        #expect(server.text("/www/index.php") == "<?php echo 2;")
        let done = await queue.page(offset: 0, limit: 10, filter: TransferJobFilter(scope: .topLevel, states: [.completed]))
        #expect(done.map(\.route).sorted() == ["Prod → This Mac", "This Mac → Prod"])
        await coordinator.stopAll(force: true)
    }

    @Test func queuedUploadFailureLeavesTheListOnceAnUploadSucceeds() async throws {
        let root = try makeTempDir("edit"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualClock()
        let server = FakeFileSystem()
        server.put("/www/index.php", "<?php echo 1;", modified: t0)
        let queue = TransferQueue(conflictPolicy: .ask, tempDirectory: root.appendingPathComponent("relay"),
                                  progressInterval: 0.005, publishInterval: 0.005)
        await queue.pause()  // edits never wait for the queue
        let coordinator = EditInPlaceCoordinator(watcher: PollingFileWatcher(clock: clock, interval: 1), rootDirectory: root, queue: queue)
        let events = await coordinator.events()
        let s = try await coordinator.open(fs: server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        server.failNext("/www/index.php", times: 1, error: RemoteError.permissionDenied("/www/index.php"))
        let failure = Task { await firstValue(events) { if case .uploadFailed = $0.kind { true } else { false } } }
        try save(s.localURL, "<?php echo 2;", mtime: t0.addingTimeInterval(30))
        await settle(clock)
        let ev = try #require(await failure.value)
        #expect(ev.logLine?.message.contains("Permission denied") == true)
        #expect(await queue.snapshot().failedCount == 1)
        await coordinator.uploadNow(s.id)
        #expect(server.text("/www/index.php") == "<?php echo 2;")
        #expect(await queue.snapshot().failedCount == 0)
        await coordinator.stopAll(force: true)
    }

    @Test func saveTriggersUploadWithToastAndLog() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let events = await e.coordinator.events()
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        let watcher = Task { await firstValue(events) { if case .uploaded = $0.kind { true } else { false } } }
        try save(s.localURL, "<?php echo 2;", mtime: t0.addingTimeInterval(30))
        await settle(e.clock)
        let uploaded = try #require(await watcher.value)
        #expect(e.server.text("/www/index.php") == "<?php echo 2;")
        #expect(uploaded.kind == .uploaded(bytes: 13))
        #expect(uploaded.toast == "Uploaded index.php to Prod")
        #expect(uploaded.logLine?.kind == .status && uploaded.logLine?.message.contains("/www/index.php") == true)
        #expect(await e.coordinator.hasUnsyncedChanges(s.id) == false)
        await e.coordinator.stopAll()
    }

    @Test func eventOrderIsOpenedChangedUploaded() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let events = await e.coordinator.events()
        let collector = Task { () -> [EditEvent.Kind] in
            var kinds: [EditEvent.Kind] = []
            for await ev in events { kinds.append(ev.kind); if kinds.count == 3 { break } }
            return kinds
        }
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        try save(s.localURL, "new", mtime: t0.addingTimeInterval(5))
        await settle(e.clock)
        #expect(await collector.value == [.opened, .changeDetected, .uploaded(bytes: 3)])
        await e.coordinator.stopAll()
    }

    @Test func burstOfSavesBeforeSettlingUploadsOnce() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        await e.clock.waitForSleepers(1)
        try save(s.localURL, "v2", mtime: t0.addingTimeInterval(10))
        e.clock.advance(by: 1)           // poll 1 sees v2
        await e.clock.waitForSleepers(1)
        try save(s.localURL, "v3-final", mtime: t0.addingTimeInterval(20))  // saved again before it settled
        e.clock.advance(by: 1)           // poll 2: differs from poll 1, not settled
        await e.clock.waitForSleepers(1)
        e.clock.advance(by: 1)           // poll 3: settled
        #expect(await waitUntil { e.server.text("/www/index.php") == "v3-final" })
        #expect(e.server.calls.filter { $0.hasPrefix("upload") }.count == 1)
        await e.coordinator.stopAll()
    }

    @Test func secondSaveUploadsAgain() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        try save(s.localURL, "one", mtime: t0.addingTimeInterval(10))
        await settle(e.clock)
        #expect(await waitUntil { e.server.text("/www/index.php") == "one" })
        try save(s.localURL, "two", mtime: t0.addingTimeInterval(20))
        await settle(e.clock)
        #expect(await waitUntil { e.server.text("/www/index.php") == "two" })
        await e.coordinator.stopAll()
    }

    @Test func originalVersionIsKeptOnceBeforeTheFirstUpload() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let seen = LockedBox<[(String, String?)]>([])
        let s = try await e.coordinator.open(
            fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod",
            beforeOverwrite: { [server = e.server] path, _ in seen.withLock { $0.append((path, server.text(path))) } })
        try save(s.localURL, "one", mtime: t0.addingTimeInterval(10))
        await settle(e.clock)
        #expect(await waitUntil { e.server.text("/www/index.php") == "one" })
        try save(s.localURL, "two", mtime: t0.addingTimeInterval(20))
        await settle(e.clock)
        #expect(await waitUntil { e.server.text("/www/index.php") == "two" })
        let calls = seen.withLock { $0 }
        #expect(calls.count == 1 && calls[0].0 == "/www/index.php" && calls[0].1 == "<?php echo 1;")
        await e.coordinator.stopAll()
    }

    @Test func failedUploadKeepsLocalFileAndCanBeRetried() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let events = await e.coordinator.events()
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        e.server.failNext("/www/index.php", times: 1, error: RemoteError.permissionDenied("/www/index.php"))
        let failure = Task { await firstValue(events) { if case .uploadFailed = $0.kind { true } else { false } } }
        try save(s.localURL, "precious edit", mtime: t0.addingTimeInterval(10))
        await settle(e.clock)
        let ev = try #require(await failure.value)
        #expect(ev.toast == "Could not upload index.php")
        #expect(ev.logLine?.kind == .error)
        #expect(ev.logLine?.message.contains("Permission denied") == true)
        #expect(e.server.text("/www/index.php") == "<?php echo 1;")
        #expect(await e.coordinator.hasUnsyncedChanges(s.id))
        // Stopping without force must not delete unsaved work.
        await e.coordinator.uploadNow(s.id)
        #expect(e.server.text("/www/index.php") == "precious edit")
        #expect(await e.coordinator.hasUnsyncedChanges(s.id) == false)
        await e.coordinator.stopAll()
        #expect(!FileManager.default.fileExists(atPath: s.localURL.path))
    }

    @Test func stopKeepsUnsyncedFileUnlessForced() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        e.server.failNext("/www/index.php", times: 5)
        try save(s.localURL, "unsaved", mtime: t0.addingTimeInterval(10))
        await settle(e.clock)
        #expect(await waitUntil { await e.coordinator.hasUnsyncedChanges(s.id) })
        #expect(await waitUntil { e.server.calls.contains { $0.hasPrefix("upload") } })
        await e.coordinator.stop(s.id)
        #expect(FileManager.default.fileExists(atPath: s.localURL.path))
        #expect(await e.coordinator.sessions.isEmpty)
    }

    @Test func remoteChangeProducesWarningButStillUploads() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let events = await e.coordinator.events()
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        e.server.put("/www/index.php", "changed by someone else", modified: t0.addingTimeInterval(500))
        let warning = Task { await firstValue(events) { $0.kind == .remoteChangedWarning } }
        try save(s.localURL, "my edit", mtime: t0.addingTimeInterval(600))
        await settle(e.clock)
        let w = try #require(await warning.value)
        #expect(w.logLine?.kind == .warning)
        #expect(w.toast?.contains("changed on the server") == true)
        #expect(await waitUntil { e.server.text("/www/index.php") == "my edit" })
        await e.coordinator.stopAll()
    }

    @Test func stopRemovesTempFilesAndStopsWatching() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let s = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "Prod")
        await e.coordinator.stop(s.id)
        #expect(!FileManager.default.fileExists(atPath: s.localURL.deletingLastPathComponent().path))
        await waitUntil { e.clock.sleeperCount == 0 }
        #expect(e.clock.sleeperCount == 0)
    }

    @Test func stopAllForConnectionLeavesOthers() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let a = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connA, connectionName: "A")
        let b = try await e.coordinator.open(fs: e.server, remotePath: "/www/index.php", connectionId: connB, connectionName: "B")
        await e.coordinator.stopAll(connectionId: connA)
        #expect(await e.coordinator.sessions.map(\.id) == [b.id])
        #expect(!FileManager.default.fileExists(atPath: a.localURL.path))
        await e.coordinator.stopAll()
    }

    @Test func downloadFailureThrowsAndLeavesNothingBehind() async throws {
        let e = try env()
        defer { try? FileManager.default.removeItem(at: e.root) }
        await #expect(throws: RemoteError.self) {
            _ = try await e.coordinator.open(fs: e.server, remotePath: "/www/missing.php", connectionId: connA, connectionName: "Prod")
        }
        #expect(await e.coordinator.sessions.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: e.root.appendingPathComponent(connA.uuidString).path)) ?? []
        #expect(leftovers.isEmpty)
    }
}

@Suite struct PollingFileWatcherTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func unchangedFileNeverFires() async throws {
        let dir = try makeTempDir("watch"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)
        let clock = ManualClock()
        let stream = PollingFileWatcher(clock: clock, interval: 1).changes(of: url)
        let fired = LockedBox(0)
        let task = Task { for await _ in stream { fired.withLock { $0 += 1 } } }
        for _ in 0..<5 { await clock.waitForSleepers(1); clock.advance(by: 1) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(fired.withLock { $0 } == 0)
        task.cancel()
    }

    @Test func detectsEditsAndAtomicReplacement() async throws {
        let dir = try makeTempDir("watch"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
        let clock = ManualClock()
        let stream = PollingFileWatcher(clock: clock, interval: 1).changes(of: url)
        let fired = LockedBox(0)
        let task = Task { for await _ in stream { fired.withLock { $0 += 1 } } }
        await clock.waitForSleepers(1)
        // Editor writes a temp file and renames it over the original (the file briefly does not exist).
        try FileManager.default.removeItem(at: url)
        clock.advance(by: 1)
        await clock.waitForSleepers(1)
        try Data("replaced".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(50)], ofItemAtPath: url.path)
        for _ in 0..<2 { clock.advance(by: 1); await clock.waitForSleepers(1) }
        #expect(await waitUntil { fired.withLock { $0 } == 1 })
        task.cancel()
    }

    @Test func sizeChangeWithSameMtimeIsDetected() async throws {
        let dir = try makeTempDir("watch"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
        let clock = ManualClock()
        let stream = PollingFileWatcher(clock: clock, interval: 1).changes(of: url)
        let fired = LockedBox(0)
        let task = Task { for await _ in stream { fired.withLock { $0 += 1 } } }
        await clock.waitForSleepers(1)
        try Data("xxxxxx".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
        for _ in 0..<2 { clock.advance(by: 1); await clock.waitForSleepers(1) }
        #expect(await waitUntil { fired.withLock { $0 } == 1 })
        task.cancel()
    }

    @Test func cancellingTheConsumerStopsPolling() async throws {
        let dir = try makeTempDir("watch"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)
        let clock = ManualClock()
        let stream = PollingFileWatcher(clock: clock, interval: 1).changes(of: url)
        let task = Task { for await _ in stream {} }
        await clock.waitForSleepers(1)
        task.cancel()
        #expect(await waitUntil { clock.sleeperCount == 0 })
    }
}
