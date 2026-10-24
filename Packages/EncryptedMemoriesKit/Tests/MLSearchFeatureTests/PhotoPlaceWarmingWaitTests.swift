import Foundation
import MediaLocationCore
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchFeature

#if DEBUG
    @Suite @MainActor struct PhotoPlaceWarmingWaitTests {
        @Test(.timeLimit(.minutes(1)))
        func automaticSearchEscalatesTheActualIndexWorkerBeforeNamingPlaces() async throws {
            let events = AsyncStream<(String, TaskPriority)>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer {
                release.continuation.yield(())
                release.continuation.finish()
            }
            let index = PhotoLocationIndex(supportSources: SupportDiagnosticsSources())
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
            let point = PhotoCoordinate(
                uid: PhotoUID(volumeID: "fixture", nodeID: "search-priority"),
                latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
            index.merge([point])
            let evidence = index.placeEvidence()
            evidence.setBeforeWarmingWaitForTesting {
                events.continuation.yield(("waiter", Task.currentPriority))
            }
            var observations = events.stream.makeAsyncIterator()
            let entered = try #require(await observations.next())
            #expect(entered.0 == "entered")
            #expect(entered.1 == .background)
            let item = PhotoItem(uid: point.uid, captureTime: point.date, mediaType: "image/jpeg")
            let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
                _, _ in "Fixture place"
            }
            defer { scheduler.reset() }
            scheduler.update(
                sections: [TimelineSection(id: "all", date: point.date, title: "", items: [item])],
                timelineRevision: 1, favoriteUIDs: [], coordinates: index.coordinates, snapshot: .disabled,
                indexedAssetCount: { 0 }, searchEvidence: nil, locationEvidence: evidence)
            let waiter = try #require(await observations.next())
            #expect(waiter.0 == "waiter")
            #expect(waiter.1 >= .utility)
            let escalated = try #require(await observations.next())
            #expect(escalated.0 == "escalated")
            #expect(escalated.1 >= waiter.1)
            release.continuation.yield(())
            release.continuation.finish()
            let analysis = try #require(await observations.next())
            #expect(analysis.0 == "analysis")
            #expect(analysis.1 >= waiter.1)
            print(
                "ISSUE683 actual-route=automatic-search waiter=\(waiter.1.rawValue) detached-analysis=\(analysis.1.rawValue)"
            )
            await scheduler.waitForRefreshForTesting()
            #expect(evidence.hasAnalyzed)
            #expect(scheduler.discovery.lastRefreshCompleted)
            events.continuation.finish()
        }
    }
#endif
