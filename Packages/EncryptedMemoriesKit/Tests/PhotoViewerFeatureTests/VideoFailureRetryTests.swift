import AVFoundation
import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerFeature
import PhotosCore
import XCTest

/// A video failure offers Retry only when a new attempt can change it, and a rate limit stays behind the loading
/// indicator while the viewer prepares the video and asks again.
final class VideoFailureRetryTests: XCTestCase {
    private let fixedFailures: [VideoPlaybackError] = [
        .notVideo, .unsupportedCodec, .streamURLUnavailable, .decryptionFailed, .malformedContent, .authExpired,
    ]
    private let changeableFailures: [VideoPlaybackError] = [
        .metadataUnavailable, .rangeNotSupported, .networkUnavailable, .quotaOrRateLimited,
        .localFileError, .playerItemFailed(detail: nil), .timedOut, .unknown(detail: nil),
    ]

    func testOnlyAFailureThatANewAttemptCannotChangeHidesRetry() {
        for failure in fixedFailures {
            XCTAssertFalse(failure.isRetryable, "\(failure.token) does not change when the person asks again")
        }
        for failure in changeableFailures {
            XCTAssertTrue(failure.isRetryable, "\(failure.token) can work on another attempt")
        }
    }

    func testTheProductionWaitsOfARateLimitAreThreeEightAndTwentySeconds() {
        let production: [Duration] = [.seconds(3), .seconds(8), .seconds(20)]
        XCTAssertEqual(VideoPlaybackError.rateLimitSilentRetryDelays, production)
        XCTAssertEqual(VideoPlaybackError.quotaOrRateLimited.silentRetryDelays, production)
        for failure in fixedFailures + changeableFailures where failure != .quotaOrRateLimited {
            XCTAssertTrue(failure.silentRetryDelays.isEmpty, "\(failure.token) shows its failure at once")
        }
    }

    func testAFailureWithATypedCauseIsClassifiedByItsType() {
        XCTAssertEqual(VideoPlaybackError.classify(TypedFailure(cause: .decryptionFailed)), .decryptionFailed)
        XCTAssertNotEqual(VideoPlaybackError.classify(TypedFailure(cause: nil)), .decryptionFailed)
    }

    // MARK: - Silent retries

    @MainActor
    func testARateLimitIsRetriedWithTheProductionWaitsAndThenShowsTheFailure() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait()
        let model = try makeModel(streamer: streamer, wait: wait)
        model.start()

