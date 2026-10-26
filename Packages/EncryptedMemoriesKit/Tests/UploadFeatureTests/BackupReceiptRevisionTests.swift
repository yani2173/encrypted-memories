import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// A saved upload receipt settles only the revision it was saved for. A source that changed after the remote commit
/// takes the ordinary path, so its new bytes are hashed, deduplicated and uploaded on their own.
final class BackupReceiptRevisionTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-receipt-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        preflight = UploadBackupPreflightIndex(store: MemoryStateStore(), now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        // A new upload of the same name gets its own Proton link, as on the server.
        uploader.distinctNodesForRepeatedNames = true
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The comparison that every source kind goes through

    func testAReceiptBelongsOnlyToTheRevisionWhoseBytesItUploaded() throws {
        for kind in [UploadSourceIdentity.Kind.fileURL, .photoLibraryAsset] {
            let entry = UploadBackupSyncQueueEntry(
                source: UploadSourceIdentity(kind: kind, identifier: "/backup/photo.jpg"), revision: revision(10),
                originalFilename: "photo.jpg", byteCount: 4, updatedAt: clock.now)
            func belongs(_ receipt: UploadRemoteCommitReconciliation, resolved: TimeInterval) -> Bool {
                BackupSyncRunner.receiptBelongs(receipt, to: entry, resolvedRevision: revision(resolved))
            }
            let saved = descriptor(for: entry)
            let unchanged = reconciliation(for: entry, descriptor: saved, binding: (10, 10))
            let drifted = reconciliation(for: entry, descriptor: saved, binding: (10, 20))
            let withoutUpload = reconciliation(for: entry, descriptor: saved, binding: (10, nil))
            let legacy = reconciliation(for: entry, descriptor: nil, binding: nil)
            let descriptorOnly = reconciliation(for: entry, descriptor: saved, binding: nil)
            let bindingOnly = reconciliation(for: entry, descriptor: nil, binding: (10, 20))

            XCTAssertTrue(belongs(unchanged, resolved: 10), "\(kind)")
            XCTAssertFalse(belongs(unchanged, resolved: 20), "a later change must not settle (\(kind))")
            XCTAssertTrue(belongs(drifted, resolved: 20), "the uploaded revision settles (\(kind))")
            XCTAssertFalse(
                belongs(drifted, resolved: 10), "the row revision is not what was uploaded (\(kind))")
            XCTAssertTrue(belongs(withoutUpload, resolved: 10), "\(kind)")
            XCTAssertFalse(belongs(withoutUpload, resolved: 20), "\(kind)")
            XCTAssertTrue(belongs(legacy, resolved: 10), "\(kind)")
            XCTAssertFalse(belongs(legacy, resolved: 20), "\(kind)")
            XCTAssertTrue(belongs(descriptorOnly, resolved: 10), "a receipt without binding uses the row (\(kind))")
            XCTAssertFalse(belongs(descriptorOnly, resolved: 20), "\(kind)")
            XCTAssertTrue(belongs(bindingOnly, resolved: 20), "a binding needs no saved descriptor (\(kind))")
            XCTAssertFalse(belongs(bindingOnly, resolved: 10), "\(kind)")
            XCTAssertFalse(
                belongs(reconciliation(for: entry, descriptor: saved, binding: (9, 10)), resolved: 10),
                "a receipt bound to another row settles nothing (\(kind))")
        }
    }

    /// A receipt saved by a released build has no uploaded revision. It still decodes, and the row revision stands in.
    func testAReceiptOfAReleasedBuildDecodesWithoutTheUploadedRevision() throws {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/released.jpg")), revision: revision(10),
            originalFilename: "released.jpg", byteCount: 4, updatedAt: clock.now)
        let current = reconciliation(for: entry, descriptor: descriptor(for: entry), binding: (10, nil))
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var binding = try XCTUnwrap(json["queueBinding"] as? [String: Any])
        XCTAssertNil(binding["uploadedRevision"], "a nil uploaded revision is not written")
        binding.removeValue(forKey: "uploadedRevision")
        json["queueBinding"] = binding
        let released = try JSONDecoder().decode(
            UploadRemoteCommitReconciliation.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(released.queueBinding?.revision, entry.revision)
        XCTAssertNil(released.queueBinding?.uploadedRevision)
        XCTAssertTrue(BackupSyncRunner.receiptBelongs(released, to: entry, resolvedRevision: revision(10)))
        XCTAssertFalse(BackupSyncRunner.receiptBelongs(released, to: entry, resolvedRevision: revision(20)))
    }

    // MARK: - Route: the source changed after the scan and before the upload

    /// The scan queued revision A, the photo changed, and the pass uploaded revision R. The receipt belongs to R, so
    /// the next pass that resolves R settles it without hashing or uploading again, and the handoff stays `uploaded`.
    func testAReceiptOfARevisionThatChangedBeforeTheUploadSettlesThatRevision() async throws {
        let entry = seedEntry("drifted-before-upload.jpg", kind: .photoLibraryAsset)
        let uploaded = resolver.defaultModified.addingTimeInterval(120)
        resolver.setModified(uploaded, for: entry.source.identifier)
        let events = HandoffLog()
        let pipeline = makePipeline()
        _ = await makeRunner(
            identityResolver: RecordFailingIdentityResolver(inner: pipeline, failures: 2), events: events
        ).runUntilDrained(mode: .eligibleOnly)
        let receipt = try XCTUnwrap(
            queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        XCTAssertEqual(receipt.queueBinding?.revision, entry.revision)
        XCTAssertEqual(receipt.queueBinding?.uploadedRevision, UploadBackupRevision(date: uploaded))
        XCTAssertEqual(uploader.requests.count, 1)
        let hashes = hasher.hashCount

        clock.advance(by: 2)
        _ = await makeRunner(identityResolver: pipeline, events: events).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(uploader.requests.count, 1, "the committed bytes are never uploaded again")
        XCTAssertEqual(hasher.hashCount, hashes, "settling a receipt needs no hash")
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        XCTAssertEqual(identityStore.record(for: entry.source)?.remoteLinkID, receipt.receipt.remoteLinkID)
        XCTAssertFalse(events.kinds.contains(.deduplicated), "the source keeps its uploaded handoff")
        XCTAssertTrue(events.kinds.contains(.uploaded))
    }

    /// The same drift for the paired video of a Live Photo: its receipt belongs to the uploaded revision as well, so the
    /// video settles without a second upload.
    func testAVideoReceiptOfARevisionThatChangedBeforeTheUploadSettlesThatRevision() async throws {
        let entry = seedEntry("drifted-live.jpg", kind: .photoLibraryAsset)
        let uploaded = resolver.defaultModified.addingTimeInterval(120)
        resolver.setModified(uploaded, for: entry.source.identifier)
        resolver.setSecondaries(["drifted-live.mov"], for: entry.source.identifier)
        let pipeline = makePipeline()
        _ = await makeRunner(
            identityResolver: RecordFailingIdentityResolver(
                inner: pipeline, failures: 2, failureFilename: "drifted-live.mov")
        ).runUntilDrained(mode: .eligibleOnly)
        let receipt = try XCTUnwrap(
            queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        XCTAssertEqual(receipt.source.resource, .livePairedVideo)
        XCTAssertEqual(receipt.queueBinding?.uploadedRevision, UploadBackupRevision(date: uploaded))

        clock.advance(by: 3600)
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(
            uploader.requests.filter { $0.name == "drifted-live.mov" }.count, 1,
            "the committed video is never uploaded again")
        XCTAssertEqual(identityStore.record(for: receipt.source)?.remoteLinkID, receipt.receipt.remoteLinkID)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    // MARK: - Route: the source returned to the queued revision after another one was uploaded

    /// The scan queued A, the pass uploaded B, and the source returned to A with the same date and size. The receipt
    /// belongs to B and must not settle A.
    func testAReceiptOfAnotherUploadedRevisionDoesNotSettleTheQueuedRevision() async throws {
        let entry = seedEntry("returned.jpg")
        let path = URL(fileURLWithPath: entry.source.identifier).path
        resolver.setModified(resolver.defaultModified.addingTimeInterval(120), for: entry.source.identifier)
        hasher.contentSeeds[path] = "revision B"
        let pipeline = makePipeline()
        _ = await makeRunner(identityResolver: RecordFailingIdentityResolver(inner: pipeline, failures: 2))
            .runUntilDrained(mode: .eligibleOnly)
        let receipt = try XCTUnwrap(
            queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        XCTAssertNotEqual(receipt.queueBinding?.uploadedRevision, entry.revision)

        resolver.setModified(resolver.defaultModified, for: entry.source.identifier)
        hasher.contentSeeds[path] = nil
        clock.advance(by: 2)
        let recorder = RecordingIdentityResolver(inner: pipeline)
        _ = await makeRunner(identityResolver: recorder).runUntilDrained(mode: .eligibleOnly)

        XCTAssertFalse(
            recorder.linkIDs.contains(receipt.receipt.remoteLinkID), "the receipt of B must not settle A")
        XCTAssertEqual(uploader.requests.count, 2, "A uploads its own bytes")
        XCTAssertNotEqual(identityStore.record(for: entry.source)?.sha1Hex, receipt.identity.sha1Hex)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    // MARK: - Route: the manifest write failed after the remote commit

    func testAChangedPhotoAfterAFailedManifestWriteUploadsItsOwnBytes() async throws {
        let entry = seedEntry("changed-after-commit.jpg")
        let pipeline = makePipeline()
        _ = await makeRunner(identityResolver: RecordFailingIdentityResolver(inner: pipeline, failures: 2))
            .runUntilDrained(mode: .eligibleOnly)
        let parked = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        let receipt = try XCTUnwrap(parked.remoteCommitReconciliation)
        XCTAssertEqual(parked.state, .needsRemoteReconciliation)
        XCTAssertEqual(uploader.requests.count, 1)

        // The photo changes before the receipt is reconciled.
        let changed = resolver.defaultModified.addingTimeInterval(120)
        resolver.setModified(changed, for: entry.source.identifier)
        hasher.contentSeeds[URL(fileURLWithPath: entry.source.identifier).path] = "changed content"
        clock.advance(by: 2)
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(uploader.requests.count, 2, "the changed revision uploads its own bytes")
        let record = try XCTUnwrap(identityStore.record(for: entry.source))
        XCTAssertEqual(record.modificationDate, changed)
        XCTAssertNotEqual(record.sha1Hex, receipt.identity.sha1Hex, "the record must hold the hash of the new bytes")
        XCTAssertNotEqual(record.remoteLinkID, receipt.receipt.remoteLinkID)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    /// The scan queued the new revision, and the pass backs it up before it reaches the receipt of the old one. The old
    /// receipt must not replace the newer record of the source.
    func testAnEarlierReceiptNeverReplacesTheNewerBackupOfTheSource() async throws {
        let entry = seedEntry("backed-up-first.jpg")
        let pipeline = makePipeline()
        _ = await makeRunner(identityResolver: RecordFailingIdentityResolver(inner: pipeline, failures: 2))
            .runUntilDrained(mode: .eligibleOnly)
        let receipt = try XCTUnwrap(
            queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)

        let changed = resolver.defaultModified.addingTimeInterval(120)
        resolver.setModified(changed, for: entry.source.identifier)
        hasher.contentSeeds[URL(fileURLWithPath: entry.source.identifier).path] = "newer content"
        let newer = UploadBackupSyncQueueEntry(
            source: entry.source, revision: UploadBackupRevision(date: changed),
            originalFilename: entry.originalFilename, byteCount: entry.byteCount, updatedAt: clock.now)
        XCTAssertTrue(queueStore.upsert(newer))
        clock.advance(by: 2)
        // One item at a time: the newer revision runs first, the receipt of the old one after it.
        let recorder = RecordingIdentityResolver(inner: pipeline)
        _ = await makeRunner(identityResolver: recorder, concurrency: 1).runUntilDrained(mode: .eligibleOnly)

        XCTAssertFalse(recorder.linkIDs.isEmpty)
        XCTAssertFalse(
            recorder.linkIDs.contains(receipt.receipt.remoteLinkID),
            "the receipt of the old revision must not be recorded after the newer backup, not even for a moment")
        XCTAssertEqual(uploader.requests.count, 2, "only the newer revision uploads again")
        let record = try XCTUnwrap(identityStore.record(for: entry.source))
        XCTAssertEqual(record.modificationDate, changed, "the newer backup keeps its record")
        XCTAssertNotEqual(record.sha1Hex, receipt.identity.sha1Hex)
        XCTAssertNotEqual(record.remoteLinkID, receipt.receipt.remoteLinkID)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    // MARK: - Route: the committed resource was not available for reconciliation

    func testAReceiptOfAMissingResourceDoesNotSettleTheResourceOfAChangedPhoto() async throws {
        let entry = seedEntry("live.jpg")
        let video = UploadSourceIdentity(
            kind: entry.source.kind, identifier: entry.source.identifier, resource: .livePairedVideo)
        let savedVideo = UploadResourceDescriptor(
            source: video, fileURL: URL(fileURLWithPath: "\(entry.source.identifier)#live.mov"),
            filename: "live.mov", fileSize: 2, modificationDate: resolver.defaultModified)
        let receipt = UploadRemoteCommitReconciliation(
            source: video,
            identity: UploadIdentity(
                correctedName: ProtonPhotoNameCorrection.correctedName(for: "live.mov"), nameHash: "video-name",
                sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "video-content"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "earlier-video"),
            descriptor: UploadResourceDescriptorSnapshot(savedVideo),
            queueBinding: UploadRemoteCommitQueueBinding(source: entry.source, revision: entry.revision))
        XCTAssertTrue(
            queueStore.markNeedsRemoteReconciliation(
                source: entry.source, revision: entry.revision, reconciliation: receipt, lastError: "waiting",
                updatedAt: clock.now.addingTimeInterval(-60)))
        let pipeline = makePipeline()

        // The library does not list the video now: the row stays parked with its receipt.
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)
        let parked = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(parked.state, .needsRemoteReconciliation)
        XCTAssertEqual(parked.remoteCommitReconciliation, receipt)

        // The photo changes and lists its video again, with new bytes.
        resolver.setModified(resolver.defaultModified.addingTimeInterval(120), for: entry.source.identifier)
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        hasher.contentSeeds["\(entry.source.identifier)#live.mov"] = "changed video"
        clock.advance(by: 3600)
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(
            uploader.requests.contains { $0.name == "live.mov" }, "the changed video uploads its own bytes")
        let record = try XCTUnwrap(identityStore.record(for: video))
        XCTAssertNotEqual(record.remoteLinkID, "earlier-video", "the earlier receipt must not settle the new video")
        XCTAssertNotEqual(record.sha1Hex, receipt.identity.sha1Hex)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    // MARK: - Fixtures

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSince1970: seconds))
    }

    private func descriptor(for entry: UploadBackupSyncQueueEntry) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: entry.source, fileURL: URL(fileURLWithPath: entry.source.identifier),
            filename: entry.originalFilename, fileSize: entry.byteCount ?? 1, modificationDate: clock.now)
    }

    private func reconciliation(
        for entry: UploadBackupSyncQueueEntry, descriptor: UploadResourceDescriptor?,
        binding: (row: TimeInterval, uploaded: TimeInterval?)?
    ) -> UploadRemoteCommitReconciliation {
        UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: ProtonPhotoNameCorrection.correctedName(for: entry.originalFilename),
                nameHash: "name", sha1Hex: String(repeating: "cd", count: 20),
                sha1Digest: Data(repeating: 0xCD, count: 20), contentHash: "content"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link"),
            descriptor: descriptor.map(UploadResourceDescriptorSnapshot.init),
            queueBinding: binding.map {
                UploadRemoteCommitQueueBinding(
                    source: entry.source, revision: revision($0.row), uploadedRevision: $0.uploaded.map(revision))
            })
    }

    private func seedEntry(_ id: String, kind: UploadSourceIdentity.Kind = .fileURL) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: kind, identifier: URL(fileURLWithPath: "/backup/\(id)").path),
            revision: UploadBackupRevision(date: resolver.defaultModified), originalFilename: id, byteCount: 4,
            updatedAt: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(queueStore.upsert(entry))
        return entry
    }

    private func makePipeline() -> UploadDedupePipeline {
        UploadDedupePipeline(
            store: identityStore, hasher: hasher, checker: checker, resourceCoordinator: .shared,
            now: { [clock] in clock!.now })
    }

    private func makeRunner(
        identityResolver: any UploadIdentityResolving, concurrency: Int = 2, events: (any BackupItemEventSink)? = nil
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore, preflight: preflight, resolver: resolver, identityResolver: identityResolver,
            uploader: uploader, tagAdder: nil, editReplacement: nil, resourceCoordinator: .shared,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: 180, uploadStallPollInterval: 5,
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
                throttle: BackupThrottlePolicy(baseConcurrency: concurrency)),
            throttleInputs: { .unconstrained }, runtimeChanges: nil, clock: clock, events: events,
            now: { [clock] in clock!.now })
    }

    /// Forwards to the pipeline and keeps every recorded upload.
    private final class RecordingIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
        private let inner: UploadDedupePipeline
        private let lock = NSLock()
        private var recorded: [String] = []
        /// The Proton link of every recorded upload, in order.
        var linkIDs: [String] { lock.withLock { recorded } }

        init(inner: UploadDedupePipeline) { self.inner = inner }

        func remoteIndexPreparationNotNeeded() async { await inner.remoteIndexPreparationNotNeeded() }

        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            try await inner.resolve(descriptor)
        }

        func prepareRemoteIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws {
            try await inner.prepareRemoteIndex(progress: progress)
        }

        func prime(_ descriptors: [UploadResourceDescriptor]) async {
            await inner.prime(descriptors)
        }

        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String,
            remoteLinkID: String
        ) async throws {
            lock.withLock { recorded.append(remoteLinkID) }
            try await inner.recordUploaded(
                descriptor, identity: identity, remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID)
        }

        func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
            await inner.remoteCommitNeedsReconciliation(descriptor)
        }

        func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
            await inner.uploadDidFail(descriptor)
        }
    }

    /// Keeps the kind of every handoff; everything else is accepted.
    private final class HandoffLog: BackupItemEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [PendingHandoffKind] = []
        var kinds: [PendingHandoffKind] { lock.withLock { recorded } }

        func recordUploadEvidence(source: UploadSourceIdentity, revision: UploadBackupRevision, replaces: [PhotoUID]) {}

        func settleUploadEvidence(source: UploadSourceIdentity, revision: UploadBackupRevision, retired: Set<String>) {}

        func recordHandoff(
            source: UploadSourceIdentity, revision: UploadBackupRevision, remote: PhotoUID, kind: PendingHandoffKind
        ) -> PendingHandoffOutcome {
            lock.withLock { recorded.append(kind) }
            return .recorded
        }

        func isExcluded(source: UploadSourceIdentity) -> Bool? { false }

        func reportProgress(source: UploadSourceIdentity, revision: UploadBackupRevision, step: Int?) {}
    }

    private final class MemoryStateStore: UploadBackupStateStore, @unchecked Sendable {
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
}
