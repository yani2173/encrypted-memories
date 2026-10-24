import Foundation
import PhotosCore

/// One account's GPS crawl session for the Map, shared by iOS, iPadOS and macOS. It owns the start generation, the
/// delayed start, the privacy stop, and the crawl inventory. Pause, resume and restart go through it; the hosts keep
/// the map prewarmer, the account checks and the teardown order.
@MainActor
public final class LocationCrawlSession {
    /// What differs between the platforms.
    public struct Platform: Sendable, Equatable {
        /// How long the thumbnail crawl runs alone before GPS probing starts.
        public var headStart: Duration
        /// Stops an earlier crawl and requires a current store session before the delayed start. Without it, the
        /// earlier crawl runs until `LocationCrawl.start` retires it, or until the account configuration or a pause
        /// stops it.
        public var requiresStoreSession: Bool

        public init(headStart: Duration, requiresStoreSession: Bool) {
            self.headStart = headStart
            self.requiresStoreSession = requiresStoreSession
        }
    }

    /// What one start needs from the host.
    public struct Start {
        public var accountUID: String
        public var location: @Sendable (PhotoUID) async -> LocationProbeResult
        /// Whether the grid shows thumbnails that it still waits for.
        public var visibleDemand: @Sendable () async -> Bool
        /// Pauses the crawl regardless of visible demand, for example while the app is inactive.
        public var yieldsAlways: @Sendable () async -> Bool
        public var log: @Sendable (String) -> Void
        /// The host's own account check, made at every step together with the generation.
        public var isCurrent: @MainActor () -> Bool
        /// Host work that must end before the crawl starts, for example the account configuration.
        public var awaiting: Task<Void, Never>?
        /// Starts the crawl again through the host when the inventory changed after the crawl last read it. Nil
        /// leaves a finished crawl until the next start.
        public var restartForNewerInventory: (@MainActor () -> Void)?

        public init(
            accountUID: String,
            location: @escaping @Sendable (PhotoUID) async -> LocationProbeResult,
            visibleDemand: @escaping @Sendable () async -> Bool,
            yieldsAlways: @escaping @Sendable () async -> Bool = { false },
            log: @escaping @Sendable (String) -> Void = { _ in },
            isCurrent: @escaping @MainActor () -> Bool,
            awaiting: Task<Void, Never>? = nil,
            restartForNewerInventory: (@MainActor () -> Void)? = nil
        ) {
            self.accountUID = accountUID
            self.location = location
            self.visibleDemand = visibleDemand
            self.yieldsAlways = yieldsAlways
            self.log = log
            self.isCurrent = isCurrent
            self.awaiting = awaiting
            self.restartForNewerInventory = restartForNewerInventory
        }
    }

    public let crawl: LocationCrawl
    public let index: PhotoLocationIndex
    public let store: PhotoLocationStore
    /// True from a start until `pause`, `prepareRestart`, `invalidate`, `retire`, `resetForTeardown`, or a restart
    /// for a newer inventory.
    public private(set) var isStarted = false
    private let platform: Platform
    private let isEnabled: @MainActor () -> Bool
    private var generation: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var privacyStopTask: Task<Void, Never>?
    private var inventoryTask: Task<LocationCrawlInventory, Never>?
    private var inventoryRevision: UInt64 = 0
    private var crawlInventoryRevision: UInt64 = 0
    private struct PendingReconciliation {
        let revision: UInt64
        let generation: UInt64
        let accountUID: String
        let recrawlRestoredItems: Bool
    }

    /// The account configuration that publications and reconciliations belong to. `invalidate`, `retire` and
    /// `resetForTeardown` move it, so work that started for an earlier configuration cannot touch the current one.
    public struct OwnerLease: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var reconciliationGeneration: UInt64 = 0
    private var reconciliationRevision: UInt64 = 0
    private var reconciliationAttempt: UInt64 = 0
    private var pendingReconciliation: PendingReconciliation?
    /// A publication of a known library still has to start the scan. A reconciliation that takes over its
    /// pending work starts the scan instead, also when that reconciliation stops; a publication that stops leaves
    /// the start to the next reconciliation or publication.
    private var publicationStartOwed = false

