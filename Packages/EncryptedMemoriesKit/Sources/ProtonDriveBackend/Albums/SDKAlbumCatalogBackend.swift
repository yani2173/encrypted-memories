import AlbumCore
import Foundation
import PhotosCore
import ProtonDriveSDK
import UploadCore

/// Narrow testable surface over the SDK actor. Keeping the protocol here avoids leaking SDK types
/// into AlbumCore while allowing catalog/cancellation/partial-result behavior to be tested without
/// constructing a signed-in Proton client.
protocol SDKPhotoCatalogClient: AnyObject, Sendable {
    func enumerateAlbumNodeUids(
        cancellationToken: UUID,
        onNodeUidEnumerated: @escaping NodeUidCallback
    ) async throws
    func cancelEnumerateAlbumNodeUids(cancellationToken: UUID) async throws
    func enumerateSharedWithMeNodeUids(
        cancellationToken: UUID,
        onNodeUidEnumerated: @escaping NodeUidCallback
    ) async throws
    func cancelEnumerateSharedWithMeNodeUids(cancellationToken: UUID) async throws
    func enumerateAlbum(
        albumUid: SDKNodeUid,
        cancellationToken: UUID,
        onAlbumItemEnumerated: @escaping AlbumItemCallback
    ) async throws
    func cancelEnumerateAlbum(cancellationToken: UUID) async throws
    func getNode(nodeUid: SDKNodeUid, cancellationToken: UUID) async throws -> DriveNode?
    func cancelGetNode(cancellationToken: UUID) async throws
    func leaveSharedNode(nodeUid: SDKNodeUid, cancellationToken: UUID) async throws
    func cancelLeaveSharedNode(cancellationToken: UUID) async throws
}

extension EncryptedMemoriesClient: SDKPhotoCatalogClient {}

enum SDKAlbumCatalogError: LocalizedError {
    case missingNode(AlbumNodeIdentifier)
    case unexpectedOwnedNode(AlbumNodeIdentifier)
    case unexpectedSharedNode(AlbumNodeIdentifier)
    case unexpectedPhotoNode(AlbumNodeIdentifier)
    case invalidCaptureTime(AlbumNodeIdentifier)

    var errorDescription: String? {
        switch self {
        case .missingNode(let node):
            "SDK returned no node for \(node.volumeID)~\(node.nodeID)"
        case .unexpectedOwnedNode(let node):
            "SDK album catalog returned a non-album node for \(node.volumeID)~\(node.nodeID)"
        case .unexpectedSharedNode(let node):
            "SDK shared photo catalog returned an unsupported node for \(node.volumeID)~\(node.nodeID)"
        case .unexpectedPhotoNode(let node):
            "SDK membership lookup returned a non-photo node for \(node.volumeID)~\(node.nodeID)"
        case .invalidCaptureTime(let node):
            "SDK album content returned an invalid capture time for \(node.volumeID)~\(node.nodeID)"
        }
    }
}

