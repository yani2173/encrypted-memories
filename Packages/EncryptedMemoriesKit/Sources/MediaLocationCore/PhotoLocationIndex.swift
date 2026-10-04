import Foundation
import Observation
import PhotosCore

/// The whole library's GPS coordinates, held in RAM for instant map queries.
///
/// Loaded once (decrypted) from `PhotoLocationStore` and then filled in live by `LocationCrawl`. Keeping
/// coordinates in memory makes region queries an in-memory filter without per-view decoding. Decrypted
/// coordinates exist only here in RAM; on disk they are always AES-GCM encrypted.
///
/// `@MainActor @Observable`: the map view binds to `revision`, so annotations refresh as the crawl adds
/// coordinates. Platform-agnostic (no AppKit) - reused as-is by a future iOS/iPad map UI.
@MainActor
@Observable
public final class PhotoLocationIndex {
    public private(set) var coordinates: [PhotoCoordinate] = []
    /// Bumped whenever `coordinates` changes. The map view observes this to re-derive annotations.
    public private(set) var revision = 0
    /// Live progress of the GPS crawl feeding this index. The map's empty state observes it to say
    /// "scanning…" honestly instead of a misleading "no places yet" while the scan hasn't finished.
    public private(set) var scanProgress = PhotoLocationScanProgress()
    @ObservationIgnored private var seen = Set<PhotoUID>()
    @ObservationIgnored private var noLocationUIDs = Set<PhotoUID>()
    @ObservationIgnored private var buckets: [PhotoLocationQuerySnapshot.BucketID: [PhotoCoordinate]] = [:]
    /// Once the library has reconciled its live identities, late results from an older crawl may only merge
    /// coordinates that still belong to that library. `nil` preserves startup loading before identities arrive.
    @ObservationIgnored private var allowedUIDs: Set<PhotoUID>?

    public init() {}

    /// Published by `LocationCrawl` (start / batch cadence / completion) - never per item.
    public func updateScanProgress(_ progress: PhotoLocationScanProgress) {
        scanProgress = progress
    }

    /// Replace the whole index - e.g. after decrypting the persisted snapshot at startup.
    public func replaceAll(_ coords: [PhotoCoordinate]) {
        replaceAll(PhotoLocationSnapshot(coordinates: coords))
    }

    /// Replace the whole index, including the persisted negative-result cache.
    public func replaceAll(_ snapshot: PhotoLocationSnapshot) {
        allowedUIDs = nil
        coordinates = snapshot.coordinates
        seen = Set(coordinates.map(\.uid))
        noLocationUIDs = snapshot.noLocationUIDs.subtracting(seen)
        seen.formUnion(noLocationUIDs)
        rebuildBuckets()
        revision += 1
    }

    /// Merge newly-crawled coordinates, deduped by uid. Bumps `revision` only if something was added,
    /// so an idle re-crawl that finds nothing new never churns the view.
    @discardableResult
    public func merge(_ coords: [PhotoCoordinate]) -> [PhotoCoordinate] {
        var accepted: [PhotoCoordinate] = []
        for c in coords
        where (allowedUIDs?.contains(c.uid) ?? true)
            && (!seen.contains(c.uid) || noLocationUIDs.contains(c.uid))
        {
            guard Self.isValid(c) else { continue }
            coordinates.append(c)
            seen.insert(c.uid)
            noLocationUIDs.remove(c.uid)
            buckets[PhotoLocationQuerySnapshot.bucketID(for: c), default: []].append(c)
            accepted.append(c)
        }
        if !accepted.isEmpty { revision += 1 }
        return accepted
    }

    /// Records metadata probes that found no GPS. A later coordinate for the same UID wins and removes the
    /// negative entry. The returned set is the exact delta that must be persisted by the crawl checkpoint.
    @discardableResult
    public func markNoLocation(_ uids: some Sequence<PhotoUID>) -> Set<PhotoUID> {
        var accepted = Set<PhotoUID>()
        for uid in uids
        where (allowedUIDs?.contains(uid) ?? true)
            && !seen.contains(uid)
        {
            noLocationUIDs.insert(uid)
            seen.insert(uid)
            accepted.insert(uid)
        }
        return accepted
    }

    /// Reconciles the index with the authoritative whole-library identities and persists the filtered encrypted
    /// snapshot off-main. The allow-list also blocks a late in-flight crawl result from resurrecting a deleted pin.
    public func retainOnly(
        _ uids: Set<PhotoUID>,
        persistTo store: PhotoLocationStore? = nil,
        sessionLease: PhotoLocationStore.SessionLease? = nil
    ) async {
        if let store, let sessionLease, !store.isCurrentSessionLease(sessionLease) {
            return
        }
        allowedUIDs = uids
        let retained = coordinates.filter { uids.contains($0.uid) }
        let retainedNegatives = noLocationUIDs.intersection(uids)
        if retained.count != coordinates.count || retainedNegatives != noLocationUIDs {
            coordinates = retained
            noLocationUIDs = retainedNegatives
            seen = Set(retained.map(\.uid))
            seen.formUnion(noLocationUIDs)
            rebuildBuckets()
            scanProgress.found = retained.count
            revision += 1
        }
        guard let store else { return }
        _ = await persist(to: store, sessionLease: sessionLease)
    }

