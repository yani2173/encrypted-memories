import Foundation
import Testing

@testable import PhotosCore

@Suite struct PhotoPlaceEvidenceTests {
    @Test func everyThresholdNeedsItsOwnEvidence() {
        #expect(!PhotoPlaceEvidence(coordinates: library()).excludedPositions().isEmpty)
        for points in [
            library(count: 49), library(days: 19), library(spacing: 3),
            library(contradictedDays: 23), library(distant: false), library(varying: false),
        ] {
            #expect(PhotoPlaceEvidence(coordinates: points).excludedPositions().isEmpty)
        }
        #expect(!PhotoPlaceEvidence(coordinates: library(contradictedDays: 24)).excludedPositions().isEmpty)
    }

    @Test(arguments: [0, 70]) func isolatedContraryDaysDoNotOverrideALongerUnprovenStay(firstContraryDay: Int) {
        let partial = library(count: 200, days: 100, contradictedDays: 30, firstContraryDay: firstContraryDay)
        #expect(PhotoPlaceEvidence(coordinates: partial).excludedPositions().isEmpty)
        let consistent = library(count: 200, days: 100, contradictedDays: 100)
        #expect(!PhotoPlaceEvidence(coordinates: consistent).excludedPositions().isEmpty)
    }

    @Test func rebuildsAreDeterministicAcrossCoordinateOrder() {
        let points = library(count: 200, days: 100, contradictedDays: 100)
        let original = PhotoPlaceEvidence(coordinates: points)
        let expected = original.excludedPositions()
        let support = original.supportSnapshot()
        #expect(expected.count == 1)
        for reordered in [points, Array(points.reversed()), Array(points.dropFirst(7)) + Array(points.prefix(7))] {
            for _ in 0..<3 {
                let rebuilt = PhotoPlaceEvidence(coordinates: reordered)
                #expect(rebuilt.excludedPositions() == expected)
                #expect(rebuilt.supportSnapshot() == support)
            }
        }
    }

    @Test func aLastDigitDifferenceIsNotAnExactRepeat() {
        let points = library().enumerated().map { offset, point in
            guard point.uid.nodeID.hasPrefix("fixed") else { return point }
            return PhotoCoordinate(
                uid: point.uid, latitude: offset.isMultiple(of: 2) ? point.latitude.nextUp : point.latitude,
                longitude: point.longitude, date: point.date)
        }
        #expect(PhotoPlaceEvidence(coordinates: points).excludedPositions().isEmpty)
    }

    @Test func unknownDatesAndOtherDaysCannotProveAFalsePlace() {
        for shift in [Double(400 * 86_400), Double.nan] {
            let points = library().map { point in
                let date =
                    point.uid.nodeID.hasPrefix("gps")
                    ? point.date.addingTimeInterval(shift) : point.date
                return PhotoCoordinate(uid: point.uid, latitude: point.latitude, longitude: point.longitude, date: date)
            }
            #expect(PhotoPlaceEvidence(coordinates: points).excludedPositions().isEmpty)
        }
    }

    @Test func supportCandidatesHaveABoundedCountAndRetainIdenticalSizedValidPlaces() {
        var points = library()
        points += library().filter { $0.uid.nodeID.hasPrefix("fixed") }.map { point in
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "trip-" + point.uid.nodeID),
                latitude: 40, longitude: 50, date: Date(timeIntervalSince1970: 1_500_000_000))
        }
        let snapshot = PhotoPlaceEvidence(coordinates: points).supportSnapshot()
        #expect(snapshot.filter { $0.photoCount == 60 && $0.excludedPhotoCount == 60 }.count == 1)
        #expect(snapshot.contains { $0.photoCount == 60 && $0.captureSpanWeeks == 0 && $0.excludedPhotoCount == 0 })
        let many = (0..<15).flatMap { cell in
            (0..<6).map { offset in
                PhotoCoordinate(
                    uid: PhotoUID(volumeID: "test", nodeID: "\(cell)-\(offset)"),
                    latitude: Double(cell), longitude: 10, date: .distantPast)
            }
        }
        #expect(PhotoPlaceEvidence(coordinates: many).supportSnapshot().count == 10)
    }

    @Test func canceledWarmingDoesNotCacheAnUnfilteredResult() async {
        let evidence = PhotoPlaceEvidence(coordinates: library())
        let canceled = Task.detached {
            try? await Task.sleep(for: .seconds(60))
            evidence.prewarm()
        }
        canceled.cancel()
        await canceled.value
        #if DEBUG
            #expect(!evidence.hasAnalyzed)
        #endif
        let excluded = await Task.detached { evidence.excludedPositions() }.value
        #expect(excluded.count == 1)
        #if DEBUG
            #expect(evidence.hasAnalyzed)
            #expect(evidence.analyzedOnMainThread == false)
        #endif
    }

    #if DEBUG
        @Test func completedAnalysisRemainsReadyDuringConcurrentCacheReads() async {
            let evidence = PhotoPlaceEvidence(coordinates: library())
            await Task.detached { evidence.prewarm() }.value
            let incompleteReads = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        var incomplete = 0
                        for _ in 0..<10_000 {
                            _ = evidence.excludedPositions()
                            if !evidence.hasAnalyzed { incomplete += 1 }
                        }
                        return incomplete
                    }
                }
                var total = 0
                for await count in group { total += count }
                return total
            }
            #expect(incompleteReads == 0)
            #expect(evidence.analyzedOnMainThread == false)
        }
    #endif

    private func library(
        count: Int = 60, days: Int = 30, spacing: Int = 7,
        contradictedDays: Int = 30, firstContraryDay: Int = 0, distant: Bool = true, varying: Bool = true
    ) -> [PhotoCoordinate] {
        var points = (0..<count).map { offset in
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "fixed-\(offset)"), latitude: 20.123456789,
                longitude: 30.123456789,
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset % days * spacing) * 86_400))
        }
        points += (0..<min(days, contradictedDays) * 2).map { offset in
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "gps-\(offset)"),
                latitude: (distant ? -20 : 20.2) + (varying ? Double(offset) * 0.0001 : 0),
                longitude: distant ? -30 : 30.2,
                date: Date(
                    timeIntervalSince1970: 1_700_000_000 + Double((offset / 2 + firstContraryDay) * spacing) * 86_400))
        }
        return points
    }
}
