import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

func collect(_ stream: AsyncStream<SearchEvent>) async -> (hits: [SearchHit], progress: [SearchProgress], summary: SearchSummary?) {
    var hits: [SearchHit] = [], progress: [SearchProgress] = []
    var summary: SearchSummary?
    for await event in stream {
        switch event {
        case .hit(let h): hits.append(h)
        case .progress(let p): progress.append(p)
        case .finished(let s): summary = s
        }
    }
    return (hits, progress, summary)
}

/// `find -printf '%y\0%s\0%T@\0%p\0'` output, preceded by the pid line.
private func printfOutput(pid: Int = 4242, _ records: [(type: String, size: Int, mtime: Double, path: String)]) -> String {
    "\(pid)\n" + records.map { "\($0.type)\0\($0.size)\0\($0.mtime)\0\($0.path)\0" }.joined()
}

@Suite struct ShellSearchTests {
    func fs(_ reply: @escaping @Sendable (String) -> (stdout: String, stderr: String, status: Int32)) -> ScriptedShellFileSystem {
        let fs = ScriptedShellFileSystem()
        fs.script(reply)
        return fs
    }

    @Test func nameSearchParsesFindOutput() async throws {
        let shell = fs { _ in
            (printfOutput([("f", 120, 1_700_000_000.5, "/srv/a/config.php"), ("d", 4096, 1_700_000_100, "/srv/a/config.d"),
                           ("f", 0, 1_700_000_200, "/srv/new\nline config.txt"), ("d", 4096, 1, "/srv")]), "", 0)
        }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "config", root: "/srv"), on: shell))
        #expect(result.hits.map(\.path) == ["/srv/a/config.php", "/srv/a/config.d", "/srv/new\nline config.txt"])
        #expect(result.hits[0].size == 120 && result.hits[0].isDirectory == false)
        #expect(result.hits[0].modified == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(result.hits[1].isDirectory == true)
        #expect(result.summary == SearchSummary(hits: 3, truncated: false, cancelled: false, usedShell: true, error: nil))
    }

    @Test func commandIsQuotedAndUsesGlob() async throws {
        let shell = fs { _ in ("1\n", "", 1) }
        _ = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "it's $(x)*", root: "/my dir/o'neil"), on: shell))
        let command = try #require(shell.commands.withLock { $0 }.first)
        #expect(command == "sh -c 'echo $$; exec \"$@\"' sh 'find' '/my dir/o'\\''neil' '-iname' 'it'\\''s $(x)*' '-printf' '%y\\0%s\\0%T@\\0%p\\0'")
    }

    @Test func plainTextBecomesASubstringGlobAndCaseCanBeForced() async throws {
        let shell = fs { _ in ("1\n", "", 1) }
        _ = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "readme", root: "/", caseSensitive: true), on: shell))
        let command = try #require(shell.commands.withLock { $0 }.first)
        #expect(command.contains("'-name' '*readme*'"))
    }

    @Test func rootStartingWithDashIsProtected() async throws {
        let shell = fs { _ in ("1\n", "", 1) }
        _ = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "x", root: "-rf"), on: shell))
        #expect(shell.commands.withLock { $0 }[0].contains("'./-rf'"))
    }

    @Test func fallsBackToPrint0WhenFindHasNoPrintf() async throws {
        let shell = fs { command in
            command.contains("-printf") ? ("", "find: -printf: unknown primary or operator", 1) : ("77\n/a/x.txt\0/a/y.txt\0", "", 0)
        }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "*.txt", root: "/a"), on: shell))
        #expect(result.hits.map(\.path) == ["/a/x.txt", "/a/y.txt"])
        #expect(result.hits[0].size == nil && result.summary?.usedShell == true)
        #expect(shell.commands.withLock { $0 }.count == 2)
    }

    @Test func hitCapStopsAndKillsTheRemoteProcess() async throws {
        let shell = fs { command in
            if command.hasPrefix("sh -c") {
                return ("999\n" + (1...50).map { "/a/f\($0)\0" }.joined(), "", 0)
            }
            return ("", "", 0)
        }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "needle", root: "/a", limit: 10), on: shell))
        #expect(result.hits.count == 10 && result.summary?.truncated == true)
        #expect(shell.commands.withLock { $0 }.last?.contains("kill -TERM 999") == true)
    }

    @Test func contentSearchCommand() async throws {
        let shell = fs { _ in ("5\n/w/a.php\0", "", 0) }
        let query = SearchQuery(mode: .content, text: "-rf $HOME", root: "/w", nameFilter: "*.php")
        let result = await collect(RemoteSearch.search(query, on: shell))
        #expect(result.hits.map(\.path) == ["/w/a.php"])
        let command = shell.commands.withLock { $0 }[0]
        #expect(command == "sh -c 'echo $$; exec \"$@\"' sh 'grep' '-rIlF' '--null' '-i' '--include=*.php' '-e' '-rf $HOME' '--' '/w'")
    }

    @Test func noMatchesIsNotAnError() async throws {
        let shell = fs { _ in ("5\n", "grep: /w/secret: Permission denied", 1) }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "x", root: "/w"), on: shell))
        #expect(result.hits.isEmpty && result.summary?.error == nil)
    }

    @Test func grepFailureIsReported() async throws {
        let shell = fs { _ in ("5\n", "grep: /nope: No such file or directory", 2) }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "x", root: "/nope"), on: shell))
        #expect(result.summary?.error == "grep: /nope: No such file or directory")
    }

    @Test func restrictedShellFallsBackToWalkingForNameSearch() async throws {
        let shell = ScriptedShellFileSystem()
        shell.script { _ in ("", "This service allows sftp connections only.\n", 1) }
        shell.base.put("/srv/a/needle.txt", "x")
        shell.base.put("/srv/b/c/Needle2.txt", "y")
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "needle", root: "/srv"), on: shell))
        #expect(Set(result.hits.map(\.path)) == ["/srv/a/needle.txt", "/srv/b/c/Needle2.txt"])
        #expect(result.summary?.usedShell == false && !result.progress.isEmpty)
    }

    @Test func restrictedShellContentSearchReportsWhy() async throws {
        let shell = ScriptedShellFileSystem()
        shell.script { _ in ("", "This service allows sftp connections only.\n", 1) }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "x", root: "/srv"), on: shell))
        #expect(result.summary?.error == "This service allows sftp connections only.")
    }
}

