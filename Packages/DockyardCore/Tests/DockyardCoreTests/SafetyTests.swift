import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private let utc = TimeZone(identifier: "UTC")!
/// 2026-10-27 12:00 UTC
private let noon = Date(timeIntervalSince1970: 1_793_102_400)
private let today = "2026-10-27"

private func net(
    _ policy: SafetyPolicy = SafetyPolicy(trashOnDelete: true, keepVersionsOnOverwrite: true),
    clock: any DockyardClock = ManualClock(start: noon),
    ask: @escaping SafetyDecision = { _ in false },
    log: @escaping @Sendable (LogLine.Kind, String) -> Void = { _, _ in }
) -> SafetyNet {
    SafetyNet(policy: policy, clock: clock, timeZone: utc, decision: ask, log: log)
}

@Suite struct GuardrailTests {
    let paths = (1...15).map { "/srv/file\($0).txt" }

    @Test func readOnlyBlocksEveryWrite() {
        for kind in OperationKind.allCases where kind.writes {
            let decision = Guardrails.decide(GuardedOperation(kind, paths: ["/a"]), isProd: false, readOnly: true, connectionName: "Client")
            guard case .deny(let reason) = decision else { Issue.record("\(kind) was not denied"); continue }
            #expect(reason.contains("\"Client\"") && reason.contains("read-only"))
        }
        #expect(Guardrails.decide(GuardedOperation(.download, paths: ["/a"]), isProd: true, readOnly: true) == .allow)
    }

    @Test func readOnlyIgnoresSessionSuppression() {
        let decision = Guardrails.decide(GuardedOperation(.delete, paths: ["/a"]), isProd: true, readOnly: true, suppressed: [.delete])
        #expect(decision == .deny(reason: "This site is read-only, so Dockyard will not delete it. Turn off Read-only in the site settings to allow changes."))
    }

    @Test func prodConfirmsDeleteAndOverwrite() throws {
        guard case .confirm(let summary) = Guardrails.decide(GuardedOperation(.delete, paths: paths), isProd: true, readOnly: false) else {
            Issue.record("expected a confirmation"); return
        }
        #expect(summary.title == "Delete 15 items on a PROD site?")
        #expect(summary.items.count == 10 && summary.hiddenCount == 5 && summary.totalCount == 15)
        #expect(summary.canSuppressForSession)

        guard case .confirm(let overwrite) = Guardrails.decide(GuardedOperation(.overwrite, paths: ["/x"]), isProd: true, readOnly: false) else {
            Issue.record("expected a confirmation"); return
        }
        #expect(overwrite.title == "Overwrite 1 item on a PROD site?" && overwrite.kind == .overwrite)
    }

    @Test func prodDoesNotAskAboutHarmlessOperations() {
        for kind in [OperationKind.upload, .download, .mkdir, .rename, .chmod, .extract] {
            #expect(Guardrails.decide(GuardedOperation(kind, paths: ["/a"]), isProd: true, readOnly: false) == .allow)
        }
    }

    @Test func nonProdNeverAsks() {
        #expect(Guardrails.decide(GuardedOperation(.delete, paths: ["/a"]), isProd: false, readOnly: false) == .allow)
    }

    @Test func suppressedKindsAreAllowed() {
        let op = GuardedOperation(.delete, paths: ["/a"])
        #expect(Guardrails.decide(op, isProd: true, readOnly: false, suppressed: [.delete]) == .allow)
        if case .confirm = Guardrails.decide(GuardedOperation(.overwrite, paths: ["/a"]), isProd: true, readOnly: false, suppressed: [.delete]) {} else {
            Issue.record("overwrite should still ask")
        }
    }

    @Test func connectionOverload() {
        var c = makeConn("Acme")
        c.isProd = true
        if case .confirm = Guardrails.decide(GuardedOperation(.delete, paths: ["/a"]), for: c) {} else { Issue.record("expected confirm") }
        c.readOnly = true
        if case .deny(let reason) = Guardrails.decide(GuardedOperation(.upload, paths: ["/a"]), for: c) {
            #expect(reason.contains("Acme"))
        } else { Issue.record("expected deny") }
    }
}