        try await waitUntil { model.videoState.error != nil || wait.requested.count > 3 }
        let calls = await streamer.calls
        XCTAssertEqual(wait.requested, [.seconds(3), .seconds(8), .seconds(20)])
        XCTAssertEqual(calls, 4, "the first attempt and one attempt after each wait")
        XCTAssertEqual(model.videoState, .failed(.quotaOrRateLimited))
        XCTAssertEqual(model.videoState.error?.isRetryable, true)
    }

    @MainActor
    func testARateLimitAsksAgainBehindTheLoadingIndicatorAndShowsTheFinalFailure() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit, Self.rateLimit, Self.codec])
        let wait = ControlledWait()
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.milliseconds(1), .milliseconds(1)])
        model.start()

        try await waitUntil { model.videoState.error != nil }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 3, "two silent retries, then the answer of the third attempt")
        XCTAssertEqual(model.videoState, .failed(.unsupportedCodec))
        XCTAssertEqual(model.videoState.errorMessage, VideoPlaybackError.unsupportedCodec.userMessage)
    }

    @MainActor
    func testARateLimitShowsNoFailureWhileTheViewerWaitsAndAsksAgainWhenTheWaitEnds() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit, Self.codec])
        let wait = ControlledWait(holds: true)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60)])
        model.start()

        try await waitUntil { wait.requested.count == 1 }
        XCTAssertEqual(model.videoState, .resolving, "the wait shows the loading indicator")
        XCTAssertNil(model.videoState.error)
        let callsWhileWaiting = await streamer.calls
        XCTAssertEqual(callsWhileWaiting, 1)

        wait.release()
        try await waitUntil { model.videoState.error != nil }
        let callsAfterRelease = await streamer.calls
        XCTAssertEqual(callsAfterRelease, 2)
        XCTAssertEqual(model.videoState, .failed(.unsupportedCodec))
    }

    @MainActor
    func testAFixedFailureShowsAtOnceAndHidesRetry() async throws {
        let streamer = ScriptedStreamProvider(failures: [TypedFailure(cause: .decryptionFailed)])
        let wait = ControlledWait()
        let model = try makeModel(streamer: streamer, wait: wait)
        model.start()

        try await waitUntil { model.videoState.error != nil }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(wait.requested.isEmpty)
        XCTAssertEqual(model.videoState, .failed(.decryptionFailed))
        XCTAssertEqual(model.videoState.error?.isRetryable, false)
    }

    @MainActor
    func testAHostWithoutAStreamProviderHidesRetry() async throws {
        let model = try makeModel(streamer: nil, wait: ControlledWait())
        model.start()

        try await waitUntil { model.videoState.error != nil }
        XCTAssertEqual(model.videoState, .failed(.streamURLUnavailable))
        XCTAssertEqual(model.videoState.error?.isRetryable, false)
    }

    @MainActor
    func testAFailedFirstDecodeWithAStreamerPresentKeepsRetry() async throws {
        let streamer = ScriptedStreamProvider(failures: [VideoStreamError.notAVideo])
        let model = try makeModel(
            items: [Self.photo(0)], streamer: streamer, wait: ControlledWait(), original: Data([1, 2, 3]))
        model.start()

        try await waitUntil { model.videoState.error != nil }
        XCTAssertNotEqual(model.videoState.error, .streamURLUnavailable, "only a host without a streamer sets it")
        XCTAssertEqual(model.videoState.error?.isRetryable, true, "a later fetch or decode can succeed")
    }

    // MARK: - The wait ends with the viewer

    @MainActor
    func testClosingTheViewerEndsTheWaitWithoutAnotherAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.stop()
        try await waitUntil { model.finishedLoadCount == 1 }
        let calls = await streamer.calls
        XCTAssertEqual(wait.ended, 1, "the sleeper ended by cancellation, without a release")
        XCTAssertEqual(calls, 1, "the load ended without another attempt")
    }

    @MainActor
    func testAWaitThatEndsAfterTheViewerClosedStartsNoAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.stop()
        wait.release()
        try await waitUntil { model.finishedLoadCount == 1 }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testMovingToAnotherItemEndsTheWaitOfTheOldItem() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true)
        let model = try makeModel(
            items: [Self.video(0), Self.video(1)], streamer: streamer, wait: wait, delays: [.seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.next()
        try await waitUntil { model.finishedLoadCount == 1 }  // the load of the old item; the new item still waits
        let oldItemCalls = await streamer.calls(for: "n0")
        XCTAssertEqual(wait.ended, 1)
        XCTAssertEqual(oldItemCalls, 1, "the old item asks no second time")
    }

    @MainActor
    func testAWaitOfTheOldItemThatEndsAfterTheMoveStartsNoAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let model = try makeModel(
            items: [Self.video(0), Self.video(1)], streamer: streamer, wait: wait,
            delays: [.seconds(60), .seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.next()
        try await waitUntil { wait.requested.count == 2 }  // the new item waits for its own rate limit
        wait.release()
        // The old load ends. The new item asks again after its wait and waits for a third time.
        try await waitUntil { model.finishedLoadCount == 1 && wait.requested.count == 3 }
        let oldItemCalls = await streamer.calls(for: "n0")
        XCTAssertEqual(oldItemCalls, 1, "a stale wait of the old item does not ask again")
    }

    @MainActor
    func testReloadingTheSameItemReplacesTheOldWait() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60), .seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.retry()  // the same item loads again; the old load is replaced
        try await waitUntil { wait.requested.count == 2 }
        wait.release()  // the stale wait ends and its load stops; the current load asks again and waits again
        try await waitUntil { model.finishedLoadCount == 1 && wait.requested.count == 3 }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 3, "first load, reload, and one attempt after the wait of the reload")
    }

    @MainActor
    func testAWaitThatEndsAfterTheSessionChangedStartsNoAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let previewCache = ThumbnailCache(namespace: "video-retry-session", rootDirectory: temporaryRoot())
        let model = try makeModel(
            streamer: streamer, wait: wait, delays: [.seconds(60)], previewCache: previewCache)
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        previewCache.configure(accountUID: "another-account", key: nil)  // sign-out or account switch
        wait.release()
        try await waitUntil { model.finishedLoadCount == 1 }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - A stream that arrives after the viewer moved on

    @MainActor
    func testAStreamThatArrivesAfterTheViewerClosedIsDisposedAndNotShown() async throws {
        let late = LateStream()
        let streamer = ScriptedStreamProvider(steps: [.fail(Self.rateLimit), .lateSuccess(late)])
        let model = try makeModel(
            streamer: streamer, wait: ControlledWait(), delays: [.milliseconds(1)], late: late)
        model.start()
        try await waitUntil { late.waiting == 1 }  // the second attempt waits for its stream

        model.stop()
        late.open()
        try await waitUntil { model.finishedLoadCount == 1 }
        XCTAssertEqual(model.video.attachedPlayerCount, 0, "a stale stream never reaches a player")
        XCTAssertEqual(late.closed, 1, "the viewer disposes a stream that it no longer wants")
        XCTAssertNil(model.player, "a stale stream is not published")
    }

    @MainActor
    func testAStreamThatArrivesAfterTheSessionChangedIsDisposedAndNotShown() async throws {
        let late = LateStream()
        let streamer = ScriptedStreamProvider(steps: [.fail(Self.rateLimit), .lateSuccess(late)])
        let previewCache = ThumbnailCache(namespace: "video-retry-late-session", rootDirectory: temporaryRoot())
        let model = try makeModel(
            streamer: streamer, wait: ControlledWait(), delays: [.milliseconds(1)], previewCache: previewCache,
            late: late)
        model.start()
        try await waitUntil { late.waiting == 1 }

        previewCache.configure(accountUID: "another-account", key: nil)
        late.open()
        try await waitUntil { model.finishedLoadCount == 1 }
        XCTAssertEqual(model.video.attachedPlayerCount, 0, "a stale stream never reaches a player")
        XCTAssertEqual(late.closed, 1)
        XCTAssertNil(model.player)
    }

    // MARK: - Helpers

    private static let rateLimit = NSError(
        domain: "ProtonAuth", code: 429,
        userInfo: [NSLocalizedDescriptionKey: "HTTP 429 for /drive/x"])
    private static let codec = NSError(domain: "AVFoundationErrorDomain", code: -11828)

    private static func video(_ number: Int) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n\(number)"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "video/mp4")
    }

    private static func photo(_ number: Int) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n\(number)"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/jpeg")
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-retry-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// `delays` replaces the waits of a rate limit; nil keeps the production waits. The test teardown stops the model,
    /// releases every outstanding wait and joins every load that the model started.
    @MainActor
    private func makeModel(
        items: [PhotoItem] = [VideoFailureRetryTests.video(0)], streamer: ScriptedStreamProvider?,
        wait: ControlledWait, delays: [Duration]? = nil, previewCache: ThumbnailCache? = nil,
        original: Data? = nil, late: LateStream? = nil
    ) throws -> PhotoViewerModel {
        let provider = FailingPreviewProvider(original: original)
        let feed = ThumbnailFeed(
            cache: ThumbnailCache(namespace: "video-retry", rootDirectory: temporaryRoot()), loader: provider)
        let waitForDelay: (Duration) async -> Void = { await wait.wait($0) }
        let model: PhotoViewerModel
        if let delays {
            model = PhotoViewerModel(
                items: items, index: 0, feed: feed, media: provider, streamer: streamer,
                previewCache: previewCache,
                silentRetryDelays: { failure in failure == .quotaOrRateLimited ? delays : [] },
                silentRetryWait: waitForDelay)
        } else {
            model = PhotoViewerModel(
                items: items, index: 0, feed: feed, media: provider, streamer: streamer,
                previewCache: previewCache, silentRetryWait: waitForDelay)
        }
        addTeardownBlock { @MainActor in
            model.stop()
            let deadline = ContinuousClock.now + .seconds(5)
            while model.finishedLoadCount < model.startedLoadCount, ContinuousClock.now < deadline {
                wait.release()  // also a load that waits again after an earlier release
                late?.open()  // and an attempt that still waits for its stream
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(
                model.finishedLoadCount, model.startedLoadCount, "a load of the viewer did not end in the teardown")
            late?.dropDelivered()  // the asset and the stream retain each other until here
        }
        return model
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the viewer did not reach the expected state")
        throw CancellationError()
    }
}

