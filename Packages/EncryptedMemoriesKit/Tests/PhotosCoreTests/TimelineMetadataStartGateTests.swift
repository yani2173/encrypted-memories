import Foundation
import XCTest

@testable import PhotosCore

/// The first full remote index build and the timeline metadata pass both read the whole library. The pass waits for
/// the build, but never longer than the gate's limits. The tests hold the gate's waits and release them, so no
/// assertion depends on how fast the machine is.
final class TimelineMetadataStartGateTests: XCTestCase {
    private let inventory = TimelineMetadataReconciliation.Inventory(
        items: [
            PhotoItem(
                uid: PhotoUID(volumeID: "library", nodeID: "0001"), captureTime: Date(timeIntervalSince1970: 500),
                mediaType: "image/jpeg")
        ], classifiedNodeIDs: [], libraryID: "library")

    func testThePassStartsOnlyAfterTheBuildEnds() async {
        let waits = HeldWaits()
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: waits.sleep)
        let reconciliation = TimelineMetadataReconciliation(startGate: gate)
        let events = StartGateEvents()
        let started = AsyncTestSignal()
        gate.buildStarted()
        reconciliation.schedule(inventory) { _ in
            await events.append("pass")
            started.fire()
        }
        // The pass is waiting in the gate once the gate's limit timer is running.
        let waiting = await waits.waitUntilRequested(1)
        XCTAssertTrue(waiting, "the gate never started its limit timer")
        guard waiting else { return }
        XCTAssertFalse(started.hasFired, "the pass must wait for the build")
        await events.append("build ended")
        gate.open()
        await awaitEvent(started, "the start of the pass")
        let log = await events.entries
        XCTAssertEqual(log, ["build ended", "pass"])
        reconciliation.retire()
        await reconciliation.waitForCurrentPass()
    }

    func testAnOpenGateStillWaitsWhileTheAppIsSuspended() async {
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: HeldWaits().sleep)
        gate.open()
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .suspended))
        let reconciliation = TimelineMetadataReconciliation(startGate: gate, runtimeState: state)
        let started = AsyncTestSignal()
        reconciliation.schedule(inventory) { _ in started.fire() }
        await awaitHeldSnapshots(1, in: reconciliation)
        XCTAssertFalse(started.hasFired, "an open gate does not start the pass while the app is suspended")

        state.update { $0.executionOpportunity = .foregroundActive }
        await awaitEvent(started, "the pass after the foreground return")
        reconciliation.retire()
        await joinCurrentPass(reconciliation)
    }

    func testThePassNeedsTheGateAndAnAppThatIsNotSuspendedInEitherOrder() async {
        let waits = HeldWaits()
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: waits.sleep)
        gate.buildStarted()
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundActive))
        let reconciliation = TimelineMetadataReconciliation(startGate: gate, runtimeState: state)
        let started = AsyncTestSignal()
        reconciliation.schedule(inventory) { _ in started.fire() }
        let waiting = await waits.waitUntilRequested(1)
        XCTAssertTrue(waiting, "the gate never started its limit timer")
        XCTAssertFalse(started.hasFired, "a closed gate holds the pass in the foreground")

        // The app is suspended before the build ends; the gate opens then.
        state.update { $0.executionOpportunity = .suspended }
        gate.open()
        await awaitHeldSnapshots(1, in: reconciliation)
        XCTAssertFalse(started.hasFired, "the open gate does not start the pass while the app is suspended")

        state.update { $0.executionOpportunity = .foregroundActive }
        await awaitEvent(started, "the pass after the foreground return")
        reconciliation.retire()
        await joinCurrentPass(reconciliation)
    }

    func testABuildThatDoesNotStartReleasesThePassAfterTheStartLimit() async {
        let waits = HeldWaits()
        let started = await passStarts(
            gate: TimelineMetadataStartGate(startLimit: .milliseconds(300), limit: .seconds(60), sleep: waits.sleep),
            waits: waits, releasing: 1)
        XCTAssertTrue(started, "the start limit must release the pass")
        let requested = await waits.requested
        XCTAssertEqual(requested, [.milliseconds(300)], "no build started, so only the start limit applies")
    }

    func testARunningBuildHoldsThePassAtMostForTheLimit() async {
        let waits = HeldWaits()
        let gate = TimelineMetadataStartGate(startLimit: .seconds(2), limit: .seconds(3), sleep: waits.sleep)
        gate.buildStarted()
        let started = await passStarts(gate: gate, waits: waits, releasing: 2)
        XCTAssertTrue(started, "the limit must release the pass")
        let requested = await waits.requested
        XCTAssertEqual(
            requested, [.seconds(2), .seconds(1)],
            "a started build is not bound by the start limit, and the total wait is the limit")
    }

    func testAnOpenGateStartsThePassAsBefore() async {
        let waits = HeldWaits()
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: waits.sleep)
        gate.open()
        let started = await passStarts(gate: gate, waits: waits, releasing: 0)
        XCTAssertTrue(started)
        let requested = await waits.requested
        XCTAssertEqual(requested, [], "an open gate waits for nothing")
    }

    func testRetirementEndsAHeldPassWithoutRunningIt() async {
        let waits = HeldWaits()
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: waits.sleep)
        let reconciliation = TimelineMetadataReconciliation(startGate: gate)
        let events = StartGateEvents()
        reconciliation.schedule(inventory) { _ in await events.append("pass") }
        let waiting = await waits.waitUntilRequested(1)
        XCTAssertTrue(waiting, "the gate never started its limit timer")
        reconciliation.retire()
        let joined = AsyncTestSignal()
        let join = Task {
            await reconciliation.waitForCurrentPass()
            joined.fire()
        }
        await awaitEvent(joined, "the shutdown joining the held pass")
        join.cancel()
        let log = await events.entries
        XCTAssertEqual(log, [])
    }

    /// Schedules a pass behind `gate`, releases `releasing` of the gate's waits one by one, and reports whether the
    /// pass started. Before the last release the pass must still be held.
    private func passStarts(gate: TimelineMetadataStartGate, waits: HeldWaits, releasing: Int) async -> Bool {
        let reconciliation = TimelineMetadataReconciliation(startGate: gate)
        let started = AsyncTestSignal()
        reconciliation.schedule(inventory) { _ in started.fire() }
        if releasing > 0 {
            for index in 1...releasing {
                let requested = await waits.waitUntilRequested(index)
                XCTAssertTrue(requested, "the gate never asked for wait \(index)")
                guard requested else {
                    reconciliation.retire()
                    await reconciliation.waitForCurrentPass()
                    return false
                }
                XCTAssertFalse(started.hasFired, "the pass must be held until wait \(index) ends")
                await waits.releaseNext()
            }
        }
        let happened = await started.wait(limit: Self.hangLimit)
        // A pass that is still held must not outlive the test.
        reconciliation.retire()
        await reconciliation.waitForCurrentPass()
        return happened
    }
}

