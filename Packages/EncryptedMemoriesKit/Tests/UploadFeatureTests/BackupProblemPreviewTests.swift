import CoreGraphics
import Photos
import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadFeature

@MainActor
final class BackupProblemPreviewTests: XCTestCase {
    func testUnusedModelRegistersNoMemoryResponder() {
        let governor = MemoryPressureGovernor()
        do {
            let model = BackupProblemPreviewModel(memoryGovernor: governor) { _ in nil }
            XCTAssertEqual(governor.responderCount, 0, "construction must not register a responder")
            withExtendedLifetime(model) {}
        }
        XCTAssertEqual(governor.responderCount, 0, "dropping an unopened model needs no deferred cleanup")
    }

    func testRelatedResourcesMapToOnePhotoAndFilesHaveNoPreview() {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "photo")
        let related = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "photo", resource: .livePairedVideo)
        XCTAssertEqual(BackupProblemPreviewModel.uid(for: source), uid("photo"))
        XCTAssertEqual(BackupProblemPreviewModel.uid(for: related), uid("photo"))
        XCTAssertNil(BackupProblemPreviewModel.uid(for: .init(kind: .fileURL, identifier: "file")))
        XCTAssertNil(BackupProblemPreviewModel.uid(for: nil))
        XCTAssertNil(BackupProblemPreviewModel.uid(for: .init(kind: .photoLibraryAsset, identifier: "")))
    }

    func testCacheEvictsByDecodedByteCostAndRejectsAnOversizedImage() async throws {
        let recorder = PreviewRecorder()
        let image = try bitmap(side: 10, rowBytes: 128)
        let model = BackupProblemPreviewModel(costLimit: image.bytesPerRow * image.height, load: recorder.load)
        model.open()
        defer { model.close() }
        let a = Task { await model.thumbnail(for: uid("a")) }
        await recorder.started("a", test: self)
        recorder.finish("a", image)
        let loaded = await a.value
        XCTAssertNotNil(loaded)
        let cached = await model.thumbnail(for: uid("a"))
        XCTAssertTrue(cached === image)
        XCTAssertEqual(recorder.requests, ["a"])
        let b = Task { await model.thumbnail(for: uid("b")) }
        await recorder.started("b", test: self)
        recorder.finish("b", image)
        _ = await b.value
        XCTAssertNil(model.cachedImage(for: uid("a")))
        XCTAssertNotNil(model.cachedImage(for: uid("b")))
        let big = Task { await model.thumbnail(for: uid("big")) }
        await recorder.started("big", test: self)
        recorder.finish("big", try bitmap(side: 20))
        _ = await big.value
        XCTAssertNil(model.cachedImage(for: uid("big")))
    }

    func testCloseAndMemoryPressureReleaseCacheAndRejectLateResults() async throws {
        for close in [false, true] {
            let governor = MemoryPressureGovernor()
            let recorder = PreviewRecorder()
            let model = BackupProblemPreviewModel(memoryGovernor: governor, load: recorder.load)
            model.open()
            let a = Task { await model.thumbnail(for: uid("a")) }
            await recorder.started("a", test: self)
            recorder.finish("a", try bitmap(side: 10))
            _ = await a.value
            let late = Task { await model.thumbnail(for: uid("late")) }
            await recorder.started("late", test: self)
            if close { model.close() } else { governor.update(.init(pressure: .critical)) }
            XCTAssertNil(model.cachedImage(for: uid("a")))
            _ = await late.value
            recorder.finish("late", try bitmap(side: 10))
            XCTAssertNil(model.cachedImage(for: uid("late")))
            model.close()
            XCTAssertEqual(governor.responderCount, 0)
        }
    }

    func testRecycledRowNeverShowsThePreviousImageOrItsLateResult() async throws {
        let recorder = PreviewRecorder()
        let state = LocalPhotoThumbnailState()
        let a = Task { await state.load(uid("a"), using: recorder.load) }
        await recorder.started("a", test: self)
        let b = Task { await state.load(uid("b"), using: recorder.load) }
        await recorder.started("b", test: self)
        recorder.finish("b", try bitmap(side: 10))
        _ = await b.value
        XCTAssertNotNil(state.image(for: uid("b")))
        XCTAssertNil(state.image(for: uid("a")))
        recorder.finish("a", try bitmap(side: 20))
        _ = await a.value
        XCTAssertEqual(state.image(for: uid("b"))?.width, 10)
        XCTAssertNil(state.image(for: uid("next")))
    }

    func testLocalOnlyRequestsNeverEnableCloudWhileDefaultKeepsNetworkAccess() async {
        for (localOnly, fresh) in [(false, false), (true, false), (false, true), (true, true)] {
            let calls = ImageRequestRecorder()
            var loader =
                localOnly
                ? PhotoKitLocalThumbnailLoader(request: calls.request, networkMode: .localOnly)
                : PhotoKitLocalThumbnailLoader(request: calls.request)
            loader.fetchAssets = { _ in [PreviewAsset(fresh: fresh)] }
            _ = await loader.listThumbnail(for: uid("asset"))
            XCTAssertEqual(calls.allowed, [!localOnly])
            XCTAssertEqual(calls.sizes, [CGSize(width: 120, height: 120)])
        }
    }

    func testLongListStartsOnlyFourLoadsAndCancelsRowsThatLeave() async {
        let recorder = PreviewRecorder()
        let model = BackupProblemPreviewModel(load: recorder.load)
        model.open()
        let tasks = (0..<40).map { index in Task { await model.thumbnail(for: uid("row-\(index)")) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.pendingWaiterCount != 40, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.pendingWaiterCount, 40)
        // The queued rows do not start a PhotoKit request until a running request ends.
        let started = expectation(description: "first four loaders started")
        Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while recorder.requests.count < 4, ContinuousClock.now < deadline { await Task.yield() }
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(recorder.requests.count, 4)
        model.close()
        for task in tasks { _ = await task.value }
        XCTAssertEqual(recorder.requests.count, 4)
        XCTAssertEqual(model.pendingWaiterCount, 0)
    }

    func testPressurePreventsRecachingUntilTheGovernorRecovers() async throws {
        for pressure in [MemoryConditions.Pressure.warning, .critical] {
            let governor = MemoryPressureGovernor()
            let recorder = PreviewRecorder()
            let model = BackupProblemPreviewModel(memoryGovernor: governor, load: recorder.load)
            model.open()
            governor.update(.init(pressure: pressure))
            let reduced = Task { await model.thumbnail(for: uid("reduced")) }
            await recorder.started("reduced", test: self)
            recorder.finish("reduced", try bitmap(side: 10))
            _ = await reduced.value
            XCTAssertNil(model.cachedImage(for: uid("reduced")))
            governor.update(.init())
            let recovered = Task { await model.thumbnail(for: uid("recovered")) }
            await recorder.started("recovered", test: self)
            recorder.finish("recovered", try bitmap(side: 10))
            _ = await recovered.value
            XCTAssertNotNil(model.cachedImage(for: uid("recovered")))
            model.close()
        }
    }

    func testProblemListFactoryNeverEnablesNetworkAccess() async {
        for fresh in [false, true] {
            let calls = ImageRequestRecorder()
            var loader = PhotoKitLocalThumbnailLoader.problemListPreviews(request: calls.request)
            loader.fetchAssets = { _ in [PreviewAsset(fresh: fresh)] }
            _ = await loader.listThumbnail(for: uid("asset"))
            XCTAssertEqual(calls.allowed, [false])
            XCTAssertEqual(calls.sizes, [CGSize(width: 120, height: 120)])
        }
    }

    func testExcludedRowKeepsImageAcrossDisappearanceButNotIdentityChange() async throws {
        let state = LocalPhotoThumbnailState()
        let image = try bitmap(side: 10)
        await state.load(uid("a"), retainingImage: true) { _ in image }
        state.clear(retainingImage: true)
        XCTAssertTrue(state.image(for: uid("a")) === image)
        let recorder = PreviewRecorder()
        let refresh = Task { await state.load(uid("a"), retainingImage: true, using: recorder.load) }
        await recorder.started("a", test: self)
        XCTAssertTrue(state.image(for: uid("a")) === image)
        state.clear(retainingImage: true)
        recorder.finish("a", try bitmap(side: 20))
        await refresh.value
        XCTAssertEqual(state.image(for: uid("a"))?.width, 10)
        let next = Task { await state.load(uid("b"), retainingImage: true, using: recorder.load) }
        await recorder.started("b", test: self)
        XCTAssertNil(state.image(for: uid("a")))
        XCTAssertNil(state.image(for: uid("b")))
        recorder.finish("b", image)
        await next.value
        XCTAssertTrue(state.image(for: uid("b")) === image)
        state.clear()
        XCTAssertNil(state.image(for: uid("b")))
    }

    func testOldRequestCannotFinishNewRequestForTheSamePhotoAfterReopen() async throws {
        let recorder = ControlledPreviewRecorder()
        let model = BackupProblemPreviewModel(load: recorder.load)
        model.open()
        defer {
            model.close()
            recorder.finishAll()
        }
        let old = Task { await model.thumbnail(for: uid("same")) }
        await eventually { recorder.requests.count == 1 }
        model.close()
        _ = await old.value
        model.open()
        let current = Task { await model.thumbnail(for: uid("same")) }
        await eventually { recorder.requests.count == 2 }
        recorder.finish(0, try bitmap(side: 20))
        await eventually { recorder.returned.contains(0) }
        let joined = Task { await model.thumbnail(for: uid("same")) }
        await eventually { model.pendingWaiterCount == 2 || model.cachedImage(for: self.uid("same")) != nil }
        XCTAssertEqual(model.pendingWaiterCount, 2)
        XCTAssertNil(model.cachedImage(for: uid("same")))
        recorder.finish(1, try bitmap(side: 10))
        let currentImage = await current.value
        let joinedImage = await joined.value
        XCTAssertEqual(currentImage?.width, 10)
        XCTAssertEqual(joinedImage?.width, 10)
        XCTAssertEqual(recorder.requests, ["same", "same"])
    }

    func testCoalescingRetainsAnotherRowsRequestAndLastCancellationEndsIt() async {
        let recorder = ControlledPreviewRecorder()
        let model = BackupProblemPreviewModel(load: recorder.load)
        model.open()
        defer {
            model.close()
            recorder.finishAll()
        }
        let first = Task { await model.thumbnail(for: uid("same")) }
        await eventually { recorder.requests.count == 1 }
        let secondDone = expectation(description: "second waiter returns")
        let second = Task {
            _ = await model.thumbnail(for: uid("same"))
            secondDone.fulfill()
        }
        await eventually { model.pendingWaiterCount == 2 }
        first.cancel()
        _ = await first.value
        // The actor's cancellation operation has removed the first waiter before it returns here.
        XCTAssertEqual(model.pendingWaiterCount, 1)
        XCTAssertFalse(recorder.cancellation.contains(0), "another row still owns the admitted load")
        second.cancel()
        await fulfillment(of: [secondDone], timeout: 2)
        await eventually { recorder.cancellation.contains(0) }
        XCTAssertEqual(model.pendingWaiterCount, 0)
    }

    func testCancellingAnAdmittedRowStartsTheQueuedRow() async {
        let recorder = ControlledPreviewRecorder()
        let model = BackupProblemPreviewModel(load: recorder.load)
        model.open()
        defer {
            model.close()
            recorder.finishAll()
        }
        var tasks: [Task<CGImage?, Never>] = []
        for index in 0..<4 {
            tasks.append(Task { await model.thumbnail(for: uid("row-\(index)")) })
            await eventually { recorder.requests.count == index + 1 }
        }
        tasks.append(Task { await model.thumbnail(for: uid("queued")) })
        await eventually { model.pendingWaiterCount == 5 }
        XCTAssertEqual(recorder.requests.count, 4)
        tasks[0].cancel()
        _ = await tasks[0].value
        await eventually { recorder.requests.contains("queued") }
        XCTAssertTrue(recorder.cancellation.contains(0))
        XCTAssertTrue(recorder.requests.contains("queued"), "cancellation must release an admission slot")
        model.close()
        for task in tasks { _ = await task.value }
    }

    func testCloseAndGovernorReductionCancelAdmittedLoads() async {
        for conditions in [
            MemoryConditions?.none, .init(pressure: .critical), .init(isBackgrounded: true), .init(thermal: .serious),
        ] {
            let recorder = ControlledPreviewRecorder()
            let governor = MemoryPressureGovernor()
            let model = BackupProblemPreviewModel(memoryGovernor: governor, load: recorder.load)
            model.open()
            let task = Task { await model.thumbnail(for: uid("a")) }
            await eventually { recorder.requests.count == 1 }
            if let conditions { governor.update(conditions) } else { model.close() }
            _ = await task.value
            await eventually { recorder.cancellation.contains(0) }
            XCTAssertTrue(recorder.cancellation.contains(0), "release must cancel the admitted load")
            model.close()
            recorder.finishAll()
        }
    }

    func testCancelledTaskCannotReadCachedPreview() async throws {
        let image = try bitmap(side: 10)
        let model = BackupProblemPreviewModel { _ in image }
        model.open()
        defer { model.close() }
        _ = await model.thumbnail(for: uid("a"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.thumbnail(for: uid("a"))
        }
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    func testUnopenedListReturnsWithoutAdmittingARequest() async {
        let recorder = ControlledPreviewRecorder()
        let model = BackupProblemPreviewModel(load: recorder.load)
        let returned = expectation(description: "closed list returns")
        let task = Task {
            let image = await model.thumbnail(for: uid("a"))
            XCTAssertNil(image)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(model.pendingWaiterCount, 0)
        XCTAssertTrue(recorder.requests.isEmpty)
        model.close()
        _ = await task.value
        recorder.finishAll()
    }

    func testCancelledRowRejectsANoncooperativeResultWithoutAnIdentityChange() async throws {
        let recorder = ControlledPreviewRecorder()
        let state = LocalPhotoThumbnailState()
        let task = Task { await state.load(uid("a"), using: recorder.load) }
        await eventually { recorder.requests.count == 1 }
        task.cancel()
        recorder.finish(0, try bitmap(side: 10))
        await task.value
        XCTAssertNil(state.image(for: uid("a")))
    }

    private func eventually(
        _ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "required event did not arrive", file: file, line: line)
    }

    private func uid(_ name: String) -> PhotoUID { PhotoUID(localPending: .photoLibrary, identifier: name) }

    private func bitmap(side: Int, rowBytes: Int? = nil) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: rowBytes ?? side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class PreviewRecorder {
    var requests: [String] = []
    var cancelled: [String] = []
    private var pending: [String: CheckedContinuation<CGImage?, Never>] = [:]
    private var starts: [String: XCTestExpectation] = [:]
    private var cancellations: [String: XCTestExpectation] = [:]

    func load(_ uid: PhotoUID) async -> CGImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests.append(uid.nodeID)
                pending[uid.nodeID] = continuation
                starts[uid.nodeID]?.fulfill()
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled.append(uid.nodeID)
                self.cancellations[uid.nodeID]?.fulfill()
                self.finish(uid.nodeID, nil)
            }
        }
    }

    func finish(_ key: String, _ image: CGImage?) { pending.removeValue(forKey: key)?.resume(returning: image) }

    func started(_ key: String, test: XCTestCase) async {
        if requests.contains(key) { return }
        let event = XCTestExpectation(description: "request \(key)")
        starts[key] = event
        await test.fulfillment(of: [event], timeout: 2)
    }

    func wasCancelled(_ key: String, test: XCTestCase) async {
        if cancelled.contains(key) { return }
        let event = XCTestExpectation(description: "cancel \(key)")
        cancellations[key] = event
        await test.fulfillment(of: [event], timeout: 2)
    }
}

