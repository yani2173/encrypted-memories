import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

private struct PartialFailureCatalog: UploadBackupAssetCatalog {
    let candidate: UploadBackupAssetCandidate
    let error: FolderEnumerationError

    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(candidate)
            continuation.finish(throwing: error)
        }
    }
}

/// Folder sync uses real temporary files, the SQLite queue, streaming hashing, and file resolution.
/// A file that vanishes during scan, check, or upload becomes `sourceMissing` without re-uploading.
final class FolderBackupIntegrationTests: XCTestCase {
    private final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
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

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }

    private var tempDir: URL!
    private var folder: URL!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var preflight: UploadBackupPreflightIndex!
    private var engine: UploadBackupSyncEngine!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!
    private var uploader: MockUploader!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-backup-integration-\(UUID().uuidString)", isDirectory: true)
        folder = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
            ))
        preflight = UploadBackupPreflightIndex(store: MemoryBackupStateStore())
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queueStore)
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: FakeIdentityStore(), checker: checker)
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRunner() -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: FileBackupResourceResolver(),
            identityResolver: pipeline,
            uploader: uploader
        )
    }

    func testScanRunRescanBacksUpOnceAndOnlyOnce() async throws {
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }

        // First pass: everything is new, everything uploads exactly once.
        let firstScan = try await engine.scan(FolderBackupCatalog(folder: folder))
        XCTAssertEqual(firstScan.scanned, 3)
        XCTAssertEqual(firstScan.queuedForWork, 3)

        let firstRun = await makeRunner().runUntilDrained()
        XCTAssertEqual(firstRun.uploaded, 3)
        XCTAssertEqual(firstRun.backedUp, 3)
        XCTAssertEqual(firstRun.fraction, 1.0)
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"])
        XCTAssertTrue(
            uploader.requests.allSatisfy { $0.expectedSHA1 != nil },
            "backup uploads must carry the integrity digest from the shared pipeline")

        // Second pass: the preflight index proves everything backed up without touching bytes.
        let secondScan = try await engine.scan(FolderBackupCatalog(folder: folder))
        XCTAssertEqual(secondScan.alreadyBackedUp, 3)
        XCTAssertEqual(secondScan.queuedForWork, 0)

        let secondRun = await makeRunner().runUntilDrained()
        XCTAssertEqual(uploader.requests.count, 3, "a repeat sync must never re-upload")
        XCTAssertEqual(secondRun.backedUp, 3)
        XCTAssertEqual(secondRun.hasOutstandingWork, false)
    }

    /// Identical content in copied folders uploads once and records every source as backed up.
    func testCopiedFoldersUploadEachContentOnlyOnce() async throws {
        let sync1 = tempDir.appendingPathComponent("sync1", isDirectory: true)
        let sync2 = tempDir.appendingPathComponent("sync2", isDirectory: true)
        try FileManager.default.createDirectory(at: sync1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync2, withIntermediateDirectories: true)
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            let bytes = Data("photo-bytes-\(name)".utf8)
            try bytes.write(to: sync1.appendingPathComponent(name))
            try bytes.write(to: sync2.appendingPathComponent(name))
        }

        _ = try await engine.scan(FolderBackupCatalog(folder: sync1))
        _ = try await engine.scan(FolderBackupCatalog(folder: sync2))
        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            uploader.requests.count, 3,
            "a byte-identical copied folder must not re-upload a single photo")
        XCTAssertEqual(progress.uploaded, 3)
        XCTAssertEqual(progress.alreadyBackedUp, 3)
        XCTAssertEqual(progress.backedUp, 6, "BOTH folders' sources must be proven backed up")
        XCTAssertEqual(progress.failed + progress.sourceMissing + progress.blocked, 0)

        // A third copy attached later: zero new uploads, everything already backed up.
        let sync3 = tempDir.appendingPathComponent("sync3", isDirectory: true)
        try FileManager.default.createDirectory(at: sync3, withIntermediateDirectories: true)
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            try Data("photo-bytes-\(name)".utf8).write(to: sync3.appendingPathComponent(name))
        }
        _ = try await engine.scan(FolderBackupCatalog(folder: sync3))
        let third = await makeRunner().runUntilDrained()

        XCTAssertEqual(uploader.requests.count, 3, "a later copied folder must upload nothing new")
        XCTAssertEqual(third.backedUp, 9)
    }

    func testCopiedContentWithDifferentFilenamesUploadsOnce() async throws {
        let sync1 = tempDir.appendingPathComponent("sync1", isDirectory: true)
        let sync2 = tempDir.appendingPathComponent("sync2", isDirectory: true)
        try FileManager.default.createDirectory(at: sync1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync2, withIntermediateDirectories: true)
        let bytes = Data("the-same-photo-bytes".utf8)
        try bytes.write(to: sync1.appendingPathComponent("IMG_0001.jpg"))
        try bytes.write(to: sync2.appendingPathComponent("export (1).jpg"))

        _ = try await engine.scan(FolderBackupCatalog(folder: sync1))
        _ = try await engine.scan(FolderBackupCatalog(folder: sync2))
        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            uploader.requests.count, 1,
            "identical bytes must dedupe even when the filename differs")
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 2)
    }

    func testFileDeletedBetweenScanAndRunIsRemovedFromQueue() async throws {
        let doomed = folder.appendingPathComponent("gone.jpg")
        try Data("bytes".utf8).write(to: doomed)

        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        try FileManager.default.removeItem(at: doomed)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(progress.sourceMissing, 0)
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(queueStore.count(), 0)
    }

    func testPartialEnumerationFailurePreservesQueuedPrefix() async throws {
        let firstURL = folder.appendingPathComponent("a-first.jpg")
        try Data("first".utf8).write(to: firstURL)
        let candidate = try FolderBackupCatalog.candidate(for: firstURL)
        let inaccessibleSubtree = folder.appendingPathComponent("z-inaccessible", isDirectory: true)
        let error = FolderEnumerationError(
            operation: .readDirectory,
            url: inaccessibleSubtree,
            failureClass: .permissionDenied,
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.EACCES.rawValue)
        )

        do {
            _ = try await engine.scan(PartialFailureCatalog(candidate: candidate, error: error))
            XCTFail("a partial folder enumeration must not report a successful scan")
        } catch let caught as FolderEnumerationError {
            XCTAssertEqual(caught, error)
        }

        let summary = queueStore.summary()!
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.waiting, 1)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.alreadyBackedUp, 0)
        XCTAssertEqual(summary.uploaded, 0)
    }
}
