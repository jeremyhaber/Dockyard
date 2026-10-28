import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct ConnectionHealthStoreTests {
    private let clock = ManualClock()

    private func setup() throws -> (ConnectionRepository, ConnectionHealthRepository) {
        let db = try DockyardDatabase()
        return (ConnectionRepository(database: db, clock: clock), ConnectionHealthRepository(database: db))
    }

    private func result(_ id: UUID, _ status: HealthStatus, latency: Int? = nil, message: String? = nil) -> ConnectionHealth {
        ConnectionHealth(connectionId: id, status: status, latencyMs: latency, message: message, testedAt: clock.now())
    }

    @Test func recordsAndReturnsTheLatestPerConnection() async throws {
        let (connections, health) = try setup()
        let a = makeConn("A"), b = makeConn("B", host: "b")
        try await connections.save([a, b])
        try await health.record([result(a.id, .authFailed, message: "denied"), result(b.id, .ok, latency: 42)])
        clock.advance(by: 10)
        try await health.record(result(a.id, .ok, latency: 80))

        let latest = try await health.latest()
        #expect(latest[a.id]?.status == .ok && latest[a.id]?.latencyMs == 80)
        #expect(latest[b.id]?.status == .ok && latest[b.id]?.latencyMs == 42 && latest[b.id]?.testedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await health.history(for: a.id).map(\.status) == [.ok, .authFailed])
        #expect(try await health.latest(for: UUID()) == nil)
    }

    @Test func everyStatusRoundTrips() async throws {
        let (connections, health) = try setup()
        for status in HealthStatus.allCases {
            let c = makeConn(status.rawValue)
            try await connections.save(c)
            try await health.record(result(c.id, status, message: status.rawValue))
            #expect(try await health.latest(for: c.id)?.status == status)
        }
        #expect(HealthStatus.ok.isFailing == false)
        #expect(HealthStatus.allCases.filter(\.isFailing).count == HealthStatus.allCases.count - 1)
    }

    @Test func keepsOnlyRecentHistoryAndCascadesOnDelete() async throws {
        let (connections, health) = try setup()
        let c = makeConn()
        try await connections.save(c)
        for i in 0..<(ConnectionHealthRepository.historyLimit + 5) { try await health.record(result(c.id, .ok, latency: i)) }
        let history = try await health.history(for: c.id, limit: 100)
        #expect(history.count == ConnectionHealthRepository.historyLimit)
        #expect(history.first?.latencyMs == ConnectionHealthRepository.historyLimit + 4)

        try await connections.delete(c.id)
        #expect(try await health.latest().isEmpty)
    }

    @Test func clearForgetsResults() async throws {
        let (connections, health) = try setup()
        let a = makeConn("A"), b = makeConn("B", host: "b")
        try await connections.save([a, b])
        try await health.record([result(a.id, .ok), result(b.id, .ok)])
        try await health.clear(connectionIds: [a.id])
        #expect(try await health.latest().keys.sorted { $0.uuidString < $1.uuidString } == [b.id])
    }

    @Test func observeEmitsOnEveryChange() async throws {
        let (connections, health) = try setup()
        let c = makeConn()
        try await connections.save(c)
        let stream = health.observeLatest()
        #expect(await firstValues(stream, count: 1).first?.isEmpty == true)
        try await health.record(result(c.id, .timedOut))
        #expect(await firstValue(stream) { $0[c.id]?.status == .timedOut } != nil)
    }

    @Test func healthFilterSeparatesFailingOkAndUntested() async throws {
        let (connections, health) = try setup()
        let ok = makeConn("Ok", host: "ok"), bad = makeConn("Bad", host: "bad"), fixed = makeConn("Fixed", host: "fixed")
        let never = makeConn("Never", host: "never"), needs = makeConn("Needs", host: "needs")
        try await connections.save([ok, bad, fixed, never, needs])
        try await health.record([
            result(ok.id, .ok), result(bad.id, .hostNotFound), result(fixed.id, .authFailed), result(needs.id, .needsSecret),
        ])
        try await health.record(result(fixed.id, .ok))

        func ids(_ h: ConnectionFilter.Health?, search: String = "") async throws -> Set<UUID> {
            Set(try await connections.fetch(ConnectionFilter(search: search, health: h)).map(\.id))
        }
        #expect(try await ids(.failing) == [bad.id, needs.id])
        #expect(try await ids(.ok) == [ok.id, fixed.id])
        #expect(try await ids(.untested) == [never.id])
        #expect(try await ids(nil).count == 5)
        #expect(try await ids(.failing, search: "bad") == [bad.id])

        let stream = connections.observe(ConnectionFilter(health: .failing))
        #expect(await firstValue(stream) { Set($0.map(\.id)) == [bad.id, needs.id] } != nil)
        try await health.record(result(bad.id, .ok))
        #expect(await firstValue(stream) { Set($0.map(\.id)) == [needs.id] } != nil)
    }

    @Test func removedConnectionsDropOutOfTheHealthFilter() async throws {
        let (connections, health) = try setup()
        let bad = makeConn("Bad")
        try await connections.save(bad)
        try await health.record(result(bad.id, .refused))
        try await connections.softDelete(ids: [bad.id])
        #expect(try await connections.fetch(ConnectionFilter(health: .failing)).isEmpty)
        try await connections.restore(ids: [bad.id])
        #expect(try await connections.fetch(ConnectionFilter(health: .failing)).map(\.id) == [bad.id])
    }
}