    /// Captures the snapshot and its store write order without yielding the MainActor. This keeps crawl and
    /// reconciliation snapshots ordered by the index state they represent, not by disk completion order.
    @discardableResult
    func persist(
        to store: PhotoLocationStore,
        sessionLease: PhotoLocationStore.SessionLease? = nil
    ) async -> Bool {
        guard let sessionLease = sessionLease ?? store.captureSessionLease(),
            store.isCurrentSessionLease(sessionLease)
        else { return false }
        let snapshot = PhotoLocationSnapshot(coordinates: coordinates, noLocationUIDs: noLocationUIDs)
        guard let writeLease = store.captureWriteLease(ifCurrent: sessionLease) else { return false }
        let saved = await Task.detached(priority: .utility) {
            store.save(snapshot, with: writeLease)
        }.value
        return saved && store.isCurrentSessionLease(sessionLease)
    }

    /// The uids already indexed - used by the crawl to skip work it has already done (resumable).
    public func indexedUIDs() -> Set<PhotoUID> { seen }

    /// True only when the encrypted in-memory index already holds a valid GPS coordinate for this photo.
    /// Unknown and authoritatively location-less photos both return false.
    public func hasKnownLocation(_ uid: PhotoUID) -> Bool {
        seen.contains(uid) && !noLocationUIDs.contains(uid)
    }

    /// The exact persisted snapshot, captured on the owning actor before a detached disk write.
    public func snapshot() -> PhotoLocationSnapshot {
        PhotoLocationSnapshot(coordinates: coordinates, noLocationUIDs: noLocationUIDs)
    }

    /// Persists only newly accepted probe results. The full snapshot is used only when the encrypted journal
    /// reaches its bounded compaction threshold.
    @discardableResult
    func persistDelta(
        coordinates newCoordinates: [PhotoCoordinate],
        noLocationUIDs newNoLocationUIDs: Set<PhotoUID>,
        to store: PhotoLocationStore,
        sessionLease: PhotoLocationStore.SessionLease? = nil
    ) async -> Bool {
        guard let sessionLease = sessionLease ?? store.captureSessionLease(),
            store.isCurrentSessionLease(sessionLease)
        else { return false }
        let snapshot = PhotoLocationSnapshot(coordinates: coordinates, noLocationUIDs: noLocationUIDs)
        let delta = PhotoLocationDelta(
            coordinates: newCoordinates,
            noLocationUIDs: newNoLocationUIDs
        )
        guard let writeLease = store.captureWriteLease(ifCurrent: sessionLease) else { return false }
        let appended = await Task.detached(priority: .utility) {
            store.append(delta, compactionSnapshot: snapshot, with: writeLease)
        }.value
        if appended { return store.isCurrentSessionLease(sessionLease) }

        // A transient append failure must not lose an in-memory coordinate forever. Retry once with the complete
        // encrypted snapshot under a newer write lease; a later crawl would otherwise skip the already-seen UID.
        guard store.isCurrentSessionLease(sessionLease),
            let recoveryLease = store.captureWriteLease(ifCurrent: sessionLease)
        else { return false }
        let recovered = await Task.detached(priority: .utility) {
            store.save(snapshot, with: recoveryLease)
        }.value
        return recovered && store.isCurrentSessionLease(sessionLease)
    }

    /// Coordinates whose point falls inside the bounding box (the visible map rect + margin).
    public func coordinates(in box: GeoBoundingBox) -> [PhotoCoordinate] {
        querySnapshot().coordinates(in: box)
    }

    private func rebuildBuckets() {
        buckets.removeAll(keepingCapacity: true)
        buckets.reserveCapacity(min(coordinates.count, 512))
        for coordinate in coordinates {
            guard Self.isValid(coordinate) else { continue }
            buckets[PhotoLocationQuerySnapshot.bucketID(for: coordinate), default: []].append(coordinate)
        }
    }

    private static func isValid(_ coordinate: PhotoCoordinate) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

/// Immutable, bucketed coordinates for detached map queries. A map plan visits only intersecting one-degree
/// buckets, then applies the exact bounding-box predicate. The map never scans the whole library per plan.
public struct PhotoLocationQuerySnapshot: Sendable {
    struct BucketID: Hashable, Sendable {
        let latitude: Int
        let longitude: Int
    }

    private let buckets: [BucketID: [PhotoCoordinate]]

    fileprivate init(buckets: [BucketID: [PhotoCoordinate]]) {
        self.buckets = buckets
    }

