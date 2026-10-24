import Foundation
import PhotosCore

/// One item the backup could not save, projected for a user-facing list. `reason` is always a clear,
/// already-localized sentence (never a raw error code); `isPermanent` marks the ones where retrying
/// cannot help (the local file is gone) so the UI can say so honestly and not offer a pointless retry.
public struct BackupFailedItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let reason: String
    public let category: BackupIssueCategory
    /// Raw detail is for support reports, never for the list.
    public let technicalDetail: String?
    public let isPermanent: Bool
    public let issue: BackupIssueKind
    public let nextAttemptAt: Date?
    public let isRetryable: Bool
    public let source: UploadSourceIdentity?
    public let revision: UploadBackupRevision?

    /// Shared localized retry copy used by both native settings shells.
    public var retryDescription: String? {
        guard category == .automatic else { return nil }
        return BackupRetryPresentation.localizedDescription(for: nextAttemptAt)
    }

    public init(
        id: String,
        filename: String,
        reason: String,
        isPermanent: Bool,
        issue: BackupIssueKind = .unknown,
        nextAttemptAt: Date? = nil,
        isRetryable: Bool? = nil,
        source: UploadSourceIdentity? = nil,
        revision: UploadBackupRevision? = nil,
        category: BackupIssueCategory? = nil,
        technicalDetail: String? = nil
    ) {
        self.category = category ?? issue.category
        self.technicalDetail = technicalDetail
        self.id = id
        self.filename = filename
        self.reason = reason
        self.isPermanent = isPermanent || self.category == .permanent
        self.issue = issue
        self.nextAttemptAt = nextAttemptAt
        self.isRetryable = isRetryable ?? (!self.isPermanent && issue.isRetryable)
        self.source = source
        self.revision = revision
    }

    public init(entry: UploadBackupSyncQueueEntry) {
        let record = BackupIssueRecord.decode(entry.lastError)
        let issue = record?.kind ?? Self.defaultIssue(for: entry.state)
        let waitingKey = record?.detail
        let waitsForOriginal = Self.isWaitingForOriginal(waitingKey)
        let waitsForPhotos = Self.isWaitingForPhotos(waitingKey)
        let isSourceWait =
            issue == .unknown
            && (waitingKey == "error.upload_source_not_ready" || waitsForOriginal || waitsForPhotos)
        // A failed row is no longer planned by the app: whatever its cause, only the person's retry runs it again.
        let isManualRetry = entry.state == .failed && (issue.category == .automatic || issue == .unknown)
        let isPermanentState = entry.state == .sourceMissing || entry.state == .failedPermanent
        let category: BackupIssueCategory
        if isPermanentState {
            category = issue == .deletedElsewhere ? .decision : .permanent
        } else if isSourceWait || (issue == .unknown && entry.state != .failed) {
            category = .automatic
        } else if isManualRetry {
            category = .userResolvable
        } else {
            category = issue.category
        }
        let reason: String
        if category == .permanent && issue.category != .permanent {
            reason = L10n.string("backup.issue_permanent")
        } else if isSourceWait {
            reason =
                waitsForOriginal
                ? L10n.string("backup.issue_waiting_original")
                : waitsForPhotos
                    ? L10n.string("backup.issue_source_unavailable") : L10n.string("backup.issue_source_not_ready")
        } else if issue == .unknown && category == .automatic {
            reason = L10n.string("backup.issue_unknown_waiting")
        } else if isManualRetry && issue == .unknown {
            reason = L10n.string("backup.fail_reason_generic")
        } else {
            reason = Self.localizedReason(for: issue)
        }
        self.init(
            id: "\(entry.source.kind.rawValue)/\(entry.source.identifier)/\(entry.source.resource.rawValue)"
                + "#\(entry.revision.rawValue)",
            filename: entry.originalFilename, reason: reason,
            isPermanent: isPermanentState,
            issue: issue, nextAttemptAt: Self.effectiveNextAttempt(record, entry: entry), source: entry.source,
            revision: entry.revision,
            category: category, technicalDetail: record?.detail ?? entry.lastError)
    }

    /// A manual retry makes a row due before the date that its reason names; the row's own date then wins.
    public static func effectiveNextAttempt(_ record: BackupIssueRecord?, entry: UploadBackupSyncQueueEntry) -> Date? {
        guard let next = record?.nextAttemptAt else { return nil }
        guard entry.state == .discovered || entry.state == .queuedForUpload || entry.state == .blockedByDraft
        else { return next }
        return min(next, entry.updatedAt)
    }

    /// The detail of a row whose file Photos cannot hand out yet (iCloud, an offline library volume, an interrupted
    /// read), and of a row whose file Photos reports as missing. The runner counts the waits of each separately.
    static let sourceUnavailableDetail = "backup.issue_source_unavailable"
    static let sourceReportedMissingDetail = "backup.issue_source_unavailable.reported_missing"

    static func isWaitingForPhotos(_ detail: String?) -> Bool {
        detail == sourceUnavailableDetail || detail == sourceReportedMissingDetail
    }

    static func isWaitingForOriginal(_ detail: String?) -> Bool {
        // The runner persists the key. Earlier builds persisted these sentences; their waits keep their count.
        [
            "backup.issue_waiting_original",
            "The edited photo is waiting for its original resources. Backup will retry automatically.",
            "Das bearbeitete Foto wartet auf seine Originalressourcen. "
                + "Das Backup versucht es automatisch erneut.",
        ].contains(detail ?? "")
    }

    private static func defaultIssue(for state: UploadBackupSyncQueueState) -> BackupIssueKind {
        switch state {
        case .sourceMissing: .sourceMissing
        case .blockedByDraft: .remoteDraft
        case .failedPermanent: .remoteDraftStale
        case .skippedRemoteDeletion: .remoteDeletion
        default: .unknown
        }
    }

    private static func localizedReason(for issue: BackupIssueKind) -> String {
        switch issue {
        case .network: L10n.string("backup.issue_network")
        case .deviceStorage: L10n.string("backup.issue_device_storage")
        case .remoteDraft: L10n.string("backup.issue_remote_draft")
        case .remoteDraftStale: L10n.string("backup.issue_remote_draft_stale")
        case .sourceMissing: L10n.string("backup.issue_source_missing")
        case .permission: L10n.string("backup.issue_permission")
        case .unsupported: L10n.string("backup.issue_unsupported")
        case .remoteService: L10n.string("backup.issue_remote_service")
        case .localState: L10n.string("backup.error_local_state_unavailable")
        case .remoteDeletion: L10n.string("backup.state_skipped_remote_deletion")
        case .deletedElsewhere: L10n.string("backup.issue_deleted_elsewhere")
        case .accountStorage: L10n.string("backup.issue_account_storage")
        case .unknown: L10n.string("backup.fail_reason_generic")
        }
    }
}

extension BackupIssueSection {
    public var localizedTitle: String {
        switch self {
        case .actionNeeded: L10n.string("backup.section_action_needed")
        case .continuesByItself: L10n.string("backup.section_continues_by_itself")
        case .notPossible: L10n.string("backup.section_not_possible")
        }
    }
}

extension Collection where Element == BackupFailedItem {
    /// The list offers Try again only while it shows a photo whose problem the person can fix.
    public var offersUserRetry: Bool { contains { $0.category == .userResolvable } }
}
