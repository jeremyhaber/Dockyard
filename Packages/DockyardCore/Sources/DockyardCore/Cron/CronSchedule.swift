import Foundation

/// Why a schedule expression was rejected, worded for the person typing it.
public struct CronScheduleError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// One of the five time fields, expanded to the values it matches.
public struct CronField: Equatable, Sendable {
    public enum Kind: Sendable, CaseIterable {
        case minute, hour, dayOfMonth, month, dayOfWeek

        var title: String {
            switch self {
            case .minute: "minute"
            case .hour: "hour"
            case .dayOfMonth: "day of month"
            case .month: "month"
            case .dayOfWeek: "day of week"
            }
        }

        /// Accepted range. Day of week takes 0-7 because both 0 and 7 mean Sunday.
        var range: ClosedRange<Int> {
            switch self {
            case .minute: 0...59
            case .hour: 0...23
            case .dayOfMonth: 1...31
            case .month: 1...12
            case .dayOfWeek: 0...7
            }
        }

        var names: [String] {
            switch self {
            case .month: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            case .dayOfWeek: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            default: []
            }
        }

        var nameOffset: Int { self == .month ? 1 : 0 }
    }

    public var raw: String
    public var values: Set<Int>
    /// True when the field starts with `*`. Cron's day-of-month / day-of-week OR rule looks at this, not at the values.
    public var isStar: Bool

    /// Parses `*`, `*/n`, `a`, `a-b`, `a-b/n` and comma lists of those, with month and weekday names.
    public static func parse(_ text: String, kind: Kind) throws -> CronField {
        let title = kind.title
        guard !text.isEmpty else { throw CronScheduleError(message: "The \(title) field is empty.") }
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { throw CronScheduleError(message: "The \(title) field has an empty item in its list.") }
            var rangeText = part
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                rangeText = part[..<slash]
                let stepText = part[part.index(after: slash)...]
                guard let n = Int(stepText), n >= 1 else {
                    throw CronScheduleError(message: "\"\(stepText)\" is not a valid step in the \(title) field; use a whole number of 1 or more.")
                }
                step = n
            }
            let low: Int, high: Int
            if rangeText == "*" {
                (low, high) = (kind.range.lowerBound, kind == .dayOfWeek ? 6 : kind.range.upperBound)
            } else if let dash = rangeText.firstIndex(of: "-") {
                low = try number(rangeText[..<dash], kind: kind)
                high = try number(rangeText[rangeText.index(after: dash)...], kind: kind)
                guard low <= high else {
                    throw CronScheduleError(message: "\"\(rangeText)\" in the \(title) field runs backwards; write the smaller value first.")
                }
            } else {
                low = try number(rangeText, kind: kind)
                // `5/10` is not valid in classic cron; a step needs `*` or a range.
                if part.contains("/") {
                    throw CronScheduleError(message: "A step in the \(title) field needs * or a range in front of it, like */\(step) or 0-30/\(step).")
                }
                high = low
            }
            var v = low
            while v <= high { values.insert(v); v += step }
        }
        if kind == .dayOfWeek, values.contains(7) { values.remove(7); values.insert(0) }
        return CronField(raw: text, values: values, isStar: text.hasPrefix("*"))
    }

    private static func number(_ text: Substring, kind: Kind) throws -> Int {
        let title = kind.title
        if let n = Int(text) {
            guard kind.range.contains(n) else {
                throw CronScheduleError(message: "\(n) is outside the \(title) range \(kind.range.lowerBound)-\(kind.range.upperBound).")
            }
            return n
        }
        if let index = kind.names.firstIndex(of: text.lowercased()) { return index + kind.nameOffset }
        if text.isEmpty { throw CronScheduleError(message: "The \(title) field has a missing value.") }
        throw CronScheduleError(message: "\"\(text)\" is not a valid \(title)." + (kind.names.isEmpty ? "" : " Use a number or a name like \(kind.names[1])."))
    }
}

/// A cron timing expression: five fields or an `@` shortcut.
public struct CronSchedule: Equatable, Sendable {
    /// The expression as written, normalised to single spaces between fields.
    public let expression: String
    /// `@reboot`, `@daily` and so on, lower-cased; nil for a five-field expression.
    public let shortcut: String?
    public let minute: CronField
    public let hour: CronField
    public let dayOfMonth: CronField
    public let month: CronField
    public let dayOfWeek: CronField