    public func coordinates(in box: GeoBoundingBox) -> [PhotoCoordinate] {
        guard box.minLatitude.isFinite, box.maxLatitude.isFinite,
            box.minLongitude.isFinite, box.maxLongitude.isFinite,
            box.minLatitude <= box.maxLatitude
        else { return [] }
        let minLatitude = max(-90, box.minLatitude)
        let maxLatitude = min(90, box.maxLatitude)
        guard minLatitude <= maxLatitude else { return [] }
        let latitudeRange = Self.bucketRange(
            lower: minLatitude,
            upper: maxLatitude,
            minimum: -90,
            maximum: 89
        )
        let longitudeRanges: [(Int, Int)]
        if box.minLongitude <= box.maxLongitude {
            longitudeRanges = [
                Self.longitudeBucketRange(
                    lower: max(-180, box.minLongitude), upper: min(180, box.maxLongitude)
                )
            ]
        } else {
            longitudeRanges = [
                Self.longitudeBucketRange(lower: max(-180, box.minLongitude), upper: 180),
                Self.longitudeBucketRange(lower: -180, upper: min(180, box.maxLongitude)),
            ]
        }

        var result: [PhotoCoordinate] = []
        for latitudeBucket in latitudeRange.0...latitudeRange.1 {
            for (lowerLongitude, upperLongitude) in longitudeRanges {
                guard lowerLongitude <= upperLongitude else { continue }
                for longitudeBucket in lowerLongitude...upperLongitude {
                    for coordinate in buckets[BucketID(latitude: latitudeBucket, longitude: longitudeBucket)] ?? []
                    where box.contains(latitude: coordinate.latitude, longitude: coordinate.longitude) {
                        result.append(coordinate)
                    }
                }
            }
        }
        return result
    }

    fileprivate static func bucketID(for coordinate: PhotoCoordinate) -> BucketID {
        let latitude = min(89, max(-90, Int(floor(coordinate.latitude))))
        let longitude =
            coordinate.longitude == 180
            ? 359
            : min(359, max(0, Int(floor(normalizedLongitude(coordinate.longitude) + 180))))
        return BucketID(latitude: latitude, longitude: longitude)
    }

    private static func bucketRange(lower: Double, upper: Double, minimum: Int, maximum: Int) -> (Int, Int) {
        let lowerBucket = min(maximum, max(minimum, Int(floor(lower))))
        let upperBucket = min(
            maximum, max(minimum, Int(floor(upper == Double(maximum + 1) ? upper - 0.000_000_1 : upper))))
        return (lowerBucket, upperBucket)
    }

    private static func longitudeBucketRange(lower: Double, upper: Double) -> (Int, Int) {
        let shiftedLower = min(180, max(-180, lower)) + 180
        let shiftedUpper = min(180, max(-180, upper)) + 180
        return bucketRange(
            lower: shiftedLower,
            upper: shiftedUpper,
            minimum: 0,
            maximum: 359
        )
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (shifted >= 0 ? shifted : shifted + 360) - 180
    }
}

public extension PhotoLocationIndex {
    /// Captures the bucket index for detached map aggregation.
    func querySnapshot() -> PhotoLocationQuerySnapshot {
        PhotoLocationQuerySnapshot(buckets: buckets)
    }
}

/// Where the GPS crawl currently stands, for honest map empty states and diagnostics.
public struct PhotoLocationScanProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No crawl has run this session (library still loading, or Map never opened).
        case idle
        /// Crawl running - the map should say "scanning", not "no places".
        case scanning
        /// Crawl finished this session. Zero `found` now honestly means "no geotagged photos".
        case completed
        /// Crawl finished but every probe failed (metadata unreachable) - a real failure, not "no GPS".
        case failed
    }

    public var phase: Phase
    /// Photos probed so far in this run (excludes ones already indexed from the persisted snapshot).
    public var scanned: Int
    /// Total candidates for this run.
    public var total: Int
    /// Coordinates in the index overall (persisted snapshot + this run).
    public var found: Int
    /// Probes that returned metadata without GPS.
    public var noLocation: Int
    /// Probes that failed outright (network/decode/decrypt).
    public var failed: Int

    public init(
        phase: Phase = .idle, scanned: Int = 0, total: Int = 0,
        found: Int = 0, noLocation: Int = 0, failed: Int = 0
    ) {
        self.phase = phase
        self.scanned = scanned
        self.total = total
        self.found = found
        self.noLocation = noLocation
        self.failed = failed
    }

    /// While a scan runs, the share of this run's photos already checked. A map that already shows places uses it
    /// to say how much is left. Nil when no scan runs or before it knows its photos.
    public var fractionScanned: Double? {
        guard phase == .scanning, total > 0 else { return nil }
        return min(1, max(0, Double(scanned) / Double(total)))
    }
}