    /// How one attempt to consume the waiting reconciliation ended.
    private enum ReconcileOutcome {
        /// The pins were reconciled; `restarting` says whether an active scan must restart for a restore.
        case completed(restarting: Bool)
        /// A newer attempt, a newer request or another configuration took over the waiting work.
        case superseded
        /// The attempt is still the latest one but stopped: a cancellation, the host check or the store session.
        /// The waiting work stays for the next publication.
        case stopped
    }
    /// How often an admitted start reached the crawl. A rejected start never touches it: `crawl.start` retires the
    /// crawl that runs, so a stale start must stop before it.
    private(set) var crawlStartsForTesting = 0

    #if DEBUG
        public var beforeWholeLibraryUIDProjectionForTesting: (@Sendable () async -> Void)? = nil
        /// Runs after a read of the inventory returned and before its revision is compared with the newest one.
        var afterInventoryReadForTesting: (@MainActor () async -> Void)?
    #endif

    public init(
        platform: Platform,
        index: PhotoLocationIndex = PhotoLocationIndex(),
        store: PhotoLocationStore = PhotoLocationStore(),
        crawl: LocationCrawl = LocationCrawl(),
        isEnabled: @escaping @MainActor () -> Bool = { MapAndPlacesPolicy.isEnabled() }
    ) {
        self.platform = platform
        self.index = index
        self.store = store
        self.crawl = crawl
        self.isEnabled = isEnabled
    }

    /// The task that started the crawl last, for hosts that join it.
    public var startingTask: Task<Void, Never>? { startTask }

    /// The task that stops the crawl last (`pause()` or an empty library), for hosts that join it.
    public var stoppingTask: Task<Void, Never>? { privacyStopTask }

    /// Builds the crawl inventory of `items` off the main actor. A running crawl reads it at its next checkpoint.
    public func updateInventory(_ items: [PhotoItem]) {
        inventoryTask?.cancel()
        inventoryTask = Task.detached(priority: .utility) { LocationCrawlInventory(items: items) }
        inventoryRevision &+= 1
    }

    /// The crawl ended (completed or failed) before it read the latest inventory.
    public var finishedWithOutdatedInventory: Bool {
        isStarted && crawlInventoryRevision != inventoryRevision
            && (index.scanProgress.phase == .completed || index.scanProgress.phase == .failed)
    }

    public func startWholeLibrary(
        items: [PhotoItem]?,
        restarting: Bool = false,
        makeStart: @MainActor () -> Start
    ) {
        guard let items else { return }
        // A known empty library has nothing to scan. The same stop as for Map and Places off ends a waiting start
        // and the running crawl of the older library; the waiting clean-up stays. A scan that this stop cut short
        // no longer shows as scanning.
        guard !items.isEmpty else { return stopCrawl(settlingCutShortScan: true) }
        if restarting { prepareRestart() }
        guard MapAndPlacesPolicy.allowsLocationCrawl(enabled: isEnabled(), itemCount: items.count) else { return }
        updateInventory(items)
        if finishedWithOutdatedInventory { prepareRestart() }
        // A crawl that runs reads the new list at its next checkpoint; the index must accept its photos by then.
        if isStarted { acceptPublishedInventory() }
        start(items: items, makeStart(), acceptingInventory: true)
    }

    /// Lets the index accept the library that was just published once its inventory is built off the main actor. The
    /// revision keeps a late result from replacing a newer one or from undoing a clean-up.
    private func acceptPublishedInventory() {
        guard let task = inventoryTask else { return }
        let revision = inventoryRevision
        Task { [weak self] in
            let inventory = await task.value
            self?.index.accept(inventory, revision: revision)
        }
    }

    /// The owner that a publication or reconciliation captures when its work starts, before any suspension.
    public func captureOwnerLease() -> OwnerLease { OwnerLease(generation: reconciliationGeneration) }

