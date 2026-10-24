import PhotosCore
import XCTest

@testable import UploadCore

private func isOrderedSubsequence(_ sub: [UploadItemState], of seq: [UploadItemState]) -> Bool {
    var i = 0
    for s in seq where i < sub.count && s == sub[i] { i += 1 }
    return i == sub.count
}

private actor UploadManagerTestLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }

    func isSignaled() -> Bool { signaled }
}

private final class ShutdownControlledUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities(
        canUpload: true,
        supportsCancel: true,
        supportsPauseResume: false,
        supportsResumeAcrossRelaunch: false
    )

    let uploadStarted = UploadManagerTestLatch()
    let uploadRelease = UploadManagerTestLatch()
    let cancelStarted = UploadManagerTestLatch()
    let cancelRelease = UploadManagerTestLatch()

    private let lock = NSLock()
    private var _requestCount = 0
    private var _cancelCount = 0

    var requestCount: Int { lock.withLock { _requestCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        lock.withLock { _requestCount += 1 }
        await uploadStarted.signal()
        await uploadRelease.wait()
        return testUID(request.name)
    }

    func cancel(token: UUID) async {
        lock.withLock { _cancelCount += 1 }
        await cancelStarted.signal()
        await cancelRelease.wait()
    }
}

private final class BurstProgressUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    let callbackCount: Int

    init(callbackCount: Int = 10_000) {
        self.callbackCount = callbackCount
    }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        for value in 0...callbackCount {
            onProgress(
                UploadProgress(
                    phase: .uploading,
                    fraction: Double(value) / Double(callbackCount)
                ))
        }
        return PhotoUID(volumeID: "volume", nodeID: request.name)
    }

    func cancel(token: UUID) async {}
    func pause(token: UUID) async throws {}
    func resume(token: UUID) async throws {}
}

private final class UploadChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class CancellationAwareAlbumResolver: AlbumAttaching, @unchecked Sendable {
    let resolveStarted = UploadManagerTestLatch()
    let resolveRelease = UploadManagerTestLatch()
    let resolveCancelled = UploadManagerTestLatch()

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        await resolveStarted.signal()
        return await withTaskCancellationHandler(
            operation: {
                await resolveRelease.wait()
                return "resolved-album"
            },
            onCancel: {
                Task { await self.resolveCancelled.signal() }
            })
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {}
    func setCover(albumID: String, photo: PhotoUID) async throws {}
}

/// Waits for a latch and reports whether it fired before `timeout`. The timeout only bounds a failing run.
private func waitForSignal(_ latch: UploadManagerTestLatch, timeout: Duration = .seconds(5)) async -> Bool {
    let timeouts = UploadChangeCounter()
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await latch.wait() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            if await !latch.isSignaled() {
                timeouts.increment()
                await latch.signal()
            }
        }
        await group.next()
        group.cancelAll()
    }
    return timeouts.count == 0
}

