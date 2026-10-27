import DockyardCore
import Foundation
import Observation

struct ConflictRequest: Identifiable, Equatable {
    let id = UUID()
    let info: ConflictInfo
}

struct PasswordRequest: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var fieldLabel: String
    var allowsEmpty = false
}

struct HostKeyRequest: Identifiable, Equatable {
    let id = UUID()
    var host: String
    var port: Int
    var algorithm: String
    var fingerprint: String
    /// Set when a different key was trusted before.
    var previousFingerprint: String?
}

struct ConfirmRequest: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var cancelTitle = "Cancel"
    var symbol = "exclamationmark.shield"
    /// Paths or names the question is about, listed under the message.
    var items: [String] = []
    /// When set, the sheet offers "Don't ask again for this session" with this label.
    var suppressTitle: String?
}

struct ConfirmAnswer: Equatable {
    var confirmed: Bool
    var suppress: Bool
}

struct LeftoverRequest: Identifiable, Equatable {
    let id = UUID()
    var queued: Int
    var failed: Int
}

struct LeftoverAnswer: Equatable {
    var choice: LeftoverChoice
    var remember: Bool
}

enum ActivePrompt: Identifiable, Equatable {
    case leftovers(LeftoverRequest)
    case conflict(ConflictRequest)
    case password(PasswordRequest)
    case hostKey(HostKeyRequest)
    case confirm(ConfirmRequest)

    var id: UUID {
        switch self {
        case .leftovers(let r): r.id
        case .conflict(let r): r.id
        case .password(let r): r.id
        case .hostKey(let r): r.id
        case .confirm(let r): r.id
        }
    }
}

/// Modal questions from background work (transfers, connecting). Each `ask` suspends until the sheet is answered.
@MainActor @Observable
final class PromptCenter {
    private(set) var conflicts: [ConflictRequest] = []
    private(set) var passwords: [PasswordRequest] = []
    private(set) var hostKeys: [HostKeyRequest] = []
    private(set) var confirmations: [ConfirmRequest] = []
    private(set) var leftovers: [LeftoverRequest] = []

    @ObservationIgnored private var confirmWaiters: [UUID: CheckedContinuation<ConfirmAnswer, Never>] = [:]
    @ObservationIgnored private var leftoverWaiters: [UUID: CheckedContinuation<LeftoverAnswer, Never>] = [:]
    @ObservationIgnored private var conflictWaiters: [UUID: CheckedContinuation<ConflictDecision, Never>] = [:]
    @ObservationIgnored private var passwordWaiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    @ObservationIgnored private var hostKeyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    nonisolated init() {}

    var active: ActivePrompt? {
        if let r = hostKeys.first { return .hostKey(r) }
        if let r = passwords.first { return .password(r) }
        if let r = confirmations.first { return .confirm(r) }
        if let r = leftovers.first { return .leftovers(r) }
        if let r = conflicts.first { return .conflict(r) }
        return nil
    }

    func askLeftovers(queued: Int, failed: Int) async -> LeftoverAnswer {
        let request = LeftoverRequest(queued: queued, failed: failed)
        return await withCheckedContinuation { continuation in
            leftoverWaiters[request.id] = continuation
            leftovers.append(request)
        }
    }

    func resolveLeftovers(_ id: UUID, _ answer: LeftoverAnswer) {
        leftovers.removeAll { $0.id == id }
        leftoverWaiters.removeValue(forKey: id)?.resume(returning: answer)
    }

    func askConflict(_ info: ConflictInfo) async -> ConflictDecision {
        let request = ConflictRequest(info: info)
        return await withCheckedContinuation { continuation in
            conflictWaiters[request.id] = continuation
            conflicts.append(request)
        }
    }

    func resolveConflict(_ id: UUID, _ decision: ConflictDecision) {
        conflicts.removeAll { $0.id == id }
        conflictWaiters.removeValue(forKey: id)?.resume(returning: decision)
    }

    /// Returns nil when the user cancels.
    func askPassword(_ request: PasswordRequest) async -> String? {
        await withCheckedContinuation { continuation in
            passwordWaiters[request.id] = continuation
            passwords.append(request)
        }
    }

    func resolvePassword(_ id: UUID, _ value: String?) {
        passwords.removeAll { $0.id == id }
        passwordWaiters.removeValue(forKey: id)?.resume(returning: value)
    }

    func askHostKey(_ request: HostKeyRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyWaiters[request.id] = continuation
            hostKeys.append(request)
        }
    }

    func resolveHostKey(_ id: UUID, trust: Bool) {
        hostKeys.removeAll { $0.id == id }
        hostKeyWaiters.removeValue(forKey: id)?.resume(returning: trust)
    }

    /// A yes/no question. True when the user confirms.
    func askConfirm(_ request: ConfirmRequest) async -> Bool {
        await askConfirmDetailed(request).confirmed
    }

    func askConfirmDetailed(_ request: ConfirmRequest) async -> ConfirmAnswer {
        await withCheckedContinuation { continuation in
            confirmWaiters[request.id] = continuation
            confirmations.append(request)
        }
    }

    func resolveConfirm(_ id: UUID, confirmed: Bool, suppress: Bool = false) {
        confirmations.removeAll { $0.id == id }
        confirmWaiters.removeValue(forKey: id)?.resume(returning: ConfirmAnswer(confirmed: confirmed, suppress: suppress))
    }
}
