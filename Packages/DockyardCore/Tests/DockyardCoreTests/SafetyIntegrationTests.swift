import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private let everything = SafetyPolicy(trashOnDelete: true, keepVersionsOnOverwrite: true)

@Suite(.serialized, .enabled(if: IT.enabled)) struct SafetyNetSFTPIntegrationTests {
    @Test func deleteThenRestoreOnARealServer() async throws {
        let fs = try await IT.sftp()
        let dir = try await IT.scratch(fs, "trash")
        let file = RemotePath.join(dir, "weird name 'quoted' $HOME;.txt")
        try await IT.upload(fs, "precious", to: file)

        let net = SafetyNet(policy: everything)
        guard case .preserved(let entry, true) = try await net.prepareDelete(path: file, on: fs) else {
            Issue.record("expected the file to be moved"); return
        }
        let home = try await fs.homeDirectory()
        #expect(entry.trashPath.hasPrefix(RemotePath.join(home, ".dockyard-trash") + "/"))
        #expect(try await fs.stat(file) == nil)
        #expect(try await IT.download(fs, entry.trashPath) == "precious")

        let browser = TrashBrowser(fs: fs)
        let listed = try await browser.entries()
        let found = try #require(listed.first { $0.originalPath == file })
        #expect(found.size == 8)
        let plan = try await browser.restorePlan(for: found, policy: .ask)
        #expect(plan.action == .restore)
        try await browser.restore(plan)
        #expect(try await IT.download(fs, file) == "precious")
        #expect(try await browser.entries().contains { $0.originalPath == file } == false)

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func overwriteKeepsAVersionAndRestoreSwapsItBack() async throws {
        let fs = try await IT.sftp()
        let dir = try await IT.scratch(fs, "versions")
        let file = RemotePath.join(dir, "config.php")
        try await IT.upload(fs, "v1", to: file)

        let net = SafetyNet(policy: everything)
        _ = try await net.prepareOverwrite(path: file, on: fs)
        try await IT.upload(fs, "v2", to: file)
        #expect(try await IT.download(fs, file) == "v2")

        let browser = TrashBrowser(fs: fs)
        let entry = try #require(try await browser.entries().first { $0.originalPath == file })
        let plan = try await browser.restorePlan(for: entry, policy: .overwrite)
        #expect(plan.action == .overwrite)
        try await browser.restore(plan)
        #expect(try await IT.download(fs, file) == "v1")

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func foldersKeepTheirTreeAndMarker() async throws {
        let fs = try await IT.sftp()
        let dir = try await IT.scratch(fs, "folder")
        let tree = RemotePath.join(dir, "theme")
        try await fs.mkdir(tree)
        try await fs.mkdir(RemotePath.join(tree, "css"))
        try await IT.upload(fs, "body{}", to: RemotePath.join(tree, "css/site.css"))

        _ = try await SafetyNet(policy: everything).prepareDelete(path: tree, on: fs)
        let browser = TrashBrowser(fs: fs)
        let entries = try await browser.entries().filter { $0.originalPath.hasPrefix(dir) }
        #expect(entries.map(\.originalPath) == [tree] && entries[0].isDirectory)
        try await browser.restore(try await browser.restorePlan(for: entries[0], policy: .ask))
        #expect(try await IT.download(fs, RemotePath.join(tree, "css/site.css")) == "body{}")
        #expect(try await fs.stat(RemotePath.join(tree, "..dir")) == nil)

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func copyFallbackUsesCpOnTheServer() async throws {
        let sftp = try await IT.sftp()
        let fs = RenameFailingFileSystem(inner: sftp)
        let dir = try await IT.scratch(sftp, "copy")
        let tree = RemotePath.join(dir, "site")
        try await sftp.mkdir(tree)
        try await IT.upload(sftp, "index", to: RemotePath.join(tree, "index.html"))
        try await IT.upload(sftp, "solo", to: RemotePath.join(dir, "solo.txt"))

        guard case .preserved(let fileEntry, false) = try await SafetyNet(policy: everything).prepareOverwrite(path: RemotePath.join(dir, "solo.txt"), on: fs),
              case .preserved(let dirEntry, false) = try await SafetyNet(policy: everything).prepareDelete(path: tree, on: fs) else {
            Issue.record("expected copies"); return
        }
        #expect(try await IT.download(sftp, fileEntry.trashPath) == "solo")
        #expect(try await IT.download(sftp, RemotePath.join(dirEntry.trashPath, "index.html")) == "index")
        // The originals are untouched; the caller deletes or overwrites them next.
        #expect(try await IT.download(sftp, RemotePath.join(tree, "index.html")) == "index")

        try await TrashBrowser(fs: sftp).deleteNow(fileEntry)
        try await TrashBrowser(fs: sftp).deleteNow(dirEntry)
        try await sftp.delete(dir, recursive: true)
        await sftp.disconnect()
    }

    @Test func purgeRemovesOldDays() async throws {
        let fs = try await IT.sftp()
        let home = try await fs.homeDirectory()
        let root = RemotePath.join(home, ".dockyard-trash")
        if try await fs.stat(root) == nil { try await fs.mkdir(root) }
        let old = RemotePath.join(root, "2020-01-01")
        try await fs.mkdir(old)
        try await IT.upload(fs, "x", to: RemotePath.join(old, "x.txt"))
        let purged = try await TrashBrowser(fs: fs).purge(olderThanDays: 14)
        #expect(purged.contains("2020-01-01"))
        #expect(try await fs.stat(old) == nil)
        await fs.disconnect()
    }
}

@Suite(.serialized, .enabled(if: IT.enabled)) struct SafetyNetFTPIntegrationTests {
    @Test(arguments: [2121, 2122])
    func deleteAndRestoreOverFTP(port: Int) async throws {
        let fs = try await IT.ftp(port: port)
        let dir = try await IT.scratch(fs, "ftp-trash")
        let file = RemotePath.join(dir, "a file.txt")
        try await IT.upload(fs, "ftp data", to: file)
        let tree = RemotePath.join(dir, "folder")
        try await fs.mkdir(tree)
        try await IT.upload(fs, "inner", to: RemotePath.join(tree, "i.txt"))

        let net = SafetyNet(policy: everything)
        guard case .preserved(let entry, true) = try await net.prepareDelete(path: file, on: fs) else {
            Issue.record("file not moved"); return
        }
        guard case .preserved(let folderEntry, true) = try await net.prepareDelete(path: tree, on: fs) else {
            Issue.record("folder not moved"); return
        }
        let fileGone = try await fs.stat(file) == nil
        let treeGone = try await fs.stat(tree) == nil
        #expect(fileGone && treeGone)
        #expect(try await IT.download(fs, entry.trashPath) == "ftp data")

        let browser = TrashBrowser(fs: fs)
        let entries = try await browser.entries().filter { $0.originalPath.hasPrefix(dir) }
        #expect(Set(entries.map(\.originalPath)) == [file, tree])
        for e in entries { try await browser.restore(try await browser.restorePlan(for: e, policy: .ask)) }
        #expect(try await IT.download(fs, file) == "ftp data")
        #expect(try await IT.download(fs, RemotePath.join(tree, "i.txt")) == "inner")
        _ = folderEntry

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }
}

@Suite(.serialized, .enabled(if: IT.enabled)) struct ChecksumIntegrationTests {
    @Test func matchMismatchAndNastyNames() async throws {
        let fs = try await IT.sftp()
        let dir = try await IT.scratch(fs, "sum")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sum-\(UUID().uuidString)")
        try "contents of the file".write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }

        for name in ["plain.txt", "it's got 'quotes'.txt", "spaced name $(id).txt", "semi;colon`tick`.txt", "-dash.txt", "new\nline.txt"] {
            let remote = RemotePath.join(dir, name)
            try await fs.upload(local, to: remote, progress: Progress(totalUnitCount: 0))
            let result = await ChecksumVerifier.verify(local: local, remote: remote, on: fs)
            guard case .match = result else { Issue.record("\(name): \(result)"); continue }
        }

        let remote = RemotePath.join(dir, "plain.txt")
        _ = try await fs.exec("printf X >> \(ShellQuote.quote(remote))")
        guard case .mismatch(let l, let r) = await ChecksumVerifier.verify(local: local, remote: remote, on: fs) else {
            Issue.record("expected a mismatch"); return
        }
        #expect(l != r && l.count == 64 && r.count == 64)

        let missing = await ChecksumVerifier.verify(local: local, remote: RemotePath.join(dir, "nope"), on: fs)
        if case .unavailable(let reason) = missing { #expect(reason.contains("No such file")) } else { Issue.record("\(missing)") }

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func ftpHasNoChecksums() async throws {
        let fs = try await IT.ftp()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sum-\(UUID().uuidString)")
        try "x".write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        if case .unavailable = await ChecksumVerifier.verify(local: local, remote: "/x", on: fs) {} else { Issue.record("expected unavailable") }
        await fs.disconnect()
    }
}