@Suite struct WalkSearchTests {
    func tree() -> FakeFileSystem {
        let fs = FakeFileSystem()
        fs.put("/site/index.php", "i")
        fs.put("/site/wp-content/themes/twenty/style.CSS", "c")
        fs.put("/site/wp-content/themes/twenty/index.php", "i")
        fs.put("/site/wp-content/plugins/readme.txt", "r")
        fs.makeDir("/site/empty")
        return fs
    }

    @Test func findsByGlobCaseInsensitively() async throws {
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "*.css", root: "/site"), on: tree()))
        #expect(result.hits.map(\.path) == ["/site/wp-content/themes/twenty/style.CSS"])
        #expect(result.summary == SearchSummary(hits: 1, truncated: false, cancelled: false, usedShell: false, error: nil))
        let strict = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "*.css", root: "/site", caseSensitive: true), on: tree()))
        #expect(strict.hits.isEmpty)
    }

    @Test func matchesFoldersToo() async throws {
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "themes", root: "/site"), on: tree()))
        #expect(result.hits.map(\.path) == ["/site/wp-content/themes"] && result.hits[0].isDirectory == true)
    }

    @Test func reportsProgressPerFolder() async throws {
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "zzz", root: "/site"), on: tree()))
        #expect(result.progress.count == 6)
        #expect(result.progress.map(\.foldersScanned) == [1, 2, 3, 4, 5, 6])
        #expect(result.progress.first?.currentFolder == "/site")
    }

    @Test func capsHits() async throws {
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "index", root: "/site", limit: 1), on: tree()))
        #expect(result.hits.count == 1 && result.summary?.truncated == true)
    }

    @Test func contentSearchIsRefusedWithoutAShell() async throws {
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "x", root: "/site"), on: tree()))
        #expect(result.hits.isEmpty && result.summary?.error?.contains("SSH") == true)
    }

    @Test func unreadableFoldersAreReportedNotFatal() async throws {
        let fs = tree()
        fs.state.withLock { $0.listFailures["/site/wp-content"] = RemoteError.permissionDenied("/site/wp-content") }
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "index", root: "/site"), on: fs))
        #expect(result.hits.map(\.path) == ["/site/index.php"])
        #expect(result.summary?.error?.contains("/site/wp-content") == true)
    }

    final class SlowListFileSystem: ShellFakeFileSystem, @unchecked Sendable {
        override func list(_ path: String) async throws -> [RemoteItem] {
            try await Task.sleep(for: .milliseconds(5))
            return try await super.list(path)
        }
    }

    @Test func cancellingStopsTheWalk() async throws {
        let fs = FakeFileSystem()
        let slow = SlowListFileSystem(base: fs)
        for i in 0..<300 { fs.put("/big/d\(i)/f.txt", "x") }
        let task = Task { await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "nomatch", root: "/big"), on: slow)) }
        await waitUntil { fs.calls.count > 3 }
        task.cancel()
        _ = await task.value
        try await Task.sleep(for: .milliseconds(100))
        let settled = fs.calls.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(fs.calls.count == settled && settled < 300)
    }

    @Test func detailsFillSizeAndDate() async throws {
        let fs = tree()
        let filled = await RemoteSearch.details(for: [SearchHit(path: "/site/index.php"), SearchHit(path: "/gone")], on: fs)
        #expect(filled[0].size == 1 && filled[0].modified != nil && filled[1].size == nil)
    }
}

