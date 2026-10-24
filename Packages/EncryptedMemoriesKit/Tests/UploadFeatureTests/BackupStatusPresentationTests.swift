import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The shared display projection of `BackupStatus`: a compact, honest row - an icon, a phase
/// headline, one overall-progress subtitle line ("<n> of <m>"), and an optional attention line.
/// Same model on every platform.
final class BackupStatusPresentationTests: XCTestCase {
    func testFailedItemOwnsSharedRetryPresentation() {
        let item = BackupFailedItem(
            id: "retry",
            filename: "photo.jpg",
            reason: "Retry",
            isPermanent: false,
            issue: .network,
            nextAttemptAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertNotNil(item.retryDescription)
        XCTAssertNil(
            BackupFailedItem(
                id: "now",
                filename: "photo.jpg",
                reason: "Retry",
                isPermanent: false
            ).retryDescription)
    }

    private func progress(
        total: Int = 0, waiting: Int = 0, uploadQueued: Int = 0, checking: Int = 0,
        uploading: Int = 0, uploaded: Int = 0, alreadyBackedUp: Int = 0,
        skippedRemoteDeletions: Int = 0, sourceMissing: Int = 0, blocked: Int = 0,
        failed: Int = 0, dismissedFailures: Int = 0,
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
        p.dismissedFailures = dismissedFailures
        p.isRunning = isRunning
        p.isPausedByPolicy = isPausedByPolicy
        p.activeTransfer = activeTransfer
        return p
    }

    private func status(_ p: BackupSyncProgress, isScanning: Bool = false) -> BackupStatus {
        BackupStatus(progress: p, isScanning: isScanning)
    }

    func testCheckingHeadlineWhenNoBytesAreMoving() {
        // A running pass with no in-flight upload is checking - never "backing up".
        let s = status(progress(total: 100, uploadQueued: 5, checking: 1, alreadyBackedUp: 20, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_checking")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.accessory, .activity)
    }

    func testPerFileProgressNeverLeaksIntoOverallSubtitle() {
        let raw = progress(total: 100, uploadQueued: 5, checking: 1, uploading: 1, alreadyBackedUp: 20, isRunning: true)
        let p = BackupStatusPresentation(status(raw))
        XCTAssertEqual(p.headlineKey, "backup.phase_uploading")
        let subtitle = try? XCTUnwrap(p.localizedSubtitle)
        XCTAssertEqual(subtitle?.contains("43"), false)
        XCTAssertEqual(subtitle?.contains("%"), false)
        XCTAssertFalse(subtitle?.contains("IMG_5560.MOV") ?? true, "no filename in the subtitle")
    }

    func testSubtitleIsCountOfBackedUpOverTotalWithNoPercentWhenNotUploading() {
        let s = status(progress(total: 100, checking: 1, uploaded: 10, alreadyBackedUp: 20, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.backedUp, 30)
        XCTAssertEqual(p.total, 100)
        let subtitle = try? XCTUnwrap(p.localizedSubtitle)
        XCTAssertEqual(subtitle?.contains("30"), true)
        XCTAssertEqual(subtitle?.contains("100"), true)
        XCTAssertEqual(subtitle?.contains("%"), false)
    }

    func testTransferLivenessIsSeparateFromStableBackedUpCount() throws {
        let transfer = BackupActiveTransferProgress(
            activeItemCount: 2,
            completedBytes: 51,
            totalBytes: 100,
            completedItemEquivalents: 0.75
        )
        let presentation = BackupStatusPresentation(
            status(
                progress(
                    total: 100, uploading: 2, alreadyBackedUp: 20, isRunning: true,
                    activeTransfer: transfer
                )))

        XCTAssertEqual(presentation.backedUp, 20)
        XCTAssertEqual(presentation.activeTransferPercent, 51)
        XCTAssertEqual(presentation.activeTransferFraction, 0.51)
        XCTAssertEqual(
            presentation.progressBarFraction, 0.51,
            "the visible bar must follow the transfer percentage immediately above it")
        XCTAssertTrue(try XCTUnwrap(presentation.localizedSubtitle).contains("20"))
        XCTAssertTrue(try XCTUnwrap(presentation.localizedTransferDetail).contains("51"))
        XCTAssertEqual(presentation.localizedProgressBarLabel, presentation.localizedTransferDetail)
    }

    func testScanningHasNoFakeProgressAndNoSubtitle() {
        let s = status(progress(total: 40, waiting: 40), isScanning: true)
        XCTAssertEqual(s.phase, .scanning)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_scanning")
        XCTAssertNil(p.progressFraction, "scanning must stay indeterminate")
        XCTAssertNil(p.localizedSubtitle, "no honest total mid-scan => no subtitle")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.detailLayout, .compact, "scanning must not reserve empty progress rows")
    }

    func testKnownTotalActivePassUsesStableExpandedDetails() {
        let checking = BackupStatusPresentation(
            status(
                progress(
                    total: 100, checking: 1, alreadyBackedUp: 20, isRunning: true
                )))
        let uploading = BackupStatusPresentation(
            status(
                progress(
                    total: 100, uploading: 1, alreadyBackedUp: 20, isRunning: true
                )))

        XCTAssertEqual(checking.detailLayout, .progress)
        XCTAssertEqual(uploading.detailLayout, .progress)
    }

    func testCompletedIsSuccessAndNotActive() {
        let s = status(progress(total: 10, uploaded: 4, alreadyBackedUp: 6))
        XCTAssertEqual(s.phase, .completed)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed")
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.accessory, .success)
        XCTAssertEqual(p.detailLayout, .compact, "completion must collapse the active progress slots")
        XCTAssertNil(p.progressBarFraction)
    }

    func testCompletedRemoteDeletionsAreInformationalAndExcludedFromBackupTarget() throws {
        let s = status(progress(total: 10, uploaded: 4, alreadyBackedUp: 3, skippedRemoteDeletions: 3))

        XCTAssertEqual(s.phase, .completed)
        XCTAssertEqual(s.backedUp, 7)
        XCTAssertEqual(s.backupTargetCount, 7)
        XCTAssertEqual(s.needsAttentionCount, 0)

        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed_with_remote_deletions")
        XCTAssertEqual(p.accessory, .success)
        XCTAssertEqual(p.total, 7)
        XCTAssertEqual(p.skippedRemoteDeletions, 3)
        XCTAssertNil(p.localizedAttention)
        XCTAssertTrue(try XCTUnwrap(p.localizedSubtitle).contains("7"))
        XCTAssertTrue(try XCTUnwrap(p.localizedRemoteDeletionDetail).contains("3"))
    }

    func testAcknowledgedPermanentFailureEndsCalmlyWithoutClaimingEverythingIsBackedUp() {
        let s = status(progress(total: 10, uploaded: 9, dismissedFailures: 1))
        let p = BackupStatusPresentation(s)

        XCTAssertEqual(s.phase, .completed)
        XCTAssertEqual(s.backedUp, 9)
        XCTAssertEqual(s.notBackedUpCount, 1)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed_with_omissions")
        XCTAssertEqual(p.accessory, .notice)
        XCTAssertEqual(p.backedUp, 9)
        XCTAssertEqual(p.total, 10)
        XCTAssertNil(p.localizedAttention)
    }

    func testAttentionLineAppearsOnlyWhenSomethingNeedsTheUser() {
        let clean = BackupStatusPresentation(
            status(progress(total: 10, checking: 1, alreadyBackedUp: 5, isRunning: true)))
        XCTAssertNil(clean.localizedAttention, "nothing failed => no attention line")

        let s = status(progress(total: 10, uploaded: 5, sourceMissing: 1, failed: 2))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_attention")
        XCTAssertEqual(p.attentionCount, s.needsAttentionCount)
        XCTAssertNotNil(p.localizedAttention)
        XCTAssertEqual(p.accessory, .attention)
    }

    func testAttentionCountExcludesRetryableDraftsWhenFailuresCoexist() {
        let s = status(progress(total: 20, uploaded: 8, alreadyBackedUp: 9, sourceMissing: 1, blocked: 2))
        let p = BackupStatusPresentation(s)

        XCTAssertEqual(s.phase, .needsAttention)
        XCTAssertEqual(p.attentionCount, 1)
        XCTAssertNotNil(p.localizedAttention)
    }

    func testRemoteIndexInterruptionDoesNotReportWholeBacklogAsFailed() throws {
        var raw = progress(total: 1_481, waiting: 1_481)
        raw.remoteIndexPreparationFailed = true
        raw.remoteIndexPreparationIssue = BackupIssueRecord(
            kind: .remoteService,
            detail: "temporary service interruption",
            nextAttemptAt: Date(timeIntervalSince1970: 1_000)
        )
        let s = status(raw)
        let p = BackupStatusPresentation(s)

        XCTAssertEqual(s.phase, .waiting)
        XCTAssertEqual(p.headlineKey, "backup.phase_waiting_proton")
        XCTAssertEqual(p.accessory, .waiting)
        XCTAssertEqual(s.notBackedUpCount, 1_481, "the backlog remains truthfully unfinished")
        XCTAssertEqual(p.attentionCount, 0, "unfinished work must not be labeled as failed media")
        XCTAssertNil(p.localizedAttention)
        XCTAssertNotNil(p.localizedSystemIssue)
        XCTAssertEqual(p.nextAttemptAt, Date(timeIntervalSince1970: 1_000))
    }

    func testBackgroundSchedulingFailureIsASeparateActionableSystemIssue() throws {
        let raw = progress(total: 10, waiting: 1, alreadyBackedUp: 9)
        let status = BackupStatus(
            progress: raw,
            isScanning: false,
            executionOpportunityIssue: .backgroundRefreshUnavailable
        )
        let presentation = BackupStatusPresentation(status)

        XCTAssertEqual(presentation.accessory, .waiting)
        XCTAssertEqual(presentation.headlineKey, "backup.phase_waiting")
        XCTAssertNil(presentation.localizedAttention, "scheduler failures do not belong in the per-photo sheet")
        XCTAssertFalse(try XCTUnwrap(presentation.localizedSystemIssue).isEmpty)
    }

    func testPausedKeepsProgressButIsNotActive() {
        let s = status(progress(total: 10, checking: 1, uploaded: 3, isRunning: true, isPausedByPolicy: true))
        XCTAssertEqual(s.phase, .paused)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_paused")
        XCTAssertEqual(p.accessory, .paused)
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.detailLayout, .progress, "pausing must retain the known progress geometry")
    }

    func testWaitingDraftNamesTheBlockerAndShowsExactRetry() {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        var raw = progress(total: 10, alreadyBackedUp: 9, blocked: 1)
        raw.outstanding = BackupOutstandingSnapshot(count: 1, issue: .remoteDraft, nextAttemptAt: retryAt)

        let presentation = BackupStatusPresentation(status(raw))

        XCTAssertEqual(presentation.headlineKey, "backup.phase_waiting_draft")
        XCTAssertEqual(presentation.nextAttemptAt, retryAt)
        XCTAssertEqual(presentation.accessory, .waiting)
        XCTAssertEqual(presentation.attentionCount, 0)
        XCTAssertEqual(presentation.waitingCount, 1)
        XCTAssertNotNil(presentation.localizedWaitingDetail)
        XCTAssertNotNil(presentation.localizedRetryDetail)
    }

    func testWaitingProtonNamesTheCauseAndPreservesItsRetryDate() throws {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        var raw = progress(total: 1, waiting: 1)
        raw.outstanding = .init(count: 1, issue: .remoteService, nextAttemptAt: retryAt)
        let presentation = BackupStatusPresentation(status(raw))
        XCTAssertEqual(presentation.headlineKey, "backup.phase_waiting_proton")
        XCTAssertEqual(presentation.nextAttemptAt, retryAt)
        XCTAssertEqual(presentation.accessory, .waiting)
        XCTAssertNil(presentation.localizedAttention)
        XCTAssertFalse(presentation.localizedHeadline.isEmpty)
    }

    func testSystemIssuesWithoutRowsKeepIdleAndExplainTheIssue() {
        var raw = progress()
        raw.remoteIndexPreparationFailed = true
        let presentation = BackupStatusPresentation(
            BackupStatus(progress: raw, isScanning: false, executionOpportunityIssue: .schedulerCapacity))
        XCTAssertEqual(presentation.headlineKey, "backup.phase_idle")
        XCTAssertEqual(presentation.accessory, .idle)
        XCTAssertEqual(presentation.attentionCount, 0)
        XCTAssertNotNil(presentation.localizedSystemIssue)
        let schedulerOnly = BackupStatusPresentation(
            BackupStatus(progress: progress(), isScanning: false, executionOpportunityIssue: .schedulerCapacity))
        XCTAssertEqual(schedulerOnly.headlineKey, "backup.phase_idle")
        XCTAssertNotNil(schedulerOnly.localizedSystemIssue)
    }

    func testFailedHeadlineStatesTheCountAndOffersReasons() {
        let presentation = BackupStatusPresentation(status(progress(total: 3, uploaded: 1, failed: 2)))
        XCTAssertEqual(presentation.localizedHeadline, PhotosCore.L10n.string("backup.phase_not_backed_up \(2)"))
    }

    func testRetryDatesAppearOnlyForAutomaticRowsAndSectionsShareMembership() {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        for category in [BackupIssueCategory.automatic, .userResolvable, .decision, .permanent] {
            let item = BackupFailedItem(
                id: category.rawValue, filename: "photo", reason: "reason", isPermanent: category == .permanent,
                nextAttemptAt: retryAt, category: category)
            XCTAssertEqual(item.retryDescription != nil, category == .automatic)
            XCTAssertFalse(category.symbolName.isEmpty)
        }
        XCTAssertEqual(BackupIssueCategory.automatic.section, .continuesByItself)
        XCTAssertEqual(BackupIssueCategory.userResolvable.section, .actionNeeded)
        XCTAssertEqual(BackupIssueCategory.decision.section, .actionNeeded)
        XCTAssertEqual(BackupIssueCategory.permanent.section, .notPossible)
        XCTAssertEqual(BackupIssueSection.allCases, [.actionNeeded, .continuesByItself, .notPossible])
    }

    func testIdleIsCalmWithNoSubtitle() {
        let idle = BackupStatusPresentation(status(progress()))
        XCTAssertEqual(idle.headlineKey, "backup.phase_idle")
        XCTAssertNil(idle.localizedSubtitle)
        XCTAssertEqual(idle.accessory, .idle)
    }

    func testMappingIsDeterministic() {
        let s = status(progress(total: 100, checking: 1, alreadyBackedUp: 40, isRunning: true))
        XCTAssertEqual(BackupStatusPresentation(s), BackupStatusPresentation(s))
    }

    /// The first scan shows how far the index of the photos already in Proton is.
    func testIndexPreparationShowsItsShareOnceTheTotalIsKnown() {
        let loading = UploadRemoteIndexPreparationProgress(phase: .loading)
        let indexing = UploadRemoteIndexPreparationProgress(phase: .indexing, completed: 1_200, total: 4_800)
        let overcounted = UploadRemoteIndexPreparationProgress(phase: .indexing, completed: 5_000, total: 4_800)

        XCTAssertNil(loading.fractionCompleted, "no bar before the list of photos in Proton is known")
        XCTAssertEqual(indexing.fractionCompleted, 0.25)
        XCTAssertEqual(overcounted.fractionCompleted, 1)
        XCTAssertNotEqual(indexing.localizedDetail, loading.localizedDetail, "a known total names the counts")
        XCTAssertEqual(overcounted.localizedDetail, UploadRemoteIndexPreparationProgress(
            phase: .indexing, completed: 4_800, total: 4_800).localizedDetail, "the count never passes the total")
    }
}
