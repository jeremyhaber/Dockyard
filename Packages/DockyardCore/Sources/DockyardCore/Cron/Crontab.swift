import Foundation

/// One scheduled command, possibly commented out (disabled), with the comment above it as its label.
public struct CronJob: Equatable, Sendable, Identifiable {
    public var id: Int
    public var label: String
    public var schedule: CronSchedule
    public var command: String
    public var enabled: Bool

    /// What the job looked like when parsed, so untouched parts are written back byte for byte.
    fileprivate struct Original: Equatable, Sendable {
        var labelLine: String?
        var label: String
        var jobLine: String
        var expression: String
        var command: String
        var enabled: Bool
    }
    fileprivate var original: Original?

    public init(id: Int = 0, label: String = "", schedule: CronSchedule, command: String, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.schedule = schedule
        self.command = command
        self.enabled = enabled
    }

    /// Why this job cannot be written, or nil. A command is one line; cron treats a newline as the end of the entry.
    public var validationError: String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the command to run." }
        if command.contains("\n") || command.contains("\r") { return "The command must be a single line." }
        return nil
    }

    var labelLines: [String] {
        let text = label.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let original, original.label == text || original.label == label { return original.labelLine.map { [$0] } ?? [] }
        return text.isEmpty ? [] : ["# \(text)"]
    }

    var jobLine: String {
        if let original, original.expression == schedule.expression, original.command == command, original.enabled == enabled {
            return original.jobLine
        }
        let line = "\(schedule.expression) \(command)"
        return enabled ? line : "# \(line)"
    }
}

/// A `NAME=value` line: MAILTO, SHELL, PATH, CRON_TZ and so on.
public struct CronEnvVar: Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var value: String
    fileprivate var original: (line: String, name: String, value: String)?

    public init(id: Int = 0, name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    public static func == (a: CronEnvVar, b: CronEnvVar) -> Bool {
        a.id == b.id && a.name == b.name && a.value == b.value && a.original?.line == b.original?.line
    }

    var line: String {
        if let original, original.name == name, original.value == value { return original.line }
        return "\(name)=\(value)"
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }
    }
}

/// A crontab as an ordered list of lines. Parsing then serialising without edits gives back the input exactly;
/// lines that are not understood are kept verbatim and reported in `issues`.
public struct Crontab: Equatable, Sendable {
    public enum Entry: Equatable, Sendable, Identifiable {
        case job(CronJob)
        case env(CronEnvVar)
        case comment(id: Int, text: String)
        case blank(id: Int, text: String)
        /// A line that is none of the above: kept as written.
        case unknown(id: Int, text: String)

        public var id: Int {
            switch self {
            case .job(let j): j.id
            case .env(let e): e.id
            case .comment(let id, _), .blank(let id, _), .unknown(let id, _): id
            }
        }
    }

    public struct Issue: Equatable, Sendable, Identifiable {
        /// 1-based line number in the parsed text.
        public var line: Int
        public var message: String
        public var id: Int { line }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var issues: [Issue] = []
    private var endsWithNewline = false
    private var nextID = 1

    public init() {}

    public init(parsing text: String) {
        guard !text.isEmpty else { return }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast(); endsWithNewline = true }

