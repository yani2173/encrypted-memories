import Foundation
import PhotosCore

/// Keeps the metadata that the ranking read, so a screen that opens again after a launch splits its groups at once.
///
/// The details belong to one cursor of the content index. A scan reads the cursor first, before any node read, and
/// asks the store for the details of exactly that cursor: when the index applied any event since, the store discards
/// all of them. A ranking stores details only while the index still stands at the cursor of the scan.
///
/// The details only split groups on the screen. They never join groups and never decide a merge or a trash: a merge
/// reads the server state of its group again.
public final class ExactDuplicateFingerprintCache: @unchecked Sendable {
    let store: ExactDuplicateFingerprintStore
    private let accountID: String
    private let lock = NSLock()
    private var snapshot: ExactDuplicateFingerprintStore.Snapshot?

    public init(store: ExactDuplicateFingerprintStore, accountID: String) {
        self.store = store
        self.accountID = accountID
    }

    /// The cache of one account, in that account's data directory next to the other account stores. Sign-out and
    /// account removal delete that directory with everything in it, so the file needs no deletion of its own. Nil when
    /// the store cannot open: every node is then read as before.
    public static func open(
        accountDirectory: URL, policy: LibraryDatabasePolicy = .conservative
    ) -> ExactDuplicateFingerprintCache? {
        let url = accountDirectory.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName)
        guard let store = ExactDuplicateFingerprintStore(url: url, cacheDirectory: accountDirectory, policy: policy)
        else { return nil }
        return ExactDuplicateFingerprintCache(store: store, accountID: accountDirectory.lastPathComponent)
    }

    /// Closes the store before the account directory goes away.
    public func close() { store.close() }

    /// Starts the details of a scan at `eventID`, the cursor that the content index had before the scan read anything.
    /// Without a cursor, or when the store cannot serve it, the scan reads every node as before.
    func begin(volumeID: String, hashKeyEpoch: String, eventID: String?) {
        let next = eventID.flatMap {
            store.prepare(
                scope: .init(accountID: accountID, volumeID: volumeID, hashKeyEpoch: hashKeyEpoch), eventID: $0)
        }
        lock.withLock { snapshot = next }
    }

    /// The saved details of every group whose members all have current details.
    func details(of groups: [ExactDuplicateGroup]) -> [PhotoUID: ExactDuplicateFingerprint] {
        guard let snapshot = lock.withLock({ snapshot }) else { return [:] }
        return store.fingerprints(ofGroups: groups, in: snapshot)
    }

    /// The details of the latest scan. A ranking takes it before its first node read and saves under it only: a scan
    /// that began later replaced it, and the details of the earlier reads must not carry the newer cursor.
    func currentSnapshot() -> ExactDuplicateFingerprintStore.Snapshot? { lock.withLock { snapshot } }

    /// Saves details that a node read returned, for the snapshot that was current before the read began.
    /// `currentEventID` is the cursor that the content index has now.
    func record(
        _ fingerprints: [PhotoUID: ExactDuplicateFingerprint], for snapshot: ExactDuplicateFingerprintStore.Snapshot?,
        currentEventID: String?
    ) {
        guard let snapshot, currentEventID == snapshot.eventID, !fingerprints.isEmpty else { return }
        store.store(fingerprints, for: snapshot)
    }

    /// Advances the saved details to a new cursor of the content index, dropping the details of the given links.
    ///
    /// The event page named `linkIDs` as changed, so their details must not survive. When the cache has no in-memory
    /// cursor, it recovers the persisted snapshot at `fromEventID` to preserve surgical invalidation across launches;
    /// a scope change (another volume or key epoch), a store that cannot serve the surgical advance, or an unreadable
    /// store falls back to a full reset: a stale detail must never reach a ranking.
    public func advance(
        volumeID: String, hashKeyEpoch: String, from fromEventID: String, to toEventID: String,
        invalidating linkIDs: Set<String>
    ) {
        lock.withLock {
            let scope = ExactDuplicateFingerprintStore.Scope(
                accountID: accountID, volumeID: volumeID, hashKeyEpoch: hashKeyEpoch)
            // Recover the persisted snapshot when this launch has no in-memory cursor yet.
            let current = snapshot ?? store.prepare(scope: scope, eventID: fromEventID)
            if let current, current.scope == scope,
                let next = store.advance(from: current, to: toEventID, invalidating: linkIDs)
            {
                self.snapshot = next
                return
            }
            // A different volume or key epoch, or a store that lost the context: discard everything and start fresh.
            snapshot = store.prepare(scope: scope, eventID: toEventID)
        }
    }

    /// Discards every saved detail for a full rebuild. A rebuilt index never serves the details of an earlier cursor.
    public func reset(volumeID: String, hashKeyEpoch: String, to eventID: String) {
        lock.withLock {
            let scope = ExactDuplicateFingerprintStore.Scope(
                accountID: accountID, volumeID: volumeID, hashKeyEpoch: hashKeyEpoch)
            snapshot = store.prepare(scope: scope, eventID: eventID)
        }
    }
}
