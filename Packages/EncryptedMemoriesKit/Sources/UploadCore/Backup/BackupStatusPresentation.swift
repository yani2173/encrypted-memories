import Foundation
import PhotosCore

public enum BackupRetryPresentation {
    public static func localizedDescription(for nextAttemptAt: Date?) -> String? {
        guard let nextAttemptAt else { return nil }
        let time = nextAttemptAt.formatted(date: .omitted, time: .shortened)
        return L10n.string("backup.detail_retry_at \(time)")
    }
}

/// Platform-neutral display projection of `BackupStatus` for the backup status row. Shared mapping
/// keeps iOS and macOS wording and row structure consistent. The row contains an icon, phase headline,
/// subtitle, progress, and an optional attention line; `BackupStatusStabilizer` handles rapid phase changes.
public struct BackupStatusPresentation: Sendable, Equatable {
    /// The single activity treatment for the row's one icon (there is never a second spinner).
    public enum Accessory: String, Sendable, Equatable {
        case idle
        case activity
        case success
        case attention
        case paused
        case waiting
        case notice
    }

    /// Stable phase-level geometry for compact platform rows. Per-file transfer changes never alter
    /// this value; only entering or leaving an active known-total pass changes the row height.
    public enum DetailLayout: String, Sendable, Equatable {
        case compact
        case progress
    }

    /// Stable phase key, used both for the headline text and by the stabilizer's dwell.
    public var headlineKey: String
    /// True while a run is active - drives the one spinning icon.
    public var isActive: Bool
    public var accessory: Accessory
    /// Determinate overall fraction (settled/total), or nil = indeterminate (scanning) / none.
    public var progressFraction: Double?

    // Subtitle inputs kept raw so the localized strings are compiler-checked, not built from a
    // dynamic key. `backedUp`/`total` render "<n> of <m>"; `attentionCount` drives the optional
    // attention line.
    public var backedUp: Int
    public var total: Int
    /// Items still to check or upload (`BackupStatus.remainingCount`); "<k> left" follows the backed-up count.
    public var remainingCount: Int
    public var attentionCount: Int
    /// Retryable work waiting on external state. It may open details, but is never worded as failure.
    public var waitingCount: Int
    /// Exact-content matches deliberately not restored after Proton reported them deleted.
    public var skippedRemoteDeletions: Int
    /// Quantized percentage of the resources moving right now. This is a liveness line, not the
    /// library completion percentage and never replaces the backed-up count.
    public var activeTransferPercent: Int?
    /// Exact aggregate byte fraction behind `activeTransferPercent`. When present, the visible progress
    /// bar represents this same transfer instead of an imperceptible one-item step across a large library.
    public var activeTransferFraction: Double?
    /// Upload speed from `BackupTransferRate`. The status alone has no history, so the timeful row model sets it.
    public var bytesPerSecond: Double?
    public var nextAttemptAt: Date?
    /// Queue-wide dedupe-index failure. Kept separate from item failures so hosts do not open an empty
    /// per-photo failure list for an account/service problem.
    public var remoteIndexPreparationFailed: Bool
    public var degradedDedupeUnresolvedCount: Int
    public var executionOpportunityIssue: BackupExecutionOpportunityIssue?

    public var detailLayout: DetailLayout {
        guard total > 0 else { return .compact }
        switch headlineKey {
        case "backup.phase_checking", "backup.phase_uploading", "backup.phase_paused":
            return .progress
        default:
            return .compact
        }
    }

    public init(
        headlineKey: String,
        isActive: Bool,
        accessory: Accessory,
        progressFraction: Double?,
        backedUp: Int = 0,
        total: Int = 0,
        remainingCount: Int = 0,
        attentionCount: Int = 0,
        waitingCount: Int = 0,
        skippedRemoteDeletions: Int = 0,
        activeTransferPercent: Int? = nil,
        activeTransferFraction: Double? = nil,
        bytesPerSecond: Double? = nil,
        nextAttemptAt: Date? = nil,
        remoteIndexPreparationFailed: Bool = false,
        degradedDedupeUnresolvedCount: Int = 0,
        executionOpportunityIssue: BackupExecutionOpportunityIssue? = nil
    ) {
        self.headlineKey = headlineKey
        self.isActive = isActive
        self.accessory = accessory
        self.progressFraction = progressFraction
        self.backedUp = backedUp
        self.total = total
        self.remainingCount = max(0, remainingCount)
        self.attentionCount = attentionCount
        self.waitingCount = waitingCount
        self.skippedRemoteDeletions = skippedRemoteDeletions
        self.activeTransferPercent = activeTransferPercent
        self.activeTransferFraction = activeTransferFraction.map { min(1, max(0, $0)) }
        self.bytesPerSecond = bytesPerSecond
        self.nextAttemptAt = nextAttemptAt
        self.remoteIndexPreparationFailed = remoteIndexPreparationFailed
        self.degradedDedupeUnresolvedCount = max(0, degradedDedupeUnresolvedCount)
        self.executionOpportunityIssue = executionOpportunityIssue
    }