@Suite(.serialized, .enabled(if: IT.enabled)) struct RemoteSearchIntegrationTests {
    static let names = [
        "plain.txt", "with space.txt", "it's quoted.txt", "dollar $HOME.txt", "back`tick`.txt", "semi;colon.txt",
        "-leading-dash.txt", "new\nline.txt", "ünïcödé ✓.txt", "glob[1].txt", "tab\there.txt",
    ]

    func seed(_ fs: SFTPFileSystem) async throws -> String {
        let dir = try await IT.scratch(fs, "search")
        let nested = RemotePath.join(dir, "nested dir/it's deep")
        try await fs.mkdir(RemotePath.join(dir, "nested dir"))
        try await fs.mkdir(nested)
        for name in Self.names {
            try await IT.upload(fs, "needle-\(name.count)\n", to: RemotePath.join(nested, name))
        }
        try await IT.upload(fs, "nothing here", to: RemotePath.join(dir, "other.md"))
        try await IT.upload(fs, "UPPER NEEDLE", to: RemotePath.join(dir, "caps.txt"))
        _ = try await fs.exec("head -c 2000 /dev/urandom > \(ShellQuote.quote(RemotePath.join(dir, "binary.dat"))); printf 'needle\\0' >> \(ShellQuote.quote(RemotePath.join(dir, "binary.dat")))")
        return dir
    }

    @Test func nameSearchWithNastyFileNames() async throws {
        let fs = try await IT.sftp()
        let dir = try await seed(fs)
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "*.txt", root: dir), on: fs))
        let nested = RemotePath.join(dir, "nested dir/it's deep")
        let expected = Set(Self.names.map { RemotePath.join(nested, $0) } + [RemotePath.join(dir, "caps.txt")])
        #expect(Set(result.hits.map(\.path)) == expected)
        #expect(result.summary?.usedShell == true && result.summary?.error == nil)
        let plain = try #require(result.hits.first { $0.name == "plain.txt" })
        #expect(plain.size == 9 && plain.isDirectory == false && plain.modified != nil)

        let one = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "it's", root: dir), on: fs))
        #expect(Set(one.hits.map(\.name)) == ["it's deep", "it's quoted.txt"])
        let folders = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "nested dir", root: dir), on: fs))
        #expect(folders.hits.map(\.isDirectory) == [true])

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func contentSearchIsLiteralAndSkipsBinaries() async throws {
        let fs = try await IT.sftp()
        let dir = try await seed(fs)
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "needle-", root: dir), on: fs))
        #expect(result.hits.count == Self.names.count)
        #expect(!result.hits.contains { $0.name == "binary.dat" })
        // Case insensitive by default, and the pattern is not a regex.
        let caps = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "upper needle", root: dir), on: fs))
        #expect(caps.hits.map(\.name) == ["caps.txt"])
        let sensitive = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "upper needle", root: dir, caseSensitive: true), on: fs))
        #expect(sensitive.hits.isEmpty)
        let regexChars = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "nee.le", root: dir), on: fs))
        #expect(regexChars.hits.isEmpty && regexChars.summary?.error == nil)
        let filtered = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "needle", root: dir, nameFilter: "caps.*"), on: fs))
        #expect(filtered.hits.map(\.name) == ["caps.txt"])
        let dashed = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "-leading", root: dir), on: fs))
        #expect(dashed.hits.isEmpty && dashed.summary?.error == nil)

        let detailed = await RemoteSearch.details(for: Array(result.hits.prefix(2)), on: fs)
        #expect(detailed.allSatisfy { $0.size != nil && $0.modified != nil })

        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func hitLimitTruncates() async throws {
        let fs = try await IT.sftp()
        let dir = try await seed(fs)
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "*.txt", root: dir, limit: 3), on: fs))
        #expect(result.hits.count == 3 && result.summary?.truncated == true)
        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }

    @Test func cancellingKillsTheRemoteProcess() async throws {
        let fs = try await IT.sftp()
        let marker = "no-such-text-\(UUID().uuidString)"
        // Counts running greps of our search (their command line starts with `grep -rIlF `).
        let probeCommand = "m=\(marker); for f in /proc/[0-9]*/cmdline; do c=$(tr '\\0' ' ' <$f 2>/dev/null); case \"$c\" in \"grep -rIlF \"*\"-e $m \"*) echo found;; esac; done"
        func running() async throws -> Int {
            try await fs.exec(probeCommand).stdoutString.split(separator: "\n").count
        }
        let task = Task { await collect(RemoteSearch.search(SearchQuery(mode: .content, text: marker, root: "/"), on: fs)) }
        var started = false
        for _ in 0..<50 {
            if try await running() >= 1 { started = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        task.cancel()
        let result = await task.value
        #expect(started, "search ended with \(String(describing: result.summary))")
        var gone = false
        for _ in 0..<50 {
            if try await running() == 0 { gone = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(gone)
        await fs.disconnect()
    }

    @Test func ftpWalksListings() async throws {
        let fs = try await IT.ftp()
        let dir = try await IT.scratch(fs, "ftpsearch")
        try await fs.mkdir(RemotePath.join(dir, "sub"))
        try await IT.upload(fs, "x", to: RemotePath.join(dir, "sub/Report final.TXT"))
        try await IT.upload(fs, "x", to: RemotePath.join(dir, "other.md"))
        let result = await collect(RemoteSearch.search(SearchQuery(mode: .name, text: "*final*", root: dir), on: fs))
        #expect(result.hits.map(\.name) == ["Report final.TXT"])
        #expect(result.summary?.usedShell == false && result.progress.count == 2)
        let content = await collect(RemoteSearch.search(SearchQuery(mode: .content, text: "x", root: dir), on: fs))
        #expect(content.summary?.error != nil)
        try await fs.delete(dir, recursive: true)
        await fs.disconnect()
    }
}
