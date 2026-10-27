import Foundation
import ConnectionKit

/// Where archive tools run: on the server over an exec channel, or on this Mac.
protocol ArchiveHost: Sendable {
    /// The file system the archive and its destination live on.
    var fs: any RemoteFileSystem { get }
    /// "on the server" / "on this Mac", for error messages.
    var place: String { get }
    func availableTools(_ names: [String]) async throws -> Set<String>
    /// Runs the command, passing stdout and stderr chunks on. Cancelling the task stops the process.
    func run(_ command: ArchiveCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32
    /// Deletes a folder tree, ignoring errors.
    func removeTree(_ path: String) async
}

/// Splits output chunks into lines.
struct LineSplitter {
    private var pending = ""

    mutating func feed(_ data: Data) -> [String] {
        pending += String(decoding: data, as: UTF8.self)
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }.filter { !$0.isEmpty }
    }

    mutating func finish() -> [String] {
        defer { pending = "" }
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? [] : [rest]
    }
}

struct RemoteArchiveHost: ArchiveHost {
    let fs: any RemoteFileSystem
    let runner: any CommandRunning
    let elevated: Bool
    var place: String { "on the server" }

    func availableTools(_ names: [String]) async throws -> Set<String> {
        let probe = "for t in \(names.joined(separator: " ")); do command -v \"$t\" >/dev/null 2>&1 && echo \"$t\"; done; true"
        let collected = LockedBox(Data())
        _ = try await runner.runCommand(probe, elevated: false) { stream, data in
            if stream == .stdout { collected.withLock { $0.append(data) } }
        }
        let text = String(decoding: collected.withLock { $0 }, as: UTF8.self)
        return Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    func run(_ command: ArchiveCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        try await runner.runCommand(command.shellLine, elevated: elevated) { _, data in onOutput(data) }
    }

    func removeTree(_ path: String) async {
        let command = "rm -rf -- \(ShellQuote.quote(path))"
        _ = try? await runner.runCommand(command, elevated: elevated) { _, _ in }
    }
}

struct LocalArchiveHost: ArchiveHost {
    let fs: any RemoteFileSystem = LocalFileSystem()
    var place: String { "on this Mac" }

    private static let searchPath = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/sbin"]

    static func find(_ tool: String) -> URL? {
        let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchPath + fromEnvironment {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func availableTools(_ names: [String]) async throws -> Set<String> {
        Set(names.filter { Self.find($0) != nil })
    }

    func run(_ command: ArchiveCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        guard let program = command.argv.first, let executable = Self.find(program) else {
            throw ArchiveError.missingTool(command.argv.first ?? "?", where: place)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(command.argv.dropFirst())
        if let directory = command.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onOutput(data) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { onOutput(rest) }
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    func removeTree(_ path: String) async {
        try? FileManager.default.removeItem(atPath: path)
    }
}