        var pendingLabel: (line: String, text: String)?
        func flushLabel(into entries: inout [Entry], ids: inout Int) {
            if let label = pendingLabel {
                entries.append(.comment(id: ids, text: label.line)); ids += 1
                pendingLabel = nil
            }
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flushLabel(into: &entries, ids: &nextID)
                entries.append(.blank(id: nextID, text: line)); nextID += 1
            } else if let job = Self.parseJob(trimmed, enabled: true) {
                var job = job
                job.id = nextID; nextID += 1
                job.original = .init(labelLine: pendingLabel?.line, label: pendingLabel?.text ?? "", jobLine: line,
                                     expression: job.schedule.expression, command: job.command, enabled: true)
                job.label = pendingLabel?.text ?? ""
                pendingLabel = nil
                entries.append(.job(job))
            } else if trimmed.hasPrefix("#") {
                let body = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                if let parsed = Self.parseJob(body, enabled: false) {
                    var job = parsed
                    job.id = nextID; nextID += 1
                    job.original = .init(labelLine: pendingLabel?.line, label: pendingLabel?.text ?? "", jobLine: line,
                                         expression: job.schedule.expression, command: job.command, enabled: false)
                    job.label = pendingLabel?.text ?? ""
                    pendingLabel = nil
                    entries.append(.job(job))
                } else {
                    flushLabel(into: &entries, ids: &nextID)
                    // A comment may label the job under it, except the stock "m h dom mon dow" header.
                    let lower = body.lowercased()
                    let isHeader = lower.contains("dom") && lower.contains("mon") && lower.contains("dow")
                    if !isHeader, !body.isEmpty, trimmed.hasPrefix("#"), !trimmed.hasPrefix("##") {
                        pendingLabel = (line, body)
                    } else {
                        entries.append(.comment(id: nextID, text: line)); nextID += 1
                    }
                }
            } else if let env = Self.parseEnv(trimmed) {
                flushLabel(into: &entries, ids: &nextID)
                var env = env
                env.id = nextID; nextID += 1
                env.original = (line, env.name, env.value)
                entries.append(.env(env))
            } else {
                flushLabel(into: &entries, ids: &nextID)
                entries.append(.unknown(id: nextID, text: line)); nextID += 1
                issues.append(Issue(line: index + 1, message: Self.explainUnknown(trimmed)))
            }
        }
        flushLabel(into: &entries, ids: &nextID)
    }

    // MARK: Parsing helpers

    private static func parseJob(_ text: String, enabled: Bool) -> CronJob? {
        guard let first = text.first, first == "@" || first == "*" || first.isNumber else { return nil }
        let (scheduleText, command) = splitSchedule(text)
        guard let scheduleText, let command, let schedule = try? CronSchedule(scheduleText) else { return nil }
        guard !command.isEmpty else { return nil }
        return CronJob(schedule: schedule, command: command, enabled: enabled)
    }

    /// Splits "m h dom mon dow command" (or "@name command") into the schedule text and the command.
    private static func splitSchedule(_ text: String) -> (String?, String?) {
        var rest = Substring(text)
        func token() -> Substring? {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard !rest.isEmpty else { return nil }
            let word = rest.prefix(while: { $0 != " " && $0 != "\t" })
            rest = rest.dropFirst(word.count)
            return word
        }
        guard let first = token() else { return (nil, nil) }
        var parts = [String(first)]
        if !first.hasPrefix("@") {
            for _ in 0..<4 { guard let t = token() else { return (nil, nil) }; parts.append(String(t)) }
        }
        let command = rest.drop(while: { $0 == " " || $0 == "\t" }).trimmingCharacters(in: .whitespacesAndNewlines)
        return (parts.joined(separator: " "), command)
    }

    private static func parseEnv(_ text: String) -> CronEnvVar? {
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let name = text[..<eq].trimmingCharacters(in: .whitespaces)
        guard CronEnvVar.isValidName(name) else { return nil }
        let value = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return CronEnvVar(name: name, value: value)
    }

    /// Why a line that is not a job, comment or variable was not understood.
    private static func explainUnknown(_ text: String) -> String {
        let (scheduleText, command) = splitSchedule(text)
        if let scheduleText, let command {
            do { _ = try CronSchedule(scheduleText) } catch { return (error as? CronScheduleError)?.message ?? "\(error)" }
            if command.isEmpty { return "The schedule has no command after it." }
        }
        if text.hasPrefix("@") || text.first?.isNumber == true || text.hasPrefix("*") {
            return "This looks like a schedule but has too few fields (it needs five, then a command)."
        }
        return "This line is not a schedule, a comment or a NAME=value setting."
    }

    // MARK: Reading

    public var jobs: [CronJob] { entries.compactMap { if case .job(let j) = $0 { j } else { nil } } }
    public var envVars: [CronEnvVar] { entries.compactMap { if case .env(let e) = $0 { e } else { nil } } }
    /// Lines kept as written that are not understood.
    public var unknownLineCount: Int { entries.filter { if case .unknown = $0 { true } else { false } }.count }
    /// The `CRON_TZ` setting, if any, which changes the time zone jobs run in.
    public var cronTimeZone: String? { envVars.last { $0.name == "CRON_TZ" }?.value }

    public func job(id: Int) -> CronJob? { jobs.first { $0.id == id } }

    // MARK: Editing

    private mutating func take() -> Int { defer { nextID += 1 }; return nextID }

    /// Appends the job after the last entry.
    @discardableResult
    public mutating func add(_ job: CronJob) -> CronJob {
        var job = job
        job.id = take()
        job.original = nil
        entries.append(.job(job))
        endsWithNewline = true
        return job
    }

    /// Inserts a copy of the job right after it, labelled "<label> (copy)".
    @discardableResult
    public mutating func duplicate(id: Int) -> CronJob? {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .job(var job) = entries[index] else { return nil }
        job.id = take()
        job.original = nil
        if !job.label.isEmpty { job.label += " (copy)" }
        entries.insert(.job(job), at: index + 1)
        endsWithNewline = true
        return job
    }

    public mutating func update(_ job: CronJob) {
        guard let index = entries.firstIndex(where: { $0.id == job.id }), case .job(let old) = entries[index] else { return }
        var job = job
        job.original = old.original
        entries[index] = .job(job)
        endsWithNewline = true
    }

    public mutating func setEnabled(_ enabled: Bool, id: Int) {
        guard var job = self.job(id: id) else { return }
        job.enabled = enabled
        update(job)
    }

    public mutating func remove(id: Int) {
        entries.removeAll { $0.id == id }
        endsWithNewline = true
    }

    /// Adds a variable after the last existing one, or at the top.
    @discardableResult
    public mutating func addEnv(name: String, value: String) -> CronEnvVar {
        let env = CronEnvVar(id: take(), name: name, value: value)
        let at = entries.lastIndex { if case .env = $0 { true } else { false } }.map { $0 + 1 } ?? 0
        entries.insert(.env(env), at: at)
        endsWithNewline = true
        return env
    }

    public mutating func updateEnv(id: Int, name: String, value: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .env(var env) = entries[index] else { return }
        env.name = name
        env.value = value
        entries[index] = .env(env)
        endsWithNewline = true
    }

    // MARK: Writing

    /// The crontab text. Unedited lines are byte-identical to what was parsed.
    public func serialized() -> String {
        var lines: [String] = []
        for entry in entries {
            switch entry {
            case .job(let job): lines += job.labelLines + [job.jobLine]
            case .env(let env): lines.append(env.line)
            case .comment(_, let text), .blank(_, let text), .unknown(_, let text): lines.append(text)
            }
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }
}
