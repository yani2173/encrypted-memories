import Foundation
import PhotosCore

// MARK: - Identifiers

/// A Proton photo album identifier (the album's link id within its volume).
public typealias AlbumID = String

// MARK: - Models

/// Lightweight album description for listing/selection UIs.
public struct AlbumSummary: Identifiable, Sendable, Equatable {
    public let id: AlbumID
    /// The SDK node's volume. Writes still use `id` because owned Photos albums share the account's
    /// Photos volume; retaining the volume here keeps catalog identity lossless.
    public let volumeID: String?
    public let title: String
    public let photoCount: Int
    /// The link id of the photo currently used as the album cover, if any.
    public let coverPhotoID: String?
    public let coverPhotoUID: PhotoUID?
    public let lastActivityTime: Date?
    public let isShared: Bool
    public let isSharedByURL: Bool
    /// True when the SDK returned the node but one or more encrypted metadata fields could not be
    /// verified/decrypted. The album remains addressable; presentation can avoid claiming complete metadata.
    public let isMetadataDegraded: Bool

    public init(
        id: AlbumID,
        volumeID: String? = nil,
        title: String,
        photoCount: Int,
        coverPhotoID: String?,
        coverPhotoUID: PhotoUID? = nil,
        lastActivityTime: Date? = nil,
        isShared: Bool = false,
        isSharedByURL: Bool = false,
        isMetadataDegraded: Bool = false
    ) {
        self.id = id
        self.volumeID = volumeID
        self.title = title
        self.photoCount = photoCount
        self.coverPhotoID = coverPhotoID
        self.coverPhotoUID =
            coverPhotoUID
            ?? volumeID.flatMap { volumeID in
                coverPhotoID.map { PhotoUID(volumeID: volumeID, nodeID: $0) }
            }
        self.lastActivityTime = lastActivityTime
        self.isShared = isShared
        self.isSharedByURL = isSharedByURL
        self.isMetadataDegraded = isMetadataDegraded
    }
}

/// Lossless SDK identity for an album or photo node. Album membership and shared-with-me data may
/// cross volumes, so a bare link id is not sufficient outside owned-album write endpoints.
public struct AlbumNodeIdentifier: Hashable, Sendable, Codable {
    public let volumeID: String
    public let nodeID: String

    public init(volumeID: String, nodeID: String) {
        self.volumeID = volumeID
        self.nodeID = nodeID
    }
}

/// App-owned mirror of the SDK 0.32.1 `MemberRole`. Core never imports SDK types.
public enum SharedAlbumRole: Sendable, Equatable, CaseIterable {
    /// Access comes from an ancestor node. The node itself is not shared directly with the user,
    /// so the effective level is unknown here and the app treats it as read-only.
    case inherited
    case viewer
    case editor
    case admin
}

/// Metadata of the direct invitation (`AlbumNode.membership`). It is descriptive only: effective
/// permissions always come from `SharedAlbumSummary.role` (`AlbumNode.directRole`).
public struct SharedAlbumInvitation: Sendable, Equatable {
    /// Role granted by this invitation. It can be lower than the effective role.
    public let role: SharedAlbumRole
    /// The inviter's claimed address, or nil when the SDK returned none.
    public let sharedBy: String?
    /// False when the SDK could not verify the invitation signature. The address is then only claimed.
    public let isSharedByVerified: Bool
    /// Nil when the SDK value is not a plausible invitation time.
    public let inviteTime: Date?

    public init(role: SharedAlbumRole, sharedBy: String?, isSharedByVerified: Bool, inviteTime: Date?) {
        let trimmed = sharedBy?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.sharedBy = trimmed?.isEmpty == false ? trimmed : nil
        self.isSharedByVerified = isSharedByVerified
        self.inviteTime = inviteTime
    }

    /// True when part of the invitation metadata is missing or unverified.
    public var isDegraded: Bool { sharedBy == nil || !isSharedByVerified || inviteTime == nil }

    /// Earliest accepted invitation time (2000-01-01T00:00:00Z). Older values indicate a zero or
    /// corrupt timestamp.
    public static let earliestPlausibleInviteTime = Date(timeIntervalSince1970: 946_684_800)
    /// Tolerated clock skew for invitation times in the future.
    public static let inviteTimeFutureTolerance: TimeInterval = 24 * 60 * 60

    /// Returns a date only for a finite time between 2000-01-01 and `now` plus one day.
    public static func plausibleInviteTime(_ interval: TimeInterval, now: Date = Date()) -> Date? {
        guard interval.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: interval)
        guard date >= earliestPlausibleInviteTime,
            date <= now.addingTimeInterval(inviteTimeFutureTolerance)
        else { return nil }
        return date
    }
}