@Suite struct TrashLayoutTests {
    @Test func rootUnderHome() throws {
        #expect(try TrashLayout.root(forHome: "/home/jane") == .init(path: "/home/jane/.dockyard-trash", warning: nil))
        #expect(try TrashLayout.root(forHome: "/home/jane/").path == "/home/jane/.dockyard-trash")
    }

    @Test(arguments: ["public_html", "www", "htdocs", "httpdocs", "WWW"])
    func rootNeverInsideWebRoot(_ name: String) throws {
        let root = try TrashLayout.root(forHome: "/home/jane/\(name)")
        #expect(root.path == "/home/jane/.dockyard-trash" && root.warning != nil)
        #expect(!TrashLayout.isInsideWebRoot(root.path))
        #expect(try TrashLayout.root(forHome: "/var/\(name)/site").path == "/var/.dockyard-trash")
    }

    @Test func refusesWhenNoSafeParentExists() {
        #expect(throws: SafetyNetError.noSafeLocation("/www")) { try TrashLayout.root(forHome: "/www") }
        let chroot = try? TrashLayout.root(forHome: "/")
        #expect(chroot?.path == "/.dockyard-trash" && chroot?.warning != nil)
    }

    @Test func destinationMirrorsOriginalPath() {
        let root = "/home/jane/.dockyard-trash"
        #expect(TrashLayout.destination(root: root, day: today, original: "/var/www/a.txt")
                == "/home/jane/.dockyard-trash/2026-10-27/var/www/a.txt")
        #expect(TrashLayout.destination(root: root, day: today, original: "/a.txt", version: 3)
                == "/home/jane/.dockyard-trash/2026-10-27/a.txt.~3~")
    }

    @Test func versionParsing() {
        #expect(TrashLayout.parseVersion("a.txt.~3~") == ("a.txt", 3))
        #expect(TrashLayout.parseVersion("a.txt") == ("a.txt", 1))
        #expect(TrashLayout.parseVersion("a.~1~") == ("a.~1~", 1))
        #expect(TrashLayout.parseVersion("weird~") == ("weird~", 1))
    }

    @Test func normalizeAndPredicates() {
        #expect(TrashLayout.normalize("site//./css/../js/", home: "/home/j") == "/home/j/site/js")
        #expect(TrashLayout.normalize("/abs/x", home: "/home/j") == "/abs/x")
        #expect(TrashLayout.isInsideTrash("/home/j/.dockyard-trash/2026-10-27/a"))
        #expect(!TrashLayout.isInsideTrash("/home/j/a"))
        #expect(TrashLayout.isDayName("2026-10-27") && !TrashLayout.isDayName("2026-1-27") && !TrashLayout.isDayName("abcd-ef-gh"))
    }
}

@Suite struct SafetyNetTests {
    let root = "/home/user/.dockyard-trash/\(today)"

