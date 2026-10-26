import Foundation
import XCTest

@testable import PhotosCore

final class LibraryBackgroundWindowPermitTests: XCTestCase {
    private func window(_ opportunity: LibraryExecutionOpportunity = .backgroundPermitted) -> LibraryRuntimeState {
        LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: opportunity))
    }

    private func acquire(
        _ state: LibraryRuntimeState, _ coordinator: LibraryResourceCoordinator
    ) -> Task<LibraryBackgroundWindowPermit?, Never> {
        Task {
            await LibraryBackgroundWindowPermit.acquire(
                LibraryBackgroundWorkTuning.crawlBatch, coordinator: coordinator, runtimeState: state)
        }
    }

    func testTheForegroundTakesNoPermit() async {
        let state = window(.foregroundActive)
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let permit = await boundedValue(of: acquire(state, coordinator))
        XCTAssertTrue(permit != nil, "the acquisition returns at once")
        XCTAssertNil(permit ?? nil, "foreground work runs as before, without the coordinator")
        let acquired = await coordinator.metrics().permitsAcquired
        XCTAssertEqual(acquired, 0)
    }

    func testAPermitInTheWindowHoldsTheCoordinatorUntilItsRelease() async throws {
        let state = window()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let acquired = await boundedValue(of: acquire(state, coordinator))
        let permit = try XCTUnwrap(acquired ?? nil)
        let backup = HeldPermit(coordinator)
        let waiting = await waitFor { await coordinator.waitingPermitCount == 1 }
        XCTAssertTrue(waiting, "backup waits for the permit of the background work")

        permit.release()
        await awaitWindowEvent(backup.entered, "the backup item after the release")
        await backup.release()
    }

    func testTheEndOfTheWindowCancelsTheWaitForThePermit() async {
        let state = window()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let backup = HeldPermit(coordinator)
        await awaitWindowEvent(backup.entered, "the backup item")
        let waitingForPermit = acquire(state, coordinator)
        let queued = await waitFor { await coordinator.waitingPermitCount == 1 }
        XCTAssertTrue(queued, "the background work waits behind backup")

        state.update { $0.executionOpportunity = .foregroundActive }
        let permit = await boundedValue(of: waitingForPermit)
        XCTAssertTrue(permit != nil, "the wait ends with the window")
        XCTAssertNil(permit ?? nil)
        // The coordinator removes the cancelled waiter on its own actor, just after the wait returned.
        let cancelled = await waitFor { await coordinator.metrics().cancelledWaiters == 1 }
        XCTAssertTrue(cancelled, "the coordinator keeps no waiter behind")
        let waiting = await coordinator.waitingPermitCount
        XCTAssertEqual(waiting, 0)
        await backup.release()
    }

    func testAPermitStopsAtTheEndOfTheWindow() async throws {
        let state = window()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let acquired = await boundedValue(of: acquire(state, coordinator))
        let permit = try XCTUnwrap(acquired ?? nil)
        defer { permit.release() }
        let stop = Task { await permit.nextStop() }
        state.update { $0.executionOpportunity = .foregroundActive }
        let reason = await boundedValue(of: stop)
        XCTAssertEqual(reason, .some(.windowEnded))
    }

    func testAStepCheckSeesTheEndOfTheWindow() async throws {
        let state = window()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let acquired = await boundedValue(of: acquire(state, coordinator))
        let permit = try XCTUnwrap(acquired ?? nil)
        defer { permit.release() }
        XCTAssertFalse(permit.mustStop)
        state.update { $0.executionOpportunity = .foregroundActive }
        XCTAssertTrue(permit.mustStop, "a step loop stops when the window ends")
    }

    func testAStepCheckSeesTheLeaseYield() async throws {
        let state = window()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let acquired = await boundedValue(of: acquire(state, coordinator))
        let permit = try XCTUnwrap(acquired ?? nil)
        defer { permit.release() }
        XCTAssertFalse(permit.mustStop)
        state.update { $0.isLowPowerMode = true }
        XCTAssertTrue(permit.mustStop, "a step loop stops when the coordinator wants the permit back")
    }

    func testAPermitStopsWhenItsLeaseYields() async throws {
        let state = window()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let acquired = await boundedValue(of: acquire(state, coordinator))
        let permit = try XCTUnwrap(acquired ?? nil)
        defer { permit.release() }
        let stop = Task { await permit.nextStop() }
        state.update { $0.isLowPowerMode = true }
        let reason = await boundedValue(of: stop)
        XCTAssertEqual(reason, .some(.yielded(.lowPowerMode)))
    }
}
