import Foundation
import MediaLocationCore
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchCore
@testable import MLSearchFeature

@MainActor @Suite struct BoundSearchCurationTests {
    private func points(_ range: Range<Int>, latitude: Double = 20) -> [PhotoCoordinate] {
        range.map {
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "curation-\($0)"), latitude: latitude, longitude: 30,
                date: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    private func sections(_ points: [PhotoCoordinate]) -> [TimelineSection] {
        [
            TimelineSection(
                id: "all", date: points[0].date, title: "",
                items: points.map { PhotoItem(uid: $0.uid, captureTime: $0.date, mediaType: "image/jpeg") })
        ]
    }

    @Test func hostKeyIgnoresRawCoordinateGrowth() {
        let first = SmartSearchDiscoveryScheduler.revisionKey(
            timelineRevision: 1, favoriteUIDs: [], coordinateCount: 1000, smartSearch: nil, placeRevision: 1)
        let batch = SmartSearchDiscoveryScheduler.revisionKey(
            timelineRevision: 1, favoriteUIDs: [], coordinateCount: 1050, smartSearch: nil, placeRevision: 1)
        let publication = SmartSearchDiscoveryScheduler.revisionKey(
            timelineRevision: 1, favoriteUIDs: [], coordinateCount: 1050, smartSearch: nil, placeRevision: 2)
        #expect(first == batch)
        #expect(batch != publication)
    }

    #if DEBUG
        @Test func crawlCuratesAndClustersOnlyPublishedPlaceSnapshots() async {
            let index = PhotoLocationIndex()
            var time: TimeInterval = 0
            index.nowForTesting = { time }
            index.replaceAll(points(0..<1000))
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
                _, _ in
                "Test place"
            }
            defer { scheduler.reset() }
            let library = sections(points(0..<2050))
            func apply() async {
                _ = index.placeEvidence()
                await index.waitForPlaceEvidenceForTesting()
                scheduler.update(
                    sections: library, timelineRevision: 1, favoriteUIDs: [], coordinates: index.coordinates,
                    smartSearch: nil, placeRevision: index.placeRevision, locationEvidence: index.placeEvidence())
                await scheduler.waitForRefreshForTesting()
            }
            await apply()
            for batch in 1...20 {
                time = Double(batch)
                index.merge(points((1000 + (batch - 1) * 50)..<(1000 + batch * 50)))
                await apply()
            }
            #expect(scheduler.curationRunCount == 3)
            #expect(scheduler.placeClusteringCount == 3)
            #expect(scheduler.metadataPassCount == 3)
            time = 40
            index.merge(points(2000..<2050))
            await apply()
            #expect(scheduler.curationRunCount == 3, "insufficient growth keeps the classified publication")
            index.updateScanProgress(PhotoLocationScanProgress(phase: .completed))
            await apply()
            #expect(scheduler.curationRunCount == 4)
            #expect(scheduler.placeClusteringCount == 4)
            #expect(scheduler.discovery.forYou.first { $0.kind == .place }?.matchCount == 2050)
        }

