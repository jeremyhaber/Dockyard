import AppKit
import ConnectionKit
import Foundation
import LocalAuthentication

/// Asks the user to authenticate (Touch ID, Apple Watch or the account password) and remembers the answer
/// for the grace period set in Settings.
actor AuthGate {
    static let shared = AuthGate()

    private var approvedUntil: Date?
    private var pending: Task<Bool, Never>?
    @MainActor private static var observing = false

    /// Throws `AppError.cancelled` when the user declines.
    func authorize() async throws {
        if let until = approvedUntil, until > Date() { return }
        let task: Task<Bool, Never>
        if let pending {
            task = pending
        } else {
            task = Task { await Self.evaluate() }
            pending = task
        }
        let approved = await task.value
        pending = nil
        guard approved else { throw AppError.cancelled }
        approvedUntil = Date().addingTimeInterval(AppSettings.touchIDGrace)
    }

    func revoke() { approvedUntil = nil }

    private static func evaluate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Dockyard needs to use a saved password to connect")
        } catch {
            return false
        }
    }

    /// The approval ends when the Mac sleeps or the screen locks.
    @MainActor
    static func installRevocation() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { await AuthGate.shared.revoke() }
            }
        }
    }
}

/// Wraps the Keychain store: with "Require Touch ID" on, reading a secret needs a recent authentication.
/// Writes and removals pass through; nothing is cached here.
struct GatedSecretStore: SecretStore {
    let base: any SecretStore

    func secret(for connection: UUID, purpose: SecretPurpose) async throws -> String? {
        guard let value = try await base.secret(for: connection, purpose: purpose) else { return nil }
        if AppSettings.touchIDRequired { try await AuthGate.shared.authorize() }
        return value
    }

    func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) async throws {
        try await base.setSecret(secret, for: connection, purpose: purpose)
    }

    func removeSecret(for connection: UUID, purpose: SecretPurpose) async throws {
        try await base.removeSecret(for: connection, purpose: purpose)
    }
}

extension AppModel {
    /// A saved secret, or nil when there is none or the Keychain cannot be read. Declining Touch ID still throws,
    /// so the connection stops instead of asking for the password again.
    func storedSecret(_ connection: UUID, _ purpose: SecretPurpose) async throws -> String? {
        do {
            return try await secrets.secret(for: connection, purpose: purpose)
        } catch AppError.cancelled {
            throw AppError.cancelled
        } catch let error as OnePasswordError {
            // A reference 1Password cannot resolve must not turn into a password prompt that hides it.
            throw error
        } catch {
            return nil
        }
    }
}
