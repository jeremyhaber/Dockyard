import Foundation
import Testing
@testable import DockyardCore

private func skips(_ patterns: [String], _ path: String, dir: Bool = false) -> Bool {
    TransferFilter(patterns: patterns).matches(path: path, isDirectory: dir)
}

@Suite struct TransferFilterTests {
    @Test func globalDefaults() {
        let f = TransferFilter.defaults
        #expect(f.matches(path: ".DS_Store", isDirectory: false))
        #expect(f.matches(path: "photos/2024/.DS_Store", isDirectory: false))
        #expect(f.matches(path: "Thumbs.db", isDirectory: false))
        #expect(f.matches(path: ".git", isDirectory: true))
        #expect(f.matches(path: "src/vendor/node_modules", isDirectory: true))
        #expect(f.matches(path: "node_modules/left-pad/index.js", isDirectory: false))
        #expect(f.matches(path: "sub/.git/config", isDirectory: false))
        #expect(!f.matches(path: "index.php", isDirectory: false))
        #expect(!f.matches(path: "thumbs.db.bak", isDirectory: false))
        // `.git/` and `node_modules/` are folder rules: a file with that name is kept.
        #expect(!f.matches(path: "docs/node_modules", isDirectory: false))
        #expect(!f.matches(path: ".git", isDirectory: false))
    }

    @Test func siteRulesAddToTheDefaults() {
        let f = TransferFilter(site: ["*.log"])
        #expect(f.matches(path: "logs/app.log", isDirectory: false))
        #expect(f.matches(path: ".DS_Store", isDirectory: false))
        let noDefaults = TransferFilter(site: ["*.log"], includeDefaults: false)
        #expect(!noDefaults.matches(path: ".DS_Store", isDirectory: false))
    }

    @Test func siteCanReincludeADefault() {
        let f = TransferFilter(site: ["!.git/"])
        #expect(!f.matches(path: ".git/config", isDirectory: false))
    }

    @Test func wildcards() {
        #expect(skips(["*.log"], "a.log"))
        #expect(skips(["*.log"], "deep/er/a.log"))
        #expect(!skips(["*.log"], "a.logx"))
        #expect(skips(["file?.txt"], "file1.txt"))
        #expect(!skips(["file?.txt"], "file12.txt"))
        #expect(skips(["[abc].tmp"], "b.tmp"))
        #expect(skips(["*~"], "notes.txt~"))
    }

    @Test func directoryOnlyPatterns() {
        #expect(skips(["build/"], "build", dir: true))
        #expect(!skips(["build/"], "build", dir: false))
        #expect(skips(["build/"], "a/build/out.o"))
        #expect(skips(["build/"], "a/b/build", dir: true))
    }

    @Test func anchoredPatterns() {
        #expect(skips(["/build"], "build", dir: true))
        #expect(skips(["/build"], "build/out.o"))
        #expect(!skips(["/build"], "src/build", dir: true))
        #expect(!skips(["/build"], "src/build/out.o"))
        #expect(skips(["src/gen"], "src/gen", dir: true))
        #expect(!skips(["src/gen"], "other/src/gen", dir: true))
    }

    @Test func doubleStar() {
        #expect(skips(["**/cache"], "cache", dir: true))
        #expect(skips(["**/cache"], "a/b/cache", dir: true))
        #expect(skips(["**/cache"], "a/b/cache/x.bin"))
        #expect(!skips(["**/cache"], "a/cached", dir: true))
        #expect(skips(["logs/**"], "logs/a/b.txt"))
        #expect(!skips(["logs/**"], "logs", dir: true))
        #expect(skips(["a/**/z"], "a/z"))
        #expect(skips(["a/**/z"], "a/b/c/z"))
        #expect(skips(["**/*.map"], "assets/js/app.js.map"))
    }

    @Test func singleStarDoesNotCrossDirectories() {
        #expect(!skips(["src/*.o"], "src/deep/a.o"))
        #expect(skips(["src/*.o"], "src/a.o"))
    }

    @Test func negation() {
        let rules = ["*.log", "!keep.log"]
        #expect(skips(rules, "a.log"))
        #expect(!skips(rules, "keep.log"))
        #expect(!skips(rules, "sub/keep.log"))
        // The last matching rule wins.
        #expect(skips(["!keep.log", "*.log"], "keep.log"))
    }

    @Test func cannotReincludeInsideAnIgnoredFolder() {
        let rules = ["vendor/", "!vendor/keep.txt"]
        #expect(skips(rules, "vendor/keep.txt"))
        #expect(skips(rules, "vendor/other.txt"))
        // Ignoring contents with a glob, not the folder, allows it.
        let reopened = ["vendor/*", "!vendor/keep.txt"]
        #expect(!skips(reopened, "vendor/keep.txt"))
        #expect(skips(reopened, "vendor/other.txt"))
    }

    @Test func commentsBlanksAndEscapes() {
        #expect(!skips(["# *.log", "", "   "], "a.log"))
        #expect(skips(["\\#notes"], "#notes"))
        #expect(skips(["\\!important"], "!important"))
        #expect(skips(["trailing  "], "trailing"))
        #expect(skips(["with\\ space\\ "], "with space "))
        #expect(skips(["*.log   "], "a.log"))
    }

    @Test func pathNormalisation() {
        #expect(skips(["build/"], "./build/out", dir: false))
        #expect(skips(["build/"], "/build/out"))
        #expect(!skips(["*.log"], ""))
        #expect(!TransferFilter.none.matches(path: "anything", isDirectory: false))
    }

    @Test func unicodeAndSpacesInNames() {
        #expect(skips(["*.tmp"], "Mappe ohne Titel/ünï cödé.tmp"))
        #expect(skips(["Mappe ohne Titel/"], "Mappe ohne Titel/a.txt"))
        #expect(skips(["[äö]*"], "ärger.txt"))
    }

    @Test func applySplitsAndCounts() {
        struct Item { var path: String; var dir: Bool }
        let items = [Item(path: "index.php", dir: false), Item(path: "a.log", dir: false), Item(path: "node_modules", dir: true),
                     Item(path: "node_modules/x.js", dir: false), Item(path: "src", dir: true)]
        let result = TransferFilter(site: ["*.log"]).apply(items, path: \.path, isDirectory: \.dir)
        #expect(result.kept.map(\.path) == ["index.php", "src"])
        #expect(result.skipped.count == 3)
    }

    @Test func buildsFromAConnection() {
        var c = makeConn()
        c.transferFilters = ["/dist"]
        let f = TransferFilter(connection: c)
        #expect(f.matches(path: "dist/app.js", isDirectory: false) && f.matches(path: "Thumbs.db", isDirectory: false))
    }

    @Test func manyRulesStayFast() {
        let patterns = (0..<500).map { "pattern\($0)*.tmp" } + ["target/"]
        let f = TransferFilter(patterns: patterns)
        let start = Date()
        var skippedCount = 0
        for i in 0..<5_000 where f.matches(path: "dir\(i % 50)/sub/file\(i).txt", isDirectory: false) { skippedCount += 1 }
        #expect(skippedCount == 0)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