    /// Publishes a complete inventory, including empty, before deciding whether to start GPS work.
    public func publishWholeLibrary(
        items: [PhotoItem]?,
        owner: OwnerLease,
        isCurrent: @MainActor () -> Bool = { true },
        makeStart: @MainActor () -> Start
    ) async {
        guard let items, owner.generation == reconciliationGeneration, !Task.isCancelled, isCurrent() else { return }
        let start = makeStart()
        let currentGeneration = reconciliationGeneration
        guard start.isCurrent() else { return }
        publicationStartOwed = true
        if let pending = pendingReconciliation {
            if pending.generation == currentGeneration, pending.accountUID == start.accountUID {
                let outcome = await reconcilePending(pending, items: items, start: start, isCurrent: isCurrent)
                guard case .completed = outcome else { return }
            } else {
                pendingReconciliation = nil
            }
        }
        guard !Task.isCancelled, reconciliationGeneration == currentGeneration, isCurrent(), start.isCurrent() else {
            return
        }
        publicationStartOwed = false
        startWholeLibrary(items: items, makeStart: { start })
    }

    public func reconcileWholeLibrary(
        items: [PhotoItem]?,
        recrawlRestoredItems: Bool,
        owner: OwnerLease,
        isCurrent: @MainActor () -> Bool = { true },
        makeStart: @MainActor () -> Start
    ) async {
        guard owner.generation == reconciliationGeneration, !Task.isCancelled, isCurrent() else { return }
        let start = makeStart()
        guard start.isCurrent() else { return }
        let previous = pendingReconciliation
        let sameOwner = previous?.generation == reconciliationGeneration && previous?.accountUID == start.accountUID
        reconciliationRevision &+= 1
        let pending = PendingReconciliation(
            revision: reconciliationRevision,
            generation: reconciliationGeneration,
            accountUID: start.accountUID,
            recrawlRestoredItems: (recrawlRestoredItems && isStarted)
                || (sameOwner && previous?.recrawlRestoredItems == true)
        )
        pendingReconciliation = pending
        guard let items else { return }
        switch await reconcilePending(pending, items: items, start: start, isCurrent: isCurrent) {
        case .completed(restarting: true) where !Task.isCancelled:
            guard reconciliationGeneration == pending.generation, isCurrent(), start.isCurrent() else { return }
            publicationStartOwed = false
            startWholeLibrary(items: items, makeStart: { start })
        case .completed, .stopped:
            // The scan that a publication owed is not the cancelled work of this request.
            startOwedScan(items: items, start: start, generation: pending.generation, isCurrent: isCurrent)
        case .superseded:
            return
        }
    }

    /// Starts the scan that a publication still owes, with the known library of the request that took it over.
    private func startOwedScan(
        items: [PhotoItem], start: Start, generation: UInt64, isCurrent: @MainActor () -> Bool
    ) {
        guard publicationStartOwed, reconciliationGeneration == generation, isCurrent(), start.isCurrent() else {
            return
        }
        publicationStartOwed = false
        startWholeLibrary(items: items, makeStart: { start })
    }

    private func reconcilePending(
        _ pending: PendingReconciliation,
        items: [PhotoItem],
        start: Start,
        isCurrent: @MainActor () -> Bool
    ) async -> ReconcileOutcome {
        // The clean-up reads its library now: every list published up to this revision is older than it.
        let inventoryRevisionAtRead = inventoryRevision
        guard admitsReconciliation(pending, attempt: reconciliationAttempt, start: start, isCurrent: isCurrent) else {
            return rejection(of: pending, attempt: reconciliationAttempt, start: start)
        }
        reconciliationAttempt &+= 1
        let attempt = reconciliationAttempt
        await start.awaiting?.value
        guard admitsReconciliation(pending, attempt: attempt, start: start, isCurrent: isCurrent),
            let lease = store.captureSessionLease()
        else { return rejection(of: pending, attempt: attempt, start: start) }
        #if DEBUG
            let beforeProjection = beforeWholeLibraryUIDProjectionForTesting
        #endif
        let uids = await Task.detached(priority: .userInitiated) {
            #if DEBUG
                if let beforeProjection { await beforeProjection() }
            #endif
            return Set(items.map(\.uid))
        }.value
        guard admitsReconciliation(pending, attempt: attempt, start: start, isCurrent: isCurrent),
            store.isCurrentSessionLease(lease)
        else { return rejection(of: pending, attempt: attempt, start: start) }
        await index.retainOnly(
            uids, persistTo: store, sessionLease: lease, afterInventoryRevision: inventoryRevisionAtRead)
        guard admitsReconciliation(pending, attempt: attempt, start: start, isCurrent: isCurrent),
            store.isCurrentSessionLease(lease)
        else { return rejection(of: pending, attempt: attempt, start: start) }
        pendingReconciliation = nil
        let restarting = pending.recrawlRestoredItems && isStarted
        if restarting { prepareRestart() }
        return .completed(restarting: restarting)
    }

