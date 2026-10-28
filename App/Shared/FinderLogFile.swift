import Foundation

/// Lines the Finder extension wants in a connection's Log. The extension appends, the app reads from its last offset.
/// Format: `<kind>\t<message>\n`, kind being a `LogLine.Kind` raw value.
enum FinderLogFile {
    static func url(for connection: UUID) -> URL? {
        AppGroup.containerURL?.appendingPathComponent("Logs/finder-\(connection.uuidString).log")
    }

    static func append(kind: String, message: String, connection: UUID) {
        guard let url = url(for: connection) else { return }
        let clean = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        let data = Data("\(kind)\t\(clean)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        // Keep the file small: start over once it is large; the app has long since read older lines.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > 512_000 {
            try? Data().write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func currentSize(connection: UUID) -> UInt64 {
        guard let url = url(for: connection) else { return 0 }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
    }

    /// New lines since `offset`. A file shorter than `offset` was reset, so reading starts at the top.
    static func read(connection: UUID, from offset: UInt64) -> (lines: [(kind: String, message: String)], next: UInt64) {
        guard let url = url(for: connection), let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end < offset ? 0 : offset
        guard end > start else { return ([], end) }
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").compactMap { line -> (kind: String, message: String)? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? (kind: String(parts[0]), message: String(parts[1])) : nil
        }
        return (lines, end)
    }
}
