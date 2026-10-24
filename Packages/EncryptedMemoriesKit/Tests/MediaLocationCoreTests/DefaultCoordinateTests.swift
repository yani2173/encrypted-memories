import Foundation
import PhotosCore
import Testing

@testable import MediaLocationCore

@Suite @MainActor struct DefaultCoordinateTests {
    @Test func repeatedDefaultDoesNotEnterMapClustersButRawIndexStaysIntact() async {
        let coordinates = Self.library()
        let index = PhotoLocationIndex()
        index.replaceAll(coordinates)
        let viewport = PhotoLocationViewport(
            centerLatitude: 20, centerLongitude: 30, latitudeDelta: 1, longitudeDelta: 1)

        #expect(index.coordinates(in: viewport, policy: .standard).isEmpty)
        #expect(index.coordinates == coordinates)
        #expect(index.indexedUIDs() == Set(coordinates.map(\.uid)))
        let evidence = index.placeEvidence()
        let framing = await Task.detached {
            PhotoLocationFraming.denseBoundingBox(for: coordinates, excluding: evidence.excludedPositions())
        }.value
        #expect((framing?.maxLatitude ?? 90) < 0)
    }

    @Test func realPlacesAndUnprovenCoordinatesRemainOnTheMap() {
        let repeated = Self.library().filter { $0.uid.nodeID.hasPrefix("fixed-") }
        for coordinates in [
            repeated,
            repeated.map { point in
                PhotoCoordinate(
                    uid: point.uid, latitude: point.latitude, longitude: point.longitude, date: repeated[0].date)
            },
            repeated.enumerated().map { offset, point in
                PhotoCoordinate(
                    uid: point.uid, latitude: point.latitude + Double(offset) * 0.00001,
                    longitude: point.longitude, date: point.date)
            },
        ] {
            let index = PhotoLocationIndex()
            index.replaceAll(coordinates)
            let box = GeoBoundingBox(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180)
            #expect(Set(index.coordinates(in: box).map(\.uid)) == Set(coordinates.map(\.uid)))
        }
    }

    @Test func nearbyVariationProtectsAnOtherwiseRepeatedHomeCoordinate() {
        let coordinates = Self.library()
        let first = coordinates[0]
        let nearby = PhotoCoordinate(
            uid: PhotoUID(volumeID: "test", nodeID: "nearby"), latitude: first.latitude.nextUp,
            longitude: first.longitude, date: first.date)
        let index = PhotoLocationIndex()
        index.replaceAll(coordinates + [nearby])
        let box = GeoBoundingBox(minLatitude: 19, maxLatitude: 21, minLongitude: 29, maxLongitude: 31)
        #expect(index.coordinates(in: box).count == 61)
    }

    @Test func evidenceIsSharedAndReplacedOnlyWhenCoordinatesChange() async {
        let index = PhotoLocationIndex()
        #if DEBUG
            index.warmingPriorityForTesting = .userInitiated
        #endif
        index.replaceAll(Self.library())
        let evidence = index.placeEvidence()
        #expect(index.placeEvidence() === evidence)
        _ = await index.photoPlaceSupportSnapshot()
        #if DEBUG
            #expect(evidence.hasAnalyzed)
        #endif
        _ = index.querySnapshot().coordinates(
            in: GeoBoundingBox(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180))
        #expect(index.placeEvidence() === evidence)
        index.merge([Self.library()[0]])
        #expect(index.placeEvidence() === evidence)
        await index.retainOnly(Set(Self.library().dropFirst().map(\.uid)))
        #expect(index.placeEvidence() !== evidence)
    }

