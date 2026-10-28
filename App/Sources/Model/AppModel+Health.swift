import ConnectionKit
import DockyardCore
import Foundation

// MARK: - Health checks

extension AppModel {
    /// Tests the connections in the background. Progress and results show in the Connections window.
    ///
    /// Secrets: a run reads every saved password, so with "Require Touch ID" on it asks once up front and then reads the
    /// Keychain without the per-read gate. References go through `op` only when 1Password is unlocked; otherwise those
    /// connections report "Needs password" instead of opening 1Password prompts for each of them.
    func testConnections(_ list: [Connection]) {
        guard !health.isRunning, !list.isEmpty else { return }
        health.launch(total: list.count) { [weak self] center in
            guard let self else { return }
            do {
                if !DemoMode.isEnabled, AppSettings.touchIDRequired { try await AuthGate.shared.authorize() }
            } catch {
                self.showToast("Testing cancelled", symbol: "xmark.circle", isError: true)
                return
            }
            let plan = await self.planHealthRun(for: list)
            guard !Task.isCancelled else { return }
            await center.execute(plan.runnable, earlier: plan.earlier, environment: plan.environment)
        }
    }

    private struct HealthPlan {
        var runnable: [Connection]
        var earlier: [ConnectionHealth]
        var environment: HealthEnvironment
    }

    private func planHealthRun(for list: [Connection]) async -> HealthPlan {
        var runnable = list
        var earlier: [ConnectionHealth] = []
        if list.contains(where: { !$0.secretReferences.isEmpty }) {
            await onePassword.refresh()
            if !onePassword.isReady {
                runnable = list.filter { $0.secretReferences.isEmpty }
                earlier = list.filter { !$0.secretReferences.isEmpty }.map {
                    ConnectionHealth(
                        connectionId: $0.id, status: .needsSecret, message: "1Password is locked or not available, so its secret was not read")
                }
                try? await health.repository.record(earlier)
            }
        }
        let store = ResolvingSecretStore(
            fallback: ungatedSecrets, references: connections, resolver: onePassword.cli,
            options: ResolvingSecretStore.Options(cacheTTL: 60))
        let environment = HealthEnvironment.make(secrets: store, knownHosts: knownHosts, connections: allConnections)
        return HealthPlan(runnable: runnable, earlier: earlier, environment: environment)
    }

    func forgetHealth(of ids: [UUID]) {
        let repository = healthRepository
        Task { try? await repository.clear(connectionIds: ids) }
    }
}

// MARK: - Removing and restoring

extension AppModel {
    /// Hides the connections for 30 days. The toast offers Undo.
    func removeConnections(_ list: [Connection]) async {
        guard !list.isEmpty else { return }
        let ids = list.map(\.id)
        for session in sessions where ids.contains(session.connection.id) { close(session) }
        do {
            try await connections.softDelete(ids: ids)
        } catch {
            alertMessage = "Could not remove the connections: \(error.userMessage)"
            return
        }
        let text = list.count == 1 ? "Removed \"\(list[0].name)\"" : "Removed \(list.count) connections"
        showToast(text, symbol: "trash", action: ToastAction(title: "Undo") { [weak self] in
            Task { await self?.restoreConnections(list) }
        })
    }

    func restoreConnections(_ list: [Connection]) async {
        guard !list.isEmpty else { return }
        do {
            let restored = try await connections.restore(ids: list.map(\.id))
            showToast(restored.count == 1 ? "Restored \"\(restored[0].name)\"" : "Restored \(restored.count) connections", symbol: "arrow.uturn.backward.circle")
        } catch {
            alertMessage = "Could not restore the connections: \(error.userMessage)"
        }
    }

    /// Deletes removed connections for good, with their saved secrets. `nil` empties the whole list.
    func deleteRemovedConnections(ids: [UUID]?) async {
        do {
            _ = try await connections.emptyRecentlyRemoved(ids: ids, secrets: ungatedSecrets)
        } catch {
            alertMessage = "Could not delete the connections: \(error.userMessage)"
        }
    }

    /// At launch: removed connections older than 30 days go, together with their Keychain items.
    func purgeExpiredRemovals() {
        let repository = connections
        let store = ungatedSecrets
        Task.detached(priority: .utility) {
            _ = try? await repository.purgeRemoved(olderThan: ConnectionRepository.removedRetention, secrets: store)
        }
    }

    func startHealthObservers() {
        health.startObserving()
        let repository = connections
        Task { [weak self] in
            for await list in repository.observeRecentlyRemoved() {
                guard let self else { return }
                self.recentlyRemoved = list
            }
        }
    }
}