    public static let shortcuts: [String: String] = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
    ]
    public static let reboot = "@reboot"

    public var isReboot: Bool { shortcut == Self.reboot }

    public init(_ text: String) throws {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.count == 1, tokens[0].hasPrefix("@") {
            let name = tokens[0].lowercased()
            if name == Self.reboot {
                try self.init(expression: name, shortcut: name, fields: ["*", "*", "*", "*", "*"])
                return
            }
            guard let fields = Self.shortcuts[name] else {
                throw CronScheduleError(message: "\"\(tokens[0])\" is not a known shortcut. Use @reboot, @hourly, @daily, @weekly, @monthly or @yearly.")
            }
            try self.init(expression: name, shortcut: name, fields: fields.split(separator: " ").map(String.init))
            return
        }
        guard tokens.count == 5 else {
            throw CronScheduleError(message: tokens.count < 5
                ? "A schedule needs five fields (minute hour day-of-month month day-of-week); found \(tokens.count)."
                : "A schedule has exactly five fields; found \(tokens.count).")
        }
        try self.init(expression: tokens.joined(separator: " "), shortcut: nil, fields: tokens)
    }

    private init(expression: String, shortcut: String?, fields: [String]) throws {
        self.expression = expression
        self.shortcut = shortcut
        minute = try CronField.parse(fields[0], kind: .minute)
        hour = try CronField.parse(fields[1], kind: .hour)
        dayOfMonth = try CronField.parse(fields[2], kind: .dayOfMonth)
        month = try CronField.parse(fields[3], kind: .month)
        dayOfWeek = try CronField.parse(fields[4], kind: .dayOfWeek)
    }

    /// The error message for `text`, or nil when it is a valid schedule. Handy for inline validation.
    public static func validate(_ text: String) -> String? {
        do { _ = try CronSchedule(text) } catch { return (error as? CronScheduleError)?.message ?? "\(error)" }
        return nil
    }

    /// Joins five field strings into one expression.
    public static func expression(minute: String, hour: String, dayOfMonth: String, month: String, dayOfWeek: String) -> String {
        [minute, hour, dayOfMonth, month, dayOfWeek].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// The five raw fields, with a shortcut expanded to what it stands for (`@reboot` gives stars).
    public var rawFields: [String] {
        if let shortcut, let expanded = Self.shortcuts[shortcut] { return expanded.split(separator: " ").map(String.init) }
        return [minute.raw, hour.raw, dayOfMonth.raw, month.raw, dayOfWeek.raw]
    }
}

// MARK: - Next runs

public extension CronSchedule {
    /// Whether cron runs a job on this calendar day. Following cron, when both day fields are restricted
    /// a day matches if either one does; when one is `*` only the other counts.
    private func matchesDay(day: Int, weekday: Int, month monthNumber: Int) -> Bool {
        guard month.values.contains(monthNumber) else { return false }
        let domMatch = dayOfMonth.values.contains(day)
        let dowMatch = dayOfWeek.values.contains(weekday)
        switch (dayOfMonth.isStar, dayOfWeek.isStar) {
        case (true, true): return true
        case (true, false): return dowMatch
        case (false, true): return domMatch
        case (false, false): return domMatch || dowMatch
        }
    }