        @Test(arguments: [false, true]) func retiredEvidenceWaitsForPublicationWithoutMetadataRetries(
            visual: Bool
        ) async throws {
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
                latitude, _ in
                latitude < 30 ? "First place" : "Replacement place"
            }
            defer { scheduler.reset() }
            let coordinates = points(0..<8)
            let library = sections(coordinates)
            let descriptor = MLModelDescriptor(identifier: "fixture", version: 1, embeddingDimension: 3)
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("fixture"),
                phase: .ready(MLIndexCoverage(total: 8, indexed: 8, permanentlyUnindexable: 0)),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
                indexingState: .ready(
                    MLSmartSearchAggregateProgress(
                        totalWorkUnits: 8, settledWorkUnits: 8, permanentlyUnavailableAssets: 0))
            )
            let evidence = MLSearchBatchResults(
                results: (MLSearchConceptCatalog.sensitivePrompts + MLSearchConceptCatalog.curated.map(\.prompt)).map {
                    MLSearchResults(descriptor: descriptor, queryText: $0, results: [])
                }, scannedUIDs: MLScannedUIDMembership(Set(coordinates.map(\.uid))))
            func apply(_ location: PhotoPlaceEvidence, revision: Int) {
                scheduler.update(
                    sections: library, timelineRevision: 1, favoriteUIDs: [], coordinates: location.coordinates,
                    snapshot: visual ? snapshot : nil, indexedAssetCount: { visual ? 8 : 0 },
                    searchEvidence: { evidence },
                    placeRevision: revision, locationEvidence: location)
            }
            apply(PhotoPlaceEvidence(coordinates: coordinates), revision: 1)
            await scheduler.waitForRefreshForTesting()
            let places = scheduler.discovery.forYou.filter { $0.kind == .place }
            #expect(!places.isEmpty)
            let replacement = PhotoPlaceEvidence(coordinates: points(0..<8, latitude: 40))
            let retired = Task<Void, Never> {}
            retired.cancel()
            await retired.value
            replacement.registerWarmingTask(retired)
            apply(replacement, revision: 2)
            #expect(scheduler.discovery.forYou.filter { $0.kind == .place } == places)
            await scheduler.waitForRefreshForTesting()
            let runs = scheduler.curationRunCount
            let metadata = scheduler.metadataPassCount
            await scheduler.waitForRefreshForTesting()
            #expect(scheduler.curationRunCount == runs, "retired place evidence waits for a new publication")
            #expect(scheduler.metadataPassCount == metadata)
            #expect(scheduler.discovery.forYou.filter { $0.kind == .place } == places)
            #expect(replacement.analysisStartsForTesting == 0)
            apply(PhotoPlaceEvidence(coordinates: points(0..<8, latitude: 40)), revision: 3)
            await scheduler.waitForRefreshForTesting()
            for _ in 0..<200 where !scheduler.discovery.forYou.contains(where: { $0.title == "Replacement place" }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(scheduler.discovery.lastRefreshCompleted)
            #expect(scheduler.discovery.forYou.contains { $0.kind == .place && $0.id != places.first?.id })
        }

        @Test func emptyPlacePreviewsStayVisibleWhileReplacementEvidenceIsRetired() async throws {
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
                latitude, _ in latitude < 30 ? "First place" : "Replacement place"
            }
            defer { scheduler.reset() }
            let coordinates = points(0..<8)
            let originalUIDs = Set(coordinates.map(\.uid))
            let descriptor = MLModelDescriptor(identifier: "fixture", version: 1, embeddingDimension: 3)
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("fixture"),
                phase: .ready(MLIndexCoverage(total: 9, indexed: 9, permanentlyUnindexable: 0)),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
                indexingState: .ready(
                    MLSmartSearchAggregateProgress(
                        totalWorkUnits: 9, settledWorkUnits: 9, permanentlyUnavailableAssets: 0))
            )
            func apply(_ location: PhotoPlaceEvidence, revision: Int, addsSafePhoto: Bool) {
                let photos = addsSafePhoto ? points(0..<9) : coordinates
                let evidence = MLSearchBatchResults(
                    results: MLSearchConceptCatalog.sensitivePrompts.map {
                        MLSearchResults(
                            descriptor: descriptor, queryText: $0,
                            results: originalUIDs.map { MLSearchResult(uid: $0, score: 1) })
                    }
                        + MLSearchConceptCatalog.curated.map {
                            MLSearchResults(descriptor: descriptor, queryText: $0.prompt, results: [])
                        }, scannedUIDs: MLScannedUIDMembership(Set(photos.map(\.uid))))
                scheduler.update(
                    sections: sections(photos), timelineRevision: addsSafePhoto ? 2 : 1,
                    favoriteUIDs: Set(photos.map(\.uid)), coordinates: location.coordinates,
                    snapshot: snapshot, indexedAssetCount: { photos.count }, searchEvidence: { evidence },
                    placeRevision: revision, locationEvidence: location)
            }
            apply(PhotoPlaceEvidence(coordinates: coordinates), revision: 1, addsSafePhoto: false)
            await scheduler.waitForRefreshForTesting()
            let places = scheduler.discovery.forYou.filter { $0.kind == .place || $0.kind == .placeSeason }
            try #require(!places.isEmpty)
            try #require(scheduler.discovery.forYou.allSatisfy { $0.representativeUIDs.isEmpty && $0.kind != .concept })
            let replacement = PhotoPlaceEvidence(coordinates: points(0..<8, latitude: 40))
            let retired = Task<Void, Never> {}
            retired.cancel()
            await retired.value
            replacement.registerWarmingTask(retired)
            apply(replacement, revision: 2, addsSafePhoto: true)
            #expect(scheduler.discovery.forYou.filter { $0.kind == .place || $0.kind == .placeSeason } == places)
            await scheduler.waitForRefreshForTesting()
            #expect(scheduler.discovery.forYou.filter { $0.kind == .place || $0.kind == .placeSeason } == places)
            let runs = scheduler.curationRunCount
            let metadata = scheduler.metadataPassCount
            await scheduler.waitForRefreshForTesting()
            #expect(scheduler.curationRunCount == runs)
            #expect(scheduler.metadataPassCount == metadata)
            #expect(replacement.analysisStartsForTesting == 0)
            apply(PhotoPlaceEvidence(coordinates: points(0..<8, latitude: 40)), revision: 3, addsSafePhoto: true)
            await scheduler.waitForRefreshForTesting()
            #expect(scheduler.discovery.lastRefreshCompleted)
            #expect(scheduler.discovery.forYou.contains { $0.kind == .place && $0.title == "Replacement place" })
            #expect(!scheduler.discovery.forYou.contains { $0.id == places.first?.id })
            #expect(scheduler.discovery.forYou.contains { !$0.representativeUIDs.isEmpty })
            #expect(scheduler.discovery.forYou.flatMap(\.representativeUIDs).allSatisfy { !originalUIDs.contains($0) })
        }

        @Test(arguments: [false, true]) func crawlStillInvalidatesLibraryAndFavoritesImmediately(favorites: Bool) async
        {
            let runtime = LibraryRuntimeState()
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in "Test place"
            }
            defer { scheduler.reset() }
            let coordinates = points(0..<20)
            let library = sections(coordinates)
            let evidence = PhotoPlaceEvidence(coordinates: coordinates)
            let originalFavorites = Set(coordinates.prefix(8).map(\.uid))
            scheduler.update(
                sections: library, timelineRevision: 1, favoriteUIDs: originalFavorites, coordinates: coordinates,
                smartSearch: nil, placeRevision: 1, locationEvidence: evidence)
            await scheduler.waitForRefreshForTesting()
            let selected = scheduler.discovery.forYou.first { $0.kind == (favorites ? .favorites : .place) }
            #expect(selected != nil)
            let search = runtime.beginActivity(.search)
            defer { search.end() }
            scheduler.update(
                sections: favorites ? library : sections(Array(coordinates.dropFirst())),
                timelineRevision: favorites ? 1 : 2, favoriteUIDs: originalFavorites.subtracting([coordinates[0].uid]),
                coordinates: coordinates, smartSearch: nil, placeRevision: 1, locationEvidence: evidence)
            #expect(!scheduler.discovery.forYou.contains { $0.id == selected?.id })
            if let selected {
                #expect(
                    scheduler.discovery.rebind(
                        selected,
                        content: SmartSearchContentIdentity(
                            timelineRevision: favorites ? 1 : 2,
                            favoriteUIDs: originalFavorites.subtracting([coordinates[0].uid])), snapshot: nil)
                        == .pending)
            }
        }
    #endif
}