final class UploadManagerTests: XCTestCase {
    private func jpegs(_ names: [String]) throws -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(names.map { "\($0).jpg" }, in: dir)
        return (dir, urls)
    }

    func testQueuePreservesEnqueueOrder() async throws {
        let (_, urls) = try jpegs(["a", "b", "c", "d"])
        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(uploader.startedOrder, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        // Snapshot order also stable by ordinal.
        let snap = await manager.snapshot()
        XCTAssertEqual(snap.map(\.displayName), ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    }

    func testAManualUploadWaitsForARunningBackupTransferAndThenCompletes() async throws {
        let (directory, urls) = try jpegs(["after-backup"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let backup = try await uploader.admission.reserve(allowsExpensiveNetwork: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        try await waitUntilWaiting(uploader.admission)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(uploader.requests.count, 0, "no byte goes out beside the backup transfer")
        let waiting = await manager.snapshot()
        XCTAssertFalse(waiting.contains { $0.state.isTerminal }, "the upload waits; it does not fail")

        backup.release()
        let finished = await waitForAllTerminal(manager)

        XCTAssertEqual(finished.map(\.state), [.completed])
        XCTAssertEqual(uploader.uploadsWithoutTheirReservation, [])
        XCTAssertEqual(uploader.requests.map(\.allowsExpensiveNetwork), [true])
        XCTAssertFalse(
            uploader.requests.contains { $0.networkReservation?.isActive == true },
            "the manager releases the reservation")
        await manager.shutdown()
    }

    func testCancellingAManualUploadEndsItsWaitForTheNetwork() async throws {
        let (directory, urls) = try jpegs(["cancelled-while-waiting"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let backup = try await uploader.admission.reserve(allowsExpensiveNetwork: false)
        defer { backup.release() }
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        try await waitUntilWaiting(uploader.admission)

        await manager.cancel(try XCTUnwrap(ids.first))
        let finished = await waitForAllTerminal(manager)

        XCTAssertEqual(finished.map(\.state), [.cancelled])
        XCTAssertEqual(uploader.requests.count, 0)
        XCTAssertEqual(uploader.admission.waitingCount, 0, "the wait ended")
        await manager.shutdown()
    }

    func testShutdownEndsAManualUploadThatWaitsForTheNetwork() async throws {
        let (directory, urls) = try jpegs(["shut-down-while-waiting"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let backup = try await uploader.admission.reserve(allowsExpensiveNetwork: false)
        defer { backup.release() }
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        try await waitUntilWaiting(uploader.admission)

        await manager.shutdown()

        XCTAssertEqual(uploader.requests.count, 0)
        XCTAssertEqual(uploader.admission.waitingCount, 0, "the shutdown ended the wait")
    }

    private func waitUntilWaiting(_ admission: UploadNetworkAdmission) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while admission.waitingCount == 0, clock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(admission.waitingCount, 1, "the upload waits for its network reservation")
    }

    func testActiveManualUploadOwnsTransferDemandUntilItFinishes() async throws {
        let (directory, urls) = try jpegs(["active"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = LibraryRuntimeState()
        let uploader = ShutdownControlledUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1, runtimeState: state)
        await manager.enqueueFiles(urls, destination: .library)
        await uploader.uploadStarted.wait()
        XCTAssertEqual(state.snapshot().activeUserTransferCount, 1)
        await uploader.uploadRelease.signal()
        _ = await waitForAllTerminal(manager)
        await manager.shutdown()
        XCTAssertEqual(state.snapshot().activeUserTransferCount, 0)
    }

    func testEnqueueFolderStreamsSupportedMediaInDeterministicQueueOrder() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("upload-folder-\(UUID().uuidString)", isDirectory: true)
        let subfolder = root.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("A.PNG"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b.jpg"))
        try Data("unsupported".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("video".utf8).write(to: subfolder.appendingPathComponent("clip.mov"))

        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = try await manager.enqueueFolder(root, destination: .library)
        let snapshot = await waitForAllTerminal(manager)

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(snapshot.map(\.displayName), ["A.PNG", "b.jpg", "clip.mov"])
        XCTAssertEqual(uploader.startedOrder, ["A.PNG", "b.jpg", "clip.mov"])
    }

    func testRespectsMaxConcurrency() async throws {
        let (_, urls) = try jpegs((0..<6).map { "f\($0)" })
        let uploader = MockUploader(workDuration: .milliseconds(40), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 2)
        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        XCTAssertLessThanOrEqual(uploader.peakConcurrent, 2, "must never exceed configured concurrency")
        XCTAssertEqual(uploader.peakConcurrent, 2, "should actually run two in parallel")
    }

    func testStateMachineHappyPath() async throws {
        let (_, urls) = try jpegs(["one"])
        let uploader = MockUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let recorder = StateRecorder()
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        let seq = recorder.sequence(ids[0])
        XCTAssertEqual(seq.last, .completed)
        XCTAssertTrue(
            isOrderedSubsequence([.queued, .preparing, .uploading(progress: 0.5), .completed], of: seq),
            "unexpected sequence: \(seq)"
        )
    }

    func testProgressCallbackBurstIsNewestBufferedAndPresentationQuantized() async throws {
        let (_, urls) = try jpegs(["burst"])
        let uploader = BurstProgressUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let changes = UploadChangeCounter()
        await manager.setOnChange { _, _ in changes.increment() }

        await manager.enqueueFiles(urls, destination: .library)
        let snapshot = await waitForAllTerminal(manager)

        XCTAssertEqual(snapshot.first?.state, .completed)
        XCTAssertLessThanOrEqual(
            changes.count,
            110,
            "Ten thousand transport callbacks must not become ten thousand actor tasks and full-queue publications"
        )
    }

    func testClearFinishedUsesMembershipSetAndKeepsActiveOrder() async throws {
        let (_, urls) = try jpegs(["first", "active", "queued"])
        let uploader = MockUploader(workDuration: .milliseconds(100), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        _ = await manager.enqueueFiles(urls, destination: .library)

        let beforeClear = await waitUntil(manager) { items in
            items.count == 3 && items[0].state.isTerminal && items[1].state.isActive
        }
        XCTAssertEqual(beforeClear.map(\.displayName), ["first.jpg", "active.jpg", "queued.jpg"])

        await manager.clearFinished()
        let retained = await manager.snapshot()
        XCTAssertEqual(retained.map(\.displayName), ["active.jpg", "queued.jpg"])
        XCTAssertEqual(retained.first?.state.isActive, true)

        _ = await waitForAllTerminal(manager)
    }

    func testStateMachineRetryToCompleted() async throws {
        let (_, urls) = try jpegs(["x"])
        let uploader = MockUploader(deliverProgress: false, transientFailures: ["x.jpg": 1])
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let recorder = StateRecorder()
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { items in
            if case .failed = items.first?.state { return true }
            return false
        }
        await manager.retry(ids[0])
        _ = await waitUntil(manager) { $0.first?.state == .completed }
        let seq = recorder.sequence(ids[0])
        // failed must appear, and completed must come after it.
        let failedIdx = seq.firstIndex {
            if case .failed = $0 { return true }
            return false
        }
        XCTAssertNotNil(failedIdx, "sequence: \(seq)")
        XCTAssertEqual(seq.last, .completed)
    }

    func testCancelInFlight() async throws {
        let (_, urls) = try jpegs(["slow"])
        let uploader = MockUploader(workDuration: .seconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { _ in !uploader.requests.isEmpty }
        await manager.cancel(ids[0])
        let snap = await waitUntil(manager) { $0.first?.state == .cancelled }
        XCTAssertEqual(snap.first?.state, .cancelled)
        XCTAssertFalse(uploader.cancelledTokens.isEmpty, "backend cancel should be invoked for in-flight item")
    }

    func testShutdownCancelsActiveTransportAndDropsQueuedWork() async throws {
        let (_, urls) = try jpegs(["active", "queued"])
        let uploader = MockUploader(workDuration: .seconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { _ in !uploader.requests.isEmpty }

        await manager.shutdown()

        let snapshot = await manager.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(uploader.startedOrder, ["active.jpg"])
        XCTAssertEqual(uploader.cancelledTokens.count, 1)
    }

    func testConcurrentShutdownCallersJoinOneTeardown() async throws {
        let (_, urls) = try jpegs(["active"])
        let uploader = ShutdownControlledUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        await uploader.uploadStarted.wait()

        let firstReturned = UploadManagerTestLatch()
        let secondStarted = UploadManagerTestLatch()
        let secondReturned = UploadManagerTestLatch()
        let first = Task {
            await manager.shutdown()
            await firstReturned.signal()
        }
        await uploader.cancelStarted.wait()

        let second = Task {
            await secondStarted.signal()
            await manager.shutdown()
            await secondReturned.signal()
        }
        await secondStarted.wait()
        await Task.yield()

        let firstWasReturned = await firstReturned.isSignaled()
        let secondWasReturned = await secondReturned.isSignaled()
        XCTAssertFalse(firstWasReturned)
        XCTAssertFalse(secondWasReturned)
        XCTAssertEqual(uploader.cancelCount, 1)

        await uploader.cancelRelease.signal()
        await uploader.uploadRelease.signal()
        await first.value
        await second.value

        let firstDidReturn = await firstReturned.isSignaled()
        let secondDidReturn = await secondReturned.isSignaled()
        XCTAssertTrue(firstDidReturn)
        XCTAssertTrue(secondDidReturn)
        XCTAssertEqual(uploader.cancelCount, 1, "joined shutdown callers must share one native cancel")
    }

    func testShutdownClosesAdmissionBeforeFirstAwaitAndBlocksResumeAndEnqueue() async throws {
        let (_, urls) = try jpegs(["active", "queued", "late"])
        let uploader = ShutdownControlledUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(Array(urls.prefix(2)), destination: .library)
        await uploader.uploadStarted.wait()

        let shutdown = Task { await manager.shutdown() }
        await uploader.cancelStarted.wait()

        await manager.resumeAll()
        let lateIDs = await manager.enqueueFiles([urls[2]], destination: .library)
        XCTAssertTrue(lateIDs.isEmpty, "shutdown must reject enqueue after admission closes")
        XCTAssertEqual(uploader.requestCount, 1, "resumeAll must not restart work during shutdown")

        await uploader.cancelRelease.signal()
        await uploader.uploadRelease.signal()
        await shutdown.value
        XCTAssertEqual(uploader.requestCount, 1)
    }

    func testShutdownWaitsForDelayedNativeCancelBeforeReturning() async throws {
        let (_, urls) = try jpegs(["active"])
        let uploader = ShutdownControlledUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        await uploader.uploadStarted.wait()

        let returned = UploadManagerTestLatch()
        let shutdown = Task {
            await manager.shutdown()
            await returned.signal()
        }
        await uploader.cancelStarted.wait()
        await Task.yield()
        let didReturnBeforeNativeCancel = await returned.isSignaled()
        XCTAssertFalse(didReturnBeforeNativeCancel, "shutdown must join delayed native cancellation")

        await uploader.cancelRelease.signal()
        await uploader.uploadRelease.signal()
        await shutdown.value
        let didReturnAfterNativeCancel = await returned.isSignaled()
        XCTAssertTrue(didReturnAfterNativeCancel)
        XCTAssertEqual(uploader.cancelCount, 1)
    }

    func testLateAlbumResolutionCannotAddWorkAfterShutdown() async throws {
        let (_, urls) = try jpegs(["late-resolution"])
        let uploader = ShutdownControlledUploader()
        let albums = CancellationAwareAlbumResolver()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let enqueue = Task {
            await manager.enqueueFiles(
                urls,
                destination: UploadDestination(target: .existingAlbum(id: "album", title: "Album"))
            )
        }
        await albums.resolveStarted.wait()

        let shutdown = Task { await manager.shutdown() }
        await albums.resolveCancelled.wait()
        let lateIDs = await manager.enqueueFiles([urls[0]], destination: .library)
        XCTAssertTrue(lateIDs.isEmpty, "shutdown must close admission while album resolution is pending")

        await albums.resolveRelease.signal()
        let ids = await enqueue.value
        await shutdown.value

        XCTAssertTrue(ids.isEmpty, "a late album resolution must not add a job")
        let snapshot = await manager.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(uploader.requestCount, 0)
    }

    func testConcurrentCancelAndShutdownForwardNativeCancellationOnce() async throws {
        let (_, urls) = try jpegs(["concurrent-cancel"])
        let uploader = MockUploader(workDuration: .seconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { _ in !uploader.requests.isEmpty }

        async let cancel: Void = manager.cancel(ids[0])
        async let shutdown: Void = manager.shutdown()
        _ = await (cancel, shutdown)

        XCTAssertEqual(
            uploader.cancelledTokens.count, 1,
            "concurrent item cancellation and shutdown must share one native cancel")
    }

    func testUnsupportedFileIsSkippedNotCrashed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(["note.txt", "good.jpg"], in: dir)
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        let snap = await waitForAllTerminal(manager)
        let txt = snap.first { $0.displayName == "note.txt" }
        let jpg = snap.first { $0.displayName == "good.jpg" }
        if case .failed = txt?.state {
        } else {
            XCTFail("txt should be failed/unsupported: \(String(describing: txt?.state))")
        }
        XCTAssertEqual(jpg?.state, .completed)
        XCTAssertEqual(uploader.startedOrder, ["good.jpg"], "unsupported file must never reach the backend")
    }

    func testExistingAlbumAddsUploadedPhotos() async throws {
        let (_, urls) = try jpegs(["p1", "p2"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        await manager.enqueueFiles(
            urls, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "Trip")))
        _ = await waitForAllTerminal(manager)
        let added = albums.addedSnapshot
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(added.allSatisfy { $0.1 == "alb" })
    }

    func testNewAlbumCreatedBeforeAdd() async throws {
        let (_, urls) = try jpegs(["n1"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: UploadDestination(target: .newAlbum(name: "Holiday")))
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(albums.createdNames, ["Holiday"])
        XCTAssertEqual(albums.addedSnapshot.first?.1, "new-album-1")
    }

    func testUnsupportedNewAlbumFailsFastWithoutUploading() async throws {
        let (_, urls) = try jpegs(["z"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching(canCreate: false)
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: UploadDestination(target: .newAlbum(name: "Nope")))
        let snap = await waitForAllTerminal(manager)
        if case .failed = snap.first?.state {} else { XCTFail("should fail fast") }
        XCTAssertTrue(
            uploader.startedOrder.isEmpty, "must not upload to library when album destination can't be honoured")
    }

    func testUnsupportedNewAlbumFailsEveryFileWithTheResolverMessage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(["a.jpg", "note.txt"], in: dir)
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching(canCreate: false)
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: UploadDestination(target: .newAlbum(name: "Nope")))
        let snapshot = await manager.snapshot()

        let message = try XCTUnwrap(UploadError.albumStep("create unsupported").errorDescription)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(snapshot.map(\.state), [.failed(message: message), .failed(message: message)])
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }

    func testAlbumDestinationWithoutAdapterFailsEveryFileWithoutUploading() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(["a.jpg", "note.txt"], in: dir)
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(
            urls, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "Trip")))
        let snapshot = await manager.snapshot()

        let message = try XCTUnwrap(UploadError.albumStep("no album backend is wired").errorDescription)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(snapshot.map(\.state), [.failed(message: message), .failed(message: message)])
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }

    func testFolderEnqueueWithExistingAlbumAddsUploadedPhotos() async throws {
        let folder = try albumFolder(["p1.jpg", "p2.png", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let ids = try await manager.enqueueFolder(
            folder, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "Trip")))
        let snapshot = await waitForAllTerminal(manager)

        XCTAssertEqual(ids.count, 2, "the unsupported file never becomes an entry")
        XCTAssertEqual(snapshot.map(\.state), [.completed, .completed])
        XCTAssertEqual(albums.addedSnapshot.map(\.1), ["alb", "alb"])
    }

    func testFolderEnqueueWithUnsupportedNewAlbumFailsSupportedEntriesWithoutUploading() async throws {
        let folder = try albumFolder(["a.jpg", "note.txt", "b.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching(canCreate: false)
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let ids = try await manager.enqueueFolder(
            folder, destination: UploadDestination(target: .newAlbum(name: "Nope")))
        let snapshot = await waitForAllTerminal(manager)

        let message = try XCTUnwrap(UploadError.albumStep("create unsupported").errorDescription)
        XCTAssertEqual(ids.count, 2, "the unsupported file is filtered, not failed")
        XCTAssertEqual(snapshot.map(\.state), [.failed(message: message), .failed(message: message)])
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }

    func testFolderEnqueueWithAlbumDestinationWithoutAdapterFailsEntriesWithoutUploading() async throws {
        let folder = try albumFolder(["a.jpg", "note.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = try await manager.enqueueFolder(
            folder, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "Trip")))
        let snapshot = await waitForAllTerminal(manager)

        let message = try XCTUnwrap(UploadError.albumStep("no album backend is wired").errorDescription)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(snapshot.map(\.state), [.failed(message: message)])
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }

    func testUnavailableSettlementFailsEveryFileAndCreatesNoAlbum() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(["a.jpg", "note.txt"], in: dir)
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(
            uploader: uploader, albums: albums, requiresDurableSettlement: true, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(
            urls, destination: UploadDestination(target: .newAlbum(name: "Holiday")))
        let snapshot = await manager.snapshot()

        let message = try settlementUnavailableMessage()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(snapshot.map(\.state), [.failed(message: message), .failed(message: message)])
        XCTAssertEqual(albums.createdNames, [], "no album is created while every item fails")
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }

    func testFolderEnqueueWithUnavailableSettlementFailsEntriesAndCreatesNoAlbum() async throws {
        let folder = try albumFolder(["a.jpg", "note.txt", "b.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(
            uploader: uploader, albums: albums, requiresDurableSettlement: true, maxConcurrent: 1)
        let ids = try await manager.enqueueFolder(
            folder, destination: UploadDestination(target: .newAlbum(name: "Holiday")))
        let snapshot = await waitForAllTerminal(manager)

        let message = try settlementUnavailableMessage()
        XCTAssertEqual(ids.count, 2, "the unsupported file is filtered, not failed")
        XCTAssertEqual(snapshot.map(\.state), [.failed(message: message), .failed(message: message)])
        XCTAssertEqual(albums.createdNames, [], "no album is created while every entry fails")
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }

    private func settlementUnavailableMessage() throws -> String {
        try XCTUnwrap(UploadError.backend("Durable manual upload settlement is unavailable.").errorDescription)
    }

    func testShutdownCancelsAndJoinsPendingAlbumResolutionOfFileEnqueue() async throws {
        let (_, urls) = try jpegs(["pending-file-resolution"])
        try await assertShutdownCancelsAndJoinsPendingAlbumResolution { manager, destination in
            await manager.enqueueFiles(urls, destination: destination)
        }
    }

    func testShutdownCancelsAndJoinsPendingAlbumResolutionOfFolderEnqueue() async throws {
        let folder = try albumFolder(["pending-folder-resolution.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        try await assertShutdownCancelsAndJoinsPendingAlbumResolution { manager, destination in
            try await manager.enqueueFolder(folder, destination: destination)
        }
    }

    private func albumFolder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-folder-\(UUID().uuidString)", isDirectory: true)
        _ = try makeTempFiles(names, in: folder)
        return folder
    }

    private func assertShutdownCancelsAndJoinsPendingAlbumResolution(
        file: StaticString = #filePath,
        line: UInt = #line,
        enqueue: @escaping @Sendable (UploadManager, UploadDestination) async throws -> [UploadQueueItemID]
    ) async throws {
        let uploader = ShutdownControlledUploader()
        let albums = CancellationAwareAlbumResolver()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let destination = UploadDestination(target: .existingAlbum(id: "album", title: "Album"))
        let pending = Task { try await enqueue(manager, destination) }
        await albums.resolveStarted.wait()

        let returned = UploadManagerTestLatch()
        let shutdown = Task {
            await manager.shutdown()
            await returned.signal()
        }
        let cancelled = await waitForSignal(albums.resolveCancelled)
        XCTAssertTrue(cancelled, "shutdown must cancel the pending album resolution", file: file, line: line)
        for _ in 0..<20 { await Task.yield() }
        let didReturnBeforeResolution = await returned.isSignaled()
        XCTAssertFalse(
            didReturnBeforeResolution, "shutdown must join the pending album resolution", file: file, line: line)

        await albums.resolveRelease.signal()
        let ids = try await pending.value
        await shutdown.value

        XCTAssertTrue(ids.isEmpty, "a late album resolution must not add a job", file: file, line: line)
        let snapshot = await manager.snapshot()
        XCTAssertTrue(snapshot.isEmpty, file: file, line: line)
        XCTAssertEqual(uploader.requestCount, 0, file: file, line: line)
    }

    func testFirstUploadedPhotoBecomesCover() async throws {
        let (_, urls) = try jpegs(["a", "b"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let dest = UploadDestination(target: .existingAlbum(id: "alb", title: "T"), cover: .firstUploaded)
        await manager.enqueueFiles(urls, destination: dest)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(albums.coversSnapshot.count, 1)
        XCTAssertEqual(albums.coversSnapshot.first?.1, testUID("a.jpg"))
    }

    func testSpecificCoverPhoto() async throws {
        let (_, urls) = try jpegs(["a", "b"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let dest = UploadDestination(
            target: .existingAlbum(id: "alb", title: "T"),
            cover: .specific(testUID("b.jpg")))
        await manager.enqueueFiles(urls, destination: dest)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(albums.coversSnapshot.first?.1, testUID("b.jpg"))
    }

    func testPartialSuccessWhenAlbumAddFails() async throws {
        let (_, urls) = try jpegs(["pf"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching(failAdd: true)
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(
            urls, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "T")))
        let snap = await waitForAllTerminal(manager)
        let item = snap.first { $0.id == ids[0] }
        XCTAssertTrue(item?.partialSuccess ?? false, "should be a partial success")
        XCTAssertEqual(item?.uploadedUID, testUID("pf.jpg"), "uploaded photo must be preserved")
        if case .failed = item?.state {} else { XCTFail("state should be failed-with-partial") }
    }

    func testResumeCapabilityIsHonest() async {
        let uploader = MockUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        XCTAssertFalse(
            manager.capabilities.supportsResumeAcrossRelaunch,
            "in-memory operations cannot resume across relaunch")
    }

    func testPauseAndResumeQueuedItem() async throws {
        let (_, urls) = try jpegs(["a", "b", "c"])
        let uploader = MockUploader(workDuration: .milliseconds(30), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        await manager.pause(ids[1])  // pause b while it's still queued (a is running)
        // a and c complete; b stays paused.
        _ = await waitUntil(manager) { items in
            items[0].state == .completed && items[2].state == .completed
        }
        let mid = await manager.snapshot()
        XCTAssertEqual(mid[1].state, .paused)
        await manager.resume(ids[1])
        let done = await waitUntil(manager) { $0[1].state == .completed }
        XCTAssertEqual(done[1].state, .completed)
    }

    func testRetryWhilePausedActiveKeepsNativeCancellationToken() async throws {
        let (_, urls) = try jpegs(["paused-active"])
        let uploader = MockUploader(workDuration: .seconds(2), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        let id = ids[0]

        _ = await waitUntil(manager) { _ in !uploader.requests.isEmpty }
        await manager.pause(id)
        _ = await waitUntil(manager) { $0.first?.state == .paused }
        let originalToken = uploader.requests.first?.cancellationToken

        await manager.retry(id)
        await manager.cancel(id)

        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(uploader.cancelledTokens, originalToken.map { [$0] } ?? [])
    }

    func testCompletedUploadEmitsRefreshEvent() async throws {
        let (_, urls) = try jpegs(["refresh"])
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let recorder = UploadCompletionRecorder()
        await manager.setOnCompleted { event in recorder.record(event) }

        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)

        let events = recorder.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.uploadedUID, testUID("refresh.jpg"))
        XCTAssertEqual(events.first?.displayName, "refresh.jpg")
    }

    func testUploadQueueNativeStateActions() throws {
        let (_, urls) = try jpegs(["active"])
        let active = UploadItem(
            id: UUID(), ordinal: 0, fileURL: urls[0], displayName: "active.jpg",
            mediaType: "image/jpeg", byteCount: 1, state: .uploading(progress: 0.5))
        let failed = UploadItem(
            id: UUID(), ordinal: 1, fileURL: urls[0], displayName: "failed.jpg",
            mediaType: "image/jpeg", byteCount: 1, state: .failed(message: "boom"))
        let caps = UploadBackendCapabilities(
            canUpload: true, supportsCancel: true,
            supportsPauseResume: false, supportsResumeAcrossRelaunch: false)

        XCTAssertEqual(UploadQueuePresentation.rowActions(for: active, capabilities: caps), [.cancel])
        XCTAssertEqual(UploadQueuePresentation.rowActions(for: failed, capabilities: caps), [.retry])

        var stats = UploadQueueStats()
        XCTAssertFalse(UploadQueuePresentation.canClearFinished(stats))
        stats.completed = 1
        XCTAssertTrue(UploadQueuePresentation.canClearFinished(stats))
        // summaryText is localized via the package catalog (compiled by Xcode; under plain SwiftPM the
        // raw key + interpolated counts is returned). Either way the three counts - completed=1,
        // active=0, failed=0 - must appear in that order. Asserting their order keeps the test
        // independent of language and of whether the catalog is compiled.
        let s = stats.summaryText
        var cursor = s.startIndex
        for expected in ["1", "0", "0"] {
            guard let r = s.range(of: expected, range: cursor..<s.endIndex) else {
                return XCTFail("summaryText missing count \(expected) in order: \(s)")
            }
            cursor = r.upperBound
        }
    }

    func testUploadPreparationStatusCountsPreUploadCheck() throws {
        let (_, urls) = try jpegs(["one"])
        let url = urls[0]
        let items = [
            UploadItem(
                id: UUID(), ordinal: 0, fileURL: url, displayName: "queued.jpg",
                mediaType: "image/jpeg", byteCount: 1, state: .queued),
            UploadItem(
                id: UUID(), ordinal: 1, fileURL: url, displayName: "checking.jpg",
                mediaType: "image/jpeg", byteCount: 1, state: .hashing),
            UploadItem(
                id: UUID(), ordinal: 2, fileURL: url, displayName: "uploading.jpg",
                mediaType: "image/jpeg", byteCount: 1, state: .uploading(progress: 0.2)),
            UploadItem(
                id: UUID(), ordinal: 3, fileURL: url, displayName: "duplicate.jpg",
                mediaType: "image/jpeg", byteCount: 1, state: .skipped(.activeDuplicate)),
            UploadItem(
                id: UUID(), ordinal: 4, fileURL: url, displayName: "failed.jpg",
                mediaType: "image/jpeg", byteCount: 1, state: .failed(message: "boom")),
        ]

        let status = UploadPreparationStatus(items: items)

        XCTAssertEqual(status.total, 5)
        XCTAssertEqual(status.waiting, 1)
        XCTAssertEqual(status.checking, 1)
        XCTAssertEqual(status.checked, 2)
        XCTAssertEqual(status.skippedDuplicates, 1)
        XCTAssertEqual(status.failed, 1)
        XCTAssertEqual(status.resolved, 3)
        XCTAssertEqual(status.progressFraction, 0.6, accuracy: 0.0001)
        XCTAssertTrue(status.isRunning)
    }
}
