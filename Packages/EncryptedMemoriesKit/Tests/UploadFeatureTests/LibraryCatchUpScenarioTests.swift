import Foundation
import MediaByteCache
import MediaCache
import PhotosCore
import XCTest

@testable import ProtonDriveBackend
@testable import TimelineCore

final class LibraryCatchUpScenarioTests: XCTestCase {
    @MainActor
    func testAnotherDeviceUploadsAfterFirstLoadSettlesDuringInactivity() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let original = harness.server.seedLink(digest: Data("first-photo".utf8))
        let repository = CatchUpEditRepository(server: harness.server)
        let feed = makeFeed(directory: harness.directory)
        let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
        await model.load()
        XCTAssertEqual(model.wholeLibraryUIDs, [original])
        let monitor = LibraryChangeMonitor()
        await monitor.restart(
            provider: repository, policy: policy, isActive: false, resetBaseline: true,
            initialToken: model.initialLibraryChangeToken
        ) { await Self.refresh(model) }
        let arriving = harness.server.seedLink(digest: Data("another-device-photo".utf8))
        await monitor.restart(provider: repository, policy: policy) { await Self.refresh(model) }
        await repository.waitForProbes(4)
        await monitor.stop()
        XCTAssertEqual(Set(model.wholeLibraryUIDs), [original, arriving])
        let observed1 = await repository.fullListings
        XCTAssertEqual(observed1, 2, "Initial load plus one remote catch-up; later probes do not list")
        await feed.stopPrefetch()
    }

    @MainActor
    func testLaggingListingRetriesWithoutAcknowledgingMissingPhoto() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        _ = harness.server.seedLink(digest: Data("first-photo".utf8))
        let repository = CatchUpEditRepository(server: harness.server)
        let feed = makeFeed(directory: harness.directory)
        let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
        await model.load()
        await repository.lagNextListing()
        let arriving = harness.server.seedLink(digest: Data("lagging-photo".utf8))
        let monitor = LibraryChangeMonitor()
        await monitor.start(provider: repository, policy: policy, initialToken: model.initialLibraryChangeToken) {
            await Self.refresh(model)
        }
        await repository.waitForProbes(5)
        await monitor.stop()
        XCTAssertTrue(model.wholeLibraryUIDs.contains(arriving))
        let observed2 = await repository.visibilityFailures
        XCTAssertEqual(observed2, 1)
        let observed3 = await repository.fullListings
        XCTAssertEqual(observed3, 3, "One initial, one lagging, one converged listing; no repeat after acknowledgement")
        let observed4 = await repository.persistedCursor
        let observed5 = await repository.currentCursor
        XCTAssertEqual(observed4, observed5)
        await feed.stopPrefetch()
    }

    @MainActor
    func testARefreshJoinsAnOlderCapturedLoadWithoutAcknowledgingTheNewerEvent() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        _ = harness.server.seedLink(digest: Data("first-photo".utf8))
        let repository = CatchUpEditRepository(server: harness.server)
        let feed = makeFeed(directory: harness.directory)
        let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
        await model.load()
        let baseline = model.initialLibraryChangeToken
        await repository.holdNextListing()
        let older = Task { try await repository.loadTimelineSnapshot() }
        await repository.waitUntilListingHeld()
        let arriving = harness.server.seedLink(digest: Data("upload-during-shared-load".utf8))
        let monitor = LibraryChangeMonitor()
        await monitor.start(provider: repository, policy: policy, initialToken: baseline) {
            let result = await model.refreshLibrary()
            await repository.recordPublishedToken(result.publishedLibraryChangeToken)
            return result.failureReason == nil ? .refreshed(token: result.publishedLibraryChangeToken) : .retry
        }
        await repository.waitUntilLoadJoined()
        await repository.releaseListing()
        _ = try await older.value
        await repository.waitForProbes(5)
        await monitor.stop()
        let tokens = await repository.publishedTokens
        XCTAssertEqual(tokens.first ?? nil, baseline, "The joined load publishes a, not the probe's b")
        XCTAssertTrue(model.wholeLibraryUIDs.contains(arriving))
        let listings = await repository.fullListings
        XCTAssertEqual(listings, 3, "Initial, older joined load, and one catch-up load; no later listing")
        await feed.stopPrefetch()
    }

    @MainActor
    func testCancelledSharedLoadDoesNotPublishOrAcknowledgeItsSnapshot() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let original = harness.server.seedLink(digest: Data("first-photo".utf8))
        let repository = CatchUpEditRepository(server: harness.server)
        let feed = makeFeed(directory: harness.directory)
        let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
        await model.load()
        _ = harness.server.seedLink(digest: Data("cancelled-photo".utf8))
        await repository.holdNextListing()
        let refresh = Task { await model.refreshLibrary() }
        await repository.waitUntilListingHeld()
        refresh.cancel()
        await repository.releaseListing()
        let result = await refresh.value
        XCTAssertEqual(result.failureReason, .cancelled)
        XCTAssertNil(result.publishedLibraryChangeToken)
        XCTAssertEqual(model.wholeLibraryUIDs, [original])
        await feed.stopPrefetch()
    }

    #if DEBUG
        @MainActor
        func testFilteredRefreshRetainsTokenUntilWholeLibraryPublishesAndThenStopsListing() async throws {
            let harness = try EditScenarioHarness()
            defer { try? harness.cleanup() }
            _ = harness.server.seedLink(digest: Data("first-photo".utf8))
            let repository = CatchUpEditRepository(server: harness.server)
            let feed = makeFeed(directory: harness.directory)
            let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
            await model.load()
            let baseline = model.initialLibraryChangeToken
            await model.select(.tag(.favorites))
            let arriving = harness.server.seedLink(digest: Data("remote-photo-while-filtered".utf8))
            await repository.blockSecondProbe()
            let monitor = LibraryChangeMonitor()
            await monitor.start(provider: repository, policy: policy, initialToken: baseline) {
                await Self.refresh(model)
            }
            await repository.waitForProbes(2)
            let observed6 = await monitor.testingBaseline()
            XCTAssertEqual(observed6, baseline, "A filtered snapshot must never acknowledge the whole library")
            let observed7 = await repository.persistedCursor
            XCTAssertEqual(observed7, baseline)
            let observed8 = await repository.fullListings
            XCTAssertEqual(observed8, 1)
            let observed9 = await repository.filteredListings
            XCTAssertEqual(observed9, 2, "One filter selection and one changed-token refresh")
            await model.select(.all, resuming: monitor)
            await repository.releaseProbe()
            await repository.waitForProbes(5)
            await monitor.stop()
            XCTAssertTrue(model.wholeLibraryUIDs.contains(arriving))
            let observed10 = await monitor.testingBaseline()
            let observed11 = await repository.currentCursor
            XCTAssertEqual(observed10, observed11)
            let observed12 = await repository.fullListings
            XCTAssertEqual(
                observed12, 3,
                "Initial, return to All Photos, and monitor acknowledgement; subsequent probes do not list")
            let observed13 = await repository.filteredListings
            XCTAssertEqual(observed13, 2)
            await feed.stopPrefetch()
        }

        @MainActor
        func testRemoteChangesOnAFilteredRouteRefreshOncePerTokenAndConfirmOnAllPhotos() async throws {
            let harness = try EditScenarioHarness()
            defer { try? harness.cleanup() }
            _ = harness.server.seedLink(digest: Data("first-photo".utf8))
            let repository = CatchUpEditRepository(server: harness.server)
            let feed = makeFeed(directory: harness.directory)
            let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
            await model.load()
            let baseline = model.initialLibraryChangeToken
            await model.select(.tag(.favorites))
            _ = harness.server.seedLink(digest: Data("first-remote-photo".utf8))
            let monitor = LibraryChangeMonitor()
            await monitor.start(provider: repository, policy: policy, initialToken: baseline) {
                await Self.refresh(model)
            }
            await repository.waitForProbes(8)
            let firstFiltered = await repository.filteredListings
            XCTAssertEqual(firstFiltered, 2, "One filter selection and exactly one refresh for the first change")
            let firstBaseline = await monitor.testingBaseline()
            XCTAssertEqual(firstBaseline, baseline, "A filtered route never installs a baseline")

            _ = harness.server.seedLink(digest: Data("second-remote-photo".utf8))
            await repository.waitForProbes(await repository.probeCount + 8)
            let secondFiltered = await repository.filteredListings
            XCTAssertEqual(secondFiltered, 3, "A newer token refreshes exactly once more, then stays quiet")
            let quietBaseline = await monitor.testingBaseline()
            XCTAssertEqual(quietBaseline, baseline)
            let quietFull = await repository.fullListings
            XCTAssertEqual(quietFull, 1, "A filtered route never lists the whole library")

            await model.select(.all, resuming: monitor)
            await repository.waitForBaseline(of: monitor)
            let confirmed = await monitor.testingBaseline()
            let cursor = await repository.currentCursor
            XCTAssertEqual(confirmed, cursor, "Returning to All Photos confirms the whole-library revision")
            await repository.waitForProbes(await repository.probeCount + 6)
            await monitor.stop()
            let fullListings = await repository.fullListings
            XCTAssertEqual(
                fullListings, 3, "Initial, return to All Photos and one confirmation; later probes do not list")
            let filteredListings = await repository.filteredListings
            XCTAssertEqual(filteredListings, 3)
            await feed.stopPrefetch()
        }
    #endif

    @MainActor
    private static func refresh(_ model: TimelineViewModel) async -> LibraryChangeRefreshOutcome {
        let result = await model.refreshLibrary()
        if result.failureReason == .scopeAccessLost { return .terminal }
        guard result.failureReason == nil else { return .retry }
        return result.refreshedOutcome
    }

    private var policy: LibraryChangePollingPolicy {
        .init(interval: .milliseconds(2), failureInterval: .milliseconds(2))
    }

    @MainActor
    private func makeFeed(directory: URL) -> ThumbnailFeed {
        ThumbnailFeed(
            cache: ThumbnailCache(rootDirectory: directory.appendingPathComponent("catch-up-thumbnails")),
            loader: CatchUpEmptyThumbnails())
    }
}

