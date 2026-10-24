import Foundation
import PhotosCore
import UploadCore

// MARK: - Local albums

/// A local (device) photo album as seen by the platform adapter - identity, display title, and
/// asset count only. Core never sees PhotoKit types.
public struct LocalAlbumSummary: Identifiable, Sendable, Equatable {
    /// The platform-stable album identifier (PhotoKit's collection localIdentifier).
    public let id: String
    public let title: String
    public let assetCount: Int

    public init(id: String, title: String, assetCount: Int) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
    }
}

/// One typed read of a local album. An existing empty album is valid; a missing album is not.
/// Keeping this distinction in Core prevents platform adapters from turning deletion into remote creation.
public enum AlbumSyncLocalAlbumContents: Sendable, Equatable {
    case present([String])
    case missing
}

// MARK: - Sync mode / mapping

/// v1 is strictly additive: photos are uploaded and attached, never removed - not from the Proton
/// library and not from the Proton album. (A future removal mode must be a separate, explicit,
/// user-visible choice; the raw value is persisted so old mappings keep meaning what they meant.)
public enum AlbumSyncMode: String, Sendable, Codable, Equatable {
    case additive
}

/// The persisted link between a local album and the Proton album it syncs into. Reuse uses the
/// stored mapping. A remote album is never selected only because its name matches.
public struct AlbumSyncMapping: Sendable, Equatable {
    public let localAlbumID: String
    public let remoteAlbumID: String
    /// Last known local title (for Settings display; the remote name is not re-read on rename).
    public var title: String
    public var mode: AlbumSyncMode
    public var createdAt: Date
    public var lastSyncedAt: Date?
    public var lastAttachedCount: Int
    public var lastFailedCount: Int

    public init(
        localAlbumID: String,
        remoteAlbumID: String,
        title: String,
        mode: AlbumSyncMode = .additive,
        createdAt: Date,
        lastSyncedAt: Date? = nil,
        lastAttachedCount: Int = 0,
        lastFailedCount: Int = 0
    ) {
        self.localAlbumID = localAlbumID
        self.remoteAlbumID = remoteAlbumID
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
        self.lastAttachedCount = lastAttachedCount
        self.lastFailedCount = lastFailedCount
    }
}

/// A user-chosen "sync this local album" entry, persisted so the Settings list survives restarts
/// and permission-less launches (the title is the last seen one until the library is read again).
public struct AlbumSyncSelection: Sendable, Equatable {
    public let localAlbumID: String
    public var title: String
    public var addedAt: Date

    public init(localAlbumID: String, title: String, addedAt: Date) {
        self.localAlbumID = localAlbumID
        self.title = title
        self.addedAt = addedAt
    }
}

// MARK: - Remote albums / attach values

/// A Proton album as needed by the sync flow (id + decrypted title).
public struct AlbumSyncRemoteAlbum: Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One photo to attach: the remote node plus, when known from the upload manifest, the plaintext
/// SHA-1 (lets the backend compute the album-context content hash without an extra fetch+decrypt).
public struct AlbumSyncAttachCandidate: Sendable, Equatable {
    public let uid: PhotoUID
    public let sha1Hex: String?

    public init(uid: PhotoUID, sha1Hex: String?) {
        self.uid = uid
        self.sha1Hex = sha1Hex
    }
}

/// Aggregated per-batch attach outcome. "Already a member" counts as convergence, not failure.
public struct AlbumSyncAttachResult: Sendable, Equatable {
    public var attached: Int
    public var alreadyMember: Int
    public var failed: Int
    public var firstFailureMessage: String?
    /// Remote link ids of the photos that could not be attached, one per failure.
    public var failedLinkIDs: [String]
    /// The reason of each failed link id, when the backend names one.
    public var failureMessages: [String: String]

    public init(
        attached: Int = 0,
        alreadyMember: Int = 0,
        failed: Int = 0,
        firstFailureMessage: String? = nil,
        failedLinkIDs: [String] = [],
        failureMessages: [String: String] = [:]
    ) {
        self.attached = attached
        self.alreadyMember = alreadyMember
        self.failed = failed
        self.firstFailureMessage = firstFailureMessage
        self.failedLinkIDs = failedLinkIDs
        self.failureMessages = failureMessages
    }

    public static func += (lhs: inout AlbumSyncAttachResult, rhs: AlbumSyncAttachResult) {
        lhs.attached += rhs.attached
        lhs.alreadyMember += rhs.alreadyMember
        lhs.failed += rhs.failed
        lhs.failedLinkIDs += rhs.failedLinkIDs
        lhs.failureMessages.merge(rhs.failureMessages) { first, _ in first }
        if lhs.firstFailureMessage == nil { lhs.firstFailureMessage = rhs.firstFailureMessage }
    }
}

/// What the upload identity manifest knows about a local asset's remote counterpart.
public struct AlbumSyncRemoteLink: Sendable, Equatable {
    public let uid: PhotoUID
    public let sha1Hex: String?
    /// True when the only known remote copy is in Proton trash - the user deleted it there
    /// intentionally, so album sync must neither attach nor re-upload it.
    public let isTrashed: Bool
    public init(uid: PhotoUID, sha1Hex: String?, isTrashed: Bool) {
        self.uid = uid
        self.sha1Hex = sha1Hex
        self.isTrashed = isTrashed
    }
}

// MARK: - Progress / status

