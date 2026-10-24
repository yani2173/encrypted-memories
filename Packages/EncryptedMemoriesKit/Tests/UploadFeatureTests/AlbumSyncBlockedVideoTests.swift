import AlbumSyncCore
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Album Sync reports an album as complete only when every resource of each photo is saved. A Live Photo whose
/// video stays blocked behind a foreign draft keeps showing as a problem.
///
/// The real backup runner, dedupe pipeline, identity manifest, link lookup and Album Sync runner run in one chain.
/// Only the PhotoKit scan of `PhotoAlbumBackupExecutor` is replaced: `BackupReportExecutor` builds the same report
/// from the same queue store.
final class AlbumSyncBlockedVideoTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var stateStore: UploadBackupStateManifestStore!
    private var manifest: UploadIdentityManifestStore!
    private var manifestURL: URL!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!
    private var mappingStore: AlbumSyncMappingStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-blocked-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        stateStore = try XCTUnwrap(
            UploadBackupStateManifestStore(url: tempDir.appendingPathComponent("backup-state.sqlite")))
        manifestURL = tempDir.appendingPathComponent("upload-manifest.sqlite")
        manifest = try XCTUnwrap(UploadIdentityManifestStore(url: manifestURL))
        mappingStore = try XCTUnwrap(AlbumSyncMappingStore(url: tempDir.appendingPathComponent("mapping.sqlite")))
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        stateStore.close()
        manifest.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Backs up the album's assets with the real runner, then reports like `PhotoAlbumBackupExecutor`.
    private final class BackupReportExecutor: AlbumSyncBackupExecuting, @unchecked Sendable {
        let runner: BackupSyncRunner
        let queue: UploadBackupSyncQueueManifestStore
        let entries: [UploadBackupSyncQueueEntry]

        init(runner: BackupSyncRunner, queue: UploadBackupSyncQueueManifestStore, entries: [UploadBackupSyncQueueEntry])
        {
            self.runner = runner
            self.queue = queue
            self.entries = entries
        }

        func ensureBackedUp(
            localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
        ) async throws -> AlbumSyncBackupReport {
            _ = await runner.runUntilDrained(workIntent: .userInitiated)
            let summary = queue.summary()
            var problems: [String: BackupFailedItem] = [:]
            queue.forEachProblemEntry { entry in
                if entry.source.kind == .photoLibraryAsset, problems[entry.source.identifier] == nil {
                    problems[entry.source.identifier] = BackupFailedItem(entry: entry)
                }
                return true
            }
            var filenames: [String: String] = [:]
            for entry in entries { filenames[entry.source.identifier] = entry.originalFilename }
            return AlbumSyncBackupReport(
                total: summary.total, backedUp: summary.resolved, failed: summary.failed,
                sourceMissing: summary.sourceMissing, skippedRemoteDeletion: summary.skippedRemoteDeletions,
                problems: problems, filenames: filenames)
        }

        func stop() async {}
    }

    private struct LocalAlbum: AlbumSyncLocalAlbumSource {
        let identifiers: [String]
        func listAlbums() async throws -> [LocalAlbumSummary] { [] }
        func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents { .present(identifiers) }
    }

    private final class RemoteAlbum: AlbumSyncRemoteAlbumOps, @unchecked Sendable {
        private let lock = NSLock()
        private var members: Set<String> = []
        var memberLinkIDs: Set<String> { lock.withLock { members } }
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
        func createAlbum(name: String) async throws -> String { "remote-album" }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { memberLinkIDs }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            lock.withLock { members.formUnion(photos.map(\.uid.nodeID)) }
            var result = AlbumSyncAttachResult()
            result.attached = photos.count
            return result
        }
    }

    private func seedPhoto(_ name: String, secondaries: [String] = []) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: name),
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: "\(name).heic", byteCount: 4, state: .discovered, attempts: 0,
            updatedAt: clock.now.addingTimeInterval(-60))
        queueStore.upsert(entry)
        if !secondaries.isEmpty { resolver.setSecondaries(secondaries, for: name) }
        return entry
    }

    private func syncAlbum(_ entries: [UploadBackupSyncQueueEntry]) async throws -> (AlbumSyncReport, RemoteAlbum) {
        let runner = BackupSyncRunner(
            queue: queueStore, preflight: UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now }),
            resolver: resolver,
            identityResolver: UploadDedupePipeline(
                store: manifest, hasher: hasher, checker: checker, now: { [clock] in clock!.now }),
            uploader: uploader,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: 180, uploadStallPollInterval: 5,
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
                throttle: BackupThrottlePolicy(baseConcurrency: 2)),
            throttleInputs: { .unconstrained }, clock: clock, now: { [clock] in clock!.now })
        let remote = RemoteAlbum()
        let lookup = try XCTUnwrap(UploadManifestRemoteLinkLookup(manifestURL: manifestURL, policy: .conservative))
        let albumRunner = AlbumSyncRunner(
            localSource: LocalAlbum(identifiers: entries.map(\.source.identifier)),
            backup: BackupReportExecutor(runner: runner, queue: queueStore, entries: entries),
            remoteOps: remote, linkLookup: lookup, mappingStore: mappingStore)
        let report = try await albumRunner.sync(album: LocalAlbumSummary(id: "album-1", title: "Trip", assetCount: 1))
        await lookup.shutdown()
        return (report, remote)
    }

    private func foreignVideoDraft() -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(
            nameHash: "nh(live.mov)", contentHash: nil, linkState: .draft, linkID: "foreign-draft",
            clientUID: "another-installation")
    }

    // MARK: - Reproduction of issue 564

    func testALivePhotoWhoseVideoStaysBlockedBehindAForeignDraftIsNotReportedAsCompletelySynced() async throws {
        let entry = seedPhoto("live", secondaries: ["live.mov"])
        checker.remoteItemsByNameHash["nh(live.mov)"] = [foreignVideoDraft()]

        let (report, remote) = try await syncAlbum([entry])

        // The backup keeps the video blocked and uploaded only the photo.
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.state, .blockedByDraft)
        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic"])
        XCTAssertEqual(remote.memberLinkIDs, ["node-live.heic"], "the main photo is in the album")
        XCTAssertFalse(
            report.isFullySynced,
            "attached \(report.attached), unattachable \(report.unattachable), problems \(report.problems.count)")
        XCTAssertEqual(report.problems.map(\.id).count, 1, "the Live Photo is listed as a problem")
        XCTAssertEqual(report.incomplete, 1)
        XCTAssertEqual(report.problems.first?.id, AlbumSyncProblemList.incompleteIDPrefix + "live")
        XCTAssertEqual(
            report.problems.first?.reason, L10n.string("backup.issue_remote_draft"),
            "the list names the backup's own reason")
        XCTAssertEqual(
            mappingStore.mapping(localAlbumID: "album-1")?.lastFailedCount, 1,
            "the album row counts the Live Photo")
    }

    // MARK: - Controls that hold before and after the fix

    func testALivePhotoWithBothResourcesSavedIsReportedAsCompletelySynced() async throws {
        let entry = seedPhoto("live", secondaries: ["live.mov"])

        let (report, remote) = try await syncAlbum([entry])

        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic", "live.mov"])
        XCTAssertEqual(remote.memberLinkIDs, ["node-live.heic"])
        XCTAssertTrue(report.isFullySynced)
        XCTAssertTrue(report.problems.isEmpty)
    }

    func testAPhotoWithoutSecondariesIsReportedAsCompletelySynced() async throws {
        let entry = seedPhoto("plain")

        let (report, _) = try await syncAlbum([entry])

        XCTAssertTrue(report.isFullySynced)
        XCTAssertTrue(report.problems.isEmpty)
    }
}
