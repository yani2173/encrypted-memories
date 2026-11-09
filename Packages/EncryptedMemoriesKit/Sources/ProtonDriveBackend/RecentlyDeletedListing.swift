import CryptoKit
import Foundation
import PhotosCore

/// One photo of the Recently Deleted listing. The listing proves only identity, capture time, and whether the
/// photo is a video, so every trash item is built here, from a fresh listing and from the stored one alike.
enum RecentlyDeletedItem {
    static func make(volumeID: String, nodeID: String, captureTime: Date, isVideo: Bool) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: nodeID),
            captureTime: captureTime,
            mediaType: isVideo ? "video/quicktime" : "image/jpeg",
            tags: isVideo ? [.videos] : [])
    }
}

/// The last Recently Deleted listing of one account and the photos trashed here that no listing settled yet,
/// AES-GCM sealed next to `library-v1.sqlite`.
///
/// A trashed photo left every inventory, and only a listing proves that the user may read it. Without the
/// stored listing, Recently Deleted could not open offline, and the first cache sweep after a launch removed
/// the thumbnails of every trashed photo. The sign-out purge removes the account directory and with it this file.
struct RecentlyDeletedListingStore: Sendable {
    static let fileName = "recently-deleted-v1.enc"

    private struct Record: Codable {
        let volumeID: String
        let nodeID: String
        let captureTime: Double
        let isVideo: Bool

        init(_ item: PhotoItem) {
            volumeID = item.uid.volumeID
            nodeID = item.uid.nodeID
            captureTime = item.captureTime.timeIntervalSince1970
            isVideo = item.isVideo
        }

        var item: PhotoItem {
            RecentlyDeletedItem.make(
                volumeID: volumeID, nodeID: nodeID, captureTime: Date(timeIntervalSince1970: captureTime),
                isVideo: isVideo)
        }
    }

    private struct TrashedHereRecord: Codable {
        let volumeID: String
        let nodeID: String
        let item: Record?
        let misses: Int
    }

    private struct AwaitingLibraryRecord: Codable {
        let volumeID: String
        let nodeID: String
        /// Seconds since the reference date, so that the moment survives a save exactly.
        let trashedAt: Double
    }

    private struct Contents: Codable {
        let listing: [Record]?
        let trashedHere: [TrashedHereRecord]
        /// Absent in files of earlier builds.
        let awaitingLibrary: [AwaitingLibraryRecord]?
        /// Files that events showed as removed and a listing may still return. Absent in files of earlier builds.
        let removedElsewhere: [AwaitingLibraryRecord]?
    }

    private let url: URL
    private let key: SymmetricKey

    init(directory: URL, accountUID: String, keyPassword: String) {
        url = directory.appendingPathComponent(Self.fileName)
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("EncryptedMemories.recently-deleted.v1.\(accountUID)".utf8)
        let info = Data("recently-deleted-listing".utf8)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
    }

    /// The stored state, or nil when there is none or it cannot be opened (another key, corruption).
    func load() -> RecentlyDeletedIdentities.Persisted? {
        guard let blob = try? Data(contentsOf: url),
            let box = try? AES.GCM.SealedBox(combined: blob),
            let plaintext = try? AES.GCM.open(box, using: key),
            let contents = try? JSONDecoder().decode(Contents.self, from: plaintext)
        else { return nil }
        return RecentlyDeletedIdentities.Persisted(
            listing: contents.listing?.map(\.item),
            trashedHere: contents.trashedHere.map {
                .init(
                    uid: PhotoUID(volumeID: $0.volumeID, nodeID: $0.nodeID), item: $0.item?.item,
                    misses: $0.misses)
            },
            trashedAwaitingLibrary: Self.waits(contents.awaitingLibrary),
            removedElsewhereAwaitingLibrary: Self.waits(contents.removedElsewhere))
    }

    private static func waits(_ records: [AwaitingLibraryRecord]?) -> [PhotoUID: Date] {
        Dictionary(
            (records ?? []).map {
                (PhotoUID(volumeID: $0.volumeID, nodeID: $0.nodeID), Date(timeIntervalSinceReferenceDate: $0.trashedAt))
            },
            uniquingKeysWith: max)
    }

    private static func records(_ waits: [PhotoUID: Date]) -> [AwaitingLibraryRecord] {
        waits.sorted { $0.key.nodeID < $1.key.nodeID }.map {
            AwaitingLibraryRecord(
                volumeID: $0.key.volumeID, nodeID: $0.key.nodeID, trashedAt: $0.value.timeIntervalSinceReferenceDate)
        }
    }

