/// FIFO mutual exclusion across suspension points, used to serialize commands on one control connection.
final class AsyncLock: @unchecked Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = LockedBox(State())

    func withLock<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let mustWait = state.withLock { state -> Bool in
                if state.locked {
                    state.waiters.append(continuation)
                    return true
                }
                state.locked = true
                return false
            }
            if !mustWait { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.locked = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