    @Test func switchesOffMeansNothingHappens() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.put("/home/user/site/a.txt", "A")
        let off = net(.off)
        #expect(try await off.prepareDelete(path: "/home/user/site/a.txt", on: fs) == .notApplicable)
        #expect(try await off.prepareOverwrite(path: "/home/user/site/a.txt", on: fs) == .notApplicable)
        #expect(fs.base.text("/home/user/site/a.txt") == "A")
        #expect(!fs.base.calls.contains { $0.hasPrefix("rename") || $0.hasPrefix("mkdir") })
    }

    @Test func switchesAreIndependent() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.put("/home/user/a.txt", "A")
        let onlyVersions = net(SafetyPolicy(trashOnDelete: false, keepVersionsOnOverwrite: true))
        #expect(try await onlyVersions.prepareDelete(path: "/home/user/a.txt", on: fs) == .notApplicable)
        let onlyTrash = net(SafetyPolicy(trashOnDelete: true, keepVersionsOnOverwrite: false))
        #expect(try await onlyTrash.prepareOverwrite(path: "/home/user/a.txt", on: fs) == .notApplicable)
        #expect(fs.base.text("/home/user/a.txt") == "A")
        guard case .preserved = try await onlyTrash.prepareDelete(path: "/home/user/a.txt", on: fs) else {
            Issue.record("delete should be preserved"); return
        }
        #expect(fs.base.text("/home/user/a.txt") == nil)
    }

    @Test func deleteMovesIntoDatedTrashKeepingThePath() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.put("/var/www/site/index.php", "<?php")
        let outcome = try await net().prepareDelete(path: "/var/www/site/index.php", on: fs)
        guard case .preserved(let entry, let removed) = outcome else { Issue.record("not preserved"); return }
        #expect(removed && !outcome.originalStillInPlace)
        #expect(entry.trashPath == "\(root)/var/www/site/index.php" && entry.originalPath == "/var/www/site/index.php")
        #expect(entry.day == today && !entry.isDirectory && entry.size == 5 && entry.version == 1)
        #expect(fs.base.text(entry.trashPath) == "<?php")
        #expect(fs.base.text("/var/www/site/index.php") == nil)
        #expect(entry.trashPath.hasPrefix("/home/user/.dockyard-trash/"))
    }

    @Test func overwriteKeepsTheOldVersion() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.put("/home/user/public_html/app.js", "v1")
        let outcome = try await net().prepareOverwrite(path: "public_html/app.js", on: fs)
        guard case .preserved(let entry, _) = outcome else { Issue.record("not preserved"); return }
        #expect(entry.originalPath == "/home/user/public_html/app.js")
        #expect(fs.base.text("\(root)/home/user/public_html/app.js") == "v1")
    }

    @Test func missingPathNeedsNoBackup() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.makeDir("/home/user/site")
        #expect(try await net().prepareOverwrite(path: "/home/user/site/new.txt", on: fs) == .notApplicable)
        #expect(!fs.base.hasDir("/home/user/.dockyard-trash"))
    }

    @Test func sameNameTwiceGetsAVersionSuffix() async throws {
        let fs = ShellFakeFileSystem()
        let safety = net()
        fs.base.put("/srv/a.txt", "one")
        _ = try await safety.prepareDelete(path: "/srv/a.txt", on: fs)
        fs.base.put("/srv/a.txt", "two")
        guard case .preserved(let second, _) = try await safety.prepareDelete(path: "/srv/a.txt", on: fs) else {
            Issue.record("not preserved"); return
        }
        #expect(second.version == 2 && second.trashPath == "\(root)/srv/a.txt.~2~")
        #expect(fs.base.text("\(root)/srv/a.txt") == "one" && fs.base.text(second.trashPath) == "two")
    }

    @Test func folderIsMovedWithItsContentAndMarked() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.put("/srv/old/css/site.css", "css")
        fs.base.put("/srv/old/index.html", "html")
        guard case .preserved(let entry, true) = try await net().prepareDelete(path: "/srv/old", on: fs) else {
            Issue.record("not preserved"); return
        }
        #expect(entry.isDirectory)
        #expect(fs.base.text("\(root)/srv/old/css/site.css") == "css")
        #expect(fs.base.text("\(root)/srv/old.~dir~") == "")
        #expect(!fs.base.hasDir("/srv/old"))
    }

    @Test func fallsBackToCopyWhenRenameFails() async throws {
        let fs = ScriptedShellFileSystem()
        fs.renameFails.withLock { $0 = true }
        fs.base.put("/mnt/data/report.csv", "rows")
        fs.script { [base = fs.base] command in
            // cp -a -- 'src' 'dst'
            let parts = command.split(separator: "'").map(String.init)
            if parts.count >= 4, let text = base.text(parts[1]) { base.put(parts[3], text); return ("", "", 0) }
            return ("", "no such file", 1)
        }
        let outcome = try await net().prepareOverwrite(path: "/mnt/data/report.csv", on: fs)
        guard case .preserved(let entry, let removed) = outcome else { Issue.record("not preserved"); return }
        #expect(!removed && outcome.originalStillInPlace)
        #expect(fs.base.text(entry.trashPath) == "rows" && fs.base.text("/mnt/data/report.csv") == "rows")
        #expect(fs.commands.withLock { $0 }.first?.hasPrefix("cp -a -- '/mnt/data/report.csv' '\(root)/mnt/data/report.csv'") == true)
    }

    @Test func copyFallbackWithoutShellRelaysThroughTheMac() async throws {
        let fs = ShellFakeFileSystem()
        fs.renameFails.withLock { $0 = true }
        fs.base.put("/mnt/a/b.bin", "bytes")
        fs.base.put("/mnt/dir/x.txt", "x")
        guard case .preserved(_, false) = try await net().prepareDelete(path: "/mnt/a/b.bin", on: fs) else {
            Issue.record("file not preserved"); return
        }
        guard case .preserved(let dir, false) = try await net().prepareDelete(path: "/mnt/dir", on: fs) else {
            Issue.record("dir not preserved"); return
        }
        #expect(fs.base.text("\(root)/mnt/a/b.bin") == "bytes" && fs.base.text("/mnt/a/b.bin") == "bytes")
        #expect(fs.base.text("\(dir.trashPath)/x.txt") == "x")
    }

    @Test func asksWhenNothingWorksAndHonoursTheAnswer() async throws {
        let fs = ScriptedShellFileSystem()
        fs.renameFails.withLock { $0 = true }
        fs.script { _ in ("", "Permission denied", 1) }
        fs.base.put("/locked/a.txt", "A")
        let asked = LockedBox<[SafetyFailure]>([])

        let yes = net(ask: { failure in asked.withLock { $0.append(failure) }; return true })
        #expect(try await yes.prepareDelete(path: "/locked/a.txt", on: fs) == .proceedUnprotected)
        #expect(asked.withLock { $0 }.first?.operation == .delete && asked.withLock { $0 }.first?.path == "/locked/a.txt")
        #expect(fs.base.text("/locked/a.txt") == "A")

        let no = net(ask: { _ in false })
        await #expect(throws: SafetyNetError.declined("/locked/a.txt")) {
            _ = try await no.prepareOverwrite(path: "/locked/a.txt", on: fs)
        }
    }

    @Test func warnsAndRelocatesWhenHomeIsInsideAWebRoot() async throws {
        let fs = ShellFakeFileSystem(home: "/home/jane/public_html")
        fs.base.put("/home/jane/public_html/a.txt", "A")
        let warnings = LockedBox<[String]>([])
        let safety = net(log: { kind, text in if kind == .warning { warnings.withLock { $0.append(text) } } })
        guard case .preserved(let entry, _) = try await safety.prepareDelete(path: "/home/jane/public_html/a.txt", on: fs) else {
            Issue.record("not preserved"); return
        }
        #expect(entry.trashPath.hasPrefix("/home/jane/.dockyard-trash/\(today)/"))
        #expect(warnings.withLock { $0 }.count == 1)
    }

    @Test func refusesToUseAWebRootAsOnlyOption() async throws {
        let fs = ShellFakeFileSystem(home: "/public_html")
        fs.base.put("/public_html/a.txt", "A")
        await #expect(throws: SafetyNetError.declined("/public_html/a.txt")) {
            _ = try await net().prepareDelete(path: "/public_html/a.txt", on: fs)
        }
        #expect(fs.base.text("/public_html/a.txt") == "A")
    }

    @Test func itemsAlreadyInTheTrashAreDeletedForReal() async throws {
        let fs = ShellFakeFileSystem()
        fs.base.put("/home/user/.dockyard-trash/2026-10-01/a.txt", "old")
        #expect(try await net().prepareDelete(path: "/home/user/.dockyard-trash/2026-10-01/a.txt", on: fs) == .notApplicable)
    }

    @Test func dayFollowsTheClock() async throws {
        let clock = ManualClock(start: noon)
        let fs = ShellFakeFileSystem()
        let safety = net(clock: clock)
        fs.base.put("/a", "1")
        _ = try await safety.prepareDelete(path: "/a", on: fs)
        clock.advance(by: 86_400)
        fs.base.put("/a", "2")
        guard case .preserved(let entry, _) = try await safety.prepareDelete(path: "/a", on: fs) else { Issue.record("x"); return }
        #expect(entry.day == "2026-10-28" && entry.version == 1)
    }

    @Test func policyFromConnection() {
        var c = makeConn()
        #expect(SafetyPolicy(c) == .off)
        c.trashOnDelete = true
        #expect(SafetyPolicy(c) == SafetyPolicy(trashOnDelete: true, keepVersionsOnOverwrite: false))
    }
}

