import Foundation
import ConnectionKit

public struct SearchQuery: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// `text` is a glob matched against file names. Without wildcards it matches names containing the text.
        case name
        /// `text` is searched for literally inside text files. `nameFilter` optionally limits which files.
        case content
    }

    public var mode: Mode
    public var text: String
    public var root: String
    public var caseSensitive: Bool
    /// Content search only: a glob such as `*.php`.
    public var nameFilter: String?
    public var limit: Int

    public static let defaultLimit = 5_000

    public init(mode: Mode, text: String, root: String, caseSensitive: Bool = false, nameFilter: String? = nil, limit: Int = SearchQuery.defaultLimit) {
        self.mode = mode
        self.text = text
        self.root = root
        self.caseSensitive = caseSensitive
        self.nameFilter = nameFilter
        self.limit = limit
    }

    /// The glob actually used for name search.
    var namePattern: String { Glob.hasWildcards(text) ? text : "*\(text)*" }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var path: String
    public var isDirectory: Bool?
    public var size: UInt64?
    public var modified: Date?
    public var id: String { path }
    public var name: String { RemotePath.lastComponent(of: path) }

    public init(path: String, isDirectory: Bool? = nil, size: UInt64? = nil, modified: Date? = nil) {
        self.path = path; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}

public struct SearchProgress: Sendable, Equatable {
    public var foldersScanned: Int
    public var currentFolder: String

    public init(foldersScanned: Int, currentFolder: String) {
        self.foldersScanned = foldersScanned
        self.currentFolder = currentFolder
    }
}

public struct SearchSummary: Sendable, Equatable {
    public var hits: Int
    /// Stopped at the hit limit.
    public var truncated: Bool
    public var cancelled: Bool
    /// True when `find`/`grep` ran on the server; false when the listings were walked.
    public var usedShell: Bool
    public var error: String?

    public init(hits: Int, truncated: Bool = false, cancelled: Bool = false, usedShell: Bool, error: String? = nil) {
        self.hits = hits; self.truncated = truncated; self.cancelled = cancelled; self.usedShell = usedShell; self.error = error
    }
}

public enum SearchEvent: Sendable, Equatable {
    case hit(SearchHit)
    /// Only sent by the listing walk, which is what FTP and cloud connections use.
    case progress(SearchProgress)
    case finished(SearchSummary)
}

/// ⌘F search in the server pane. SFTP runs `find` / `grep -rIl` on the server; other backends walk listings
/// (name search only). The stream always ends with `.finished`. Cancel by cancelling the consuming task or
/// dropping the stream; the remote process is killed.
public enum RemoteSearch {
    public static func search(_ query: SearchQuery, on fs: any RemoteFileSystem) -> AsyncStream<SearchEvent> {
        let (stream, continuation) = AsyncStream<SearchEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            let summary: SearchSummary
            if let runner = fs as? any RemoteCommandRunner {
                summary = await ShellSearch(query: query, runner: runner, emit: { continuation.yield($0) }).run(fallback: fs)
            } else {
                summary = await WalkSearch(query: query, fs: fs, emit: { continuation.yield($0) }).run()
            }
            continuation.yield(.finished(summary))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Fills in size and modification time for hits that come without them (content search).
    public static func details(for hits: [SearchHit], on fs: any RemoteFileSystem) async -> [SearchHit] {
        var out: [SearchHit] = []
        for hit in hits {
            guard hit.size == nil, let item = try? await fs.stat(hit.path) else { out.append(hit); continue }
            out.append(SearchHit(path: hit.path, isDirectory: item.isDirectory, size: item.size, modified: item.modified))
        }
        return out
    }
}

// MARK: - Listing walk

private struct WalkSearch {
    let query: SearchQuery
    let fs: any RemoteFileSystem
    let emit: @Sendable (SearchEvent) -> Void

    func run() async -> SearchSummary {
        guard query.mode == .name else {
            return SearchSummary(hits: 0, truncated: false, cancelled: false, usedShell: false,
                                 error: "Searching file contents needs an SSH connection")
        }
        let pattern = query.namePattern
        var queue = [query.root]
        var scanned = 0, hits = 0
        var firstError: String?
        while !queue.isEmpty {
            if Task.isCancelled { return SearchSummary(hits: hits, truncated: false, cancelled: true, usedShell: false, error: nil) }
            let folder = queue.removeFirst()
            let items: [RemoteItem]
            do { items = try await fs.list(folder) } catch {
                if firstError == nil { firstError = "Cannot list \(folder): \(error)" }
                continue
            }
            scanned += 1
            emit(.progress(SearchProgress(foldersScanned: scanned, currentFolder: folder)))
            for item in items where item.name != "." && item.name != ".." {
                if Glob.matches(pattern, item.name, caseInsensitive: !query.caseSensitive) {
                    hits += 1
                    emit(.hit(SearchHit(path: item.path, isDirectory: item.isDirectory, size: item.size, modified: item.modified)))
                    if hits >= query.limit { return SearchSummary(hits: hits, truncated: true, cancelled: false, usedShell: false, error: nil) }
                }
                if item.isDirectory && !item.isSymlink { queue.append(item.path) }
            }
        }
        return SearchSummary(hits: hits, truncated: false, cancelled: false, usedShell: false, error: firstError)
    }
}

// MARK: - Remote find / grep

private struct ShellSearch {
    let query: SearchQuery
    let runner: any RemoteCommandRunner
    let emit: @Sendable (SearchEvent) -> Void