    @Test func supportExportContainsOnlyAnonymousCountsAndRoundedSpans() async throws {
        let sources = SupportDiagnosticsSources()
        let index = PhotoLocationIndex(supportSources: sources)
        #if DEBUG
            index.warmingPriorityForTesting = .userInitiated
        #endif
        index.replaceAll(Self.library())
        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources)
        let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let candidates = try #require(report["placeCandidates"] as? [[String: Int]])
        #expect(candidates.count == 2)
        #expect(
            candidates.allSatisfy {
                Set($0.keys) == ["photoCount", "distinctExactCoordinates", "captureSpanWeeks", "excludedPhotoCount"]
            })
        #expect(
            candidates.contains {
                $0["photoCount"] == 60 && $0["distinctExactCoordinates"] == 1
                    && $0["captureSpanWeeks"] == 29 && $0["excludedPhotoCount"] == 60
            })
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("fixed-") && !text.contains("gps-"))
        #expect(!text.contains("20.123456789") && !text.contains("30.123456789"))
        index.replaceAll([])
        #expect(await sources.placeSnapshot().isEmpty)
    }

    @Test func largeIndexSharesBackgroundAnalysisAcrossViewports() async {
        var points = Self.library()
        points += (120..<100_000).map { offset in
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "large-\(offset)"),
                latitude: -20 + Double(offset) * 0.000001, longitude: -30,
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset % 30 * 7) * 86_400))
        }
        let index = PhotoLocationIndex()
        index.replaceAll(points)
        let evidence = index.placeEvidence()
        let query = index.querySnapshot()
        let started = ContinuousClock.now
        let count = await Task.detached {
            query.coordinates(
                in: GeoBoundingBox(
                    minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180)
            ).count
        }.value
        print("Place evidence fixture: photos=100000 firstQuery=\(started.duration(to: .now))")
        #expect(count == 99_940)
        #expect(index.placeEvidence() === evidence)
        #if DEBUG
            #expect(evidence.hasAnalyzed)
        #endif
        let viewport = PhotoLocationViewport(
            centerLatitude: 20, centerLongitude: 30, latitudeDelta: 1, longitudeDelta: 1)
        #expect(index.coordinates(in: viewport, policy: .standard).isEmpty)
        #expect(index.placeEvidence() === evidence)
    }

    #if DEBUG
        @Test func replacingSnapshotWarmsTheSharedEvidenceWithoutAConsumer() async throws {
            let index = PhotoLocationIndex()
            index.warmingPriorityForTesting = .userInitiated
            index.replaceAll(Self.library())
            let evidence = index.placeEvidence()
            // The index owns the warming task; awaiting it needs no time limit.
            try #require(await evidence.waitForWarming())
            try #require(evidence.hasAnalyzed)
            #expect(evidence.analyzedOnMainThread == false)
            #expect(index.placeEvidence() === evidence)
            #expect(evidence.excludedPositions().count == 1)
        }

        @Test func crawlWarmsOnlyTheCompletedSnapshot() async throws {
            let index = PhotoLocationIndex()
            index.warmingPriorityForTesting = .userInitiated
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            index.merge(Self.library())
            let evidence = index.placeEvidence()
            #expect(!evidence.hasAnalyzed)
            index.updateScanProgress(PhotoLocationScanProgress(phase: .completed))
            // The index owns the warming task; awaiting it needs no time limit.
            try #require(await evidence.waitForWarming())
            try #require(evidence.hasAnalyzed)
            #expect(evidence.analyzedOnMainThread == false)
            #expect(index.placeEvidence() === evidence)
        }
    #endif

    static func library() -> [PhotoCoordinate] {
        (0..<60).flatMap { offset in
            let day = offset / 2
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(day * 7) * 86_400)
            return [
                PhotoCoordinate(
                    uid: PhotoUID(volumeID: "test", nodeID: "fixed-\(offset)"),
                    latitude: 20.123456789, longitude: 30.123456789, date: date),
                PhotoCoordinate(
                    uid: PhotoUID(volumeID: "test", nodeID: "gps-\(offset)"),
                    latitude: -20 + Double(offset) * 0.0001, longitude: -30, date: date),
            ]
        }
    }
}
