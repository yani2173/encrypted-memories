import Foundation
import MapKit
import MediaLocationCore
import PhotosCore
import Testing

@testable import MapCore

#if DEBUG
    @Suite @MainActor struct PhotoMapOpeningTests {
        @Test func retiredInitialWarmingDoesNotRestartForAHeldQuery() async throws {
            let index = PhotoLocationIndex()
            var time: TimeInterval = 0
            index.nowForTesting = { time }
            func points(_ range: Range<Int>) -> [PhotoCoordinate] {
                range.map {
                    PhotoCoordinate(
                        uid: PhotoUID(volumeID: "test", nodeID: "retired-crawl-\($0)"),
                        latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
                }
            }
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            index.merge(points(0..<1000))
            let pause = AnalysisPause()
            index.beforePlaceAnalysisForTesting = { pause.wait() }
            defer { pause.release() }
            let query = index.querySnapshot()
            let reader = Task.detached {
                _ = await query.evidence.waitForWarming()
                return query.coordinates(
                    in: GeoBoundingBox(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180))
            }
            try #require(await pause.entered.happens(), "The analysis must reach its pause")
            time = 10
            index.merge(points(1000..<1100))
            index.beforePlaceAnalysisForTesting = nil
            _ = index.placeEvidence()
            pause.release()
            let result = await reader.value
            #expect(query.evidence.analysisStartsForTesting == 1, "A retired admission must not restart in its reader")
            let returnedCount = result.count
            #expect(returnedCount == 0, "A retired unclassified query must not publish raw coordinates")
            await index.waitForPlaceEvidenceForTesting()
            #expect(index.placeEvidence().coordinates.count == 1100)
        }

        @Test func openingCrawlFinishesItsAdmittedSnapshotWhileNewBatchesArrive() async throws {
            let index = PhotoLocationIndex()
            func points(_ range: Range<Int>) -> [PhotoCoordinate] {
                range.map {
                    PhotoCoordinate(
                        uid: PhotoUID(volumeID: "test", nodeID: "opening-crawl-\($0)"),
                        latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
                }
            }
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            index.merge(points(0..<1000))
            let evidence = index.placeEvidence()
            let pause = AnalysisPause()
            evidence.setBeforeAnalysisForTesting { pause.wait() }
            defer { pause.release() }
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
            var time: CFTimeInterval = 0
            index.nowForTesting = { time }
            loader.attach(map)
            try #require(await pause.entered.happens(), "The analysis must reach its pause")
            time = 1
            index.merge(points(1000..<1050))
            let laterEvidence = index.placeEvidence()
            loader.refreshIfChanged(revision: index.revision)
            #expect(map.annotations.isEmpty)
            pause.release()
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            #expect(evidence.analysisStartsForTesting == 1, "Later batches must not cancel admitted warming")
            #expect(evidence.hasAnalyzed)
            #expect(laterEvidence === evidence)
            #expect(map.annotations.compactMap { $0 as? PhotoMapAnnotation }.reduce(0) { $0 + $1.memberCount } == 1000)
        }

        @Test func mapMovementDoesNotRestartAnAdmittedCrawlAnalysis() async throws {
            let index = PhotoLocationIndex()
            func points(_ range: Range<Int>) -> [PhotoCoordinate] {
                range.map {
                    PhotoCoordinate(
                        uid: PhotoUID(volumeID: "test", nodeID: "pan-\($0)"),
                        latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
                }
            }
            index.replaceAll(points(0..<1000))
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
            var time: CFTimeInterval = 0
            index.nowForTesting = { time }
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            loader.attach(map)
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            time = 10
            index.merge(points(1000..<1100))
            let pause = AnalysisPause()
            index.beforePlaceAnalysisForTesting = { pause.wait() }
            defer { pause.release() }
            loader.refreshIfChanged(revision: index.revision)
            try #require(await pause.entered.happens(), "The analysis must reach its pause")
            var region = map.region
            region.center.longitude += 0.001
            map.setRegion(region, animated: false)
            loader.reloadVisible()
            pause.release()
            await index.waitForPlaceEvidenceForTesting()
            loader.refreshIfChanged(revision: index.revision)
            await loader.waitForReloadForTesting()
            #expect(
                index.placeEvidence().analysisStartsForTesting == 1,
                "A viewport change must share the admitted analysis")
            #expect(map.annotations.compactMap { $0 as? PhotoMapAnnotation }.reduce(0) { $0 + $1.memberCount } == 1100)
        }

        @Test func crawlBoundsClassificationByTimeAndGrowthAndReloadsAtCompletion() async throws {
            let index = PhotoLocationIndex()
            func points(_ range: Range<Int>) -> [PhotoCoordinate] {
                range.map {
                    PhotoCoordinate(
                        uid: PhotoUID(volumeID: "test", nodeID: "crawl-\($0)"),
                        latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
                }
            }
            index.replaceAll(points(0..<1000))
            let first = index.placeEvidence()
            await Task.detached { first.prewarm() }.value
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
            var time: CFTimeInterval = 0
            index.nowForTesting = { time }
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            loader.attach(map)
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            var analyzed = [ObjectIdentifier(first): first]
            func pinCount() -> Int {
                map.annotations.compactMap { $0 as? PhotoMapAnnotation }.reduce(0) { $0 + $1.memberCount }
            }
            for batch in 1...20 {
                time = Double(batch)
                index.merge(points((1000 + (batch - 1) * 50)..<(1000 + batch * 50)))
                _ = index.placeEvidence()
                await index.waitForPlaceEvidenceForTesting()
                let evidence = index.placeEvidence()
                analyzed[ObjectIdentifier(evidence)] = evidence
                loader.refreshIfChanged(revision: index.revision)
                loader.reloadVisible()  // Layout and region callbacks must obey the same admission rule.
                await loader.waitForReloadForTesting()
                #expect(pinCount() == (batch < 10 ? 1000 : batch < 20 ? 1500 : 2000))
            }
            #expect(
                analyzed.values.reduce(0) { $0 + $1.analysisStartsForTesting } == 3,
                "Twenty crawl batches need only the initial and two admitted classifications")
            time = 40
            index.merge(points(2000..<2050))  // Enough time, less than ten percent growth.
            let previous = index.placeEvidence()
            loader.refreshIfChanged(revision: index.revision)
            await loader.waitForReloadForTesting()
            #expect(analyzed.values.reduce(0) { $0 + $1.analysisStartsForTesting } == 3)
            #expect(index.placeEvidence() === previous)
            #expect(pinCount() == 2000)
            index.updateScanProgress(PhotoLocationScanProgress(phase: .completed))
            // The scan observer reloads the map on its own; the test only waits for the pins.
            _ = await eventually { pinCount() == 2050 }
            #expect(pinCount() == 2050, "Completion must reload without another coordinate revision")
            #expect(index.placeEvidence().analysisStartsForTesting == 1)
        }

        @Test(arguments: [false, true])
        func openingFramesBeforePublishingPins(initiallyEmpty: Bool) async throws {
            let index = PhotoLocationIndex()
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            map.setRegion(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 240)), animated: false)
            let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
            if initiallyEmpty {
                loader.attach(map)
                await loader.waitForFramingForTesting()
                await loader.waitForReloadForTesting()
                #expect(map.annotations.isEmpty)
            }
            let point = PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "point"), latitude: 20, longitude: 30, date: .now)
            index.replaceAll([point])
            let gate = FramingPause()
            loader.beforeFramingForTesting = { await gate.pause() }
            if initiallyEmpty {
                loader.refreshIfChanged(revision: index.revision)
            } else {
                loader.attach(map)
            }
            defer { gate.release() }
            try #require(await gate.entered.happens(), "The framing must reach its pause")
            loader.reloadVisible()
            await loader.waitForReloadForTesting()
            #expect(map.annotations.isEmpty, "The first pins must wait for the dense-core frame")
            gate.release()
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            #expect(map.annotations.compactMap { $0 as? PhotoMapAnnotation }.count == 1)
            #expect(abs(map.region.center.latitude - point.latitude) < 0.1)
            #expect(abs(map.region.center.longitude - point.longitude) < 0.1)
        }
    }

    /// Holds the framing worker until the test releases it, or until the worker is cancelled.
    private final class FramingPause: Sendable {
        let entered = AsyncTestSignal()
        private let released = AsyncTestSignal()
        func pause() async {
            entered.fire()
            await released.wait()
        }
        func release() { released.fire() }
    }

    /// Blocks the analysis worker until the test releases it. Every test releases it in a `defer`. The worker blocks a
    /// thread of the shared pool, so the hang limit also releases it: a full pool must not stop the limit of `happens()`.
    private final class AnalysisPause: @unchecked Sendable {
        let entered = AsyncTestSignal()
        private let condition = NSCondition()
        private var released = false
        func wait() {
            entered.fire()
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date(timeIntervalSinceNow: TimeInterval(AsyncTestSignal.hangLimit.components.seconds))
            while !released && condition.wait(until: deadline) {}
        }
        func release() {
            condition.withLock {
                released = true
                condition.broadcast()
            }
        }
    }
#endif