    private func rejection(of pending: PendingReconciliation, attempt: UInt64, start: Start) -> ReconcileOutcome {
        let latest =
            reconciliationGeneration == pending.generation && reconciliationAttempt == attempt
            && pendingReconciliation?.revision == pending.revision && start.accountUID == pending.accountUID
        return latest ? .stopped : .superseded
    }

    private func admitsReconciliation(
        _ pending: PendingReconciliation,
        attempt: UInt64,
        start: Start,
        isCurrent: @MainActor () -> Bool
    ) -> Bool {
        !Task.isCancelled && reconciliationGeneration == pending.generation
            && reconciliationAttempt == attempt && pendingReconciliation?.revision == pending.revision
            && start.accountUID == pending.accountUID && isCurrent() && start.isCurrent()
    }

    private func discardPendingReconciliation() {
        reconciliationGeneration &+= 1
        reconciliationAttempt &+= 1
        pendingReconciliation = nil
        publicationStartOwed = false
    }

    /// Starts the crawl once; repeated calls do nothing until a pause, restart or retirement. `items` builds the
    /// inventory when none exists yet. With `acceptingInventory` the scan may store results for every photo of the
    /// inventory that it reads when it begins, also after a clean-up excluded them.
    public func start(items: [PhotoItem], _ start: Start, acceptingInventory: Bool = false) {
        guard !isStarted else { return }
        isStarted = true
        generation &+= 1
        let crawlGeneration = generation
        let previousStarter = startTask
        let previousPrivacyStop = privacyStopTask
        let awaiting = start.awaiting
        previousStarter?.cancel()
        if inventoryTask == nil {
            inventoryTask = Task.detached(priority: .utility) { LocationCrawlInventory(items: items) }
        }
        let initialInventory = inventoryTask
        crawlInventoryRevision = inventoryRevision
        let index = index
        let store = store
        let crawl = crawl
        let platform = platform
        let governor = LibraryWorkloadGovernorPolicy()
        startTask = Task { [weak self, previousStarter, previousPrivacyStop, awaiting] in
            await previousPrivacyStop?.value
            await awaiting?.value
            await previousStarter?.value
            guard let self, self.admits(crawlGeneration, start) else { return }
            var sessionLease: PhotoLocationStore.SessionLease?
            if platform.requiresStoreSession {
                // Startup already restored the account's location cache. Map entry only resumes its crawl.
                await crawl.cancel()
                guard self.admits(crawlGeneration, start) else { return }
                guard let lease = store.captureSessionLease() else { return }
                sessionLease = lease
            }
            // Give the thumbnail crawl a head start, then crawl GPS whenever the grid does not wait for visible
            // thumbnails. Do not use `hasPendingThumbnailWork()`: it includes whole-library fill and can starve
            // the Map behind a large thumbnail crawl.
            do {
                try await Task.sleep(for: platform.headStart)
            } catch {
                return
            }
            guard sessionLease.map(store.isCurrentSessionLease) ?? true, self.admits(crawlGeneration, start)
            else { return }
            // The newest inventory, not the one this start was called with: a publication may have replaced it while
            // the start waited, and the crawl must not probe a photo that the newer library lacks. A publication can
            // also land while the inventory is awaited, so the revision is checked again, a bounded number of times,
            // and nothing is awaited between that check, the acceptance and the start.
            var newest = await self.newestInventory(startedWith: initialInventory)
            var rereads = 0
            while newest.revision != self.inventoryRevision, rereads < 5, self.admits(crawlGeneration, start) {
                rereads += 1
                newest = await self.newestInventory(startedWith: initialInventory)
            }
            guard self.admits(crawlGeneration, start) else { return }
            let inventory = newest.inventory
            if acceptingInventory { index.accept(inventory, revision: newest.revision) }
            self.crawlStartsForTesting += 1
            await crawl.start(
                uids: inventory.uids,
                captureDates: inventory.captureDates,
                accountUID: start.accountUID,
                location: start.location,
                index: index,
                store: store,
                shouldYield: { [yieldsAlways = start.yieldsAlways, visibleDemand = start.visibleDemand] in
                    if await yieldsAlways() { return true }
                    return governor.budget(
                        for: .backgroundLocationCrawl,
                        signals: LibraryWorkloadSignals(hasVisibleMediaDemand: await visibleDemand())
                    ).shouldYield
                },
                log: start.log,
                inventory: { @MainActor [weak self] in await self?.latestInventory() ?? LocationCrawlInventory() }
            )
            guard !Task.isCancelled, crawlGeneration == self.generation, start.isCurrent() else {
                await crawl.cancel()
                return
            }
            if let restart = start.restartForNewerInventory, self.crawlInventoryRevision != self.inventoryRevision {
                self.isStarted = false
                restart()
            }
        }
    }

