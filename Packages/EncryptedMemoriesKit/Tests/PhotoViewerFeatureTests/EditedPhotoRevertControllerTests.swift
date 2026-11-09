import PhotosCore
import XCTest

@testable import PhotoViewerCore

@MainActor
final class EditedPhotoRevertControllerTests: XCTestCase {
    private struct Boom: Error {}

    // MARK: - Confirmation

    func testRequestAsksForConfirmationAndWritesNothing() {
        let controller = EditedPhotoRevertController()
        controller.request()
        XCTAssertEqual(controller.phase, .confirming)
        XCTAssertTrue(controller.isConfirming)
        XCTAssertFalse(controller.showsFailure)
    }

    func testCancelChangesNothingAndTheNextConfirmStartsNothing() async {
        let controller = EditedPhotoRevertController()
        let runs = Counter()
        controller.request()
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)

        controller.confirm(perform: { await runs.increment() }, onSuccess: {})
        await controller.current?.value

        let count = await runs.value
        XCTAssertEqual(count, 0, "a cancelled confirmation never starts the revert")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testConfirmWithoutARequestStartsNothing() async {
        let controller = EditedPhotoRevertController()
        let runs = Counter()
        controller.confirm(perform: { await runs.increment() }, onSuccess: {})
        await controller.current?.value
        let count = await runs.value
        XCTAssertEqual(count, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Single flight

    /// A repeated tap on "Revert" while the first revert runs starts one revert only.
    func testARepeatedConfirmWhileTheRevertRunsStartsOneRevert() async {
        let controller = EditedPhotoRevertController()
        let runs = Counter()
        let gate = Gate()
        controller.request()
        controller.confirm(
            perform: {
                await runs.increment()
                await gate.wait()
            }, onSuccess: {})
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the revert did not start")
        XCTAssertEqual(controller.phase, .running)

        controller.confirm(perform: { await runs.increment() }, onSuccess: {})
        controller.request()
        XCTAssertEqual(controller.phase, .running, "a request while the revert runs changes nothing")
        await gate.open()
        await controller.current?.value

        let count = await runs.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Result

    func testSuccessEndsInIdleAndReportsOnce() async {
        let controller = EditedPhotoRevertController()
        var successes = 0
        controller.request()
        controller.confirm(perform: {}, onSuccess: { successes += 1 })
        await controller.current?.value
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.showsFailure)
    }

    /// A failure shows once and offers no retry: while it shows, neither a request nor a confirm starts anything.
    func testAFailureShowsOnceAndOffersNoRetry() async {
        let controller = EditedPhotoRevertController()
        let runs = Counter()
        var successes = 0
        controller.request()
        controller.confirm(
            perform: {
                await runs.increment()
                throw Boom()
            }, onSuccess: { successes += 1 })
        await controller.current?.value
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.showsFailure)
        XCTAssertEqual(successes, 0)

        controller.request()
        controller.confirm(perform: { await runs.increment() }, onSuccess: {})
        await controller.current?.value
        XCTAssertEqual(controller.phase, .failed, "no retry while the failure shows")
        let runsWhileFailed = await runs.value
        XCTAssertEqual(runsWhileFailed, 1)

        controller.dismissFailure()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.showsFailure, "the failure does not come back")
    }

