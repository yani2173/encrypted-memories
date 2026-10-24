import Foundation
import MLSearchCore
import Observation
import PhotosCore
import TimelineCore

/// Account-owned, event-driven suggestion refresh. Visible searches and foreground media always take priority.
@MainActor @Observable
public final class SmartSearchDiscoveryScheduler {
    public private(set) var discovery: SmartSearchDiscoveryModel
    public private(set) var isRefreshing = false

    private struct Input: Sendable {
        let sections: [TimelineSection]
        let revision: UInt64
        let favorites: Set<PhotoUID>
        let coordinates: [PhotoCoordinate]
        let locationEvidence: PhotoPlaceEvidence?
        let controller: MLSmartSearchController?
        let snapshot: MLSmartSearchSnapshot?
        let key: String
        let contentKey: String
        let visualKey: String
        let cacheKey: String
        let libraryIsSettled: Bool
        let cacheContentIsSettled: Bool
        let indexedAssetCount: @Sendable () async -> Int
        let searchEvidence: (@Sendable () async throws -> MLSearchBatchResults)?
        let cacheAccess: (@Sendable () async -> MLSearchSuggestionCacheAccess?)?

        /// A metadata-only pass must not consume the later full-curation wakeup.
        var generationKey: String {
            snapshot?.permitsAutomaticSuggestionGeneration == false ? contentKey + "|metadata" : contentKey
        }
    }

    @ObservationIgnored private let runtimeState: LibraryRuntimeState
    @ObservationIgnored private let debounce: Duration
    /// The wait before each retry of a failed refresh or suggestion save. Its count is the evidence retry budget; the
    /// save budget stays four attempts.
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let placeName: SmartSearchDiscoveryModel.PlaceNameResolver
    @ObservationIgnored private let libraryRows: SmartSearchLibraryRowsCache
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var completedKey: String?
    @ObservationIgnored private var failedKey: String?
    /// Retired place evidence needs a publication event, not another metadata pass.
    @ObservationIgnored private var waitingForPlaceKey: String?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var eligible = false
    @ObservationIgnored private var evidenceKey: String?
    @ObservationIgnored private var evidence: MLSearchBatchResults?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var cacheGeneration: UInt64 = 0
    @ObservationIgnored private var preparedCacheKey: String?
    @ObservationIgnored private var cacheAccess: MLSearchSuggestionCacheAccess?
    @ObservationIgnored private var contentFingerprint: Data?
    /// Computed together with `contentFingerprint`, so a save does not read every photo again.
    @ObservationIgnored private var assetFingerprint: Data?
    @ObservationIgnored private var pendingPersistenceKey: String?
    @ObservationIgnored private var failedPersistenceKey: String?
    @ObservationIgnored private var persistenceWriteFailures = 0

    #if DEBUG
        private(set) var curationRunCount = 0
        private(set) var metadataPassCount = 0
        private(set) var placeClusteringCount = 0
        func waitForRefreshForTesting() async { await task?.value }
        var cachedEvidenceAssetCount: Int { evidence?.scannedUIDs.count ?? 0 }
        var libraryRowBuildCount: Int { libraryRows.buildCount }
    #endif

    public init(
        runtimeState: LibraryRuntimeState = .shared,
        debounce: Duration = .milliseconds(250),
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        placeName: @escaping SmartSearchDiscoveryModel.PlaceNameResolver
    ) {
        precondition(!retryDelays.isEmpty, "a failed suggestion save needs at least one retry delay")
        self.runtimeState = runtimeState
        self.debounce = debounce
        self.retryDelays = retryDelays
        self.placeName = placeName
        let libraryRows = SmartSearchLibraryRowsCache()
        self.libraryRows = libraryRows
        discovery = SmartSearchDiscoveryModel(
            refreshPolicy: .background, placeName: placeName, libraryRows: libraryRows)
    }

    private func makeModel() -> SmartSearchDiscoveryModel {
        SmartSearchDiscoveryModel(refreshPolicy: .background, placeName: placeName, libraryRows: libraryRows)
    }

