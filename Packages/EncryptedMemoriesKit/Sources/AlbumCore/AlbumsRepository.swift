import Foundation
import PhotosCore

/// App-facing album operations. UI binds to this, never to the SDK/HTTP layer. Shares its method set
/// with the split catalog/write seams via `AlbumOperations`; this facade adds input validation and a
/// normalized `AlbumError` surface on top of the injected transports.
public protocol AlbumManaging: AlbumOperations {
    /// Creates one album and, when supplied, attaches already-uploaded photos without moving media
    /// bytes. Capability checks happen before creation so an unsupported add cannot leave an empty
    /// surprise album behind.
    func createAlbum(name: String, adding photoUIDs: [PhotoUID]) async throws -> AlbumID
}

/// Default implementation over separate catalog and write backends. This split makes the SDK the
/// only owned/shared catalog and membership reader while preserving the narrow HTTP write surface
/// for operations SDK 0.29.1 does not expose.
public actor AlbumsRepository: AlbumManaging {
    public nonisolated let capabilities: AlbumCapabilities
    private let catalogBackend: any AlbumCatalogBackend
    private let writeBackend: any AlbumWriteBackend
    private let didLeaveSharedAlbum: @Sendable (AlbumNodeIdentifier) async -> Void
    private var albumCatalogCache: [AlbumSummary]?
    /// Last shared-with-me catalog. Owned-album writes take a bare link id, so this guards against a
    /// shared album reaching the owned-share HTTP path.
    private var sharedAlbumCatalogCache: [SharedAlbumSummary] = []
    private var hasLoadedSharedAlbumCatalog = false
    /// Session-local on-demand membership cache. Successful writes update it in place, so opening a
    /// picker after a mutation cannot show a stale checkmark or schedule a redundant attach.
    private var membershipCache: [PhotoUID: Set<AlbumNodeIdentifier>] = [:]
    private var membershipCacheOrder: [PhotoUID] = []
    private static let membershipCacheLimit = 512
    /// Records album adds of photos that are still on their way to Proton; the backup applies them after
    /// the upload. Nil when no pending grid runs, and local photos then cannot be added.
    private var pendingAlbumAdds: (@Sendable ([PhotoUID], AlbumID) async -> Bool)?

    public init(
        catalogBackend: any AlbumCatalogBackend,
        writeBackend: any AlbumWriteBackend,
        capabilities: AlbumCapabilities = .sdkCatalogWithHTTPWrites,
        didLeaveSharedAlbum: @escaping @Sendable (AlbumNodeIdentifier) async -> Void = { _ in }
    ) {
        self.catalogBackend = catalogBackend
        self.writeBackend = writeBackend
        self.capabilities = capabilities
        self.didLeaveSharedAlbum = didLeaveSharedAlbum
    }

    public func setPendingAlbumAdds(_ record: (@Sendable ([PhotoUID], AlbumID) async -> Bool)?) {
        pendingAlbumAdds = record
    }

    /// Hands local pending photos to the backup, which adds them once they are uploaded.
    private func recordPendingAlbumAdds(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        guard !photoUIDs.isEmpty else { return }
        guard let pendingAlbumAdds else {
            throw AlbumError.unsupported(operation: "Add to album", gap: "no pending grid records local photos")
        }
        guard await pendingAlbumAdds(photoUIDs, albumID) else {
            throw AlbumError.backend("the pending store did not record the album add")
        }
    }

    public func listAlbums() async throws -> [AlbumSummary] {
        guard capabilities.canList else {
            throw AlbumError.unsupported(operation: "List albums", gap: "no album listing backend is wired")
        }
        do {
            let albums = try await catalogBackend.listAlbums()
            albumCatalogCache = albums
            return albums
        } catch {
            throw Self.normalized(error)
        }
    }

    public func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] {
        guard capabilities.canListSharedWithMe else {
            throw AlbumError.unsupported(
                operation: "List shared albums",
                gap: "the wired SDK has no shared-with-me album catalog"
            )
        }
        do {
            let albums = try await catalogBackend.listSharedWithMeAlbums()
            sharedAlbumCatalogCache = albums
            hasLoadedSharedAlbumCatalog = true
            return albums
        } catch {
            throw Self.normalized(error)
        }
    }

    /// Per-album permissions from the effective role and the wired transport.
    public nonisolated func permissions(for album: SharedAlbumSummary) -> SharedAlbumPermissions {
        SharedAlbumPermissions.resolve(role: album.role, capabilities: capabilities)
    }

    public func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {
        guard capabilities.canLeaveSharedAlbum else {
            throw AlbumError.unsupported(
                operation: "Leave shared album",
                gap: "the wired SDK has no leave-shared-node operation"
            )
        }
        do {
            try await catalogBackend.leaveSharedAlbum(album)
            sharedAlbumCatalogCache.removeAll { $0.node == album }
            await didLeaveSharedAlbum(album)
        } catch {
            throw Self.normalized(error)
        }
    }

    public func albumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        guard !photoUIDs.isEmpty else { return [:] }
        guard capabilities.canReadMemberships else {
            throw AlbumError.unsupported(
                operation: "Read album memberships",
                gap: "the wired album catalog does not expose photo membership metadata"
            )
        }
        let uniqueUIDs = Self.unique(photoUIDs)
        // Local pending photos are in no Proton album yet.
        let missing = uniqueUIDs.filter { membershipCache[$0] == nil && !$0.isLocalPending }
        if !missing.isEmpty {
            do {
                let loaded = try await catalogBackend.albumMemberships(for: missing)
                for uid in missing {
                    cacheMemberships(loaded[uid] ?? [], for: uid)
                }
            } catch {
                throw Self.normalized(error)
            }
        }
        return Dictionary(uniqueKeysWithValues: uniqueUIDs.map { ($0, membershipCache[$0] ?? []) })
    }

    /// `albumMemberships(for:)` read from the catalog for every photo, never from the cache, which it refreshes. A write
    /// that depends on the memberships, such as a carry-over before a trash, needs the current state.
    public func currentAlbumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        guard !photoUIDs.isEmpty else { return [:] }
        guard capabilities.canReadMemberships else {
            throw AlbumError.unsupported(
                operation: "Read album memberships",
                gap: "the wired album catalog does not expose photo membership metadata"
            )
        }
        let uniqueUIDs = Self.unique(photoUIDs)
        let remote = uniqueUIDs.filter { !$0.isLocalPending }
        if !remote.isEmpty {
            do {
                let loaded = try await catalogBackend.albumMemberships(for: remote)
                for uid in remote {
                    cacheMemberships(loaded[uid] ?? [], for: uid)
                }
            } catch {
                throw Self.normalized(error)
            }
        }
        return Dictionary(uniqueKeysWithValues: uniqueUIDs.map { ($0, membershipCache[$0] ?? []) })
    }

    public func albumMembershipTitles(for photoUID: PhotoUID) async throws -> [String] {
        let membershipsByPhoto = try await albumMemberships(for: [photoUID])
        let memberships = membershipsByPhoto[photoUID] ?? []
        guard !memberships.isEmpty else { return [] }
        let albums: [AlbumSummary]
        if let albumCatalogCache {
            albums = albumCatalogCache
        } else {
            albums = try await listAlbums()
        }
        let owned = albums.filter { album in
            memberships.contains { membership in
                membership.nodeID == album.id
                    && (album.volumeID == nil || album.volumeID == membership.volumeID)
            }
        }
        if owned.count < memberships.count, capabilities.canListSharedWithMe, !hasLoadedSharedAlbumCatalog {
            _ = try await listSharedWithMeAlbums()
        }
        let shared = sharedAlbumCatalogCache.filter { memberships.contains($0.node) }
        return Set(owned.map(\.title) + shared.map(\.title))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func createAlbum(name: String) async throws -> AlbumID {
        let trimmed = try validatedName(name)
        guard capabilities.canCreate else {
            throw AlbumError.unsupported(
                operation: "Create album",
                gap: "the wired album backend has no SDK-backed album create operation yet"
            )
        }
        do {
            return try await writeBackend.createAlbum(name: trimmed)
        } catch {
            throw Self.normalized(error)
        }
    }

    public func createAlbum(name: String, adding photoUIDs: [PhotoUID]) async throws -> AlbumID {
        let trimmed = try validatedName(name)
        guard capabilities.canCreate else {
            throw AlbumError.unsupported(
                operation: "Create album",
                gap: "the wired album backend has no SDK-backed album create operation yet"
            )
        }
        if !photoUIDs.isEmpty, !capabilities.canAddPhotos {
            throw AlbumError.unsupported(
                operation: "Add to album",
                gap: "the wired album backend has no SDK-backed album photo attachment operation yet"
            )
        }

        let albumID: AlbumID
        do {
            albumID = try await writeBackend.createAlbum(name: trimmed)
        } catch {
            throw Self.normalized(error)
        }
        guard !photoUIDs.isEmpty else { return albumID }
        let split = LocalPendingSplit(photoUIDs)
        do {
            if !split.remote.isEmpty {
                try await writeBackend.addPhotos(split.remote, to: albumID)
                noteAdded(split.remote, to: albumID)
            }
            try await recordPendingAlbumAdds(split.local, to: albumID)
        } catch {
            throw AlbumError.albumCreatedButPhotosNotAdded(
                albumID: albumID,
                albumName: trimmed,
                message: (error as? AlbumError)?.diagnosticDescription
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
        return albumID
    }

    public func deleteAlbum(albumID: AlbumID) async throws {
        guard capabilities.canDelete else {
            throw AlbumError.unsupported(
                operation: "Delete album",
                gap: "the wired album backend exposes no safe album-delete operation"
            )
        }
        try rejectSharedAlbumTarget(albumID)
        do {
            try await writeBackend.deleteAlbum(albumID: albumID)
            for uid in membershipCache.keys {
                removeMembership(albumID, from: uid)
            }
        } catch {
            throw Self.normalized(error)
        }
    }

    public func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        let uniqueUIDs = Self.unique(photoUIDs)
        guard !uniqueUIDs.isEmpty else { return }
        guard capabilities.canAddPhotos else {
            throw AlbumError.unsupported(
                operation: "Add to album",
                gap: "the wired album backend has no SDK-backed album photo attachment operation yet"
            )
        }
        try rejectSharedAlbumTarget(albumID)
        let split = LocalPendingSplit(uniqueUIDs)
        do {
            if !split.remote.isEmpty {
                try await writeBackend.addPhotos(split.remote, to: albumID)
                noteAdded(split.remote, to: albumID)
            }
            try await recordPendingAlbumAdds(split.local, to: albumID)
        } catch {
            throw Self.normalized(error)
        }
    }

    public func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
        let uniqueUIDs = Self.unique(photoUIDs)
        guard !uniqueUIDs.isEmpty else { return }
        guard capabilities.canRemovePhotos else {
            throw AlbumError.unsupported(
                operation: "Remove from album",
                gap: "the wired album backend has no album membership removal operation"
            )
        }
        try rejectSharedAlbumTarget(albumID)
        do {
            try await writeBackend.removePhotos(uniqueUIDs, from: albumID)
            for uid in uniqueUIDs {
                removeMembership(albumID, from: uid)
            }
        } catch {
            throw Self.normalized(error)
        }
    }

    public func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        guard capabilities.canSetCover else {
            throw AlbumError.unsupported(
                operation: "Set album cover",
                gap: "the wired album backend exposes no album-cover write"
            )
        }
        try rejectSharedAlbumTarget(albumID)
        do {
            try await writeBackend.setAlbumCover(albumID: albumID, photoUID: photoUID)
        } catch {
            throw Self.normalized(error)
        }
    }

    /// Owned-album writes use the account's own Photos share and volume. A known shared album that is
    /// not also an owned album is rejected before any request, with its per-album reason. This is
    /// defence in depth: no UI routes shared albums here, and the server remains the authority.
    /// The match uses the link id only; a collision can only reject, never misroute, a write.
    private func rejectSharedAlbumTarget(_ albumID: AlbumID) throws {
        guard albumCatalogCache?.contains(where: { $0.id == albumID }) != true,
            let shared = sharedAlbumCatalogCache.first(where: { $0.node.nodeID == albumID })
        else { return }
        throw AlbumError.sharedAlbumReadOnly(
            permissions(for: shared).writeRestriction ?? .transportUnsupported
        )
    }

    private static func normalized(_ error: Error) -> AlbumError {
        if let albumError = error as? AlbumError { return albumError }
        return .backend((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private static func unique(_ photoUIDs: [PhotoUID]) -> [PhotoUID] {
        var seen = Set<PhotoUID>()
        return photoUIDs.filter { seen.insert($0).inserted }
    }

    private func noteAdded(_ photoUIDs: [PhotoUID], to albumID: AlbumID) {
        let albumVolumeID = albumCatalogCache?.first(where: { $0.id == albumID })?.volumeID
        for uid in photoUIDs {
            guard var memberships = membershipCache[uid] else { continue }
            memberships.insert(
                AlbumNodeIdentifier(volumeID: albumVolumeID ?? uid.volumeID, nodeID: albumID)
            )
            membershipCache[uid] = memberships
        }
    }

    private func cacheMemberships(_ memberships: Set<AlbumNodeIdentifier>, for uid: PhotoUID) {
        if membershipCache[uid] == nil {
            membershipCacheOrder.append(uid)
        }
        membershipCache[uid] = memberships
        while membershipCacheOrder.count > Self.membershipCacheLimit {
            let evicted = membershipCacheOrder.removeFirst()
            membershipCache.removeValue(forKey: evicted)
        }
    }

    private func removeMembership(_ albumID: AlbumID, from uid: PhotoUID) {
        guard let memberships = membershipCache[uid] else { return }
        membershipCache[uid] = Set(memberships.filter { $0.nodeID != albumID })
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AlbumError.backend(L10n.string("error.album_name_empty"))
        }
        return trimmed
    }
}
