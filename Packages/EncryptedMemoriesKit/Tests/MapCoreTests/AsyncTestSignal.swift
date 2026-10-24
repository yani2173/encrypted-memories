import Foundation

/// A one-shot event that a test awaits instead of a wall-clock limit: the test continues when the event happens, so a
/// slow machine only makes it slower. `happens()` has an upper bound that only ends a hung test.
final class AsyncTestSignal: @unchecked Sendable {
    /// The limit only ends a hung test. Machine load never reaches it.
    static let hangLimit: Duration = .seconds(300)

    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func fire() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            fired = true
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        resumed.forEach { $0.resume() }
    }

    var hasFired: Bool { lock.withLock { fired } }

    /// Returns when the event has happened, or when the awaiting task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if fired || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// False when the event did not happen within the hang limit.
    func happens() async -> Bool {
        if hasFired { return true }
        return await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: Self.hangLimit) }
            await group.next()
            group.cancelAll()
            return hasFired
        }
    }
}

/// Checks `condition` on the main actor until it holds. The limit only ends a hung test.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + AsyncTestSignal.hangLimit
    // The pause between checks is a poll interval, not a limit: it keeps the wait from holding a core.
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
}
