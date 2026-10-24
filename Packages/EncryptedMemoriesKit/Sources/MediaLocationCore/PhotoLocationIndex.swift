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
public final class PhotoLocationIndex: PhotoPlaceSupportSource {
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
    @ObservationIgnored private var allowed: AllowList?

    /// The photos that may store results after a clean-up: the library of that clean-up and, on top of it, the
    /// library that the latest scan runs for.
    private struct AllowList {
        var retained: Set<PhotoUID>
        /// The inventory revision at which the clean-up read its library. A list that was read at this revision or
        /// earlier is older than the clean-up and never widens the index again.
        let narrowedAfter: UInt64
        /// The inventory of the latest scan. It is kept by reference, so a scan start makes no pass over the library.
        var scanned: [PhotoUID: Date] = [:]
        var scannedRevision: UInt64 = 0

        func contains(_ uid: PhotoUID) -> Bool { retained.contains(uid) || scanned[uid] != nil }
    }

    @ObservationIgnored public private(set) var coordinateGeneration = 0
    /// Changes when a classified snapshot becomes available, even without another crawl batch.
    public private(set) var placeRevision = 0
    @ObservationIgnored private var placeEvidenceTime: TimeInterval?
    @ObservationIgnored private var placeEvidenceCount = 0
    @ObservationIgnored private var cachedPlaceSnapshot: PlaceSnapshot?
    @ObservationIgnored private var pendingPlaceSnapshot: PlaceSnapshot?
    @ObservationIgnored private var placeEvidenceWarmTask: Task<Void, Never>?
    @ObservationIgnored private var placeRefreshTask: Task<Void, Never>?

    private final class PlaceSnapshot: Sendable {
        let query: PhotoLocationQuerySnapshot
        init(_ query: PhotoLocationQuerySnapshot) { self.query = query }
    }

    #if DEBUG
        public var nowForTesting: (() -> TimeInterval)?
        public var beforePlaceAnalysisForTesting: (@Sendable () -> Void)?
        public var beforePlaceAnalysisAsyncForTesting: (@Sendable () async -> Void)?
        public func waitForPlaceEvidenceForTesting() async { await placeEvidenceWarmTask?.value }
        /// A test raises the priority of the warming task: a background task starves while many builds run.
        public var warmingPriorityForTesting: TaskPriority = .background
    #endif

    private var warmingPriority: TaskPriority {
        #if DEBUG
            warmingPriorityForTesting
        #else
            .background
        #endif
    }

    public init(supportSources: SupportDiagnosticsSources = .shared) {
        supportSources.registerPlaces(self)
    }

    deinit {
        placeEvidenceWarmTask?.cancel()
        placeRefreshTask?.cancel()
    }

