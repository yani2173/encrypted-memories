import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The shared user-facing backup status surface: phase derivation honesty (checking is never
/// worded as uploading, no fake progress), count aggregation, and stability.
final class BackupStatusTests: XCTestCase {
    private func progress(
        total: Int = 0, waiting: Int = 0, uploadQueued: Int = 0, checking: Int = 0,
        uploading: Int = 0, uploaded: Int = 0, alreadyBackedUp: Int = 0,
        skippedRemoteDeletions: Int = 0, sourceMissing: Int = 0, blocked: Int = 0,
        failed: Int = 0, currentItemName: String? = nil,
        isRunning: Bool = false, isPausedByPolicy: Bool = false,
        activeTransfer: BackupActiveTransferProgress? = nil
    ) -> BackupSyncProgress {
        var p = BackupSyncProgress()
        p.total = total
        p.waiting = waiting
        p.uploadQueued = uploadQueued
        p.checking = checking
        p.uploading = uploading
        p.uploaded = uploaded
        p.alreadyBackedUp = alreadyBackedUp
        p.skippedRemoteDeletions = skippedRemoteDeletions
        p.sourceMissing = sourceMissing
        p.blocked = blocked
        p.failed = failed
        p.currentItemName = currentItemName
        p.isRunning = isRunning
        p.isPausedByPolicy = isPausedByPolicy
        p.activeTransfer = activeTransfer
        return p
    }

    func testScanningIsIndeterminate() {
        let status = BackupStatus(progress: progress(total: 40, waiting: 40), isScanning: true)
        XCTAssertEqual(status.phase, .scanning)
        XCTAssertNil(status.totalConsidered, "totals are still growing - claiming one would lie")
        XCTAssertNil(status.fractionCompleted)
        XCTAssertEqual(status.titleKey, "backup.phase_scanning")
    }

    func testCheckingIsNeverLabeledUploading() {
        let status = BackupStatus(
            progress: progress(
                total: 10, waiting: 7, checking: 2, alreadyBackedUp: 1,
                currentItemName: "IMG_0042.HEIC", isRunning: true),
            isScanning: false
        )
        XCTAssertEqual(status.phase, .checking)
        XCTAssertEqual(status.titleKey, "backup.phase_checking")
        XCTAssertNotEqual(
            status.titleKey, "backup.phase_uploading",
            "hash/duplicate checking must never present as uploading")
        XCTAssertEqual(status.currentItemName, "IMG_0042.HEIC")
    }

    func testUploadingOnlyWhenUploadsDominateNotAStrayByteMovement() {
        let checkingOnly = BackupStatus(
            progress: progress(total: 5, waiting: 4, checking: 1, isRunning: true), isScanning: false
        )
        XCTAssertEqual(checkingOnly.phase, .checking)

        // Keep the phase at "checking" while most of the library is still unexamined. A first
        // reconciliation may upload one item before discovering that the rest is already backed up.
        let strayUploadDuringCheck = BackupStatus(
            progress: progress(total: 100, waiting: 90, uploading: 1, uploaded: 1, isRunning: true),
            isScanning: false
        )
        XCTAssertEqual(
            strayUploadDuringCheck.phase, .checking,
            "one upload among a large unexamined backlog is still 'checking', not 'uploading'")

        // Once nothing is left to examine and bytes are moving, it is genuinely uploading.
        let uploadingNow = BackupStatus(
            progress: progress(total: 5, waiting: 0, uploading: 1, uploaded: 4, isRunning: true),
            isScanning: false
        )
        XCTAssertEqual(uploadingNow.phase, .uploading)
        XCTAssertEqual(uploadingNow.titleKey, "backup.phase_uploading")
    }

    func testPolicyPauseWinsWhileRunning() {
        let status = BackupStatus(
            progress: progress(total: 5, waiting: 4, uploading: 1, isRunning: true, isPausedByPolicy: true),
            isScanning: false
        )
        XCTAssertEqual(status.phase, .paused)
    }

    func testPolicyPauseDoesNotLookCompletedWhenRowsAreParkedAsPaused() {
        var raw = progress(total: 5, isRunning: true, isPausedByPolicy: true)
        raw.paused = 5

        let status = BackupStatus(progress: raw, isScanning: false)

        XCTAssertEqual(status.phase, .paused)
        XCTAssertNotEqual(status.backedUp, status.backupTargetCount)
    }

    func testInterruptedRunIsWaitingNotCompleted() {
        let status = BackupStatus(
            progress: progress(total: 10, waiting: 4, uploadQueued: 2, uploaded: 6), isScanning: false
        )
        XCTAssertEqual(status.phase, .waiting)
        XCTAssertLessThan(status.fractionCompleted ?? 1, 1.0)
    }

    func testBlockedOnlyRemainsWaitingWithHonestFraction() {
        let status = BackupStatus(
            progress: progress(total: 3, alreadyBackedUp: 2, blocked: 1), isScanning: false
        )
        XCTAssertEqual(status.phase, .waiting)
        XCTAssertEqual(status.fractionCompleted, 2.0 / 3.0)
    }

    func testFailureSummaryIsStableAndRecoverableLooking() {
        let p = progress(total: 4, uploaded: 2, sourceMissing: 1, failed: 1)
        let first = BackupStatus(progress: p, isScanning: false)
        let second = BackupStatus(progress: p, isScanning: false)
        XCTAssertEqual(first, second, "same durable input must derive the identical summary")
        XCTAssertEqual(first.phase, .needsAttention)
        XCTAssertEqual(first.needsAttentionCount, 2)
        XCTAssertEqual(first.backedUp, 2)
    }

    func testNotBackedUpCountIncludesFailuresAndBlockedDrafts() {
        let status = BackupStatus(
            progress: progress(
                total: 20, uploaded: 8, alreadyBackedUp: 9,
                skippedRemoteDeletions: 0, sourceMissing: 1, blocked: 2),
            isScanning: false
        )

        XCTAssertEqual(status.phase, .needsAttention)
        XCTAssertEqual(status.needsAttentionCount, 1)
        XCTAssertEqual(status.notBackedUpCount, 3)
    }

    func testCompletedAndIdle() {
        let done = BackupStatus(
            progress: progress(total: 3, uploaded: 1, alreadyBackedUp: 2), isScanning: false
        )
        XCTAssertEqual(done.phase, .completed)
        XCTAssertEqual(done.fractionCompleted, 1.0)

        let idle = BackupStatus(progress: progress(), isScanning: false)
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertEqual(idle.totalConsidered, 0)
        XCTAssertNil(idle.fractionCompleted, "an empty queue has no honest fraction")
    }

    func testTerminalQueueWinsOverOuterRunLifetime() {
        let status = BackupStatus(
            progress: progress(total: 16_407, uploaded: 16_407, isRunning: true),
            isScanning: false
        )

        XCTAssertEqual(status.phase, .completed)
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.backedUp, status.backupTargetCount)
    }

    func testProvenRemoteDeletionCompletesPolicyWithoutInflatingBackedUpCount() {
        let status = BackupStatus(
            progress: progress(total: 3, uploaded: 2, skippedRemoteDeletions: 1),
            isScanning: false
        )
        XCTAssertEqual(status.phase, .completed)
        XCTAssertEqual(status.backedUp, 2)
        XCTAssertEqual(status.backupTargetCount, 2)
        XCTAssertEqual(status.needsAttentionCount, 0)
        XCTAssertEqual(status.fractionCompleted, 1)
    }

    func testQueueTreatsProvenRemoteDeletionAsSettledButNotPresent() {
        var summary = UploadBackupSyncQueueSummary()
        summary.include(.completed, count: 2)
        summary.include(.skippedRemoteDeletion)

        XCTAssertEqual(summary.resolved, 2)
        XCTAssertEqual(summary.settledSuccessfully, 3)
        XCTAssertEqual(summary.progressFraction, 1)
        XCTAssertFalse(summary.hasWork)
        XCTAssertTrue(UploadBackupSyncQueueState.skippedRemoteDeletion.isTerminalSuccess)
    }

    func testCountsAggregateFromQueueSummaryIncludingUploadQueueSplit() {
        var summary = UploadBackupSyncQueueSummary()
        summary.include(.discovered, count: 3)
        summary.include(.queuedForUpload, count: 2)
        summary.include(.checking)
        summary.include(.uploading)
        summary.include(.completed, count: 4)
        summary.include(.alreadyBackedUp, count: 5)
        summary.include(.skippedRemoteDeletion)
        summary.include(.sourceMissing)
        summary.include(.blockedByDraft)
        summary.include(.failed)

        XCTAssertEqual(summary.waiting, 5, "queued-for-upload rows still count as waiting overall")
        XCTAssertEqual(summary.queuedForUpload, 2)

        let status = BackupStatus(
            progress: BackupSyncProgress(summary: summary, isRunning: true), isScanning: false
        )
        XCTAssertEqual(status.totalConsidered, 20)
        XCTAssertEqual(status.uploadQueued, 2)
        XCTAssertEqual(status.backedUp, 9)
        XCTAssertEqual(status.alreadyBackedUp, 5)
        XCTAssertEqual(status.uploaded, 4)
        XCTAssertEqual(status.skippedRemoteDeletions, 1)
        XCTAssertEqual(status.sourceMissing, 1)
        XCTAssertEqual(status.waitingRetry, 1)
        XCTAssertEqual(status.failed, 1)
        XCTAssertEqual(status.needsAttentionCount, 2, "only failure and missing source need attention")
        // checked = everything past its backup-status check (incl. upload-queued and blocked).
        XCTAssertEqual(status.checked, 4 + 5 + 1 + 1 + 1 + 1 + 2)
    }

    func testExecutionProgressAddsFractionalTransferWithoutInflatingBackedUpCount() throws {
        let transfer = BackupActiveTransferProgress(
            activeItemCount: 1,
            completedBytes: 50,
            totalBytes: 100,
            completedItemEquivalents: 0.5
        )
        let status = BackupStatus(
            progress: progress(
                total: 10, waiting: 3, uploading: 1, alreadyBackedUp: 5,
                skippedRemoteDeletions: 1, isRunning: true, activeTransfer: transfer
            ),
            isScanning: false
        )

        XCTAssertEqual(status.backedUp, 5)
        XCTAssertEqual(status.settled, 6)
        let execution = try XCTUnwrap(status.executionProgress)
        XCTAssertEqual(execution.totalUnitCount, 10_000)
        XCTAssertEqual(execution.completedUnitCount, 6_500)
    }

    func testManualCheckMapsToSharedPhasesWithoutClaimingUpload() {
        var running = UploadPreparationStatus()
        running.total = 10
        running.waiting = 4
        running.checking = 2
        running.checked = 3
        running.skippedDuplicates = 1
        let checking = BackupStatus(manualUploadCheck: running)
        XCTAssertEqual(
            checking.phase, .checking,
            "the preparation aggregate cannot see bytes - it must never claim uploading")
        XCTAssertEqual(checking.alreadyBackedUp, 1)
        XCTAssertEqual(checking.totalConsidered, 10)

        let idle = BackupStatus(manualUploadCheck: UploadPreparationStatus())
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertNil(idle.fractionCompleted)

        var failed = UploadPreparationStatus()
        failed.total = 2
        failed.checked = 1
        failed.failed = 1
        XCTAssertEqual(BackupStatus(manualUploadCheck: failed).phase, .needsAttention)

        var done = UploadPreparationStatus()
        done.total = 2
        done.checked = 1
        done.skippedDuplicates = 1
        XCTAssertEqual(BackupStatus(manualUploadCheck: done).phase, .completed)
    }

    func testTheProblemListReloadsForNewProblemsButNotForTransferProgress() {
        var status = BackupStatus()
        status.phase = .uploading
        status.activeTransfer = BackupActiveTransferProgress(
            activeItemCount: 1, completedBytes: 10, totalBytes: 100, completedItemEquivalents: 0.1)
        let key = status.problemListKey
        status.activeTransfer = BackupActiveTransferProgress(
            activeItemCount: 1, completedBytes: 90, totalBytes: 100, completedItemEquivalents: 0.9)
        status.activeExecutionItemEquivalents = 0.9
        status.uploaded += 1
        status.currentItemName = "next.heic"
        XCTAssertEqual(status.problemListKey, key)

        var waiting = status
        waiting.outstandingCount = 1
        XCTAssertNotEqual(waiting.problemListKey, key, "a photo starts to wait with a reason")
        var failed = status
        failed.failed = 1
        XCTAssertNotEqual(failed.problemListKey, key, "a photo needs the person")
        var cause = status
        cause.outstandingIssue = .accountStorage
        XCTAssertNotEqual(cause.problemListKey, key, "the reason of a wait changes")
    }

    /// `localizedTitle` keeps literal `L10n.string` calls, which the catalog hygiene test scans; `titleKey` names the
    /// same keys for tests. Two switches can drift apart, so this pins that both name the same key.
    func testLocalizedTitleUsesTheTitleKeyOfEveryPhaseVariant() {
        let phases: [BackupStatus.Phase] = [
            .idle, .scanning, .checking, .uploading, .paused, .waitingForWiFi, .waiting, .completed, .needsAttention,
        ]
        var variants: [BackupStatus] = []
        for phase in phases {
            var status = BackupStatus()
            status.phase = phase
            variants.append(status)
            var onlyPhotosChecks = status
            onlyPhotosChecks.pendingSourceRechecks = 1
            onlyPhotosChecks.outstandingCount = 1
            variants.append(onlyPhotosChecks)
            var withOmissions = status
            withOmissions.dismissedFailures = 1
            variants.append(withOmissions)
        }
        XCTAssertEqual(Set(variants.map(\.titleKey)).count, 12, "every title key is reached")
        for status in variants {
            XCTAssertEqual(
                L10n.string(dynamicKey: status.titleKey), status.localizedTitle,
                "\(status.phase), \(status.titleKey)")
        }
    }
}
