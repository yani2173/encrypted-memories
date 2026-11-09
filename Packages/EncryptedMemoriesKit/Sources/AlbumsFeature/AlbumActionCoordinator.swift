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
    public private(set) var loadFailure: AlbumFailurePresentation?
    public private(set) var sharedLoadFailure: AlbumFailurePresentation?
    public var loadErrorMessage: String? { loadFailure?.message }
    public var sharedLoadErrorMessage: String? { sharedLoadFailure?.message }
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
    @ObservationIgnored private var albumReadWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var sharedAlbumReadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var membershipSelection: [PhotoUID] = []
    private var membershipsByPhoto: [PhotoUID: Set<AlbumNodeIdentifier>] = [:]
    private var membershipSelectionIsCovered = false

    public init(repository: AlbumsRepository) {
        self.repository = repository
    }

    public func refresh() async {
        await refreshOwned(allowReplacement: true)
    }

    private func refreshOwned(allowReplacement: Bool) async {
        guard !Task.isCancelled else { return }
        if isLoading {
            let replaceCancelledRead = await withCheckedContinuation { albumReadWaiters.append($0) }
            if replaceCancelledRead {
                await refreshOwned(allowReplacement: false)
            }
            return
        }
        let previous = (loadFailure, lastAlbumLoadFailed, hasCompletedInitialAlbumLoad)
        var wasCancelled = false
        isLoading = true
        loadFailure = nil
        defer {
            isLoading = false
            let waiters = albumReadWaiters
            albumReadWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: wasCancelled && allowReplacement) }
        }
        do {
            let loaded = try await repository.listAlbums()
            try Task.checkCancellation()
            albums = loaded
            lastAlbumLoadFailed = false
            hasCompletedInitialAlbumLoad = true
        } catch {
            if let failure = AlbumFailurePresentation.read(error) {
                loadFailure = failure
                lastAlbumLoadFailed = true
                hasCompletedInitialAlbumLoad = true
            } else {
                wasCancelled = true
                (loadFailure, lastAlbumLoadFailed, hasCompletedInitialAlbumLoad) = previous
            }
        }
    }

    public func refreshSharedAlbums() async {
        await refreshShared(allowReplacement: true)
    }

    private func refreshShared(allowReplacement: Bool) async {
        guard canListSharedWithMe, !Task.isCancelled else { return }
        if isLoadingShared {
            let replaceCancelledRead = await withCheckedContinuation { sharedAlbumReadWaiters.append($0) }
            if replaceCancelledRead {
                await refreshShared(allowReplacement: false)
            }
            return
        }
        let previous = (sharedLoadFailure, lastSharedAlbumLoadFailed, hasCompletedInitialSharedAlbumLoad)
        var wasCancelled = false
        isLoadingShared = true
        sharedLoadFailure = nil
        defer {
            isLoadingShared = false
            let waiters = sharedAlbumReadWaiters
            sharedAlbumReadWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: wasCancelled && allowReplacement) }
        }
        do {
            let loaded = try await repository.listSharedWithMeAlbums()
            try Task.checkCancellation()
            sharedAlbums = loaded
            lastSharedAlbumLoadFailed = false
            hasCompletedInitialSharedAlbumLoad = true
        } catch {
            if let failure = AlbumFailurePresentation.read(error) {
                sharedLoadFailure = failure
                lastSharedAlbumLoadFailed = true
                hasCompletedInitialSharedAlbumLoad = true
            } else {
                wasCancelled = true
                (sharedLoadFailure, lastSharedAlbumLoadFailed, hasCompletedInitialSharedAlbumLoad) = previous
            }
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
        membershipSelection = photoUIDs.uniqued()
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
                case .albumCreatedButPhotosNotAdded(let albumID, _, _, _) = albumError
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
        let uniqueUIDs = photoUIDs.uniqued()
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
            let loaded = try await repository.listAlbums()
            try Task.checkCancellation()
            albums = loaded
            loadFailure = nil
            lastAlbumLoadFailed = false
        } catch {
            // The write already succeeded. Keep the old list and let the owning screen's revision
            // refresh retry later instead of turning a successful mutation into a false failure.
            loadFailure = AlbumFailurePresentation.read(error)
            lastAlbumLoadFailed = loadFailure != nil
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
