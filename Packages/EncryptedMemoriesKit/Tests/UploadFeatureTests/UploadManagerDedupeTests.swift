import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Scripted `UploadIdentityResolving`: decisions per filename, recorded calls, optional delay so
/// cancellation can land mid-"hashing".
final class FakeIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let lock = NSLock()
    var decisionsByFilename: [String: UploadDuplicateDecision] = [:]
    private var notNeededSignals = 0
    /// How often the backup reported that it ended a pass without preparing the index.
    var remoteIndexPreparationNotNeededCount: Int { lock.withLock { notNeededSignals } }

    func remoteIndexPreparationNotNeeded() async {
        lock.withLock { notNeededSignals += 1 }
    }
    var errorsByFilename: [String: Error] = [:]
    var recordErrorsByFilename: [String: Error] = [:]
    var resolveDelay: Duration?
    var primeGate: DedupePrimeGate?
    /// Called after each recorded prime, so a test can await the fire-and-forget prime instead of sleeping.
    var onPrime: (@Sendable () -> Void)?
    private var _resolved: [String] = []
    private var _primedFilenames: [[String]] = []
    private var _recordedUploads: [(filename: String, remoteLinkID: String)] = []
    private var _failedUploads: [String] = []

    var resolved: [String] { lock.withLock { _resolved } }
    var primedFilenames: [[String]] { lock.withLock { _primedFilenames } }
    var recordedUploads: [(filename: String, remoteLinkID: String)] { lock.withLock { _recordedUploads } }
    var failedUploads: [String] { lock.withLock { _failedUploads } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        if let resolveDelay {
            try await Task.sleep(for: resolveDelay)
        }
        try Task.checkCancellation()
        lock.withLock { _resolved.append(descriptor.filename) }
        if let error = lock.withLock({ errorsByFilename[descriptor.filename] }) { throw error }
        let decision = lock.withLock { decisionsByFilename[descriptor.filename] } ?? .upload
        let identity = UploadIdentity(
            correctedName: "corrected-\(descriptor.filename)",
            nameHash: "nh",
            sha1Hex: String(repeating: "ab", count: 20),
            sha1Digest: Data(repeating: 0xAB, count: 20),
            contentHash: "ch"
        )
        return UploadPreflightResult(identity: identity, decision: decision)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        lock.withLock { _primedFilenames.append(descriptors.map(\.filename)) }
        onPrime?()
        if let primeGate {
            await primeGate.waitForRelease()
        }
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        if let error = lock.withLock({ recordErrorsByFilename[descriptor.filename] }) {
            throw error
        }
        lock.withLock { _recordedUploads.append((descriptor.filename, remoteLinkID)) }
    }

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        lock.withLock { _failedUploads.append(descriptor.filename) }
    }
}

actor DedupePrimeGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

