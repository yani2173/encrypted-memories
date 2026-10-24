import Foundation
import PhotosCore
import XCTest

@testable import PhotoViewerCore

@MainActor
final class EditedPhotoOriginalLookupTests: XCTestCase {
    private let edited = item("edited")
    private let other = item("other")
    private let original = item("original", mediaType: "image/heic")

    // MARK: - Lookup

    func testTheAskStartsOnlyAfterThePhotoStaysForTheDwell() async throws {
        let (lookup, provider, dwell) = make()
        var found: [PhotoUID: PhotoUID] = [:]

        lookup.settled(on: edited, provider: provider) { base, original in found[base.uid] = original.uid }
        try await dwell.nextStart()
        let beforeDwell = await provider.asked
        XCTAssertEqual(beforeDwell, [])
        dwell.release()
        await mustFinish(lookup.pending)

        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
        XCTAssertEqual(found, [edited.uid: original.uid])
        XCTAssertEqual(dwell.requested, [EditedPhotoOriginalLookup.dwell])
    }

    func testPagingOnBeforeTheDwellAsksOnlyForTheNewPage() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: provider) { _, _ in }
        try await dwell.nextStart()
        lookup.settled(on: other, provider: provider) { _, _ in }
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)

        let asked = await provider.asked
        XCTAssertEqual(asked, [other.uid])
    }

    func testLivePhotosAndSeriesAskNothing() {
        let (lookup, provider, _) = make()
        let live = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "live"), captureTime: .distantPast, mediaType: "image/heic",
            isLivePhoto: true, relatedVideoID: "video")
        let series = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "series"), captureTime: .distantPast, mediaType: "image/heic",
            burstMemberIDs: ["series", "frame"])

        lookup.settled(on: live, provider: provider) { _, _ in }
        XCTAssertNil(lookup.pending)
        lookup.settled(on: series, provider: provider) { _, _ in }
        XCTAssertNil(lookup.pending)
    }

    func testAPhotoWithoutAProviderAsksNothing() {
        let (lookup, _, _) = make()
        lookup.settled(on: edited, provider: nil) { _, _ in }
        XCTAssertNil(lookup.pending)
    }

    func testEachPhotoIsAskedOncePerViewerAlsoWithoutAnOriginal() async throws {
        let (lookup, provider, dwell) = make(hasOriginal: false)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("no original") }
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)
        lookup.settled(on: other, provider: provider) { _, _ in }
        try await dwell.nextStart()
        lookup.settled(on: edited, provider: provider) { _, _ in }

        XCTAssertNil(lookup.pending)
        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
    }

    func testAnAskThatIsNotAdmittedWaitsAndStartsWhenTheAppAdmitsIt() async throws {
        let conditions = Conditions(admitted: false)
        let (lookup, provider, dwell) = make(conditions: conditions)
        var found: [PhotoUID: PhotoUID] = [:]

        lookup.settled(on: edited, provider: provider) { base, original in found[base.uid] = original.uid }
        try await dwell.nextStart()
        dwell.release()
        try await conditions.nextSubscription()
        let refused = await provider.asked
        XCTAssertEqual(refused, [])

        conditions.setAdmitted(true)
        await mustFinish(lookup.pending)

        let admitted = await provider.asked
        XCTAssertEqual(admitted, [edited.uid])
        XCTAssertEqual(found, [edited.uid: original.uid])
    }

    func testAnAskThatWaitsForAdmissionStopsWhenThePersonPagesOn() async throws {
        let conditions = Conditions(admitted: false)
        let (lookup, provider, dwell) = make(conditions: conditions)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("the page changed") }
        try await dwell.nextStart()
        dwell.release()
        try await conditions.nextSubscription()
        let waiting = lookup.pending
        lookup.settled(on: other, provider: provider) { _, _ in }
        let replacement = lookup.pending
        conditions.setAdmitted(true)
        await mustFinish(waiting)

        let asked = await provider.asked
        XCTAssertEqual(asked, [], "the new page is still in its dwell, the old page must not ask")
        lookup.cancel()
        await mustFinish(replacement)
    }

    func testAPhotoWithoutAProviderAsksWhenTheProviderBecomesAvailable() async throws {
        let (lookup, provider, dwell) = make()
        var found: [PhotoUID: PhotoUID] = [:]

        lookup.settled(on: edited, provider: nil) { base, original in found[base.uid] = original.uid }
        XCTAssertNil(lookup.pending)
        lookup.providerAvailable(provider)
        _ = try XCTUnwrap(lookup.pending, "no ask is scheduled")
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)

        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
        XCTAssertEqual(found, [edited.uid: original.uid])
    }

    func testOnlyThePhotoOnScreenWaitsForTheProvider() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: nil) { _, _ in XCTFail("the page changed") }
        lookup.settled(on: other, provider: nil) { _, _ in }
        lookup.providerAvailable(provider)
        _ = try XCTUnwrap(lookup.pending, "no ask is scheduled")
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)
        let asked = await provider.asked
        XCTAssertEqual(asked, [other.uid])

        lookup.settled(on: edited, provider: nil) { _, _ in }
        lookup.cancel()
        lookup.providerAvailable(provider)
        XCTAssertNil(lookup.pending, "a closed viewer asks nothing")
    }

    func testAFetchThatThrewLeavesThePhotoUnansweredAndTheNextVisitAsksAgain() async throws {
        let (lookup, provider, dwell) = make(failures: 1)
        var found: [PhotoUID: PhotoUID] = [:]

        lookup.settled(on: edited, provider: provider) { base, original in found[base.uid] = original.uid }
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)
        XCTAssertEqual(found, [:])

        lookup.settled(on: edited, provider: provider) { base, original in found[base.uid] = original.uid }
        _ = try XCTUnwrap(lookup.pending, "the unanswered photo asks again")
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)

        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid, edited.uid])
        XCTAssertEqual(found, [edited.uid: original.uid])
    }

    func testACancelAfterTheAdmissionWaitEndedAsksNothing() async throws {
        let conditions = Conditions(admitted: false)
        let (lookup, provider, dwell) = make(conditions: conditions)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("the page changed") }
        try await dwell.nextStart()
        dwell.release()
        try await conditions.nextSubscription()
        let task = lookup.pending
        // The wait ends on another thread. This test keeps the main actor until the cancel below, so the task cannot
        // continue between the end of the wait and the cancel.
        conditions.setAdmitted(true)
        try conditions.blockUntilAdmissionAnswered()
        lookup.cancel()
        await mustFinish(task)

        let asked = await provider.asked
        XCTAssertEqual(asked, [], "a photo that is no longer on screen must not be asked")
    }

    func testASuccessfulAnswerStaysWhenThePersonPagedOnDuringTheCall() async throws {
        let gate = Gate()
        let (lookup, provider, dwell) = make(gate: gate)
        var found: [PhotoUID: PhotoUID] = [:]

        lookup.settled(on: edited, provider: provider) { base, original in found[base.uid] = original.uid }
        try await dwell.nextStart()
        dwell.release()
        try await provider.waitUntilAsked()
        let task = lookup.pending
        lookup.cancel()
        await gate.open()
        await mustFinish(task)

        XCTAssertEqual(found, [edited.uid: original.uid], "the original is recorded by photo")
        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("answered") }
        XCTAssertNil(lookup.pending)
        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
    }

    func testASuccessfulAnswerWithoutAnOriginalStaysWhenThePersonPagedOnDuringTheCall() async throws {
        let gate = Gate()
        let (lookup, provider, dwell) = make(hasOriginal: false, gate: gate)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("no original") }
        try await dwell.nextStart()
        dwell.release()
        try await provider.waitUntilAsked()
        let task = lookup.pending
        lookup.cancel()
        await gate.open()
        await mustFinish(task)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("answered") }
        XCTAssertNil(lookup.pending)
        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
    }

    func testAnAnsweredPhotoIsNotAskedAgain() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: provider) { _, _ in }
        try await dwell.nextStart()
        dwell.release()
        await mustFinish(lookup.pending)
        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("answered") }
        lookup.providerAvailable(provider)

        XCTAssertNil(lookup.pending)
        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
    }

    func testACancelledDwellAsksNothing() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("cancelled") }
        try await dwell.nextStart()
        let task = lookup.pending
        lookup.cancel()
        dwell.release()
        await mustFinish(task)

        let asked = await provider.asked
        XCTAssertEqual(asked, [])
    }

    // MARK: - Cancellation at every later point
    //
    // Each test cancels after the links before it, and observes what the link under test alone prevents.

    func testACancelDuringTheDwellNeverEvaluatesTheAdmission() async throws {
        let conditions = Conditions(admitted: false)
        let (lookup, provider, dwell) = make(conditions: conditions)

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("cancelled") }
        try await dwell.nextStart()
        let task = lookup.pending
        lookup.cancel()
        let ended = await finishes(task)

        XCTAssertTrue(ended)
        XCTAssertEqual(conditions.readCount, 0, "a cancelled dwell must not reach the admission")
        XCTAssertEqual(conditions.subscriptionCount, 0)
        let asked = await provider.asked
        XCTAssertEqual(asked, [])
    }

    func testACancelRightAfterTheDwellEndedAsksNothing() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("cancelled") }
        try await dwell.nextStart()
        let task = lookup.pending
        // The dwell returns normally, and the cancel follows before the task continues: the main actor is not given
        // back in between. The admission is already true, so the wait ends without a stream.
        dwell.release()
        lookup.cancel()
        let ended = await finishes(task)

        XCTAssertTrue(ended)
        let asked = await provider.asked
        XCTAssertEqual(asked, [], "a photo that is no longer on screen must not be asked")
    }

    func testAChangeThatArrivesAfterTheCancelIsNotEvaluated() async throws {
        let conditions = Conditions(admitted: false)
        let started = Flag()
        let gate = Gate()
        // A stream that does not end on a cancel: it delivers the change that was already on its way.
        let (lookup, provider, dwell) = make(
            conditions: conditions,
            changes: {
                AsyncStream<Void>(unfolding: {
                    started.set()
                    await gate.wait()
                    return ()
                })
            })

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("cancelled") }
        try await dwell.nextStart()
        dwell.release()
        try await eventually { started.value }
        let task = lookup.pending
        let readsBefore = conditions.readCount
        lookup.cancel()
        conditions.setAdmitted(true)
        await gate.open()
        let ended = await finishes(task)

        XCTAssertTrue(ended)
        XCTAssertEqual(conditions.readCount, readsBefore, "a change after the cancel must not read the admission")
        let asked = await provider.asked
        XCTAssertEqual(asked, [])
    }

    func testAFinishingChangeStreamEndsTheWaitWithoutAnAsk() async throws {
        let conditions = Conditions(admitted: false)
        let (lookup, provider, dwell) = make(conditions: conditions, changes: { AsyncStream<Void> { $0.finish() } })

        lookup.settled(on: edited, provider: provider) { _, _ in XCTFail("never admitted") }
        try await dwell.nextStart()
        dwell.release()
        let task = lookup.pending
        let ended = await finishes(task)

        XCTAssertTrue(ended, "a finished stream must end the wait, not spin on it")
        let asked = await provider.asked
        XCTAssertEqual(asked, [])
    }

    func testAChangeThatLeavesTheAppNotAdmittedAsksNothing() async throws {
        let conditions = Conditions(admitted: false)
        let (lookup, provider, dwell) = make(conditions: conditions)

        lookup.settled(on: edited, provider: provider) { _, _ in }
        try await dwell.nextStart()
        dwell.release()
        try await conditions.nextSubscription()
        let readsBefore = conditions.readCount
        conditions.signal()
        try await eventually { conditions.readCount > readsBefore }
        let beforeAdmission = await provider.asked
        XCTAssertEqual(beforeAdmission, [], "the admission is read again after every change")

        conditions.setAdmitted(true)
        await mustFinish(lookup.pending)
        let afterAdmission = await provider.asked
        XCTAssertEqual(afterAdmission, [edited.uid])
    }

    // MARK: - Waiting photo

    func testAPageWithoutAPhotoDropsThePhotoThatWaitsForTheProvider() {
        let (lookup, provider, _) = make()

        lookup.settled(on: edited, provider: nil) { _, _ in XCTFail("the page changed") }
        lookup.settled(on: nil, provider: provider) { _, _ in XCTFail("no photo") }
        lookup.providerAvailable(provider)

        XCTAssertNil(lookup.pending)
    }

    func testTheProviderBecomingAvailableKeepsARunningAsk() async throws {
        let (lookup, provider, dwell) = make()

        lookup.settled(on: edited, provider: provider) { _, _ in }
        let task = try XCTUnwrap(lookup.pending)
        try await dwell.nextStart()
        lookup.providerAvailable(provider)
        XCTAssertEqual(lookup.pending, task, "nothing waits for the provider, so the running ask stays")
        dwell.release()
        await mustFinish(task)

        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid])
    }

    func testAPhotoThatIsNotAFitForAnOriginalNeverWaits() {
        let (lookup, provider, _) = make()
        let live = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "live"), captureTime: .distantPast, mediaType: "image/heic",
            isLivePhoto: true, relatedVideoID: "video")

        lookup.settled(on: live, provider: nil) { _, _ in XCTFail("a Live Photo has no original here") }
        lookup.providerAvailable(provider)

        XCTAssertNil(lookup.pending)
    }

    // MARK: - Default change stream

    func testTheDefaultChangeStreamForwardsEveryChangeOfTheRuntimeState() async throws {
        let shared = LibraryRuntimeState.shared
        let before = shared.snapshot().network
        defer { shared.update { $0.network = before } }
        let received = Counter()
        let consumer = Task {
            for await _ in EditedPhotoOriginalLookup.runtimeChanges() { received.increment() }
        }
        addTeardownBlock {
            consumer.cancel()
            if await !Self.boundedJoin(consumer) { XCTFail("the consumer of the default stream outlived its test") }
        }

        try await eventually { received.value >= 1 }
        for _ in 0..<2 {
            let seen = received.value
            shared.update { $0.network.isConstrained.toggle() }
            try await eventually { received.value > seen }
        }

        consumer.cancel()
        let ended = await finishes(consumer)
        XCTAssertTrue(ended, "the stream ends when its consumer is cancelled")
    }

    func testAnEarlierAskThatFinishesWhileTheReplacementDwellsIsNotAskedAgain() async throws {
        let gate = Gate()
        let (lookup, provider, dwell) = make(gate: gate)
        let found = Counter()

        lookup.settled(on: edited, provider: provider) { _, _ in found.increment() }
        try await dwell.nextStart()
        dwell.release()
        try await provider.waitUntilAsked()
        let first = lookup.pending
        // The person pages away and back while the first ask is still running. The photo is not answered yet.
        lookup.settled(on: edited, provider: provider) { _, _ in found.increment() }
        let replacement = try XCTUnwrap(lookup.pending, "the photo is not answered yet, so it dwells again")
        try await dwell.nextStart()
        await gate.open()
        await mustFinish(first)
        dwell.release()
        await mustFinish(replacement)

        let asked = await provider.asked
        XCTAssertEqual(asked, [edited.uid], "the first ask answered the photo; the replacement must not ask again")
        XCTAssertEqual(found.value, 1)
    }

    func testTheBoundedWaitReportsATimeoutAlsoWhenTheTaskEndsBecauseOfIt() async {
        for _ in 0..<200 {
            let stuck = CancelOnly()
            let ended = await Self.boundedJoin(stuck.start(), within: .milliseconds(1))
            XCTAssertFalse(ended, "a task that only the timeout ended did not finish by itself")
            XCTAssertTrue(stuck.wasCancelled)
        }
        let quick = Task<Void, Never> {}
        let quickEnded = await Self.boundedJoin(quick)
        XCTAssertTrue(quickEnded)
    }

    func testOnlyAnActiveForegroundOnAnUnconstrainedNetworkAdmitsTheAsk() {
        XCTAssertTrue(EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot()))
        for opportunity in [LibraryExecutionOpportunity.foregroundInactive, .backgroundPermitted, .suspended] {
            XCTAssertFalse(EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot(executionOpportunity: opportunity)))
        }
        XCTAssertFalse(
            EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot(network: LibraryNetworkState(isConstrained: true))))
        XCTAssertFalse(
            EditedPhotoOriginalLookup.admits(LibraryRuntimeSnapshot(network: LibraryNetworkState(isReachable: false))))
    }

    // MARK: - State

    func testAPageShowsItsOriginalOnlyAfterTheOriginalIsKnown() {
        var state = EditedPhotoOriginalState()
        state.toggle(edited.uid)
        XCTAssertFalse(state.canShowOriginal(of: edited.uid))
        XCTAssertEqual(state.displayed(edited), edited)

        state.record(original, of: edited.uid)
        XCTAssertTrue(state.canShowOriginal(of: edited.uid))
        XCTAssertEqual(state.displayed(edited), edited)
        state.toggle(edited.uid)
        XCTAssertTrue(state.isShowingOriginal(of: edited.uid))
        XCTAssertEqual(state.displayed(edited), original)
        state.toggle(edited.uid)
        XCTAssertEqual(state.displayed(edited), edited)
    }

    func testAnotherPageShowsTheEditedVersionAgainAndTheControlStays() {
        var state = EditedPhotoOriginalState()
        state.record(original, of: edited.uid)
        state.toggle(edited.uid)

        state.pageChanged(to: edited.uid)
        XCTAssertTrue(state.isShowingOriginal(of: edited.uid))
        state.pageChanged(to: other.uid)
        state.pageChanged(to: edited.uid)
        XCTAssertFalse(state.isShowingOriginal(of: edited.uid))
        XCTAssertTrue(state.canShowOriginal(of: edited.uid))
    }

    func testTheFirstFoundOriginalStays() {
        var state = EditedPhotoOriginalState()
        state.record(original, of: edited.uid)
        state.record(Self.item("later"), of: edited.uid)
        state.toggle(edited.uid)
        XCTAssertEqual(state.displayed(edited), original)
    }

    // MARK: - Helpers

    private static func item(_ nodeID: String, mediaType: String = "image/jpeg") -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: nodeID), captureTime: .distantPast, mediaType: mediaType)
    }

    private func make(
        hasOriginal: Bool = true, failures: Int = 0, gate: Gate? = nil,
        conditions: Conditions = Conditions(admitted: true),
        changes: (@Sendable () -> AsyncStream<Void>)? = nil
    ) -> (EditedPhotoOriginalLookup, Provider, ManualDwell) {
        let provider = Provider(original: hasOriginal ? original : nil, failures: failures, gate: gate)
        let dwell = ManualDwell()
        let lookup = EditedPhotoOriginalLookup(
            sleep: { try await dwell.sleep($0) }, admits: { conditions.admitted },
            changes: changes ?? { conditions.subscribe() })
        // Registered before any wait of the test can throw: a throw must not leave a task of this lookup behind.
        addTeardownBlock { [lookup, dwell] in
            let task = await MainActor.run { () -> Task<Void, Never>? in
                let task = lookup.pending
                lookup.cancel()
                return task
            }
            dwell.release()
            await gate?.open()
            if await !Self.boundedJoin(task) { XCTFail("a task of the lookup outlived its test") }
        }
        return (lookup, provider, dwell)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }

    /// A task that ends only when it is cancelled.
    private final class CancelOnly: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var cancelled = false

        var wasCancelled: Bool { lock.withLock { cancelled } }

        func start() -> Task<Void, Never> {
            Task {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let resumeNow = lock.withLock { () -> Bool in
                            if cancelled { return true }
                            waiter = continuation
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                } onCancel: {
                    let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        cancelled = true
                        defer { waiter = nil }
                        return waiter
                    }
                    held?.resume()
                }
            }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
    }

    /// Polls until the condition holds. Fails when it does not within the limit.
    private func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ConditionNotMet() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for a task, with a limit. A task that does not end by itself is cancelled, so that no task outlives the
    /// test, and the result is false.
    private func finishes(_ task: Task<Void, Never>?, within timeout: Duration = .seconds(10)) async -> Bool {
        await Self.boundedJoin(task, within: timeout)
    }

    /// The result comes from the recorded timeout, not from the child that ends first: the cancel that follows the
    /// timeout can end a cancellation-responsive task before the timer child returns.
    private nonisolated static func boundedJoin(
        _ task: Task<Void, Never>?, within timeout: Duration = .seconds(10)
    ) async -> Bool {
        guard let task else { return true }
        let timedOut = Flag()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return }
                timedOut.set()
                task.cancel()
            }
            await group.next()
            group.cancelAll()
        }
        return !timedOut.value
    }

    /// Waits for a task with the same limit as `finishes`. A task that does not end fails the test and is cancelled,
    /// so that no task outlives the test and a broken lookup fails instead of hanging.
    private func mustFinish(
        _ task: Task<Void, Never>?, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let ended = await finishes(task)
        XCTAssertTrue(ended, "the task did not end within the limit", file: file, line: line)
    }

    private struct ConditionNotMet: Error {}
    private struct FetchFailed: Error {}
    private struct NoSubscription: Error {}
    private struct NotAsked: Error {}
    private struct NoStart: Error {}

    /// Holds a call of the provider open until the test opens the gate.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    private actor Provider: EditedPhotoOriginalProviding {
        let original: PhotoItem?
        private let gate: Gate?
        private var failuresLeft: Int
        private(set) var asked: [PhotoUID] = []

        init(original: PhotoItem?, failures: Int, gate: Gate? = nil) {
            self.original = original
            self.gate = gate
            failuresLeft = failures
        }

        func editedOriginal(of item: PhotoItem) async throws -> PhotoItem? {
            asked.append(item.uid)
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw FetchFailed()
            }
            if let gate { await gate.wait() }
            return original
        }

        /// Waits until a call arrived. Fails when none arrives within the limit.
        func waitUntilAsked(timeout: Duration = .seconds(10)) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while asked.isEmpty {
                guard ContinuousClock.now < deadline else { throw NotAsked() }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// The admission of the ask, and the stream that reports its changes. A change is yielded to every subscriber.
    private final class Conditions: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        private var continuations: [AsyncStream<Void>.Continuation] = []
        private var subscribed = 0
        private var trueReads = 0
        private var reads = 0

        init(admitted: Bool) { stored = admitted }

        var admitted: Bool {
            lock.withLock {
                reads += 1
                if stored { trueReads += 1 }
                return stored
            }
        }

        /// How often the lookup read the admission.
        var readCount: Int { lock.withLock { reads } }
        var subscriptionCount: Int { lock.withLock { subscribed } }

        /// Reports a change to every subscriber without changing the admission.
        func signal() {
            let targets = lock.withLock { continuations }
            for target in targets { target.yield() }
        }

        /// Blocks the calling thread, on purpose, until `admits` answered true once. The main actor stays occupied, so a
        /// task of the lookup cannot continue after its admission wait ended until the caller gives the actor back.
        func blockUntilAdmissionAnswered(timeout: Duration = .seconds(10)) throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while lock.withLock({ trueReads }) == 0 {
                guard ContinuousClock.now < deadline else { throw NoSubscription() }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        func subscribe() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            lock.withLock {
                continuations.append(continuation)
                subscribed += 1
            }
            return stream
        }

        /// Waits until the ask waits for a change of the conditions. Fails when it does not within the limit.
        func nextSubscription(timeout: Duration = .seconds(10)) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while lock.withLock({ subscribed }) == 0 {
                guard ContinuousClock.now < deadline else { throw NoSubscription() }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func setAdmitted(_ value: Bool) {
            let targets = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
                stored = value
                return continuations
            }
            for target in targets { target.yield() }
        }
    }

    /// A dwell that ends only when the test releases it, and that reports when a wait starts.
    private final class ManualDwell: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var durations: [Duration] = []
        private var starts = 0
        private var consumedStarts = 0

        var requested: [Duration] { lock.withLock { durations } }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let cancelled = lock.withLock { () -> Bool in
                        guard !Task.isCancelled else { return true }
                        waiters[id] = continuation
                        durations.append(duration)
                        starts += 1
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }

        /// Waits until a dwell starts. Fails when none starts within the limit.
        func nextStart(timeout: Duration = .seconds(10)) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while lock.withLock({ starts == consumedStarts }) {
                guard ContinuousClock.now < deadline else { throw NoStart() }
                try await Task.sleep(for: .milliseconds(5))
            }
            lock.withLock { consumedStarts += 1 }
        }

        func release() {
            let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { waiters = [:] }
                return Array(waiters.values)
            }
            for waiter in released { waiter.resume() }
        }
    }
}