    /// A shared place publication replaces raw coordinate count as the location trigger.
    /// Callers without a shared snapshot can omit `placeRevision` and supply `coordinateCount`.
    public static func revisionKey(
        timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>, coordinateCount: Int = 0,
        smartSearch: MLSmartSearchController?, placeRevision: Int? = nil
    ) -> String {
        revisionKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs, coordinateCount: coordinateCount,
            smartSearch: smartSearch, snapshot: smartSearch?.snapshot, placeRevision: placeRevision)
    }

    private static func revisionKey(
        timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>, coordinateCount: Int,
        smartSearch: MLSmartSearchController?, snapshot: MLSmartSearchSnapshot?, placeRevision: Int?
    ) -> String {
        contentKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs, coordinateCount: coordinateCount,
            smartSearch: smartSearch, snapshot: snapshot, placeRevision: placeRevision)
            + "|generationReady:\(permitsAutomaticGeneration(snapshot))"
            + "|fullGenerationReady:\(snapshot?.permitsAutomaticSuggestionGeneration ?? true)"
            + "|cacheAuthority:\(cacheAuthorityKey(snapshot))"
    }

    /// Activation publishes an empty coverage snapshot before the first index pass restores its counts.
    /// That transition can make the saved cache readable without changing the evidence coverage key.
    private static func cacheAuthorityKey(_ snapshot: MLSmartSearchSnapshot?) -> String {
        switch snapshot?.phase {
        case .ready, .waiting, .indexing: "active"
        default: "pending"
        }
    }

    private static func contentKey(
        timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>, coordinateCount: Int,
        smartSearch: MLSmartSearchController?, snapshot: MLSmartSearchSnapshot?, placeRevision: Int?
    ) -> String {
        let visualKey = visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot)
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return [
            visualKey, "\(favoriteUIDs.hashValue)",
            placeRevision.map { "places:\($0)" } ?? "coordinates:\(coordinateCount)", "\(day)",
            "\(snapshot?.isEnabled == true)",
            smartSearch.map { "\(ObjectIdentifier($0))" } ?? "-",
        ].joined(separator: "|")
    }

    /// Pass the same place publication revision as the host key and its matching evidence.
    public func update(
        sections: [TimelineSection], timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate], smartSearch: MLSmartSearchController?, libraryIsSettled: Bool = true,
        cacheContentIsSettled: Bool = true, placeRevision: Int? = nil, locationEvidence: PhotoPlaceEvidence? = nil
    ) {
        let lifecycle = smartSearch?.lifecycleActor
        let searchEvidence: (@Sendable () async throws -> MLSearchBatchResults)?
        let cacheAccess: (@Sendable () async -> MLSearchSuggestionCacheAccess?)?
        if let lifecycle {
            searchEvidence = { try await lifecycle.searchSuggestionEvidence() }
            cacheAccess = { await lifecycle.suggestionCacheAccess() }
        } else {
            searchEvidence = nil
            cacheAccess = nil
        }
        update(
            sections: sections, timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs,
            coordinates: coordinates, smartSearch: smartSearch, snapshot: smartSearch?.snapshot,
            indexedAssetCount: { await lifecycle?.semanticIndexedAssetCount() ?? 0 },
            searchEvidence: searchEvidence, libraryIsSettled: libraryIsSettled,
            cacheContentIsSettled: cacheContentIsSettled,
            cacheAccess: cacheAccess, placeRevision: placeRevision, locationEvidence: locationEvidence)
    }

    func update(
        sections: [TimelineSection], timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate], smartSearch: MLSmartSearchController? = nil,
        snapshot: MLSmartSearchSnapshot?, indexedAssetCount: @escaping @Sendable () async -> Int,
        searchEvidence: (@Sendable () async throws -> MLSearchBatchResults)?, libraryIsSettled: Bool = true,
        cacheContentIsSettled: Bool = true,
        cacheAccess: (@Sendable () async -> MLSearchSuggestionCacheAccess?)? = nil,
        placeRevision: Int? = nil, locationEvidence: PhotoPlaceEvidence? = nil
    ) {
        // Coordinates and eligibility must describe the same classified snapshot during a crawl.
        let coordinates = locationEvidence?.coordinates ?? coordinates
        if let input, input.controller !== smartSearch { reset() }
        let visualKey = Self.visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot)
        let key =
            Self.revisionKey(
                timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs,
                coordinateCount: coordinates.count, smartSearch: smartSearch, snapshot: snapshot,
                placeRevision: placeRevision
            ) + "|librarySettled:\(libraryIsSettled)|cacheContentSettled:\(cacheContentIsSettled)"
        guard input?.key != key else { return }
        let contentKey = Self.contentKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs, coordinateCount: coordinates.count,
            smartSearch: smartSearch, snapshot: snapshot, placeRevision: placeRevision)
        let cacheKey = contentKey + "|cacheAuthority:\(Self.cacheAuthorityKey(snapshot))"
        // A replacement inventory must stop the superseded scan, not queue another full pass behind it.
        if input?.contentKey != contentKey || !libraryIsSettled || !cacheContentIsSettled
            || !Self.permitsAutomaticGeneration(snapshot)
            || input?.snapshot?.permitsAutomaticSuggestionGeneration != snapshot?.permitsAutomaticSuggestionGeneration
        {
            task?.cancel()
        }
        if input?.contentKey != contentKey {
            pendingPersistenceKey = nil
            failedPersistenceKey = nil
            persistenceWriteFailures = 0
        }
        if input?.cacheKey != cacheKey || !cacheContentIsSettled {
            cacheGeneration &+= 1
            cacheTask?.cancel()
            cacheTask = nil
            preparedCacheKey = nil
            self.cacheAccess = nil
            contentFingerprint = nil
            assetFingerprint = nil
        }
        if !SmartSearchDiscoveryModel.visualConceptsAvailable(snapshot) || evidenceKey != visualKey {
            discardEvidence()
        }
        if let previous = input, discovery.hasComputed {
            if Self.persistedModelKey(previous.snapshot) != Self.persistedModelKey(snapshot) {
                let replacement = makeModel()
                replacement.reusePlaceNames(from: discovery)
                discovery = replacement
            } else {
                // Invalid rows disappear at once, so this diff stays on the main actor; it indexes only the
                // part of the library that differs.
                let affectedUIDs =
                    previous.revision != timelineRevision
                    ? Self.changedPhotos(from: previous.sections, to: sections) : []
                discovery.invalidateRows(
                    affectedUIDs: affectedUIDs, favoritesChanged: previous.favorites != favoriteUIDs,
                    locationsChanged: locationEvidence == nil && previous.coordinates != coordinates)
            }
        }
        eligible =
            libraryIsSettled && cacheContentIsSettled && Self.permitsAutomaticGeneration(snapshot)
            && Self.permitsRefresh(runtimeState.snapshot())
        PhotoDiagnostics.shared.emitDebug(
            "SearchSuggestions",
            [
                "event": "input", "generationAllowed": "\(Self.permitsAutomaticGeneration(snapshot))",
                "librarySettled": "\(libraryIsSettled)", "cacheContentSettled": "\(cacheContentIsSettled)",
                "eligible": "\(eligible)", "items": "\(sections.reduce(0) { $0 + $1.items.count })",
                "coordinates": "\(coordinates.count)",
            ])
        input = Input(
            sections: sections, revision: timelineRevision, favorites: favoriteUIDs,
            coordinates: coordinates, locationEvidence: locationEvidence, controller: smartSearch, snapshot: snapshot,
            key: key,
            contentKey: contentKey, visualKey: visualKey, cacheKey: cacheKey, libraryIsSettled: libraryIsSettled,
            cacheContentIsSettled: cacheContentIsSettled,
            indexedAssetCount: indexedAssetCount, searchEvidence: searchEvidence, cacheAccess: cacheAccess)
        failedKey = nil
        if input?.contentKey != waitingForPlaceKey { waitingForPlaceKey = nil }
        retryCount = 0
        if observer == nil {
            let updates = runtimeState.updates()
            observer = Task { [weak self] in
                for await snapshot in updates {
                    guard !Task.isCancelled, let self else { return }
                    self.conditionsChanged(snapshot)
                }
            }
        }
        prepareCacheIfNeeded()
        schedule(after: debounce)
    }

    /// Photos of `previous` that `current` removed or changed as suggestions see them. Consecutive timelines
    /// share long unchanged runs at both ends; only the differing middle is indexed. Each timeline must hold a
    /// photo once, as `TimelineContentProjection` guarantees for both hosts.
    nonisolated static func changedPhotos(
        from previous: [TimelineSection], to current: [TimelineSection]
    ) -> Set<PhotoUID> {
        let old = previous.flatMap(\.items)
        let new = current.flatMap(\.items)
        func same(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
            lhs == rhs
                || SmartSearchDiscoveryPersistence.suggestionItem(lhs)
                    == SmartSearchDiscoveryPersistence.suggestionItem(rhs)
        }
        var prefix = 0
        while prefix < old.count, prefix < new.count, same(old[prefix], new[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            same(old[old.count - 1 - suffix], new[new.count - 1 - suffix])
        {
            suffix += 1
        }
        let remaining = Dictionary(
            new[prefix..<(new.count - suffix)].map { ($0.uid, SmartSearchDiscoveryPersistence.suggestionItem($0)) },
            uniquingKeysWith: { first, _ in first })
        var changed = Set<PhotoUID>()
        for item in old[prefix..<(old.count - suffix)]
        where remaining[item.uid] != SmartSearchDiscoveryPersistence.suggestionItem(item) {
            changed.insert(item.uid)
        }
        return changed
    }

    private static func visualEvidenceKey(timelineRevision: UInt64, snapshot: MLSmartSearchSnapshot?) -> String {
        SmartSearchDiscoveryModel.visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot,
            indexingKey: snapshot?.isVisualIndexComplete == true ? "complete" : "pending")
    }

    private static func permitsAutomaticGeneration(_ snapshot: MLSmartSearchSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return snapshot.permitsAutomaticSuggestionGeneration || snapshot.permitsAutomaticSuggestionMetadata
    }

    /// Called by account/scope teardown before its controllers and stores are retired.
    public func reset() {
        generation &+= 1
        task?.cancel()
        observer?.cancel()
        cacheTask?.cancel()
        cacheTask = nil
        cacheGeneration &+= 1
        preparedCacheKey = nil
        cacheAccess = nil
        contentFingerprint = nil
        assetFingerprint = nil
        pendingPersistenceKey = nil
        failedPersistenceKey = nil
        persistenceWriteFailures = 0
        task = nil
        observer = nil
        input = nil
        libraryRows.removeAll()
        completedKey = nil
        failedKey = nil
        waitingForPlaceKey = nil
        evidenceKey = nil
        evidence = nil
        retryCount = 0
        isRefreshing = false
        discovery = makeModel()
    }

    private static func permitsRefresh(_ snapshot: LibraryRuntimeSnapshot) -> Bool {
        snapshot.executionOpportunity == .foregroundActive
            && !snapshot.isLowPowerMode
            && snapshot.thermalLevel < .serious
            && snapshot.memoryPressure == .normal
            && snapshot.memoryHeadroom != .constrained && snapshot.memoryHeadroom != .critical
            && !snapshot.hasActiveUserInteraction && !snapshot.hasVisibleMediaDemand
            && snapshot.activeVideoPlaybackCount == 0 && snapshot.activeUserTransferCount == 0
            && snapshot.activeSearchCount == 0
    }

    private func conditionsChanged(_ snapshot: LibraryRuntimeSnapshot) {
        let wasEligible = eligible
        if snapshot.memoryPressure != .normal || snapshot.memoryHeadroom >= .constrained {
            discardEvidence()
            if cacheTask != nil {
                cacheGeneration &+= 1
                cacheTask?.cancel()
                cacheTask = nil
                preparedCacheKey = nil
            }
        } else {
            prepareCacheIfNeeded()
        }
        eligible =
            input?.libraryIsSettled == true && input?.cacheContentIsSettled == true
            && Self.permitsAutomaticGeneration(input?.snapshot)
            && Self.permitsRefresh(snapshot)
        if !eligible {
            task?.cancel()
        } else if !wasEligible {
            failedKey = nil
            retryCount = 0
            prepareCacheIfNeeded()
            schedule(after: debounce)
        }
    }

    private func discardEvidence() {
        evidence = nil
        evidenceKey = nil
        pendingPersistenceKey = nil
    }

    private static func persistedModelKey(_ input: Input) -> String {
        persistedModelKey(input.snapshot)
    }

    private static func persistedModelKey(_ snapshot: MLSmartSearchSnapshot?) -> String {
        "\(snapshot?.isEnabled == true)|"
            + SmartSearchDiscoveryModel.visualEvidenceKey(
                timelineRevision: 0, snapshot: snapshot, indexingKey: "persisted")
    }

    private struct PreparedCache: Sendable {
        let fingerprint: Data?
        let assetFingerprint: Data?
        let saved: SmartSearchDiscoveryPersistence?
        let snapshot: SmartSearchDiscoveryModel.PersistedSnapshot?
        let exact: Bool
        let reusesEvidence: Bool
    }

    /// Hydrate saved rows even while Search is active. This performs no inference or geocoding.
    private func prepareCacheIfNeeded() {
        guard cacheTask == nil, let input, input.cacheContentIsSettled, preparedCacheKey != input.cacheKey else {
            return
        }
        guard let load = input.cacheAccess, input.sections.contains(where: { !$0.items.isEmpty }) else {
            preparedCacheKey = input.cacheKey
            return
        }
        let runtime = runtimeState.snapshot()
        guard runtime.memoryPressure == .normal, runtime.memoryHeadroom < .constrained else { return }
        // The first restore is worth a pass over every photo. Later checks of changed content wait while the device
        // saves energy or is hot; `conditionsChanged` prepares again when that ends.
        guard !discovery.hasComputed || (!runtime.isLowPowerMode && runtime.thermalLevel < .serious) else { return }
        let owner = cacheGeneration
        let modelKey = Self.persistedModelKey(input)
        cacheTask = Task(priority: .utility) { [weak self] in
            let started = ContinuousClock.now
            var access = await load()
            let data = access?.data
            var prepared = await SmartSearchDiscoveryModel.background {
                Result { () throws -> PreparedCache in
                    try Task.checkCancellation()
                    var saved: SmartSearchDiscoveryPersistence?
                    if let data {
                        do {
                            let decoded = try PropertyListDecoder().decode(
                                SmartSearchDiscoveryPersistence.self, from: data)
                            let evidenceComplete = decoded.hasCompleteEvidence(
                                requiresVisualEvidence: SmartSearchDiscoveryModel.visualConceptsAvailable(
                                    input.snapshot))
                            if decoded.version == SmartSearchDiscoveryPersistence.version, decoded.modelKey == modelKey,
                                evidenceComplete
                            {
                                saved = decoded
                            } else {
                                PhotoDiagnostics.shared.emitDebug(
                                    "SearchSuggestions",
                                    [
                                        "cache": "payloadRejected",
                                        "versionMatches":
                                            "\(decoded.version == SmartSearchDiscoveryPersistence.version)",
                                        "modelMatches": "\(decoded.modelKey == modelKey)",
                                        "evidenceComplete": "\(evidenceComplete)",
                                    ])
                            }
                        } catch {
                            PhotoDiagnostics.shared.increment("ml.suggestions.snapshotDecodeFailed")
                        }
                    }
                    guard let saved else {
                        return PreparedCache(
                            fingerprint: nil, assetFingerprint: nil, saved: nil, snapshot: nil, exact: false,
                            reusesEvidence: false)
                    }
                    let fingerprints = try SmartSearchDiscoveryPersistence.fingerprints(
                        sections: input.sections, favorites: input.favorites, coordinates: input.coordinates)
                    try Task.checkCancellation()
                    let exact = saved.fingerprint == fingerprints.content
                    return PreparedCache(
                        fingerprint: fingerprints.content, assetFingerprint: fingerprints.assets, saved: saved,
                        snapshot: exact ? saved.snapshot : nil, exact: exact,
                        reusesEvidence: exact || saved.assetFingerprint == fingerprints.assets)
                }
            }
            if let lease = access, !(await lease.isCurrent()) {
                // Decoding can outlive a model/index reset. Retire the read result as well as its writer.
                prepared = .success(
                    PreparedCache(
                        fingerprint: nil, assetFingerprint: nil, saved: nil, snapshot: nil, exact: false,
                        reusesEvidence: false))
                access = await load()
            }
            guard let self, owner == self.cacheGeneration, !Task.isCancelled,
                self.input?.cacheKey == input.cacheKey
            else { return }
            self.cacheTask = nil
            self.preparedCacheKey = input.cacheKey
            // Do not retain a second copy of the serialized payload alongside the decoded rows.
            self.cacheAccess = access.map {
                MLSearchSuggestionCacheAccess(data: nil, isCurrent: $0.isCurrent, save: $0.save)
            }
            if access != nil {
                self.failedPersistenceKey = nil
                self.persistenceWriteFailures = 0
            }
            switch prepared {
            case .success(let prepared):
                let outcome =
                    access == nil
                    ? "unavailable"
                    : access?.data == nil
                        ? "missing"
                        : prepared.saved == nil ? "incompatible" : prepared.exact ? "restored" : "contentChanged"
                Self.recordPersistence(action: "restore", result: outcome, started: started)
                self.contentFingerprint = prepared.fingerprint
                self.assetFingerprint = prepared.assetFingerprint
                PhotoDiagnostics.shared.emitDebug(
                    "SearchSuggestions",
                    [
                        "cache": "prepared", "lease": "\(access != nil)", "payload": "\(prepared.saved != nil)",
                        "exactContent": "\(prepared.exact)",
                    ])
                if let saved = prepared.saved {
                    self.discovery.restorePlaceNames(from: saved.snapshot)
                    if let snapshot = prepared.snapshot {
                        self.discovery.restore(
                            snapshot,
                            content: SmartSearchContentIdentity(
                                timelineRevision: input.revision, favoriteUIDs: input.favorites),
                            isExactContent: prepared.exact)
                    }
                    let runtime = self.runtimeState.snapshot()
                    if prepared.reusesEvidence, runtime.memoryPressure == .normal, runtime.memoryHeadroom < .constrained
                    {
                        self.evidence = saved.evidence
                        self.evidenceKey = saved.evidence == nil ? nil : input.visualKey
                    }
                    if prepared.exact { self.completedKey = input.contentKey }
                    if prepared.exact { PhotoDiagnostics.shared.increment("ml.suggestions.snapshotRestored") }
                }
            case .failure(let error):
                Self.recordPersistence(action: "restore", result: "failed", started: started)
                if !(error is CancellationError) {
                    PhotoDiagnostics.shared.increment("ml.suggestions.snapshotPreparationFailed")
                }
            }
            self.schedule(after: self.debounce)
        }
    }

    private func persistCompletedSuggestions(_ input: Input) async -> Bool {
        guard input.cacheAccess != nil else { return true }
        guard let access = cacheAccess, let fingerprint = contentFingerprint, let assets = assetFingerprint,
            let snapshot = discovery.persistedSnapshot(), !Task.isCancelled,
            self.input?.contentKey == input.contentKey
        else { return false }
        pendingPersistenceKey = input.contentKey
        let started = ContinuousClock.now
        var saved = SmartSearchDiscoveryPersistence(
            version: SmartSearchDiscoveryPersistence.version, modelKey: Self.persistedModelKey(input),
            fingerprint: fingerprint, snapshot: snapshot,
            evidence: evidenceKey == input.visualKey ? evidence : nil)
        saved.assetFingerprint = assets
        let encoded = await SmartSearchDiscoveryModel.background { [saved] in Result { try saved.encoded() } }
        guard !Task.isCancelled, self.input?.contentKey == input.contentKey else { return false }
        do {
            try await access.save(encoded.get())
            guard !Task.isCancelled, self.input?.contentKey == input.contentKey else { return false }
            pendingPersistenceKey = nil
            failedPersistenceKey = nil
            persistenceWriteFailures = 0
            Self.recordPersistence(action: "save", result: "saved", started: started)
            PhotoDiagnostics.shared.emitDebug(
                "SearchSuggestions", ["cache": "saved", "rows": "\(snapshot.candidates.count)"])
            return true
        } catch is CancellationError {
            return false
        } catch MLSmartSearchQueryError.staleEpoch {
            guard !Task.isCancelled, self.input?.cacheKey == input.cacheKey else { return false }
            // Reacquire authority and evidence together. Never attach an old scan to a new index lease.
            PhotoDiagnostics.shared.increment("ml.suggestions.snapshotWriteSuperseded")
            Self.recordPersistence(action: "save", result: "superseded", started: started)
            pendingPersistenceKey = nil
            discardEvidence()
            preparedCacheKey = nil
            cacheAccess = nil
            contentFingerprint = nil
            assetFingerprint = nil
            prepareCacheIfNeeded()
        } catch {
            guard !Task.isCancelled, self.input?.cacheKey == input.cacheKey else { return false }
            PhotoDiagnostics.shared.increment("ml.suggestions.snapshotWriteFailed")
            Self.recordPersistence(action: "save", result: "failed", started: started)
            persistenceWriteFailures += 1
            if persistenceWriteFailures >= 4 {
                failedPersistenceKey = input.cacheKey
                PhotoDiagnostics.shared.increment("ml.suggestions.persistenceRetryExhausted")
                Self.recordPersistence(action: "save", result: "exhausted", started: started)
            }
        }
        return false
    }

    private static func recordPersistence(action: String, result: String, started: ContinuousClock.Instant) {
        let elapsed = started.duration(to: .now).components
        PhotoDiagnostics.shared.emitSupport(
            "SearchSuggestions",
            [
                "action": action, "result": result,
                "durationMs": "\(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)",
            ])
    }

    private func schedule(after delay: Duration) {
        guard task == nil, eligible, let input, completedKey != input.contentKey,
            completedKey != input.generationKey, failedKey != input.key, waitingForPlaceKey != input.contentKey
        else { return }
        guard failedPersistenceKey != input.cacheKey else { return }
        guard input.cacheAccess == nil || preparedCacheKey == input.cacheKey else { return }
        let generation = generation
        task = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) } catch {}
            guard let self, self.generation == generation else { return }
            var succeeded = false
            let current = self.input
            if !Task.isCancelled, self.eligible, let current {
                self.isRefreshing = true
                succeeded = await self.refresh(current)
            }
            guard self.generation == generation else { return }
            self.isRefreshing = false
            self.task = nil
            guard let current, !Task.isCancelled else {
                self.schedule(after: self.debounce)
                return
            }
            guard current.contentKey == self.input?.contentKey else {
                self.schedule(after: self.debounce)
                return
            }
            guard self.waitingForPlaceKey != current.contentKey else { return }
            if succeeded {
                self.completedKey = current.generationKey
            } else if current.key != self.input?.key {
                self.schedule(after: self.debounce)
            } else {
                let delays = self.retryDelays
                if self.pendingPersistenceKey == current.contentKey {
                    guard self.failedPersistenceKey != current.cacheKey else { return }
                    let retry = min(delays.count - 1, max(0, self.persistenceWriteFailures - 1))
                    self.schedule(after: delays[retry])
                    return
                }
                guard self.retryCount < delays.count else {
                    PhotoDiagnostics.shared.increment("ml.suggestions.evidenceRetryExhausted")
                    self.failedKey = current.key
                    return
                }
                let delay = delays[self.retryCount]
                self.retryCount += 1
                self.schedule(after: delay)
            }
        }
    }

    private func refresh(_ input: Input) async -> Bool {
        guard input.cacheContentIsSettled else { return false }
        if pendingPersistenceKey == input.contentKey {
            return await persistCompletedSuggestions(input)
        }
        guard Self.permitsAutomaticGeneration(input.snapshot), input.libraryIsSettled else { return false }
        if input.snapshot?.permitsAutomaticSuggestionGeneration == false {
            // Keep existing valid rows. An unavailable model only needs this cheap path for an empty landing.
            if discovery.forYou.isEmpty && discovery.chips.isEmpty {
                await discovery.refresh(
                    sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
                    coordinates: [], snapshot: input.snapshot, indexedAssetCount: { 0 }, search: nil,
                    includeVisualConcepts: false, metadataOnly: true)
            } else {
                // This pass never replaces invalidated rows. The kept rows are final, so a selection stops waiting.
                discovery.settleRetainedRows()
            }
            return !Task.isCancelled && self.input?.key == input.key
        }
        if input.cacheAccess != nil, contentFingerprint == nil || assetFingerprint == nil {
            let prepared = await SmartSearchDiscoveryModel.background {
                Result {
                    try SmartSearchDiscoveryPersistence.fingerprints(
                        sections: input.sections, favorites: input.favorites, coordinates: input.coordinates)
                }
            }
            guard !Task.isCancelled, self.input?.contentKey == input.contentKey else { return false }
            do {
                let fingerprints = try prepared.get()
                contentFingerprint = fingerprints.content
                assetFingerprint = fingerprints.assets
            } catch is CancellationError {
                return false
            } catch {
                PhotoDiagnostics.shared.increment("ml.suggestions.snapshotPreparationFailed")
                return false
            }
        }
        #if DEBUG
            curationRunCount += 1
        #endif
        let previous = discovery
        // Build later updates privately. Entering Search during cancellation keeps the published rows usable.
        let model =
            previous.hasComputed ? makeModel() : previous
        model.reusePlaceNames(from: previous)
        #if DEBUG
            model.metadataDidRunForTesting = { [weak self] in self?.metadataPassCount += 1 }
            model.clusteringDidRunForTesting = { [weak self] in self?.placeClusteringCount += 1 }
        #endif
        let covered = await input.indexedAssetCount()
        guard !Task.isCancelled else { return false }
        // Publish local metadata first. Place-name requests must not delay the evidence gate and previews.
        await model.refresh(
            sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
            coordinates: input.coordinates, snapshot: input.snapshot, indexedAssetCount: { covered },
            search: nil, includeVisualConcepts: false,
            metadataOnly: SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot),
            locationEvidence: input.locationEvidence
        )
        guard !Task.isCancelled else { return false }
        if model.lastRefreshWaitsForPlaces {
            waitingForPlaceKey = input.contentKey
            return false
        }
        guard SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot), covered > 0,
            let searchEvidence = input.searchEvidence
        else {
            if !SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot)
                || !previous.forYou.contains(where: { $0.kind == .concept })
                || previous.computedContent != model.computedContent
            {
                discovery = model
                // Metadata-only startup is not a completed visual presentation to persist.
                if model.lastRefreshCompleted { return await persistCompletedSuggestions(input) }
            }
            return true
        }
        if evidenceKey != input.visualKey {
            do {
                PhotoDiagnostics.shared.emitDebug("SearchSuggestions", ["event": "evidenceScanStarted"])
                let fresh = try await searchEvidence()
                guard !Task.isCancelled, self.input?.visualKey == input.visualKey,
                    SmartSearchDiscoveryModel.visualConceptsAvailable(self.input?.snapshot),
                    Self.permitsRefresh(runtimeState.snapshot()), self.input?.libraryIsSettled == true
                else { return false }
                evidence = fresh
                evidenceKey = input.visualKey
                PhotoDiagnostics.shared.emitDebug(
                    "SearchSuggestions", ["event": "evidenceScanCompleted", "assets": "\(fresh.scannedUIDs.count)"])
            } catch is CancellationError {
                return false
            } catch {
                PhotoDiagnostics.shared.increment("ml.suggestions.evidenceBatchFailed")
                return false
            }
        }
        guard let evidence else { return false }
        let matchesByPrompt = Dictionary(
            uniqueKeysWithValues: evidence.results.map { ($0.queryText, $0.results.map(\.uid)) })
        let replacesEmptyPreviews = !previous.forYou.contains {
            !$0.representativeUIDs.isEmpty || $0.kind == .concept || $0.kind == .place || $0.kind == .placeSeason
        }
        await model.refresh(
            sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
            coordinates: input.coordinates, snapshot: input.snapshot, indexedAssetCount: { covered },
            search: { prompt, limit in
                guard let matches = matchesByPrompt[prompt] else { throw MLSmartSearchQueryError.unavailable }
                return Array(matches.prefix(max(0, limit)))
            },
            allowsRepresentative: { evidence.scannedUIDs.contains($0) },
            previewsDidPublish: {
                // First usable previews need not wait for geocoding. Keep existing places even without preview photos.
                guard replacesEmptyPreviews, !Task.isCancelled, self.input?.contentKey == input.contentKey,
                    Self.permitsRefresh(self.runtimeState.snapshot()),
                    model.forYou.contains(where: { !$0.representativeUIDs.isEmpty })
                else { return }
                self.discovery = model
            },
            locationEvidence: input.locationEvidence
        )
        guard !Task.isCancelled else { return false }
        if model.lastRefreshWaitsForPlaces {
            waitingForPlaceKey = input.contentKey
            return false
        }
        guard model.lastRefreshCompleted else { return false }
        discovery = model
        return await persistCompletedSuggestions(input)
    }

    deinit {
        task?.cancel()
        observer?.cancel()
        cacheTask?.cancel()
    }
}