    func testACancelledRevertEndsInIdleWithoutAFailure() async {
        let controller = EditedPhotoRevertController()
        controller.request()
        controller.confirm(perform: { throw CancellationError() }, onSuccess: {})
        await controller.current?.value
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.showsFailure)
    }

    func testDismissFailureDoesNothingOutsideAFailure() {
        let controller = EditedPhotoRevertController()
        controller.request()
        controller.dismissFailure()
        XCTAssertEqual(controller.phase, .confirming)
    }

    // MARK: - The revert of one photo

    private let main = PhotoItem(
        uid: PhotoUID(volumeID: "own", nodeID: "edited"), captureTime: Date(timeIntervalSince1970: 1),
        mediaType: "image/jpeg")
    private let original = PhotoItem(
        uid: PhotoUID(volumeID: "own", nodeID: "original"), captureTime: Date(timeIntervalSince1970: 1),
        mediaType: "image/heic")

    func testTheRevertOfOnePhotoCallsTheReverterThenTheHostWorkThenOnSuccess() async {
        let controller = EditedPhotoRevertController()
        let reverter = SpyReverter()
        let events = Events()
        controller.request()

        controller.confirm(
            main: main, original: original, reverter: reverter,
            onReverted: { photo in await events.add("reverted \(photo.uid.nodeID)") },
            onSuccess: { Task { await events.add("success") } })
        await controller.current?.value
        // `onSuccess` hops through a task; wait for its event.
        for _ in 0..<50 where await events.count < 2 { await Task.yield() }

        let calls = await reverter.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.main.uid, main.uid)
        XCTAssertEqual(calls.first?.original.uid, original.uid)
        let order = await events.all
        XCTAssertEqual(order, ["reverted edited", "success"], "the host work comes before the success callback")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAFailedRevertRunsNeitherTheHostWorkNorOnSuccess() async {
        let controller = EditedPhotoRevertController()
        let reverter = SpyReverter(error: Boom())
        let events = Events()
        controller.request()

        controller.confirm(
            main: main, original: original, reverter: reverter,
            onReverted: { _ in await events.add("reverted") },
            onSuccess: { Task { await events.add("success") } })
        await controller.current?.value
        await Task.yield()

        let order = await events.all
        XCTAssertEqual(order, [])
        XCTAssertEqual(controller.phase, .failed)
    }

    // MARK: - Paging

    func testPagingEndsAPendingConfirmationButNotARunningRevert() async {
        let controller = EditedPhotoRevertController()
        controller.request()
        controller.pageChanged()
        XCTAssertEqual(controller.phase, .idle)

        let gate = Gate()
        controller.request()
        controller.confirm(perform: { await gate.wait() }, onSuccess: {})
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the revert did not start")
        controller.pageChanged()
        XCTAssertEqual(controller.phase, .running, "a running revert goes on when the person pages")
        await gate.open()
        await controller.current?.value
    }

    /// The viewer closes while the revert runs. The production success closure captures the viewer, the viewer keeps its
    /// model, and the model keeps the controller, so the controller never goes away by itself: a weak reference alone
    /// does not stop the callback. The test captures the controller in `onSuccess` the way production does, and the
    /// viewer's teardown detaches it. The work that belongs to every outcome runs in `perform` and still happens.
    func testADetachedControllerRunsNoSuccessCallbackButTheHostWorkStillRuns() async {
        let controller = EditedPhotoRevertController()
        let gate = Gate()
        let callbacks = Counter()
        let hostWork = Counter()
        controller.request()
        controller.confirm(
            perform: {
                await gate.wait()
                await hostWork.increment()
            },
            onSuccess: { [controller] in
                _ = controller
                Task { await callbacks.increment() }
            })
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the revert did not start")

        controller.detach()
        await gate.open()
        await controller.current?.value
        for _ in 0..<20 { await Task.yield() }

        let work = await hostWork.value
        let count = await callbacks.value
        XCTAssertEqual(work, 1, "the host work of the revert runs although the viewer closed")
        XCTAssertEqual(count, 0, "a detached controller runs no success callback")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testDetachEndsAPendingConfirmationAndKeepsTheOtherPhases() async {
        let controller = EditedPhotoRevertController()
        controller.request()
        controller.detach()
        XCTAssertEqual(controller.phase, .idle)

        let gate = Gate()
        controller.request()
        controller.confirm(perform: { await gate.wait() }, onSuccess: {})
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the revert did not start")
        controller.detach()
        XCTAssertEqual(controller.phase, .running, "the revert goes on after the viewer closed")
        await gate.open()
        await controller.current?.value
    }

    /// The callback runs once. A viewer that is still open after a finished revert gets no second call.
    func testTheSuccessCallbackRunsExactlyOnce() async {
        let controller = EditedPhotoRevertController()
        let callbacks = Counter()
        controller.request()
        controller.confirm(perform: {}, onSuccess: { Task { await callbacks.increment() } })
        await controller.current?.value
        controller.request()
        controller.confirm(perform: {}, onSuccess: { Task { await callbacks.increment() } })
        await controller.current?.value
        for _ in 0..<20 { await Task.yield() }
        let count = await callbacks.value
        XCTAssertEqual(count, 2, "each confirmed revert reports once, and nothing reports twice")
    }

    /// The controller keeps the success callback only while the revert runs. Afterwards nothing keeps the viewer chain
    /// alive through it: the callback captures the viewer, and the viewer keeps its model and this controller.
    func testTheCallbackIsReleasedAfterASuccessAndAfterAFailure() async {
        for fails in [false, true] {
            let controller = EditedPhotoRevertController()
            weak var probe: Probe?
            do {
                let strong = Probe()
                probe = strong
                controller.request()
                controller.confirm(
                    perform: { if fails { throw Boom() } },
                    onSuccess: { [strong] in _ = strong })
            }
            await controller.current?.value
            XCTAssertNil(probe, "the controller released the callback after \(fails ? "a failure" : "a success")")
        }
    }

    /// A controller that went away without a detach also runs no callback. This pins the weak reference only; it does
    /// not capture the controller, so it cannot show the production chain (see the detach test above).
    func testAControllerThatWentAwayWithoutADetachRunsNoCallback() async {
        var controller: EditedPhotoRevertController? = EditedPhotoRevertController()
        let gate = Gate()
        let callbacks = Counter()
        controller?.request()
        controller?.confirm(perform: { await gate.wait() }, onSuccess: { Task { await callbacks.increment() } })
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the revert did not start")
        let task = controller?.current

        controller = nil
        await gate.open()
        await task?.value
        for _ in 0..<20 { await Task.yield() }

        let count = await callbacks.value
        XCTAssertEqual(count, 0, "a revert that ends after its controller went away runs no success callback")
    }

    // MARK: - Availability

    /// The revert belongs to the own library only: the viewer's mutation there is "Move to Trash". The Trash restores
    /// and a shared album saves to the library, so neither offers the revert.
    func testTheCommandNeedsAProvenOriginalTheOwnLibraryAndAReverter() {
        typealias C = EditedPhotoRevertController
        XCTAssertTrue(C.isAvailable(canShowOriginal: true, mutationAction: .moveToTrash, hasReverter: true))
        XCTAssertFalse(C.isAvailable(canShowOriginal: false, mutationAction: .moveToTrash, hasReverter: true))
        XCTAssertFalse(C.isAvailable(canShowOriginal: true, mutationAction: .restore, hasReverter: true))
        XCTAssertFalse(C.isAvailable(canShowOriginal: true, mutationAction: .saveToLibrary, hasReverter: true))
        XCTAssertFalse(C.isAvailable(canShowOriginal: true, mutationAction: nil, hasReverter: true))
        XCTAssertFalse(C.isAvailable(canShowOriginal: true, mutationAction: .moveToTrash, hasReverter: false))
    }

    func testTheCommandStartsOnlyFromIdle() {
        let controller = EditedPhotoRevertController()
        XCTAssertTrue(controller.canStart(canShowOriginal: true, mutationAction: .moveToTrash, hasReverter: true))
        XCTAssertFalse(controller.canStart(canShowOriginal: true, mutationAction: .restore, hasReverter: true))
        controller.request()
        XCTAssertFalse(
            controller.canStart(canShowOriginal: true, mutationAction: .moveToTrash, hasReverter: true),
            "no second start while the confirmation shows")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor SpyReverter: EditedPhotoReverting {
    struct Call {
        let main: PhotoItem
        let original: PhotoItem
    }
    private(set) var calls: [Call] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) { self.error = error }

    func revertToOriginal(of main: PhotoItem, original: PhotoItem) async throws {
        calls.append(Call(main: main, original: original))
        if let error { throw error }
    }
}

private actor Events {
    private(set) var all: [String] = []
    var count: Int { all.count }
    func add(_ event: String) { all.append(event) }
}

private final class Probe: Sendable {}
