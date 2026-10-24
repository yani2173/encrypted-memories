import CryptoKit
import Foundation
import MediaLocationCore
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchCore
@testable import MLSearchFeature

@MainActor @Suite struct SmartSearchDiscoverySchedulerTests {
    /// The production retry delays scaled from seconds to milliseconds, for a test that exhausts the save budget.
    private static let shortRetryDelays: [Duration] = [.milliseconds(1), .milliseconds(2), .milliseconds(4)]

    #if DEBUG
        @Test func crawlingSearchAndSupportShareBoundedClassifications() async throws {
            let index = PhotoLocationIndex()
            var time: TimeInterval = 0
            index.nowForTesting = { time }
            func points(_ range: Range<Int>) -> [PhotoCoordinate] {
                range.map {
                    PhotoCoordinate(
                        uid: PhotoUID(volumeID: "test", nodeID: "search-crawl-\($0)"),
                        latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
                }
            }
            index.replaceAll(points(0..<1000))
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
                _, _ in
                "Test place"
            }
            defer { scheduler.reset() }
            let items = points(0..<2050).map { PhotoItem(uid: $0.uid, captureTime: $0.date, mediaType: "image/jpeg") }
            let sections = [TimelineSection(id: "all", date: items[0].captureTime, title: "", items: items)]
            var analyzed: [ObjectIdentifier: PhotoPlaceEvidence] = [:]
            func curate() async {
                _ = index.placeEvidence()
                await index.waitForPlaceEvidenceForTesting()
                let evidence = index.placeEvidence()
                analyzed[ObjectIdentifier(evidence)] = evidence
                scheduler.update(
                    sections: sections, timelineRevision: 1, favoriteUIDs: [], coordinates: index.coordinates,
                    smartSearch: nil, placeRevision: index.placeRevision, locationEvidence: evidence)
                await scheduler.waitForRefreshForTesting()
            }
            await curate()
            for batch in 1...20 {
                time = Double(batch)
                index.merge(points((1000 + (batch - 1) * 50)..<(1000 + batch * 50)))
                await curate()
                let count = scheduler.discovery.forYou.filter { $0.kind == .place }.reduce(0) {
                    $0 + ($1.matchCount ?? 0)
                }
                #expect(count == (batch < 10 ? 1000 : batch < 20 ? 1500 : 2000))
            }
            #expect(analyzed.values.reduce(0) { $0 + $1.analysisStartsForTesting } == 3)
            time = 40
            index.merge(points(2000..<2050))
            await curate()
            let support = await index.photoPlaceSupportSnapshot()
            #expect(support.first?.photoCount == 2000, "Support must share the last classified snapshot during a crawl")
            #expect(analyzed.values.reduce(0) { $0 + $1.analysisStartsForTesting } == 3)
            index.updateScanProgress(PhotoLocationScanProgress(phase: .completed))
            await curate()
            #expect(analyzed.values.reduce(0) { $0 + $1.analysisStartsForTesting } == 4)
            #expect((await index.photoPlaceSupportSnapshot()).first?.photoCount == 2050)
        }
    #endif

