import ConnectionKit
import DockyardCore
import Foundation
import RcloneKit

struct ConnectionTestResult: Equatable {
    var success: Bool
    var message: String
}

extension AppModel {
    /// Saves the draft and its typed-in secrets. Returns the stored connection.
    func save(_ draft: SiteDraft) async throws -> Connection {
        let connection = try draft.connection()
        do { _ = try JumpChain.resolve(for: connection, lookup: jumpLookup(replacing: connection)) } catch {
            throw SiteDraftError.jump("\(error)")
        }
        let saved = try await connections.saveEdited(connection)
        for (purpose, value) in draft.secretsToStore {
            try await secrets.setSecret(value, for: saved.id, purpose: purpose)
        }
        // An edit can change anything a test result or a resolved secret was based on.
        forgetHealth(of: [saved.id])
        flushSecretCache()
        if let session = session(for: saved.id) { session.updateConnection(saved) }
        return saved
    }

    func saveAndConnect(_ draft: SiteDraft) async throws {
        let saved = try await save(draft)
        open(saved)
    }

    func testConnection(_ draft: SiteDraft) async -> ConnectionTestResult {
        let log = LogBuffer(capacity: 200)
        do {
            let connection = try draft.connection()
            let memory = InMemorySecretStore()
            for purpose in SecretPurpose.allCases {
                if let value = try? await keychainSecrets.secret(for: connection.id, purpose: purpose) {
                    await memory.setSecret(value, for: connection.id, purpose: purpose)
                }
            }
            for (purpose, value) in draft.secretsToStore {
                await memory.setSecret(value, for: connection.id, purpose: purpose)
            }
            // The draft's references, not the saved ones, decide where the test reads from.
            let store = ResolvingSecretStore(
                fallback: memory, references: StaticSecretReferences([connection.id: connection.secretReferences]),
                resolver: onePassword.cli)
            if connection.protocol == .rclone, let cloud = connection.cloud,
               RcloneBackend(rawValue: cloud.backend)?.usesOAuth == true,
               (await memory.secret(for: connection.id, purpose: .cloudToken)) == nil {
                return ConnectionTestResult(success: false, message: "Save and connect once to authorise this account in your browser.")
            }
            if usesPassword(connection), connection.secretReferences[.password] == nil,
               (await memory.secret(for: connection.id, purpose: .password)) == nil {
                return ConnectionTestResult(success: false, message: "Enter a password to test the connection.")
            }
            let validator = hostKeyValidator(host: connection.host, port: connection.port, log: log)
            let fs = try FileSystemFactory.make(
                for: connection, secrets: store, hostKeyValidator: validator,
                jumpHops: try jumpHops(for: connection, log: log))
            try await fs.connect()
            let home = (try? await fs.homeDirectory()) ?? "/"
            let count = try await fs.list(home).count
            await fs.disconnect()
            return ConnectionTestResult(success: true, message: "Connected. \(home) has \(count) item\(count == 1 ? "" : "s").")
        } catch let error as SiteDraftError {
            return ConnectionTestResult(success: false, message: error.description)
        } catch {
            return ConnectionTestResult(success: false, message: error.userMessage)
        }
    }

    private func usesPassword(_ c: Connection) -> Bool {
        switch c.protocol {
        case .sftp: c.authMethods == .password
        case .ftp, .ftps: c.username.lowercased() != "anonymous"
        case .rclone: false
        }
    }

    /// Runs rclone's OAuth flow for a draft and returns the token so the editor can keep it until saved.
    func authorizeCloud(_ draft: SiteDraft) async -> Result<String, AppError> {
        do {
            let preset = draft.cloudPreset
            guard let backend = RcloneBackend(rawValue: preset.backend) else { return .failure(.message("Unknown provider")) }
            let library = try FileSystemFactory.loadRclone()
            let client = RcloneClient(transport: library)
            let token = try await RcloneOAuth(client: client).authorize(backend: backend, options: preset.options)
            return .success(token)
        } catch let error as AppError {
            return .failure(error)
        } catch {
            return .failure(.message(error.userMessage))
        }
    }
}

/// The transfer queue as the UI sees it. Views go through these so a paged queue can replace the snapshot later.
extension AppModel {
    func cancelTransfer(_ id: UUID) { let q = queue; Task { await q.cancel(id) } }
    func retryTransfer(_ id: UUID) { let q = queue; Task { await q.retry(id) } }
    func retryFailedTransfers() { let q = queue; Task { await q.retryFailed() } }
    func setTransfersPaused(_ paused: Bool) { let q = queue; Task { if paused { await q.pause() } else { await q.resume() } } }
    func clearFinishedTransfers() { let q = queue; Task { await q.removeFinished() } }
    func cancelAllTransfers() { let q = queue; Task { await q.cancelAll() } }
}
