import Foundation

/// The friendly schedule choices of the job editor. `custom` holds any expression the others cannot say.
public enum CronPreset: Equatable, Sendable {
    case everyMinute
    case everyNMinutes(Int)
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    /// `days` are 0 (Sunday) to 6 (Saturday).
    case weekly(days: Set<Int>, hour: Int, minute: Int)
    case monthly(day: Int, hour: Int, minute: Int)
    case reboot
    case custom(String)

    /// Picker categories, without their values.
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case everyMinute, everyNMinutes, hourly, daily, weekly, monthly, reboot, custom
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .everyMinute: "Every minute"
            case .everyNMinutes: "Every N minutes"
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .reboot: "At reboot"
            case .custom: "Custom"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .everyMinute: .everyMinute
        case .everyNMinutes: .everyNMinutes
        case .hourly: .hourly
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .reboot: .reboot
        case .custom: .custom
        }
    }

    /// The cron expression this preset stands for.
    public var expression: String {
        switch self {
        case .everyMinute: "* * * * *"
        case .everyNMinutes(let n): "*/\(max(2, min(59, n))) * * * *"
        case .hourly(let m): "\(Self.minute(m)) * * * *"
        case .daily(let h, let m): "\(Self.minute(m)) \(Self.hour(h)) * * *"
        case .weekly(let days, let h, let m):
            "\(Self.minute(m)) \(Self.hour(h)) * * \(days.isEmpty ? "1" : days.sorted().map(String.init).joined(separator: ","))"
        case .monthly(let d, let h, let m): "\(Self.minute(m)) \(Self.hour(h)) \(max(1, min(31, d))) * *"
        case .reboot: "@reboot"
        case .custom(let text): text
        }
    }

    private static func minute(_ m: Int) -> Int { max(0, min(59, m)) }
    private static func hour(_ h: Int) -> Int { max(0, min(23, h)) }

    /// Sensible starting values when the picker switches to `kind`.
    public static func defaults(for kind: Kind, from current: CronPreset) -> CronPreset {
        let (h, m) = current.timeOfDay ?? (3, 0)
        switch kind {
        case .everyMinute: return .everyMinute
        case .everyNMinutes: return .everyNMinutes(5)
        case .hourly: return .hourly(minute: current.timeOfDay?.minute ?? 0)
        case .daily: return .daily(hour: h, minute: m)
        case .weekly: return .weekly(days: [1], hour: h, minute: m)
        case .monthly: return .monthly(day: 1, hour: h, minute: m)
        case .reboot: return .reboot
        case .custom: return .custom(current.expression)
        }
    }

    private var timeOfDay: (hour: Int, minute: Int)? {
        switch self {
        case .daily(let h, let m), .weekly(_, let h, let m), .monthly(_, let h, let m): (h, m)
        case .hourly(let m): (0, m)
        default: nil
        }
    }

    /// The preset that says exactly this schedule, or `.custom` with its expression.
    public static func matching(_ schedule: CronSchedule) -> CronPreset {
        let custom = CronPreset.custom(schedule.expression)
        switch schedule.shortcut {
        case "@reboot": return .reboot
        case "@hourly": return .hourly(minute: 0)
        case "@daily", "@midnight": return .daily(hour: 0, minute: 0)
        case "@weekly": return .weekly(days: [0], hour: 0, minute: 0)
        case "@monthly": return .monthly(day: 1, hour: 0, minute: 0)
        case .some: return custom
        case nil: break
        }
        let f = schedule.rawFields
        func int(_ s: String) -> Int? { s.allSatisfy(\.isNumber) ? Int(s) : nil }
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])
        guard month == "*" else { return custom }
        if hour == "*", dom == "*", dow == "*" {
            if minute == "*" { return .everyMinute }
            if minute.hasPrefix("*/"), let n = int(String(minute.dropFirst(2))), (2...59).contains(n) { return .everyNMinutes(n) }
            if let m = int(minute) { return .hourly(minute: m) }
            return custom
        }
        guard let m = int(minute), let h = int(hour) else { return custom }
        if dom == "*", dow == "*" { return .daily(hour: h, minute: m) }
        if dom == "*", !schedule.dayOfWeek.isStar, !schedule.dayOfWeek.values.isEmpty,
           dow.allSatisfy({ $0.isNumber || $0 == "," }) {
            return .weekly(days: schedule.dayOfWeek.values, hour: h, minute: m)
        }
        if dow == "*", let d = int(dom) { return .monthly(day: d, hour: h, minute: m) }
        return custom
    }
}
