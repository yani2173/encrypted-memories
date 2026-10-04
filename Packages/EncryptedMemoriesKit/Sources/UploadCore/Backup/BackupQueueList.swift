import Foundation
import PhotosCore

/// The files that the backup still has to save: the ones that upload now and the ones that wait their turn.
/// Problem rows stay in the problem list (`BackupFailedItem`); this list shows only work that runs by itself.
public struct BackupQueueList: Sendable, Equatable {
    public enum Phase: String, CaseIterable, Sendable, Identifiable {
        case uploading
        case waiting

        public var id: String { rawValue }

        public var localizedTitle: String {
            switch self {
            case .uploading: L10n.string("backup.queue_section_uploading")
            case .waiting: L10n.string("backup.queue_section_waiting")
            }
        }
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let filename: String
        public let state: UploadBackupSyncQueueState

        public var localizedState: String {
            switch state {
            case .checking: L10n.string("upload.state_preparing")
            case .hashing, .duplicateChecking: L10n.string("upload.state_hashing")
            case .uploading: L10n.string("backup.queue_state_uploading")
            case .finalizing, .needsRemoteReconciliation: L10n.string("upload.state_finalizing")
            case .paused: L10n.string("upload.state_paused")
            default: L10n.string("upload.state_queued")
            }
        }
    }

    public let uploading: [Item]
    /// The first waiting files in the order the backup takes them.
    public let waiting: [Item]
    /// Every waiting file, including those beyond the listed ones.
    public let waitingCount: Int

    public var isEmpty: Bool { uploading.isEmpty && waitingCount == 0 }

    /// Waiting files that the list leaves out.
    public var hiddenWaitingCount: Int { waitingCount - waiting.count }

    public static let empty = BackupQueueList(rows: [])

    /// `limit` bounds the waiting files, so a first pass over a large library stays a short list.
    public init(rows: [UploadBackupQueueRowState], limit: Int = 200) {
        var uploading: [UploadBackupQueueRowState] = []
        var waiting: [UploadBackupQueueRowState] = []
        for row in rows {
            switch Self.phase(of: row.state) {
            case .uploading: uploading.append(row)
            case .waiting: waiting.append(row)
            case nil: break
            }
        }
        // The file that started last is at the top; the backup takes waiting files newest photo first.
        uploading.sort { $0.updatedAt > $1.updatedAt }
        waiting.sort { $0.revision != $1.revision ? $0.revision > $1.revision : $0.updatedAt < $1.updatedAt }
        self.uploading = uploading.map(Self.item)
        self.waiting = waiting.prefix(max(0, limit)).map(Self.item)
        waitingCount = waiting.count
    }

    /// Failed, blocked, and settled rows are not queue work: the problem list or the library shows them.
    public static func phase(of state: UploadBackupSyncQueueState) -> Phase? {
        switch state {
        case .checking, .hashing, .duplicateChecking, .uploading, .finalizing, .needsRemoteReconciliation:
            .uploading
        case .discovered, .queuedForUpload, .paused:
            .waiting
        case .alreadyBackedUp, .completed, .skippedRemoteDeletion, .sourceMissing, .blockedByDraft, .failed,
            .failedPermanent, .dismissedFailure:
            nil
        }
    }

    private static func item(_ row: UploadBackupQueueRowState) -> Item {
        let source = row.source
        return Item(
            id: "\(source.kind.rawValue):\(source.identifier):\(source.resource.rawValue):\(row.revision.rawValue)",
            filename: row.originalFilename,
            state: row.state)
    }
}
