@testable import DockyardCore
import ConnectionKit
import Foundation
import Testing

@Suite struct ChangeJournalTests {
    private let scope = UUID()

    private func journal(limit: Int = 100) throws -> ChangeJournal {
        ChangeJournal(database: try DockyardDatabase(), limit: limit)
    }

    @Test func recordsAndKeepsLastEntries() async throws {
        let j = try journal(limit: 3)
        for n in 1...5 {
            try await j.record(ChangeEntry(scope: scope, kind: .rename, fromPath: "/a\(n)", toPath: "/b\(n)"))
        }
        let list = try await j.entries(scope: scope)
        #expect(list.map(\.toPath) == ["/b5", "/b4", "/b3"])
        #expect(try await j.entries(scope: UUID()).isEmpty)
    }

    @Test func roundTripsFieldsAndUndoRedoOrder() async throws {
        let j = try journal()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await j.record(ChangeEntry(scope: scope, kind: .chmod, toPath: "/x", previousMode: 0o644, newMode: 0o600, time: when))
        let second = try await j.record(ChangeEntry(scope: scope, kind: .upload, toPath: "/y", createdSize: 5, createdModified: when, time: when))
        let loaded = try #require(try await j.nextUndo(scope: scope))
        #expect(loaded == second)
        try await j.setUndone(try #require(second.id), true)
        #expect(try await j.nextUndo(scope: scope)?.kind == .chmod)
        #expect(try await j.nextRedo(scope: scope)?.kind == .upload)
        // A new change discards the redo chain.
        try await j.record(ChangeEntry(scope: scope, kind: .newFolder, toPath: "/z", isDirectory: true))
        #expect(try await j.nextRedo(scope: scope) == nil)
    }

    @Test func undoesAndRedoesMove() async throws {
        let fs = FakeFileSystem()
        fs.put("/new/images/a.jpg", "x")
        fs.makeDir("/old")
        let entry = ChangeEntry(scope: scope, kind: .move, fromPath: "/old/images", toPath: "/new/images", isDirectory: true)
        // The recorded move put the folder at /new/images; /old/images is free.
        let undoer = ChangeUndoer(fs: fs)
        #expect(await undoer.check(entry) == nil)
        try await undoer.undo(entry)
        #expect(fs.hasDir("/old/images"))
        #expect(!fs.hasDir("/new/images"))
        try await undoer.redo(entry)
        #expect(fs.hasDir("/new/images"))
    }

    @Test func refusesWhenStateChangedAndOffersConflictChoices() async throws {
        let fs = FakeFileSystem()
        fs.put("/b.txt", "moved")
        fs.put("/a.txt", "someone else")
        let entry = ChangeEntry(scope: scope, kind: .rename, fromPath: "/a.txt", toPath: "/b.txt")
        let undoer = ChangeUndoer(fs: fs)
        #expect(await undoer.check(entry) == .pathOccupied("/a.txt"))
        await #expect(throws: UndoBlockedError.self) { try await undoer.undo(entry) }
        try await undoer.undo(entry, resolution: .keepBoth)
        #expect(fs.text("/a.txt") == "someone else")
        let names = try await fs.list("/").map(\.name)
        #expect(names.contains { $0.hasPrefix("a (conflict") })
        #expect(await undoer.check(ChangeEntry(scope: scope, kind: .rename, fromPath: "/q", toPath: "/gone")) == .itemMissing("/gone"))
    }

    @Test func undoOfUploadChecksSizeAndTime() async throws {
        let fs = FakeFileSystem()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        fs.put("/up.txt", "12345", modified: when)
        let entry = ChangeEntry(scope: scope, kind: .upload, toPath: "/up.txt", createdSize: 5, createdModified: when)
        let undoer = ChangeUndoer(fs: fs)
        #expect(await undoer.check(entry) == nil)
        #expect(await undoer.check(entry, redo: true) != nil)
        fs.put("/up.txt", "changed!", modified: when)
        #expect(await undoer.check(entry) == .changedSince("/up.txt"))
        fs.put("/up.txt", "12345", modified: when)
        try await undoer.undo(entry)
        #expect(fs.text("/up.txt") == nil)
    }

    @Test func undoOfNewFolderOnlyWhenEmpty() async throws {
        let fs = FakeFileSystem()
        fs.makeDir("/made")
        fs.put("/made/file", "x")
        let entry = ChangeEntry(scope: scope, kind: .newFolder, toPath: "/made", isDirectory: true)
        let undoer = ChangeUndoer(fs: fs)
        #expect(await undoer.check(entry) == .folderNotEmpty("/made"))
        try await fs.delete("/made/file", recursive: false)
        try await undoer.undo(entry)
        #expect(!fs.hasDir("/made"))
        try await undoer.redo(entry)
        #expect(fs.hasDir("/made"))
    }

    @Test func titlesAndSummaries() {
        let move = ChangeEntry(scope: scope, kind: .move, fromPath: "/a/images", toPath: "/old-site/images")
        #expect(move.title == "Move \u{201C}images\u{201D}")
        #expect(move.summary == "Moved \u{201C}images\u{201D} into \u{201C}old-site\u{201D}")
        let rename = ChangeEntry(scope: scope, kind: .rename, fromPath: "/a/x.txt", toPath: "/a/y.txt")
        #expect(rename.summary == "Renamed \u{201C}x.txt\u{201D} to \u{201C}y.txt\u{201D}")
    }
}
