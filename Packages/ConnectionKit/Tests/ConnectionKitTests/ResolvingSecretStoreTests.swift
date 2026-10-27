import Foundation
import Testing
@testable import ConnectionKit

private final class CountingResolver: SecretReferenceResolving {
    let values: LockedBox<[String: String]>
    let calls = LockedBox<[String]>([])
    private let _delay = LockedBox(Duration.zero)
    private let _failure = LockedBox<OnePasswordError?>(nil)
    var delay: Duration { get { _delay.withLock { $0 } } set { _delay.withLock { $0 = newValue } } }
    var failure: OnePasswordError? { get { _failure.withLock { $0 } } set { _failure.withLock { $0 = newValue } } }

    init(_ values: [String: String] = [:]) { self.values = LockedBox(values) }

    var callCount: Int { calls.withLock { $0.count } }

    func resolve(reference: String) async throws -> String {
        calls.withLock { $0.append(reference) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        guard let value = values.withLock({ $0[reference] }) else { throw OnePasswordError.notFound("reference") }
        return value
    }
}

private func makeStore(
    _ resolver: CountingResolver, references: [UUID: [SecretPurpose: String]], fallback: InMemorySecretStore = InMemorySecretStore(),
    options: ResolvingSecretStore.Options = .init(), now: @escaping @Sendable () -> Date = { Date() }
) -> ResolvingSecretStore {
    ResolvingSecretStore(fallback: fallback, references: StaticSecretReferences(references), resolver: resolver, options: options, now: now)
}

@Suite struct ResolvingSecretStoreTests {
    let id = UUID()

