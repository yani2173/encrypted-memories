import Foundation
import PhotosCore

/// Normalized execution units for OS/runtime progress surfaces. The user-facing backed-up count
/// remains separate; these units may also include deliberately-settled rows and fractional active
/// transfers so a long video proves liveness before the whole compound becomes terminal.
public struct BackupExecutionProgress: Sendable, Equatable {
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64

    public init(completedUnitCount: Int64, totalUnitCount: Int64) {
        self.totalUnitCount = max(0, totalUnitCount)
        self.completedUnitCount = min(max(0, completedUnitCount), self.totalUnitCount)
    }
}

/// Typed failure of an OS execution opportunity. Core owns the semantic categories and wording contract;
/// platform adapters map their native scheduler errors into these cases.
public enum BackupExecutionOpportunityIssue: String, Sendable, Equatable {
    case backgroundRefreshUnavailable
    case backgroundLaunchNotPermitted
    case schedulerCapacity
    case immediateRunIneligible
    case registrationFailed
    case unknown
}

/// THE user-facing backup/sync state surface, shared by every platform. Derived purely from the
/// durable queue progress (or the manual upload queue's preparation aggregate) plus a
/// platform-provided "scanning" flag - it holds no state of its own and invents nothing:
/// when the total is unknown the fraction is nil (indeterminate), and "uploading" is claimed
/// only while bytes actually move.
///
/// Wording contract (single source, keys in the shared PhotosCore catalog):
/// checking work is "Backup-Status wird geprüft" / "Checking backup status" - never "hashing",
/// never "uploading"; `backedUp` is the only count presented as safe.
public struct BackupStatus: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        /// Nothing to do and nothing known - a calm resting state.
        case idle
        /// Enumerating folders/assets. Totals are still growing - indeterminate by design.
        case scanning
        /// Proving items already backed up (streamed identity + duplicate check).
        case checking
        /// Bytes are moving.
        case uploading
        /// A running pass is held by policy (thermal/power) or items are user-paused.
        case paused
        /// Work remains but nothing runs right now (interrupted pass, draft re-checks pending).
        case waiting
        /// Everything considered is settled and nothing failed.
        case completed
        /// Some items exhausted their retries - recoverable, user-visible.
        case needsAttention
    }

    public var phase: Phase = .idle
    /// Items considered so far. `nil` while scanning - any total would be a lie mid-enumeration.
    public var totalConsidered: Int?
    /// Items whose backup-status check finished (whatever the outcome).
    public var checked = 0
    public var alreadyBackedUp = 0
    /// Checked items waiting for their bytes to upload.
    public var uploadQueued = 0
    public var uploaded = 0
    public var failed = 0
    /// Permanent failures whose warning the user acknowledged. They remain outside `backedUp`.
    public var dismissedFailures = 0
    /// Proven prior Proton copies that were deleted there and deliberately not re-uploaded.
    public var skippedRemoteDeletions = 0
    /// Local files that disappeared before backup.
    public var sourceMissing = 0
    /// Items parked for a later re-check (remote draft backoff).
    public var waitingRetry = 0
    public var currentItemName: String?
    /// Honest progress; `nil` = indeterminate (unknown total or nothing measurable).
    public var fractionCompleted: Double?
    public var remoteIndexCompleted: Int?
    public var remoteIndexTotal: Int?
    public var isPreparingRemoteIndex = false
    public var remoteIndexPreparationFailed = false
    public var remoteIndexPreparationIssue: BackupIssueRecord?
    public var remoteContentIndexHealth: UploadRemoteContentIndexHealth = .complete(indexedCount: 0)
    /// Terminal work of every outcome, used for execution progress only; never labeled backed up.
    public var settled = 0
    /// Ephemeral byte progress for resources currently moving.
    public var activeTransfer: BackupActiveTransferProgress?
    /// Bytes the backup has sent since its runner started; see `BackupSyncProgress.transferredBytes`.
    public var transferredBytes: Int64 = 0
    public var activeExecutionItemEquivalents: Double = 0
    /// Dominant typed reason for unfinished work and the next time Core can honestly retry it.
    public var outstandingIssue: BackupIssueKind?
    public var nextAttemptAt: Date?
    public var outstandingCount = 0
    public var executionOpportunityIssue: BackupExecutionOpportunityIssue?

    public init() {}

    /// The only number UI may call "backed up".
    public var backedUp: Int { uploaded + alreadyBackedUp }
    /// The count the "N of M backed up" line compares against. Intentional remote deletions are
    /// outside that target: counting them as backed up would lie, while leaving them in M would
    /// make a successfully respected deletion look like a permanent failure.
    public var backupTargetCount: Int? {
        totalConsidered.map { max(0, $0 - skippedRemoteDeletions) }
    }
    public var needsAttentionCount: Int { failed + sourceMissing }
    /// Items the backup still has to check or upload: everything considered that has not settled with any outcome.
    /// Nil while scanning, like the total.
    public var remainingCount: Int? {
        totalConsidered.map { max(0, $0 - settled) }
    }
    /// Changes when a photo can enter or leave the problem list, never on transfer progress alone, so an open
    /// list reloads only when its content can differ.
    public var problemListKey: ProblemListKey {
        ProblemListKey(
            phase: phase,
            counts: [failed, sourceMissing, waitingRetry, dismissedFailures, skippedRemoteDeletions, outstandingCount],
            issue: outstandingIssue, nextAttemptAt: nextAttemptAt)
    }

    public struct ProblemListKey: Sendable, Equatable {
        let phase: Phase
        let counts: [Int]
        let issue: BackupIssueKind?
        let nextAttemptAt: Date?
    }
    /// Every item that is not currently proven present in Proton Drive. Intentional remote deletions are
    /// excluded because the backup policy has already settled them successfully.
    public var notBackedUpCount: Int {
        guard let totalConsidered else { return needsAttentionCount + waitingRetry }
        return max(0, totalConsidered - backedUp - skippedRemoteDeletions)
    }
    public var isActive: Bool {
        phase == .scanning || phase == .checking || phase == .uploading
    }

    // MARK: - Derivation from the folder/asset backup queue

    public init(
        progress: BackupSyncProgress,
        isScanning: Bool,
        isUserPaused: Bool = false,
        executionOpportunityIssue: BackupExecutionOpportunityIssue? = nil
    ) {
        self.init()
        self.executionOpportunityIssue = executionOpportunityIssue
        checked =
            progress.uploaded + progress.alreadyBackedUp + progress.skippedRemoteDeletions
            + progress.failed + progress.dismissedFailures + progress.sourceMissing
            + progress.blocked + progress.uploadQueued
        alreadyBackedUp = progress.alreadyBackedUp
        uploadQueued = progress.uploadQueued
        uploaded = progress.uploaded
        failed = progress.failed
        dismissedFailures = progress.dismissedFailures
        skippedRemoteDeletions = progress.skippedRemoteDeletions
        sourceMissing = progress.sourceMissing
        waitingRetry = progress.blocked
        settled = progress.settled
        activeTransfer = progress.activeTransfer
        transferredBytes = progress.transferredBytes
        activeExecutionItemEquivalents = max(
            progress.activeExecutionItemEquivalents,
            progress.activeTransfer?.completedItemEquivalents ?? 0
        )
        outstandingIssue = progress.outstanding.issue
        nextAttemptAt = progress.outstanding.nextAttemptAt
        outstandingCount = progress.outstanding.count
        currentItemName = progress.currentItemName
        if let preparation = progress.remoteIndexPreparation, preparation.phase != .ready {
            isPreparingRemoteIndex = true
            remoteIndexCompleted = preparation.completed
            remoteIndexTotal = preparation.total
        }
        remoteIndexPreparationFailed = progress.remoteIndexPreparationFailed
        remoteIndexPreparationIssue = progress.remoteIndexPreparationIssue
        remoteContentIndexHealth = progress.remoteContentIndexHealth
        if let issue = progress.remoteIndexPreparationIssue {
            outstandingIssue = issue.kind
            nextAttemptAt = issue.nextAttemptAt
            outstandingCount = max(1, progress.outstanding.count)
        }
        // An explicit user pause wins over everything: show "Pausiert", not "checking"/"waiting".
        if isUserPaused {
            phase = .paused
            totalConsidered = progress.total
            fractionCompleted = progress.total > 0 ? progress.fraction : nil
            return
        }

        if isScanning {
            phase = .scanning
            totalConsidered = nil
            fractionCompleted = nil
            return
        }

        totalConsidered = progress.total
        fractionCompleted = progress.total > 0 ? progress.fraction : nil

        if progress.isRunning && (progress.hasOutstandingWork || progress.paused > 0 || isPreparingRemoteIndex) {
            // `waiting` lumps not-yet-examined `discovered` rows with confirmed `queuedForUpload`
            // ones; the unexamined part is `waiting - uploadQueued`. During a first pass over an
            // already-backed-up library almost everything is being checked (and turns out already
            // backed up), while a stray item or two upload. Claiming "uploading" there is the
            // misleading "Sichert neue Objekte" the user sees. Only call it uploading once confirmed
            // new work actually outweighs the still-unexamined backlog; otherwise it's checking.
            let unexamined = max(0, progress.waiting - progress.uploadQueued)
            if progress.isPausedByPolicy {
                phase = .paused
            } else if progress.uploading > 0 && (progress.uploadQueued + progress.uploading) >= unexamined {
                phase = .uploading
            } else {
                phase = .checking
            }
        } else if progress.needsAttention > 0 {
            phase = .needsAttention
        } else if progress.waiting + progress.checking + progress.uploading + progress.blocked > 0 {
            phase = .waiting
        } else if progress.total > 0 {
            phase = .completed
        } else {
            phase = .idle
        }
    }

    // MARK: - Derivation from the manual upload queue's pre-upload check

    /// Maps the manual upload queue's "checking before upload" aggregate onto the same phases and
    /// wording. The preparation aggregate cannot distinguish byte-upload from post-check work, so
    /// this surface deliberately never claims `.uploading` - the upload queue panel owns that.
    public init(manualUploadCheck status: UploadPreparationStatus) {
        self.init()
        totalConsidered = status.hasItems ? status.total : 0
        checked = status.resolved
        alreadyBackedUp = status.skippedDuplicates
        skippedRemoteDeletions = status.skippedRemoteDeletions
        failed = status.failed
        fractionCompleted = status.hasItems ? status.progressFraction : nil

        if !status.hasItems {
            phase = .idle
        } else if status.isRunning {
            phase = .checking
        } else if status.failed > 0 {
            phase = .needsAttention
        } else if status.paused > 0 {
            phase = .paused
        } else {
            phase = .completed
        }
    }

    // MARK: - Shared wording (one source for macOS/iOS/iPadOS)

    /// Stable catalog key for the phase headline - exposed so tests can pin wording honesty
    /// (checking is never the uploading key) without compiled string catalogs.
    public var titleKey: String {
        switch phase {
        case .idle: "backup.phase_idle"
        case .scanning: "backup.phase_scanning"
        case .checking: "backup.phase_checking"
        case .uploading: "backup.phase_uploading"
        case .paused: "backup.phase_paused"
        case .waiting: "backup.phase_waiting"
        case .completed:
            dismissedFailures > 0 ? "backup.phase_completed_with_omissions" : "backup.phase_completed"
        case .needsAttention: "backup.phase_attention"
        }
    }

    public var localizedTitle: String {
        switch phase {
        case .idle: L10n.string("backup.phase_idle")
        case .scanning: L10n.string("backup.phase_scanning")
        case .checking: L10n.string("backup.phase_checking")
        case .uploading: L10n.string("backup.phase_uploading")
        case .paused: L10n.string("backup.phase_paused")
        case .waiting: L10n.string("backup.phase_waiting")
        case .completed:
            dismissedFailures > 0
                ? L10n.string("backup.phase_completed_with_omissions")
                : L10n.string("backup.phase_completed")
        case .needsAttention: L10n.string("backup.phase_attention")
        }
    }

    /// One calm supporting line per phase; nil when the headline says it all.
    public var localizedDetail: String? {
        switch phase {
        case .idle, .scanning, .paused:
            return nil
        case .checking:
            if isPreparingRemoteIndex {
                if let completed = remoteIndexCompleted, let total = remoteIndexTotal, total > 0 {
                    return L10n.string("backup.detail_preparing_index \(completed) \(total)")
                }
                return L10n.string("backup.detail_preparing_index_indeterminate")
            }
            guard let total = totalConsidered, total > 0 else { return currentItemName }
            return L10n.string("backup.detail_checked \(checked) \(total)")
        case .uploading:
            guard let total = totalConsidered, total > 0 else { return nil }
            return L10n.string("backup.detail_backed_up \(backedUp) \(total)")
        case .waiting:
            return L10n.string(
                "backup.detail_waiting \(uploadQueued + waitingRetry + max(0, (totalConsidered ?? 0) - checked))")
        case .completed:
            guard alreadyBackedUp > 0 else { return nil }
            return L10n.string("backup.detail_already_backed_up \(alreadyBackedUp)")
        case .needsAttention:
            if remoteIndexPreparationFailed {
                return L10n.string("backup.detail_preparing_index_failed")
            }
            return L10n.string("backup.detail_attention \(needsAttentionCount)")
        }
    }

    /// Scaled units let a continued-processing task advance within one large item while preserving
    /// item-based durable totals. 1,000 subunits per item is enough for one-percent SDK progress and
    /// does not change the user-visible backed-up count.
    public var executionProgress: BackupExecutionProgress? {
        guard let total = totalConsidered, total > 0 else { return nil }
        let scale: Int64 = 1_000
        let activeEquivalent = activeExecutionItemEquivalents
        let completed = Int64(
            ((Double(settled) + activeEquivalent) * Double(scale)).rounded(.down)
        )
        return BackupExecutionProgress(
            completedUnitCount: completed,
            totalUnitCount: Int64(total) * scale
        )
    }
}