/// The gate's sleeper: every wait is recorded and held until the test releases it.
private final class HeldWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []
    private var held: [CheckedContinuation<Void, any Error>] = []
    private var counters: [(count: Int, signal: AsyncTestSignal)] = []

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await hold(duration) }
    }

    var requested: [Duration] {
        get async { lock.withLock { durations } }
    }

    private func hold(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked under the lock: a cancellation handler that already ran cannot leave this wait held.
                let ready = lock.withLock { () -> [AsyncTestSignal]? in
                    if Task.isCancelled { return nil }
                    durations.append(duration)
                    held.append(continuation)
                    let ready = counters.filter { $0.count <= durations.count }
                    counters.removeAll { $0.count <= durations.count }
                    return ready.map(\.signal)
                }
                guard let ready else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                ready.forEach { $0.fire() }
            }
        } onCancel: {
            // The gate cancels its timer when it opens; a held wait ends then.
            let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                defer { held = [] }
                return held
            }
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    /// Returns false when the gate has not asked for `count` waits within the hang limit.
    func waitUntilRequested(_ count: Int) async -> Bool {
        let signal = AsyncTestSignal()
        let ready = lock.withLock { () -> Bool in
            if durations.count >= count { return true }
            counters.append((count, signal))
            return false
        }
        if ready { return true }
        return await signal.wait(limit: XCTestCase.hangLimit)
    }

    func releaseNext() async {
        let next = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        next?.resume()
    }
}

private actor StartGateEvents {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
