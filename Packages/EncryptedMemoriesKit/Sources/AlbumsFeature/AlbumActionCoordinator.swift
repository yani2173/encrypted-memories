import AlbumCore
import Foundation
import Observation
import PhotosCore

public struct AlbumActionFailure: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public enum AlbumCreationOutcome: Sendable, Equatable {
    case completed(albumID: AlbumID)
    /// The album is visible and must not be created again. The selection stays active so the user
    /// can choose that album and retry only the membership operation.
    case albumCreatedNeedsMembershipRetry(albumID: AlbumID)
}

/// One shared state machine for create/list/add album interactions on macOS, iOS and iPadOS. Views
/// choose only the native presentation container; capability gating, serialization, truthful partial
/// success and refresh behavior live here once.
@MainActor
@Observable
public final class AlbumActionCoordinator {
    public static let membershipSelectionLimit = 20

    public private(set) var albums: [AlbumSummary] = []
    public private(set) var sharedAlbums: [SharedAlbumSummary] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingShared = false
    public private(set) var hasCompletedInitialAlbumLoad = false
    public private(set) var hasCompletedInitialSharedAlbumLoad = false
    public private(set) var isWorking = false
    public private(set) var leavingSharedAlbumIDs: Set<AlbumNodeIdentifier> = []
    public private(set) var loadErrorMessage: String?
    public private(set) var sharedLoadErrorMessage: String?
    public var actionFailure: AlbumActionFailure?

    public var canCreate: Bool { repository.capabilities.canCreate }
    public var canAddPhotos: Bool { repository.capabilities.canAddPhotos }
    public var canListSharedWithMe: Bool { repository.capabilities.canListSharedWithMe }
    public var canLeaveSharedAlbum: Bool { repository.capabilities.canLeaveSharedAlbum }
    public var canReadMemberships: Bool { repository.capabilities.canReadMemberships }
    public var capabilities: AlbumCapabilities { repository.capabilities }

    /// Per-album shared permissions. Views must use this instead of evaluating roles themselves.
    public func permissions(for album: SharedAlbumSummary) -> SharedAlbumPermissions {
        repository.permissions(for: album)
    }

    public func presentation(for album: SharedAlbumSummary) -> SharedAlbumPresentation {
        SharedAlbumPresentation(album: album, permissions: permissions(for: album))
    }
    /// The album list shows its loading row while it has no albums and the first load runs, or a retry runs after a
    /// failed load. A reload of an empty list that loaded fine keeps showing the empty list instead of flickering.
    public var showsAlbumLoadingPlaceholder: Bool {
        albums.isEmpty && (!hasCompletedInitialAlbumLoad || (isLoading && lastAlbumLoadFailed))
    }
    public var showsSharedAlbumLoadingPlaceholder: Bool {
        canListSharedWithMe && sharedAlbums.isEmpty
            && (!hasCompletedInitialSharedAlbumLoad || (isLoadingShared && lastSharedAlbumLoadFailed))
    }

    private let repository: AlbumsRepository
    /// Whether the last finished load failed. The error message clears when a retry starts; this does not.
    private var lastAlbumLoadFailed = false
    private var lastSharedAlbumLoadFailed = false
    private var membershipSelection: [PhotoUID] = []
    private var membershipsByPhoto: [PhotoUID: Set<AlbumNodeIdentifier>] = [:]
    private var membershipSelectionIsCovered = false

    public init(repository: AlbumsRepository) {
        self.repository = repository
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadErrorMessage = nil
        defer {
            isLoading = false
            hasCompletedInitialAlbumLoad = true
        }
        do {
            albums = try await repository.listAlbums()
            lastAlbumLoadFailed = false
        } catch {
            loadErrorMessage = Self.message(for: error)
            lastAlbumLoadFailed = true
        }
    }

    public func refreshSharedAlbums() async {
        guard canListSharedWithMe, !isLoadingShared else { return }
        isLoadingShared = true
        sharedLoadErrorMessage = nil
        defer {
            isLoadingShared = false
            hasCompletedInitialSharedAlbumLoad = true
        }
        do {
            sharedAlbums = try await repository.listSharedWithMeAlbums()
            lastSharedAlbumLoadFailed = false
        } catch {
            sharedLoadErrorMessage = Self.message(for: error)
            lastSharedAlbumLoadFailed = true
        }
    }

