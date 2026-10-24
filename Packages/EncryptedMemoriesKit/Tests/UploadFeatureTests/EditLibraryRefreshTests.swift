import Foundation
import MediaByteCache
import MediaCache
import PhotosCore
import TimelineCore
import XCTest

@testable import ProtonDriveBackend

final class EditLibraryRefreshTests: XCTestCase {
    @MainActor
    func testAllPhotosAfterAViewSwitchShowsTheEditedServerLibrary() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        try await harness.enqueue()
        await harness.drain()
        let earlier = try harness.liveMain()
        let repository = EditLibraryRepository(server: harness.server)
        let feed = makeFeed(directory: harness.directory)
        let model = TimelineViewModel(repository: repository, feed: feed.feedCore, library: repository)
        await model.load()
        XCTAssertEqual(model.allItems.map(\.uid), [earlier])

        await model.select(.tag(.favorites))
        harness.library.edit("render-after-view-switch", at: harness.clock.now)
        try await harness.enqueue()
        await harness.drain()
        let edited = try harness.liveMain()
        XCTAssertNotEqual(edited, earlier)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
        // The retained All Photos snapshot predates the edit. Returning must read the server again.
        XCTAssertEqual(model.wholeLibraryUIDs, [earlier])
        await model.select(.all)

        XCTAssertEqual(model.gridItems.map(\.uid), [edited])
        XCTAssertEqual(model.wholeLibraryUIDs, [edited])
        XCTAssertEqual(model.wholeLibraryItemsForViewer, repository.serverItems)
        await feed.stopPrefetch()
    }

    func testASecondEventDuringALaggingListingDoesNotShowTheReplacedPhoto() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        try await harness.enqueue()
        await harness.drain()
        let earlier = try harness.liveMain()
        harness.library.edit("render-with-lagging-listing", at: harness.clock.now)
        try await harness.enqueue()
        await harness.drain()
        let edited = try harness.liveMain()
        XCTAssertNotEqual(earlier, edited)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
        let repository = EditLibraryRepository(server: harness.server)
        var removals = RecentlyDeletedIdentities(listing: nil)
        let firstReadAt = harness.clock.now
        let firstChanged = removals.eventsRead(
            .init(active: [edited.nodeID], removed: [earlier.nodeID]), volumeID: "vol", at: firstReadAt)
        XCTAssertTrue(firstChanged)
        let first = repository.listing(includingTrashed: [earlier])
        let firstRead = LibraryListingRead(listed: Set(first.map(\.uid)), readAt: firstReadAt)
        XCTAssertTrue(firstRead.listed.contains(earlier), "The raw server listing must actually lag")
        let firstVisible = TimelineContentProjection(sections: sections(first))
            .removing(removals.lagging(in: firstRead, now: firstReadAt)).snapshot.items
        XCTAssertEqual(firstVisible, repository.serverItems)
        _ = removals.libraryAccepted(firstRead, now: firstReadAt)
        XCTAssertTrue(removals.hasPhotosAwaitingLibrary, "Filtering a listing must not settle the removal")

        // The first load consumed the removal event. A later upload starts another load before the listing catches up.
        let other = harness.server.seedLink(digest: Data("another-photo".utf8))
        harness.clock.advance(by: 40)
        _ = removals.eventsRead(.init(active: [other.nodeID]), volumeID: "vol", at: harness.clock.now)
        let second = repository.listing(includingTrashed: [earlier])
        let secondRead = LibraryListingRead(listed: Set(second.map(\.uid)), readAt: harness.clock.now)
        XCTAssertTrue(secondRead.listed.contains(earlier))
        let secondVisible = TimelineContentProjection(sections: sections(second))
            .removing(removals.lagging(in: secondRead, now: harness.clock.now)).snapshot.items
        XCTAssertEqual(secondVisible, repository.serverItems)
        XCTAssertFalse(secondVisible.contains { $0.uid == earlier })
        _ = removals.libraryAccepted(secondRead, now: harness.clock.now)
        XCTAssertTrue(removals.hasPhotosAwaitingLibrary)

        harness.clock.advance(by: 50)
        let caughtUp = LibraryListingRead(listed: Set(repository.serverItems.map(\.uid)), readAt: harness.clock.now)
        _ = removals.libraryAccepted(caughtUp, now: harness.clock.now)
        XCTAssertFalse(removals.hasPhotosAwaitingLibrary, "A raw listing without the photo settles the wait")
        harness.server.personRestore(earlier)
        _ = removals.eventsRead(.init(active: [earlier.nodeID]), volumeID: "vol", at: harness.clock.now)
        let restored = LibraryListingRead(listed: Set(repository.serverItems.map(\.uid)), readAt: harness.clock.now)
        XCTAssertTrue(restored.listed.contains(earlier), "An explicit server restore must remain visible")
        XCTAssertTrue(removals.lagging(in: restored, now: harness.clock.now).isEmpty)
    }

    @MainActor
    private func makeFeed(directory: URL) -> ThumbnailFeed {
        ThumbnailFeed(
            cache: ThumbnailCache(
                namespace: "edit-library-refresh-\(UUID().uuidString)",
                rootDirectory: directory.appendingPathComponent("thumbnails")),
            loader: EmptyEditLibraryThumbnails())
    }

    private func sections(_ items: [PhotoItem]) -> [TimelineSection] {
        [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
    }
}

/// Every route reads the same uploaded links as replacement and dedupe. Related files never become library tiles.
struct EditLibraryRepository: PhotosRepository, PhotoLibraryProvider {
    let server: EditScenarioServer

    var serverItems: [PhotoItem] { listing(includingTrashed: []) }

    func listing(includingTrashed lagging: Set<PhotoUID>) -> [PhotoItem] {
        server.links.filter {
            $0.mainLinkID == nil && ($0.state == .active || ($0.state == .trashed && lagging.contains($0.uid)))
        }.map {
            PhotoItem(
                uid: $0.uid, captureTime: $0.captureTime, mediaType: $0.mimeType,
                tags: Set($0.tags.compactMap(PhotoTag.init(rawValue:))))
        }.sorted(by: TimelineOrder.areInIncreasingOrder)
    }

    func loadTimeline() async throws -> [TimelineSection] {
        let items = serverItems
        return [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
    }

    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        let items = server.links.filter { $0.mainLinkID == nil && $0.state == .active && $0.favorite }.map {
            PhotoItem(
                uid: $0.uid, captureTime: $0.captureTime, mediaType: $0.mimeType,
                tags: Set($0.tags.compactMap(PhotoTag.init(rawValue:))))
        }.sorted(by: TimelineOrder.areInIncreasingOrder)
        return [
            TimelineSection(id: "favorites", date: items.first?.captureTime ?? .distantPast, title: "", items: items)
        ]
    }
}

private struct EmptyEditLibraryThumbnails: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { ThumbnailBatchLoadResult() }
}