    @Test(arguments: [
        "selection", "missingModel", "download", "modelFailure", "nativeFailure", "nativePartialFailure",
        "nativeOnlyFailure",
    ])
    func blockedIndexPublishesOnlyMetadataAndRecovers(state: String) async throws {
        let failure = MLSmartSearchFailure(kind: .storage, isRetryable: true, debugDescription: "fixture")
        let complete = visualSnapshot(settled: 8, ready: true)
        let phase: MLSmartSearchPhase
        switch state {
        case "selection": phase = .selectingModel
        case "missingModel": phase = .notInstalled(downloadable: false)
        case "download": phase = .downloading(MLModelTransferProgress(bytesReceived: 0, totalBytes: 100))
        case "modelFailure": phase = .failed(failure)
        case "nativePartialFailure":
            phase = .indexing(
                MLIndexProgress(
                    phase: .indexing, descriptor: .init(identifier: "fixture", version: 1, embeddingDimension: 3),
                    totalAssets: 8, indexed: 4))
        case "nativeOnlyFailure": phase = .disabled
        default: phase = complete.phase
        }
        let blocked = MLSmartSearchSnapshot(
            isEnabled: true, selectedModelID: state != "nativeOnlyFailure" ? MLModelID("visual-model") : nil,
            phase: phase,
            installedModelBytes: 0, availableModels: [], isSearchAvailable: false,
            indexingState: state.hasPrefix("native") ? .failed(failure) : .idle)
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        defer { scheduler.reset() }
        func apply(_ snapshot: MLSmartSearchSnapshot, librarySettled: Bool = true) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)),
                coordinates: items.map {
                    PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
                }, snapshot: snapshot, indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) },
                libraryIsSettled: librarySettled, cacheAccess: { await cache.access() })
        }
        apply(blocked, librarySettled: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!scheduler.discovery.hasComputed, "thumbnail and initial library work retain priority")
        apply(blocked)
        for _ in 0..<200 where !scheduler.discovery.hasComputed || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!scheduler.discovery.forYou.isEmpty, "a blocked model must not hide local metadata forever")
        #expect(scheduler.discovery.forYou.allSatisfy { $0.kind != .concept })
        if blocked.selectedModelID != nil {
            #expect(scheduler.discovery.forYou.allSatisfy { $0.representativeUIDs.isEmpty })
        }
        #expect(await probe.calls == 0, "metadata fallback must not scan embeddings")
        #expect(await probe.placeCalls == 0, "metadata fallback must not start geocoding")
        #expect(await cache.saves == 0, "partial metadata must not replace the completed encrypted collection")
        apply(complete)
        for _ in 0..<200 where await cache.saves == 0 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1, "recovery must run full curation even when coverage was already complete")
        #expect(await cache.saves == 1)
        #expect(!scheduler.discovery.forYou.flatMap(\.representativeUIDs).isEmpty)
    }

    @Test func missingModelStillYieldsToActiveNativeIndexing() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let item = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(), mediaType: "image/jpeg")
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: [item])],
            timelineRevision: 1, favoriteUIDs: [item.uid], coordinates: [],
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("visual-model"),
                phase: .notInstalled(downloadable: false), installedModelBytes: 0, availableModels: [],
                isSearchAvailable: false,
                indexingState: .indexing(
                    MLSmartSearchAggregateProgress(
                        totalWorkUnits: 100, settledWorkUnits: 1, permanentlyUnavailableAssets: 0))),
            indexedAssetCount: { 0 }, searchEvidence: nil)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!scheduler.discovery.hasComputed)
    }

    @Test func unknownContentCannotGenerateWithoutACacheProvider() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let item = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(), mediaType: "image/jpeg")
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: [item])],
            timelineRevision: 1, favoriteUIDs: [], coordinates: [], snapshot: .disabled,
            indexedAssetCount: { 0 }, searchEvidence: nil, cacheContentIsSettled: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!scheduler.discovery.hasComputed, "unknown favorites are not an authoritative empty set")
    }

    @Test func unknownContentCancelsAnInFlightEvidenceScan() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = CancellationProbe()
        func apply(settled: Bool) {
            scheduler.update(
                sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { try await probe.wait() }, cacheContentIsSettled: settled)
        }
        apply(settled: true)
        for _ in 0..<200 where !(await probe.started) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await probe.started)
        apply(settled: false)
        for _ in 0..<200 where !(await probe.cancelled) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.cancelled, "losing content authority must stop work before publication or persistence")
    }

    @Test(arguments: [false, true]) func unknownFavoritesPreserveTheSavedCollectionUntilRecovery(
        knownEmpty: Bool
    ) async throws {
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let favorites: Set<PhotoUID> = knownEmpty ? [] : Set(items.map(\.uid))
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, known: Bool) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: known ? favorites : [], coordinates: [], snapshot: .disabled,
                indexedAssetCount: { 0 }, searchEvidence: nil, cacheContentIsSettled: known,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, known: true)
        for _ in 0..<200 where await cache.saves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(await cache.data)
        let expected = first.discovery.forYou
        first.reset()
        let second = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second, known: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!second.discovery.hasComputed)
        #expect(await cache.data == original)
        #expect(await cache.saves == 1)
        apply(second, known: true)
        for _ in 0..<200 where !second.discovery.hasComputed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(second.discovery.hasComputed, "a successful empty favorite response is still authoritative")
        #expect(second.discovery.forYou == expected)
        #expect(await cache.data == original)
        #expect(await cache.saves == 1, "recovery must restore, not replace, the saved collection")
    }

    @Test(arguments: [false, true]) func invalidRowsDisappearEvenWhenRefreshIsBlocked(policyChange: Bool) async throws {
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let runtime = LibraryRuntimeState()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: policyChange ? .disabled : visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!scheduler.discovery.forYou.isEmpty)
        runtime.update { $0.activeSearchCount = 1 }
        let remaining = policyChange ? items : []
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: remaining)],
            timelineRevision: policyChange ? 1 : 2, favoriteUIDs: Set(remaining.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 }, searchEvidence: nil,
            libraryIsSettled: false)
        #expect(
            scheduler.discovery.forYou.isEmpty,
            "deletions and a newly enabled sensitive policy invalidate old rows before background work")
        #expect(scheduler.discovery.chips.isEmpty)
    }

    /// Invalidated rows are hidden at once, but only the replacement refresh proves that a selected suggestion is
    /// gone. Until then both hosts must keep it; `.drop` cleared the iOS query and re-ran the macOS title as text.
    @Test(arguments: ["favorites", "deletion"]) func invalidatedSelectionWaitsForItsReplacement(
        change: String
    ) async throws {
        let start = Date(timeIntervalSince1970: 1_718_413_200)
        let items = (0..<20).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "item-\($0)"),
                captureTime: start.addingTimeInterval(Double($0) * 600), mediaType: "image/jpeg")
        }
        let favorites = Set(items.prefix(8).map(\.uid))
        let runtime = LibraryRuntimeState()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: start, title: "", items: items)], timelineRevision: 1,
            favoriteUIDs: favorites, coordinates: [], smartSearch: nil)
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = SmartSearchContentIdentity(timelineRevision: 1, favoriteUIDs: favorites)
        let selected = try #require(
            scheduler.discovery.displayableSuggestions(content: before, snapshot: nil).first {
                $0.kind == .favorites && $0.matchingUIDs == favorites
            })

        // The user keeps the selected results open, so the replacement refresh waits.
        let search = runtime.beginActivity(.search)
        let removed = items[0].uid
        let remaining = change == "deletion" ? Array(items.dropFirst()) : items
        let revision: UInt64 = change == "deletion" ? 2 : 1
        let changedFavorites = favorites.subtracting([removed])
        scheduler.update(
            sections: [TimelineSection(id: "all", date: start, title: "", items: remaining)],
            timelineRevision: revision, favoriteUIDs: changedFavorites, coordinates: [], smartSearch: nil)
        let after = SmartSearchContentIdentity(timelineRevision: revision, favoriteUIDs: changedFavorites)
        #expect(
            !scheduler.discovery.displayableSuggestions(content: after, snapshot: nil).contains {
                $0.id == selected.id
            }, "the invalidated row stays hidden")
        #expect(scheduler.discovery.rebind(selected, content: after, snapshot: nil) == .pending)

        search.end()
        for _ in 0..<200 where scheduler.discovery.settledContent != after {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .keep(let fresh) = scheduler.discovery.rebind(selected, content: after, snapshot: nil) else {
            Issue.record("the selected suggestion must rebind to its replacement")
            return
        }
        #expect(fresh.matchingUIDs == changedFavorites)
    }

    /// A metadata-only pass keeps its remaining rows and never replaces invalidated ones, so the selection must
    /// not wait for a refresh that cannot come. This also holds when the model fails after the invalidation.
    @Test(arguments: [false, true]) func unavailableModelDropsAnInvalidatedSelection(
        failsAfterInvalidation: Bool
    ) async throws {
        let start = Date(timeIntervalSince1970: 1_718_413_200)
        let items = (0..<20).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "item-\($0)"),
                captureTime: start.addingTimeInterval(Double($0) * 600),
                mediaType: $0 % 4 == 0 ? "video/mp4" : "image/jpeg")
        }
        let favorites = Set(items.prefix(8).map(\.uid))
        let missingModel = MLSmartSearchSnapshot(
            isEnabled: true, selectedModelID: MLModelID("visual-model"),
            phase: .notInstalled(downloadable: false), installedModelBytes: 0, availableModels: [],
            isSearchAvailable: false, indexingState: .idle)
        let complete = visualSnapshot(settled: 20, ready: true)
        try #require(!missingModel.permitsAutomaticSuggestionGeneration)
        try #require(missingModel.permitsAutomaticSuggestionMetadata)
        try #require(complete.permitsAutomaticSuggestionGeneration)
        let runtime = LibraryRuntimeState()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        func apply(favorites: Set<PhotoUID>, snapshot: MLSmartSearchSnapshot) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: start, title: "", items: items)], timelineRevision: 1,
                favoriteUIDs: favorites, coordinates: [], snapshot: snapshot, indexedAssetCount: { 0 },
                searchEvidence: nil)
        }
        let initial = failsAfterInvalidation ? complete : missingModel
        apply(favorites: favorites, snapshot: initial)
        for _ in 0..<200 where scheduler.discovery.settledContent == nil || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = SmartSearchContentIdentity(timelineRevision: 1, favoriteUIDs: favorites)
        let selected = try #require(
            scheduler.discovery.displayableSuggestions(content: before, snapshot: initial).first {
                $0.kind == .favorites
            })

        let changedFavorites = favorites.subtracting([items[0].uid])
        let after = SmartSearchContentIdentity(timelineRevision: 1, favoriteUIDs: changedFavorites)
        if failsAfterInvalidation {
            // The selection waits for a full refresh, but the model fails before that refresh can run.
            let search = runtime.beginActivity(.search)
            apply(favorites: changedFavorites, snapshot: complete)
            #expect(scheduler.discovery.rebind(selected, content: after, snapshot: complete) == .pending)
            apply(favorites: changedFavorites, snapshot: missingModel)
            search.end()
        } else {
            apply(favorites: changedFavorites, snapshot: missingModel)
        }
        for _ in 0..<200 where scheduler.discovery.settledContent == nil || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(
            !scheduler.discovery.displayableSuggestions(content: after, snapshot: missingModel).isEmpty,
            "the metadata-only pass keeps the remaining valid rows")
        #expect(scheduler.discovery.rebind(selected, content: after, snapshot: missingModel) == .drop)
    }

    @Test func emptyLibraryRemovesPreviouslyPublishedConcepts() async throws {
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(scheduler.discovery.forYou.contains { $0.kind == .concept })
        scheduler.update(
            sections: [], timelineRevision: 2, favoriteUIDs: [], coordinates: [],
            snapshot: visualSnapshot(settled: 0, ready: true), indexedAssetCount: { 0 }, searchEvidence: nil)
        for _ in 0..<200 where scheduler.discovery.computedContent?.timelineRevision != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.forYou.isEmpty)
        #expect(scheduler.discovery.chips.isEmpty)
    }

    @Test func changedInventoryCannotReuseEvidenceFromAnotherSuggestionScope() async throws {
        let cache = SnapshotCache()
        let probe = EvidenceProbe()
        let items = (0..<9).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, count: Int) {
            let current = Array(items.prefix(count))
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: current)],
                timelineRevision: 1, favoriteUIDs: Set(current.map(\.uid)), coordinates: [],
                snapshot: visualSnapshot(settled: 9, ready: true), indexedAssetCount: { 9 },
                searchEvidence: { await probe.query(sensitive: items[0].uid, scanned: Set(current.map(\.uid))) },
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, count: 8)
        for _ in 0..<200 where await cache.saves < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.saves == 1)
        first.reset()
        let second = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second, count: 9)
        for _ in 0..<200 where await cache.saves < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(
            await probe.calls == 2,
            "a changed library scope needs fresh evidence even when the model index is unchanged")
    }

    @Test func sameCountLocationReplacementUpdatesSuggestions() async throws {
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
            latitude, _ in
            latitude > 45 ? "Vienna" : "Rome"
        }
        defer { scheduler.reset() }
        func apply(latitude: Double, placeRevision: Int) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: [],
                coordinates: items.map {
                    PhotoCoordinate(uid: $0.uid, latitude: latitude, longitude: 16, date: $0.captureTime)
                }, snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                placeRevision: placeRevision)
        }
        apply(latitude: 48, placeRevision: 1)
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(scheduler.discovery.forYou.contains { $0.title == "Vienna" })
        apply(latitude: 42, placeRevision: 2)
        for _ in 0..<200 where !scheduler.discovery.forYou.contains(where: { $0.title == "Rome" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.forYou.contains { $0.title == "Rome" })
        #expect(!scheduler.discovery.forYou.contains { $0.title == "Vienna" })
    }

    @Test func disablingMapAndPlacesRemovesPlaceSuggestionsButKeepsOtherRows() async throws {
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let coordinates = items.map {
            PhotoCoordinate(uid: $0.uid, latitude: 48, longitude: 16, date: $0.captureTime)
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
            _, _ in "Vienna"
        }
        defer { scheduler.reset() }
        func apply(enabled: Bool) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)),
                coordinates: MapAndPlacesPolicy.suggestionCoordinates(coordinates, enabled: enabled),
                snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil)
        }
        apply(enabled: true)
        for _ in 0..<200 where !scheduler.discovery.forYou.contains(where: { $0.title == "Vienna" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(scheduler.discovery.forYou.contains { $0.title == "Vienna" })
        apply(enabled: false)
        for _ in 0..<200 where scheduler.discovery.forYou.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!scheduler.discovery.forYou.contains { $0.title == "Vienna" })
        #expect(scheduler.discovery.forYou.contains { $0.kind == .favorites })
    }

    @Test func metadataSuggestionsSurviveRelaunchWithoutVisualEvidence() async throws {
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, reversed: Bool) {
            scheduler.update(
                sections: [
                    TimelineSection(id: "all", date: Date(), title: "", items: reversed ? items.reversed() : items)
                ],
                timelineRevision: reversed ? 1 : 50, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, reversed: false)
        for _ in 0..<200 where await cache.data == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.data != nil)
        let expected = first.discovery.forYou
        try #require(expected.contains { !$0.representativeUIDs.isEmpty })
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let second = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second, reversed: true)
        for _ in 0..<200 where !second.discovery.hasComputed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(second.discovery.forYou == expected)
        #expect(await cache.saves == 1, "restoration must not regenerate the collection")
    }

    @Test func retiredCacheReadCannotPublishAndReacquiresAuthority() async throws {
        let cache = SnapshotCache()
        let item = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(), mediaType: "image/jpeg")
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: [item])]
        func apply(_ scheduler: SmartSearchDiscoveryScheduler) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: [item.uid], coordinates: [],
                snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first)
        for _ in 0..<200 where await cache.saves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.saves == 1)
        first.reset()
        await cache.retireNextRead()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let second = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second)
        for _ in 0..<200 where await cache.reads < 3 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.reads == 3, "retired authority must be reacquired")
        #expect(!second.discovery.hasComputed, "retired bytes must never become visible")
        runtime.update { $0.activeSearchCount = 0 }
        for _ in 0..<200 where await cache.saves < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await cache.saves == 2, "the current lease must still permit a fresh completed snapshot")
        #expect(second.discovery.hasComputed)
    }

    @Test func contentFingerprintIgnoresTimelineOrderingButDetectsDeletion() throws {
        let now = Date()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: now, mediaType: "image/jpeg")
        }
        func fingerprint(_ items: [PhotoItem]) throws -> Data {
            try SmartSearchDiscoveryPersistence.fingerprint(
                sections: [TimelineSection(id: "all", date: now, title: "", items: items)],
                favorites: [], coordinates: [], now: now)
        }
        #expect(try fingerprint(items) == fingerprint(items.reversed()))
        #expect(try fingerprint(items) != fingerprint(Array(items.dropLast())))
    }

    /// Saved suggestions stay valid across the update only while both fingerprints keep their bytes.
    @Test func bothFingerprintsFromOnePassKeepTheSavedFormat() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let items = (0..<8).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "\(7 - $0)"), captureTime: now.addingTimeInterval(Double($0)),
                mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: now, title: "", items: items)]
        let favorites: Set = [items[2].uid]
        let coordinates = [PhotoCoordinate(uid: items[1].uid, latitude: 48.2, longitude: 16.3, date: now)]
        let both = try SmartSearchDiscoveryPersistence.fingerprints(
            sections: sections, favorites: favorites, coordinates: coordinates, now: now, calendar: calendar,
            locale: Locale(identifier: "de_AT"))

        #expect(
            both.content
                == (try SmartSearchDiscoveryPersistence.fingerprint(
                    sections: sections, favorites: favorites, coordinates: coordinates, now: now, calendar: calendar,
                    locale: Locale(identifier: "de_AT"))))
        #expect(both.assets == (try SmartSearchDiscoveryPersistence.assetFingerprint(sections: sections)))
        #expect(
            both.assets.map { String(format: "%02x", $0) }.joined()
                == "146fc7a30bf45d23de138afeb6608a3122c7594ff0a2b9e2da9755b6058eaabe")
    }

    @Test func changedPhotosMatchAComparisonOfTheWholeLibrary() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ index: Int, mediaType: String = "image/jpeg", duration: Double? = nil) -> PhotoItem {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "\(index)"), captureTime: base.addingTimeInterval(Double(index)),
                mediaType: mediaType, durationSeconds: duration)
        }
        func sections(_ items: [PhotoItem]) -> [TimelineSection] {
            stride(from: 0, to: items.count, by: 40).map {
                TimelineSection(id: "\($0)", date: base, title: "", items: Array(items[$0..<min($0 + 40, items.count)]))
            }
        }
        func wholeLibrary(_ previous: [PhotoItem], _ current: [PhotoItem]) -> Set<PhotoUID> {
            let index = Dictionary(
                current.map { ($0.uid, SmartSearchDiscoveryPersistence.suggestionItem($0)) },
                uniquingKeysWith: { first, _ in first })
            return Set(
                previous.filter { index[$0.uid] != SmartSearchDiscoveryPersistence.suggestionItem($0) }.map(\.uid))
        }
        let original = (0..<200).map { item($0) }
        var edited = original
        edited[100] = item(100, mediaType: "image/heic")
        var deletedAndAdded = original
        deletedAndAdded.remove(at: 57)
        deletedAndAdded.append(item(900))
        var reordered = original
        reordered.swapAt(10, 190)
        var learnedDuration = original
        learnedDuration[5] = item(5, duration: 12)
        let cases: [[PhotoItem]] = [
            original, Array(original.dropFirst(3)), original + [item(901), item(902)], [item(903)] + original,
            edited, deletedAndAdded, reordered, learnedDuration, original.reversed(), [],
        ]
        for current in cases {
            #expect(
                SmartSearchDiscoveryScheduler.changedPhotos(from: sections(original), to: sections(current))
                    == wholeLibrary(original, current))
            #expect(
                SmartSearchDiscoveryScheduler.changedPhotos(from: sections(current), to: sections(original))
                    == wholeLibrary(current, original))
        }
    }

    #if DEBUG
        @Test func metadataRowsAreBuiltOncePerLibraryContent() async throws {
            let probe = EvidenceProbe()
            let cache = SnapshotCache()
            let items = (0..<8).map {
                PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
            }
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
                _, _ in
                await probe.placeName()
            }
            defer { scheduler.reset() }
            // The saved fingerprint covers the content, so each step changes the content, not only a revision.
            func apply(revision: UInt64, library: [PhotoItem], latitude: Double) {
                scheduler.update(
                    sections: [TimelineSection(id: "all", date: Date(), title: "", items: library)],
                    timelineRevision: revision, favoriteUIDs: Set(items.map(\.uid)),
                    coordinates: library.map {
                        PhotoCoordinate(uid: $0.uid, latitude: latitude, longitude: 16.3, date: $0.captureTime)
                    }, snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                    searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) },
                    cacheAccess: { await cache.access() }, placeRevision: Int(latitude))
            }
            func waitForSave(_ count: Int) async throws {
                for _ in 0..<400 where await cache.saves < count || scheduler.isRefreshing {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try #require(await cache.saves == count)
            }

            apply(revision: 1, library: items, latitude: 48)
            try await waitForSave(1)
            #expect(scheduler.libraryRowBuildCount == 1, "the metadata pass and the full pass share one build")

            apply(revision: 1, library: items, latitude: 47)
            try await waitForSave(2)
            #expect(scheduler.libraryRowBuildCount == 1, "a place change keeps the library rows")

            apply(revision: 2, library: Array(items.dropLast()), latitude: 47)
            try await waitForSave(3)
            #expect(scheduler.libraryRowBuildCount == 2, "a library change builds new rows")
        }
    #endif

    @Test func lowPowerDefersCheckingSavedSuggestionsAgainstChangedContent() async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let runtime = LibraryRuntimeState()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        func apply(revision: UInt64) {
            let library = revision == 1 ? items : Array(items.dropLast())
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: library)],
                timelineRevision: revision, favoriteUIDs: [], coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) },
                cacheAccess: { await cache.access() })
        }
        apply(revision: 1)
        for _ in 0..<400 where await cache.saves < 1 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await cache.saves == 1)
        let reads = await cache.reads

        runtime.update { $0.isLowPowerMode = true }
        apply(revision: 2)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await cache.reads == reads, "changed content waits instead of reading every photo again")
        #expect(scheduler.discovery.hasComputed, "the shown rows stay")

        runtime.update { $0.isLowPowerMode = false }
        for _ in 0..<400 where await cache.saves < 2 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cache.reads > reads)
        #expect(await cache.saves == 2)
    }

    @Test func learnedVideoDurationDoesNotInvalidateSavedSuggestions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = PhotoItem(uid: .init(volumeID: "v", nodeID: "video"), captureTime: now, mediaType: "video/mp4")
        #expect(store.save([item]).succeeded)
        #expect(store.updateDurations([item.uid: 42.75]).succeeded)
        #expect(store.save([item]).succeeded)
        let restored = try store.load()
        #expect(restored.first?.durationSeconds == 42.75)
        func fingerprint(_ items: [PhotoItem]) throws -> Data {
            try SmartSearchDiscoveryPersistence.fingerprint(
                sections: [TimelineSection(id: "all", date: now, title: "", items: items)], favorites: [],
                coordinates: [], now: now)
        }
        #expect(
            try fingerprint(restored) == fingerprint([item]),
            "learned playback duration is absent from server rows and irrelevant to suggestions")
    }

    @Test(arguments: [0, 55]) func waitingWithCompletedWorkCanGenerateSuggestions(deferred: Int) async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let coverage = MLIndexCoverage(total: 100, indexed: 100, permanentlyUnindexable: 0)
        let progress = MLSmartSearchAggregateProgress(
            totalWorkUnits: 200, settledWorkUnits: 200 - deferred, permanentlyUnavailableAssets: 0,
            deferredWorkUnits: deferred)
        scheduler.update(
            sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("visual-model"), phase: .waiting(coverage),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true, indexingState: .waiting(progress)),
            indexedAssetCount: { 100 },
            searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        for _ in 0..<200 where await probe.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.calls == 1, "waiting is not active indexing and must not indefinitely suppress suggestions")
        // A retry quantum must not discard completed evidence or regenerate the same collection.
        scheduler.update(
            sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("visual-model"), phase: .waiting(coverage),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true, indexingState: .indexing(progress)
            ),
            indexedAssetCount: { 100 },
            searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 1)
    }

    @Test(arguments: [8, 50_000], [false, true]) func relaunchRestoresSuggestionsWhileSearchIsAlreadyActive(
        itemCount: Int, recoveringMemoryPressure: Bool
    ) async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<itemCount).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: String(format: "%064d", $0)), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let favorites = Set(items.map(\.uid))
        func apply(
            _ scheduler: SmartSearchDiscoveryScheduler, revision: UInt64,
            libraryIsSettled: Bool = true
        ) {
            scheduler.update(
                sections: sections, timelineRevision: revision, favoriteUIDs: favorites, coordinates: [],
                snapshot: visualSnapshot(settled: itemCount, ready: true), indexedAssetCount: { itemCount },
                searchEvidence: { await probe.query(sensitive: items[0].uid, scanned: Set(items.map(\.uid))) },
                libraryIsSettled: libraryIsSettled, cacheContentIsSettled: true,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, revision: 50)
        // The 50,000-photo pass takes minutes on a loaded machine; the limit only ends a hung test.
        try await waitUntilHangLimit { first.discovery.lastRefreshCompleted && !first.isRefreshing }
        try #require(first.discovery.lastRefreshCompleted && !first.isRefreshing)
        let expected = first.discovery.forYou
        try #require(expected.contains { !$0.representativeUIDs.isEmpty })
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        if recoveringMemoryPressure { runtime.update { $0.memoryPressure = .critical } }
        let relaunched = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { relaunched.reset() }
        let restoreStarted = ContinuousClock.now
        apply(relaunched, revision: 1, libraryIsSettled: false)
        if recoveringMemoryPressure {
            try await Task.sleep(for: .milliseconds(25))
            #expect(!relaunched.discovery.hasComputed)
            runtime.update { $0.memoryPressure = .normal }
        }
        try await waitUntilHangLimit { relaunched.discovery.hasComputed }
        try #require(relaunched.discovery.hasComputed)
        #expect(
            relaunched.discovery.forYou == expected, "relaunch must preserve completed suggestions without inference")
        #expect(relaunched.discovery.computedContent?.timelineRevision == 1)
        #expect(await probe.calls == 1, "opening Search must not require another full index scan")
        #expect(!relaunched.isRefreshing)
        let bytes = await cache.data?.count ?? 0
        #expect(bytes < 64 * 1_024 * 1_024)
        if itemCount == 50_000 {
            print("Suggestion cache fixture: assets=50000 bytes=\(bytes) restore=\(restoreStarted.duration(to: .now))")
        }
    }

    @Test func placePolicyFingerprintKeepsTheExactSaltedDigest() throws {
        struct Content: Encodable {
            let items: [PhotoItem]
            let favorites: [PhotoUID]
            let coordinates: [PhotoCoordinate]
            let day: Date
            let calendar: String
            let timeZone: String
            let locale: String
        }
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "test", nodeID: "salted"), captureTime: captured, mediaType: "image/jpeg")
        let points = [PhotoCoordinate(uid: item.uid, latitude: 20, longitude: 30, date: captured)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(
            Content(
                items: [item], favorites: [item.uid], coordinates: points, day: calendar.startOfDay(for: captured),
                calendar: String(describing: calendar.identifier), timeZone: calendar.timeZone.identifier,
                locale: locale.identifier + "|" + Locale.preferredLanguages.joined(separator: "|")))
        let expected = Data(SHA256.hash(data: Data("place-evidence-v1|".utf8) + data))
        let actual = try SmartSearchDiscoveryPersistence.fingerprint(
            sections: [TimelineSection(id: "all", date: captured, title: "", items: [item])],
            favorites: [item.uid], coordinates: points, now: captured, calendar: calendar, locale: locale)
        #expect(actual == expected)
    }

    @Test func legacyPlacePolicyCannotRestoreRowsBeforeNewCuration() async throws {
        let cache = SnapshotCache()
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "test", nodeID: "\($0)"), captureTime: captured, mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: captured, title: "", items: items)]
        let coordinates = items.map { PhotoCoordinate(uid: $0.uid, latitude: 20, longitude: 30, date: captured) }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: [], coordinates: coordinates,
                snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            "Place"
        }
        apply(first)
        for _ in 0..<200 where await cache.saves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let saved = try PropertyListDecoder().decode(
            SmartSearchDiscoveryPersistence.self, from: try #require(await cache.data))
        try #require(saved.snapshot.candidates.contains { $0.kind == .place })
        first.reset()

        // This is the exact pre-filter fingerprint payload, with no policy salt.
        struct LegacyContent: Encodable {
            let items: [PhotoItem]
            let favorites: [PhotoUID] = []
            let coordinates: [PhotoCoordinate]
            let day = Calendar.current.startOfDay(for: Date())
            let calendar = String(describing: Calendar.current.identifier)
            let timeZone = Calendar.current.timeZone.identifier
            let locale = Locale.current.identifier + "|" + Locale.preferredLanguages.joined(separator: "|")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let legacy = Data(SHA256.hash(data: try encoder.encode(LegacyContent(items: items, coordinates: coordinates))))
        await cache.save(
            try SmartSearchDiscoveryPersistence(
                version: saved.version, modelKey: saved.modelKey, fingerprint: legacy,
                snapshot: saved.snapshot, evidence: saved.evidence, assetFingerprint: saved.assetFingerprint
            ).encoded())
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in "Place" }
        defer { next.reset() }
        apply(next)
        for _ in 0..<200 where await cache.reads < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!next.discovery.hasComputed)
        #expect(next.discovery.forYou.isEmpty)
    }

    @Test func disabledSmartSearchNamesOnlyEligibleCoordinatesAndReusesTheIndexEvidence() async throws {
        let coordinates = (0..<60).flatMap { offset in
            let captured = Date(timeIntervalSince1970: 1_700_000_000 + Double(offset / 2 * 7) * 86_400)
            return [
                PhotoCoordinate(
                    uid: PhotoUID(volumeID: "test", nodeID: "fixed-\(offset)"),
                    latitude: 20.123456789, longitude: 30.123456789, date: captured),
                PhotoCoordinate(
                    uid: PhotoUID(volumeID: "test", nodeID: "gps-\(offset)"),
                    latitude: -20 + Double(offset) * 0.0001, longitude: -30, date: captured),
            ]
        }
        let items = coordinates.map { PhotoItem(uid: $0.uid, captureTime: $0.date, mediaType: "image/jpeg") }
        let evidence = PhotoPlaceEvidence(coordinates: coordinates)
        let placeProbe = PlaceRequestProbe()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { lat, _ in
            await placeProbe.name(latitude: lat)
        }
        defer { scheduler.reset() }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: items[0].captureTime, title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: [], coordinates: coordinates, snapshot: .disabled,
            indexedAssetCount: { 0 }, searchEvidence: nil, locationEvidence: evidence)
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(scheduler.discovery.lastRefreshCompleted)
        let namedLatitudes = await placeProbe.latitudes
        #expect(namedLatitudes.count == 1 && namedLatitudes.allSatisfy { $0 < 0 })
        #if DEBUG
            #expect(evidence.hasAnalyzed)
        #endif
        let places = scheduler.discovery.forYou.filter { $0.kind == .place || $0.kind == .placeSeason }
        #expect(!places.isEmpty)
        #expect(places.allSatisfy { $0.matchingUIDs?.allSatisfy { $0.nodeID.hasPrefix("gps-") } == true })
    }

    private actor PlaceRequestProbe {
        var latitudes: [Double] = []
        func name(latitude: Double) -> String {
            latitudes.append(latitude)
            return "Place"
        }
    }

    private actor SnapshotCache {
        var data: Data?
        var failuresRemaining = 0
        var saves = 0
        var reads = 0
        var retiresNextRead = false
        func retireNextRead() { retiresNextRead = true }
        func failNextSave(count: Int = 1) { failuresRemaining = count }
        func access() -> MLSearchSuggestionCacheAccess {
            reads += 1
            let current = !retiresNextRead
            retiresNextRead = false
            return MLSearchSuggestionCacheAccess(
                data: data, isCurrent: { current },
                save: { data in
                    await self.noteSave()
                    if await self.takeFailure() { throw CocoaError(.fileWriteUnknown) }
                    await self.save(data)
                })
        }
        private func noteSave() { saves += 1 }
        private func takeFailure() -> Bool {
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        func save(_ data: Data) { self.data = data }
    }

    @Test func indexProgressDoesNotRearmAnExhaustedPersistenceWrite() async throws {
        let cache = SnapshotCache()
        await cache.failNextSave(count: 100)
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(
            runtimeState: LibraryRuntimeState(), debounce: .zero, retryDelays: Self.shortRetryDelays
        ) { _, _ in nil }
        defer { scheduler.reset() }
        func apply(_ snapshot: MLSmartSearchSnapshot) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: snapshot, indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheAccess: { await cache.access() })
        }
        // The visual index stays complete, so the content and the cache key stay equal; only the scheduler key
        // changes while index work runs, and the update gets past its early return.
        func indexing() -> MLSmartSearchSnapshot {
            let complete = visualSnapshot(settled: 8, ready: true)
            let progress = MLSmartSearchAggregateProgress(
                totalWorkUnits: 100, settledWorkUnits: 20, permanentlyUnavailableAssets: 0)
            return MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: complete.selectedModelID, phase: complete.phase,
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
                indexingState: .waiting(progress))
        }
        apply(visualSnapshot(settled: 8, ready: true))
        for _ in 0..<2_000 where await cache.saves < 4 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await cache.saves == 4)
        for _ in 0..<2 {
            apply(indexing())
            apply(visualSnapshot(settled: 8, ready: true))
            #if DEBUG
                await scheduler.waitForRefreshForTesting()
            #endif
        }
        #expect(await cache.saves == 4, "index progress must not renew an exhausted disk-write budget")
        #expect(await probe.calls == 1)
        #expect(scheduler.discovery.hasComputed, "failed persistence must retain usable rows")
    }

    @Test func transientSaveFailureRetriesOnlyPersistenceAndSurvivesRelaunch() async throws {
        let cache = SnapshotCache()
        await cache.failNextSave()
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let coordinates = items.map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: coordinates,
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        apply(first)
        for _ in 0..<200 where await cache.saves == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let publishedModel = first.discovery
        for _ in 0..<500 where await cache.data == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cache.data != nil, "a transient disk failure must not finalize an unsaved presentation")
        #expect(await cache.saves == 2)
        #expect(first.discovery === publishedModel, "a persistence retry must not rebuild suggestion rows")
        let expected = first.discovery.forYou
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in
            await probe.placeName()
        }
        defer { next.reset() }
        apply(next)
        for _ in 0..<200 where !next.discovery.hasComputed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.discovery.forYou == expected)
        #expect(await probe.calls == 1)
        #expect(await probe.placeCalls == 1)
        #expect(!next.discovery.showsVisualSuggestionsPendingNote(visualSnapshot(settled: 0, ready: false)))
    }

    @Test func relaunchRetriesCacheWhenModelStartupFinishesBeforeCoverageRestores() async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let ready = visualSnapshot(settled: 8, ready: true)
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, phase: MLSmartSearchPhase, cacheReady: Bool) {
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: ready.isEnabled,
                selectedModelID: ready.selectedModelID, phase: phase,
                installedModelBytes: ready.installedModelBytes, availableModels: ready.availableModels,
                isSearchAvailable: false, indexingState: cacheReady ? ready.indexingState : .idle)
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: snapshot, indexedAssetCount: { cacheReady ? 8 : 0 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheAccess: { cacheReady ? await cache.access() : nil })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, phase: ready.phase, cacheReady: true)
        for _ in 0..<200 where await cache.data == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await cache.data != nil)
        let expected = first.discovery.forYou
        try #require(expected.contains { !$0.representativeUIDs.isEmpty })
        first.reset()

        let runtime = LibraryRuntimeState()
        let search = runtime.beginActivity(.search)
        defer { search.end() }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { next.reset() }
        apply(next, phase: .preparingModel, cacheReady: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!next.discovery.hasComputed)
        apply(next, phase: .waiting(.init(total: 0, indexed: 0, permanentlyUnindexable: 0)), cacheReady: true)
        for _ in 0..<200 where !next.discovery.hasComputed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.discovery.forYou == expected, "saved suggestions must not wait for a new coverage pass")
        #expect(await probe.calls == 1, "restoring completed rows must not rerun their evidence scan")
    }

    @Test(arguments: ["unstableContent", "favorites", "missingGate"])
    func relaunchDoesNotPresentProvisionalOrChangedContentAsCurrent(
        change: String
    ) async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, favorites: Set<PhotoUID>, settled: Bool) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: favorites, coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheContentIsSettled: settled,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, favorites: Set(items.map(\.uid)), settled: true)
        for _ in 0..<200 where !first.discovery.lastRefreshCompleted || first.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(first.discovery.lastRefreshCompleted)
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { next.reset() }
        let favorites = Set((change == "favorites" ? Array(items.dropFirst()) : items).map(\.uid))
        if change == "missingGate" {
            let data = try #require(await cache.data)
            let saved = try PropertyListDecoder().decode(SmartSearchDiscoveryPersistence.self, from: data)
            let evidence = try #require(saved.evidence)
            let invalid = SmartSearchDiscoveryPersistence(
                version: saved.version, modelKey: saved.modelKey, fingerprint: saved.fingerprint,
                snapshot: saved.snapshot,
                evidence: MLSearchBatchResults(
                    results: Array(evidence.results.dropFirst()), scannedUIDs: evidence.scannedUIDs))
            await cache.save(try invalid.encoded())
        }
        apply(next, favorites: favorites, settled: change != "unstableContent")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!next.discovery.hasComputed, "unstable or different content must not become a current saved snapshot")
        runtime.update { $0.activeSearchCount = 0 }
        apply(next, favorites: favorites, settled: true)
        for _ in 0..<200 where !next.discovery.lastRefreshCompleted || next.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.discovery.lastRefreshCompleted)
        #expect(next.discovery.computedContent?.favoriteCount == favorites.count)
        #expect(await probe.calls == (change == "missingGate" ? 2 : 1))
    }

    @Test func metadataChangeAfterRelaunchReusesVisualEvidenceAndResolvedPlaces() async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let coordinates = items.map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, favorites: Set<PhotoUID>, revision: UInt64) {
            scheduler.update(
                sections: sections, timelineRevision: revision, favoriteUIDs: favorites, coordinates: coordinates,
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) }, cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        apply(first, favorites: Set(items.map(\.uid)), revision: 20)
        for _ in 0..<200 where !first.discovery.lastRefreshCompleted || first.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(first.discovery.lastRefreshCompleted)
        try #require(await probe.placeCalls == 1)
        first.reset()
        let second = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        defer { second.reset() }
        apply(second, favorites: Set(items.dropFirst().map(\.uid)), revision: 1)
        for _ in 0..<200 where !second.discovery.lastRefreshCompleted || second.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(second.discovery.computedContent?.favoriteCount == 7)
        #expect(await probe.calls == 1, "metadata changes must reuse saved evidence")
        #expect(await probe.placeCalls == 1, "unchanged place cells must not request their names again after relaunch")
    }

    private actor EvidenceProbe {
        var calls = 0
        var placeCalls = 0
        func placeName() -> String {
            placeCalls += 1
            return "Vienna"
        }
        var failuresRemaining = 0
        func failNext(_ count: Int) { failuresRemaining = count }
        func retryableQuery(sensitive: PhotoUID) throws -> MLSearchBatchResults {
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                calls += 1
                throw MLSmartSearchQueryError.unavailable
            }
            return query(sensitive: sensitive)
        }
        nonisolated static func evidence(
            sensitive: [PhotoUID], scanned: Set<PhotoUID>, conceptUIDs: [PhotoUID] = []
        ) -> MLSearchBatchResults {
            let descriptor = MLModelDescriptor(identifier: "fixture", version: 1, embeddingDimension: 3)
            let prompts =
                MLSearchConceptCatalog.sensitivePrompts.map { ($0, sensitive) }
                + MLSearchConceptCatalog.curated.map { ($0.prompt, conceptUIDs) }
            return MLSearchBatchResults(
                results: prompts.map { prompt, uids in
                    MLSearchResults(
                        descriptor: descriptor, queryText: prompt,
                        results: uids.map { MLSearchResult(uid: $0, score: 1) })
                }, scannedUIDs: MLScannedUIDMembership(scanned))
        }
        func query(
            sensitive: PhotoUID, conceptUIDs: [PhotoUID] = [], scanned: Set<PhotoUID>? = nil
        ) -> MLSearchBatchResults {
            calls += 1
            return Self.evidence(
                sensitive: [sensitive],
                scanned: scanned ?? Set((0..<8).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }),
                conceptUIDs: conceptUIDs)
        }
    }

    #if DEBUG
        @Test(arguments: [false, true]) func evidenceIsReleasedOnMemoryPressureOrVisualDisablement(
            disableVisual: Bool
        ) async throws {
            let runtime = LibraryRuntimeState()
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
            defer { scheduler.reset() }
            let probe = EvidenceProbe()
            let items = (0..<8).map {
                PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
            }
            func apply(visual: Bool, favorites: Set<PhotoUID>) {
                scheduler.update(
                    sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                    timelineRevision: 1, favoriteUIDs: favorites, coordinates: [],
                    snapshot: visual ? visualSnapshot(settled: 8, ready: true) : nil,
                    indexedAssetCount: { visual ? 8 : 0 },
                    searchEvidence: { await probe.query(sensitive: items[0].uid) })
            }
            let favorites = Set(items.map(\.uid))
            apply(visual: true, favorites: favorites)
            for _ in 0..<200 where scheduler.cachedEvidenceAssetCount == 0 || scheduler.isRefreshing {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(scheduler.cachedEvidenceAssetCount == 8)
            let originalRows = scheduler.discovery.forYou
            if disableVisual {
                apply(visual: false, favorites: favorites)
            } else {
                runtime.update { $0.memoryPressure = .critical }
            }
            for _ in 0..<200 where scheduler.cachedEvidenceAssetCount != 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(scheduler.cachedEvidenceAssetCount == 0)
            if !disableVisual { #expect(scheduler.discovery.forYou == originalRows) }
            runtime.update { $0.memoryPressure = .normal }
            apply(visual: true, favorites: Set(items.dropFirst().map(\.uid)))
            for _ in 0..<200 where await probe.calls < 2 || scheduler.isRefreshing {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await probe.calls == 2, "a later content refresh must rebuild evicted evidence")
            #expect(!scheduler.discovery.forYou.flatMap(\.representativeUIDs).contains(items[0].uid))
        }
    #endif

    @Test func startupRevisionsWaitForLibraryWorkAndCoalesceBeforeEvidence() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        func apply(revision: UInt64, settled: Bool) {
            scheduler.update(
                sections: [], timelineRevision: revision, favoriteUIDs: [], coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "0")) },
                libraryIsSettled: settled)
        }
        apply(revision: 1, settled: false)
        try await Task.sleep(for: .milliseconds(25))
        apply(revision: 2, settled: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0, "startup must retain its CPU, model and cache budget")
        #expect(!scheduler.isRefreshing)
        apply(revision: 2, settled: true)
        for _ in 0..<200 where await probe.calls == 0 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
    }

    @Test func replacedRevisionCancelsItsAutomaticEvidenceBeforeCompletion() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = CancellationProbe()
        scheduler.update(
            sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { try await probe.wait() })
        for _ in 0..<200 where !(await probe.started) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await probe.started)
        scheduler.update(
            sections: [], timelineRevision: 2, favoriteUIDs: [], coordinates: [],
            snapshot: nil, indexedAssetCount: { 0 }, searchEvidence: nil)
        for _ in 0..<200 where !(await probe.cancelled) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.cancelled, "a superseded scan must stop rather than run to completion")
        for _ in 0..<200 where scheduler.discovery.computedContent?.timelineRevision != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
    }

    private actor CancellationProbe {
        var started = false
        var cancelled = false
        func wait() async throws -> MLSearchBatchResults {
            started = true
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled = true
                throw error
            }
            return MLSearchBatchResults(results: [], scannedUIDs: [])
        }
    }

    @Test func semanticCompletionWaitsForNativeIndexCompletion() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        func update(semanticComplete: Bool, aggregateReady: Bool) {
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("visual-model"),
                phase: semanticComplete
                    ? .ready(MLIndexCoverage(total: 100, indexed: 100, permanentlyUnindexable: 0))
                    : .waiting(MLIndexCoverage(total: 100, indexed: 40, permanentlyUnindexable: 0)),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
                indexingState: aggregateReady
                    ? .ready(
                        MLSmartSearchAggregateProgress(
                            totalWorkUnits: 200, settledWorkUnits: 200, permanentlyUnavailableAssets: 0))
                    : .waiting(
                        MLSmartSearchAggregateProgress(
                            totalWorkUnits: 200, settledWorkUnits: 140, permanentlyUnavailableAssets: 0)))
            scheduler.update(
                sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
                snapshot: snapshot, indexedAssetCount: { semanticComplete ? 100 : 40 },
                searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        }
        update(semanticComplete: false, aggregateReady: false)
        try await Task.sleep(for: .milliseconds(25))
        update(semanticComplete: true, aggregateReady: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0, "semantic completion must not compete with native indexing")
        #expect(!scheduler.discovery.hasComputed)
        update(semanticComplete: true, aggregateReady: true)
        for _ in 0..<200 where await probe.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.calls == 1)
    }

    /// Waits until `condition` holds. The limit is far above any loaded machine and only ends a hung test.
    private func waitUntilHangLimit(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(300)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func visualSnapshot(settled: Int, ready: Bool) -> MLSmartSearchSnapshot {
        let total = ready ? settled : 100
        let progress = MLSmartSearchAggregateProgress(
            totalWorkUnits: total, settledWorkUnits: settled, permanentlyUnavailableAssets: 0)
        let coverage = MLIndexCoverage(total: total, indexed: settled, permanentlyUnindexable: 0)
        return MLSmartSearchSnapshot(
            isEnabled: true, selectedModelID: MLModelID("visual-model"),
            phase: ready ? .ready(coverage) : .waiting(coverage),
            installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
            indexingState: ready ? .ready(progress) : .waiting(progress))
    }

    @Test func partialIndexWaitsForEveryEnabledPipeline() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: false), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: sensitive) })
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0)
        #expect(!scheduler.discovery.hasComputed)
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 100, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: sensitive) })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
    }

    @Test(arguments: [false, true], [false, true]) func slowPlaceNamesDoNotDelaySafeMetadataPreviews(
        startsWithoutCoverage: Bool, hasMetadataRows: Bool
    ) async throws {
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            didEnter.yield()
            for await _ in release { break }
            return "Vienna"
        }
        defer {
            doRelease.finish()
            didEnter.finish()
            scheduler.reset()
        }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        if startsWithoutCoverage {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: hasMetadataRows ? Set(items.map(\.uid)) : [], coordinates: [],
                snapshot: visualSnapshot(settled: 0, ready: false), indexedAssetCount: { 0 },
                searchEvidence: { await probe.query(sensitive: sensitive, conceptUIDs: items.map(\.uid)) })
            try await Task.sleep(for: .milliseconds(25))
            #expect(await probe.calls == 0)
            #expect(!scheduler.discovery.hasComputed)
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: hasMetadataRows ? Set(items.map(\.uid)) : [],
            coordinates: items.map {
                PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
            },
            snapshot: visualSnapshot(settled: 100, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: sensitive, conceptUIDs: items.map(\.uid)) })
        for await _ in entered { break }
        #expect(await probe.calls == 1)
        let previews = scheduler.discovery.forYou.flatMap(\.representativeUIDs)
        #expect(!previews.isEmpty)
        #expect(!previews.contains(sensitive))
    }

    @Test func partialCoverageDoesNotStartEvidenceUntilIndexCompletion() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        func update(settled: Int, ready: Bool, revision: UInt64) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: revision, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: visualSnapshot(settled: settled, ready: ready), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: sensitive) })
        }
        update(settled: 8, ready: false, revision: 1)
        try await Task.sleep(for: .milliseconds(25))
        update(settled: 55, ready: false, revision: 1)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0)
        #expect(!scheduler.discovery.hasComputed)
        update(settled: 100, ready: true, revision: 1)
        for _ in 0..<200 where await probe.calls < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
    }

    private func update(_ scheduler: SmartSearchDiscoveryScheduler, revision: UInt64) {
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: revision, favoriteUIDs: Set(items.map(\.uid)), coordinates: [], smartSearch: nil
        )
    }

    @Test func activeSearchDefersAndCoalescesUpdatesUntilTheUserLeaves() async throws {
        let runtime = LibraryRuntimeState()
        let search = runtime.beginActivity(.search)
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        update(scheduler, revision: 1)
        update(scheduler, revision: 1)
        update(scheduler, revision: 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!scheduler.discovery.hasComputed)
        #expect(!scheduler.isRefreshing)

        search.end()
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
        #expect(scheduler.discovery.settledGeneration == 1)
        #expect(!scheduler.discovery.forYou.isEmpty)
        update(scheduler, revision: 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(scheduler.discovery.settledGeneration == 1)
    }

    @Test func backgroundAndLowPowerWorkWaitForARealEligibilityChange() async throws {
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(isLowPowerMode: true))
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        update(scheduler, revision: 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!scheduler.discovery.hasComputed)
        runtime.update {
            $0.isLowPowerMode = false
            $0.executionOpportunity = .backgroundPermitted
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!scheduler.discovery.hasComputed)
        runtime.update { $0.executionOpportunity = .foregroundActive }
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.hasComputed)
        scheduler.reset()
        #expect(!scheduler.discovery.hasComputed)
        #expect(scheduler.discovery.forYou.isEmpty)
    }

    @Test func enteringSearchDuringRefreshKeepsTheLastPublishedSuggestionsUsable() async throws {
        let runtime = LibraryRuntimeState()
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in
            didEnter.yield()
            for await _ in release { break }
            return "Vienna"
        }
        defer { scheduler.reset() }
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)], timelineRevision: 1,
            favoriteUIDs: Set(items.map(\.uid)), coordinates: [], smartSearch: nil)
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = scheduler.discovery
        let rows = original.forYou
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)], timelineRevision: 2,
            favoriteUIDs: Set(items.map(\.uid)),
            coordinates: items.map {
                PhotoCoordinate(uid: $0.uid, latitude: 48.2082, longitude: 16.3738, date: $0.captureTime)
            }, smartSearch: nil
        )
        for await _ in entered { break }
        let search = runtime.beginActivity(.search)
        for _ in 0..<200 where scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery === original)
        #expect(scheduler.discovery.computedContent?.timelineRevision == 1)
        #expect(scheduler.discovery.forYou == rows)
        doRelease.yield()
        search.end()
        for _ in 0..<200 where scheduler.discovery.computedContent?.timelineRevision != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
    }
}
