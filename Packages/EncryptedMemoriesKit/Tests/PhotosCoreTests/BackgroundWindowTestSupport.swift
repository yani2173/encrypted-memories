import Foundation
import XCTest

@testable import PhotosCore

/// The value of `task`, or nil when it does not end within `limit`. A task that hangs is cancelled, so the test fails
/// instead of hanging.
func boundedValue<T: Sendable>(of task: Task<T, Never>, limit: Duration = .seconds(20)) async -> T? {
    let ended = AsyncTestSignal()
    let box = LockedValue<T>()
    let join = Task {
        box.set(await task.value)
        ended.fire()
    }
    guard await ended.wait(limit: limit) else {
        task.cancel()
        join.cancel()
        return nil
    }
    return box.value
}

/// Waits until `condition` holds, bounded, so a condition that never holds fails the test instead of hanging it.
func waitFor(_ condition: @escaping @Sendable () async -> Bool, limit: Duration = .seconds(20)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? { lock.withLock { stored } }

    func set(_ value: T) { lock.withLock { stored = value } }
}

/// Holds the coordinator's single permit, as a backup item does, until the test releases it.
final class HeldPermit: @unchecked Sendable {
    let entered = AsyncTestSignal()
    private let released = AsyncTestSignal()
    private var task: Task<Void, Never>?

    init(
        _ coordinator: LibraryResourceCoordinator,
        request: LibraryWorkRequest = .init(workload: .backupHashing, intent: .automatic)
    ) {
        task = Task { [entered, released] in
            _ = try? await coordinator.withHeavyPermit(request) { _ in
                entered.fire()
                await released.wait()
            }
        }
    }

    /// Lets the holder return. A holder that never got the permit stops waiting, so the release cannot hang.
    func release() async {
        released.fire()
        if !entered.hasFired { task?.cancel() }
        await task?.value
    }
}

extension XCTestCase {
    /// The limit for an event of the background-window tests: long enough for a loaded machine, short enough that a
    /// mutant that removes the event fails a phase in seconds instead of minutes.
    static let backgroundWindowEventLimit: Duration = .seconds(20)

    func awaitWindowEvent(
        _ signal: AsyncTestSignal, _ description: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let happened = await signal.wait(limit: Self.backgroundWindowEventLimit)
        XCTAssertTrue(happened, "\(description) did not happen", file: file, line: line)
    }
}