/// Why a shared album stays read-only in this app.
public enum SharedAlbumWriteRestriction: Sendable, Equatable {
    /// The effective role (viewer, or inherited access) does not permit edits.
    case roleDoesNotPermitEditing
    /// The role permits edits, but no wired write transport addresses shared albums.
    case transportUnsupported
}

extension SharedAlbumWriteRestriction {
    /// User-facing reason shared by rows, hints and errors.
    public var localizedReason: String {
        switch self {
        case .roleDoesNotPermitEditing: L10n.string("albums.shared_read_only_role")
        case .transportUnsupported: L10n.string("albums.shared_read_only_transport")
        }
    }
}

/// Per-album permissions for one shared album. Owned albums keep using `AlbumCapabilities`.
public struct SharedAlbumPermissions: Sendable, Equatable {
    public let canView: Bool
    public let canAddPhotos: Bool
    public let canRemovePhotos: Bool
    public let canSetCover: Bool
    /// Always false: deleting a shared album is not an editor/admin action in this app.
    public let canDelete: Bool
    /// Always false: member and role management is not implemented.
    public let canManageMembers: Bool
    /// Nil when at least one write is permitted.
    public let writeRestriction: SharedAlbumWriteRestriction?

    public var isReadOnly: Bool { !canAddPhotos && !canRemovePhotos && !canSetCover }

    /// The single rule for shared-album writes. It uses the effective role (`directRole`) and the
    /// wired transport, never the invitation role alone.
    public static func resolve(role: SharedAlbumRole, capabilities: AlbumCapabilities) -> SharedAlbumPermissions {
        let roleAllowsEditing: Bool
        switch role {
        case .editor, .admin: roleAllowsEditing = true
        case .viewer, .inherited: roleAllowsEditing = false
        }
        let transport = capabilities.canWriteSharedAlbums
        let canAdd = roleAllowsEditing && transport && capabilities.canAddPhotos
        let canRemove = roleAllowsEditing && transport && capabilities.canRemovePhotos
        let canSetCover = roleAllowsEditing && transport && capabilities.canSetCover
        let restriction: SharedAlbumWriteRestriction?
        if !roleAllowsEditing {
            restriction = .roleDoesNotPermitEditing
        } else if !(canAdd || canRemove || canSetCover) {
            restriction = .transportUnsupported
        } else {
            restriction = nil
        }
        return SharedAlbumPermissions(
            canView: true,
            canAddPhotos: canAdd,
            canRemovePhotos: canRemove,
            canSetCover: canSetCover,
            canDelete: false,
            canManageMembers: false,
            writeRestriction: restriction
        )
    }
}

/// An album shared with the current account.
public struct SharedAlbumSummary: Identifiable, Sendable, Equatable {
    public var id: AlbumNodeIdentifier { node }
    public let node: AlbumNodeIdentifier
    public let title: String
    public let photoCount: Int
    public let coverPhotoID: String?
    public let coverPhotoUID: PhotoUID?
    public let owner: String?
    public let lastActivityTime: Date?
    public let isSharedByURL: Bool
    public let isMetadataDegraded: Bool
    /// Effective role (`AlbumNode.directRole`). Use only this value for permission decisions.
    public let role: SharedAlbumRole
    /// Direct invitation (`AlbumNode.membership`). Nil for inherited access.
    public let invitation: SharedAlbumInvitation?

    public init(
        node: AlbumNodeIdentifier,
        title: String,
        photoCount: Int,
        coverPhotoID: String?,
        coverPhotoUID: PhotoUID? = nil,
        owner: String?,
        lastActivityTime: Date?,
        isSharedByURL: Bool,
        isMetadataDegraded: Bool,
        role: SharedAlbumRole = .inherited,
        invitation: SharedAlbumInvitation? = nil
    ) {
        self.node = node
        self.title = title
        self.photoCount = photoCount
        self.coverPhotoID = coverPhotoID
        self.coverPhotoUID =
            coverPhotoUID
            ?? coverPhotoID.map {
                PhotoUID(volumeID: node.volumeID, nodeID: $0)
            }
        self.owner = owner
        self.lastActivityTime = lastActivityTime
        self.isSharedByURL = isSharedByURL
        self.isMetadataDegraded = isMetadataDegraded
        self.role = role
        self.invitation = invitation
    }
}

public enum AlbumMembershipState: Sendable, Equatable {
    case none
    case some
    case all
}

// MARK: - Capabilities