    private struct Attempt {
        var hits = 0
        var truncated = false
        var cancelled = false
        var exitStatus: Int32?
        var stderr = ""
        var failedToStart: String?
        /// The wrapper printed its pid, so the server did run our command.
        var sawPid = false
    }

    func run(fallback fs: any RemoteFileSystem) async -> SearchSummary {
        var attempt: Attempt
        switch query.mode {
        case .name:
            attempt = await execute(arguments: findArguments(printFormat: true), format: .findPrintf)
            if attempt.hits == 0, !attempt.cancelled, Self.looksUnsupported(attempt) {
                attempt = await execute(arguments: findArguments(printFormat: false), format: .nulSeparated)
            }
        case .content:
            attempt = await execute(arguments: grepArguments(), format: .nulSeparated)
        }

        // Accounts limited to SFTP refuse commands; the output then never contains our pid line.
        let shellUnusable = attempt.failedToStart != nil || (!attempt.sawPid && !attempt.cancelled)
        if shellUnusable, query.mode == .name {
            return await WalkSearch(query: query, fs: fs, emit: emit).run()
        }
        let stderr = attempt.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var error: String?
        if shellUnusable {
            error = attempt.failedToStart ?? (stderr.isEmpty ? "The server did not run the search command" : stderr)
        } else if attempt.hits == 0, ![0, 1].contains(attempt.exitStatus ?? 0), !stderr.isEmpty {
            error = stderr
        }
        return SearchSummary(hits: attempt.hits, truncated: attempt.truncated, cancelled: attempt.cancelled, usedShell: true, error: error)
    }

    private static func looksUnsupported(_ a: Attempt) -> Bool {
        let text = a.stderr.lowercased()
        return ["unknown predicate", "illegal option", "unknown option", "-printf"].contains { text.contains($0) }
    }

    // MARK: Commands

    /// `sh -c 'echo $$; exec "$@"'` prints a pid line first, which tells us the server really ran the shell.
    /// Stopping early needs no kill: dropping the stream kills the remote process group.
    private func wrap(_ arguments: [String]) -> String {
        "sh -c 'echo $$; exec \"$@\"' sh " + ShellQuote.join(arguments)
    }

    private var root: String { query.root.hasPrefix("-") ? "./" + query.root : query.root }

    private func findArguments(printFormat: Bool) -> [String] {
        var args = ["find", root, query.caseSensitive ? "-name" : "-iname", query.namePattern]
        args += printFormat ? ["-printf", "%y\\0%s\\0%T@\\0%p\\0"] : ["-print0"]
        return args
    }

    private func grepArguments() -> [String] {
        var args = ["grep", "-rIlF", "--null"]
        if !query.caseSensitive { args.append("-i") }
        if let filter = query.nameFilter, !filter.isEmpty { args.append("--include=\(filter)") }
        args += ["-e", query.text, "--", root]
        return args
    }

    // MARK: Streaming

    private enum Format { case findPrintf, nulSeparated }

    private func execute(arguments: [String], format: Format) async -> Attempt {
        var attempt = Attempt()
        let events: AsyncThrowingStream<SSHExecEvent, Error>
        do { events = try await runner.execStream(wrap(arguments)) } catch {
            attempt.failedToStart = "\(error)"
            return attempt
        }

        var pid: Int?
        var buffer = Data()
        var fields: [String] = []
        let perHit = format == .findPrintf ? 4 : 1

        do {
            read: for try await event in events {
                switch event {
                case .stderr(let data):
                    attempt.stderr += String(decoding: data, as: UTF8.self)
                case .exit(let status):
                    attempt.exitStatus = status
                case .stdout(let data):
                    buffer.append(data)
                    if pid == nil {
                        guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
                        pid = Int(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces))
                        attempt.sawPid = pid != nil
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                    while let nul = buffer.firstIndex(of: 0) {
                        fields.append(String(decoding: buffer[buffer.startIndex..<nul], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...nul)
                        guard fields.count == perHit else { continue }
                        defer { fields.removeAll(keepingCapacity: true) }
                        guard let hit = makeHit(fields, format: format) else { continue }
                        attempt.hits += 1
                        emit(.hit(hit))
                        if attempt.hits >= query.limit {
                            attempt.truncated = true
                            break read
                        }
                    }
                }
                if Task.isCancelled { break read }
            }
        } catch {
            attempt.failedToStart = "\(error)"
        }

        if attempt.truncated || Task.isCancelled {
            attempt.cancelled = Task.isCancelled && !attempt.truncated
        }
        return attempt
    }

    private func makeHit(_ fields: [String], format: Format) -> SearchHit? {
        switch format {
        case .nulSeparated:
            guard let path = fields.first, path != query.root else { return nil }
            return SearchHit(path: path)
        case .findPrintf:
            let path = fields[3]
            guard path != query.root else { return nil }
            return SearchHit(
                path: path, isDirectory: fields[0] == "d", size: UInt64(fields[1]),
                modified: Double(fields[2]).map { Date(timeIntervalSince1970: $0) })
        }
    }
}
