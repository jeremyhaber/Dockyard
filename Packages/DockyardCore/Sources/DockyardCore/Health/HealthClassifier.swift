import Foundation
import ConnectionKit

/// The test's own time limit expired.
struct HealthTimeoutError: Error, CustomStringConvertible {
    var seconds: TimeInterval
    var description: String { "No answer within \(Int(seconds.rounded(.up))) seconds" }
}

/// Maps what a backend threw to a `HealthStatus` and a message that is safe to store and show.
public enum HealthClassifier {
    public static func status(for error: any Error) -> HealthStatus {
        if error is HealthTimeoutError { return .timedOut }
        switch ConnectionErrorClassifier.classify(error) {
        case .authenticationFailed: return .authFailed
        case .hostNotFound: return .hostNotFound
        case .timedOut: return .timedOut
        case .refused: return .refused
        case .hostKeyRejected: return .hostKeyChanged
        case .other: return .otherError
        }
    }

    public static func message(for error: any Error, redacting secrets: [String] = []) -> String {
        let text = error is RemoteError || error is HealthTimeoutError ? String(describing: error) : error.localizedDescription
        return sanitize(text, redacting: secrets)
    }

    /// One short line without secrets: known secret values, URL credentials and `op://` references are removed.
    public static func sanitize(_ text: String, redacting secrets: [String] = [], limit: Int = 200) -> String {
        var result = text
        for secret in secrets where secret.count >= minimumRedactedLength {
            result = result.replacingOccurrences(of: secret, with: "•••")
        }
        result = result.replacingOccurrences(of: #"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"op://\S+"#, with: "•••", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return result.count > limit ? String(result.prefix(limit - 1)) + "…" : result
    }

    /// Shorter values would blank out ordinary words.
    static let minimumRedactedLength = 4
}