    /// Best effort: a failed write only means that the next offline launch shows an older listing.
    func save(_ persisted: RecentlyDeletedIdentities.Persisted) {
        let contents = Contents(
            listing: persisted.listing?.map(Record.init),
            trashedHere: persisted.trashedHere.map {
                TrashedHereRecord(
                    volumeID: $0.uid.volumeID, nodeID: $0.uid.nodeID, item: $0.item.map(Record.init),
                    misses: $0.misses)
            },
            awaitingLibrary: Self.records(persisted.trashedAwaitingLibrary),
            removedElsewhere: Self.records(persisted.removedElsewhereAwaitingLibrary))
        guard let plaintext = try? JSONEncoder().encode(contents),
            let sealed = try? AES.GCM.seal(plaintext, using: key).combined
        else { return }
        do {
            try sealed.write(to: url, options: .atomic)
        } catch {
            PhotoDiagnostics.shared.increment("recentlyDeleted.cacheWriteFailed")
        }
    }
}

/// What one library refresh read: the photos that its listing returned before the events of the refresh filtered
/// it, the photos that these events show as restored, and when the listing was read.
struct LibraryListingRead: Sendable, Equatable {
    var listed: Set<PhotoUID>
    var restoredElsewhere: Set<PhotoUID> = []
    var readAt: Date
}

/// The photos whose thumbnails Recently Deleted may read and keep, newest first.
///
/// A listing is the authority, but it can lag behind a change made here. Photos trashed here join the stored
/// listing at once, so their thumbnails survive a relaunch before a listing shows them. A photo that two listings
/// after the trash request both lack was restored or deleted elsewhere and leaves. Restored photos stay registered
/// until the library lists them again, so their thumbnails never lose their place.
struct RecentlyDeletedIdentities: Sendable, Equatable {
    /// Taken when a listing starts. A listing is stale when a trash change here finished while it ran, or when a
    /// listing that started later was already applied; a stale listing changes nothing.
    struct ListingTicket: Sendable, Equatable {
        fileprivate let start: UInt64
        fileprivate let changes: UInt64
    }

    enum ListingOutcome: Sendable, Equatable {
        case applied
        /// A trash, restore, or Empty Trash request here finished while the listing ran; another listing is needed.
        case overtakenByChange
        /// A listing that started later was already applied.
        case superseded
    }

    /// The last trash listing that the server returned.
    private var receivedListing: [PhotoItem]?
    /// Photos trashed here that no listing has shown yet, oldest request first, with the items the library knew.
    private var trashedHere: [PhotoUID] = []
    private var trashedHereItems: [PhotoUID: PhotoItem] = [:]
    /// Listings since the trash request that lacked the photo. The second one proves that it moved on elsewhere.
    private var trashedHereMisses: [PhotoUID: Int] = [:]
    /// Photos restored here. A library refresh that lists one marks it; the next refresh releases it, because by
    /// then the library that lists it was published.
    private var restoredHere: [PhotoUID] = []
    private var restoredListedByLibrary: Set<PhotoUID> = []
    /// Photos trashed here, with the moment of the trash, that a library listing may still return. The library
    /// listing lags behind a trash; without this, a refresh would bring them back into the library and into the
    /// stored timeline, and a relaunch would show them until the listing caught up.
    private var trashedAwaitingLibrary: [PhotoUID: Date] = [:]
    /// Files that volume events showed as removed, with the moment a refresh first read that event. A refresh that
    /// commits moves the event cursor past the event, so a later refresh, also after a relaunch, no longer sees it
    /// while the listing can still return the file. They end like a trash here; `libraryLagLimit` bounds the age, and
    /// every accepted listing prunes them, so only the removals of the last `libraryLagLimit` stay.
    private var removedElsewhereAwaitingLibrary: [PhotoUID: Date] = [:]
    /// A photo that a library listing still returns this long after the trash was restored elsewhere.
    static let libraryLagLimit: TimeInterval = 600
    private var listingStarts: UInt64 = 0
    private var appliedListingStart: UInt64 = 0
    private var changesHere: UInt64 = 0
    /// True until a listing applies: once per session, again after a failed or overtaken listing, and while a
    /// photo trashed here still waits for a listing that shows it.
    private(set) var needsListing = true

    /// What survives a relaunch: the last listing and the photos trashed here that no second listing settled.
    struct Persisted: Sendable, Equatable {
        struct TrashedHere: Sendable, Equatable {
            let uid: PhotoUID
            let item: PhotoItem?
            let misses: Int
        }