@Suite struct TrashBrowserTests {
    func setup() -> (ShellFakeFileSystem, ManualClock, SafetyNet, TrashBrowser) {
        let fs = ShellFakeFileSystem()
        let clock = ManualClock(start: noon)
        return (fs, clock, net(clock: clock), TrashBrowser(fs: fs, clock: clock, timeZone: utc))
    }

    @Test func listsFilesFoldersAndVersions() async throws {
        let (fs, clock, safety, browser) = setup()
        fs.base.put("/srv/site/a.txt", "1")
        fs.base.put("/srv/site/sub/b.txt", "22")
        fs.base.put("/srv/old/c.txt", "333")
        fs.base.makeDir("/srv/emptydir")
        _ = try await safety.prepareDelete(path: "/srv/site/a.txt", on: fs)
        fs.base.put("/srv/site/a.txt", "again")
        _ = try await safety.prepareDelete(path: "/srv/site/a.txt", on: fs)
        _ = try await safety.prepareDelete(path: "/srv/site/sub", on: fs)
        clock.advance(by: 86_400)
        _ = try await safety.prepareDelete(path: "/srv/old", on: fs)
        _ = try await safety.prepareDelete(path: "/srv/emptydir", on: fs)

        let entries = try await browser.entries()
        #expect(entries.map(\.originalPath) == ["/srv/emptydir", "/srv/old", "/srv/site/a.txt", "/srv/site/a.txt", "/srv/site/sub"])
        #expect(entries.map(\.day) == ["2026-10-28", "2026-10-28", "2026-10-27", "2026-10-27", "2026-10-27"])
        #expect(entries.filter { $0.originalPath == "/srv/site/a.txt" }.map(\.version).sorted() == [1, 2])
        #expect(entries.first { $0.originalPath == "/srv/old" }?.isDirectory == true)
        #expect(entries.first { $0.originalPath == "/srv/emptydir" }?.isDirectory == true)
    }

