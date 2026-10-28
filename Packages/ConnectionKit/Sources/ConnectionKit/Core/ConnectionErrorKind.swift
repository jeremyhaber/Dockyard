import Foundation
import NIOCore
import NIOPosix

/// What went wrong while reaching and logging in to a server, independent of the backend that reported it.
public enum ConnectionErrorKind: Sendable, Equatable {
    case authenticationFailed
    case hostNotFound
    case timedOut
    case refused
    case hostKeyRejected
    case other
}

public enum ConnectionErrorClassifier {
    public static func classify(_ error: any Error) -> ConnectionErrorKind {
        if error is CancellationError { return .other }
        if let remote = error as? RemoteError { return classify(remote) }
        if let connection = error as? NIOConnectionError { return classify(connection) }
        if let channel = error as? ChannelError {
            if case .connectTimeout = channel { return .timedOut }
            return .other
        }
        if let io = error as? IOError { return classify(errno: io.errnoCode) }
        if let url = error as? URLError { return classify(urlCode: url.code) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return classify(errno: Int32(truncatingIfNeeded: ns.code)) }
        return classify(message: error.localizedDescription)
    }

    static func classify(_ error: RemoteError) -> ConnectionErrorKind {
        switch error {
        case .authenticationFailed(let message):
            return RemoteError.looksLikeConnectionLimit(message) ? .refused : .authenticationFailed
        case .hostKeyRejected:
            return .hostKeyRejected
        case .connectionRefused:
            return .refused
        case .serverRejected(let code, let message):
            if RemoteError.looksLikeConnectionLimit(message) || code == 421 { return .refused }
            return code == 530 ? .authenticationFailed : .other
        case .protocolError(let message):
            return classify(message: message)
        case .notConnected, .notFound, .permissionDenied, .unsupported, .invalidConfiguration:
            return .other
        }
    }

    private static func classify(_ error: NIOConnectionError) -> ConnectionErrorKind {
        if error.connectionErrors.isEmpty, error.dnsAError != nil || error.dnsAAAAError != nil { return .hostNotFound }
        for failure in error.connectionErrors {
            let kind = classify(failure.error)
            if kind != .other { return kind }
        }
        return .other
    }

    private static func classify(errno code: Int32) -> ConnectionErrorKind {
        switch code {
        case ECONNREFUSED: .refused
        case ETIMEDOUT: .timedOut
        default: .other
        }
    }

    private static func classify(urlCode code: URLError.Code) -> ConnectionErrorKind {
        switch code {
        case .cannotFindHost, .dnsLookupFailed: .hostNotFound
        case .timedOut: .timedOut
        case .cannotConnectToHost: .refused
        default: .other
        }
    }

    /// libssh2 and our own TCP setup report plain text.
    static func classify(message: String) -> ConnectionErrorKind {
        let text = message.lowercased()
        if RemoteError.looksLikeConnectionLimit(text) { return .refused }
        if resolutionPhrases.contains(where: text.contains) { return .hostNotFound }
        if text.contains("connection refused") { return .refused }
        if text.contains("timed out") || text.contains("timeout") { return .timedOut }
        return .other
    }

    private static let resolutionPhrases = [
        "cannot resolve", "name or service not known", "nodename nor servname", "no address associated",
        "temporary failure in name resolution", "name resolution",
    ]
}