    /// Lets the next start run again, for example after the crawl finished or the library changed.
    public func prepareRestart() {
        isStarted = false
    }

    /// Stops the crawl for privacy (Map and Places off). A later start waits until it stopped.
    public func pause() {
        stopCrawl(settlingCutShortScan: false)
    }

    private func stopCrawl(settlingCutShortScan: Bool) {
        generation &+= 1
        isStarted = false
        startTask?.cancel()
        let previousStop = privacyStopTask
        let crawl = crawl
        let index = index
        privacyStopTask = Task {
            await previousStop?.value
            await crawl.cancel()
            // The crawl has ended and publishes no more progress. A later start waits for this task.
            if settlingCutShortScan, index.scanProgress.phase == .scanning {
                index.updateScanProgress(PhotoLocationScanProgress(phase: .completed, found: index.coordinates.count))
            }
        }
    }

    /// Rejects every admitted start of an earlier account configuration. Returns the cancelled start task, which
    /// stays the predecessor of the next start. The clean-up that waits belongs to the account, not to the
    /// configuration: it stays for the next publication of the same account. A publication of another account drops it.
    @discardableResult
    public func invalidate() -> Task<Void, Never>? {
        let waiting = pendingReconciliation
        discardPendingReconciliation()
        if let waiting {
            pendingReconciliation = PendingReconciliation(
                revision: waiting.revision, generation: reconciliationGeneration, accountUID: waiting.accountUID,
                recrawlRestoredItems: waiting.recrawlRestoredItems)
        }
        generation &+= 1
        isStarted = false
        startTask?.cancel()
        return startTask
    }

    /// Ends the session's work for the account teardown and forgets its inventory. The caller joins the returned
    /// start task, then cancels `crawl`.
    @discardableResult
    public func retire() -> Task<Void, Never>? {
        discardPendingReconciliation()
        let starter = startTask
        generation &+= 1
        starter?.cancel()
        startTask = nil
        isStarted = false
        inventoryTask?.cancel()
        inventoryTask = nil
        return starter
    }

    /// Forgets the inventory and the started state for a sign-out without cancelling the start task: the host's
    /// account check rejects it, and the teardown joins `startingTask` before it cancels `crawl`.
    public func resetForTeardown() {
        discardPendingReconciliation()
        isStarted = false
        inventoryTask?.cancel()
        inventoryTask = nil
    }

    private func admits(_ crawlGeneration: UInt64, _ start: Start) -> Bool {
        !Task.isCancelled && crawlGeneration == generation && start.isCurrent() && isEnabled()
    }

    private func newestInventory(
        startedWith initial: Task<LocationCrawlInventory, Never>?
    ) async -> (inventory: LocationCrawlInventory, revision: UInt64) {
        guard inventoryTask != nil else {
            return (await initial?.value ?? LocationCrawlInventory(), inventoryRevision)
        }
        return await readLatestInventory()
    }

    private func latestInventory() async -> LocationCrawlInventory {
        guard inventoryTask != nil else { return LocationCrawlInventory() }
        return await readLatestInventory().inventory
    }

    /// The inventory of the revision that was current when the read began, with that revision.
    private func readLatestInventory() async -> (inventory: LocationCrawlInventory, revision: UInt64) {
        guard let task = inventoryTask else { return (LocationCrawlInventory(), inventoryRevision) }
        let revision = inventoryRevision
        let inventory = await task.value
        #if DEBUG
            await afterInventoryReadForTesting?()
        #endif
        crawlInventoryRevision = max(crawlInventoryRevision, revision)
        return (inventory, revision)
    }
}
