import Foundation

public enum FileNaming {
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    /// Splits `archive.tar.gz` into (`archive`, `tar.gz`) and `.bashrc` into (`.bashrc`, ``).
    public static func split(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        for c in compoundExtensions where lower.hasSuffix("." + c) && name.count > c.count + 1 {
            return (String(name.dropLast(c.count + 1)), String(name.suffix(c.count)))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// `report.txt` -> `report (2).txt`
    public static func numbered(_ name: String, _ n: Int) -> String {
        let (stem, ext) = split(name)
        return ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
    }

    /// `report.txt` -> `report (conflict 2026-10-27).txt` (the date is formatted in `timeZone`).
    public static func conflictCopy(_ name: String, date: Date, timeZone: TimeZone = .current) -> String {
        let (stem, ext) = split(name)
        let label = "conflict \(dayString(date, timeZone: timeZone))"
        return ext.isEmpty ? "\(stem) (\(label))" : "\(stem) (\(label)).\(ext)"
    }

    /// Like `conflictCopy` but appends ` 2`, ` 3`... until the name is not in `existing`.
    public static func uniqueConflictCopy(_ name: String, date: Date, existing: Set<String>, timeZone: TimeZone = .current) -> String {
        let (stem, ext) = split(name)
        let day = dayString(date, timeZone: timeZone)
        func make(_ suffix: String) -> String {
            let label = "conflict \(day)\(suffix)"
            return ext.isEmpty ? "\(stem) (\(label))" : "\(stem) (\(label)).\(ext)"
        }
        var candidate = make("")
        var n = 2
        while existing.contains(candidate) { candidate = make(" \(n)"); n += 1 }
        return candidate
    }

    static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
