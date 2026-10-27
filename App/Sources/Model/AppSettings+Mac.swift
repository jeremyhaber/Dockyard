import Foundation

/// Settings for the Mac integration features: notifications, Touch ID and updates.
extension AppSettings {
    static let notificationMode = "notificationMode"
    static let requireTouchID = "requireTouchID"
    static let touchIDGraceMinutes = "touchIDGraceMinutes"

    static let touchIDGraceRange = 0...60
    static let defaultTouchIDGraceMinutes = 5

    /// When a finished batch of transfers posts a notification.
    enum NotificationMode: String, CaseIterable, Identifiable {
        case off, failedOnly, always
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .failedOnly: "Only when something failed"
            case .always: "Always"
            }
        }
    }

    static var notifications: NotificationMode {
        UserDefaults.standard.string(forKey: notificationMode).flatMap(NotificationMode.init(rawValue:)) ?? .failedOnly
    }

    static var touchIDRequired: Bool {
        UserDefaults.standard.bool(forKey: requireTouchID)
    }

    static var touchIDGrace: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: touchIDGraceMinutes) as? Int ?? defaultTouchIDGraceMinutes
        return TimeInterval(min(max(stored, touchIDGraceRange.lowerBound), touchIDGraceRange.upperBound)) * 60
    }
}
