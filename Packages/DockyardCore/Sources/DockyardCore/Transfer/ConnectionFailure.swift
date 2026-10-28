import Foundation
import ConnectionKit

/// How the scheduler reacts to an error from a session.
public enum ConnectionFailure: Sendable, Equatable {
    /// The server will not take (more) connections now. Lower the site's live limit and retry later.
    case refused
    /// An established session died. Drop it and retry on a fresh one; the limit is unaffected.
    case sessionLost
    /// Anything else: the item failed on its own merits.
    case other
}

public enum FailurePhase: Sendable {
    /// Creating, connecting or logging in a session.
    case connecting
    /// Using a connected session.
    case working
}

public enum ConnectionFailureClassifier {
    public static func classify(_ error: any Error, phase: FailurePhase) -> ConnectionFailure {
        if error is CancellationError { return .other }
        guard let remote = error as? RemoteError else {
            return RemoteError.looksLikeConnectionLimit(error.localizedDescription) ? .refused : .other
        }
        switch remote {
        case .connectionRefused:
            return .refused
        case .serverRejected(let code, let message):
            if RemoteError.looksLikeConnectionLimit(message) { return .refused }
            if code == 421 { return phase == .connecting ? .refused : .sessionLost }
            return .other
        case .notConnected:
            return phase == .connecting ? .refused : .sessionLost
        case .protocolError(let message), .permissionDenied(let message):
            if RemoteError.looksLikeConnectionLimit(message) { return .refused }
            return phase == .working && looksLikeDroppedConnection(message) ? .sessionLost : .other
        case .authenticationFailed(let message):
            return RemoteError.looksLikeConnectionLimit(message) ? .refused : .other
        case .notFound, .unsupported, .invalidConfiguration, .hostKeyRejected:
            return .other
        }
    }

    static func looksLikeDroppedConnection(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["socket", "connection reset", "broken pipe", "timed out", "connection lost", "not connected", "disconnect", "end of file"]
            .contains { text.contains($0) }
    }

    /// Whether the session can serve another item after `error`.
    static func sessionSurvives(_ error: any Error) -> Bool {
        guard let remote = error as? RemoteError else { return false }
        switch remote {
        case .notFound, .permissionDenied, .unsupported, .invalidConfiguration: return true
        case .serverRejected(let code, _): return code >= 500
        default: return false
        }
    }
}
