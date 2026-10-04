import Foundation
import PhotosCore

/// The current inventory used by a crawl checkpoint. A provider lets the crawl notice items added after
/// the map opened without copying a fixed startup snapshot into a second store.
public struct LocationCrawlInventory: Sendable, Equatable {
    public let uids: [PhotoUID]
    public let captureDates: [PhotoUID: Date]

    public init(uids: [PhotoUID] = [], captureDates: [PhotoUID: Date] = [:]) {
        self.uids = uids
        self.captureDates = captureDates
    }

    /// Builds the one canonical newest-first crawl inventory used by every platform shell.
    public init(items: [PhotoItem]) {
        uids = items.reversed().map(\.uid)
        captureDates = Dictionary(
            items.map { ($0.uid, $0.captureTime) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// What one GPS probe of a photo's metadata yielded.
public enum LocationProbeResult: Equatable, Sendable {
    case found(latitude: Double, longitude: Double)
    case noLocation
    /// `category` must be non-sensitive (e.g. "http-429", "CancellationError") - it is logged.
    case failed(category: String)
}

/// Background crawl that builds the whole-library GPS index.
///
/// The crawl keeps its policy in Core: it skips persisted positive and negative results, refreshes the
/// inventory at encrypted checkpoints, persists deltas, and backs off for live foreground demand.
/// Platform adapters provide only the inventory, metadata probe, and lifecycle demand signal.
public actor LocationCrawl {
    private var task: Task<Void, Never>?
    private var taskToken: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var generation: UInt64 = 0
    private var accountUID: String?
    private let throttle: Duration
    private let backoff: Duration
    private let mergeEvery: Int
    private let saveEvery: Int
    private let logEvery: Int
    private let progressEvery: Int
    private let probeConcurrency: Int

    /// `probeConcurrency` probes run at once; each result is handled as soon as it arrives, one at a time.
    /// `progressEvery` publishes the scanned count, so a map that already shows places can show what is left.
    public init(
        throttle: Duration = .milliseconds(40),
        backoff: Duration = .milliseconds(500),
        mergeEvery: Int = 50,
        saveEvery: Int = 250,
        logEvery: Int = 500,
        progressEvery: Int = 20,
        probeConcurrency: Int = 1
    ) {
        self.throttle = throttle
        self.backoff = backoff
        self.mergeEvery = max(1, mergeEvery)
        self.saveEvery = max(1, saveEvery)
        self.logEvery = max(1, logEvery)
        self.progressEvery = max(1, progressEvery)
        self.probeConcurrency = max(1, probeConcurrency)
    }

    /// Crawl GPS for every UID not already indexed.
    ///
    /// `inventory` is sampled at startup and at save checkpoints. A UID is queued once per run, so a transient
    /// probe failure remains visible in progress and is retried by a later crawl rather than busy-looped.
    public func start(
        uids: [PhotoUID],
        captureDates: [PhotoUID: Date],
        accountUID: String = "",
        location: @escaping @Sendable (PhotoUID) async -> LocationProbeResult,
        index: PhotoLocationIndex,
        store: PhotoLocationStore,
        shouldYield: @escaping @Sendable () async -> Bool = { false },
        log: @escaping @Sendable (String) -> Void = { _ in },
        inventory: (@Sendable () async -> LocationCrawlInventory)? = nil
    ) async {
        lifecycleGeneration &+= 1
        let requestGeneration = lifecycleGeneration
        await retireCurrentTask()
        guard !Task.isCancelled, requestGeneration == lifecycleGeneration else { return }
        generation &+= 1
        let runGeneration = generation
        self.accountUID = accountUID
        let throttle = throttle
        let backoff = backoff
        let mergeEvery = mergeEvery
        let saveEvery = saveEvery
        let logEvery = logEvery
        let progressEvery = progressEvery
        let probeConcurrency = probeConcurrency
        let storeSessionLease = store.captureSessionLease()
        let isCurrent: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.isCurrent(generation: runGeneration, accountUID: accountUID)
        }
        taskToken &+= 1
        task = Task {
            func current() async -> Bool {
                guard !Task.isCancelled else { return false }
                return await isCurrent()
            }

            let alreadyIndexed = await index.indexedUIDs()
            guard await current() else { return }
            var queued = alreadyIndexed
            var pending: [PhotoUID] = []
            var dates = captureDates
            var inventoryCall = LocationCrawlInventory(uids: uids, captureDates: captureDates)
            if let inventory {
                let currentInventory = await inventory()
                inventoryCall = LocationCrawlInventory(
                    uids: uids + currentInventory.uids,
                    captureDates: currentInventory.captureDates
                )
                dates.merge(currentInventory.captureDates, uniquingKeysWith: { _, current in current })
            }
            for (offset, uid) in inventoryCall.uids.enumerated() {
                if offset.isMultiple(of: 256), !(await current()) { return }
                if queued.insert(uid).inserted { pending.append(uid) }
            }

            var progress = PhotoLocationScanProgress(
                phase: .scanning,
                scanned: 0,
                total: pending.count,
                found: await index.coordinates.count,
                noLocation: 0,
                failed: 0
            )
            guard await current() else { return }
            await index.updateScanProgress(progress)
            guard await current() else { return }
            log("[LocationCrawl] started candidates=\(pending.count) alreadyIndexed=\(alreadyIndexed.count)")

            var batch: [PhotoCoordinate] = []
            var pendingCoordinatesForPersistence: [PhotoCoordinate] = []
            var pendingNoLocationForPersistence = Set<PhotoUID>()
            var sinceSave = 0
            var sinceLog = 0
            var sinceProgress = 0
            var failureCategories: [String: Int] = [:]
            var loggedBackoff = false
            var nextIndex = 0

            func mergeNow() async -> Bool {
                guard await current() else { return false }
                let toMerge = batch
                batch.removeAll(keepingCapacity: true)
                guard await current() else { return false }
                pendingCoordinatesForPersistence.append(contentsOf: await index.merge(toMerge))
                guard await current() else { return false }
                progress.found = await index.coordinates.count
                await index.updateScanProgress(progress)
                return await current()
            }

            func refreshInventoryIfCurrent() async -> Bool {
                guard let inventory else { return await current() }
                guard await current() else { return false }
                let refreshed = await inventory()
                dates.merge(refreshed.captureDates, uniquingKeysWith: { _, current in current })
                for (offset, uid) in refreshed.uids.enumerated() {
                    if offset.isMultiple(of: 256), !(await current()) { return false }
                    if queued.insert(uid).inserted { pending.append(uid) }
                }
                progress.total = pending.count
                await index.updateScanProgress(progress)
                return await current()
            }

            func persistIfCurrent() async -> Bool {
                guard await current() else { return false }
                guard let storeSessionLease else { return true }
                let coordinates = pendingCoordinatesForPersistence
                let noLocationUIDs = pendingNoLocationForPersistence
                pendingCoordinatesForPersistence.removeAll(keepingCapacity: true)
                pendingNoLocationForPersistence.removeAll(keepingCapacity: true)
                guard !coordinates.isEmpty || !noLocationUIDs.isEmpty else { return true }
                let persisted = await index.persistDelta(
                    coordinates: coordinates,
                    noLocationUIDs: noLocationUIDs,
                    to: store,
                    sessionLease: storeSessionLease
                )
                if !persisted, await current() {
                    progress.phase = .failed
                    await index.updateScanProgress(progress)
                    log("[LocationCrawl] FAILED persistence scanned=\(progress.scanned)/\(progress.total)")
                }
                return persisted
            }

            /// Records one probe result. False ends the run.
            func handle(_ uid: PhotoUID, _ result: LocationProbeResult) async -> Bool {
                switch result {
                case .found(let latitude, let longitude):
                    batch.append(
                        PhotoCoordinate(
                            uid: uid,
                            latitude: latitude,
                            longitude: longitude,
                            date: dates[uid] ?? .distantPast
                        ))
                case .noLocation:
                    let accepted = await index.markNoLocation([uid])
                    pendingNoLocationForPersistence.formUnion(accepted)
                    progress.noLocation += 1
                case .failed(let category):
                    progress.failed += 1
                    if failureCategories[category] != nil || failureCategories.count < 4 {
                        failureCategories[category, default: 0] += 1
                    }
                }
                progress.scanned += 1
                sinceSave += 1
                sinceLog += 1
                sinceProgress += 1

                guard await current() else { return false }
                if batch.count >= mergeEvery, !(await mergeNow()) { return false }
                if sinceSave >= saveEvery {
                    sinceSave = 0
                    if !batch.isEmpty, !(await mergeNow()) { return false }
                    guard await persistIfCurrent() else { return false }
                    guard await refreshInventoryIfCurrent() else { return false }
                }
                if sinceProgress >= progressEvery {
                    sinceProgress = 0
                    guard await current() else { return false }
                    await index.updateScanProgress(progress)
                }
                if sinceLog >= logEvery {
                    sinceLog = 0
                    guard await current() else { return false }
                    await index.updateScanProgress(progress)
                    guard await current() else { return false }
                    log(
                        "[LocationCrawl] scanned=\(progress.scanned)/\(progress.total) found=\(progress.found + batch.count) noLocation=\(progress.noLocation) failed=\(progress.failed)"
                    )
                }
                return await current()
            }

            /// Probes the pending photos, at most `probeConcurrency` at once, and records each result as it
            /// arrives. While the crawl yields, no new probe starts; the running ones still finish. False ends the run.
            func drainPending() async -> Bool {
                await withTaskGroup(of: (PhotoUID, LocationProbeResult).self, returning: Bool.self) { group in
                    var inFlight = 0
                    while nextIndex < pending.count || inFlight > 0 {
                        guard await current() else {
                            group.cancelAll()
                            return false
                        }
                        if nextIndex < pending.count, inFlight < probeConcurrency {
                            if await shouldYield() {
                                if inFlight == 0 {
                                    if !loggedBackoff {
                                        loggedBackoff = true
                                        log(
                                            "[LocationCrawl] backing off (live demand) scanned=\(progress.scanned)/\(progress.total)"
                                        )
                                    }
                                    do {
                                        try await Task.sleep(for: backoff)
                                    } catch {
                                        return false
                                    }
                                    continue
                                }
                            } else {
                                if loggedBackoff {
                                    loggedBackoff = false
                                    log("[LocationCrawl] resumed scanned=\(progress.scanned)/\(progress.total)")
                                }
                                let uid = pending[nextIndex]
                                nextIndex += 1
                                group.addTask { (uid, await location(uid)) }
                                inFlight += 1
                                continue
                            }
                        }
                        guard let next = await group.next() else { break }
                        inFlight -= 1
                        guard await current(), await handle(next.0, next.1) else {
                            group.cancelAll()
                            return false
                        }
                        do {
                            try await Task.sleep(for: throttle)
                        } catch {
                            group.cancelAll()
                            return false
                        }
                    }
                    return true
                }
            }

            while true {
                guard await drainPending() else { return }

                guard await current() else { return }
                if !batch.isEmpty, !(await mergeNow()) { return }
                guard await persistIfCurrent() else { return }
                guard await refreshInventoryIfCurrent() else { return }
                if nextIndex < pending.count { continue }
                break
            }

            guard await current() else { return }
            progress.found = await index.coordinates.count
            let allFailed = progress.scanned > 0 && progress.failed == progress.scanned && progress.found == 0
            progress.phase = allFailed ? .failed : .completed
            guard await current() else { return }
            await index.updateScanProgress(progress)
            guard await current() else { return }
            let categories = failureCategories.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " ")
            log(
                "[LocationCrawl] \(allFailed ? "FAILED" : "completed") scanned=\(progress.scanned)/\(progress.total) found=\(progress.found) noLocation=\(progress.noLocation) failed=\(progress.failed)"
                    + (categories.isEmpty ? "" : " categories: \(categories)"))
        }
    }

    public func cancel() async {
        lifecycleGeneration &+= 1
        await retireCurrentTask()
    }

    private func isCurrent(generation: UInt64, accountUID: String) -> Bool {
        self.generation == generation && self.accountUID == accountUID
    }

    private func retireCurrentTask() async {
        generation &+= 1
        accountUID = nil
        let activeTask = task
        let activeTaskToken = taskToken
        activeTask?.cancel()
        await activeTask?.value
        if taskToken == activeTaskToken {
            task = nil
        }
    }
}

public extension LocationCrawl {
    /// The canonical GPS probe over a `PhotoMetadataProvider` backend.
    static func metadataProbe(
        _ metadata: any PhotoMetadataProvider
    ) -> @Sendable (PhotoUID) async -> LocationProbeResult {
        { uid in
            do {
                let m = try await metadata.metadata(for: uid)
                if m.hasLocation, let latitude = m.latitude, let longitude = m.longitude {
                    return .found(latitude: latitude, longitude: longitude)
                }
                return .noLocation
            } catch is CancellationError {
                return .failed(category: "cancelled")
            } catch {
                let ns = error as NSError
                return .failed(category: "\(ns.domain)#\(ns.code)")
            }
        }
    }
}