/// An error that names its playback failure, like the typed errors of the Drive backend.
private struct TypedFailure: VideoPlaybackClassifiable {
    let cause: VideoPlaybackError?
    var videoPlaybackError: VideoPlaybackError? { cause }
}

private enum StreamStep {
    case fail(any Error)
    /// Waits until the test opens the stream, then delivers an asset.
    case lateSuccess(LateStream)
}

private actor ScriptedStreamProvider: VideoStreamProvider {
    private let steps: [StreamStep]
    private var nodeIDs: [String] = []

    init(steps: [StreamStep]) {
        self.steps = steps.isEmpty ? [.fail(CancellationError())] : steps
    }

    init(failures: [any Error]) { self.init(steps: failures.map(StreamStep.fail)) }

    var calls: Int { nodeIDs.count }

    func calls(for nodeID: String) -> Int { nodeIDs.filter { $0 == nodeID }.count }

    func prefetchEncrypted(for uid: PhotoUID) async throws {}

    /// The steps in order; the last one repeats.
    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        nodeIDs.append(uid.nodeID)
        switch steps[min(nodeIDs.count, steps.count) - 1] {
        case .fail(let error): throw error
        case .lateSuccess(let late): return await late.deliver()
        }
    }
}

/// A stream that the test delivers late. It keeps the assets that it delivered, so a close is an explicit close of the
/// viewer and not the release of the last reference.
private final class LateStream: @unchecked Sendable, VideoStreamLifetime {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var delivered: [StreamingVideoAsset] = []
    private var closeCount = 0

