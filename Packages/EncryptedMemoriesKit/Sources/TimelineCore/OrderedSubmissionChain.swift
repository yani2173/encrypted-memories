import Foundation

/// Runs submitted work one item after the other, in the order of submission. Hosts submit from synchronous code.
/// Separate unstructured tasks do not promise their order, so a pass end could reach the coordinator before the
/// upload signal that it must publish. Submitted work never waits for a refresh, so the chain stays short.
final class OrderedSubmissionChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func append(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await work()
            }
        }
    }

    /// Returns when all work that was submitted before this call has finished.
    func drain() async {
        await lock.withLock { tail }?.value
    }
}