    /// The next `count` run times strictly after `date`, in `timeZone`. `@reboot` never runs on a clock, so it gives none.
    /// The search covers eight years, so something like Feb 30 yields an empty list instead of looping.
    func nextRuns(after date: Date, count: Int, in timeZone: TimeZone) -> [Date] {
        guard !isReboot, count > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hours = hour.values.sorted(), minutes = minute.values.sorted()
        guard !hours.isEmpty, !minutes.isEmpty else { return [] }
        var results: [Date] = []
        var day = calendar.startOfDay(for: date)
        for _ in 0..<(366 * 8) {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            // Calendar weekday is 1 = Sunday; cron is 0 = Sunday.
            if matchesDay(day: parts.day ?? 0, weekday: (parts.weekday ?? 1) - 1, month: parts.month ?? 0) {
                for h in hours {
                    for m in minutes {
                        var c = DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: h, minute: m, second: 0)
                        c.timeZone = timeZone
                        guard let candidate = calendar.date(from: c), candidate > date else { continue }
                        // Skip wall-clock times a DST jump moved to another hour.
                        guard calendar.component(.hour, from: candidate) == h else { continue }
                        results.append(candidate)
                        if results.count == count { return results }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return results
    }
}

// MARK: - Description

public extension CronSchedule {
    /// A plain-English summary ("Every 5 minutes", "Daily at 03:30"), or the raw expression when it is not simple.
    var summary: String { describe() ?? expression }

    /// True when `summary` fell back to the expression.
    var isDescribedRaw: Bool { describe() == nil }

    private static let dayNames = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    private static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private static func clock(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }

    /// `*/n` over the whole range, as n; nil for anything else.
    private static func wildcardStep(_ field: CronField) -> Int? {
        guard field.raw.hasPrefix("*/"), let n = Int(field.raw.dropFirst(2)) else { return nil }
        return n
    }

    private func describe() -> String? {
        if isReboot { return "At reboot" }
        let sets = [minute, hour, dayOfMonth, month, dayOfWeek]
        if sets.contains(where: { $0.values.isEmpty }) { return nil }

        // What the time of day says.
        enum Time { case everyMinute, everyNMinutes(Int), minuteOfEveryHour(Int), minuteOfEveryNthHour(Int, Int), clock([String]) }
        let time: Time
        let minuteSingle = minute.values.count == 1 && !minute.isStar ? minute.values.first : nil
        if minute.raw == "*", hour.raw == "*" {
            time = .everyMinute
        } else if let n = Self.wildcardStep(minute), hour.raw == "*" {
            time = n == 1 ? .everyMinute : .everyNMinutes(n)
        } else if let m = minuteSingle, hour.raw == "*" {
            time = .minuteOfEveryHour(m)
        } else if let m = minuteSingle, let n = Self.wildcardStep(hour) {
            time = .minuteOfEveryNthHour(m, n)
        } else if minute.values.count * hour.values.count <= 6, !minute.isStar, !hour.isStar {
            time = .clock(hour.values.sorted().flatMap { h in minute.values.sorted().map { Self.clock(h, $0) } })
        } else {
            return nil
        }

        // Which days it applies to.
        let domText: String? = dayOfMonth.isStar ? nil : "the " + Self.list(dayOfMonth.values.sorted().map(Self.ordinal))
        var dowText: String?
        if !dayOfWeek.isStar {
            let days = dayOfWeek.values
            if days == [1, 2, 3, 4, 5] { dowText = "weekdays" } else if days == [0, 6] { dowText = "weekends" } else {
                dowText = Self.list(days.sorted().map { Self.dayNames[$0] })
            }
        }
        var monthText: String?
        if !month.isStar { monthText = Self.list(month.values.sorted().map { Self.monthNames[$0 - 1] }) }
        // `*/n` over days or months has no short wording.
        if dayOfMonth.isStar, dayOfMonth.raw != "*" { return nil }
        if dayOfWeek.isStar, dayOfWeek.raw != "*" { return nil }
        if month.isStar, month.raw != "*" { return nil }

        var dayPhrase: String
        switch (domText, dowText) {
        case (nil, nil): dayPhrase = ""
        case (let d?, nil): dayPhrase = "on \(d)"
        case (nil, let w?): dayPhrase = "on \(w)"
        case (let d?, let w?): dayPhrase = "on \(d) and on \(w)"
        }
        if let monthText { dayPhrase += (dayPhrase.isEmpty ? "" : " ") + "in \(monthText)" }

        switch time {
        case .clock(let times):
            let at = "at " + Self.list(times)
            switch (domText, dowText, monthText) {
            case (nil, nil, nil): return "Daily \(at)"
            case (nil, let w?, nil): return "\(w.prefix(1).uppercased() + w.dropFirst()) \(at)"
            case (let d?, nil, nil): return "Monthly on \(d) \(at)"
            default: return "\(dayPhrase.prefix(1).uppercased() + dayPhrase.dropFirst()) \(at)"
            }
        case .everyMinute: return suffix("Every minute", dayPhrase)
        case .everyNMinutes(let n): return suffix("Every \(n) minutes", dayPhrase)
        case .minuteOfEveryHour(let m): return suffix(m == 0 ? "Every hour" : "Every hour at minute \(m)", dayPhrase)
        case .minuteOfEveryNthHour(let m, let n):
            return suffix(n == 1 ? "At minute \(m) past every hour" : "At minute \(m) past every \(Self.ordinal(n)) hour", dayPhrase)
        }
    }

    private func suffix(_ base: String, _ dayPhrase: String) -> String {
        dayPhrase.isEmpty ? base : "\(base), \(dayPhrase)"
    }
}
