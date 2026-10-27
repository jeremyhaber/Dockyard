import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

let nastyNames = [
    "plain.txt", "with space.txt", "it's.txt", "dollar $HOME.txt", "back`tick`.txt", "semi;colon&amp|pipe.txt",
    "new\nline.txt", "-leading-dash.txt", "[bracket]*star?.txt", "quote\"double.txt", "ünïcode ✓.txt",
]

/// Relative path -> contents for every file below `root`.
func tree(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    // The enumerator reports resolved paths (/private/var/... on macOS for /var/...), so resolve the root too.
    let root = root.resolvingSymlinksInPath()
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        out[relative] = try? String(contentsOf: url, encoding: .utf8)
    }
    return out
}

private func makeNastyTree(_ root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for (i, name) in nastyNames.enumerated() { try Data("content \(i)".utf8).write(to: root.appendingPathComponent(name)) }
    let folder = root.appendingPathComponent("odd folder $x 'q'")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("inner".utf8).write(to: folder.appendingPathComponent("in side.txt"))
}

@Suite struct ShellQuoteTests {
    @Test(arguments: nastyNames + ["", "'", "''", "a'b'c", "\\", "$(echo pwned)", "`echo pwned`", "; rm -rf /", "tab\there", "trailing space "])
    func quotedWordsSurviveTheShell(word: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(ShellQuote.quote(word))"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == word)
    }

    @Test func operandsStartingWithADashAreMadeRelative() {
        #expect(ShellQuote.operand("-rf") == "'./-rf'")
        #expect(ShellQuote.operand("/abs/-x") == "'/abs/-x'")
        #expect(ShellQuote.join(["tar", "-cf", "it's"]) == "'tar' '-cf' 'it'\\''s'")
    }
}

