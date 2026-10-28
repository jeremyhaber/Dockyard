import ConnectionKit
import DockyardCore
import Foundation

/// Demo screens for connection health and Recently removed. Demo mode only; nothing is contacted.
@MainActor
extension AppModel {
    /// Mixed results from a test that is about two thirds through, so the manager shows every status.
    func seedHealthDemo() async {
        func result(_ n: Int, _ status: HealthStatus, ms: Int? = nil, message: String? = nil, minutes: Double = 3) -> ConnectionHealth {
            ConnectionHealth(
                connectionId: DemoSeeder.id(n), status: status, latencyMs: ms, message: message,
                testedAt: DemoMode.anchor.addingTimeInterval(-minutes * 60))
        }
        var results = [
            result(1, .ok, ms: 142), result(2, .ok, ms: 88), result(3, .ok, ms: 231),
            result(4, .authFailed, message: "Authentication failed"),
            result(5, .ok, ms: 312), result(6, .timedOut, message: "No answer within 15 seconds"),
            result(300, .ok, ms: 96), result(301, .refused, message: "Connection refused"),
            result(302, .hostNotFound, message: "Cannot resolve test.example.org"),
            result(200, .ok, ms: 120), result(201, .ok, ms: 175), result(202, .ok, ms: 64),
            result(203, .timedOut, message: "No answer within 15 seconds"),
        ]
        let fine = [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 14]
        for (offset, i) in fine.enumerated() { results.append(result(100 + i, .ok, ms: 70 + (offset * 37) % 220, minutes: 2)) }
        results += [
            result(107, .removedFromSource, message: "No longer listed by its WHM server", minutes: 2),
            result(111, .authFailed, message: "Authentication failed", minutes: 1.5),
            result(113, .needsSecret, message: "No password stored", minutes: 1.5),
            result(115, .hostKeyChanged, message: "The host key does not match the one you trusted before", minutes: 1),
            result(116, .hostKeyChanged, message: HealthMessages.unknownHostKey, minutes: 1),
            result(117, .authFailed, message: "Authentication failed", minutes: 0.5),
            result(118, .authFailed, message: "Authentication failed", minutes: 0.5),
        ]
        try? await healthRepository.record(results)
        health.seedDemoRun(
            total: allConnections.count, completed: results.count + 2,
            testing: [DemoSeeder.id(121), DemoSeeder.id(122)], paused: [DemoSeeder.id(119), DemoSeeder.id(120)])
    }

    /// Five removed connections, one of them close to the 30 day limit.
    func seedRemovedDemo() async {
        let hour = 3_600.0, day = 86_400.0
        let removed: [(Int, Double)] = [(300, hour), (201, 2 * day), (206, 5 * day), (302, 12 * day), (200, 27 * day)]
        for (n, age) in removed {
            let when = Date().addingTimeInterval(-age)
            try? await connections.update(DemoSeeder.id(n)) { $0.deletedAt = when }
        }
    }
}
