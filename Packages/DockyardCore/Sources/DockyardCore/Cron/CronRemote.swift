import ConnectionKit
import Foundation

/// The server's wall clock, so "next run" times are in the zone cron actually uses.
public struct CronServerClock: Equatable, Sendable {
    public var date: Date
    public var timeZone: TimeZone
    /// Abbreviation the server reported, such as "CEST" or "UTC".
    public var abbreviation: String

    /// Parses the output of `date '+%Y-%m-%d %H:%M:%S %z %Z'`, e.g. `2026-11-10 14:03:22 +0100 CET`.
    public static func parse(_ output: String) -> CronServerClock? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 3).map(String.init)
        guard parts.count >= 3 else { return nil }
        let zone = parts[2]
        guard zone.count == 5, let sign = zone.first, sign == "+" || sign == "-",
              let hh = Int(zone.dropFirst().prefix(2)), let mm = Int(zone.suffix(2)),
              let tz = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60)) else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let clock = parts[1].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, clock.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        guard let date = calendar.date(from: DateComponents(
            year: day[0], month: day[1], day: day[2], hour: clock[0], minute: clock[1], second: clock[2])) else { return nil }
        let name = parts.count > 3 ? parts[3] : zone
        return CronServerClock(date: date, timeZone: tz, abbreviation: name)
    }
}

public enum CronRemoteError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The crontab on the server differs from the text this editor loaded. Carries the server's current text.
    case changedOnServer(current: String)
    /// `crontab` refused the text; carries its message (it validates syntax).
    case rejected(String)
    case failed(String)

    public var description: String {
        switch self {
        case .changedOnServer: "The crontab changed on the server since you opened it."
        case .rejected(let m): m
        case .failed(let m): m
        }
    }
}

/// Reads and writes a user's crontab through `crontab -l` / `crontab -` over an SSH command runner.
public struct CronRemote: Sendable {
    public let runner: any RemoteCommandRunner
    /// Run as root through the connection's `su`/`sudo` setting, to edit root's crontab.
    public let elevated: Bool
    private let log: @Sendable (LogLine.Kind, String) -> Void

    public init(runner: any RemoteCommandRunner, elevated: Bool = false, log: @escaping @Sendable (LogLine.Kind, String) -> Void = { _, _ in }) {
        self.runner = runner
        self.elevated = elevated
        self.log = log
    }

    private struct Output { var stdout: String; var stderr: String; var status: Int32 }

    private func run(_ command: String, stdin: Data? = nil) async throws -> Output {
        var out = Data(), err = Data(), status: Int32?
        for try await event in try await runner.execStream(command, elevated: elevated, stdin: stdin) {
            switch event {
            case .stdout(let d): out += d
            case .stderr(let d): err += d
            case .exit(let s): status = s
            }
        }
        guard let status else { throw CronRemoteError.failed("The command ended without an exit status.") }
        return Output(stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), status: status)
    }

    private static func message(_ output: Output, fallback: String) -> String {
        let text = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(fallback) (exit \(output.status))" : text
    }

    /// The crontab text; empty when the user has none yet.
    public func load() async throws -> String {
        let text = try await read()
        log(.status, "Loaded crontab (\(Crontab(parsing: text).jobs.count) jobs)")
        return text
    }

    private func read() async throws -> String {
        let output = try await run("crontab -l")
        if output.status == 0 { return output.stdout }
        // Exit 1 with "no crontab for <user>" just means nothing is installed yet.
        if output.status == 1, output.stderr.lowercased().contains("no crontab for") { return "" }
        throw CronRemoteError.failed(Self.message(output, fallback: "crontab -l failed"))
    }

    /// The server's time and zone, or nil when `date` is unavailable or says something unexpected.
    public func serverClock() async -> CronServerClock? {
        guard let output = try? await run("date '+%Y-%m-%d %H:%M:%S %z %Z'"), output.status == 0 else { return nil }
        return CronServerClock.parse(output.stdout)
    }

    /// Installs `text`. With `expecting` set, the crontab is re-read first and `.changedOnServer` is thrown
    /// if it no longer matches (someone else edited it). Pass nil to overwrite regardless.
    public func save(_ text: String, expecting: String?) async throws {
        if let expecting {
            let current = try await read()
            if current != expecting { throw CronRemoteError.changedOnServer(current: current) }
        }
        let body = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        let output = try await run("crontab -", stdin: Data(body.utf8))
        guard output.status == 0 else {
            let message = Self.message(output, fallback: "crontab rejected the file")
            // crontab's message can quote the offending line, so it is shown to the user but not logged.
            log(.error, "Saving crontab failed (crontab exit \(output.status))")
            throw CronRemoteError.rejected(message)
        }
        // Counts only: a crontab can hold secrets.
        log(.status, "Saved crontab (\(Crontab(parsing: body).jobs.count) jobs)")
    }
}