private final class PreviewAsset: PHAsset, @unchecked Sendable {
    let fresh: Bool
    init(fresh: Bool) {
        self.fresh = fresh
        super.init()
    }
    override var localIdentifier: String { "asset" }
    override var creationDate: Date? { fresh ? Date() : .distantPast }
}

private final class ImageRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    private var targets: [CGSize] = []
    var allowed: [Bool] { lock.withLock { flags } }
    var sizes: [CGSize] { lock.withLock { targets } }
    func request(
        _ asset: PHAsset, _ size: CGSize, _ mode: PHImageContentMode,
        _ options: PHImageRequestOptions, _ finish: @escaping @Sendable (CGImage?, Bool) -> Void
    ) -> PHImageRequestID {
        lock.withLock {
            flags.append(options.isNetworkAccessAllowed)
            targets.append(size)
        }
        finish(nil, false)
        return PHInvalidImageRequestID
    }
}

/// Cancellation is observed synchronously, but only explicit completion releases the fake loader.
@MainActor
private final class ControlledPreviewRecorder {
    let cancellation = PreviewCancellationProbe()
    var requests: [String] = []
    var returned: Set<Int> = []
    private var pending: [Int: CheckedContinuation<CGImage?, Never>] = [:]

    func load(_ uid: PhotoUID) async -> CGImage? {
        let index = requests.count
        requests.append(uid.nodeID)
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { pending[index] = $0 }
        } onCancel: { [cancellation] in
            cancellation.record(index)
        }
        returned.insert(index)
        return image
    }

    func finish(_ index: Int, _ image: CGImage?) { pending.removeValue(forKey: index)?.resume(returning: image) }
    func finishAll() {
        let values = pending.values
        pending.removeAll()
        for continuation in values { continuation.resume(returning: nil) }
    }
}

private final class PreviewCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var indices: Set<Int> = []
    func record(_ index: Int) { lock.withLock { _ = indices.insert(index) } }
    func contains(_ index: Int) -> Bool { lock.withLock { indices.contains(index) } }
}