@Suite struct ArchiveCommandTests {
    @Test func formatDetection() {
        let cases: [(String, ArchiveFormat?)] = [
            ("a.zip", .zip), ("A.ZIP", .zip), ("a.tar", .tar), ("a.tar.gz", .tarGz), ("a.tgz", .tarGz),
            ("a.tar.bz2", .tarBz2), ("a.tbz2", .tarBz2), ("a.tar.xz", .tarXz), ("a.txz", .tarXz), ("a.gz", nil), ("tar", nil),
        ]
        for (name, expected) in cases { #expect(ArchiveFormat.detect(fileName: name) == expected, "\(name)") }
        #expect(ArchiveFormat.stem(of: "backup.tar.gz") == "backup")
        #expect(ArchiveFormat.stem(of: "x.tgz") == "x")
        #expect(ArchiveFormat.stem(of: "notes.txt") == "notes.txt")
    }

    @Test func remoteCommandLinesQuoteEverything() {
        let command = ArchiveCommands.compress(
            .tarGz, directory: "/home/u/my docs", names: ["it's", "-dash", "a b"], archive: "/tmp/o'o.tar.gz", available: ["tar", "gzip"])
        #expect(command.shellLine == "cd '/home/u/my docs' && 'tar' '-czf' '/tmp/o'\\''o.tar.gz' '--' 'it'\\''s' './-dash' 'a b'")
        let zip = ArchiveCommands.compress(.zip, directory: "/d", names: ["x"], archive: "/o.zip", available: ["zip"])
        #expect(zip.argv.prefix(3) == ["zip", "-r", "-y"])
        let fallback = ArchiveCommands.compress(.zip, directory: "/d", names: ["x"], archive: "/o.zip", available: ["bsdtar"])
        #expect(fallback.argv.first == "bsdtar")
        let extract = ArchiveCommands.extract(.tarXz, archive: "/a b.tar.xz", into: "/t", available: [])
        #expect(extract.argv == ["tar", "-xJf", "/a b.tar.xz", "-C", "/t"])
    }

    @Test func missingToolsAreNamed() {
        #expect(ArchiveCommands.compressTools(.tarBz2, available: []) == ["tar", "bzip2"])
        #expect(ArchiveCommands.extractTools(.zip, available: ["bsdtar"]) == ["bsdtar"])
        #expect(ArchiveCommands.extractTools(.zip, available: ["unzip", "bsdtar"]) == ["unzip"])
        #expect(ArchiveError.missingTool("zip", where: "on the server").description == "zip is not installed on the server")
    }
}

/// Reports no tools and blocks in `run`, to test errors and cancellation.
private struct StubHost: ArchiveHost {
    let fs: any RemoteFileSystem = LocalFileSystem()
    var place: String { "on the server" }
    var tools: Set<String> = []
    var block = false
    func availableTools(_ names: [String]) async throws -> Set<String> { tools }
    func run(_ command: ArchiveCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        if block { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return 0
    }
    func removeTree(_ path: String) async { try? FileManager.default.removeItem(atPath: path) }
}

@Suite struct LocalArchiveTests {
    private func roundTrip(_ format: ArchiveFormat, tools: [String]) async throws {
        // zip cannot store line breaks in names (compress refuses them), so that name is only used for tar.
        let skipped: Set<String> = format == .zip ? ["new\nline.txt"] : []
        let available = LocalArchiveHost()
        let present = try await available.availableTools(tools)
        guard Set(tools).isSubset(of: present) || (format == .zip && present.contains("bsdtar")) else { return }  // tool not installed here
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("src dir")
        try makeNastyTree(source)
        for name in skipped { try FileManager.default.removeItem(at: source.appendingPathComponent(name)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        let service = ArchiveService(conflictPolicy: .overwrite)
        let archive = work.appendingPathComponent("out put").appendingPathComponent("my archive.\(format.fileExtension)").path
        try FileManager.default.createDirectory(atPath: RemotePath.parent(of: archive), withIntermediateDirectories: true)
        let made = try await service.compressLocally(CompressRequest(directory: source.path, names: names, destination: archive, format: format))
        #expect(made.placed == [archive])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: RemotePath.parent(of: archive))
        #expect(leftovers == ["my archive.\(format.fileExtension)"])

        let target = work.appendingPathComponent("extracted")
        let result = try await service.extractLocally(ExtractRequest(archive: archive, destination: target.path))
        #expect(result.placed.count == names.count)
        #expect(tree(target) == tree(source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == names)  // no temp folder left behind
    }

    @Test func tarGzRoundTripWithNastyNames() async throws { try await roundTrip(.tarGz, tools: ["tar", "gzip"]) }
    @Test func tarRoundTripWithNastyNames() async throws { try await roundTrip(.tar, tools: ["tar"]) }
    @Test func zipRoundTripWithNastyNames() async throws { try await roundTrip(.zip, tools: ["zip", "unzip"]) }

    @Test func extractsEveryFormatItCanFindToolsFor() async throws {
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        let host = LocalArchiveHost()
        let service = ArchiveService(conflictPolicy: .overwrite)
        try Data("hello".utf8).write(to: work.appendingPathComponent("hello.txt"))
        for (flag, ext, tools) in [("-cjf", "tar.bz2", ["tar", "bzip2"]), ("-cJf", "tar.xz", ["tar", "xz"]), ("-czf", "tgz", ["tar", "gzip"])] {
            guard Set(tools).isSubset(of: try await host.availableTools(tools)) else { continue }
            let archive = work.appendingPathComponent("a.\(ext)").path
            let code = try await host.run(ArchiveCommand(argv: ["tar", flag, archive, "hello.txt"], directory: work.path)) { _ in }
            #expect(code == 0)
            let out = work.appendingPathComponent("out-\(ext)")
            _ = try await service.extractLocally(ExtractRequest(archive: archive, destination: out.path))
            #expect(tree(out) == ["hello.txt": "hello"])
        }
    }

    @Test func extractMergesFoldersAndAppliesTheConflictPolicy() async throws {
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("new a".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("new b".utf8).write(to: source.appendingPathComponent("docs/b.txt"))
        try Data("new c".utf8).write(to: source.appendingPathComponent("docs/c.txt"))
        let archive = work.appendingPathComponent("x.tar").path
        _ = try await ArchiveService(conflictPolicy: .overwrite).compressLocally(
            CompressRequest(directory: source.path, names: ["a.txt", "docs"], destination: archive, format: .tar))

        func destination() throws -> URL {
            let dest = work.appendingPathComponent("dest-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: dest.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try Data("old a".utf8).write(to: dest.appendingPathComponent("a.txt"))
            try Data("old b".utf8).write(to: dest.appendingPathComponent("docs/b.txt"))
            try Data("keep".utf8).write(to: dest.appendingPathComponent("docs/keep.txt"))
            return dest
        }

        var dest = try destination()
        var result = try await ArchiveService(conflictPolicy: .skip).extractLocally(ExtractRequest(archive: archive, destination: dest.path))
        #expect(tree(dest) == ["a.txt": "old a", "docs/b.txt": "old b", "docs/c.txt": "new c", "docs/keep.txt": "keep"])
        #expect(result.skipped == 2)

        dest = try destination()
        result = try await ArchiveService(conflictPolicy: .overwrite).extractLocally(ExtractRequest(archive: archive, destination: dest.path))
        #expect(tree(dest) == ["a.txt": "new a", "docs/b.txt": "new b", "docs/c.txt": "new c", "docs/keep.txt": "keep"])

        dest = try destination()
        _ = try await ArchiveService(conflictPolicy: .rename).extractLocally(ExtractRequest(archive: archive, destination: dest.path))
        #expect(tree(dest)["a.txt"] == "old a" && tree(dest)["a (1).txt"] == "new a")
        #expect(tree(dest)["docs/b (1).txt"] == "new b")

        dest = try destination()
        let asked = Arrivals()
        let service = ArchiveService(conflictPolicy: .ask) { _ in await asked.hit(); return ConflictDecision(.overwrite) }
        _ = try await service.extractLocally(ExtractRequest(archive: archive, destination: dest.path))
        #expect(await asked.count == 2)
        #expect(tree(dest)["a.txt"] == "new a")

        // Without anyone to ask, nothing is overwritten.
        dest = try destination()
        _ = try await ArchiveService(conflictPolicy: .ask).extractLocally(ExtractRequest(archive: archive, destination: dest.path))
        #expect(tree(dest)["a.txt"] == "old a")
    }

    @Test func compressAvoidsOverwritingAnExistingArchive() async throws {
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("x".utf8).write(to: work.appendingPathComponent("f.txt"))
        let archive = work.appendingPathComponent("f.tar").path
        let request = CompressRequest(directory: work.path, names: ["f.txt"], destination: archive, format: .tar)
        _ = try await ArchiveService(conflictPolicy: .overwrite).compressLocally(request)
        let skipped = try await ArchiveService(conflictPolicy: .skip).compressLocally(request)
        #expect(skipped.skipped == 1 && skipped.placed.isEmpty)
        let renamed = try await ArchiveService(conflictPolicy: .rename).compressLocally(request)
        #expect(renamed.placed == [work.appendingPathComponent("f (1).tar").path])
    }

    @Test func missingToolsProduceAClearError() async throws {
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        let service = ArchiveService(conflictPolicy: .overwrite)
        do {
            _ = try await service.compress(
                CompressRequest(directory: work.path, names: ["x"], destination: work.appendingPathComponent("x.zip").path, format: .zip),
                host: StubHost())
            Issue.record("expected an error")
        } catch let error as ArchiveError {
            #expect(error == .missingTool("zip", where: "on the server"))
            #expect(error.description == "zip is not installed on the server")
        }
        do {
            _ = try await service.extract(ExtractRequest(archive: "/x/a.tar.xz", destination: work.path), host: StubHost(tools: ["tar"]))
            Issue.record("expected an error")
        } catch let error as ArchiveError {
            #expect(error == .missingTool("xz", where: "on the server"))
        }
        do {
            _ = try await service.extract(ExtractRequest(archive: "/x/a.rar", destination: work.path), host: StubHost())
            Issue.record("expected an error")
        } catch let error as ArchiveError {
            if case .unsupported = error {} else { Issue.record("wrong error \(error)") }
        }
    }

    @Test func zipRefusesNamesItCannotStore() async throws {
        do {
            _ = try await ArchiveService().compress(
                CompressRequest(directory: "/d", names: ["a\nb"], destination: "/d/x.zip", format: .zip), host: StubHost(tools: ["zip"]))
            Issue.record("expected an error")
        } catch let error as ArchiveError {
            if case .unsupported = error {} else { Issue.record("wrong error \(error)") }
        }
    }

    @Test func cancellingLeavesNoTemporaryFolder() async throws {
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        let task = Task {
            try await ArchiveService(conflictPolicy: .overwrite).extract(
                ExtractRequest(archive: "/x/a.tar", destination: work.path), host: StubHost(tools: ["tar"], block: true))
        }
        #expect(await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: work.path).count) == 1 })
        task.cancel()
        _ = try? await task.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func outputIsStreamedToTheLog() async throws {
        let work = try makeTempDir("archive")
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("x".utf8).write(to: work.appendingPathComponent("f.txt"))
        let service = ArchiveService(conflictPolicy: .overwrite)
        let lines = LockedBox<[LogLine]>([])
        let stream = service.log.stream()
        let collector = Task { for await l in stream { lines.withLock { $0.append(l) } } }
        _ = try await service.compressLocally(CompressRequest(
            directory: work.path, names: ["f.txt"], destination: work.appendingPathComponent("o.tar").path, format: .tar))
        try await Task.sleep(nanoseconds: 50_000_000)
        collector.cancel()
        let log = lines.withLock { $0 }
        #expect(log.contains { $0.kind == .command && $0.message.contains("'tar'") })
        #expect(log.contains { $0.kind == .status && $0.message.hasPrefix("Created") })
    }
}

@Suite struct ArchiveRelayTests {
    @Test func compressOnAServerWithoutAShellRelaysThroughTheMac() async throws {
        let present = try await LocalArchiveHost().availableTools(["tar", "gzip"])
        guard present.isSuperset(of: ["tar", "gzip"]) else { return }
        let env = try TransferEnv()
        let server = FakeServer()
        server.files.put("/site/index.html", "<html>")
        server.files.put("/site/css/main.css", "body{}")
        server.files.makeDir("/out")
        let site = server.site(max: 2)
        let q = env.queue()
        await q.register(site: site)
        let endpoint = server.endpoint(site)
        let plan = ArchiveRelayPlan(endpoint: endpoint, operation: .compress(
            directory: "/out", items: try await server.files.list("/site"), archiveName: "site.tar.gz", format: .tarGz))
        #expect(plan.summary.contains("relayed through this Mac"))
        #expect(plan.steps.count == 3)
        let result = try await plan.run(on: q, service: ArchiveService(conflictPolicy: .overwrite), tempRoot: env.dir)
        #expect(result.placed == ["/out/site.tar.gz"])
        let stored = try #require(server.files.state.withLock { $0.files["/out/site.tar.gz"] })
        let check = env.dir.appendingPathComponent("check.tar.gz")
        try stored.data.write(to: check)
        let out = env.dir.appendingPathComponent("check")
        _ = try await ArchiveService(conflictPolicy: .overwrite).extractLocally(ExtractRequest(archive: check.path, destination: out.path))
        #expect(tree(out) == ["index.html": "<html>", "css/main.css": "body{}"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.dir.path).filter { $0.hasPrefix("dockyard-archive-") }.isEmpty)
    }

    @Test func extractOnAServerWithoutAShellRelaysThroughTheMac() async throws {
        let present = try await LocalArchiveHost().availableTools(["tar", "gzip"])
        guard present.isSuperset(of: ["tar", "gzip"]) else { return }
        let env = try TransferEnv()
        let build = env.dir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: build.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: build.appendingPathComponent("sub/two.txt"))
        let archive = env.dir.appendingPathComponent("pack.tar.gz")
        _ = try await ArchiveService(conflictPolicy: .overwrite).compressLocally(
            CompressRequest(directory: build.path, names: ["one.txt", "sub"], destination: archive.path, format: .tarGz))

        let server = FakeServer()
        server.files.put("/in/pack.tar.gz", data: try Data(contentsOf: archive))
        server.files.makeDir("/dest")
        let site = server.site(max: 2)
        let q = env.queue()
        await q.register(site: site)
        let item = try #require(try await server.files.list("/in").first)
        let plan = ArchiveRelayPlan(endpoint: server.endpoint(site), operation: .extract(archive: item, destination: "/dest"))
        _ = try await plan.run(on: q, service: ArchiveService(conflictPolicy: .overwrite), tempRoot: env.dir)
        #expect(server.files.text("/dest/one.txt") == "one")
        #expect(server.files.text("/dest/sub/two.txt") == "two")
    }
}
