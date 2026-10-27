import Foundation

enum FTPListParser {
    // MARK: MLSD

    /// Parses one RFC 3659 fact line, e.g. `type=file;size=12;modify=20240115123045; name`.
    /// Returns nil for `cdir`/`pdir` entries and unparseable lines.
    static func parseMLSD(_ line: String, parent: String) -> RemoteItem? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let factPart = line[..<space]
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty else { return nil }

        var facts: [String: String] = [:]
        for fact in factPart.split(separator: ";") {
            guard let eq = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<eq].lowercased()] = String(fact[fact.index(after: eq)...])
        }

        var isDirectory = false
        var symlinkTarget: String?
        switch (facts["type"] ?? "").lowercased() {
        case "file": break
        case "dir": isDirectory = true
        case "cdir", "pdir": return nil
        case let type where type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink"):
            let original = facts["type"] ?? ""
            symlinkTarget = original.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        default: break
        }

        let mode = facts["unix.mode"].flatMap { UInt16($0, radix: 8) }.map { $0 & 0o7777 }
        return RemoteItem(
            name: name,
            path: RemotePath.join(parent, name),
            isDirectory: isDirectory,
            size: facts["size"].flatMap { UInt64($0) },
            modified: facts["modify"].flatMap(parseMLSTTime),
            permissions: mode,
            symlinkTarget: symlinkTarget
        )
    }

    static func parseMLSTTime(_ value: String) -> Date? {
        let main = value.split(separator: ".").first.map(String.init) ?? value
        guard main.count == 14, main.allSatisfy(\.isNumber) else { return nil }
        let digits = Array(main.utf8).map { Int($0) - 48 }
        func num(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        var components = DateComponents()
        components.year = num(0..<4)
        components.month = num(4..<6)
        components.day = num(6..<8)
        components.hour = num(8..<10)
        components.minute = num(10..<12)
        components.second = num(12..<14)
        return utcCalendar.date(from: components)
    }

    // MARK: Unix LIST

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Parses `drwxr-xr-x 2 user group 4096 Jan 15 12:30 name`. Returns nil for `total` lines and
    /// anything that is not Unix style. Times without a year are interpreted as UTC.
    static func parseUnixList(_ line: String, parent: String, now: Date = Date()) -> RemoteItem? {
        let chars = Array(line)
        var index = 0
        var tokens: [String] = []

        while tokens.count < 8 {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
            let start = index
            while index < chars.count, chars[index] != " ", chars[index] != "\t" { index += 1 }
            guard index > start else { return nil }
            tokens.append(String(chars[start..<index]))
        }
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        var name = String(chars[index...])
        guard !name.isEmpty else { return nil }

        let perms = tokens[0]
        guard perms.count >= 10, "-dlbcpsDM".contains(perms.first!), let size = UInt64(tokens[4]),
              let monthIndex = months.firstIndex(of: tokens[5].lowercased()), let day = Int(tokens[6]) else { return nil }

        var symlinkTarget: String?
        if perms.first == "l", let arrow = name.range(of: " -> ") {
            symlinkTarget = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }

        guard let modified = listDate(month: monthIndex + 1, day: day, yearOrTime: tokens[7], now: now) else { return nil }
        return RemoteItem(
            name: name,
            path: RemotePath.join(parent, name),
            isDirectory: perms.first == "d",
            size: size,
            modified: modified,
            permissions: mode(fromSymbolic: perms),
            symlinkTarget: symlinkTarget
        )
    }

    private static func listDate(month: Int, day: Int, yearOrTime: String, now: Date) -> Date? {
        var components = DateComponents()
        components.month = month
        components.day = day
        if yearOrTime.contains(":") {
            let hm = yearOrTime.split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2 else { return nil }
            components.hour = hm[0]
            components.minute = hm[1]
            let currentYear = utcCalendar.component(.year, from: now)
            components.year = currentYear
            guard var date = utcCalendar.date(from: components) else { return nil }
            // A date more than a day ahead belongs to the previous year.
            if date > now.addingTimeInterval(86_400) {
                components.year = currentYear - 1
                date = utcCalendar.date(from: components) ?? date
            }
            return date
        }
        guard let year = Int(yearOrTime) else { return nil }
        components.year = year
        return utcCalendar.date(from: components)
    }

    /// Converts `rwxr-xr-x`-style strings (with optional leading type char) into mode bits.
    static func mode(fromSymbolic text: String) -> UInt16? {
        let bits = Array(text.dropFirst().prefix(9))
        guard bits.count == 9 else { return nil }
        var mode: UInt16 = 0
        for (i, c) in bits.enumerated() {
            let shift = UInt16(8 - i)
            switch c {
            case "r", "w", "x": mode |= 1 << shift
            case "s", "t": mode |= 1 << shift
            case "-", "S", "T": break
            default: return nil
            }
            // setuid / setgid / sticky
            if i == 2, c == "s" || c == "S" { mode |= 0o4000 }
            if i == 5, c == "s" || c == "S" { mode |= 0o2000 }
            if i == 8, c == "t" || c == "T" { mode |= 0o1000 }
        }
        return mode
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