final class UploadManagerDedupeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-manager-dedupe-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFolderBatchDoesNotStartBeforeDedupePrimeCompletes() async throws {
        let folder = try XCTUnwrap(tempDir)
        let files = try makeTempFiles(["one.jpg", "two.jpg"], in: folder)
        XCTAssertEqual(files.count, 2)
        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let gate = DedupePrimeGate()
        resolver.primeGate = gate
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)

        let enqueue = Task { try await manager.enqueueFolder(folder, destination: .library) }
        await gate.waitUntilStarted()

        XCTAssertTrue(resolver.resolved.isEmpty)
        XCTAssertTrue(uploader.requests.isEmpty)

        await gate.release()
        let enqueuedIDs = try await enqueue.value
        XCTAssertEqual(enqueuedIDs.count, 2)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(resolver.primedFilenames, [["one.jpg", "two.jpg"]])
        XCTAssertEqual(uploader.requests.count, 2)
    }

    func testFolderReadFailurePublishesTheCompleteQueuedPrefix() async throws {
        let folder = try XCTUnwrap(tempDir)
        let filenames = (0..<35).map { String(format: "%03d.jpg", $0) }
        _ = try makeTempFiles(filenames, in: folder)
        let later = folder.appendingPathComponent("z-later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try Data("later".utf8).write(to: later.appendingPathComponent("later.jpg"))

        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let gate = DedupePrimeGate()
        resolver.primeGate = gate
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)

        let enqueue = Task { try await manager.enqueueFolder(folder, destination: .library) }
        await gate.waitUntilStarted()
        try FileManager.default.removeItem(at: later)
        await gate.release()

        do {
            _ = try await enqueue.value
            XCTFail("a removed subtree must fail the folder enqueue")
        } catch let error as FolderEnumerationError {
            XCTAssertEqual(error.failureClass, .missing)
            XCTAssertEqual(error.url.lastPathComponent, later.lastPathComponent)
            XCTAssertEqual(
                error.url.deletingLastPathComponent().resolvingSymlinksInPath(),
                later.deletingLastPathComponent().resolvingSymlinksInPath()
            )
        }

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.map(\.displayName), filenames)
        XCTAssertEqual(resolver.primedFilenames.map(\.count), [32, 3])
    }

    func testIdenticalContentFromDifferentPathsUploadsOnce() async throws {
        let dirA = tempDir.appendingPathComponent("sync1", isDirectory: true)
        let dirB = tempDir.appendingPathComponent("sync2", isDirectory: true)
        let fileA = try makeTempFiles(["IMG_1.jpg"], in: dirA)[0]
        let fileB = try makeTempFiles(["IMG_renamed.jpg"], in: dirB)[0]
        try Data("identical-bytes".utf8).write(to: fileA)
        try Data("identical-bytes".utf8).write(to: fileB)

        let uploader = MockUploader()
        let pipeline = UploadDedupePipeline(store: FakeIdentityStore(), checker: FakeChecker())
        let manager = UploadManager(uploader: uploader, identityResolver: pipeline)

        await manager.enqueueFiles([fileA, fileB], destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(
            uploader.requests.count, 1,
            "identical bytes from different paths/filenames must upload exactly once")
        let states = items.map(\.state)
        XCTAssertTrue(states.contains(.completed))
        XCTAssertTrue(
            states.contains(.skipped(.knownFromManifest)),
            "the copy must be reported as an already-backed-up duplicate, got \(states)")
    }

    func testDifferentContentWithSameFilenameUploadsBoth() async throws {
        let dirA = tempDir.appendingPathComponent("sync1", isDirectory: true)
        let dirB = tempDir.appendingPathComponent("sync2", isDirectory: true)
        let fileA = try makeTempFiles(["IMG_1.jpg"], in: dirA)[0]
        let fileB = try makeTempFiles(["IMG_1.jpg"], in: dirB)[0]
        try Data("bytes-version-a".utf8).write(to: fileA)
        try Data("bytes-version-b".utf8).write(to: fileB)

        let uploader = MockUploader()
        let pipeline = UploadDedupePipeline(store: FakeIdentityStore(), checker: FakeChecker())
        let manager = UploadManager(uploader: uploader, identityResolver: pipeline)

        await manager.enqueueFiles([fileA, fileB], destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(
            uploader.requests.count, 2,
            "same filename with different bytes is NOT a duplicate and must upload both")
        XCTAssertTrue(items.allSatisfy { $0.state == .completed })
    }

    func testDuplicateItemSkipsWithoutUploadingBytes() async throws {
        let urls = try makeTempFiles(["dup.jpg", "new.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["dup.jpg"] = .skip(.activeDuplicate, remoteLinkID: "l1")
        let completions = UploadCompletionRecorder()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)
        await manager.setOnCompleted { completions.record($0) }

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        let dup = try XCTUnwrap(items.first { $0.displayName == "dup.jpg" })
        let fresh = try XCTUnwrap(items.first { $0.displayName == "new.jpg" })
        XCTAssertEqual(dup.state, .skipped(.activeDuplicate))
        XCTAssertEqual(fresh.state, .completed)
        XCTAssertEqual(uploader.startedOrder, ["corrected-new.jpg"], "duplicate bytes must never upload")
        XCTAssertEqual(
            completions.events.map(\.displayName), ["new.jpg"],
            "skipped duplicates must not emit a completion event (no new node exists)")

        let stats = { () -> UploadQueueStats in
            var s = UploadQueueStats()
            for item in items {
                switch item.state {
                case .completed: s.completed += 1
                case .skipped(let reason) where reason.countsAsBackedUp: s.skippedDuplicates += 1
                default: break
                }
            }
            return s
        }()
        XCTAssertEqual(stats.skippedDuplicates, 1)
    }

    func testNonDuplicateUploadsOnceWithIdentityApplied() async throws {
        let urls = try makeTempFiles(["photo one.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)

        XCTAssertEqual(uploader.requests.count, 1)
        let request = try XCTUnwrap(uploader.requests.first)
        XCTAssertEqual(request.name, "corrected-photo one.jpg", "the Proton-corrected name must be uploaded")
        XCTAssertEqual(
            request.expectedSHA1, Data(repeating: 0xAB, count: 20), "the hashed digest must reach the backend")
        XCTAssertEqual(
            resolver.recordedUploads.map(\.filename), ["photo one.jpg"],
            "successful uploads must be recorded in the manifest")
    }

    func testResolveFailureFailsTheItemWithoutBlindUpload() async throws {
        let urls = try makeTempFiles(["broken.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.errorsByFilename["broken.jpg"] = UploadError.backend("duplicate check unavailable")
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        guard case .failed = items[0].state else {
            return XCTFail("expected failed, got \(items[0].state)")
        }
        XCTAssertTrue(uploader.startedOrder.isEmpty, "a failed duplicate check must not upload blindly")
    }

    func testDraftDuplicateFailsRetryablyInsteadOfClaimingBackedUp() async throws {
        let urls = try makeTempFiles(["draft.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["draft.jpg"] = .skip(.draftExists, remoteLinkID: "draft-link")
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        guard case .failed(let message) = items[0].state else {
            return XCTFail("expected failed draft state, got \(items[0].state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(uploader.startedOrder.isEmpty, "a draft blocker must never upload blindly")
        XCTAssertEqual(UploadQueuePresentation.rowActions(for: items[0], capabilities: .unavailable), [.retry])
    }

    func testRemoteDeletionSkipDoesNotCountAsBackedUpDuplicate() async throws {
        let urls = try makeTempFiles(["deleted.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["deleted.jpg"] = .skip(.deletedRemotely, remoteLinkID: "old-link")
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .skipped(.deletedRemotely))
        XCTAssertTrue(uploader.startedOrder.isEmpty, "remote deletion policy must not restore bytes")
        var stats = UploadQueueStats()
        if case .skipped(let reason) = items[0].state {
            if reason.countsAsBackedUp {
                stats.skippedDuplicates += 1
            } else {
                stats.skippedRemoteDeletions += 1
            }
        }
        XCTAssertEqual(stats.skippedDuplicates, 0)
        XCTAssertEqual(stats.skippedRemoteDeletions, 1)
    }

    func testCancelDuringHashingCancelsWithoutUpload() async throws {
        let urls = try makeTempFiles(["slow.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.resolveDelay = .seconds(5)
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { $0.first?.state == .hashing }
        await manager.cancel(ids[0])
        let items = await waitForAllTerminal(manager, timeout: .seconds(2))

        XCTAssertEqual(items[0].state, .cancelled)
        XCTAssertTrue(uploader.startedOrder.isEmpty, "cancel during hashing must abort before any upload")
    }

    func testCancelDuringUploadSettlesClaimExactlyOnce() async throws {
        let urls = try makeTempFiles(["slow-upload.jpg"], in: tempDir)
        let uploader = MockUploader(workDuration: .seconds(5), deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { items in
            items.first?.state.isActive == true && !uploader.startedOrder.isEmpty
        }
        await manager.cancel(ids[0])
        let items = await waitForAllTerminal(manager, timeout: .seconds(2))

        XCTAssertEqual(items[0].state, .cancelled)
        XCTAssertEqual(resolver.failedUploads, ["slow-upload.jpg"])
        XCTAssertTrue(resolver.recordedUploads.isEmpty)
    }

    func testSuccessfulUploadRecordsReceiptWithoutFailureSettlement() async throws {
        let urls = try makeTempFiles(["receipt.jpg"], in: tempDir)
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(
            uploader: MockUploader(workDuration: .milliseconds(1), deliverProgress: false),
            identityResolver: resolver
        )

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .completed)
        XCTAssertEqual(resolver.recordedUploads.map(\.filename), ["receipt.jpg"])
        XCTAssertTrue(resolver.failedUploads.isEmpty)
    }

    func testManifestFailurePreservesRemoteCommitReceiptWithoutFailureSettlement() async throws {
        let descriptor = UploadResourceDescriptor(
            source: UploadSourceIdentity(kind: .fileURL, identifier: "/tmp/receipt.jpg"),
            fileURL: URL(fileURLWithPath: "/tmp/receipt.jpg"),
            filename: "receipt.jpg",
            fileSize: 10,
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        let resolver = FakeIdentityResolver()
        resolver.recordErrorsByFilename["receipt.jpg"] = UploadError.backend("manifest full")
        let receipt = UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link")

        do {
            let _: Void = try await resolver.withUploadDecision(descriptor) { _ in
                .remoteCommitted((), receipt: receipt)
            }
            XCTFail("expected the local settlement failure")
        } catch let error as UploadRemoteCommitSettlementError {
            XCTAssertEqual(error.receipt, receipt)
            XCTAssertEqual(error.settlementMessage, "manifest full")
        }

        XCTAssertTrue(resolver.recordedUploads.isEmpty)
        XCTAssertTrue(
            resolver.failedUploads.isEmpty,
            "a committed remote object must be reconciled, never released as an upload failure")
    }

    func testStateSequenceIncludesHashingBeforeUploading() async throws {
        let urls = try makeTempFiles(["seq.jpg"], in: tempDir)
        let uploader = MockUploader(deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let recorder = StateRecorder()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)
        await manager.setOnChange { items, _ in recorder.record(items) }

        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)

        let sequence = recorder.sequence(ids[0])
        let hashingIndex = try XCTUnwrap(sequence.firstIndex(of: .hashing), "items must pass through .hashing")
        let completedIndex = try XCTUnwrap(sequence.firstIndex(of: .completed))
        XCTAssertLessThan(hashingIndex, completedIndex)
    }

    func testEnqueuePrimesTheBatch() async throws {
        let urls = try makeTempFiles(["a.jpg", "b.jpg", "c.jpg"], in: tempDir)
        let resolver = FakeIdentityResolver()
        // The prime is fire-and-forget: the test awaits it. The timeout only ends a hung test. Created directly, the
        // expectation does not raise on a second or a late fulfillment, which would end the whole test bundle; the
        // count below fails the test instead.
        let primed = XCTestExpectation(description: "the batch is primed")
        resolver.onPrime = { primed.fulfill() }
        let manager = UploadManager(uploader: MockUploader(), identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        await fulfillment(of: [primed], timeout: 300)

        XCTAssertEqual(resolver.primedFilenames.count, 1)
        // A missing prime fails the test; an index out of range would end the whole test bundle.
        let batch = try XCTUnwrap(resolver.primedFilenames.first, "the batch was not primed")
        XCTAssertEqual(Set(batch), ["a.jpg", "b.jpg", "c.jpg"])
    }

    func testWithoutResolverBehaviourIsUnchanged() async throws {
        let urls = try makeTempFiles(["plain.jpg"], in: tempDir)
        let uploader = MockUploader()
        let manager = UploadManager(uploader: uploader)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .completed)
        XCTAssertEqual(uploader.startedOrder, ["plain.jpg"], "no resolver → original name, no dedupe")
        XCTAssertNil(uploader.requests.first?.expectedSHA1)
    }

    func testMissingSecondariesDecisionSkipsPrimaryForManualUploads() async throws {
        // Manual uploads are single-resource compounds; if the policy ever reports missing
        // secondaries the primary itself is on the server, so nothing may upload.
        let urls = try makeTempFiles(["live.heic"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["live.heic"] = .uploadMissingSecondaries(
            primaryLinkID: "l1",
            missing: [UploadSourceIdentity(kind: .fileURL, identifier: "/x.mov", resource: .livePairedVideo)]
        )
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .skipped(.primaryAlreadyPresent))
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }
}
