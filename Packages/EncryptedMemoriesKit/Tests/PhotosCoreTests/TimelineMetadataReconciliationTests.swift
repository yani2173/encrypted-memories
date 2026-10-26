import Foundation
import XCTest

@testable import PhotosCore

final class TimelineMetadataReconciliationTests: XCTestCase {
    private func fixture() throws -> ReconciliationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try ReconciliationFixture(url: directory.appendingPathComponent("order.sqlite"))
    }

    private func inventory(_ count: Int, library: String = "first") -> TimelineMetadataReconciliation.Inventory {
        .init(
            items: (0..<count).map {
                PhotoItem(
                    uid: PhotoUID(volumeID: library, nodeID: String(format: "%04d", $0)),
                    captureTime: Date(timeIntervalSince1970: 500), mediaType: "image/jpeg")
            }, classifiedNodeIDs: [], libraryID: library)
    }

    // MARK: - Background window

    private func runtimeState(_ opportunity: LibraryExecutionOpportunity) -> LibraryRuntimeState {
        LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: opportunity))
    }

    /// A coordinator of its own per test, which follows the runtime state as the app's shared one does.
    private func coordinator(_ state: LibraryRuntimeState) async -> LibraryResourceCoordinator {
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        return coordinator
    }

    func testAPassRunsInABackgroundWindowUnderTheHeavyPermit() async {
        let state = runtimeState(.backgroundPermitted)
        let coordinator = await coordinator(state)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
        let log = PassLog()
        reconciliation.schedule(inventory(2)) { await log.start($0) }
        await awaitWindowEvent(log.started, "the pass in the background window")
        await joinCurrentPass(reconciliation)
        let acquired = await coordinator.metrics().permitsAcquired
        XCTAssertEqual(acquired, 1, "the pass ran under the coordinator's permit")
        // The coordinator records the release when the permit's holder returns, just after the pass.
        let released = await waitFor { await coordinator.metrics().permitsReleased == 1 }
        XCTAssertTrue(released, "the pass gave the permit back")
        let started = await log.count
        XCTAssertEqual(started, 1)
    }

    func testAPassWaitsWhileTheAppIsSuspended() async {
        let state = runtimeState(.suspended)
        let coordinator = await coordinator(state)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
        let log = PassLog()
        reconciliation.schedule(inventory(2)) { await log.start($0) }
        await awaitHeldSnapshots(1, in: reconciliation)
        let held = await log.count
        XCTAssertEqual(held, 0, "no pass starts while the app is suspended")

        state.update { $0.executionOpportunity = .foregroundActive }
        await awaitWindowEvent(log.started, "the pass after the foreground return")
        await joinCurrentPass(reconciliation)
        let started = await log.count
        XCTAssertEqual(started, 1, "the foreground return starts exactly one pass")
        XCTAssertEqual(reconciliation.heldSnapshotCount, 1, "one check per runtime change")
    }

    func testAForegroundPassTakesNoPermit() async {
        for opportunity in [LibraryExecutionOpportunity.foregroundActive, .foregroundInactive] {
            let state = runtimeState(opportunity)
            let coordinator = await coordinator(state)
            let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
            let log = PassLog()
            reconciliation.schedule(inventory(2)) { await log.start($0) }
            await awaitWindowEvent(log.started, "the pass in the foreground")
            await joinCurrentPass(reconciliation)
            let acquired = await coordinator.metrics().permitsAcquired
            XCTAssertEqual(acquired, 0, "the foreground pass runs as before, without the coordinator")
        }
    }

    func testAPassRunsAtOnceWhileTheAppIsInTheForegroundButInactive() async {
        // A Mac app behind another window, or an iPhone app under Control Center, is not in a background window.
        let reconciliation = TimelineMetadataReconciliation(runtimeState: runtimeState(.foregroundInactive))
        let log = PassLog()
        reconciliation.schedule(inventory(2)) { await log.start($0) }
        let ran = await log.started.wait(limit: .seconds(20))
        XCTAssertTrue(ran, "the pass starts at once")
        // A pass that waits would keep the task alive; retiring it lets the test end.
        if !ran { reconciliation.retire() }
        await joinCurrentPass(reconciliation)
        XCTAssertEqual(reconciliation.heldSnapshotCount, 0)
    }

    func testLowPowerModeInABackgroundWindowKeepsThePassWaitingWithoutPolling() async {
        let state = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(isLowPowerMode: true, executionOpportunity: .backgroundPermitted))
        let coordinator = await coordinator(state)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
        let log = PassLog()
        reconciliation.schedule(inventory(2)) { await log.start($0) }
        let queued = await waitFor { await coordinator.waitingPermitCount == 1 }
        XCTAssertTrue(queued, "the pass waits in the coordinator's queue")
        let held = await log.count
        XCTAssertEqual(held, 0, "Low Power Mode refuses background work")

        state.update { $0.isLowPowerMode = false }
        await awaitWindowEvent(log.started, "the pass after Low Power Mode ends")
        await joinCurrentPass(reconciliation)
        let started = await log.count
        XCTAssertEqual(started, 1)
    }

    func testAPendingPassRunsUnderThePermitWhenTheAppEnteredTheBackgroundDuringTheFirstPass() async {
        let state = runtimeState(.foregroundActive)
        let coordinator = await coordinator(state)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
        let log = PassLog()
        let firstRunning = AsyncTestSignal()
        let releaseFirst = AsyncTestSignal()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { pass in
            await log.start(pass)
            if pass.inventory.items.count == 2 {
                firstRunning.fire()
                _ = await releaseFirst.wait(limit: Self.hangLimit)
            }
        }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitWindowEvent(firstRunning, "the first pass")
        state.update { $0.executionOpportunity = .backgroundPermitted }
        reconciliation.schedule(inventory(3), operation: operation)
        releaseFirst.fire()
        await joinCurrentPass(reconciliation)
        let started = await log.count
        XCTAssertEqual(started, 2)
        let acquired = await coordinator.metrics().permitsAcquired
        XCTAssertEqual(acquired, 1, "only the pass in the background window took the permit")
    }

    func testABackupItemStopsTheBackgroundPassWhichRunsAgainWithTheSameInventory() async {
        let state = runtimeState(.backgroundPermitted)
        let coordinator = await coordinator(state)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
        let order = OrderLog()
        let firstRunning = AsyncTestSignal()
        reconciliation.schedule(inventory(2)) { pass in
            let run = await order.append("pass \(pass.inventory.items.count)")
            guard run == 1 else { return }
            firstRunning.fire()
            // The first run waits until the stop cancels it, as the bridge's page loop does.
            await waitUntilCancelled()
            await order.append(Task.isCancelled ? "pass stopped" : "pass not stopped")
        }
        await awaitWindowEvent(firstRunning, "the background pass")
        let backup = HeldPermit(coordinator)
        await awaitWindowEvent(backup.entered, "the backup item")
        await order.append("backup")
        await backup.release()
        await joinCurrentPass(reconciliation)
        let entries = await order.entries
        XCTAssertEqual(entries, ["pass 2", "pass stopped", "backup", "pass 2"])
    }

    func testTheEndOfTheWindowStopsThePassAndTheForegroundRepeatsNoSavedPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try MIMEReconciliationFixture(
            directory: directory, useOrderCache: true, holdsTheSecondPageOfTheFirstPass: true)
        let state = runtimeState(.backgroundPermitted)
        let coordinator = await coordinator(state)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state, coordinator: coordinator)
        reconciliation.schedule(inventory(302)) { await fixture.run($0, reconciliation: reconciliation) }
        await awaitWindowEvent(fixture.requested, "the second page of the background pass")

        state.update { $0.executionOpportunity = .foregroundActive }
        await joinCurrentPass(reconciliation)
        let result = try await fixture.result()
        XCTAssertEqual(result.requests.count, 2, "the stopped pass ran again in the foreground")
        let firstPage = Set(try XCTUnwrap(result.requests.first?.first))
        let repeated = result.requests.last?.flatMap { $0 }.filter { firstPage.contains($0) } ?? []
        XCTAssertTrue(repeated.isEmpty, "the saved first page is not requested again")
        XCTAssertEqual(result.classified, 302, "the foreground pass completes the library")
        XCTAssertTrue(result.pending.isEmpty)
        await fixture.close()
    }

    func testRetiringAWaitingPassEndsItWithoutAStart() async {
        let reconciliation = TimelineMetadataReconciliation(runtimeState: runtimeState(.suspended))
        let log = PassLog()
        reconciliation.schedule(inventory(2)) { await log.start($0) }
        await awaitHeldSnapshots(1, in: reconciliation)
        reconciliation.retire()
        await joinCurrentPass(reconciliation)
        let started = await log.count
        XCTAssertEqual(started, 0)
    }

    func testALibraryReplacementWhileAPassWaitsStartsOnlyTheNewLibrary() async {
        let state = runtimeState(.suspended)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state)
        let log = PassLog()
        reconciliation.schedule(inventory(2, library: "first")) { await log.start($0) }
        await awaitHeldSnapshots(1, in: reconciliation)
        reconciliation.schedule(inventory(2, library: "second")) { await log.start($0) }
        await awaitHeldSnapshots(2, in: reconciliation)

        state.update { $0.executionOpportunity = .foregroundActive }
        await awaitEvent(log.started, "the pass of the new library")
        await joinCurrentPass(reconciliation)
        let libraries = await log.libraries
        XCTAssertEqual(libraries, ["second"])
    }

    func testAHeldPassResumesWhenTheAppReturnsToAnInactiveForeground() async {
        let state = runtimeState(.suspended)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state)
        let log = PassLog()
        reconciliation.schedule(inventory(2)) { await log.start($0) }
        await awaitHeldSnapshots(1, in: reconciliation)

        // The app comes back under Control Center: in the foreground, but not active.
        state.update { $0.executionOpportunity = .foregroundInactive }
        let ran = await log.started.wait(limit: .seconds(20))
        XCTAssertTrue(ran, "an inactive foreground runs the held pass")
        if !ran { reconciliation.retire() }
        await joinCurrentPass(reconciliation)
    }

    func testAPassThatEndsInTheBackgroundLeavesNoWaiterBehind() async {
        let state = runtimeState(.foregroundActive)
        let reconciliation = TimelineMetadataReconciliation(runtimeState: state)
        let running = AsyncTestSignal()
        let release = AsyncTestSignal()
        reconciliation.schedule(inventory(2)) { _ in
            running.fire()
            _ = await release.wait(limit: Self.hangLimit)
        }
        await awaitEvent(running, "the pass")
        // The join holds the running task; the app leaves the foreground before the pass ends without a follow-up.
        let joined = AsyncTestSignal()
        let entered = AsyncTestSignal()
        let join = Task {
            entered.fire()
            await reconciliation.waitForCurrentPass()
            joined.fire()
        }
        await awaitEvent(entered, "the join")
        for _ in 0..<20 { await Task.yield() }
        state.update { $0.executionOpportunity = .backgroundPermitted }
        release.fire()

        let ended = await joined.wait(limit: .seconds(20))
        XCTAssertTrue(ended, "the task ends when no pass is owed")
        XCTAssertEqual(reconciliation.heldSnapshotCount, 0, "no waiter holds the background")
        if !ended {
            reconciliation.retire()
            join.cancel()
        }
    }

    func testFrequentChangesPublishTheActiveSnapshotAndOnlyOneLatestFollowUp() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { pass in
            await fixture.run(pass)
        }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        for count in 3...12 { reconciliation.schedule(inventory(count), operation: operation) }
        let beforeRelease = await fixture.counts()
        XCTAssertEqual(beforeRelease.started, 1, "inventory changes must not displace the network phase")
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 2, "one change series must produce exactly one follow-up")
        XCTAssertEqual(result.cancelled, 0)
        XCTAssertEqual(result.published.map(\.count), [2, 12], "the original snapshot must publish before the latest")
        await fixture.close()
    }

    func testQueuedPassDoesNotRepeatCompletedMIMERequests() async throws {
        try await assertQueuedMIMERequests(useOrderCache: true)
    }

    func testQueuedMIMEFallbackDoesNotRepeatCompletedRequests() async throws {
        try await assertQueuedMIMERequests(useOrderCache: false)
    }

    private func assertQueuedMIMERequests(useOrderCache: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try MIMEReconciliationFixture(directory: directory, useOrderCache: useOrderCache)
        let reconciliation = TimelineMetadataReconciliation()
        let initial = inventory(302)
        let latest = inventory(303)
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = {
            await fixture.run($0, reconciliation: reconciliation)
        }
        reconciliation.schedule(initial, operation: operation)
        await awaitEvent(fixture.requested, "the first MIME request")
        // B is queued before A commits its first MIME response.
        reconciliation.schedule(latest, operation: operation)
        let before = try await fixture.result()
        XCTAssertEqual(before.requests.map(\.count), [1])
        XCTAssertEqual(before.classified, 0)
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = try await fixture.result()
        XCTAssertEqual(result.requests.map(\.count), [3, 1], "B must request only the newly added photo")
        XCTAssertEqual(result.requests.last?.flatMap { $0 }, [latest.items.last!.uid])
        XCTAssertEqual(
            result.requests.flatMap { $0 }.flatMap { $0 }.count, 303, "completed MIME checks must not repeat")
        XCTAssertEqual(result.classified, 303)
        XCTAssertEqual(result.images, 152)
        XCTAssertEqual(result.videos, 151)
        XCTAssertTrue(result.pending.isEmpty, "completed checkpoints must remain complete")
        await fixture.close()
    }

    func testReturningToTheActiveInventoryDropsAnObsoleteFollowUp() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        reconciliation.schedule(inventory(3), operation: operation)
        reconciliation.schedule(inventory(2), operation: operation)
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.cancelled, 0)
        XCTAssertEqual(result.published.map(\.count), [2])
        await fixture.close()
    }

    func testRepeatedIdenticalInventoriesKeepTheHeldRequest() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        let initial = inventory(2)
        reconciliation.schedule(initial, operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        let reversed = TimelineMetadataReconciliation.Inventory(
            items: Array(initial.items.reversed()), classifiedNodeIDs: [], libraryID: initial.libraryID)
        for _ in 0..<20 { reconciliation.schedule(reversed, operation: operation) }
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.cancelled, 0)
        XCTAssertEqual(result.published.map(\.count), [2])
        await fixture.close()
    }

    func testNewPhotosStayVisibleInFallbackOrderBeforePublication() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let initial = inventory(2)
        let latest = inventory(5)
        reconciliation.schedule(initial) { await fixture.run($0) }
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        reconciliation.schedule(latest) { await fixture.run($0) }
        let visible = await fixture.enrich(latest.items)
        XCTAssertEqual(visible.map(\.uid), latest.items.map(\.uid))
        XCTAssertTrue(visible.allSatisfy { $0.timelineOrder == nil })
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.published.map(\.count), [2, 5])
        XCTAssertEqual(result.published.last?.first?.uid, latest.items.last?.uid)
        await fixture.close()
    }

    func testLogoutCancelsThePassAndDiscardsThePendingInventory() async throws {
        try await assertRetirement()
    }

    func testAccountReplacementCancelsTheOldPassAndDiscardsItsPendingInventory() async throws {
        try await assertRetirement()
        let replacement = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        await replacement.release()
        reconciliation.schedule(inventory(2, library: "replacement")) { await replacement.run($0) }
        await reconciliation.waitForCurrentPass()
        let result = await replacement.result()
        XCTAssertEqual(result.published.map(\.count), [2])
        XCTAssertEqual(result.published.first?.first?.uid.volumeID, "replacement")
        await replacement.close()
    }

    private func assertRetirement() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        for count in 3...12 { reconciliation.schedule(inventory(count), operation: operation) }
        // The same account admission barrier is used by the production owner before teardown.
        fixture.admission.closeAdmission()
        reconciliation.retire()
        await fixture.admission.closeAdmissionAndJoin()
        await reconciliation.waitForCurrentPass()
        reconciliation.schedule(inventory(13), operation: operation)
        let result = await fixture.result()
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.cancelled, 1, "cancellation must finish without releasing the held network request")
        XCTAssertTrue(result.published.isEmpty)
        await fixture.close()
    }

    func testRetirementCancellationHandlerCanReadTheCoordinator() async {
        await assertCancellationOutsideLock(replacingLibrary: false)
    }

    func testLibraryReplacementCancellationHandlerCanReadTheCoordinator() async {
        await assertCancellationOutsideLock(replacingLibrary: true)
    }

    private func assertCancellationOutsideLock(replacingLibrary: Bool) async {
        let reconciliation = TimelineMetadataReconciliation()
        let started = AsyncTestSignal()
        let finished = AsyncTestSignal()
        reconciliation.schedule(inventory(2)) { pass in
            await withTaskCancellationHandler {
                started.fire()
                try? await Task.sleep(for: .seconds(30))
            } onCancel: {
                let queried = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    XCTAssertFalse(reconciliation.isCurrent(pass))
                    queried.signal()
                }
                // The query is a plain read; the bound only ends a deadlock, so machine load never reaches it.
                XCTAssertEqual(
                    queried.wait(timeout: .now() + 60), .success,
                    "cancellation handlers must be able to read the coordinator without waiting for its lock")
            }
            finished.fire()
        }
        await awaitEvent(started, "the registration of the cancellation handler")
        if replacingLibrary {
            reconciliation.schedule(inventory(2, library: "second")) { _ in }
        } else {
            reconciliation.retire()
        }
        await awaitEvent(finished, "the end of the cancelled pass")
        await reconciliation.waitForCurrentPass()
    }

    func testLibraryReplacementCancelsThePassAndDropsTheOldFollowUp() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        for count in 3...12 { reconciliation.schedule(inventory(count), operation: operation) }
        reconciliation.schedule(inventory(3, library: "second"), operation: operation)
        await awaitEvent(fixture.cancelled, "the cancellation of the old pass")
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 2)
        XCTAssertEqual(result.cancelled, 1)
        XCTAssertEqual(result.published.map(\.count), [3])
        XCTAssertTrue(result.published.flatMap { $0 }.allSatisfy { $0.uid.volumeID == "second" })
        await fixture.close()
    }
}

