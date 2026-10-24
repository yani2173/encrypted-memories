import Foundation
import MapKit
import MediaLocationCore
import PhotosCore
import Testing

@testable import MapCore

#if DEBUG
    @Suite @MainActor struct PhotoMapWarmingPriorityTests {
        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func openingTheMapFramesAtForegroundPriorityWhileTheIndexScans(scanning: Bool) async throws {
            let index = PhotoLocationIndex(supportSources: SupportDiagnosticsSources())
            if scanning { index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning)) }
            let point = PhotoCoordinate(
                uid: PhotoUID(volumeID: "fixture", nodeID: "map-priority"),
                latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
            index.merge([point])
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
            let events = AsyncStream<TaskPriority>.makeStream()
            loader.beforeFramingForTesting = { events.continuation.yield(Task.currentPriority) }
            loader.attach(map)
            var observations = events.stream.makeAsyncIterator()
            let observed = try #require(await observations.next())
            print("ISSUE683 map-framing scanning=\(scanning) priority=\(observed.rawValue)")
            #expect(observed >= .userInitiated)
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            events.continuation.finish()
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["framing", "annotations", "support"])
        func publicLocationWaitEscalatesTheActualIndexWorker(route: String) async throws {
            let index = PhotoLocationIndex(supportSources: SupportDiagnosticsSources())
            index.updateScanProgress(PhotoLocationScanProgress(phase: .scanning))
            let point = PhotoCoordinate(
                uid: PhotoUID(volumeID: "fixture", nodeID: "nested-priority"),
                latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
            index.merge([point])
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
            if route == "annotations" {
                loader.attach(map)
                await loader.waitForFramingForTesting()
                await loader.waitForReloadForTesting()
            }
            let events = AsyncStream<(String, TaskPriority)>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer {
                release.continuation.yield(())
                release.continuation.finish()
            }
            index.beforePlaceAnalysisAsyncForTesting = {
                await withTaskPriorityEscalationHandler {
                    events.continuation.yield(("entered", Task.currentPriority))
                    for await _ in release.stream { break }
                } onPriorityEscalated: { _, priority in
                    events.continuation.yield(("escalated", priority))
                }
            }
            index.beforePlaceAnalysisForTesting = {
                events.continuation.yield(("analysis", Task.currentPriority))
            }
            if route == "annotations" { index.replaceAll([point]) }
            let evidence = index.placeEvidence()
            evidence.setBeforeWarmingWaitForTesting {
                events.continuation.yield(("waiter", Task.currentPriority))
            }
            var observations = events.stream.makeAsyncIterator()
            let entered = try #require(await observations.next())
            #expect(entered.0 == "entered")
            #expect(entered.1 == .background)
            var support: Task<[PlaceCandidateSupportSnapshot], Never>?
            switch route {
            case "support":
                support = Task.detached(priority: .userInitiated) { await index.photoPlaceSupportSnapshot() }
            case "annotations": loader.refreshIfChanged(revision: index.revision)
            default: loader.attach(map)
            }
            let waiter = try #require(await observations.next())
            #expect(waiter.0 == "waiter")
            print("ISSUE683 actual-route=\(route) waiter=\(waiter.1.rawValue)")
            #expect(waiter.1 >= .userInitiated)
            if waiter.1 > entered.1 {
                let escalated = try #require(await observations.next())
                #expect(escalated.0 == "escalated")
                #expect(escalated.1 >= waiter.1)
            }
            release.continuation.yield(())
            release.continuation.finish()
            let analysis = try #require(await observations.next())
            #expect(analysis.0 == "analysis")
            #expect(analysis.1 >= waiter.1)
            print("ISSUE683 actual-route=\(route) detached-analysis=\(analysis.1.rawValue)")
            if let support { _ = await support.value }
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            #expect(evidence.hasAnalyzed)
            events.continuation.finish()
        }
    }
#endif