/// The user-facing phase ladder. Wording contract (see the localization catalog): "uploading" only
/// while media bytes actually move; hashing/duplicate checks say "checking", album membership work
/// says "adding" - never a misleading blanket "uploading".
public enum AlbumSyncPhase: Sendable, Equatable {
    case idle
    case scanningLocal
    case backingUp
    case checkingAlbum
    case attaching
    case completed
    case needsAttention
}

/// Immutable progress snapshot for UI (throttling is the observer's job).
public struct AlbumSyncProgress: Sendable, Equatable {
    public var phase: AlbumSyncPhase = .idle
    public var localAlbumID: String?
    public var albumTitle: String = ""
    /// Total assets in the local album.
    public var totalAssets = 0
    /// Backup sub-progress (photos safe in the Proton library). `backupFailed` is live feedback
    /// during the backup phase; the settled equivalent is `unattachable` after planning.
    public var backedUp = 0
    public var backupFailed = 0
    /// Attach sub-progress.
    public var attachTotal = 0
    public var attachDone = 0
    public var alreadyMember = 0
    public var attachFailed = 0
    /// Local assets with no usable remote counterpart after backup (upload failed / asset gone).
    public var unattachable = 0
    /// Local assets whose only remote copy the user trashed on Proton - respected, not attached.
    public var trashedSkipped = 0
    /// Local assets that are in the Proton album, but whose backup is not complete, for example a Live Photo
    /// whose video stays blocked behind a draft.
    public var incomplete = 0
    public var message: String?
    /// The backup phase waits because mobile data is off for backups on an expensive network.
    public var isWaitingForWiFi = false

    public init() {}

    public var needsAttentionCount: Int { attachFailed + unattachable + trashedSkipped + incomplete }

    public var localizedTitle: String {
        switch phase {
        case .idle: L10n.string("albumsync.phase_idle")
        case .scanningLocal: L10n.string("albumsync.phase_scanning")
        case .backingUp:
            isWaitingForWiFi ? L10n.string("backup.phase_waiting_wifi") : L10n.string("albumsync.phase_backing_up")
        case .checkingAlbum: L10n.string("albumsync.phase_checking")
        case .attaching: L10n.string("albumsync.phase_attaching")
        case .completed: L10n.string("albumsync.phase_completed")
        case .needsAttention: L10n.string("albumsync.phase_needs_attention")
        }
    }

    public var localizedDetail: String? {
        switch phase {
        case .idle, .scanningLocal:
            return nil
        case .backingUp:
            return L10n.string("albumsync.detail_backed_up \(backedUp) \(totalAssets)")
        case .checkingAlbum:
            return nil
        case .attaching:
            return L10n.string("albumsync.detail_attached \(attachDone + alreadyMember) \(attachTotal)")
        case .completed:
            return L10n.string("albumsync.detail_completed \(attachDone + alreadyMember)")
        case .needsAttention:
            return message ?? L10n.string("albumsync.detail_needs_attention \(needsAttentionCount)")
        }
    }
}

/// Final outcome of one sync run. A photo skipped because its copy is in the trash remains a gap in the album.
/// Additive sync respects the deletion and reports the photo for the person's decision.
public struct AlbumSyncReport: Sendable, Equatable {
    public let remoteAlbumID: String
    public let totalAssets: Int
    public let attached: Int
    public let alreadyMember: Int
    public let attachFailed: Int
    public let unattachable: Int
    public let trashedSkipped: Int
    /// Photos that are in the Proton album, but whose backup is not complete after this run.
    public let incomplete: Int
    /// One item for each photo that needs attention after this run, with its reason.
    public let problems: [BackupFailedItem]

    public init(
        remoteAlbumID: String,
        totalAssets: Int,
        attached: Int,
        alreadyMember: Int,
        attachFailed: Int,
        unattachable: Int,
        trashedSkipped: Int,
        incomplete: Int = 0,
        problems: [BackupFailedItem] = []
    ) {
        self.remoteAlbumID = remoteAlbumID
        self.totalAssets = totalAssets
        self.attached = attached
        self.alreadyMember = alreadyMember
        self.attachFailed = attachFailed
        self.unattachable = unattachable
        self.trashedSkipped = trashedSkipped
        self.incomplete = incomplete
        self.problems = problems
    }

    public var isFullySynced: Bool {
        attachFailed == 0 && unattachable == 0 && trashedSkipped == 0 && incomplete == 0
    }
}

/// Errors the sync flow surfaces to the UI. All cases are explicit - there is no silent fallback.
public enum AlbumSyncError: LocalizedError, Equatable {
    /// A remote album already carries this name and no mapping exists - the user must choose
    /// between attaching to it and cancelling (we never guess by name).
    case nameConflict(existing: [AlbumSyncRemoteAlbum])
    /// The mapping store could not be opened - syncing without it would re-create albums.
    case mappingStoreUnavailable
    /// The local album disappeared before the runner could safely resolve or mutate remote state.
    case localAlbumMissing
    /// Another album sync is already running (v1 syncs one album at a time).
    case alreadyRunning
    /// The user stopped the run; work already done is durable and the next run converges.
    case stopped

    public var errorDescription: String? {
        switch self {
        case .nameConflict: L10n.string("albumsync.error_name_conflict")
        case .mappingStoreUnavailable: L10n.string("albumsync.error_store_unavailable")
        case .localAlbumMissing: L10n.string("albumsync.error_local_album_missing")
        case .alreadyRunning: L10n.string("albumsync.error_already_running")
        case .stopped: L10n.string("albumsync.error_stopped")
        }
    }
}
