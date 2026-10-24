/// The favorite state of one library host: the server favorites, the writes in flight, and whether a read is known.
///
/// Every host keeps one value and runs the backend calls itself. This type owns the transitions, so an optimistic
/// write, its rollback, and a server read that overlaps a write behave the same on every platform.
public struct FavoriteState: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        /// No server read has finished since the last reset.
        case loading
        case available
        /// The last server read failed.
        case unavailable
    }

    /// One server read of the favorites, from `beginLoad` to `finishLoad` or `cancelLoad`.
    public struct Read: Sendable, Equatable {
        fileprivate let id: Int
    }

    public private(set) var favorites: Set<PhotoUID> = []
    /// Identities with a write in flight. A new write that overlaps them is refused.
    public private(set) var inFlight: Set<PhotoUID> = []
    public private(set) var availability: Availability = .loading
    /// Writes that started while a server read ran or no read was known. The next read applies them, so a
    /// delayed response cannot undo a newer optimistic or completed write.
    private var newerTargets: [PhotoUID: Bool] = [:]
    private var openReads: Set<Int> = []
    private var nextRead = 0
    /// The newest read whose response was applied. An older response that arrives later is stale.
    private var appliedRead = -1
    /// The library event token of the newest refresh. A favorite that another device changes moves it.
    private var observedToken: String?
    /// The observed token at the start of each open read, and at the start of the newest applied read.
    private var readTokens: [Int: String] = [:]
    private var appliedToken: String?

    private var tracksNewerWrites: Bool { !openReads.isEmpty || availability != .available }

    /// Whether the favorites may predate the newest observed library token, so a server read is due. A read that
    /// failed, or that started before the newest token, leaves them outdated.
    public var isOutdated: Bool { observedToken != nil && observedToken != appliedToken }

    /// Whether a server read is due: the last one is unknown or failed, or a newer library token arrived.
    public var needsRead: Bool { availability != .available || isOutdated }

    public init() {}

    /// Records the token that a successful library refresh returned. A nil token carries no information.
    public mutating func observeLibraryToken(_ token: String?) {
        if let token { observedToken = token }
    }

    /// Forgets the writes in flight and the read state, for a new session or a retry. The shown favorites stay
    /// when `keepingFavorites` is true, so a retry does not blank the hearts. A read started before the reset
    /// changes nothing when it ends.
    public mutating func reset(keepingFavorites: Bool) {
        let shown = favorites
        let next = nextRead
        self = FavoriteState()
        nextRead = next
        if keepingFavorites { favorites = shown }
    }

    /// Starts a server read. The writes in flight win over its result. Known favorites stay available meanwhile.
    public mutating func beginLoad() -> Read {
        for uid in inFlight { newerTargets[uid] = favorites.contains(uid) }
        let read = Read(id: nextRead)
        nextRead += 1
        openReads.insert(read.id)
        readTokens[read.id] = observedToken
        if availability != .available { availability = .loading }
        return read
    }

    /// Ends a server read. `nil` means that the read failed: the shown favorites stay, and favorites that were
    /// known before stay available. A response older than an applied one changes no favorites.
    public mutating func finishLoad(_ loaded: Set<PhotoUID>?, for read: Read) {
        guard openReads.remove(read.id) != nil else { return }
        let token = readTokens.removeValue(forKey: read.id)
        if let loaded {
            if read.id > appliedRead {
                favorites = FavoriteMutationPolicy.reconciling(authoritative: loaded, newerTargets: newerTargets)
                appliedRead = read.id
                appliedToken = token
            }
            availability = .available
        } else if availability != .available {
            availability = .unavailable
        }
        endRead()
    }

    /// Ends a read whose task was cancelled, without a result.
    public mutating func cancelLoad(_ read: Read) {
        guard openReads.remove(read.id) != nil else { return }
        readTokens.removeValue(forKey: read.id)
        endRead()
    }

    /// Removes photos that moved to the trash, for when the server read after the trash fails.
    public mutating func removeTrashed(_ uids: Set<PhotoUID>) {
        favorites.subtract(uids)
    }

    private mutating func endRead() {
        // A later read that is still open predates the writes of this journal, so they must stay.
        if openReads.isEmpty { newerTargets.removeAll(keepingCapacity: false) }
    }

    /// Plans a write for `selection` and publishes its optimistic state. Nil when the write overlaps one in
    /// flight or changes nothing.
    public mutating func beginWrite(selection: Set<PhotoUID>, target: Bool) -> FavoriteMutationRequest? {
        guard
            let request = FavoriteMutationPolicy.request(
                selection: selection, current: favorites, inFlight: inFlight, target: target)
        else { return nil }
        if tracksNewerWrites {
            for uid in request.requested { newerTargets[uid] = request.target }
        }
        inFlight.formUnion(request.requested)
        favorites = request.optimisticState
        return request
    }

    /// Ends a write. The failed identities return to their state before the write.
    public mutating func finishWrite(_ request: FavoriteMutationRequest, failed: Set<PhotoUID>) {
        if tracksNewerWrites {
            for uid in failed { newerTargets.removeValue(forKey: uid) }
        }
        favorites = FavoriteMutationPolicy.rollbackState(current: favorites, failed: failed, target: request.target)
        inFlight.subtract(request.requested)
    }

    /// Runs a planned write through `write` and returns the identities that failed.
    public static func perform(
        _ request: FavoriteMutationRequest,
        write: ([PhotoUID], Bool) async throws -> Void
    ) async -> Set<PhotoUID> {
        do {
            try await write(Array(request.requested), request.target)
            return []
        } catch {
            return FavoriteMutationPolicy.failedUIDs(after: error, requested: request.requested)
        }
    }
}
