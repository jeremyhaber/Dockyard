import Foundation
import Crypto
import ConnectionKit

public enum ChecksumResult: Sendable, Equatable {
    case match(String)
    case mismatch(local: String, remote: String)
    /// No way to compute the remote hash (no shell, or no `sha256sum`/`shasum`), or the remote read failed.
    case unavailable(String)
}

/// Compares the SHA-256 of a local file with the one the server computes for the uploaded or downloaded copy.
public enum ChecksumVerifier {
    /// Hex SHA-256 of a local file, read in 1 MiB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Runs `sha256sum` (or `shasum -a 256`) on the server and compares. Only SFTP connections can do this.
    public static func verify(local: URL, remote: String, on fs: any RemoteFileSystem) async -> ChecksumResult {
        guard let runner = fs as? any RemoteCommandRunner else {
            return .unavailable("This connection has no shell to compute checksums")
        }
        let localHash: String
        do { localHash = try await Task.detached(priority: .utility) { try sha256(of: local) }.value } catch {
            return .unavailable("Cannot read \(local.lastPathComponent): \(error.localizedDescription)")
        }
        switch await remoteSHA256(of: remote, using: runner) {
        case .success(let remoteHash):
            return remoteHash == localHash ? .match(localHash) : .mismatch(local: localHash, remote: remoteHash)
        case .failure(let failure):
            return .unavailable(failure.reason)
        }
    }

    struct Unavailable: Error { var reason: String }

    static func remoteSHA256(of path: String, using runner: any RemoteCommandRunner) async -> Result<String, Unavailable> {
        let quoted = ShellQuote.quote(path)
        var lastReason = "No sha256sum or shasum on the server"
        for command in ["sha256sum -- \(quoted)", "shasum -a 256 -- \(quoted)"] {
            let result: SSHExecResult
            do { result = try await runner.exec(command) } catch {
                return .failure(Unavailable(reason: "Could not run \(command.split(separator: " ")[0]): \(error)"))
            }
            if result.exitStatus == 0 {
                guard let hash = parseDigest(result.stdoutString) else {
                    return .failure(Unavailable(reason: "Unexpected checksum output from the server"))
                }
                return .success(hash)
            }
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            // 127 / "not found": try the next tool. Anything else (missing file, permissions) will not improve.
            if result.exitStatus == 127 || stderr.localizedCaseInsensitiveContains("not found") { continue }
            lastReason = stderr.isEmpty ? "Checksum command failed (exit \(result.exitStatus))" : stderr
            return .failure(Unavailable(reason: lastReason))
        }
        return .failure(Unavailable(reason: lastReason))
    }

    /// First 64-hex-digit token of `sha256sum` output; GNU prefixes the line with a backslash when the name is escaped.
    static func parseDigest(_ output: String) -> String? {
        var line = Substring(output.split(whereSeparator: \.isNewline).first ?? "")
        if line.hasPrefix("\\") { line = line.dropFirst() }
        let token = line.prefix { !$0.isWhitespace }
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        return token.lowercased()
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
