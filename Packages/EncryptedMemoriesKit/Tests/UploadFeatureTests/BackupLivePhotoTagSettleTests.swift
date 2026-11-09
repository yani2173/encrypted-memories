import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Issue 888: Never leave a Live Photo indicator on a still whose video was not backed up.
/// Pattern: upload still without tag 3 → upload video without tag 3 → add tag 3 after both settle.
/// On tag-add failure, retryOrPark requeues; settlement waits for confirmed tag.
final class BackupLivePhotoTagSettleTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var stateStore: MemoryBackupStateStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!
    private var tagAdder: SpyTagAdder!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-live-tag-settle-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = UploadBackupSyncQueueManifestStore(
            url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        )!
        stateStore = MemoryBackupStateStore()
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        tagAdder = SpyTagAdder(failing: false)
    }

    override func tearDown() {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeRunner(
        uploader: (any PhotoUploading)? = nil,
        tagAdder: (any PhotoTagAdding)? = nil
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: resolver,
            identityResolver: UploadDedupePipeline(
                store: identityStore, hasher: hasher, checker: checker,
                resourceCoordinator: .shared, now: { [clock] in clock!.now }),
            uploader: uploader ?? self.uploader,
            tagAdder: tagAdder,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: 180, uploadStallPollInterval: 5,
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
                throttle: BackupThrottlePolicy(baseConcurrency: 2),
                leavesOutMissingLivePhotoVideos: false
            ),
            throttleInputs: { .unconstrained },
            runtimeChanges: nil,
            clock: clock,
            events: nil,
            now: { [clock] in clock!.now }
        )
    }

    private func seedEntry(
        _ id: String,
        state: UploadBackupSyncQueueState = .discovered,
        attempts: Int = 0,
        ageSeconds: TimeInterval = 60
    ) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/\(id)")),
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: id, byteCount: 4, state: state, attempts: attempts,
            updatedAt: clock.now.addingTimeInterval(-ageSeconds)
        )
        _ = queueStore.upsert(entry)
        return entry
    }

    private func state(of entry: UploadBackupSyncQueueEntry) -> UploadBackupSyncQueueState? {
        queueEntryForTesting(in: queueStore, source: entry.source, revision: entry.revision)?.state
    }

    private func expectedHashes(id: String) -> (nameHash: String, contentHash: String) {
        let path = URL(fileURLWithPath: "/backup/\(id)").standardizedFileURL.path
        return ("nh(\(id))", expectedContentHash(path: path))
    }

    private func expectedContentHash(path: String) -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in path.utf8.enumerated() { digest[i % 20] ^= byte }
        let hex = UploadContentSHA1.hexString(digest: digest)
        return "ch(\(hex))"
    }

    // MARK: - RED tests (candidate A: no tag at creation; add after settle)

    func testStillUploadCarriesNoLivePhotoTagWhenVideoIsPresent() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let tagAdder = SpyTagAdder(failing: false)
        let runner = makeRunner(tagAdder: tagAdder)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["live.heic", "live.mov"],
            "still uploads first, then video")
        XCTAssertEqual(
            uploader.requests.map(\.tags),
            [[], []], "neither part carries tag 3 at creation")
        XCTAssertEqual(tagAdder.calls.count, 1, "tag added once after settle")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testLivePhotoTagAddedAfterBothPartsSettle() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let tagAdder = SpyTagAdder(failing: false)
        let runner = makeRunner(tagAdder: tagAdder)

        _ = await runner.runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.tags), [[], []], "no tag 3 on creation uploads")
        XCTAssertEqual(tagAdder.calls.map(\.tags), [[PhotoTag.livePhotos.rawValue]], "tag 3 added to the still")
        XCTAssertEqual(tagAdder.calls.count, 1, "tag 3 added exactly once, after both settle")
        XCTAssertEqual(tagAdder.calls.first?.uid.nodeID, testUID("live.heic").nodeID, "tag lands on the still")
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testTagAddFailurePreventsSettlementAndRetries() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let failingTagAdder = SpyTagAdder(failing: true)
        let runner = makeRunner(tagAdder: failingTagAdder)

        let progress = await runner.runUntilDrained()

        // The retry budget of the test configuration is 4 counted attempts; the drain walks through
        // every one of them (waitForScheduledRetries advances the clock past each backoff).
        XCTAssertEqual(
            failingTagAdder.calls.map(\.tags),
            Array(repeating: [PhotoTag.livePhotos.rawValue], count: 4),
            "tag add attempted on every retry")
        XCTAssertEqual(
            failingTagAdder.calls.first?.uid.nodeID, testUID("live.heic").nodeID, "tag targets the still")
        XCTAssertEqual(uploader.requests.count, 2, "still and video upload once; retries never re-upload")
        XCTAssertEqual(uploader.requests.map(\.tags), [[], []], "uploads succeed without tag 3")
        XCTAssertEqual(state(of: entry), .failed, "an unconfirmed tag never fakes settlement")
        XCTAssertEqual(progress.uploaded, 0)
        XCTAssertEqual(progress.failed, 1)
    }

    func testRelaunchAlreadyBackedUpPathRunsLivePhotoTagAdd() async throws {
        // Simulate a relaunch where the primary is already remote-active (knownFromManifest or activeDuplicate).
        // The decision skips the primary, uploads the missing video, then adds tag 3 after settle.
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let hashes = expectedHashes(id: "live.heic")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: hashes.contentHash,
                linkState: .active,
                linkID: "remote-main"
            )
        ]
        let tagAdder = SpyTagAdder(failing: false)
        let runner = makeRunner(tagAdder: tagAdder)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["live.mov"],
            "only the missing video uploads when primary is known")
        XCTAssertEqual(uploader.requests.map(\.tags), [[]], "video carries no tag 3")
        XCTAssertEqual(tagAdder.calls.map(\.tags), [[PhotoTag.livePhotos.rawValue]], "tag 3 added to remote still")
        XCTAssertEqual(tagAdder.calls.count, 1, "tag added once after video settles")
        XCTAssertEqual(tagAdder.calls.first?.uid.nodeID, "remote-main", "tag lands on the remote still")
        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(progress.alreadyBackedUp, 1)
    }

    func testPermanentlyFailedVideoStillGetsNoTagAnywhere() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let tagAdder = SpyTagAdder(failing: false)
        // Fail the video for good: UploadError.backend counts, so the row burns its retry budget and parks.
        let failingUploader = MockUploader(
            workDuration: .milliseconds(1), deliverProgress: false,
            failNames: ["live.mov"]
        )
        let runner = makeRunner(uploader: failingUploader, tagAdder: tagAdder)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            failingUploader.uploaded.map(\.request.name), ["live.heic"],
            "only the still finishes; the video never settles")
        XCTAssertTrue(failingUploader.uploaded.map(\.request.tags).allSatisfy { $0.isEmpty })
        XCTAssertEqual(tagAdder.calls.count, 0, "no tag added while video fails")
        XCTAssertEqual(state(of: entry), .failed)
        XCTAssertEqual(progress.failed, 1)
    }

    func testNilTagAdderParksRowInsteadOfSilentlySettling() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        // Defensive path only: production always wires ProtonClientFacade.photoTagAdder.
        let runner = makeRunner(tagAdder: nil)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["live.heic", "live.mov"],
            "both parts upload untagged")
        XCTAssertEqual(
            uploader.requests.map(\.tags), [[], []],
            "neither part carries tag 3 at creation")
        XCTAssertEqual(
            state(of: entry), .failed,
            "nil tagAdder fails visibly instead of faking settlement")
        XCTAssertEqual(progress.uploaded, 0)
        XCTAssertEqual(progress.failed, 1)
        let parkedRow = try queueStore.entry(for: entry.source, revision: entry.revision)
        let parkedIssue = BackupIssueRecord.decode(parkedRow?.lastError)
        XCTAssertEqual(
            parkedIssue?.kind, .localState,
            "nil tagAdder classifies as a local-state issue, not unknown")
        XCTAssertEqual(
            parkedIssue?.detail, UploadError.tagAdderUnavailable.errorDescription,
            "the parked reason names the tag-adder gap itself")
    }
}

// MARK: - Test Doubles (scoped to this file; shared internally via UploadFeatureTests target)

/// Internal memory backup state store (mirrors BackupSyncRunnerTests' nested class).
final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
        lock.withLock { rows[source]?[revision] }
    }

    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
        lock.withLock { !(rows[source]?.isEmpty ?? true) }
    }

    func upsert(_ record: UploadBackupAssetRecord) -> Bool {
        lock.withLock { rows[record.source, default: [:]][record.revision] = record }
        return true
    }

    func removeRecords(for source: UploadSourceIdentity, keeping revisions: Set<UploadBackupRevision>) -> Bool {
        lock.withLock { rows[source] = rows[source]?.filter { revisions.contains($0.key) } }
        return true
    }

    func count() -> Int {
        lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
    }
}