        var listing: [PhotoItem]?
        var trashedHere: [TrashedHere] = []
        var trashedAwaitingLibrary: [PhotoUID: Date] = [:]
        var removedElsewhereAwaitingLibrary: [PhotoUID: Date] = [:]
    }

    init(listing: [PhotoItem]?) {
        self.init(persisted: Persisted(listing: listing))
    }

    init(persisted: Persisted) {
        receivedListing = persisted.listing
        for entry in persisted.trashedHere where !trashedHere.contains(entry.uid) {
            trashedHere.append(entry.uid)
            if let item = entry.item { trashedHereItems[entry.uid] = item }
            if entry.misses > 0 { trashedHereMisses[entry.uid] = entry.misses }
        }
        trashedAwaitingLibrary = persisted.trashedAwaitingLibrary
        removedElsewhereAwaitingLibrary = persisted.removedElsewhereAwaitingLibrary
    }

    var persisted: Persisted {
        Persisted(
            listing: receivedListing,
            trashedHere: trashedHere.map {
                .init(uid: $0, item: trashedHereItems[$0], misses: trashedHereMisses[$0] ?? 0)
            },
            trashedAwaitingLibrary: trashedAwaitingLibrary,
            removedElsewhereAwaitingLibrary: removedElsewhereAwaitingLibrary)
    }

    /// What Recently Deleted shows and stores: the last listing and the photos trashed here that it lacks.
    var listing: [PhotoItem]? {
        let pending = trashedHere.compactMap { trashedHereItems[$0] }
        guard receivedListing != nil || !pending.isEmpty else { return nil }
        var seen = Set<PhotoUID>()
        return ((receivedListing ?? []) + pending)
            .filter { seen.insert($0.uid).inserted }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
    }

    /// Registered identities: photos trashed here first, then the listing newest first, then restored photos.
    var ordered: [PhotoUID] {
        var seen = Set<PhotoUID>()
        let listed = (listing ?? []).reversed().map(\.uid)
        return (trashedHere.reversed() + listed + restoredHere).filter { seen.insert($0).inserted }
    }

    var photosTrashedHereAwaitingLibraryCount: Int { trashedAwaitingLibrary.count }

    var hasRestoredPhotos: Bool { !restoredHere.isEmpty }

    mutating func beginListing() -> ListingTicket {
        listingStarts &+= 1
        return ListingTicket(start: listingStarts, changes: changesHere)
    }

    /// Applies a listing unless it is stale.
    mutating func received(_ listing: [PhotoItem], ticket: ListingTicket) -> ListingOutcome {
        guard ticket.changes == changesHere else {
            needsListing = true
            return .overtakenByChange
        }
        guard ticket.start > appliedListingStart else { return .superseded }
        appliedListingStart = ticket.start
        receivedListing = listing
        let listed = Set(listing.map(\.uid))
        var kept = Set<PhotoUID>()
        for uid in trashedHere where !listed.contains(uid) {
            let misses = (trashedHereMisses[uid] ?? 0) + 1
            if misses < 2 {
                trashedHereMisses[uid] = misses
                kept.insert(uid)
            }
        }
        trashedHere.removeAll { !kept.contains($0) }
        trashedHereItems = trashedHereItems.filter { kept.contains($0.key) }
        trashedHereMisses = trashedHereMisses.filter { kept.contains($0.key) }
        needsListing = !trashedHere.isEmpty
        return .applied
    }

    mutating func listingFailed() {
        needsListing = true
    }

    /// `items` holds what the library knew about the moved photos; a photo without one is registered only.
    mutating func trashed(_ uids: [PhotoUID], items: [PhotoItem], at now: Date = Date()) {
        changesHere &+= 1
        for uid in uids { trashedAwaitingLibrary[uid] = now }
        needsListing = true
        let moved = Set(uids)
        restoredHere.removeAll { moved.contains($0) }
        restoredListedByLibrary.subtract(moved)
        trashedHere.removeAll { moved.contains($0) }
        trashedHere.append(contentsOf: uids)
        trashedHereMisses = trashedHereMisses.filter { !moved.contains($0.key) }
        for item in items where moved.contains(item.uid) { trashedHereItems[item.uid] = item }
    }

    mutating func restored(_ uids: [PhotoUID]) {
        changesHere &+= 1
        let moved = Set(uids)
        receivedListing?.removeAll { moved.contains($0.uid) }
        trashedHere.removeAll { moved.contains($0) }
        trashedHereItems = trashedHereItems.filter { !moved.contains($0.key) }
        trashedHereMisses = trashedHereMisses.filter { !moved.contains($0.key) }
        restoredHere.removeAll { moved.contains($0) }
        restoredListedByLibrary.subtract(moved)
        restoredHere.append(contentsOf: uids)
        for uid in uids {
            trashedAwaitingLibrary[uid] = nil
            removedElsewhereAwaitingLibrary[uid] = nil
        }
    }