    // MARK: - Mapping from the shared status

    public init(_ status: BackupStatus) {
        let backupTarget = status.backupTargetCount ?? 0
        switch status.phase {
        case .scanning:
            self.init(
                headlineKey: "backup.phase_scanning", isActive: true, accessory: .activity,
                progressFraction: nil, backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .checking:
            self.init(
                headlineKey: "backup.phase_checking",
                isActive: true, accessory: .activity,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .uploading:
            self.init(
                headlineKey: "backup.phase_uploading",
                isActive: true, accessory: .activity,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .paused:
            self.init(
                headlineKey: "backup.phase_paused", isActive: false, accessory: .paused,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .waiting:
            let headlineKey =
                switch status.outstandingIssue {
                case .network: "backup.phase_waiting_network"
                case .remoteService: "backup.phase_waiting_proton"
                case .deviceStorage: "backup.phase_waiting_storage"
                case .accountStorage: "backup.phase_waiting_account_storage"
                case .remoteDraft: "backup.phase_waiting_draft"
                case .deletedElsewhere: "backup.phase_attention"
                default: "backup.phase_waiting"
                }
            self.init(
                headlineKey: headlineKey, isActive: false, accessory: .waiting,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                waitingCount: status.outstandingCount,
                skippedRemoteDeletions: status.skippedRemoteDeletions,
                nextAttemptAt: status.nextAttemptAt)

        case .completed:
            self.init(
                headlineKey: status.dismissedFailures > 0
                    ? "backup.phase_completed_with_omissions"
                    : status.skippedRemoteDeletions > 0
                        ? "backup.phase_completed_with_remote_deletions"
                        : "backup.phase_completed",
                isActive: false,
                accessory: status.dismissedFailures > 0 ? .notice : .success,
                progressFraction: nil,
                backedUp: status.backedUp,
                total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions
            )

        case .needsAttention:
            self.init(
                headlineKey: "backup.phase_attention", isActive: false, accessory: .attention,
                progressFraction: nil, backedUp: status.backedUp, total: backupTarget,
                // Only terminal item failures belong under "couldn't be backed up". A
                // queue-wide index/service interruption can leave a large discovered backlog;
                // those rows are still scheduled work, not failed photos.
                attentionCount: status.needsAttentionCount,
                skippedRemoteDeletions: status.skippedRemoteDeletions,
                nextAttemptAt: status.nextAttemptAt,
                remoteIndexPreparationFailed: status.remoteIndexPreparationFailed)

        case .idle:
            self.init(
                headlineKey: "backup.phase_idle", isActive: false, accessory: .idle,
                progressFraction: nil)
        }
        if let fraction = status.activeTransfer?.fraction {
            activeTransferFraction = fraction
            activeTransferPercent = min(100, max(0, Int((fraction * 100).rounded(.down))))
        }
        if total > 0 { remainingCount = status.remainingCount ?? 0 }
        executionOpportunityIssue = status.executionOpportunityIssue
        if status.remoteContentIndexHealth.shouldWarn {
            degradedDedupeUnresolvedCount = status.remoteContentIndexHealth.unresolvedCount
        }
        remoteIndexPreparationFailed = status.remoteIndexPreparationFailed
    }

    // MARK: - Localized accessors (finite key sets; no dynamic-key lookups)

    public var localizedHeadline: String {
        switch headlineKey {
        case "backup.phase_scanning": return L10n.string("backup.phase_scanning")
        case "backup.phase_checking": return L10n.string("backup.phase_checking")
        case "backup.phase_uploading": return L10n.string("backup.phase_uploading")
        case "backup.phase_paused": return L10n.string("backup.phase_paused")
        case "backup.phase_waiting": return L10n.string("backup.phase_waiting")
        case "backup.phase_waiting_proton": return L10n.string("backup.phase_waiting_proton")
        case "backup.phase_waiting_network": return L10n.string("backup.phase_waiting_network")
        case "backup.phase_waiting_storage": return L10n.string("backup.phase_waiting_storage")
        case "backup.phase_waiting_account_storage": return L10n.string("backup.phase_waiting_account_storage")
        case "backup.phase_waiting_draft": return L10n.string("backup.phase_waiting_draft")
        case "backup.phase_completed": return L10n.string("backup.phase_completed")
        case "backup.phase_completed_with_remote_deletions":
            return L10n.string("backup.phase_completed_with_remote_deletions")
        case "backup.phase_completed_with_omissions":
            return L10n.string("backup.phase_completed_with_omissions")
        case "backup.phase_attention":
            return attentionCount > 0
                ? L10n.string("backup.phase_not_backed_up \(attentionCount)") : L10n.string("backup.phase_attention")
        default: return L10n.string("backup.phase_idle")
        }
    }

    /// "<n> of <m> backed up", followed by "<k> left" while items still wait for their check or upload. Nil when
    /// there is no honest total yet (scanning/idle).
    public var localizedSubtitle: String? {
        guard total > 0 else { return nil }
        guard remainingCount > 0 else { return L10n.string("backup.progress_backed_up \(backedUp) \(total)") }
        return L10n.string("backup.progress_backed_up_left \(backedUp) \(total) \(remainingCount)")
    }

    /// Shown only when something actually needs the user; nil otherwise.
    public var localizedAttention: String? {
        guard attentionCount > 0 else { return nil }
        return L10n.string("backup.progress_attention \(attentionCount)")
    }

    public var localizedWaitingDetail: String? {
        guard waitingCount > 0 else { return nil }
        return L10n.string("backup.progress_waiting \(waitingCount)")
    }

    public var localizedSystemIssue: String? {
        if remoteIndexPreparationFailed {
            return L10n.string("backup.detail_preparing_index_failed")
        }
        switch executionOpportunityIssue {
        case .backgroundRefreshUnavailable:
            return L10n.string("backup.error_background_refresh_unavailable")
        case .backgroundLaunchNotPermitted:
            return L10n.string("backup.error_background_not_permitted")
        case .schedulerCapacity:
            return L10n.string("backup.error_background_scheduler_capacity")
        case .immediateRunIneligible:
            return L10n.string("backup.error_background_immediate_ineligible")
        case .registrationFailed:
            return L10n.string("backup.error_background_registration")
        case .unknown:
            return L10n.string("backup.error_background_unknown")
        case nil:
            return nil
        }
    }

    public var localizedDedupeWarning: String? {
        guard degradedDedupeUnresolvedCount > 0 else { return nil }
        return L10n.string("backup.warning_dedupe_degraded \(degradedDedupeUnresolvedCount)")
    }

    /// Informational, never an attention state: Proton proved the exact files existed and were
    /// deleted there, so automatic backup intentionally did not recreate them.
    public var localizedRemoteDeletionDetail: String? {
        guard skippedRemoteDeletions > 0 else { return nil }
        return L10n.string("backup.detail_respected_remote_deletions \(skippedRemoteDeletions)")
    }

    public var localizedRetryDetail: String? {
        BackupRetryPresentation.localizedDescription(for: nextAttemptAt)
    }

    /// Honest active-transfer liveness for large resources. Kept separate from the stable
    /// "N of M backed up" subtitle so fractional bytes can never inflate the backed-up count.
    public var localizedTransferDetail: String? {
        guard let activeTransferPercent else { return nil }
        guard let speed = localizedUploadSpeed else {
            return L10n.string("backup.progress_transferring \(activeTransferPercent)")
        }
        return L10n.string("backup.progress_transferring_speed \(activeTransferPercent) \(speed)")
    }

    /// The upload speed as a byte count per second, such as "2.4 MB", while bytes move; nil before it is measured.
    public var localizedUploadSpeed: String? {
        guard activeTransferPercent != nil, let bytesPerSecond, bytesPerSecond >= 1 else { return nil }
        return Int64(bytesPerSecond.rounded(.down)).formatted(.byteCount(style: .file))
    }

    /// The bar follows the percentage immediately above it while bytes move. Otherwise it remains the
    /// determinate queue-wide fraction. The durable "N of M" count is never inflated by active bytes.
    public var progressBarFraction: Double? {
        activeTransferFraction ?? progressFraction
    }

    public var localizedProgressBarLabel: String? {
        activeTransferFraction == nil ? localizedSubtitle : localizedTransferDetail
    }
}

extension UploadRemoteIndexPreparationProgress {
    /// "Preparing backup index: 1,200 of 8,000" while the photos already in Proton are indexed; without numbers
    /// before the total is known.
    public var localizedDetail: String {
        if let total, total > 0 {
            return L10n.string("backup.detail_preparing_index \(min(completed, total)) \(total)")
        }
        return L10n.string("backup.detail_preparing_index_indeterminate")
    }

    /// Share of the photos in Proton already indexed. Nil before the total is known.
    public var fractionCompleted: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}