    @Test func theReferenceWinsOverTheKeychain() async throws {
        let keychain = InMemorySecretStore()
        await keychain.setSecret("stale", for: id, purpose: .password)
        let resolver = CountingResolver(["op://V/I/password": "fresh"])
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], fallback: keychain)
        #expect(try await store.secret(for: id, purpose: .password) == "fresh")
    }

    @Test func withoutAReferenceTheKeychainIsUsedAndOpIsNotCalled() async throws {
        let keychain = InMemorySecretStore()
        await keychain.setSecret("kc", for: id, purpose: .keyPassphrase)
        let resolver = CountingResolver()
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], fallback: keychain)
        #expect(try await store.secret(for: id, purpose: .keyPassphrase) == "kc")
        #expect(try await store.secret(for: id, purpose: .elevationPassword) == nil)
        #expect(try await store.secret(for: UUID(), purpose: .password) == nil)
        #expect(resolver.callCount == 0)
    }

    @Test func referencesArePerPurpose() async throws {
        let resolver = CountingResolver(["op://V/I/password": "pw", "op://V/I/passphrase": "phrase"])
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password", .keyPassphrase: "op://V/I/passphrase"]])
        #expect(try await store.secret(for: id, purpose: .password) == "pw")
        #expect(try await store.secret(for: id, purpose: .keyPassphrase) == "phrase")
    }

    @Test func aFailedResolveFallsBackToAStoredValue() async throws {
        let keychain = InMemorySecretStore()
        await keychain.setSecret("kc", for: id, purpose: .password)
        let resolver = CountingResolver()
        resolver.failure = .appLocked
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], fallback: keychain)
        #expect(try await store.secret(for: id, purpose: .password) == "kc")
    }

    @Test func aFailedResolveWithNothingToFallBackOnThrowsTheOriginalError() async throws {
        let resolver = CountingResolver()
        resolver.failure = .authorizationDismissed
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]])
        await #expect(throws: OnePasswordError.authorizationDismissed) { try await store.secret(for: id, purpose: .password) }
    }

    @Test func fallbackCanBeDisabled() async throws {
        let keychain = InMemorySecretStore()
        await keychain.setSecret("kc", for: id, purpose: .password)
        let resolver = CountingResolver()
        resolver.failure = .appLocked
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], fallback: keychain, options: .init(fallbackOnFailure: false))
        await #expect(throws: OnePasswordError.appLocked) { try await store.secret(for: id, purpose: .password) }
    }

    @Test func writesAndRemovalsGoToTheFallbackStore() async throws {
        let keychain = InMemorySecretStore()
        let store = makeStore(CountingResolver(), references: [:], fallback: keychain)
        try await store.setSecret("new", for: id, purpose: .password)
        #expect(await keychain.secret(for: id, purpose: .password) == "new")
        try await store.removeSecret(for: id, purpose: .password)
        #expect(await keychain.secret(for: id, purpose: .password) == nil)
    }

    @Test func noCacheByDefault() async throws {
        let resolver = CountingResolver(["op://V/I/password": "pw"])
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]])
        _ = try await store.secret(for: id, purpose: .password)
        _ = try await store.secret(for: id, purpose: .password)
        #expect(resolver.callCount == 2)
    }

    @Test func cachesForTheTTLThenResolvesAgain() async throws {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let resolver = CountingResolver(["op://V/I/password": "v1"])
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], options: .init(cacheTTL: 30), now: { clock.withLock { $0 } })

        #expect(try await store.secret(for: id, purpose: .password) == "v1")
        resolver.values.withLock { $0["op://V/I/password"] = "v2" }
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_029) }
        #expect(try await store.secret(for: id, purpose: .password) == "v1")
        #expect(resolver.callCount == 1)

        clock.withLock { $0 = Date(timeIntervalSince1970: 1_031) }
        #expect(try await store.secret(for: id, purpose: .password) == "v2")
        #expect(resolver.callCount == 2)
    }

    @Test func flushingForgetsCachedSecrets() async throws {
        let resolver = CountingResolver(["op://V/I/password": "pw"])
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], options: .init(cacheTTL: 60))
        _ = try await store.secret(for: id, purpose: .password)
        await store.flushCache()
        _ = try await store.secret(for: id, purpose: .password)
        #expect(resolver.callCount == 2)
    }

    @Test func failuresAreNotCached() async throws {
        let resolver = CountingResolver(["op://V/I/password": "pw"])
        resolver.failure = .appLocked
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], options: .init(cacheTTL: 60))
        await #expect(throws: OnePasswordError.appLocked) { try await store.secret(for: id, purpose: .password) }
        resolver.failure = nil
        #expect(try await store.secret(for: id, purpose: .password) == "pw")
    }

    @Test func concurrentReadsShareOneResolve() async throws {
        let resolver = CountingResolver(["op://V/I/password": "pw"])
        resolver.delay = .milliseconds(200)
        let store = makeStore(resolver, references: [id: [.password: "op://V/I/password"]], options: .init(cacheTTL: 60))
        let id = id
        let values = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<5 { group.addTask { try await store.secret(for: id, purpose: .password) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(values == Array(repeating: "pw", count: 5))
        #expect(resolver.callCount == 1)
    }

    @Test func worksAsTheSecretStoreOfAnSFTPAuthPlan() async throws {
        var config = ConnectionConfig(protocol: .sftp, host: "h", username: "u", authMethods: .password)
        config.id = id
        let store = makeStore(CountingResolver(["op://V/I/password": "pw-from-op"]), references: [id: [.password: "op://V/I/password"]])
        let steps = try await SSHAuth.steps(for: config, secrets: store)
        guard case .password(let password) = steps.first else { Issue.record("expected a password step, got \(steps)"); return }
        #expect(password == "pw-from-op")
    }
}

@Suite struct AgentSocketTests {
    @Test func rawValueRoundTrip() {
        for socket in [AgentSocket.system, .onePassword, .custom("/tmp/a b/agent.sock")] {
            #expect(AgentSocket(rawValue: socket.rawValue) == socket)
        }
        #expect(AgentSocket(rawValue: "custom:") == nil && AgentSocket(rawValue: "bogus") == nil)
    }

    @Test func resolvedPaths() {
        #expect(AgentSocket.system.resolvedPath(home: "/Users/j") == nil)
        #expect(AgentSocket.onePassword.resolvedPath(home: "/Users/j") == "/Users/j/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
        #expect(AgentSocket.custom("~/s/agent").resolvedPath(home: "/Users/j") == "/Users/j/s/agent")
        #expect(AgentSocket.custom("/run/agent").resolvedPath(home: "/Users/j") == "/run/agent")
        #expect(AgentSocket.onePasswordDefaultPath == "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
    }

    @Test func configCodableKeepsOldDataReadable() throws {
        var config = ConnectionConfig(protocol: .sftp, host: "h", username: "u", authMethods: .agent, agentSocket: .onePassword)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)

        config.agentSocket = .system
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["agentSocket"] = nil
        let old = try JSONDecoder().decode(ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.agentSocket == .system)
    }

    @Test func authPlanUsesTheConfiguredSocket() async throws {
        let store = InMemorySecretStore()
        var config = ConnectionConfig(protocol: .sftp, host: "h", username: "u", authMethods: .agent)
        guard case .agent = try await SSHAuth.steps(for: config, secrets: store).first else { Issue.record("expected the system agent"); return }

        config.agentSocket = .custom("/tmp/x.sock")
        guard case .agentSocket(let path) = try await SSHAuth.steps(for: config, secrets: store).first else { Issue.record("expected a socket step"); return }
        #expect(path == "/tmp/x.sock")

        config.agentSocket = .onePassword
        guard case .agentSocket(let op) = try await SSHAuth.steps(for: config, secrets: store).first else { Issue.record("expected a socket step"); return }
        #expect(op.hasSuffix("/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock") && !op.contains("~"))
    }
}
