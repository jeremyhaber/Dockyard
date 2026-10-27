import Foundation
import ConnectionKit

public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip, tar, tarGz, tarBz2, tarXz

    /// What "Compress…" offers. Everything can be extracted.
    public static let creatable: [ArchiveFormat] = [.zip, .tarGz, .tar]

    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGz: "tar.gz"
        case .tarBz2: "tar.bz2"
        case .tarXz: "tar.xz"
        }
    }

    public var canCreate: Bool { Self.creatable.contains(self) }

    public static func detect(fileName: String) -> ArchiveFormat? {
        let name = fileName.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }

    /// `backup.tar.gz` -> `backup`; used for "Extract here" folder names.
    public static func stem(of fileName: String) -> String {
        guard let format = detect(fileName: fileName) else { return fileName }
        let lower = fileName.lowercased()
        for ext in [format.fileExtension, "tgz", "tbz2", "tbz", "txz"] where lower.hasSuffix("." + ext) {
            return String(fileName.dropLast(ext.count + 1))
        }
        return fileName
    }
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case missingTool(String, where: String)
    case unsupported(String)
    case commandFailed(status: Int32, output: String)
    case destinationExists(String)

    public var description: String {
        switch self {
        case .missingTool(let tool, let place): "\(tool) is not installed \(place)"
        case .unsupported(let m): m
        case .commandFailed(let status, let output):
            "The command failed (exit status \(status))" + (output.isEmpty ? "" : ": \(output)")
        case .destinationExists(let path): "\(path) already exists"
        }
    }
}

/// One program invocation, built once and rendered for a remote shell or run locally.
struct ArchiveCommand: Sendable, Equatable {
    var argv: [String]
    /// Working directory; relative operands are resolved against it.
    var directory: String?

    var shellLine: String {
        let call = ShellQuote.join(argv)
        guard let directory else { return call }
        return "cd \(ShellQuote.quote(directory)) && \(call)"
    }
}

/// Builds the commands. Item names are relative to `directory`; names that start with `-` get `./`.
enum ArchiveCommands {
    static func operand(_ name: String) -> String { name.hasPrefix("-") ? "./" + name : name }

    /// Tools `compress` needs for `format` given what the host has.
    static func compressTools(_ format: ArchiveFormat, available: Set<String>) -> [String] {
        switch format {
        case .zip: available.contains("zip") || !available.contains("bsdtar") ? ["zip"] : ["bsdtar"]
        case .tar: ["tar"]
        case .tarGz: ["tar", "gzip"]
        case .tarBz2: ["tar", "bzip2"]
        case .tarXz: ["tar", "xz"]
        }
    }

    static func extractTools(_ format: ArchiveFormat, available: Set<String>) -> [String] {
        switch format {
        case .zip: available.contains("unzip") || !available.contains("bsdtar") ? ["unzip"] : ["bsdtar"]
        default: compressTools(format, available: available)
        }
    }

    static func compress(
        _ format: ArchiveFormat, directory: String, names: [String], archive: String, available: Set<String>
    ) -> ArchiveCommand {
        let items = names.map(operand)
        switch format {
        case .zip:
            if available.contains("zip") || !available.contains("bsdtar") {
                return ArchiveCommand(argv: ["zip", "-r", "-y", "-nw", archive] + items, directory: directory)
            }
            return ArchiveCommand(argv: ["bsdtar", "-c", "--format", "zip", "-f", archive] + items, directory: directory)
        case .tar: return ArchiveCommand(argv: ["tar", "-cf", archive, "--"] + items, directory: directory)
        case .tarGz: return ArchiveCommand(argv: ["tar", "-czf", archive, "--"] + items, directory: directory)
        case .tarBz2: return ArchiveCommand(argv: ["tar", "-cjf", archive, "--"] + items, directory: directory)
        case .tarXz: return ArchiveCommand(argv: ["tar", "-cJf", archive, "--"] + items, directory: directory)
        }
    }

    static func extract(_ format: ArchiveFormat, archive: String, into folder: String, available: Set<String>) -> ArchiveCommand {
        switch format {
        case .zip:
            if available.contains("unzip") || !available.contains("bsdtar") {
                return ArchiveCommand(argv: ["unzip", "-q", archive, "-d", folder])
            }
            return ArchiveCommand(argv: ["bsdtar", "-xf", archive, "-C", folder])
        case .tar: return ArchiveCommand(argv: ["tar", "-xf", archive, "-C", folder])
        case .tarGz: return ArchiveCommand(argv: ["tar", "-xzf", archive, "-C", folder])
        case .tarBz2: return ArchiveCommand(argv: ["tar", "-xjf", archive, "-C", folder])
        case .tarXz: return ArchiveCommand(argv: ["tar", "-xJf", archive, "-C", folder])
        }
    }
}
