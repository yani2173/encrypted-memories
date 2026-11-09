import AlbumCore
import CryptoKit
import Foundation
import PhotosCore

protocol LibrarySourceRemoteBackend: Sendable {
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier]
    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem]
}

extension SDKAlbumCatalogBackend: LibrarySourceRemoteBackend {}

public enum LibrarySourceRefreshOutcome: Sendable, Equatable {
    case complete
    case retryableFailure
    case cancelled
}

/// Admission is distinct from runtime binding: only an accepted inventory authorizes its resources.
public enum PrimaryInventoryAdmission: Sendable, Equatable {
    case accepted
    case rejected
    case deferred
    case superseded
    case unavailable
}

/// Account-scoped source discovery, membership refresh, persistence, and byte-route fencing.
///
/// The coordinator owns one graph. Platform hosts consume immutable changes and never infer source
/// membership from UI state. The main projection remains the primary inventory; additional inventories
/// participate only in explicitly authorized derived-data work.
public actor LibrarySourceCoordinator: PriorityThumbnailBatchLoader, ProvisionalThumbnailAuthorizing {
    public typealias ChangeHandler = @Sendable (LibrarySourceChange) async -> Void

    private static let primarySourceID = SourceID("primary")
    private static let primarySource = LibrarySource(
        id: primarySourceID,
        capabilities: [.readMetadata, .readThumbnail, .readContent, .writeContent, .observeChanges],
        precedence: 100,
        isIncluded: true
    )

    private let remote: any LibrarySourceRemoteBackend
    private let thumbnailLoader: any ThumbnailBatchLoader
    private var inventoryStore: LibrarySourceInventoryStore?
    private var inventorySession: LibrarySourceInventoryStore.SessionLease?
    private var graph = LibrarySourceGraph()
    /// Confirmed local access losses remain fenced until one complete remote source snapshot no longer
    /// contains the locator. Persisted access-lost inventories keep the fence across process restarts.
    private var revokedLocators = Set<AlbumNodeIdentifier>()
    private var revocationPersistenceGeneration: UInt64 = 0
    private var changeHandler: ChangeHandler?
    private var lastPublishedSignature: ConsumerChangeSignature?
    private var refreshTask: Task<LibrarySourceRefreshOutcome, Never>?
    private var refreshGeneration: UInt64 = 0
    private var refreshRequestedWhileActive = false
    private var activeRevocations = 0
    private var revocationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepared = false
    private var closed = false
    /// Sequence of the last applied Recently Deleted report.
    private var identitiesOutsideInventorySequence: UInt64 = 0
    private var listedIdentitiesOutsideInventory: [PhotoUID] = []
    private var provisionalThumbnailIdentities: [UUID: [PhotoUID]] = [:]

    init(
        remote: any LibrarySourceRemoteBackend,
        thumbnailLoader: any ThumbnailBatchLoader,
        inventoryStore: LibrarySourceInventoryStore?
    ) {
        self.remote = remote
        self.thumbnailLoader = thumbnailLoader
        self.inventoryStore = inventoryStore
    }

    /// Opens the optional rebuildable inventory store before any platform consumer binds to the graph.
    func prepare() async {
        guard !prepared, !closed else { return }
        prepared = true

        var restored: [LibrarySourceInventory] = []
        if let inventoryStore {
            do {
                let loadSession = try await inventoryStore.activate(for: graph.runtimeEpoch)
                restored = try await inventoryStore.load(using: loadSession)
                    .filter { $0.source.id != Self.primarySourceID }
            } catch {
                DebugLog.log("[LibrarySource] inventory warm start unavailable")
            }
        }

        let primary = LibrarySourceInventory(
            source: Self.primarySource,
            accessState: .temporarilyUnavailable,
            authority: .hydrating,
            items: []
        )
        do {
            graph = try LibrarySourceGraph(restoring: [primary] + restored)
        } catch {
            let fallback = LibrarySourceGraph()
            let sourceSetLease = fallback.beginSourceSetRefresh()
            _ = fallback.commitSourceSet([Self.primarySource], using: sourceSetLease)
            graph = fallback
            restored = []
        }
        revokedLocators = Set(
            restored.compactMap { inventory in
                guard inventory.accessState == .accessLost else { return nil }
                return Self.locator(from: inventory.source.id)
            }
        )

        guard let inventoryStore else { return }
        do {
            inventorySession = try await inventoryStore.activate(for: graph.runtimeEpoch)
        } catch {
            await inventoryStore.close()
            self.inventoryStore = nil
            inventorySession = nil
            DebugLog.log("[LibrarySource] inventory persistence unavailable")
        }
    }

    /// Installs the one account-host consumer and returns a same-revision initial snapshot.
    public func attach(_ handler: @escaping ChangeHandler) -> LibrarySourceChange {
        changeHandler = handler
        let change = graph.snapshot()
        lastPublishedSignature = ConsumerChangeSignature(change)
        return change
    }

    public func detach() {
        changeHandler = nil
        lastPublishedSignature = nil
    }

    /// Returns the graph state at this actor boundary. Runtime startup uses it after binding its
    /// consumers, so a change delivered during that bind cannot be lost.
    package func snapshot() -> LibrarySourceChange {
        graph.snapshot()
    }

    /// Replaces the primary inventory with explicit host authority.
    /// Cached frames become query-visible but cannot authorize destructive derived-data reconciliation.
    @discardableResult
    public func replacePrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority
    ) async -> PrimaryInventoryAdmission {
        guard prepared, !closed else { return .unavailable }
        guard authority != .hydrating else { return .deferred }
        let sourceItems = items.map { item in
            // A Live Photo tag does not prove that the listing resolved its companion. Keep the raw tag,
            // but do not claim a complete relationship or erase an earlier known pairing.
            let knownFields: LibrarySourceMetadataFields =
                item.isLivePhoto && item.relatedVideoID == nil
                ? .complete.subtracting(.livePhotoRelationship) : .complete
            return LibrarySourceItem(item: item, knownFields: knownFields)
        }
        if authority == .cached {
            guard let current = graph.inventory(for: Self.primarySourceID) else { return .unavailable }
            guard current.authority != .authoritative else { return .superseded }
            if current.items == sourceItems { return .accepted }
            if let change = graph.installCachedInventory(
                sourceItems,
                for: Self.primarySourceID
            ) {
                await publish(change)
                return closed ? .unavailable : .accepted
            }
            return .rejected
        }
        if let current = graph.inventory(for: Self.primarySourceID),
            current.accessState == .available,
            current.authority == .authoritative,
            current.items == sourceItems
        {
            return .accepted
        }
        guard let lease = graph.beginRefresh(Self.primarySourceID) else { return .unavailable }
        guard let change = graph.commit(sourceItems, validationToken: nil, using: lease) else {
            if let failed = graph.failRefresh(using: lease) { await publish(failed) }
            return .rejected
        }
        await publish(change)
        return closed ? .unavailable : .accepted
    }

    /// Registers the photos in Recently Deleted, newest first; they are outside every inventory.
    ///
    /// A trashed photo left the inventory, so no scope and no lease authorized its thumbnail and each tile
    /// stayed black. The list authorizes thumbnail reads and keeps their bytes; the thumbnail crawl fetches
    /// them after every library photo. A later list without a photo releases its bytes again. Reports arrive with
    /// an increasing sequence; one older than the last applied report is ignored, because actor hops may reorder them.
    public func setIdentitiesOutsideInventory(_ uids: [PhotoUID], sequence: UInt64) async {
        guard !closed, sequence > identitiesOutsideInventorySequence else { return }
        identitiesOutsideInventorySequence = sequence
        listedIdentitiesOutsideInventory = uids
        await publishIdentitiesOutsideInventory()
    }

    /// A presentation owns only its temporary byte registration, never primary inventory membership.
    public func beginProvisionalThumbnailAccess() -> UUID? {
        guard prepared, !closed else { return nil }
        let lease = UUID()
        provisionalThumbnailIdentities[lease] = []
        return lease
    }

    public func updateProvisionalThumbnailAccess(_ uids: [PhotoUID], using lease: UUID) async {
        guard !closed, provisionalThumbnailIdentities[lease] != nil else { return }
        provisionalThumbnailIdentities[lease] = uids
        await publishIdentitiesOutsideInventory()
    }

    public func endProvisionalThumbnailAccess(_ lease: UUID) async {
        guard !closed, provisionalThumbnailIdentities.removeValue(forKey: lease) != nil else { return }
        await publishIdentitiesOutsideInventory()
    }

    private func publishIdentitiesOutsideInventory() async {
        var uids = listedIdentitiesOutsideInventory
        for lease in provisionalThumbnailIdentities.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            uids.append(contentsOf: provisionalThumbnailIdentities[lease] ?? [])
        }
        if let change = graph.setIdentitiesOutsideInventory(uids) { await publish(change) }
    }

    /// Applies an already-confirmed remote access loss without waiting for another catalog sweep.
    /// This invalidates byte-route leases and derived-data memberships in the same graph mutation.
    func revokeAdditionalSource(for locator: AlbumNodeIdentifier) async {
        guard prepared, !closed else { return }
        activeRevocations += 1
        defer { finishRevocation() }
        if revokedLocators.insert(locator).inserted {
            revocationPersistenceGeneration &+= 1
        }
        let sourceID = Self.sourceID(for: locator)
        let change = graph.removeSource(sourceID)
        // Publish the access fence before persistence. A slow local store must never keep stale
        // thumbnail authorization or derived-data membership visible after confirmed access loss.
        if let change { await publish(change) }
        await persistAccessLoss(for: sourceID)
        await persistAdditionalInventories()
    }

    private func finishRevocation() {
        activeRevocations -= 1
        guard activeRevocations == 0 else { return }
        let waiters = revocationDrainWaiters
        revocationDrainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForRevocationDrain() async {
        guard activeRevocations > 0 else { return }
        await withCheckedContinuation { continuation in
            revocationDrainWaiters.append(continuation)
        }
    }

    /// Coalesces foreground and launch refreshes. Discovery is authoritative only after the complete SDK
    /// callback stream returns; every album membership commits only after its own complete enumeration.
    @discardableResult
    public func refresh() async -> LibrarySourceRefreshOutcome {
        // The caller can be cancelled before its cross-actor hop reaches this admission gate.
        // Never create an unstructured coordinator task for already-retired runtime work.
        guard prepared, !closed, !Task.isCancelled else { return .cancelled }
        if let refreshTask {
            refreshRequestedWhileActive = true
            return await refreshTask.value
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshRequestedWhileActive = false
        let task = Task { [weak self] in
            guard let self else { return LibrarySourceRefreshOutcome.cancelled }
            return await self.performRefreshLoop(generation: generation)
        }
        refreshTask = task
        return await task.value
    }

    private func performRefreshLoop(generation: UInt64) async -> LibrarySourceRefreshOutcome {
        while true {
            let outcome = await performRefresh(generation: generation)
            guard isCurrentRefresh(generation) else { return .cancelled }
            guard refreshRequestedWhileActive else {
                // Retire the task before it completes. A request which arrives after this point sees no
                // active task and starts a fresh pass instead of attaching to an already-finished result.
                refreshTask = nil
                return outcome
            }
            refreshRequestedWhileActive = false
        }
    }

    /// Cancels and joins the coordinator-owned refresh without closing the graph. Runtime hosts use
    /// this as an ownership barrier before detaching their consumer; facade shutdown closes the
    /// coordinator and its persistence store later in the ordered account teardown.
    package func cancelRefresh() async {
        refreshGeneration &+= 1
        let activeRefresh = refreshTask
        activeRefresh?.cancel()
        _ = await activeRefresh?.value
        refreshTask = nil
        refreshRequestedWhileActive = false
    }

    private func performRefresh(generation: UInt64) async -> LibrarySourceRefreshOutcome {
        let locators: [AlbumNodeIdentifier]
        do {
            locators = try await remote.librarySourceLocators()
        } catch {
            return isCurrentRefresh(generation) ? .retryableFailure : .cancelled
        }
        guard isCurrentRefresh(generation) else { return .cancelled }

        let discoveredLocators = Set(locators)
        // A complete absence acknowledges a prior local revocation. A still-listed locator remains
        // fenced, including across a restart, until the remote source set has converged.
        let priorRevokedLocators = revokedLocators
        revokedLocators.formIntersection(discoveredLocators)
        if revokedLocators != priorRevokedLocators {
            revocationPersistenceGeneration &+= 1
        }
        var seen = Set<SourceID>()
        let uniqueLocators = locators.compactMap { locator -> (SourceID, AlbumNodeIdentifier)? in
            guard !revokedLocators.contains(locator) else { return nil }
            let sourceID = Self.sourceID(for: locator)
            return seen.insert(sourceID).inserted ? (sourceID, locator) : nil
        }
        let additionalSources = uniqueLocators.map { sourceID, _ in
            Self.additionalSource(id: sourceID)
        }
        let baseline = graph.captureChangeBaseline()
        let sourceSetLease = graph.beginSourceSetRefresh()
        guard
            graph.commitSourceSetWithoutProjection(
                [Self.primarySource] + additionalSources,
                using: sourceSetLease
            )
        else {
            if let failed = graph.failSourceSetRefresh(using: sourceSetLease) {
                await publish(failed)
            }
            return .cancelled
        }

        let jobs = uniqueLocators.compactMap { sourceID, locator -> SourceRefreshJob? in
            guard let lease = graph.beginRefresh(sourceID) else { return nil }
            return SourceRefreshJob(sourceID: sourceID, locator: locator, lease: lease)
        }
        let results = await enumerate(jobs)
        guard isCurrentRefresh(generation) else { return .cancelled }
        var needsRetry = false
        for result in results {
            needsRetry = needsRetry || result.items == nil
            _ = graph.finishRefreshWithoutProjection(
                result.items,
                validationToken: nil,
                using: result.job.lease
            )
        }
        let change = graph.snapshot(since: baseline)
        await persistAdditionalInventories()
        await publish(change)
        return needsRetry ? .retryableFailure : .complete
    }

    private struct SourceRefreshJob: Sendable {
        let sourceID: SourceID
        let locator: AlbumNodeIdentifier
        let lease: SourceUpdateLease
    }

    private struct SourceRefreshResult: Sendable {
        let job: SourceRefreshJob
        let items: [LibrarySourceItem]?
    }

    private func enumerate(_ jobs: [SourceRefreshJob]) async -> [SourceRefreshResult] {
        guard !jobs.isEmpty else { return [] }
        let remote = self.remote
        let answers = await BoundedConcurrency.map(jobs, limit: 4) { job in
            try? await remote.librarySourceItems(for: job.locator)
        }
        // A source that never started (the run was cancelled) has no answer, like one whose read failed.
        return zip(jobs, answers).map { SourceRefreshResult(job: $0, items: $1 ?? nil) }
    }

    private func persistAdditionalInventories() async {
        guard let inventoryStore, let inventorySession else { return }
        do {
            let lease = try await inventoryStore.captureWriteLease(using: inventorySession)
            var inventories = graph.inventories().filter { inventory in
                guard inventory.source.id != Self.primarySourceID else { return false }
                guard inventory.accessState == .accessLost else { return true }
                guard let locator = Self.locator(from: inventory.source.id) else { return false }
                return revokedLocators.contains(locator)
            }
            let persistedSourceIDs = Set(inventories.map(\.source.id))
            inventories.append(
                contentsOf: revokedLocators.compactMap { locator in
                    let sourceID = Self.sourceID(for: locator)
                    guard !persistedSourceIDs.contains(sourceID) else { return nil }
                    return LibrarySourceInventory(
                        source: Self.additionalSource(id: sourceID),
                        accessState: .accessLost,
                        authority: .authoritative,
                        items: []
                    )
                })
            let persistenceSignature = graph.persistenceSignature(
                excluding: [Self.primarySourceID],
                additionalStateGeneration: revocationPersistenceGeneration
            )
            _ = try await inventoryStore.save(
                inventories,
                sourceSetAuthority: graph.sourceSetAuthority,
                persistenceSignature: persistenceSignature,
                using: lease
            )
        } catch {
            DebugLog.log("[LibrarySource] inventory snapshot could not be persisted")
        }
    }

    private func persistAccessLoss(for sourceID: SourceID) async {
        guard let inventoryStore, let inventorySession else { return }
        do {
            let lease = try await inventoryStore.captureWriteLease(using: inventorySession)
            try await inventoryStore.recordAccessLoss(
                for: Self.additionalSource(id: sourceID),
                using: lease
            )
        } catch {
            DebugLog.log("[LibrarySource] access-loss fence could not be persisted")
        }
    }

    private func publish(_ change: LibrarySourceChange) async {
        guard !closed, let changeHandler else { return }
        guard change.analysisScope.epoch == graph.runtimeEpoch,
            change.analysisScope.revision == graph.revision
        else { return }
        let signature = ConsumerChangeSignature(change)
        if let lastPublishedSignature,
            signature.hasSameInventories(as: lastPublishedSignature),
            signature.hasSameAuthority(as: lastPublishedSignature)
        {
            return
        }
        lastPublishedSignature = signature
        await changeHandler(change)
    }

    private func isCurrentRefresh(_ generation: UInt64) -> Bool {
        !closed && !Task.isCancelled && refreshGeneration == generation
    }

    // MARK: - Source-fenced thumbnail route

    public func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        await loadAuthorizedThumbnails(for: uids, priority: nil, onLoaded: onLoaded)
    }

    public func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        await loadAuthorizedThumbnails(for: uids, priority: priority, onLoaded: onLoaded)
    }

    private func loadAuthorizedThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority?,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        guard !closed else { return ThumbnailBatchLoadResult(batchError: "source runtime closed") }
        let leases = thumbnailAccessLeases(for: Set(uids))
        var denied: [PhotoUID: String] = [:]
        for uid in Set(uids) where leases[uid] == nil {
            denied[uid] = "source unavailable"
        }
        var requested = Set<PhotoUID>()
        let authorized = uids.filter { leases[$0] != nil && requested.insert($0).inserted }
        guard !authorized.isEmpty else {
            return ThumbnailBatchLoadResult(itemErrors: denied)
        }

        let (stream, continuation) = AsyncStream<(PhotoUID, Data)>.makeStream(
            bufferingPolicy: .bufferingOldest(authorized.count)
        )
        async let loading = Self.streamThumbnails(
            loader: thumbnailLoader, uids: authorized, priority: priority, continuation: continuation
        )
        var itemErrors = denied
        var withheld = Set<PhotoUID>()
        var delivered = Set<PhotoUID>()
        // Validate on this actor at delivery time, not on the SDK callback thread. One slow item must
        // not hold already-available thumbnails behind the completion of the entire network batch.
        for await (uid, data) in stream {
            if Task.isCancelled { break }
            guard let lease = leases[uid], !closed, isStillAuthorized(by: lease) else {
                withheld.insert(uid)
                continue
            }
            delivered.insert(uid)
            onLoaded(uid, data)
        }
        let result = await loading
        for (uid, reason) in result.itemErrors
        where leases[uid] != nil && !delivered.contains(uid) && !withheld.contains(uid) && itemErrors[uid] == nil {
            itemErrors[uid] = reason
        }
        return ThumbnailBatchLoadResult(
            batchError: Task.isCancelled ? "cancelled" : result.batchError,
            itemErrors: itemErrors,
            withheldUIDs: withheld
        )
    }

    /// Thumbnail leases: library items through their source, burst members through the item that lists them, and
    /// photos in Recently Deleted, which left every inventory, through the listing that registered them.
    private func thumbnailAccessLeases(for uids: Set<PhotoUID>) -> [PhotoUID: SourceAccessLease] {
        var leases: [PhotoUID: SourceAccessLease] = [:]
        var unleased = Set<PhotoUID>()
        for uid in uids {
            if let lease = graph.accessLease(for: uid, requiring: .readThumbnail) {
                leases[uid] = lease
            } else {
                unleased.insert(uid)
            }
        }
        let burstLeases = graph.burstMemberAccessLeases(for: unleased, requiring: .readThumbnail)
        let outsideInventoryLeases = graph.identityOutsideInventoryAccessLeases(
            for: unleased.subtracting(burstLeases.keys),
            requiring: .readThumbnail
        )
        for uid in unleased {
            if let lease = burstLeases[uid] ?? outsideInventoryLeases[uid] { leases[uid] = lease }
        }
        return leases
    }

    /// Checks a late thumbnail against the graph as it is now. Every inventory refresh that changes an item, even
    /// only its tags, invalidates the leases of the whole source, and after sign-in such refreshes follow each
    /// other. Bytes of a photo whose route the graph still authorizes are delivered; a photo that left the source,
    /// or a source that lost access, keeps them withheld.
    private func isStillAuthorized(by lease: SourceAccessLease) -> Bool {
        graph.isCurrent(lease) || graph.renewed(lease) != nil
    }

    private static func streamThumbnails(
        loader: any ThumbnailBatchLoader,
        uids: [PhotoUID],
        priority: ThumbnailPriority?,
        continuation: AsyncStream<(PhotoUID, Data)>.Continuation
    ) async -> ThumbnailBatchLoadResult {
        defer { continuation.finish() }
        let emitter = ThumbnailStreamEmitter(uids: uids, continuation: continuation)
        if let priority, let loader = loader as? any PriorityThumbnailBatchLoader {
            return await loader.loadThumbnails(for: uids, priority: priority) { uid, data in
                emitter.yield(uid, data)
            }
        }
        return await loader.loadThumbnails(for: uids) { uid, data in
            emitter.yield(uid, data)
        }
    }

    /// Stops discovery before the facade closes the SDK admission gate and releases the inventory database.
    public func shutdown() async {
        guard !closed else { return }
        closed = true
        provisionalThumbnailIdentities.removeAll(keepingCapacity: false)
        await cancelRefresh()
        await waitForRevocationDrain()
        changeHandler = nil
        lastPublishedSignature = nil
        if let inventoryStore {
            await inventoryStore.close()
        }
        inventoryStore = nil
        inventorySession = nil
        revokedLocators.removeAll(keepingCapacity: false)
        revocationPersistenceGeneration = 0
    }

    private static func additionalSource(id: SourceID) -> LibrarySource {
        LibrarySource(
            id: id,
            capabilities: [.readThumbnail],
            precedence: 0,
            isIncluded: false
        )
    }

    private static func sourceID(for locator: AlbumNodeIdentifier) -> SourceID {
        let volume = Data(locator.volumeID.utf8).base64EncodedString()
        let node = Data(locator.nodeID.utf8).base64EncodedString()
        return SourceID("additional:\(volume):\(node)")
    }

    private static func locator(from sourceID: SourceID) -> AlbumNodeIdentifier? {
        let prefix = "additional:"
        guard sourceID.rawValue.hasPrefix(prefix) else { return nil }
        let encoded = sourceID.rawValue.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard encoded.count == 2,
            let volumeData = Data(base64Encoded: String(encoded[0])),
            let nodeData = Data(base64Encoded: String(encoded[1])),
            let volumeID = String(data: volumeData, encoding: .utf8),
            let nodeID = String(data: nodeData, encoding: .utf8),
            !volumeID.isEmpty,
            !nodeID.isEmpty
        else { return nil }
        return AlbumNodeIdentifier(volumeID: volumeID, nodeID: nodeID)
    }
}

