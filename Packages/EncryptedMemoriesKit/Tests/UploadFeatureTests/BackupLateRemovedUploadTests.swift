import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class BackupLateRemovedUploadTests: XCTestCase {
    func testCancellationKeepsARemovedSourcesLateUploadAfterReopen() async throws {
        try await assertLateUploadSurvives(timeout: false, excluded: false)
    }

    func testTimeoutKeepsARemovedSourcesLateUploadAfterReopen() async throws {
        try await assertLateUploadSurvives(timeout: true, excluded: false)
    }

    func testCancellationKeepsAnExcludedSourcesLateUploadOwedToTrashAfterReopen() async throws {
        try await assertLateUploadSurvives(timeout: false, excluded: true)
    }

    func testTimeoutKeepsAnExcludedSourcesLateUploadOwedToTrashAfterReopen() async throws {
        try await assertLateUploadSurvives(timeout: true, excluded: true)
    }

    private func assertLateUploadSurvives(
        timeout: Bool, excluded: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("late-removed-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        defer { queue.close() }
        let state = try XCTUnwrap(
            UploadBackupStateManifestStore(
                url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)))
        defer { state.close() }
        let pendingURL = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let pending = try XCTUnwrap(PendingBackupManifestStore(url: pendingURL))
        defer { pending.close() }
        let clock = BackupTestClock()
        let resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3_600))
        let identities = FakeIdentityStore()
        let recorder = PendingBackupEventRecorder(store: pending, now: { clock.now })
        let name = "late-\(timeout)-\(excluded).jpg"
        let uploader = CommitThenGateUploader(gatedName: name)
        func enqueue(_ name: String, age: TimeInterval) throws -> UploadBackupSyncQueueEntry {
            let entry = UploadBackupSyncQueueEntry(
                source: .file(URL(fileURLWithPath: "/backup/\(name)")),
                revision: UploadBackupRevision(date: resolver.defaultModified), originalFilename: name,
                byteCount: 4, state: .discovered, attempts: 0,
                updatedAt: clock.now.addingTimeInterval(-age))
            XCTAssertTrue(queue.upsert(entry), file: file, line: line)
            return entry
        }
        let removed = try enqueue(name, age: 600)
        let next = try enqueue("after-\(name)", age: 60)
        let runner = BackupSyncRunner(
            queue: queue,
            preflight: UploadBackupPreflightIndex(store: state, now: { clock.now }),
            resolver: resolver,
            identityResolver: UploadDedupePipeline(
                store: identities, hasher: FakeHasher(), checker: FakeChecker(), now: { clock.now }),
            uploader: uploader,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: timeout ? 0.05 : 60,
                uploadStallPollInterval: timeout ? 0.01 : 5,
                throttle: BackupThrottlePolicy(baseConcurrency: 1)),
            clock: clock, events: recorder, now: { clock.now })
        let drain = Task { await runner.runUntilDrained() }
        await uploader.committed.wait()
        if timeout { await uploader.cancelled.wait() }
        let key = PendingSourceKey(removed.source)
        if excluded {
            XCTAssertNotNil(
                pending.exclude(
                    [PendingExclusionRequest(key: key, presentation: nil, remote: nil, revision: removed.revision)],
                    at: clock.now), file: file, line: line)
        }
        let removal = Task {
            await runner.removeSources(kind: removed.source.kind, identifiers: [removed.source.identifier])
        }
        await uploader.cancelled.wait()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try queue.entry(for: removed.source, revision: removed.revision) != nil,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        let removedBeforeResult = try queue.entry(for: removed.source, revision: removed.revision) == nil
        await uploader.returnGate.signal()
        _ = await removal.value
        let progress = await drain.value
        recorder.finish()

        XCTAssertTrue(removedBeforeResult, file: file, line: line)
        XCTAssertNil(try queue.entry(for: removed.source, revision: removed.revision), file: file, line: line)
        XCTAssertNil(identities.record(for: removed.source)?.remoteLinkID, file: file, line: line)
        XCTAssertEqual(
            try queue.entry(for: next.source, revision: next.revision)?.state, .completed, file: file, line: line)
        XCTAssertEqual(progress.failed, 0, file: file, line: line)

        pending.close()
        let reopened = try XCTUnwrap(PendingBackupManifestStore(url: pendingURL))
        defer { reopened.close() }
        let handoff = try XCTUnwrap(
            reopened.latestHandoffsRead(for: [key])[key]?.handoff,
            "the removed source's verified upload must survive a store reopen", file: file, line: line)
        XCTAssertEqual(handoff.revision, removed.revision, file: file, line: line)
        XCTAssertEqual(handoff.remote, testUID(name), file: file, line: line)
        XCTAssertEqual(handoff.kind, .uploaded, file: file, line: line)
        if excluded {
            let owed = try XCTUnwrap(reopened.sourceStateRead(for: key).state, file: file, line: line)
            XCTAssertEqual(owed.desired, .excluded, file: file, line: line)
            XCTAssertEqual(owed.remote, testUID(name), file: file, line: line)
            XCTAssertTrue(owed.needsRemoteTrash, file: file, line: line)
        } else {
            XCTAssertEqual(reopened.sourceStateRead(for: key), .readable(nil), file: file, line: line)
        }
    }
}