    /// Called with the volume events that a refresh read, before it reads the listing and before the refresh moves
    /// its event cursor. A file that the events show as active again leaves at once; a removed file waits from the
    /// first refresh that read its removal. Returns whether the persisted state changed, so the caller saves it
    /// before the cursor moves past these events.
    mutating func eventsRead(_ changes: TimelineRemoteEventChanges, volumeID: String, at now: Date) -> Bool {
        let before = removedElsewhereAwaitingLibrary
        for nodeID in changes.active {
            removedElsewhereAwaitingLibrary[PhotoUID(volumeID: volumeID, nodeID: nodeID)] = nil
        }
        for nodeID in changes.removed {
            let uid = PhotoUID(volumeID: volumeID, nodeID: nodeID)
            if removedElsewhereAwaitingLibrary[uid] == nil { removedElsewhereAwaitingLibrary[uid] = now }
        }
        return removedElsewhereAwaitingLibrary != before
    }

    /// Called when a refresh cannot read the events since its cursor. A restore elsewhere is then unknown, and no
    /// later event would end the wait, so a removed file shows again as soon as a listing returns it. Returns whether
    /// the persisted state changed.
    mutating func eventsLost() -> Bool {
        guard !removedElsewhereAwaitingLibrary.isEmpty else { return false }
        removedElsewhereAwaitingLibrary = [:]
        return true
    }

    /// The trash is empty now; restored photos keep their thumbnails until the library lists them again.
    mutating func emptied() {
        changesHere &+= 1
        receivedListing = []
        trashedHere = []
        trashedHereItems = [:]
        trashedHereMisses = [:]
    }

    var hasPhotosAwaitingLibrary: Bool { !trashedAwaitingLibrary.isEmpty || !removedElsewhereAwaitingLibrary.isEmpty }

    /// The photos trashed here or removed by an event that a listing still returns; the caller leaves them out.
    func lagging(in read: LibraryListingRead, now: Date) -> Set<PhotoUID> {
        let waits = { (wait: (key: PhotoUID, value: Date)) in
            read.listed.contains(wait.key) && !read.restoredElsewhere.contains(wait.key)
                && Self.awaitsLibrary(trashedAt: wait.value, now: now)
        }
        return Set(trashedAwaitingLibrary.filter(waits).keys).union(removedElsewhereAwaitingLibrary.filter(waits).keys)
    }

    /// Called once the library of a refresh is accepted; a discarded refresh must not end a wait. Ends the wait of a
    /// photo that another device restored, that waited `libraryLagLimit`, or that was trashed before the listing
    /// and that the listing no longer returns. Returns whether the persisted state changed.
    mutating func libraryAccepted(_ read: LibraryListingRead, now: Date) -> Bool {
        let before = (trashedAwaitingLibrary, removedElsewhereAwaitingLibrary)
        let waits = { (wait: (key: PhotoUID, value: Date)) in
            Self.awaitsLibrary(trashedAt: wait.value, now: now) && !read.restoredElsewhere.contains(wait.key)
                && (read.listed.contains(wait.key) || wait.value > read.readAt)
        }
        trashedAwaitingLibrary = trashedAwaitingLibrary.filter(waits)
        removedElsewhereAwaitingLibrary = removedElsewhereAwaitingLibrary.filter(waits)
        return trashedAwaitingLibrary != before.0 || removedElsewhereAwaitingLibrary != before.1
    }

    /// A clock that moved back behind the trash ends the wait too, so it cannot outlast `libraryLagLimit`.
    private static func awaitsLibrary(trashedAt: Date, now: Date) -> Bool {
        let waited = now.timeIntervalSince(trashedAt)
        return waited >= 0 && waited < libraryLagLimit
    }

    /// Called after each library refresh. Releases restored photos that the previous refresh already listed and
    /// marks the ones this refresh lists. Returns whether a photo was released.
    mutating func libraryRefreshed(lists isListed: (PhotoUID) -> Bool) -> Bool {
        let released = restoredHere.filter { restoredListedByLibrary.contains($0) }
        restoredHere.removeAll { restoredListedByLibrary.contains($0) }
        restoredListedByLibrary = Set(restoredHere.filter(isListed))
        return !released.isEmpty
    }
}