private struct ConsumerScopeSignature: Equatable {
    let sourceIDs: Set<SourceID>
    let orderedUIDs: [PhotoUID]
    let authorizationOnlyUIDs: Set<PhotoUID>
    let isAuthoritative: Bool

    init<Kind>(_ scope: DerivedDataScope<Kind>) {
        sourceIDs = scope.sourceIDs
        orderedUIDs = scope.orderedUIDs
        authorizationOnlyUIDs = scope.authorizationOnlyUIDs
        isAuthoritative = scope.isAuthoritative
    }

    func hasSameInventory(as other: Self) -> Bool {
        sourceIDs == other.sourceIDs && orderedUIDs == other.orderedUIDs
            && authorizationOnlyUIDs == other.authorizationOnlyUIDs
    }
}

private struct ConsumerChangeSignature: Equatable {
    let selected: ConsumerScopeSignature
    let analysis: ConsumerScopeSignature
    let thumbnailRetention: ConsumerScopeSignature
    let videoRetention: ConsumerScopeSignature

    init(_ change: LibrarySourceChange) {
        selected = ConsumerScopeSignature(change.selectedScope)
        analysis = ConsumerScopeSignature(change.analysisScope)
        thumbnailRetention = ConsumerScopeSignature(change.thumbnailRetentionScope)
        videoRetention = ConsumerScopeSignature(change.videoRetentionScope)
    }

