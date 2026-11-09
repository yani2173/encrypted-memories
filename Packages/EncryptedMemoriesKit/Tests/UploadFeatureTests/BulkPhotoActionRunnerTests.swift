import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

@MainActor
final class BulkPhotoActionRunnerTests: XCTestCase {
    func testAcknowledgingTheResultKeepsItUntilAcknowledgementThenAllowsAFreshCapture() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .backUpAgain))
        XCTAssertTrue(runner.start(confirmation) { _ in true })
        await runner.waitUntilFinished()
        XCTAssertEqual(runner.summary?.completed, 3)
        runner.dismissSummary()
        XCTAssertNil(runner.summary)
        XCTAssertEqual(runner.total, 0)
        XCTAssertEqual(runner.processed, 0)
        XCTAssertEqual(runner.prepare(rows(2), action: .backUpAgain)?.count, 2)
    }

    func testAnAcknowledgementDuringTheRunNeverClearsItsProgress() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .restore))
        XCTAssertTrue(
            runner.start(confirmation) { _ in
                runner.dismissSummary()
                XCTAssertEqual(runner.total, 3)
                XCTAssertEqual(runner.completed, runner.processed)
                return true
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(runner.summary?.total, 3)
    }

    func testEmptyAndRepeatedPendingConfirmationNeverReplaceConsent() throws {
        let runner = BulkPhotoActionRunner()
        XCTAssertNil(runner.prepare([], action: .backUpAgain))
        let first = try XCTUnwrap(runner.prepare(rows(3), action: .backUpAgain))
        XCTAssertNil(runner.prepare(rows(7), action: .restore))
        XCTAssertEqual(runner.confirmation, first)
    }

    func testAReadThatDecodesOnlyAPrefixNeverCreatesConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { queue.close() }
        for (id, revision) in [("valid", Int64(2)), ("broken", 1)] {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: id),
                        revision: .init(rawValue: revision), originalFilename: "\(id).heic", state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: Date())))
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db, "UPDATE backup_sync_queue SET source_kind='invalid-kind' WHERE source_id='broken';", nil, nil, nil),
            SQLITE_OK)
        let runner = BulkPhotoActionRunner()
        let captured = await runner.prepareBackUpAgain(in: queue)
        XCTAssertNil(captured, "a valid first row never turns an incomplete read into all photos")
        XCTAssertNil(runner.confirmation)
    }

    func testGracefulStopFinishesTheAdmittedPhotoWithoutCancellingItsStep() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .backUpAgain))
        var touched: [String] = []
        XCTAssertTrue(
            runner.start(confirmation) { item in
                touched.append(item.id)
                runner.stopAfterCurrentPhoto()
                await Task.yield()
                XCTAssertFalse(Task.isCancelled)
                return true
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(touched, ["0"])
        XCTAssertEqual(runner.summary?.completed, 1)
        XCTAssertEqual(runner.summary?.stayed, 2)
        XCTAssertEqual(runner.summary?.cancelled, true)
    }

    func testCaptureCountsAPhotoOnceWhenOneDecisionSettlesItsSiblingRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
        defer { queue.close() }
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "edited-photo")
        for rawRevision in [Int64(1), 2] {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: source, revision: .init(rawValue: rawRevision), originalFilename: "edited.heic",
                        state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: Date())))
        }
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let captured = await runner.prepareBackUpAgain(in: queue)
        let confirmation = try XCTUnwrap(captured)
        XCTAssertEqual(confirmation.count, 1, "two revisions are one photo")
        XCTAssertEqual(confirmation.items.first?.revision, .init(rawValue: 2), "consent names the newest version")
        XCTAssertEqual(confirmation.revisionsBySource[source], [.init(rawValue: 1), .init(rawValue: 2)])
        var calls = 0
        XCTAssertTrue(
            runner.start(confirmation) { _ in
                calls += 1
                return calls == 1
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(runner.summary?.completed, 1)
        XCTAssertEqual(runner.summary?.stayed, 0, "settled sibling revisions are not unchanged photos")
    }

    func testCaptureReadsTheEntireDecisionGroupBeyondTwoHundredRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
        defer { queue.close() }
        let revision = UploadBackupRevision(rawValue: 1)
        for index in 0..<1_001 {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: "photo-\(index)"), revision: revision,
                        originalFilename: "photo-\(index).heic", state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: Date())))
        }
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "other-problem"), revision: revision,
                    originalFilename: "other.heic", state: .failed,
                    lastError: BackupIssueRecord(kind: .permission, detail: "Permission").persistedValue,
                    updatedAt: Date())))
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let captured = await runner.prepareBackUpAgain(in: queue)
        let confirmation = try XCTUnwrap(captured)
        XCTAssertEqual(confirmation.count, 1_001)
        XCTAssertTrue(confirmation.items.allSatisfy { $0.issue == .deletedElsewhere })
        // A newly arrived decision is outside the set that the person confirmed.
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "later"), revision: revision,
                    originalFilename: "later.heic", state: .failedPermanent,
                    lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                    updatedAt: Date())))
        var touched: [String] = []
        XCTAssertTrue(
            runner.start(confirmation) {
                touched.append($0.id)
                return true
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(touched.count, confirmation.count)
        XCTAssertFalse(touched.contains { $0.contains("later") || $0.contains("other-problem") })
        XCTAssertEqual(runner.summary?.total, confirmation.count)
    }

    func testUnavailableCaptureNeverCreatesConsent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
        queue.close()
        let runner = BulkPhotoActionRunner()
        let confirmation = await runner.prepareBackUpAgain(in: queue)
        XCTAssertNil(confirmation)
        XCTAssertNil(runner.confirmation)
    }

    func testPreparingAndCancellingConfirmationTouchesNothing() async throws {
        let runner = BulkPhotoActionRunner()
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .backUpAgain))
        XCTAssertEqual(confirmation.count, 3)
        XCTAssertFalse(runner.isRunning)
        runner.dismissConfirmation()
        var touched = 0
        XCTAssertFalse(
            runner.start(confirmation) { _ in
                touched += 1
                return true
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(touched, 0)
        XCTAssertNil(runner.summary)
    }

    func testMixedRowsProduceOneTruthfulSummary() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let input = rows(4)
        let confirmation = try XCTUnwrap(runner.prepare(input, action: .backUpAgain))
        var touched: [BackupFailedItem] = []
        XCTAssertTrue(
            runner.start(confirmation) { item in
                touched.append(item)
                // The source-missing row and the row reopened separately remain unchanged.
                return item.id == "0" || item.id == "3"
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(touched, input)
        XCTAssertEqual(runner.summary?.completed, 2)
        XCTAssertEqual(runner.summary?.stayed, 2)
        XCTAssertEqual(runner.summary?.total, 4)
        XCTAssertEqual(runner.processed, 4)
        XCTAssertFalse(runner.isRunning)
    }

    func testRepeatedTapCannotStartAnotherRunOrChangeItsSnapshot() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .restore))
        var touched = 0
        XCTAssertTrue(
            runner.start(confirmation) { _ in
                touched += 1
                return true
            })
        XCTAssertFalse(
            runner.start(confirmation) { _ in
                XCTFail("second run")
                return true
            })
        XCTAssertNil(runner.prepare(rows(7), action: .restore))
        await runner.waitUntilFinished()
        XCTAssertEqual(touched, 3)
        XCTAssertEqual(runner.summary?.total, 3)
        XCTAssertFalse(
            runner.start(confirmation) { _ in
                XCTFail("reused confirmation")
                return true
            })
    }

    func testCancelBeforeFirstAdmissionLeavesAllRowsUntouched() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .backUpAgain))
        var touched = 0
        XCTAssertTrue(
            runner.start(confirmation) { _ in
                touched += 1
                return true
            })
        runner.cancel()
        await runner.waitUntilFinished()
        XCTAssertEqual(touched, 0)
        XCTAssertEqual(runner.summary?.completed, 0)
        XCTAssertEqual(runner.summary?.stayed, 3)
        XCTAssertEqual(runner.summary?.cancelled, true)
    }

    func testCancelDuringARowRetainsItsCommittedOutcomeAndStopsBeforeTheNext() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .restore))
        var touched: [String] = []
        XCTAssertTrue(
            runner.start(confirmation) { item in
                touched.append(item.id)
                runner.cancel()
                return true
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(touched, ["0"])
        XCTAssertEqual(runner.summary?.completed, 1)
        XCTAssertEqual(runner.summary?.stayed, 2)
        XCTAssertEqual(runner.summary?.cancelled, true)
    }

    func testThousandRowsStartSeriallyAndEveryLaterStartIsPaced() async throws {
        var sleeps: [TimeInterval] = []
        let runner = BulkPhotoActionRunner(sleep: { sleeps.append($0) })
        let confirmation = try XCTUnwrap(runner.prepare(rows(1_001), action: .backUpAgain))
        var starts = 0
        var inFlight = 0
        XCTAssertTrue(
            runner.start(confirmation) { _ in
                XCTAssertEqual(sleeps.count, starts, "no admission burst")
                inFlight += 1
                XCTAssertEqual(inFlight, 1)
                await Task.yield()
                starts += 1
                inFlight -= 1
                return true
            })
        await runner.waitUntilFinished()
        XCTAssertEqual(starts, 1_001)
        XCTAssertEqual(sleeps.count, 1_000)
        XCTAssertTrue(sleeps.allSatisfy { $0 >= 0.25 })
        XCTAssertEqual(runner.summary?.completed, 1_001)
        XCTAssertEqual(runner.summary?.stayed, 0)
    }

    func testShutdownRevokesPendingConfirmationAndFutureAdmission() async throws {
        let runner = BulkPhotoActionRunner(sleep: { _ in })
        let confirmation = try XCTUnwrap(runner.prepare(rows(3), action: .restore))
        await runner.shutdown()
        XCTAssertNil(runner.confirmation)
        XCTAssertNil(runner.prepare(rows(1), action: .restore))
        XCTAssertFalse(
            runner.start(confirmation) { _ in
                XCTFail("retired account")
                return true
            })
    }

    func testConfirmationFromAnotherAccountIsRejected() async throws {
        let first = BulkPhotoActionRunner()
        let other = BulkPhotoActionRunner()
        let confirmation = try XCTUnwrap(first.prepare(rows(3), action: .restore))
        XCTAssertFalse(
            other.start(confirmation) { _ in
                XCTFail("wrong account")
                return true
            })
    }

    #if DEBUG
        func testShutdownJoinsAnInFlightCaptureAndCancelledCaptureNeverCreatesConsent() async throws {
            for shutsDown in [true, false] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let queue = try XCTUnwrap(
                    UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
                defer { queue.close() }
                XCTAssertTrue(
                    queue.upsert(
                        .init(
                            source: .init(kind: .photoLibraryAsset, identifier: "photo"), revision: .init(rawValue: 1),
                            originalFilename: "photo.heic", state: .failedPermanent,
                            lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                            updatedAt: Date())))
                let gate = BulkSnapshotReadGate()
                queue.onProblemReadEvent = {
                    switch $0 {
                    case .willLock: gate.holdOnce()
                    case .didUnlock: gate.recordCancellation(Task.isCancelled)
                    default: break
                    }
                }
                let runner = BulkPhotoActionRunner()
                let capture = Task { await runner.prepareBackUpAgain(in: queue) }
                let deadline = ContinuousClock.now + .seconds(3)
                while !gate.hasStarted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertTrue(gate.hasStarted)
                let overlapping = await runner.prepareBackUpAgain(in: queue)
                XCTAssertNil(overlapping, "The runner owns one complete capture at a time")
                var returned = false
                let shutdown = Task {
                    if shutsDown { await runner.shutdown() } else { capture.cancel() }
                    returned = true
                }
                try await Task.sleep(for: .milliseconds(30))
                if shutsDown {
                    XCTAssertFalse(returned, "Shutdown must join the capture before the account closes its store")
                }
                gate.release()
                await shutdown.value
                let confirmation = await capture.value
                XCTAssertNil(confirmation)
                XCTAssertTrue(gate.observedCancellation, "The owned read receives caller or shutdown cancellation")
                XCTAssertNil(runner.confirmation)
                await runner.shutdown()
            }
        }
    #endif

    private func rows(_ count: Int) -> [BackupFailedItem] {
        (0..<count).map {
            BackupFailedItem(
                id: "\($0)", filename: "Photo \($0).heic", reason: "Deleted in Proton Drive.",
                isPermanent: true, issue: .deletedElsewhere)
        }
    }
}

private final class BulkSnapshotReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var cancelled = false
    var hasStarted: Bool { lock.withLock { started } }
    var observedCancellation: Bool { lock.withLock { cancelled } }
    func recordCancellation(_ value: Bool) { lock.withLock { cancelled = cancelled || value } }
    func holdOnce() {
        let shouldHold = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        if shouldHold { _ = semaphore.wait(timeout: .now() + 5) }
    }
    func release() { semaphore.signal() }
}