/// Which album operations the wired backend can actually perform. Drives UI gating and honest
/// "unsupported" messaging; nothing is faked.
public struct AlbumCapabilities: Sendable, Equatable {
    public var canList: Bool
    public var canCreate: Bool
    public var canDelete: Bool
    public var canAddPhotos: Bool
    public var canRemovePhotos: Bool
    public var canSetCover: Bool
    public var canListSharedWithMe: Bool
    public var canLeaveSharedAlbum: Bool
    public var canReadMemberships: Bool
    /// True only when a wired write transport addresses albums on another user's volume. The
    /// owned-album writes above never imply this.
    public var canWriteSharedAlbums: Bool

    public init(
        canList: Bool,
        canCreate: Bool,
        canDelete: Bool = false,
        canAddPhotos: Bool,
        canRemovePhotos: Bool = false,
        canSetCover: Bool,
        canListSharedWithMe: Bool = false,
        canLeaveSharedAlbum: Bool = false,
        canReadMemberships: Bool = false,
        canWriteSharedAlbums: Bool = false
    ) {
        self.canList = canList
        self.canCreate = canCreate
        self.canDelete = canDelete
        self.canAddPhotos = canAddPhotos
        self.canRemovePhotos = canRemovePhotos
        self.canSetCover = canSetCover
        self.canListSharedWithMe = canListSharedWithMe
        self.canLeaveSharedAlbum = canLeaveSharedAlbum
        self.canReadMemberships = canReadMemberships
        self.canWriteSharedAlbums = canWriteSharedAlbums
    }

    /// Read-only: list works, writes are not supported.
    public static let readOnly = AlbumCapabilities(
        canList: true,
        canCreate: false,
        canDelete: false,
        canAddPhotos: false,
        canRemovePhotos: false,
        canSetCover: false
    )

    /// SDK reads plus the narrow direct-HTTP write surface that the Swift API of SDK 0.32.1 cannot replace.
    /// The HTTP writes resolve the account's own Photos share, volume and root key, so they address
    /// only owned albums. `canWriteSharedAlbums` therefore stays false.
    public static let sdkCatalogWithHTTPWrites = AlbumCapabilities(
        canList: true,
        canCreate: true,
        canDelete: true,
        canAddPhotos: true,
        canRemovePhotos: true,
        canSetCover: true,
        canListSharedWithMe: true,
        canLeaveSharedAlbum: true,
        canReadMemberships: true
    )
}

// MARK: - Errors

/// Surfaced when an album operation cannot be completed. `.unsupported` is the explicit,
/// user-visible signal for "the wired backend cannot honestly perform this operation" - never a
/// crash, never silently downgraded to a library-only upload.
public enum AlbumError: LocalizedError, Equatable {
    /// The operation is not implemented by the wired backend. `operation`/`gap` are developer-facing
    /// diagnostics and are deliberately not surfaced in `errorDescription`.
    case unsupported(operation: String, gap: String)
    /// The album exists, but attaching the requested existing photos did not fully converge. The
    /// identifier is retained so UI can refresh the album list and offer a membership-only retry
    /// without creating a duplicate album.
    case albumCreatedButPhotosNotAdded(albumID: AlbumID, albumName: String, message: String)
    /// Proton accepted some membership writes and rejected others. Existing successful membership
    /// must never be hidden behind an all-or-nothing UI claim.
    case partialAdd(succeeded: Int, total: Int, message: String)
    /// A write targeted a shared album. It is rejected before any network request.
    case sharedAlbumReadOnly(SharedAlbumWriteRestriction)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            L10n.string("error.album_action_unavailable")
        case .sharedAlbumReadOnly(let restriction):
            restriction.localizedReason
        case .albumCreatedButPhotosNotAdded(_, let albumName, _):
            L10n.string("error.album_created_add_failed \(albumName)")
        case .partialAdd(let succeeded, let total, _):
            L10n.string("error.album_partial_add \(succeeded) \(total)")
        case .backend:
            L10n.string("error.album_backend")
        }
    }

    /// Raw backend context is retained for opt-in local diagnostics but is never presented to the user.
    /// Proton's API messages are not localized and may contain implementation detail or misleading client copy.
    public var diagnosticDescription: String {
        switch self {
        case .unsupported(let operation, let gap):
            "\(operation): \(gap)"
        case .sharedAlbumReadOnly(let restriction):
            "shared album write rejected: \(restriction)"
        case .albumCreatedButPhotosNotAdded(_, _, let message),
            .partialAdd(_, _, let message),
            .backend(let message):
            message
        }
    }
}