    @Test func emptyTrashLists_nothing() async throws {
        let (_, _, _, browser) = setup()
        #expect(try await browser.entries().isEmpty)
    }

    @Test func restoreBringsTheFileBackAndCleansUp() async throws {
        let (fs, _, safety, browser) = setup()
        fs.base.put("/srv/site/a.txt", "precious")
        _ = try await safety.prepareDelete(path: "/srv/site/a.txt", on: fs)
        let entry = try #require(try await browser.entries().first)
        let plan = try await browser.restorePlan(for: entry, policy: .ask)
        #expect(plan.action == .restore && plan.destination == "/srv/site/a.txt")
        let result = try await browser.restore(plan)
        #expect(result == RestoreResult(restoredPath: "/srv/site/a.txt", skipped: false))
        #expect(fs.base.text("/srv/site/a.txt") == "precious")
        #expect(try await browser.entries().isEmpty)
        #expect(!fs.base.hasDir("/home/user/.dockyard-trash/\(today)"))
    }

    @Test func restoreRecreatesMissingParentFolders() async throws {
        let (fs, _, safety, browser) = setup()
        fs.base.put("/srv/deep/er/a.txt", "x")
        _ = try await safety.prepareDelete(path: "/srv/deep", on: fs)
        let entry = try #require(try await browser.entries().first)
        try await browser.restore(try await browser.restorePlan(for: entry, policy: .ask))
        #expect(fs.base.text("/srv/deep/er/a.txt") == "x")
        #expect(fs.base.text("/home/user/.dockyard-trash/\(today)/srv/deep.~dir~") == nil)
    }

