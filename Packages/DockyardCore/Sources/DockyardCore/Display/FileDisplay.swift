import Foundation
import ConnectionKit

/// Text for the file list columns.
public enum FileDisplay {
    public static func size(_ bytes: UInt64?) -> String {
        guard let bytes else { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1024; unit += 1 }
        let number = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return "\(number) \(units[unit])"
    }

    /// `rwxr-xr-x`
    public static func permissions(_ mode: UInt16?) -> String {
        guard let mode else { return "" }
        let symbols: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        var out: [Character] = symbols.map { mode & $0.0 != 0 ? $0.1 : "-" }
        if mode & 0o4000 != 0 { out[2] = out[2] == "x" ? "s" : "S" }
        if mode & 0o2000 != 0 { out[5] = out[5] == "x" ? "s" : "S" }
        if mode & 0o1000 != 0 { out[8] = out[8] == "x" ? "t" : "T" }
        return String(out)
    }

    public static func octal(_ mode: UInt16?) -> String {
        guard let mode else { return "" }
        return String(mode & 0o7777, radix: 8)
    }

    /// Parses `755` or `0644`. Nil when not a valid octal mode.
    public static func parseOctal(_ text: String) -> UInt16? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 4, let v = UInt16(t, radix: 8) else { return nil }
        return v
    }

    private static let formatter = LockedBox<DateFormatter>({
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }())

    public static func modified(_ date: Date?) -> String {
        guard let date else { return "" }
        return formatter.withLock { $0.string(from: date) }
    }
}