    /// The number of attempts that wait for this stream.
    var waiting: Int { lock.withLock { continuations.count } }
    /// The number of closes of the delivered assets.
    var closed: Int { lock.withLock { closeCount } }

    func deliver() async -> StreamingVideoAsset {
        await withCheckedContinuation { continuation in
            let open = lock.withLock { () -> Bool in
                if isOpen { return true }
                continuations.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
        let asset = StreamingVideoAsset(asset: AVURLAsset(url: URL(string: "protonvideo://late")!), retaining: self)
        lock.withLock { delivered.append(asset) }
        return asset
    }

    func open() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { continuations.removeAll() }
            return continuations
        }
        for waiter in waiters { waiter.resume() }
    }

    func close() { lock.withLock { closeCount += 1 } }

    /// Lets go of the delivered assets. Each one retains this stream and this stream retains it. The assets end
    /// outside the lock, because the last reference of an asset that is still open closes it, and a close takes the lock.
    func dropDelivered() {
        let assets = lock.withLock { () -> [StreamingVideoAsset] in
            defer { delivered = [] }
            return delivered
        }
        withExtendedLifetime(assets) {}
    }
}

/// The wait between two silent retries, which a test holds and releases. `holds: false` returns at once. A held wait
/// ends when the test releases it, or when its task is cancelled unless `endsOnCancellation` is false. A release
/// reaches every wait that has been requested, also one that has not parked yet.
private final class ControlledWait: @unchecked Sendable {
    private let lock = NSLock()
    private let holds: Bool
    private let endsOnCancellation: Bool
    private var delays: [Duration] = []
    private var endedCount = 0
    private var outstanding: [Int] = []
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var resumedEarly: Set<Int> = []
    private var nextID = 0

    init(holds: Bool = false, endsOnCancellation: Bool = true) {
        self.holds = holds
        self.endsOnCancellation = endsOnCancellation
    }

    /// The delays that the model asked for, in order.
    var requested: [Duration] { lock.withLock { delays } }
    /// The number of waits that have ended.
    var ended: Int { lock.withLock { endedCount } }

    func wait(_ delay: Duration) async {
        let id = lock.withLock { () -> Int in
            delays.append(delay)
            nextID += 1
            if holds { outstanding.append(nextID) }
            return nextID
        }
        if holds {
            if endsOnCancellation {
                await withTaskCancellationHandler {
                    await park(id)
                } onCancel: {
                    resume(id)
                }
            } else {
                await park(id)
            }
        }
        lock.withLock {
            endedCount += 1
            outstanding.removeAll { $0 == id }
        }
    }

    /// Ends every held wait that has been requested, the oldest first.
    func release() {
        let ids = lock.withLock { outstanding }
        for id in ids { resume(id) }
    }

    private func park(_ id: Int) async {
        await withCheckedContinuation { continuation in
            let early = lock.withLock { () -> Bool in
                if resumedEarly.remove(id) != nil { return true }
                parked[id] = continuation
                return false
            }
            if early { continuation.resume() }
        }
    }

    private func resume(_ id: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let continuation = parked.removeValue(forKey: id) else {
                resumedEarly.insert(id)
                return nil
            }
            return continuation
        }
        continuation?.resume()
    }
}

private struct FailingPreviewProvider: FullMediaProvider, ThumbnailBatchLoader {
    /// The bytes that `originalData` returns; nil makes it fail.
    let original: Data?

    func preview(for uid: PhotoUID) async throws -> Data { throw VideoStreamError.notAVideo }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let original else { throw VideoStreamError.notAVideo }
        return original
    }
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