    @Test func conflictPolicies() async throws {
        let (fs, _, safety, browser) = setup()
        fs.base.put("/srv/a.txt", "old")
        _ = try await safety.prepareDelete(path: "/srv/a.txt", on: fs)
        fs.base.put("/srv/a.txt", "new")
        let entry = try #require(try await browser.entries().first)

        let ask = try await browser.restorePlan(for: entry, policy: .ask)
        guard case .needsDecision(let existing) = ask.action else { Issue.record("expected a decision"); return }
        #expect(existing.size == 3)
        #expect(try await browser.restore(ask).skipped)

        let skip = try await browser.restorePlan(for: entry, policy: .skip)
        #expect(skip.action == .skip && fs.base.text("/srv/a.txt") == "new")

        let rename = try await browser.restorePlan(for: entry, policy: .rename)
        #expect(rename.action == .restoreAs("a (conflict 2026-10-27).txt"))
        let renamed = try await browser.restore(rename)
        #expect(renamed.restoredPath == "/srv/a (conflict 2026-10-27).txt")
        #expect(fs.base.text("/srv/a (conflict 2026-10-27).txt") == "old" && fs.base.text("/srv/a.txt") == "new")
    }

    @Test func overwriteReplacesTheCurrentFile() async throws {
        let (fs, _, safety, browser) = setup()
        fs.base.put("/srv/a.txt", "old")
        _ = try await safety.prepareDelete(path: "/srv/a.txt", on: fs)
        fs.base.put("/srv/a.txt", "new")
        let entry = try #require(try await browser.entries().first)
        let plan = try await browser.restorePlan(for: entry, policy: .ask).resolving(.overwrite)
        try await browser.restore(plan)
        #expect(fs.base.text("/srv/a.txt") == "old")
    }

    @Test func restoreToAnotherLocation() async throws {
        let (fs, _, safety, browser) = setup()
        fs.base.put("/srv/a.txt", "old")
        _ = try await safety.prepareDelete(path: "/srv/a.txt", on: fs)
        fs.base.makeDir("/elsewhere")
        let entry = try #require(try await browser.entries().first)
        try await browser.restore(try await browser.restorePlan(for: entry, policy: .ask, destination: "/elsewhere/a.txt"))
        #expect(fs.base.text("/elsewhere/a.txt") == "old")
    }