    func hasSameInventories(as other: Self) -> Bool {
        selected.hasSameInventory(as: other.selected)
            && analysis.hasSameInventory(as: other.analysis)
            && thumbnailRetention.hasSameInventory(as: other.thumbnailRetention)
            && videoRetention.hasSameInventory(as: other.videoRetention)
    }

    func hasSameAuthority(as other: Self) -> Bool {
        selected.isAuthoritative == other.selected.isAuthoritative
            && analysis.isAuthoritative == other.analysis.isAuthoritative
            && thumbnailRetention.isAuthoritative == other.thumbnailRetention.isAuthoritative
            && videoRetention.isAuthoritative == other.videoRetention.isAuthoritative
    }
}

/// Admit at most one value per requested UID before buffering; duplicate or unsolicited SDK
/// callbacks must not consume another requested thumbnail's bounded stream slot.
private final class ThumbnailStreamEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<PhotoUID>
    private let continuation: AsyncStream<(PhotoUID, Data)>.Continuation

    init(uids: [PhotoUID], continuation: AsyncStream<(PhotoUID, Data)>.Continuation) {
        remaining = Set(uids)
        self.continuation = continuation
    }

    func yield(_ uid: PhotoUID, _ data: Data) {
        guard lock.withLock({ remaining.remove(uid) != nil }) else { return }
        continuation.yield((uid, data))
    }
}

enum LibrarySourceInventoryKeyDerivation {
    static func key(accountUID: String, keyPassword: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(keyPassword.utf8)),
            salt: Data("EncryptedMemories.library-source-inventory.v1.\(accountUID)".utf8),
            info: Data("local-source-inventory".utf8),
            outputByteCount: 32
        )
    }
}