    private var now: TimeInterval {
        #if DEBUG
            if let nowForTesting { return nowForTesting() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    private func invalidatePlaceEvidence() {
        placeEvidenceWarmTask?.cancel()
        placeEvidenceWarmTask = nil
        placeRefreshTask?.cancel()
        placeRefreshTask = nil
        pendingPlaceSnapshot = nil
        cachedPlaceSnapshot = nil
    }

    private func resetPlaceEvidenceAdmission() {
        coordinateGeneration &+= 1
        placeEvidenceTime = nil
        placeEvidenceCount = 0
    }

    /// All consumers use the same admission. A nil delay means that growth is insufficient.
    private func placeEvidenceRefreshDelay(at time: TimeInterval) -> TimeInterval? {
        guard scanProgress.phase == .scanning, let placeEvidenceTime else { return 0 }
        guard coordinates.count >= placeEvidenceCount + max(1, (placeEvidenceCount + 9) / 10) else { return nil }
        return max(0, 10 - (time - placeEvidenceTime))
    }

    private func placeSnapshot() -> PlaceSnapshot {
        if let pendingPlaceSnapshot, pendingPlaceSnapshot.query.revision == revision {
            return cachedPlaceSnapshot ?? pendingPlaceSnapshot
        }
        if let cachedPlaceSnapshot, cachedPlaceSnapshot.query.revision == revision { return cachedPlaceSnapshot }
        let time = now
        if let cachedPlaceSnapshot, placeEvidenceRefreshDelay(at: time) != 0 {
            if placeRefreshTask == nil, let delay = placeEvidenceRefreshDelay(at: time), delay > 0 {
                // The timer holds no coordinate, bucket, or evidence snapshot.
                placeRefreshTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self else { return }
                    self.placeRefreshTask = nil
                    _ = self.placeSnapshot()
                }
            }
            return cachedPlaceSnapshot
        }
        placeRefreshTask?.cancel()
        placeRefreshTask = nil
        placeEvidenceWarmTask?.cancel()
        let evidence = PhotoPlaceEvidence(coordinates: coordinates)
        #if DEBUG
            if let beforePlaceAnalysisForTesting { evidence.setBeforeAnalysisForTesting(beforePlaceAnalysisForTesting) }
        #endif
        let snapshot = PlaceSnapshot(
            PhotoLocationQuerySnapshot(
                buckets: buckets, evidence: evidence, revision: revision, generation: coordinateGeneration))
        pendingPlaceSnapshot = snapshot
        // The first opening can wait for its initial snapshot. Later consumers retain the classified snapshot.
        if cachedPlaceSnapshot == nil { cachedPlaceSnapshot = snapshot }
        placeEvidenceTime = time
        placeEvidenceCount = coordinates.count
        let priority = warmingPriority
        #if DEBUG
            let beforeAnalysis = beforePlaceAnalysisAsyncForTesting
        #endif
        let task = Task(priority: priority) { @MainActor [weak self, weak snapshot] in
            guard let snapshot, !Task.isCancelled else { return }
            let worker = Task.detached(priority: priority) {
                #if DEBUG
                    if let beforeAnalysis { await beforeAnalysis() }
                #endif
                snapshot.query.evidence.prewarm()
            }
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.publishPlaceSnapshot(snapshot)
        }
        evidence.registerWarmingTask(task)
        placeEvidenceWarmTask = task
        return cachedPlaceSnapshot ?? snapshot
    }

    private func publishPlaceSnapshot(_ snapshot: PlaceSnapshot) {
        guard pendingPlaceSnapshot === snapshot, snapshot.query.generation == coordinateGeneration else { return }
        cachedPlaceSnapshot = snapshot
        pendingPlaceSnapshot = nil
        placeRevision &+= 1
    }

    /// Creation is constant-time. The snapshot shares existing storage and one independent background analysis.
    public func placeEvidence() -> PhotoPlaceEvidence { placeSnapshot().query.evidence }

    private func warmPlaceEvidence() { _ = placeSnapshot() }

    public func photoPlaceSupportSnapshot() async -> [PlaceCandidateSupportSnapshot] {
        let evidence = placeEvidence()
        guard await evidence.waitForWarming() else { return [] }
        return await Task.detached(priority: .utility) { evidence.supportSnapshot() }.value
    }

    /// Published by `LocationCrawl` (start / batch cadence / completion) - never per item.
    public func updateScanProgress(_ progress: PhotoLocationScanProgress) {
        if progress.phase == .scanning, scanProgress.phase != .scanning, let cachedPlaceSnapshot {
            placeEvidenceTime = now
            placeEvidenceCount = cachedPlaceSnapshot.query.evidence.coordinates.count
        }
        scanProgress = progress
        // Completion bypasses crawl admission and publishes the final shared snapshot.
        if progress.phase == .completed { warmPlaceEvidence() }
    }

    /// Replace the whole index - e.g. after decrypting the persisted snapshot at startup.
    public func replaceAll(_ coords: [PhotoCoordinate]) {
        replaceAll(PhotoLocationSnapshot(coordinates: coords))
    }

    /// Replace the whole index, including the persisted negative-result cache.
    public func replaceAll(_ snapshot: PhotoLocationSnapshot) {
        invalidatePlaceEvidence()
        resetPlaceEvidenceAdmission()
        allowed = nil
        coordinates = snapshot.coordinates
        seen = Set(coordinates.map(\.uid))
        noLocationUIDs = snapshot.noLocationUIDs.subtracting(seen)
        seen.formUnion(noLocationUIDs)
        rebuildBuckets()
        revision += 1
        warmPlaceEvidence()
    }

    /// Merge newly-crawled coordinates, deduped by uid. Bumps `revision` only if something was added,
    /// so an idle re-crawl that finds nothing new never churns the view.
    @discardableResult
    public func merge(_ coords: [PhotoCoordinate]) -> [PhotoCoordinate] {
        var accepted: [PhotoCoordinate] = []
        for c in coords
        where (allowed?.contains(c.uid) ?? true)
            && (!seen.contains(c.uid) || noLocationUIDs.contains(c.uid))
        {
            guard Self.isValid(c) else { continue }
            // Outside a crawl, release unobserved storage before append. A crawl retains its classified snapshot.
            if accepted.isEmpty, scanProgress.phase != .scanning { invalidatePlaceEvidence() }
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
        where (allowed?.contains(uid) ?? true)
            && !seen.contains(uid)
        {
            noLocationUIDs.insert(uid)
            seen.insert(uid)
            accepted.insert(uid)
        }
        return accepted
    }

    /// Lets a scan of a known library store results for every photo of that library, also for photos that a clean-up
    /// excluded. Only `retainOnly` narrows what the index accepts; without a clean-up every photo is accepted already.
    /// `revision` is the inventory revision at which the library was read. A library that is not newer than the last
    /// clean-up, or older than the library of an earlier accept, is ignored: a late list never undoes a clean-up or a
    /// newer list. The library of the latest scan replaces the one of an earlier scan, so a photo that a newer library
    /// lacks is not accepted any more. The call keeps the inventory by reference and makes no pass over it.
    public func accept(_ inventory: LocationCrawlInventory, revision: UInt64) {
        guard let list = allowed, revision > list.narrowedAfter, revision >= list.scannedRevision else { return }
        allowed?.scanned = inventory.captureDates
        allowed?.scannedRevision = revision
    }

    /// Reconciles the index with the authoritative whole-library identities and persists the filtered encrypted
    /// snapshot off-main. The allow-list also blocks a late in-flight crawl result from resurrecting a deleted pin.
    public func retainOnly(
        _ uids: Set<PhotoUID>,
        persistTo store: PhotoLocationStore? = nil,
        sessionLease: PhotoLocationStore.SessionLease? = nil,
        afterInventoryRevision inventoryRevision: UInt64 = 0
    ) async {
        if let store, let sessionLease, !store.isCurrentSessionLease(sessionLease) {
            return
        }
        allowed = AllowList(retained: uids, narrowedAfter: inventoryRevision)
        let retained = coordinates.filter { uids.contains($0.uid) }
        let retainedNegatives = noLocationUIDs.intersection(uids)
        if retained.count != coordinates.count || retainedNegatives != noLocationUIDs {
            coordinates = retained
            noLocationUIDs = retainedNegatives
            seen = Set(retained.map(\.uid))
            seen.formUnion(noLocationUIDs)
            rebuildBuckets()
            scanProgress.found = retained.count
            invalidatePlaceEvidence()
            resetPlaceEvidenceAdmission()
            revision += 1
            warmPlaceEvidence()
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
    public let evidence: PhotoPlaceEvidence
    public let revision: Int
    public let generation: Int

    fileprivate init(
        buckets: [BucketID: [PhotoCoordinate]], evidence: PhotoPlaceEvidence, revision: Int, generation: Int
    ) {
        self.buckets = buckets
        self.evidence = evidence
        self.revision = revision
        self.generation = generation
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

        let excluded = evidence.excludedPositions()
        guard !Task.isCancelled, !evidence.warmingIsRetired else { return [] }
        var result: [PhotoCoordinate] = []
        for latitudeBucket in latitudeRange.0...latitudeRange.1 {
            for (lowerLongitude, upperLongitude) in longitudeRanges {
                guard lowerLongitude <= upperLongitude else { continue }
                for longitudeBucket in lowerLongitude...upperLongitude {
                    for coordinate in buckets[BucketID(latitude: latitudeBucket, longitude: longitudeBucket)] ?? []
                    where box.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        && !excluded.contains(PhotoExactPosition(coordinate))
                    {
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
        placeSnapshot().query
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