    public func leaveSharedAlbum(_ album: SharedAlbumSummary) async -> Bool {
        guard canLeaveSharedAlbum, !leavingSharedAlbumIDs.contains(album.node) else { return false }
        leavingSharedAlbumIDs.insert(album.node)
        actionFailure = nil
        defer { leavingSharedAlbumIDs.remove(album.node) }
        do {
            try await repository.leaveSharedAlbum(album.node)
            sharedAlbums.removeAll { $0.node == album.node }
            return true
        } catch {
            actionFailure = AlbumActionFailure(
                title: L10n.string("albums.leave_shared_failed_title"),
                message: Self.message(for: error)
            )
            return false
        }
    }

    /// Loads exact SDK memberships only for small interactive selections. Large selections keep the
    /// write path available but deliberately avoid one get-node request per photo.
    public func loadMemberships(for photoUIDs: [PhotoUID]) async {
        membershipSelection = Self.unique(photoUIDs)
        membershipsByPhoto = [:]
        membershipSelectionIsCovered = false
        guard canReadMemberships,
            !membershipSelection.isEmpty,
            membershipSelection.count <= Self.membershipSelectionLimit
        else { return }
        do {
            membershipsByPhoto = try await repository.albumMemberships(for: membershipSelection)
            membershipSelectionIsCovered = true
        } catch {
            // Membership hints are an optimization. A failed read must not disable the established
            // write path; the picker simply omits checkmarks and submits the original selection.
        }
    }

    public func membershipState(for albumID: AlbumID) -> AlbumMembershipState? {
        guard membershipSelectionIsCovered, !membershipSelection.isEmpty else { return nil }
        let membershipCount = membershipSelection.reduce(into: 0) { count, uid in
            if membershipsByPhoto[uid]?.contains(where: { $0.nodeID == albumID }) == true {
                count += 1
            }
        }
        if membershipCount == 0 { return AlbumMembershipState.none }
        if membershipCount == membershipSelection.count { return .all }
        return .some
    }

    public func createAlbum(name: String, adding photoUIDs: [PhotoUID] = []) async -> AlbumCreationOutcome? {
        guard !isWorking else { return nil }
        isWorking = true
        actionFailure = nil
        defer { isWorking = false }
        do {
            let albumID = try await repository.createAlbum(name: name, adding: photoUIDs)
            await reloadAfterMutation()
            return .completed(albumID: albumID)
        } catch {
            if let albumError = error as? AlbumError,
                case .albumCreatedButPhotosNotAdded(let albumID, _, _) = albumError
            {
                await reloadAfterMutation()
                actionFailure = AlbumActionFailure(
                    title: L10n.string("albums.add_failed_title"),
                    message: Self.message(for: albumError)
                )
                return .albumCreatedNeedsMembershipRetry(albumID: albumID)
            }
            actionFailure = AlbumActionFailure(
                title: L10n.string(photoUIDs.isEmpty ? "albums.create_failed_title" : "albums.add_failed_title"),
                message: Self.message(for: error)
            )
            return nil
        }
    }

    public func add(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async -> Bool {
        let uniqueUIDs = Self.unique(photoUIDs)
        guard !uniqueUIDs.isEmpty, !isWorking else { return false }
        let missingUIDs: [PhotoUID]
        if membershipSelectionIsCovered, Set(uniqueUIDs) == Set(membershipSelection) {
            missingUIDs = uniqueUIDs.filter {
                membershipsByPhoto[$0]?.contains(where: { $0.nodeID == albumID }) != true
            }
        } else {
            missingUIDs = uniqueUIDs
        }
        guard !missingUIDs.isEmpty else { return true }
        isWorking = true
        actionFailure = nil
        defer { isWorking = false }
        do {
            try await repository.addPhotos(missingUIDs, to: albumID)
            for uid in missingUIDs {
                membershipsByPhoto[uid, default: []].insert(
                    AlbumNodeIdentifier(volumeID: uid.volumeID, nodeID: albumID)
                )
            }
            await reloadAfterMutation()
            return true
        } catch {
            actionFailure = AlbumActionFailure(
                title: L10n.string("albums.add_failed_title"),
                message: Self.message(for: error)
            )
            return false
        }
    }

    public func clearActionFailure() {
        actionFailure = nil
    }

    private func reloadAfterMutation() async {
        do {
            albums = try await repository.listAlbums()
            loadErrorMessage = nil
            lastAlbumLoadFailed = false
        } catch {
            // The write already succeeded. Keep the old list and let the owning screen's revision
            // refresh retry later instead of turning a successful mutation into a false failure.
            loadErrorMessage = Self.message(for: error)
            lastAlbumLoadFailed = true
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func unique(_ photoUIDs: [PhotoUID]) -> [PhotoUID] {
        var seen = Set<PhotoUID>()
        return photoUIDs.filter { seen.insert($0).inserted }
    }
}