private actor ReconciliationFixture {
    nonisolated let started = AsyncTestSignal()
    nonisolated let cancelled = AsyncTestSignal()
    nonisolated let admission = JoinedShutdownGate()
    private let store: TimelineOrderMetadataStore
    private var startedCount = 0
    private var cancelledCount = 0
    private var publications: [[PhotoItem]] = []
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(url: URL) throws { store = try XCTUnwrap(TimelineOrderMetadataStore(url: url)) }

    nonisolated func run(_ pass: TimelineMetadataReconciliation.Pass) async {
        _ = try? await admission.withAdmission { await self.perform(pass) }
    }

    private func perform(_ pass: TimelineMetadataReconciliation.Pass) async {
        startedCount += 1
        let items = pass.inventory.items
        guard await store.synchronizeInChunks(items, isClassified: { _ in true }) else { return }
        if startedCount == 1 { started.fire() }
        do {
            try await networkRequest()
            try Task.checkCancellation()
            let metadata = Dictionary(
                uniqueKeysWithValues: items.enumerated().map { index, item in
                    (
                        item.uid,
                        TimelineOrderMetadata(
                            exactCaptureTime: item.captureTime.addingTimeInterval(0.1),
                            stableIdentity: String(format: "%04d", 1000 - index))
                    )
                })
            XCTAssertTrue(store.record(metadata))
            XCTAssertTrue(try store.publishCompletedSeconds())
            publications.append(store.enrich(items))
        } catch is CancellationError {
            cancelledCount += 1
            if cancelledCount == 1 { cancelled.fire() }
        } catch {
            XCTFail("unexpected pass failure: \(error)")
        }
    }

    private func networkRequest() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if released { return }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func release() {
        released = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func counts() -> (started: Int, cancelled: Int) { (startedCount, cancelledCount) }
    func result() -> (started: Int, cancelled: Int, published: [[PhotoItem]]) {
        (startedCount, cancelledCount, publications)
    }
    func enrich(_ items: [PhotoItem]) -> [PhotoItem] { store.enrich(items) }
    func close() async {
        await admission.closeAdmissionAndJoin()
        store.close()
    }
}

private actor MIMEReconciliationFixture {
    nonisolated let requested = AsyncTestSignal()
    private let timeline: TimelineMetadataStore
    private let order: TimelineOrderMetadataStore?
    private var requests: [[[PhotoUID]]] = []
    private var response: CheckedContinuation<Void, Never>?
    private var released = false
    /// The first pass waits at its second page until it is cancelled, after it saved its first page.
    private let holdsTheSecondPageOfTheFirstPass: Bool

    init(directory: URL, useOrderCache: Bool, holdsTheSecondPageOfTheFirstPass: Bool = false) throws {
        self.holdsTheSecondPageOfTheFirstPass = holdsTheSecondPageOfTheFirstPass
        timeline = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        order =
            useOrderCache
            ? try XCTUnwrap(TimelineOrderMetadataStore(url: directory.appendingPathComponent("order.sqlite"))) : nil
    }

    func run(_ pass: TimelineMetadataReconciliation.Pass, reconciliation: TimelineMetadataReconciliation) async {
        let reader = TimelineMetadataPageReader(inventory: pass.inventory, orderStore: order, timelineStore: timeline)
        requests.append([])
        let index = requests.count - 1
        do {
            try await reader.prepare(isCurrent: { reconciliation.isCurrent(pass) })
            while true {
                let page = try await reader.nextPage(isCurrent: { reconciliation.isCurrent(pass) })
                if page.isEmpty { break }
                requests[index].append(page.map(\.uid))
                if holdsTheSecondPageOfTheFirstPass {
                    if index == 0, requests[index].count == 2 {
                        requested.fire()
                        await waitUntilCancelled()
                        return
                    }
                } else if index == 0, requests[index].count == 1, !released {
                    await withCheckedContinuation {
                        response = $0
                        requested.fire()
                    }
                }
                let evidence = Dictionary(
                    uniqueKeysWithValues: page.map {
                        ($0.uid, Int($0.uid.nodeID)!.isMultiple(of: 2) ? "image/jpeg" : "video/mp4")
                    })
                XCTAssertTrue(timeline.recordMediaTypeEvidence(evidence, publishRevision: false).succeeded)
                if let order {
                    let metadata = Dictionary(
                        uniqueKeysWithValues: page.filter(\.needsOrder).map { ($0.uid, TimelineOrderMetadata()) })
                    XCTAssertTrue(order.record(metadata, classifiedUIDs: Set(evidence.keys)))
                }
            }
            if let order { _ = try order.publishCompletedSeconds() }
        } catch { XCTFail("unexpected MIME reconciliation failure: \(error)") }
    }

    func release() {
        released = true
        response?.resume()
        response = nil
    }

    func result() throws -> (requests: [[[PhotoUID]]], classified: Int, images: Int, videos: Int, pending: [PhotoUID]) {
        let evidence = try XCTUnwrap(timeline.mediaTypeEvidence(volumeID: "first"))
        return (
            requests, evidence.count,
            evidence.values.filter { $0 == "image/jpeg" }.count,
            evidence.values.filter { $0 == "video/mp4" }.count,
            try order?.nextPage().map(\.uid) ?? []
        )
    }

    func close() {
        order?.close()
        timeline.close()
    }
}

/// The order of events across a pass and other work. `append` returns how often the entry occurred so far.
private actor OrderLog {
    private(set) var entries: [String] = []

    @discardableResult
    func append(_ entry: String) -> Int {
        entries.append(entry)
        return entries.filter { $0 == entry }.count
    }
}

/// Returns when the awaiting task is cancelled.
private func waitUntilCancelled() async {
    await AsyncTestSignal().wait()
}

/// The passes that started, by library.
private actor PassLog {
    nonisolated let started = AsyncTestSignal()
    private(set) var libraries: [String?] = []

    var count: Int { libraries.count }

    func start(_ pass: TimelineMetadataReconciliation.Pass) {
        libraries.append(pass.inventory.libraryID)
        started.fire()
    }
}

extension XCTestCase {
    /// Joins the current pass, bounded: a pass that never ends fails here and is retired instead of hanging the test.
    func joinCurrentPass(
        _ reconciliation: TimelineMetadataReconciliation, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let joined = AsyncTestSignal()
        let join = Task {
            await reconciliation.waitForCurrentPass()
            joined.fire()
        }
        let ended = await joined.wait(limit: .seconds(20))
        XCTAssertTrue(ended, "the pass did not end", file: file, line: line)
        if !ended {
            reconciliation.retire()
            join.cancel()
        }
    }

    /// A pass that is held evaluates each runtime snapshot once; this waits for the expected number. It is bounded,
    /// so a pass that never waits fails here instead of hanging.
    func awaitHeldSnapshots(
        _ count: Int, in reconciliation: TimelineMetadataReconciliation, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while reconciliation.heldSnapshotCount < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            reconciliation.heldSnapshotCount, count, "the pass did not wait for the runtime state", file: file,
            line: line)
    }
}
