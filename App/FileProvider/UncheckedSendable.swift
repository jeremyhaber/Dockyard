/// Carries a non-Sendable File Provider callback into a `Task`. The system hands these
/// to us and accepts calls from any thread; Swift 6.2 no longer accepts
/// `nonisolated(unsafe)` locals captured by a sending closure.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