private actor CatchUpEditRepository: PhotosRepository, PhotoLibraryProvider, LibraryChangeTokenProvider {
    let base: EditLibraryRepository
    private(set) var fullListings = 0
    private(set) var filteredListings = 0
    private(set) var visibilityFailures = 0
    private(set) var persistedCursor: String?
    private var laggingItems: [PhotoItem]?
    private var loadTask: Task<TimelineLoadSnapshot, Error>?
    private var joinedLoads = 0
    private(set) var publishedTokens: [String?] = []
    private var holdsNextListing = false
    private var listingHeld = false
    private var heldListing: CheckedContinuation<Void, Never>?
    private(set) var probes = 0
    private var holdsSecondProbe = false
    private var heldProbe: CheckedContinuation<Void, Never>?
    init(server: EditScenarioServer) { base = EditLibraryRepository(server: server) }
    var currentCursor: String { "event-\(base.server.steps.count)" }
    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        if let loadTask {
            joinedLoads += 1
            return try await loadTask.value
        }
        let task = Task { try await self.performLoad() }
        loadTask = task
        defer { loadTask = nil }
        return try await task.value
    }
    private func performLoad() async throws -> TimelineLoadSnapshot {
        fullListings += 1
        let start = currentCursor
        let actual = base.serverItems
        let listed = laggingItems ?? actual
        laggingItems = nil
        if holdsNextListing {
            holdsNextListing = false
            listingHeld = true
            await withCheckedContinuation { heldListing = $0 }
        }
        let missing = Set(actual.map(\.uid)).subtracting(listed.map(\.uid))
        if !missing.isEmpty {
            let visibility = try await base.server.linkVisibility(of: missing.map(\.nodeID))
            let awaited = TimelineRemoteVisibilityRequirement.awaited(
                Set(missing.map(\.nodeID)), links: visibility, mainPhotos: [:])
            if !awaited.isEmpty {
                visibilityFailures += 1
                throw TimelineInventoryVisibilityError.remoteChangesNotVisible(awaited.count)
            }
        }
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: start, endEventToken: currentCursor, enrichmentComplete: true)
        persistedCursor = decision.persistedValidationToken
        let sections = [
            TimelineSection(id: "all", date: listed.first?.captureTime ?? .distantPast, title: "", items: listed)
        ]
        return TimelineLoadSnapshot(sections: sections, validationToken: decision.monitorBaseline)
    }
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        filteredListings += 1
        return try await base.timeline(filter: filter)
    }
    func libraryChangeToken() async throws -> String {
        probes += 1
        if holdsSecondProbe, probes == 2 {
            await withCheckedContinuation { heldProbe = $0 }
        }
        return currentCursor
    }
    func recordPublishedToken(_ token: String?) { publishedTokens.append(token) }
    func waitUntilLoadJoined() async { while joinedLoads == 0 { await Task.yield() } }
    func holdNextListing() { holdsNextListing = true }
    func waitUntilListingHeld() async { while !listingHeld { await Task.yield() } }
    func releaseListing() {
        heldListing?.resume()
        heldListing = nil
        listingHeld = false
    }
    func lagNextListing() { laggingItems = base.serverItems }
    func blockSecondProbe() { holdsSecondProbe = true }
    func releaseProbe() {
        holdsSecondProbe = false
        heldProbe?.resume()
        heldProbe = nil
    }
    var probeCount: Int { probes }
    func waitForBaseline(of monitor: LibraryChangeMonitor) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while await monitor.testingBaseline() != currentCursor, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
    func waitForProbes(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while probes < count, ContinuousClock.now < deadline { await Task.yield() }
    }
}

private struct CatchUpEmptyThumbnails: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult()
    }
}
