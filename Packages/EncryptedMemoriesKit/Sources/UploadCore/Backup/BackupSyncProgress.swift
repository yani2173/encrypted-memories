import Foundation

/// Ephemeral byte progress for the transfers that are moving right now. It is deliberately never
/// persisted: queue checkpoints remain item/state based, while this snapshot gives every platform
/// honest liveness for large resources without turning per-block callbacks into database writes.
public struct BackupActiveTransferProgress: Sendable, Equatable {
    public var activeItemCount: Int
    public var completedBytes: Int64
    public var totalBytes: Int64
    /// Sum of each active compound's bounded 0..<1 contribution to library execution progress.
    /// A compound with multiple PhotoKit resources still contributes at most one item.
    public var completedItemEquivalents: Double

    public init(
        activeItemCount: Int,
        completedBytes: Int64,
        totalBytes: Int64,
        completedItemEquivalents: Double
    ) {
        self.activeItemCount = max(0, activeItemCount)
        self.totalBytes = max(0, totalBytes)
        self.completedBytes = min(max(0, completedBytes), self.totalBytes)
        self.completedItemEquivalents = max(0, completedItemEquivalents)
    }

    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

/// UI-facing snapshot of one backup sync pass. Every count comes from the persistent queue, so
/// the snapshot can never claim more than the durable state proves. The wording contract for
/// consumers: `backedUp` is the only number that may be presented as "gesichert"; checking work
/// is "wird geprüft" (never "hashing"); respected remote deletions, missing sources, blocked work,
/// and failures each get their own honest bucket instead of inflating the backed-up count.
public struct BackupSyncProgress: Sendable, Equatable {
    public var total = 0
    /// Discovered/queued rows that no worker has picked up yet.
    public var waiting = 0
    /// Subset of `waiting` already past its duplicate check and waiting for bytes only.
    public var uploadQueued = 0
    /// In the pre-upload phase (resolve + hash + duplicate check) - "wird geprüft".
    public var checking = 0
    /// Pushing bytes right now - "wird gesichert".
    public var uploading = 0
    /// Uploaded by this app.
    public var uploaded = 0
    /// Confirmed as already present (active) in the Proton library without uploading bytes.
    public var alreadyBackedUp = 0
    /// The identical photo was proven in Proton and deleted there. It is deliberately not re-uploaded.
    public var skippedRemoteDeletions = 0
    /// The local source file disappeared before it could be backed up.
    public var sourceMissing = 0
    /// A remote draft occupies the name and must be re-checked before backup.
    public var blocked = 0
    /// Retry budget exhausted - needs user attention.
    public var failed = 0
    /// Permanent failures the user acknowledged. Still not backed up, but no longer attention work.
    public var dismissedFailures = 0
    public var paused = 0
    /// The file currently being processed, for "wird geprüft: IMG_0042.HEIC" style rows.
    public var currentItemName: String?
    /// True while a runner pass is draining the queue.
    public var isRunning = false
    /// True while the throttle policy holds the running pass at zero concurrency
    /// (e.g. critical thermal pressure) - "paused", not "working".
    public var isPausedByPolicy = false
    /// Remote duplicate-index preparation runs before item work so a large encrypted metadata
    /// refresh is visible and resumable instead of looking like a frozen backup counter.
    public var remoteIndexPreparation: UploadRemoteIndexPreparationProgress?
    public var remoteIndexPreparationFailed = false
    /// Durable queue-wide reason for a failed remote index refresh. This is not attached to each photo.
    public var remoteIndexPreparationIssue: BackupIssueRecord?
    /// Readable-but-incomplete remote metadata degrades duplicate coverage without blocking backup.
    /// `.unavailable` never reaches a running snapshot because preparation remains fail-closed.
    public var remoteContentIndexHealth: UploadRemoteContentIndexHealth = .complete(indexedCount: 0)
    /// In-memory only; see `BackupActiveTransferProgress`.
    public var activeTransfer: BackupActiveTransferProgress?
    /// Bytes the runner has sent since it started: finished transfers and the sent share of active ones. It only
    /// grows while the runner lives. In-memory only; the upload speed is its growth over time (`BackupTransferRate`).
    public var transferredBytes: Int64 = 0
    /// Fractional item-equivalents across identity reads, deferred exports and SDK uploads. The runner
    /// combines stages per item monotonically; OS progress can move before upload bytes exist.
    public var activeExecutionItemEquivalents: Double = 0
    /// Queue-derived reason and exact eligibility time when a pass is not running but work remains.
    /// This is the source for both scheduling and honest cross-platform wording.
    public var outstanding = BackupOutstandingSnapshot()

    public init() {}

    /// The only number UI may call "backed up": proven uploads + proven active duplicates.
    public var backedUp: Int { uploaded + alreadyBackedUp }

    /// Rows this pass can no longer move: proven safe, deliberately skipped, gone, or failed.
    /// `blocked` is not settled because a draft retry is still pending.
    public var settled: Int { backedUp + skippedRemoteDeletions + sourceMissing + failed + dismissedFailures }

    /// Honest progress: settled work over total. Stays below 1.0 while anything waits,
    /// runs, or is blocked on a draft re-check.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(settled) / Double(total)
    }

    /// Items the user should look at. A proven remote deletion is an intentional policy success,
    /// not an error; the UI reports its count separately without an attention state.
    public var needsAttention: Int { failed + sourceMissing }

    public var hasOutstandingWork: Bool {
        waiting + checking + uploading + blocked > 0
    }

    /// Seeds the queue-derived counters from a summary; live fields stay as set by the runner.
    public init(
        summary: UploadBackupSyncQueueSummary,
        currentItemName: String? = nil,
        isRunning: Bool = false
    ) {
        self.init()
        total = summary.total
        waiting = summary.waiting
        uploadQueued = summary.queuedForUpload
        checking = summary.checkingActive
        uploading = summary.uploadingActive
        uploaded = summary.uploaded
        alreadyBackedUp = summary.alreadyBackedUp
        skippedRemoteDeletions = summary.skippedRemoteDeletions
        sourceMissing = summary.sourceMissing
        blocked = summary.blocked
        failed = summary.failed
        dismissedFailures = summary.dismissedFailures
        paused = summary.paused
        self.currentItemName = currentItemName
        self.isRunning = isRunning
    }
}
