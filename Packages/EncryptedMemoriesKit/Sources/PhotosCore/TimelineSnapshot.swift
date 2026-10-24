import Foundation

/// Immutable, flattened, and ordered timeline data with a uid-to-index map built in the same pass.
///
/// The first occurrence of each uid wins. An O(n) scan detects an ordering inversion, and sorting runs only
/// when the retained items are not already in canonical order. Lookups use the prebuilt index.
///
/// Ordering follows `TimelineOrder`: capture time, optional subsecond evidence, then stable identity and link ID.
public struct TimelineSnapshot: Sendable {
    /// The flattened, uid-unique items in timeline order.
    public let items: [PhotoItem]
    /// Maps each uid to its position in `items`.
    private let indexByUID: [PhotoUID: Int]

    /// The empty snapshot (no items) - the initial state before any timeline has loaded.
    public init() {
        self.init(items: [], indexByUID: [:])
    }

    /// Flatten, deduplicate and canonically order `sections`. The common already-ordered path builds the
    /// result and index in one O(n) pass; an inversion falls back to one sort. Pure and safe to run off-main.
    /// The first occurrence of a uid in the incoming section/item order is authoritative.
    public init(sections: [TimelineSection]) {
        let count = sections.reduce(into: 0) { $0 += $1.items.count }
        let result = try! Self.canonicalized(
            sections.lazy.flatMap { $0.items },
            estimatedCount: count,
            checkCancellation: false
        )
        self.init(items: result.items, indexByUID: result.indexByUID)
    }

    /// Canonicalizes sections while allowing an off-actor caller to observe cancellation during the scan.
    /// The result and uid index are built together, so callers do not pay a second flattening pass.
    package init(canonicalizing sections: [TimelineSection], checkCancellation: Bool) throws {
        let count = sections.reduce(into: 0) { $0 += $1.items.count }
        let result = try Self.canonicalized(
            sections.lazy.flatMap { $0.items },
            estimatedCount: count,
            checkCancellation: checkCancellation
        )
        self.init(items: result.items, indexByUID: result.indexByUID)
    }

    /// Build directly from items expected to be in `TimelineOrder` (used by `removingItems` and tests).
    /// Duplicate uids are still removed with the same first-occurrence rule as `init(sections:)`; an accidental
    /// inversion is normalized defensively so every initializer preserves the public snapshot invariant.
    public init(orderedItems: [PhotoItem]) {
        let result = try! Self.canonicalized(
            orderedItems,
            estimatedCount: orderedItems.count,
            checkCancellation: false
        )
        self.init(items: result.items, indexByUID: result.indexByUID)
    }

    /// Builds a presentation snapshot whose order the caller owns. The pending grid keeps a photo in the
    /// position of its local tile after upload, which can differ from `TimelineOrder` within one second, so
    /// this initializer never re-sorts. Duplicate uids keep their first occurrence.
    public init(trustingOrderOf items: [PhotoItem]) {
        var unique: [PhotoItem] = []
        unique.reserveCapacity(items.count)
        var map = [PhotoUID: Int](minimumCapacity: items.count)
        for item in items where map[item.uid] == nil {
            map[item.uid] = unique.count
            unique.append(item)
        }
        self.init(items: unique, indexByUID: map)
    }

    private init(items: [PhotoItem], indexByUID: [PhotoUID: Int]) {
        self.items = items
        self.indexByUID = indexByUID
    }

    private static func canonicalized<Source: Sequence>(
        _ source: Source,
        estimatedCount: Int,
        checkCancellation: Bool
    ) throws -> (items: [PhotoItem], indexByUID: [PhotoUID: Int])
    where Source.Element == PhotoItem {
        var normalized: [PhotoItem] = []
        normalized.reserveCapacity(estimatedCount)
        var map = [PhotoUID: Int](minimumCapacity: estimatedCount)
        var containsInversion = false

        var sourceIndex = 0
        for item in source {
            if checkCancellation && sourceIndex.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            sourceIndex += 1
            guard map[item.uid] == nil else { continue }
            if let previous = normalized.last,
                TimelineOrder.areInIncreasingOrder(item, previous)
            {
                containsInversion = true
            }
            map[item.uid] = normalized.count
            normalized.append(item)
        }

        if containsInversion {
            normalized.sort(by: TimelineOrder.areInIncreasingOrder)
            map.removeAll(keepingCapacity: true)
            for (position, item) in normalized.enumerated() {
                map[item.uid] = position
            }
        }

        if checkCancellation { try Task.checkCancellation() }
        return (normalized, map)
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Position of `uid` in `items`, or nil. O(1).
    public func index(of uid: PhotoUID) -> Int? { indexByUID[uid] }

    /// The item for `uid`, or nil. O(1).
    public func item(for uid: PhotoUID) -> PhotoItem? { indexByUID[uid].map { items[$0] } }

    /// The items whose uid is in `uids`, in timeline order - for share/export of a selection. O(k log k) in
    /// the selection size, never an O(n) scan of the whole library.
    public func items(withUIDs uids: Set<PhotoUID>) -> [PhotoItem] {
        uids.compactMap { indexByUID[$0] }.sorted().map { items[$0] }
    }

    /// Every requested identity, with known items in timeline order and any identity from a concurrently
    /// replaced projection retained at the end in stable ID order. Destructive/export actions intentionally
    /// use `items(withUIDs:)` because they require current models; ID-only server actions must not silently
    /// drop a user's selection merely because the authoritative snapshot changed while a sheet opened.
    public func orderedUIDs(including uids: Set<PhotoUID>) -> [PhotoUID] {
        let knownPositions = uids.compactMap { uid in indexByUID[uid].map { ($0, uid) } }.sorted { $0.0 < $1.0 }
        let known = knownPositions.map(\.1)
        let knownSet = Set(known)
        let missing = uids.subtracting(knownSet).sorted {
            $0.volumeID == $1.volumeID ? $0.nodeID < $1.nodeID : $0.volumeID < $1.volumeID
        }
        return known + missing
    }

    /// A new snapshot without `uids` (trash), preserving order and rebuilding the index. Returns `self`
    /// unchanged when nothing is removed.
    public func removingItems(withUIDs uids: Set<PhotoUID>) -> TimelineSnapshot {
        guard !uids.isEmpty else { return self }
        return TimelineSnapshot(orderedItems: items.filter { !uids.contains($0.uid) })
    }
}

extension TimelineSnapshot: Equatable {
    /// Equal when the ordered items match - the index is a pure function of them, so it is not compared
    /// (avoids walking a large dictionary).
    public static func == (lhs: TimelineSnapshot, rhs: TimelineSnapshot) -> Bool {
        lhs.items == rhs.items
    }
}
