import Foundation

/// One external program run. Arguments are passed as an argv array, never through a shell.
public struct CommandInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Added to the inherited environment.
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(executable: String, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 30) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct CommandResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: String

    public init(exitCode: Int32, stdout: Data = Data(), stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Output is withheld: results of `op read` and `op item get` carry secrets.
    public var description: String { "CommandResult(exit \(exitCode), \(stdout.count) bytes of output)" }
    public var debugDescription: String { description }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
    case timedOut
}

/// The seam between `OnePasswordCLI` and the operating system. Tests inject a fake.
public protocol CommandExecuting: Sendable {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult
}

/// Runs the program with `Process`, with stdin closed. The process is terminated at the timeout or when the task is cancelled.
public struct ProcessCommandExecutor: CommandExecuting {
    public init() {}

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        let handle = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Plain threads: blocked readers must not starve libdispatch's small worker pool.
                Thread.detachNewThread {
                    continuation.resume(with: Result { try Self.runBlocking(invocation, handle: handle) })
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    private static func runBlocking(_ invocation: CommandInvocation, handle: RunningProcess) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, new in new }
        }
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // The child inherits this thread's signal mask; a mask that blocks SIGTERM would make `terminate()` a no-op.
        var none = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, nil)
        do { try process.run() } catch { throw CommandError.launchFailed(error.localizedDescription) }
        handle.set(process)

        let outData = LockedBox(Data()), errData = LockedBox(Data())
        let readersDone = DispatchSemaphore(value: 0)
        for (pipe, box) in [(stdout, outData), (stderr, errData)] {
            Thread.detachNewThread {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                box.withLock { $0 = data }
                readersDone.signal()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + invocation.timeout) == .timedOut {
            timedOut = true
            handle.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readersDone.wait()
        readersDone.wait()

        if timedOut { throw CommandError.timedOut }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: outData.withLock { $0 },
            stderr: String(decoding: errData.withLock { $0 }, as: UTF8.self))
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        if cancelled, process.isRunning { process.terminate() }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
