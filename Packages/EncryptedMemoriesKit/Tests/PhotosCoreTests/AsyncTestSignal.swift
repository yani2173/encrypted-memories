import Foundation
import XCTest

/// A one-shot event that a test awaits instead of a wall-clock limit: the test continues when the event happens, so a
/// slow machine only makes it slower. `wait(limit:)` has an upper bound that only ends a hung test.
final class AsyncTestSignal: @unchecked Sendable {
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

    var hasFired: Bool { lock.withLock { fired } }

    /// False when the event did not happen within `limit`. Use a limit that only a hung test can reach.
    func wait(limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first && hasFired
        }
    }
}

extension XCTestCase {
    /// The limit only ends a hung test. Machine load never reaches it.
    static let hangLimit: Duration = .seconds(300)

    func awaitEvent(
        _ signal: AsyncTestSignal, _ description: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let happened = await signal.wait(limit: Self.hangLimit)
        XCTAssertTrue(happened, "\(description) did not happen", file: file, line: line)
    }
}
