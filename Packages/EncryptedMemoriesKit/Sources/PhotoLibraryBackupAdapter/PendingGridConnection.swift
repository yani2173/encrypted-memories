import Observation
import PhotosCore
import TimelineCore
import UploadCore

/// The session and the store of a pending grid that left its connection, by `retire()` or because a new `start`
/// replaced them. The owner closes both. `close(beforeSession:whileStoreOpen:)` keeps the order of the account teardown.
public struct RetiredPendingGrid {
    public let session: PendingGridSession?
    public let store: PendingBackupManifestStore?

    public init(session: PendingGridSession?, store: PendingBackupManifestStore?) {
        self.session = session
        self.store = store
    }

    public static var none: RetiredPendingGrid { RetiredPendingGrid(session: nil, store: nil) }

    public var isEmpty: Bool { session == nil && store == nil }

    /// Runs `beforeSession`, closes the session, runs `whileStoreOpen`, then closes the store. Every other writer of
    /// the store shuts down in one of the two closures, in the order of the account teardown: the Mac's folder backup
    /// belongs to `beforeSession`, because its teardown stage comes before the session closes. The photo backup
    /// controller belongs to `whileStoreOpen`. An empty pair does nothing and runs neither closure.
    @MainActor
    public func close(
        beforeSession: () async -> Void = {}, whileStoreOpen: () async -> Void = {}
    ) async {
        guard !isEmpty else { return }
        await beforeSession()
        await session?.close()
        await whileStoreOpen()
        store?.close()
    }
}

/// The result of `PendingGridConnection.start`.
public struct PendingGridStart {
    /// The session that started. Nil without a store or when the session cannot start.
    public let session: PendingGridSession?
    /// The session and store that this start replaced. Empty unless the connection was still live. The caller
    /// closes it (`RetiredPendingGrid.close`), because the connection no longer knows it.
    public let replaced: RetiredPendingGrid
}

/// Connects one account's `PendingGridSession` to the app, shared by iOS, iPadOS and macOS. It keeps the session
/// and its store for the teardown, shows the session's trash and excluded lists, counts changes of the favorite
/// intents, and hands album adds of pending photos to the session. The account host keeps the teardown order.
@MainActor
@Observable
public final class PendingGridConnection {
    /// Local photos on their way to Proton, merged into the whole-library grid. Nil while no session runs.
    public private(set) var session: PendingGridSession?
    /// Local photos in "Zuletzt gelöscht", shown with the Proton trash.
    public private(set) var trash = PendingTrashPresentation.empty
    /// Photos deleted before upload, for the Backup settings list.
    public private(set) var excludedTiles: [PendingTile] = []
    /// Changes when pending favorite intents change, so favorite displays refresh.
    public private(set) var favoriteRevision: UInt64 = 0
    @ObservationIgnored private var store: PendingBackupManifestStore?
    @ObservationIgnored private var lastFavoriteIntents: [PhotoUID: Bool] = [:]

    public init() {}

    /// Keeps `store` for the teardown, also when no session can start, and starts the session that `makeSession`
    /// builds over it. `prepare` attaches the host's presentation before the session starts. `albumAdds` installs
    /// the album-add handler in the account's albums; without it, album adds of pending photos do not reach the
    /// session. The session is nil without a store or when the session cannot start.
    ///
    /// A session and store that are still live are retired first, so they are never overwritten while open. They
    /// come back as `replaced`, and the caller closes them. The same store passed again stays the live store.
    public func start(
        store: PendingBackupManifestStore?,
        makeSession: (PendingBackupManifestStore) -> PendingGridSession?,
        albumAdds: (@Sendable (@escaping @Sendable ([PhotoUID], String) async -> Bool) async -> Void)? = nil,
        prepare: (PendingGridSession) -> Void = { _ in }
    ) -> PendingGridStart {
        var replaced = RetiredPendingGrid.none
        if session != nil || self.store != nil {
            let earlier = retire()
            replaced = RetiredPendingGrid(
                session: earlier.session, store: earlier.store === store ? nil : earlier.store)
        }
        self.store = store
        guard let store, let session = makeSession(store) else {
            return PendingGridStart(session: nil, replaced: replaced)
        }
        // A retired session still reaches its callbacks, for example when its close publishes empty lists. Only the
        // session that the connection shows may change the connection.
        session.onListsChange = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            trash = session.trash
            excludedTiles = session.excludedTiles
        }
        session.onPendingChange = { [weak self, weak session] snapshot in
            guard let self, let session, self.session === session, snapshot.favoriteIntents != lastFavoriteIntents
            else { return }
            lastFavoriteIntents = snapshot.favoriteIntents
            favoriteRevision &+= 1
        }
        if let albumAdds {
            Task { [weak session] in
                await albumAdds { [weak session] uids, albumID in
                    await session?.addToAlbum(uids, albumID: albumID) ?? false
                }
            }
        }
        self.session = session
        prepare(session)
        session.start()
        return PendingGridStart(session: session, replaced: replaced)
    }

    /// The presentation callback of `session`, for the host to set on `session.presenter.onChange`. It calls `apply`
    /// only while this connection shows `session`. A retired or replaced session still publishes, for example an
    /// empty presentation when it closes, and it cannot change what the host shows. Both references are weak.
    public func presentationHandler(
        for session: PendingGridSession, apply: @escaping (PendingTimelinePresentation) -> Void
    ) -> (PendingTimelinePresentation) -> Void {
        { [weak self, weak session] presentation in
            guard let self, let session, self.session === session else { return }
            apply(presentation)
        }
    }

    /// Detaches the session and its store and empties the lists. The caller closes the session before the backup
    /// controller shuts down, and the store after it (`RetiredPendingGrid.close(beforeSession:whileStoreOpen:)`).
    public func retire() -> RetiredPendingGrid {
        let retired = RetiredPendingGrid(session: session, store: store)
        session = nil
        store = nil
        trash = .empty
        excludedTiles = []
        lastFavoriteIntents = [:]
        favoriteRevision &+= 1
        return retired
    }
}