/// One account-scoped, short-lived snapshot shared by album UI and derived-data source discovery.
/// Concurrent callers join one SDK enumeration instead of repeating every bounded `getNode` request.
actor SDKSharedAlbumSnapshotCache {
    private struct CachedSnapshot {
        let nodes: [AlbumNode]
        let expiresAt: ContinuousClock.Instant
    }

    private struct Flight {
        let id: UUID
        let generation: UInt64
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<[AlbumNode], any Error>]
    }

    private struct ScopeState {
        var generation: UInt64 = 0
        var cached: CachedSnapshot?
        var flight: Flight?
    }

    private struct OrphanedFlight {
        let scope: ObjectIdentifier
        let task: Task<Void, Never>
    }

    private let lifetime: Duration
    private var scopes: [ObjectIdentifier: ScopeState] = [:]
    private var orphanedFlights: [UUID: OrphanedFlight] = [:]

    init(lifetime: Duration = .seconds(5)) {
        self.lifetime = lifetime
    }

    func value(
        client: any SDKPhotoCatalogClient,
        loader: @escaping @Sendable () async throws -> [AlbumNode]
    ) async throws -> [AlbumNode] {
        try Task.checkCancellation()
        let scope = ObjectIdentifier(client)
        let now = ContinuousClock.now
        if let cached = scopes[scope]?.cached, now < cached.expiresAt {
            try Task.checkCancellation()
            return cached.nodes
        }
        let waiterID = UUID()
        let nodes = try await withTaskCancellationHandler {
            try await wait(
                scope: scope,
                waiterID: waiterID,
                loader: loader
            )
        } onCancel: {
            Task { await self.cancelWaiter(scope: scope, waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return nodes
    }

    /// Fences one account immediately. Canceled native work remains tracked for the shutdown join,
    /// so a successful leave never waits on a non-cooperative SDK cancellation callback.
    func invalidate(client: any SDKPhotoCatalogClient) {
        fence(scopes: [ObjectIdentifier(client)])
    }

    func invalidateAll() async {
        let allScopes = Set(scopes.keys).union(orphanedFlights.values.map(\.scope))
        fence(scopes: Array(allScopes))
        let tasks = orphanedFlights.values.map(\.task)
        for task in tasks { await task.value }
    }

    private func wait(
        scope: ObjectIdentifier,
        waiterID: UUID,
        loader: @escaping @Sendable () async throws -> [AlbumNode]
    ) async throws -> [AlbumNode] {
        try await withCheckedThrowingContinuation { continuation in
            var state = scopes[scope] ?? ScopeState()
            let now = ContinuousClock.now
            if let cached = state.cached, now < cached.expiresAt {
                continuation.resume(returning: cached.nodes)
                return
            }
            state.cached = nil
            if var flight = state.flight {
                flight.waiters[waiterID] = continuation
                state.flight = flight
                scopes[scope] = state
            } else {
                let flightID = UUID()
                let generation = state.generation
                state.flight = Flight(
                    id: flightID,
                    generation: generation,
                    task: nil,
                    waiters: [waiterID: continuation]
                )
                scopes[scope] = state
                let task = Task { [weak self] in
                    let result: Result<[AlbumNode], any Error>
                    do {
                        result = .success(try await loader())
                    } catch {
                        result = .failure(error)
                    }
                    await self?.complete(
                        scope: scope,
                        flightID: flightID,
                        generation: generation,
                        result: result
                    )
                }
                if var installed = scopes[scope], var flight = installed.flight,
                    flight.id == flightID
                {
                    flight.task = task
                    installed.flight = flight
                    scopes[scope] = installed
                } else {
                    task.cancel()
                }
            }
            if Task.isCancelled {
                cancelWaiter(scope: scope, waiterID: waiterID)
            }
        }
    }

    private func cancelWaiter(scope: ObjectIdentifier, waiterID: UUID) {
        guard var state = scopes[scope], var flight = state.flight,
            let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        if flight.waiters.isEmpty {
            state.flight = nil
            if let task = flight.task {
                orphanedFlights[flight.id] = OrphanedFlight(scope: scope, task: task)
                task.cancel()
            }
        } else {
            state.flight = flight
        }
        scopes[scope] = state
        continuation.resume(throwing: CancellationError())
    }

    private func complete(
        scope: ObjectIdentifier,
        flightID: UUID,
        generation: UInt64,
        result: Result<[AlbumNode], any Error>
    ) {
        orphanedFlights.removeValue(forKey: flightID)
        guard var state = scopes[scope], state.generation == generation,
            let flight = state.flight, flight.id == flightID
        else { return }
        state.flight = nil
        if case .success(let nodes) = result {
            state.cached = CachedSnapshot(
                nodes: nodes,
                expiresAt: ContinuousClock.now + lifetime
            )
        }
        scopes[scope] = state
        for continuation in flight.waiters.values {
            switch result {
            case .success(let nodes): continuation.resume(returning: nodes)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private func fence(scopes requestedScopes: [ObjectIdentifier]) {
        let requested = Set(requestedScopes)
        var waiters: [CheckedContinuation<[AlbumNode], any Error>] = []
        for scope in requested {
            guard var state = scopes[scope] else { continue }
            state.generation &+= 1
            state.cached = nil
            if let flight = state.flight {
                if let task = flight.task {
                    orphanedFlights[flight.id] = OrphanedFlight(scope: scope, task: task)
                    task.cancel()
                }
                waiters.append(contentsOf: flight.waiters.values)
                state.flight = nil
            }
            scopes[scope] = state
        }
        for flight in orphanedFlights.values where requested.contains(flight.scope) {
            flight.task.cancel()
        }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// SDK 0.29.1 catalog/sharing/membership adapter. Enumerations publish only after their native
/// callback stream completes, and node hydration uses a bounded task group so a large catalog
/// cannot create one unbounded task per album.
struct SDKAlbumCatalogBackend: AlbumCatalogBackend {
    private let client: any SDKPhotoCatalogClient
    private let maximumConcurrentNodeLoads: Int
    private let admission: JoinedShutdownGate?
    private let sharedAlbumSnapshotCache: SDKSharedAlbumSnapshotCache

    init(
        client: any SDKPhotoCatalogClient,
        maximumConcurrentNodeLoads: Int = 4,
        admission: JoinedShutdownGate? = nil,
        sharedAlbumSnapshotCache: SDKSharedAlbumSnapshotCache = SDKSharedAlbumSnapshotCache()
    ) {
        self.client = client
        self.maximumConcurrentNodeLoads = max(1, maximumConcurrentNodeLoads)
        self.admission = admission
        self.sharedAlbumSnapshotCache = sharedAlbumSnapshotCache
    }

    func listAlbums() async throws -> [AlbumSummary] {
        try await withAdmission {
            try await self.performListAlbums()
        }
    }

    private func performListAlbums() async throws -> [AlbumSummary] {
        let uids = try await enumerateAlbumUIDs()
        let nodes = try await loadNodes(uids)
        let albums = try nodes.compactMap { uid, node -> AlbumSummary? in
            guard let node else {
                throw SDKAlbumCatalogError.missingNode(Self.identifier(uid))
            }
            guard case .album(let album) = node else {
                throw SDKAlbumCatalogError.unexpectedOwnedNode(Self.identifier(uid))
            }
            guard album.trashTime == nil else { return nil }
            return Self.ownedSummary(album)
        }
        return albums.sorted(by: Self.ownedAlbumOrder)
    }

    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] {
        try await withAdmission {
            try await self.performListSharedWithMeAlbums()
        }
    }

    private func performListSharedWithMeAlbums() async throws -> [SharedAlbumSummary] {
        let albums = try await sharedAlbumNodes().map(Self.sharedSummary)
        return albums.sorted(by: Self.sharedAlbumOrder)
    }

    /// Complete, volume-qualified locators for every currently accessible additional album source.
    /// Photo nodes can also appear in Shared with me and are deliberately ignored here.
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        try await withAdmission {
            try await self.sharedAlbumNodes()
                .map { Self.identifier($0.uid) }
                .sorted(by: Self.identifierOrder)
        }
    }

    /// Complete membership enumeration for one source. `AlbumItem` proves only identity and capture time;
    /// richer fields stay unknown so no consumer can mistake a partial SDK contract for full metadata.
    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        try await withAdmission {
            let collector = SDKEnumerationCollector<AlbumItem>()
            let sdkUID = SDKNodeUid(volumeID: album.volumeID, nodeID: album.nodeID)
            let items = try await SDKCancellableOperation.run { token in
                try await client.enumerateAlbum(
                    albumUid: sdkUID,
                    cancellationToken: token,
                    onAlbumItemEnumerated: { result in collector.receive(result) }
                )
                return try collector.collected()
            } cancel: { token in
                try? await client.cancelEnumerateAlbum(cancellationToken: token)
            }
            return try items.map { item in
                guard item.captureTime.isFinite else {
                    throw SDKAlbumCatalogError.invalidCaptureTime(Self.identifier(item.nodeUid))
                }
                return LibrarySourceItem(
                    item: PhotoItem(
                        uid: Self.photoUID(item.nodeUid),
                        captureTime: Date(timeIntervalSince1970: item.captureTime),
                        mediaType: ""
                    ),
                    knownFields: [.captureTime]
                )
            }
        }
    }

    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {
        try await withAdmission {
            try await self.performLeaveSharedAlbum(album)
        }
    }

    private func performLeaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {
        let uid = SDKNodeUid(volumeID: album.volumeID, nodeID: album.nodeID)
        try await SDKCancellableOperation.run { token in
            try await client.leaveSharedNode(nodeUid: uid, cancellationToken: token)
        } cancel: { token in
            try? await client.cancelLeaveSharedNode(cancellationToken: token)
        }
        await sharedAlbumSnapshotCache.invalidate(client: client)
    }

    func albumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        try await withAdmission {
            try await self.performAlbumMemberships(for: photoUIDs)
        }
    }

    private func performAlbumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        let uniqueUIDs = Array(Set(photoUIDs))
        let sdkUIDs = uniqueUIDs.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        let nodes = try await loadNodes(sdkUIDs)
        var result: [PhotoUID: Set<AlbumNodeIdentifier>] = [:]
        result.reserveCapacity(nodes.count)
        for (sdkUID, node) in nodes {
            guard let node else {
                throw SDKAlbumCatalogError.missingNode(Self.identifier(sdkUID))
            }
            guard case .photo(let photo) = node else {
                throw SDKAlbumCatalogError.unexpectedPhotoNode(Self.identifier(sdkUID))
            }
            let uid = PhotoUID(volumeID: sdkUID.volumeID, nodeID: sdkUID.nodeID)
            result[uid] = Set(photo.albumUids.map(Self.identifier))
        }
        return result
    }

    /// The sharing state, the claimed file size, and the albums of each photo. One node read for each photo,
    /// `maximumConcurrentNodeLoads` at once. A missing node fails the read, because absence proves nothing.
    func nodeFacts(of photoUIDs: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await withAdmission {
            let uniqueUIDs = Array(Set(photoUIDs))
            let sdkUIDs = uniqueUIDs.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
            let nodes = try await self.loadNodes(sdkUIDs)
            var facts: [PhotoUID: ExactDuplicateNodeFacts] = [:]
            for (sdkUID, node) in nodes {
                let fact: ExactDuplicateNodeFacts
                switch node {
                case .photo(let photo):
                    fact = .init(
                        isShared: photo.isShared || photo.isSharedByUrl, byteSize: photo.activeRevision.claimedSize,
                        albums: photo.albumUids.map { SeriesAlbumReference(volumeID: $0.volumeID, albumID: $0.nodeID) })
                case .file(let file):
                    fact = .init(
                        isShared: file.isShared || file.isSharedByUrl, byteSize: file.activeRevision.claimedSize)
                case .album, .folder: throw SDKAlbumCatalogError.unexpectedPhotoNode(Self.identifier(sdkUID))
                case nil: throw SDKAlbumCatalogError.missingNode(Self.identifier(sdkUID))
                }
                facts[PhotoUID(volumeID: sdkUID.volumeID, nodeID: sdkUID.nodeID)] = fact
            }
            return facts
        }
    }

    private func withAdmission<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let admission else { return try await operation() }
        return try await admission.withAdmission(operation)
    }

    private func enumerateAlbumUIDs() async throws -> [SDKNodeUid] {
        let collector = SDKEnumerationCollector<SDKNodeUid>()
        return try await SDKCancellableOperation.run { token in
            try await client.enumerateAlbumNodeUids(
                cancellationToken: token,
                onNodeUidEnumerated: { result in collector.receive(result) }
            )
            return try collector.collected()
        } cancel: { token in
            try? await client.cancelEnumerateAlbumNodeUids(cancellationToken: token)
        }
    }

    private func enumerateSharedWithMeUIDs() async throws -> [SDKNodeUid] {
        let collector = SDKEnumerationCollector<SDKNodeUid>()
        return try await SDKCancellableOperation.run { token in
            try await client.enumerateSharedWithMeNodeUids(
                cancellationToken: token,
                onNodeUidEnumerated: { result in collector.receive(result) }
            )
            return try collector.collected()
        } cancel: { token in
            try? await client.cancelEnumerateSharedWithMeNodeUids(cancellationToken: token)
        }
    }

    private func sharedAlbumNodes() async throws -> [AlbumNode] {
        try await sharedAlbumSnapshotCache.value(client: client) {
            try await loadSharedAlbumNodes()
        }
    }

    private func loadSharedAlbumNodes() async throws -> [AlbumNode] {
        let uids = try await enumerateSharedWithMeUIDs()
        let nodes = try await loadNodes(uids)
        return try nodes.compactMap { uid, node in
            guard let node else {
                throw SDKAlbumCatalogError.missingNode(Self.identifier(uid))
            }
            switch node {
            case .album(let album):
                return album.trashTime == nil ? album : nil
            case .photo:
                return nil
            case .folder, .file:
                throw SDKAlbumCatalogError.unexpectedSharedNode(Self.identifier(uid))
            }
        }
    }

    private func loadNodes(_ uids: [SDKNodeUid]) async throws -> [(SDKNodeUid, DriveNode?)] {
        guard !uids.isEmpty else { return [] }
        return try await withThrowingTaskGroup(
            of: (Int, SDKNodeUid, DriveNode?).self,
            returning: [(SDKNodeUid, DriveNode?)].self
        ) { group in
            var nextIndex = 0
            var ordered = [(SDKNodeUid, DriveNode?)?](repeating: nil, count: uids.count)

            func addNext() {
                guard nextIndex < uids.count else { return }
                let index = nextIndex
                let uid = uids[index]
                nextIndex += 1
                group.addTask {
                    let node = try await SDKCancellableOperation.run { token in
                        try await client.getNode(nodeUid: uid, cancellationToken: token)
                    } cancel: { token in
                        try? await client.cancelGetNode(cancellationToken: token)
                    }
                    return (index, uid, node)
                }
            }

            for _ in 0..<min(maximumConcurrentNodeLoads, uids.count) {
                addNext()
            }
            while let (index, uid, node) = try await group.next() {
                ordered[index] = (uid, node)
                addNext()
            }
            return ordered.compactMap { $0 }
        }
    }

    private static func ownedSummary(_ album: AlbumNode) -> AlbumSummary {
        let name = resolvedName(album.name)
        return AlbumSummary(
            id: album.uid.nodeID,
            volumeID: album.uid.volumeID,
            title: name.value,
            photoCount: Int(clamping: album.photoCount),
            coverPhotoID: album.coverPhotoNodeUid?.nodeID,
            coverPhotoUID: album.coverPhotoNodeUid.map(Self.photoUID),
            lastActivityTime: album.lastActivityTime.map(Date.init(timeIntervalSince1970:)),
            isShared: album.isShared,
            isSharedByURL: album.isSharedByUrl,
            isMetadataDegraded: name.isDegraded || !album.errors.isEmpty
        )
    }

    private static func sharedSummary(_ album: AlbumNode) -> SharedAlbumSummary {
        let name = resolvedName(album.name)
        return SharedAlbumSummary(
            node: identifier(album.uid),
            title: name.value,
            photoCount: Int(clamping: album.photoCount),
            coverPhotoID: album.coverPhotoNodeUid?.nodeID,
            coverPhotoUID: album.coverPhotoNodeUid.map(Self.photoUID),
            owner: album.ownedBy.email ?? album.ownedBy.organization,
            lastActivityTime: album.lastActivityTime.map(Date.init(timeIntervalSince1970:)),
            isSharedByURL: album.isSharedByUrl,
            isMetadataDegraded: name.isDegraded || !album.errors.isEmpty,
            role: role(album.directRole),
            invitation: album.membership.map { invitation($0) }
        )
    }

    /// `directRole` is the effective role. `membership.role` is kept only as invitation metadata.
    static func role(_ role: MemberRole) -> SharedAlbumRole {
        switch role {
        case .inherited: .inherited
        case .viewer: .viewer
        case .editor: .editor
        case .admin: .admin
        }
    }

    static func invitation(_ membership: Membership, now: Date = Date()) -> SharedAlbumInvitation {
        SharedAlbumInvitation(
            role: role(membership.role),
            sharedBy: membership.sharedBy.emailAddress,
            isSharedByVerified: membership.sharedBy.signatureVerificationError == nil,
            inviteTime: SharedAlbumInvitation.plausibleInviteTime(membership.inviteTime, now: now)
        )
    }

    private static func resolvedName(
        _ result: Result<String, ProtonDriveSDKDriveError>
    ) -> (value: String, isDegraded: Bool) {
        switch result {
        case .success(let value) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            (value, false)
        default:
            (L10n.string("upload.album_label"), true)
        }
    }

    private static func ownedAlbumOrder(_ lhs: AlbumSummary, _ rhs: AlbumSummary) -> Bool {
        let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
        return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
    }

    private static func sharedAlbumOrder(_ lhs: SharedAlbumSummary, _ rhs: SharedAlbumSummary) -> Bool {
        let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.node.volumeID != rhs.node.volumeID { return lhs.node.volumeID < rhs.node.volumeID }
        return lhs.node.nodeID < rhs.node.nodeID
    }

    private static func identifierOrder(_ lhs: AlbumNodeIdentifier, _ rhs: AlbumNodeIdentifier) -> Bool {
        if lhs.volumeID != rhs.volumeID {
            return lhs.volumeID.utf8.lexicographicallyPrecedes(rhs.volumeID.utf8)
        }
        return lhs.nodeID.utf8.lexicographicallyPrecedes(rhs.nodeID.utf8)
    }

    private static func identifier(_ uid: SDKNodeUid) -> AlbumNodeIdentifier {
        AlbumNodeIdentifier(volumeID: uid.volumeID, nodeID: uid.nodeID)
    }

    private static func photoUID(_ uid: SDKNodeUid) -> PhotoUID {
        PhotoUID(volumeID: uid.volumeID, nodeID: uid.nodeID)
    }
}