    @Test func deleteNowAndEmpty() async throws {
        let (fs, _, safety, browser) = setup()
        for name in ["a", "b", "c"] { fs.base.put("/srv/\(name)", name) }
        for name in ["a", "b", "c"] { _ = try await safety.prepareDelete(path: "/srv/\(name)", on: fs) }
        var entries = try await browser.entries()
        try await browser.deleteNow(try #require(entries.first { $0.name == "b" }))
        entries = try await browser.entries()
        #expect(entries.map(\.name).sorted() == ["a", "c"])
        try await browser.empty()
        #expect(try await browser.entries().isEmpty)
        #expect(!fs.base.hasDir("/home/user/.dockyard-trash"))
        try await browser.empty()  // already gone
    }

    @Test func deleteNowRemovesFolderMarkers() async throws {
        let (fs, _, safety, browser) = setup()
        fs.base.put("/srv/d/x", "x")
        _ = try await safety.prepareDelete(path: "/srv/d", on: fs)
        try await browser.deleteNow(try #require(try await browser.entries().first))
        #expect(fs.base.text("/home/user/.dockyard-trash/\(today)/srv/d.~dir~") == nil)
        #expect(!fs.base.hasDir("/home/user/.dockyard-trash/\(today)"))
    }

    @Test func purgeDropsOnlyOldDays() async throws {
        let (fs, clock, safety, browser) = setup()
        fs.base.put("/srv/old", "o")
        _ = try await safety.prepareDelete(path: "/srv/old", on: fs)       // 2026-10-27
        clock.advance(by: 10 * 86_400)
        fs.base.put("/srv/mid", "m")
        _ = try await safety.prepareDelete(path: "/srv/mid", on: fs)       // 2026-11-06
        clock.advance(by: 5 * 86_400)                                      // 2026-11-11: 15 and 5 days old
        #expect(try await browser.purge() == ["2026-10-27"])
        #expect(try await browser.entries().map(\.name) == ["mid"])
        #expect(try await browser.purge().isEmpty)
        clock.advance(by: 20 * 86_400)
        #expect(try await browser.purge(olderThanDays: 14) == ["2026-11-06"])
        #expect(try await browser.entries().isEmpty)
    }

    @Test func purgeWithNoTrashIsHarmless() async throws {
        let (_, _, _, browser) = setup()
        #expect(try await browser.purge().isEmpty)
    }

    @Test func ignoresUnrelatedFoldersInTheTrashRoot() async throws {
        let (fs, _, _, browser) = setup()
        fs.base.put("/home/user/.dockyard-trash/README", "hi")
        fs.base.put("/home/user/.dockyard-trash/not-a-day/x", "x")
        #expect(try await browser.entries().isEmpty)
        #expect(try await browser.purge().isEmpty)
    }
}

@Suite struct ChecksumTests {
    @Test func knownVector() {
        #expect(ChecksumVerifier.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ChecksumVerifier.sha256(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func streamsLargeFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = dir.appendingPathComponent("big.bin")
        try data.write(to: url)
        #expect(try ChecksumVerifier.sha256(of: url) == ChecksumVerifier.sha256(of: data))
    }

    @Test func digestParsing() {
        let h = String(repeating: "ab", count: 32)
        #expect(ChecksumVerifier.parseDigest("\(h)  file.txt\n") == h)
        #expect(ChecksumVerifier.parseDigest("\\\(h.uppercased())  we\\nird\n") == h)
        #expect(ChecksumVerifier.parseDigest("short  file") == nil)
        #expect(ChecksumVerifier.parseDigest("") == nil)
    }

    func upload(_ text: String) throws -> (URL, String, URL) {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("f.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (url, ChecksumVerifier.sha256(of: Data(text.utf8)), dir)
    }

    @Test func matchAndMismatch() async throws {
        let (url, hash, dir) = try upload("hello")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ScriptedShellFileSystem()
        fs.script { _ in ("\(hash)  /srv/f.txt\n", "", 0) }
        #expect(await ChecksumVerifier.verify(local: url, remote: "/srv/f.txt", on: fs) == .match(hash))

        let corrupted = String(repeating: "0", count: 64)
        fs.script { _ in ("\(corrupted)  /srv/f.txt\n", "", 0) }
        #expect(await ChecksumVerifier.verify(local: url, remote: "/srv/f.txt", on: fs) == .mismatch(local: hash, remote: corrupted))
    }

    @Test func fallsBackToShasumAndQuotesThePath() async throws {
        let (url, hash, dir) = try upload("hello")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ScriptedShellFileSystem()
        fs.script { command in
            command.hasPrefix("sha256sum") ? ("", "sh: sha256sum: not found", 127) : ("\(hash)  x\n", "", 0)
        }
        let nasty = "/srv/it's a $(rm -rf ~) file; `x`.txt"
        #expect(await ChecksumVerifier.verify(local: url, remote: nasty, on: fs) == .match(hash))
        let commands = fs.commands.withLock { $0 }
        #expect(commands == ["sha256sum -- '/srv/it'\\''s a $(rm -rf ~) file; `x`.txt'",
                             "shasum -a 256 -- '/srv/it'\\''s a $(rm -rf ~) file; `x`.txt'"])
    }

    @Test func unavailableCases() async throws {
        let (url, _, dir) = try upload("hello")
        defer { try? FileManager.default.removeItem(at: dir) }
        let none = ScriptedShellFileSystem()  // every command: exit 127
        if case .unavailable = await ChecksumVerifier.verify(local: url, remote: "/f", on: none) {} else { Issue.record("expected unavailable") }

        let missing = ScriptedShellFileSystem()
        missing.script { _ in ("", "sha256sum: /f: No such file or directory", 1) }
        let result = await ChecksumVerifier.verify(local: url, remote: "/f", on: missing)
        #expect(result == .unavailable("sha256sum: /f: No such file or directory"))
        #expect(missing.commands.withLock { $0 }.count == 1)

        let garbage = ScriptedShellFileSystem()
        garbage.script { _ in ("hello world\n", "", 0) }
        if case .unavailable = await ChecksumVerifier.verify(local: url, remote: "/f", on: garbage) {} else { Issue.record("expected unavailable") }

        let noShell = FakeFileSystem()
        #expect(await ChecksumVerifier.verify(local: url, remote: "/f", on: noShell) == .unavailable("This connection has no shell to compute checksums"))
        if case .unavailable = await ChecksumVerifier.verify(local: dir.appendingPathComponent("gone"), remote: "/f", on: none) {} else {
            Issue.record("missing local file should be unavailable")
        }
    }
}
