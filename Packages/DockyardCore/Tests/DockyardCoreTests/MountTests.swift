import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct MountTests {
    let utc = TimeZone(identifier: "UTC")!
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func displayNames() {
        #expect(MountNaming.displayName(connectionName: "Prod", clientName: "Client", readOnly: true) == "Client – Prod (read-only)")
        #expect(MountNaming.displayName(connectionName: "Prod", clientName: "Client", readOnly: false) == "Client – Prod")
        #expect(MountNaming.displayName(connectionName: "Prod", clientName: nil, readOnly: true) == "Prod (read-only)")
        // Same name as the client is not repeated.
        #expect(MountNaming.displayName(connectionName: "Acme", clientName: "acme", readOnly: false) == "Acme")
        #expect(MountNaming.displayName(connectionName: "  ", clientName: nil, readOnly: false) == "Connection")
    }

    @Test func displayNamesAreFinderSafe() {
        #expect(MountNaming.displayName(connectionName: "a/b: c\n d", clientName: nil, readOnly: false) == "a b c d")
        let long = String(repeating: "x", count: 200)
        let n = MountNaming.displayName(connectionName: long, clientName: nil, readOnly: true)
        #expect(n.count <= MountNaming.maxNameLength && n.hasSuffix(" (read-only)"))
    }

    @Test func uniqueNames() {
        #expect(MountNaming.uniqueDisplayName("Prod", among: []) == "Prod")
        #expect(MountNaming.uniqueDisplayName("Prod", among: ["Prod"]) == "Prod 2")
        #expect(MountNaming.uniqueDisplayName("Prod", among: ["Prod", "Prod 2"]) == "Prod 3")
        #expect(MountNaming.uniqueDisplayName("Prod (read-only)", among: ["Prod (read-only)"]) == "Prod 2 (read-only)")
    }

    @Test func domainIdentifiersRoundTrip() {
        let id = UUID()
        let d = MountNaming.domainIdentifier(for: id)
        #expect(MountNaming.connectionId(fromDomainIdentifier: d) == id)
        #expect(MountNaming.connectionId(fromDomainIdentifier: "other.\(id)") == nil)
        #expect(MountNaming.connectionId(fromDomainIdentifier: "app.dockyard.mount.nope") == nil)
        #expect(d == MountNaming.domainIdentifier(for: id))  // stable
    }

    @Test func prodDefaultsToReadOnlyAndNameSaysSo() {
        #expect(MountPolicy.defaultReadOnly(isProd: true))
        #expect(!MountPolicy.defaultReadOnly(isProd: false))
        var c = Connection(name: "Prod", host: "h", username: "u", isProd: true, mountInFinder: true)
        let spec = MountPolicy.desiredDomains(connections: [c]).first
        #expect(spec?.displayName == "Prod (read-only)" && spec?.readOnly == true)
        c.mountReadOnly = false
        #expect(MountPolicy.desiredDomains(connections: [c]).first?.displayName == "Prod")
    }

    @Test func mountsNeverElevate() {
        let c = Connection(name: "x", host: "h", username: "u", elevation: .sudo)
        #expect(MountPolicy.config(for: c).elevation == .none)
        #expect(c.config.elevation == .sudo)
    }

    @Test func desiredDomainsOnlyForMountedAndDedupeNames() {
        let client = UUID()
        let a = Connection(name: "Prod", clientFolderId: client, host: "a", username: "u", mountInFinder: true, createdAt: t0)
        let b = Connection(name: "Prod", clientFolderId: client, host: "b", username: "u", mountInFinder: true, createdAt: t0.addingTimeInterval(1))
        let off = Connection(name: "Off", host: "c", username: "u", mountInFinder: false)
        let gone = Connection(name: "Gone", host: "d", username: "u", mountInFinder: true, removedFromSource: true)
        let specs = MountPolicy.desiredDomains(connections: [b, a, off, gone], clientNames: [client: "Acme"])
        #expect(specs.map(\.displayName) == ["Acme – Prod", "Acme – Prod 2"])
        #expect(specs.map(\.connectionId) == [a.id, b.id])
    }

    @Test func mountOnLaunchSelection() {
        let a = Connection(name: "a", host: "h", username: "u", mountInFinder: true, mountOnLaunch: true)
        let b = Connection(name: "b", host: "h", username: "u", mountInFinder: true, mountOnLaunch: false)
        let c = Connection(name: "c", host: "h", username: "u", mountInFinder: false, mountOnLaunch: true)
        #expect(MountPolicy.mountOnLaunch([a, b, c]).map(\.name) == ["a"])
    }

    @Test func reconcileAddsRemovesAndRenames() {
        let keep = Connection(name: "Keep", host: "h", username: "u", mountInFinder: true, createdAt: t0)
        var renamed = Connection(name: "Old", host: "h", username: "u", mountInFinder: true, createdAt: t0.addingTimeInterval(1))
        let new = Connection(name: "New", host: "h", username: "u", mountInFinder: true, createdAt: t0.addingTimeInterval(2))
        let registeredRenamed = MountPolicy.desiredDomains(connections: [renamed])[0]
        let registered = MountPolicy.desiredDomains(connections: [keep]) + [registeredRenamed]
            + [MountDomainSpec(identifier: MountNaming.domainIdentifier(for: UUID()), connectionId: UUID(), displayName: "Deleted conn", readOnly: false)]
        renamed.name = "Newer name"
        let diff = MountPolicy.reconcile(registered: registered, connections: [keep, renamed, new])
        #expect(diff.add.map(\.displayName) == ["New"])
        #expect(diff.update.map(\.displayName) == ["Newer name"])
        #expect(diff.remove.count == 1)
        // Toggling read-only counts as an update.
        renamed.mountReadOnly = true
        #expect(MountPolicy.reconcile(registered: [registeredRenamed], connections: [renamed]).update.first?.readOnly == true)
        // Turning mounting off removes the domain; nothing to do when already in sync.
        var off = keep; off.mountInFinder = false
        #expect(MountPolicy.reconcile(registered: [registered[0]], connections: [off]).remove == [registered[0].identifier])
        #expect(MountPolicy.reconcile(registered: [registered[0]], connections: [keep]).isEmpty)
    }

    // MARK: Conflict copies

    @Test func conflictCopyNames() {
        #expect(FileNaming.conflictCopy("report.txt", date: t0, timeZone: utc) == "report (conflict 2023-11-14).txt")
        #expect(FileNaming.conflictCopy("Makefile", date: t0, timeZone: utc) == "Makefile (conflict 2023-11-14)")
        #expect(FileNaming.conflictCopy(".bashrc", date: t0, timeZone: utc) == ".bashrc (conflict 2023-11-14)")
        #expect(FileNaming.conflictCopy("backup.tar.gz", date: t0, timeZone: utc) == "backup (conflict 2023-11-14).tar.gz")
        #expect(FileNaming.conflictCopy("my.file.name.php", date: t0, timeZone: utc) == "my.file.name (conflict 2023-11-14).php")
        #expect(FileNaming.conflictCopy("trailing.", date: t0, timeZone: utc) == "trailing. (conflict 2023-11-14)")
    }

    @Test func conflictCopyHonoursTimeZone() {
        let late = Date(timeIntervalSince1970: 1_700_000_000 + 3 * 3600)  // 01:13 UTC on the 15th
        #expect(FileNaming.conflictCopy("a.txt", date: late, timeZone: utc) == "a (conflict 2023-11-15).txt")
        #expect(FileNaming.conflictCopy("a.txt", date: late, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "a (conflict 2023-11-14).txt")
    }

    @Test func conflictCopiesNeverCollide() {
        let first = "a (conflict 2023-11-14).txt"
        #expect(FileNaming.uniqueConflictCopy("a.txt", date: t0, existing: [], timeZone: utc) == first)
        #expect(FileNaming.uniqueConflictCopy("a.txt", date: t0, existing: [first], timeZone: utc) == "a (conflict 2023-11-14 2).txt")
        #expect(FileNaming.uniqueConflictCopy("a.txt", date: t0, existing: [first, "a (conflict 2023-11-14 2).txt"], timeZone: utc) == "a (conflict 2023-11-14 3).txt")
    }

    @Test func numberedNames() {
        #expect(FileNaming.numbered("a.txt", 1) == "a (1).txt")
        #expect(FileNaming.numbered("noext", 2) == "noext (2)")
        #expect(FileNaming.numbered("x.tar.gz", 3) == "x (3).tar.gz")
    }

    @Test func conflictDecisionMatrix() {
        let base = RemoteVersion(modified: t0, size: 10)
        func decide(remote: RemoteVersion?, edited: Bool) -> MountConflict.Decision {
            MountConflict.decide(fileName: "a.txt", downloaded: base, currentRemote: remote, locallyEdited: edited, siblings: [], now: t0, timeZone: utc)
        }
        // Only edited locally: upload.
        #expect(decide(remote: base, edited: true) == .upload)
        // Only changed on the server (not edited locally): nothing to keep.
        #expect(decide(remote: RemoteVersion(modified: t0.addingTimeInterval(60), size: 10), edited: false) == .upload)
        // Both changed: keep both.
        #expect(decide(remote: RemoteVersion(modified: t0.addingTimeInterval(60), size: 10), edited: true) == .keepBoth(conflictName: "a (conflict 2023-11-14).txt"))
        // Size alone is enough.
        #expect(decide(remote: RemoteVersion(modified: t0, size: 11), edited: true) == .keepBoth(conflictName: "a (conflict 2023-11-14).txt"))
        // Within mtime tolerance and same size: no conflict.
        #expect(decide(remote: RemoteVersion(modified: t0.addingTimeInterval(0.4), size: 10), edited: true) == .upload)
        // File deleted on the server meanwhile: upload recreates it.
        #expect(decide(remote: nil, edited: true) == .upload)
        // Unknown times fall back on sizes.
        #expect(MountConflict.isConflict(downloaded: RemoteVersion(modified: nil, size: 5), currentRemote: RemoteVersion(modified: nil, size: 6), locallyEdited: true))
        #expect(!MountConflict.isConflict(downloaded: RemoteVersion(modified: nil, size: 5), currentRemote: RemoteVersion(modified: nil, size: 5), locallyEdited: true))
        #expect(MountConflict.warning(for: "a.txt", conflictName: "a (conflict 2023-11-14).txt").contains("kept both"))
    }

    @Test func conflictNameAvoidsExistingSiblings() {
        let d = MountConflict.decide(fileName: "a.txt", downloaded: RemoteVersion(modified: t0, size: 1), currentRemote: RemoteVersion(modified: t0, size: 2),
                                     locallyEdited: true, siblings: ["a (conflict 2023-11-14).txt"], now: t0, timeZone: utc)
        #expect(d == .keepBoth(conflictName: "a (conflict 2023-11-14 2).txt"))
    }

    // MARK: Polling

    @Test func pollingSettingsClamp() {
        #expect(MountPollingSettings().interval == 30)
        #expect(MountPollingSettings(interval: 1).interval == 5)
        #expect(MountPollingSettings(interval: 99_999).interval == 3600)
        #expect(MountPollingSettings(interval: .nan).interval == 30)
        #expect(MountPollingSettings(interval: 45).interval == 45)
    }

    @Test func pollingBackoff() {
        let s = MountPollingSettings(interval: 30)
        #expect(s.delay(afterConsecutiveFailures: 0) == 30)
        #expect(s.delay(afterConsecutiveFailures: 1) == 60)
        #expect(s.delay(afterConsecutiveFailures: 3) == 240)
        #expect(s.delay(afterConsecutiveFailures: 50) == 600)  // capped
        #expect(MountPollingSettings(interval: 3600).delay(afterConsecutiveFailures: 4) == 3600)  // never below the user's interval
    }

    @Test func pollingSettingsCodable() throws {
        let data = try JSONEncoder().encode(MountPollingSettings(interval: 90))
        #expect(try JSONDecoder().decode(MountPollingSettings.self, from: data).interval == 90)
    }

    @Test func directoryDiff() {
        func f(_ n: String, size: UInt64 = 1, mod: Double = 0, dir: Bool = false) -> RemoteItem {
            RemoteItem(name: n, path: "/\(n)", isDirectory: dir, size: size, modified: Date(timeIntervalSince1970: mod))
        }
        let old = [f("same"), f("grew"), f("touched", mod: 0), f("gone"), f("swap")]
        let new = [f("same"), f("grew", size: 9), f("touched", mod: 100), f("fresh"), f("swap", dir: true)]
        let d = DirectoryChangeDetector.diff(old: old, new: new)
        #expect(d.added.map(\.name) == ["fresh"])
        #expect(d.modified.map(\.name) == ["grew", "touched", "swap"])
        #expect(d.deleted.map(\.name) == ["gone"])
        #expect(DirectoryChangeDetector.diff(old: old, new: old).isEmpty)
        #expect(DirectoryChangeDetector.diff(old: [f("a", mod: 0)], new: [f("a", mod: 0.5)]).isEmpty)  // within tolerance
    }

    @Test func finderLogSource() {
        let line = LogLine(kind: .status, message: FinderLog.message("Opened /a.txt"))
        #expect(FinderLog.isFromFinder(line))
        #expect(!FinderLog.isFromFinder(LogLine(kind: .status, message: "Opened /a.txt")))
    }
}
