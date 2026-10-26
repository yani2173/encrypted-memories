import Foundation
import PhotosCore

/// One local backup source, independent of its revision and resources. A Live Photo pair, a burst and an
/// edited original all belong to one source and show as one pending tile.
public struct PendingSourceKey: Hashable, Sendable, Codable, Comparable {
    public let kind: UploadSourceIdentity.Kind
    public let identifier: String

    public init(kind: UploadSourceIdentity.Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public init(_ source: UploadSourceIdentity) {
        self.init(kind: source.kind, identifier: source.identifier)
    }

    public init?(localUID: PhotoUID) {
        switch localUID.localPendingNamespace {
        case .photoLibrary: self.init(kind: .photoLibraryAsset, identifier: localUID.nodeID)
        case .file: self.init(kind: .fileURL, identifier: localUID.nodeID)
        case nil: return nil
        }
    }

    /// The grid identity of the pending tile.
    public var localUID: PhotoUID {
        switch kind {
        case .photoLibraryAsset: PhotoUID(localPending: .photoLibrary, identifier: identifier)
        case .fileURL: PhotoUID(localPending: .file, identifier: identifier)
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.kind.rawValue == rhs.kind.rawValue
            ? lhs.identifier < rhs.identifier : lhs.kind.rawValue < rhs.kind.rawValue
    }
}

/// The upload decision and the main photos that this revision replaces.
public struct PendingUploadEvidence: Sendable, Equatable {
    public let key: PendingSourceKey
    public let revision: UploadBackupRevision
    /// Nil when this process has no replacement record for the revision.
    public let replaces: [PhotoUID]?

    public init(key: PendingSourceKey, revision: UploadBackupRevision, replaces: [PhotoUID]?) {
        self.key = key
        self.revision = revision
        self.replaces = replaces
    }
}

/// An in-memory replacement whose new main has committed, independent of pending metadata or publications.
public struct PendingReplacementHandoff: Sendable, Equatable {
    public let evidence: PendingUploadEvidence
    public let remote: PhotoUID
    public let settled: Bool

    public init(evidence: PendingUploadEvidence, remote: PhotoUID, settled: Bool = false) {
        self.evidence = evidence
        self.remote = remote
        self.settled = settled
    }
}

/// How a pending source reached Proton.
public enum PendingHandoffKind: String, Sendable, Codable {
    /// This app committed the primary resource.
    case uploaded
    /// The duplicate check mapped the source to a photo that already exists in Proton.
    case deduplicated
}

/// Durable proof that one revision of a source has a Proton photo. The grid swaps the pending tile for
/// the remote tile once that photo is listed. An empty `remote.volumeID` means the account's photos volume.
public struct PendingHandoff: Sendable, Equatable {
    public let key: PendingSourceKey
    public let revision: UploadBackupRevision
    public let remote: PhotoUID
    public let kind: PendingHandoffKind
    public let createdAt: Date
    public let acknowledged: Bool

    public init(
        key: PendingSourceKey,
        revision: UploadBackupRevision,
        remote: PhotoUID,
        kind: PendingHandoffKind,
        createdAt: Date,
        acknowledged: Bool = false
    ) {
        self.key = key
        self.revision = revision
        self.remote = remote
        self.kind = kind
        self.createdAt = createdAt
        self.acknowledged = acknowledged
    }
}

/// What a handoff record changed for a source that the person excluded while it uploaded.
public enum PendingHandoffOutcome: Sendable, Equatable {
    case recorded
    /// The source is excluded. The store has already scheduled the remote photo for the Proton trash.
    case excludedRemoteNeedsTrash
    case failed
}

/// Presentation data kept for an excluded source, so "Zuletzt gelöscht" and the excluded list can show it
/// without the backup queue.
public struct PendingPresentationMetadata: Sendable, Equatable {
    public let captureTime: Date
    public let mediaType: String
    public let isLivePhoto: Bool
    public let durationSeconds: Double?
    public let displayName: String

    public init(
        captureTime: Date,
        mediaType: String,
        isLivePhoto: Bool = false,
        durationSeconds: Double? = nil,
        displayName: String
    ) {
        self.captureTime = captureTime
        self.mediaType = mediaType
        self.isLivePhoto = isLivePhoto
        self.durationSeconds = durationSeconds
        self.displayName = displayName
    }
}

public enum PendingDesiredState: String, Sendable, Equatable {
    case excluded
    case included
}

/// One source's desired state as read from the store. A readable nil is confirmed absence; `unreadable` means the query
/// failed or the row did not decode.
public enum PendingSourceStateRead: Sendable, Equatable {
    case unreadable
    case readable(PendingSourceState?)

    public var state: PendingSourceState? {
        guard case .readable(let state) = self else { return nil }
        return state
    }
}

/// The source states that decoded, and whether the read was complete. An incomplete read can leave out owed work.
public struct PendingSourceStatesRead: Sendable, Equatable {
    public let states: [PendingSourceState]
    public let complete: Bool

    public init(states: [PendingSourceState], complete: Bool) {
        self.states = states
        self.complete = complete
    }
}

/// One source's latest handoff as read from the store. A readable nil is confirmed absence; `unreadable` means the
/// query failed or the row did not decode.
public enum PendingHandoffRead: Sendable, Equatable {
    case unreadable
    case readable(PendingHandoff?)

    public var handoff: PendingHandoff? {
        guard case .readable(let handoff) = self else { return nil }
        return handoff
    }
}

/// The actions that decoded, and whether the read was complete. An incomplete read can leave out owed actions.
public struct PendingActionsRead: Sendable, Equatable {
    public let actions: [PendingAction]
    public let complete: Bool

    public init(actions: [PendingAction], complete: Bool) {
        self.actions = actions
        self.complete = complete
    }
}

/// The desired backup state of one source and the effects that are still due. A row is never deleted
/// before its effects finish, so a crash or a failed request cannot lose a delete or a restore.
public struct PendingSourceState: Sendable, Equatable {
    public let key: PendingSourceKey
    public let desired: PendingDesiredState
    public let generation: Int64
    /// The backup queue does not yet reflect `desired` (rows removed or re-enqueued).
    public let needsQueueSync: Bool
    /// A Proton photo exists for the source and must move to the Proton trash.
    public let needsRemoteTrash: Bool
    /// This path moved the Proton photo to the trash, and the person restored the source since.
    public let needsRemoteRestore: Bool
    public let remote: PhotoUID?
    /// This path moved `remote` to the Proton trash.
    public let remoteTrashed: Bool
    /// A trash or restore request was sent and its outcome is not confirmed yet. New decisions treat it as
    /// possibly done, so a crash or a late completion cannot lose a compensation.
    public let remoteOperation: PendingSourceEffect?
    public let listedInTrash: Bool
    public let excludedAt: Date?
    public let presentation: PendingPresentationMetadata?
    public let attempts: Int
    public let nextAttemptAt: Date
    public let updatedAt: Date

    public var hasDueEffect: Bool { needsQueueSync || needsRemoteTrash || needsRemoteRestore }

    public init(
        key: PendingSourceKey,
        desired: PendingDesiredState,
        generation: Int64,
        needsQueueSync: Bool,
        needsRemoteTrash: Bool,
        needsRemoteRestore: Bool,
        remote: PhotoUID?,
        remoteTrashed: Bool,
        remoteOperation: PendingSourceEffect? = nil,
        listedInTrash: Bool,
        excludedAt: Date?,
        presentation: PendingPresentationMetadata?,
        attempts: Int,
        nextAttemptAt: Date,
        updatedAt: Date
    ) {
        self.key = key
        self.desired = desired
        self.generation = generation
        self.needsQueueSync = needsQueueSync
        self.needsRemoteTrash = needsRemoteTrash
        self.needsRemoteRestore = needsRemoteRestore
        self.remote = remote
        self.remoteTrashed = remoteTrashed
        self.remoteOperation = remoteOperation
        self.listedInTrash = listedInTrash
        self.excludedAt = excludedAt
        self.presentation = presentation
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.updatedAt = updatedAt
    }
}

/// One exclusion request from a delete in the app.
public struct PendingExclusionRequest: Sendable, Equatable {
    public let key: PendingSourceKey
    public let presentation: PendingPresentationMetadata?
    /// The committed Proton photo of the deleted revision, when a handoff exists. For an unfinished edit, the
    /// earlier upload that its tile hides.
    public let remote: PhotoUID?
    /// The revision the person deleted. The store also looks up a durable handoff of this revision, so a
    /// commit whose event has not reached the coordinator yet still goes to the trash.
    public let revision: UploadBackupRevision?
    /// The coordinator could not tell which Proton photo the delete covers. The store then keeps no photo that the
    /// stored state still names; only a durable commit of the deleted revision goes to the trash.
    public let remoteUnknown: Bool

    public init(
        key: PendingSourceKey,
        presentation: PendingPresentationMetadata?,
        remote: PhotoUID?,
        revision: UploadBackupRevision? = nil,
        remoteUnknown: Bool = false
    ) {
        self.key = key
        self.presentation = presentation
        self.remote = remote
        self.revision = revision
        self.remoteUnknown = remoteUnknown
    }
}

/// The effect a reconciler finished for one source generation.
public enum PendingSourceEffect: String, Sendable, Equatable {
    case queueSync
    case remoteTrash
    case remoteRestore
}

public enum PendingActionKind: String, Sendable, Codable {
    case favorite
    case addToAlbum
}

/// A deferred action on a pending tile. The app applies it once the source's Proton photo is listed.
public struct PendingAction: Sendable, Equatable {
    public let key: PendingSourceKey
    public let kind: PendingActionKind
    /// Empty for favorites.
    public let albumID: String
    /// Favorite: the desired favorite state. Album: always true.
    public let desired: Bool
    public let createdAt: Date
    public let attempts: Int
    public let nextAttemptAt: Date
    public let failed: Bool

    public init(
        key: PendingSourceKey,
        kind: PendingActionKind,
        albumID: String,
        desired: Bool,
        createdAt: Date,
        attempts: Int = 0,
        nextAttemptAt: Date,
        failed: Bool = false
    ) {
        self.key = key
        self.kind = kind
        self.albumID = albumID
        self.desired = desired
        self.createdAt = createdAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.failed = failed
    }
}

/// Retry schedule shared by source effects and deferred actions: 1 min, 5 min, 30 min, 2 h, then 6 h.
public enum PendingRetrySchedule {
    public static func delay(afterAttempts attempts: Int) -> TimeInterval {
        switch attempts {
        case ..<1: 60
        case 1: 5 * 60
        case 2: 30 * 60
        case 3: 2 * 60 * 60
        default: 6 * 60 * 60
        }
    }
}
