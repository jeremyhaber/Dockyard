import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

/// Runs against `Packages/ConnectionKit/scripts/integration-servers.sh`; skipped unless DOCKYARD_INTEGRATION=1.
@Suite(.enabled(if: Live.enabled), .serialized) struct HealthIntegrationTests {
    private let secrets = InMemorySecretStore()

    private func site(
        _ name: String, proto: ConnectionProtocol = .sftp, host: String = Live.host, port: Int,
        password: String = Live.password, auth: AuthMethods = .password
    ) async -> Connection {
        let c = Connection(name: name, protocol: proto, host: host, port: port, username: Live.user, authMethods: auth)
        await secrets.setSecret(password, for: c.id, purpose: .password)
        return c
    }

    private func run(
        _ connections: [Connection], tracker: SessionTracker = SessionTracker(), options: HealthCheckOptions = .init(timeout: 20)
    ) async -> [HealthEvent] {
        let checker = HealthChecker(options: options)
        let stream = await checker.run(
            connections: connections,
            makeFileSystem: { c in
                let inner: any RemoteFileSystem = c.protocol == .sftp
                    ? SFTPFileSystem(config: c.config, secrets: secrets) : FTPFileSystem(config: c.config, secrets: secrets)
                return TrackedFileSystem(inner, tracker: tracker, connection: c)
            },
            secrets: secrets)
        return await collect(stream)
    }

    @Test func classifiesAMixOfGoodAndBrokenConnections() async throws {
        let goodSFTP = await site("sftp", port: 2222)
        let kbdOnly = await site("kbd", port: 2224, auth: .keyboardInteractive)
        let goodFTP = await site("ftp", proto: .ftp, port: 2121)
        let listFTP = await site("vsftpd", proto: .ftp, port: 2122)
        let wrongPassword = await site("wrong", port: 2222, password: "not-the-password")
        let wrongFTP = await site("wrong-ftp", proto: .ftp, port: 2121, password: "not-the-password")
        let missingHost = await site("missing", host: "no-such-host.invalid", port: 22)
        let missingFTP = await site("missing-ftp", proto: .ftp, host: "no-such-host.invalid", port: 21)
        let closedPort = await site("closed", port: 2299)
        let noSecret = Connection(name: "nopw", host: Live.host, port: 2222, username: Live.user)
        let all = [goodSFTP, kbdOnly, goodFTP, listFTP, wrongPassword, wrongFTP, missingHost, missingFTP, closedPort, noSecret]

        let tracker = SessionTracker()
        let results = healthResults(await run(all, tracker: tracker))

        for c in [goodSFTP, kbdOnly, goodFTP, listFTP] {
            #expect(results[c.id]?.status == .ok, "\(c.name): \(results[c.id]?.message ?? "")")
            #expect(results[c.id]?.latencyMs != nil)
        }
        #expect(results[wrongPassword.id]?.status == .authFailed)
        #expect(results[wrongFTP.id]?.status == .authFailed)
        #expect(results[missingHost.id]?.status == .hostNotFound, "\(results[missingHost.id]?.message ?? "")")
        #expect(results[missingFTP.id]?.status == .hostNotFound, "\(results[missingFTP.id]?.message ?? "")")
        #expect(results[closedPort.id]?.status == .refused, "\(results[closedPort.id]?.message ?? "")")
        #expect(results[noSecret.id]?.status == .needsSecret)
        #expect(!tracker.connectOrder.contains(noSecret.id))
        for result in results.values {
            #expect(!(result.message ?? "").contains(Live.password))
            #expect(!(result.message ?? "").contains("not-the-password"))
        }
    }

    @Test func neverRunsMoreThanTwoSessionsPerHost() async {
        var connections: [Connection] = []
        for i in 0..<10 { connections.append(await site("s\(i)", port: 2222)) }
        connections.append(contentsOf: [await site("ftp1", proto: .ftp, port: 2121), await site("ftp2", proto: .ftp, port: 2122)])
        let tracker = SessionTracker()
        let results = healthResults(await run(connections, tracker: tracker))

        #expect(results.values.allSatisfy { $0.status == .ok })
        #expect(results.count == 12)
        #expect(tracker.peakPerHost[Live.host] == 2)
    }

    @Test func circuitBreakerStopsContactingAHostAfterThreeLoginFailures() async {
        var bad: [Connection] = []
        for i in 0..<10 { bad.append(await site("bad\(i)", port: 2222, password: "wrong-\(i)")) }
        let otherName = await site("good-by-another-name", host: "localhost", port: 2222)
        let tracker = SessionTracker()
        let events = await run(bad + [otherName], tracker: tracker)

        let results = healthResults(events)
        let contacted = tracker.connects[Live.host] ?? 0
        // Up to two more can already be in flight when the third failure arrives.
        #expect((3...4).contains(contacted))
        #expect(healthSkips(events).count == bad.count - contacted)
        #expect(results.values.filter { $0.status == .authFailed }.count == contacted)
        #expect(results[otherName.id]?.status == .ok, "\(results[otherName.id]?.message ?? "")")
    }
}
