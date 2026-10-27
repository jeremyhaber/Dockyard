import DockyardCore
import Foundation

/// How the manager's Status column shows one connection: an icon, a short text, the latency and a tooltip.
struct HealthStatusDisplay: Equatable {
    enum Tone { case good, warning, bad, neutral, active }

    var symbol: String
    var tone: Tone
    var text: String
    var detail: String?
    var tooltip: String
    /// Failing connections sort first so they are easy to select and remove.
    var sortRank: Int

    var accessibilityText: String { [text, detail].compactMap { $0 }.joined(separator: ", ") }

    static func make(
        connection: Connection, session: SessionStatus?, health: ConnectionHealth?, testing: Bool, paused: Bool, now: Date = Date()
    ) -> HealthStatusDisplay {
        if let removed = connection.deletedAt {
            return HealthStatusDisplay(
                symbol: "trash", tone: .neutral, text: "Removed", detail: relative(removed, now: now),
                tooltip: "Removed \(removed.formatted(date: .abbreviated, time: .shortened)). Restore it within 30 days.", sortRank: 5)
        }
        if session?.isConnected == true {
            return HealthStatusDisplay(
                symbol: "checkmark.circle.fill", tone: .good, text: "Connected", detail: nil, tooltip: "Open in a tab", sortRank: 1)
        }
        if testing {
            return HealthStatusDisplay(
                symbol: "arrow.triangle.2.circlepath", tone: .active, text: "Testing\u{2026}", detail: nil,
                tooltip: "Connecting, logging in and listing the home folder", sortRank: 2)
        }
        if paused {
            return HealthStatusDisplay(
                symbol: "pause.circle.fill", tone: .warning, text: HealthSkipReason.pausedToAvoidLockout.message, detail: nil,
                tooltip: "Several logins to this host failed in a row. Dockyard stopped testing it so the server does not block your IP address. The earlier result still applies.",
                sortRank: 3)
        }
        guard let health else {
            return HealthStatusDisplay(
                symbol: "circle.dashed", tone: .neutral, text: "Not tested", detail: nil,
                tooltip: "Use Test to check that this connection works", sortRank: 4)
        }
        let tested = "Tested \(relative(health.testedAt, now: now))"
        let message = health.message.map { $0 + "\n" } ?? ""
        let isUnknownKey = health.status == .hostKeyChanged && health.message == HealthMessages.unknownHostKey
        return HealthStatusDisplay(
            symbol: health.status.symbol, tone: health.status.tone, text: isUnknownKey ? "Unknown host key" : health.status.title,
            detail: health.latencyMs.map { "\($0) ms" }, tooltip: message + tested,
            sortRank: health.status == .ok ? 3 : 0)
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension HealthStatus {
    var title: String {
        switch self {
        case .ok: "OK"
        case .authFailed: "Login failed"
        case .hostNotFound: "Host not found"
        case .timedOut: "Timed out"
        case .refused: "Refused"
        case .hostKeyChanged: "Host key changed"
        case .needsSecret: "Needs password"
        case .removedFromSource: "Removed from WHM"
        case .otherError: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .authFailed: "lock.slash.fill"
        case .hostNotFound: "questionmark.circle.fill"
        case .timedOut: "clock.badge.exclamationmark"
        case .refused: "nosign"
        case .hostKeyChanged: "exclamationmark.shield.fill"
        case .needsSecret: "lock.circle.fill"
        case .removedFromSource: "minus.circle.fill"
        case .otherError: "xmark.octagon.fill"
        }
    }

    var tone: HealthStatusDisplay.Tone {
        switch self {
        case .ok: .good
        case .needsSecret, .removedFromSource: .warning
        default: .bad
        }
    }
}
