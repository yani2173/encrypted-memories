import AlbumCore
import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerCore
import PhotoViewerFeature
import PhotosCore
import XCTest

final class PhotoMetadataLoadStateTests: XCTestCase {
    @MainActor
    func testUnprovenLocationShowsDateTitleBeforeMetadataCompletes() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-title-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "no-location"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "metadata-title-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: SuspendedMetadataProvider()
        )

        XCTAssertEqual(model.titleMetadataState, .resolving)
        XCTAssertFalse(model.isPlaceNameResolving)
        model.stop()
    }

    @MainActor
    func testKnownLocationKeepsThePlaceNameLineWhileMetadataResolvesAndFollowsTheIndex() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-known-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "located"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        var indexKnowsTheLocation = false
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "metadata-known-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: SuspendedMetadataProvider(),
            hasKnownLocation: { $0 == item.uid && indexKnowsTheLocation }
        )

        XCTAssertEqual(model.titleMetadataState, .resolving)
        XCTAssertFalse(model.isPlaceNameResolving, "an unknown location shows the date at once")
        indexKnowsTheLocation = true
        XCTAssertTrue(model.isPlaceNameResolving, "a location that the index learns later reserves the line")
        model.stop()
    }

    @MainActor
    func testFailureCanRetryToLoadedMetadata() async {
        let provider = RetryMetadataProvider()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-state-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "metadata-state-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: provider
        )
        model.start()
        model.toggleInfo()
        await waitUntil { model.metadataLoadState == .failed }

        model.retryMetadata()
        await waitUntil { model.metadataLoadState.metadata?.filename == "IMG_0001.HEIC" }
        model.stop()

        XCTAssertEqual(model.metadata?.filename, "IMG_0001.HEIC")
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testInfoPanelLoadsAlbumMembershipTitlesForDisplayedPhoto() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-membership-state-\(UUID().uuidString)", isDirectory: true)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg"
        )
        let memberships = StaticAlbumMembershipProvider(titles: ["Family", "Summer"])
        let model = PhotoViewerModel(
            items: [item],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "album-membership-\(UUID().uuidString)", rootDirectory: root),
                loader: MetadataEmptyThumbnailLoader()
            ),
            media: MetadataFailingMediaProvider(),
            metadataProvider: RetryMetadataProvider(),
            albumMembershipProvider: memberships
        )

        model.toggleInfo()
        await waitUntil { model.albumTitles == ["Family", "Summer"] }
        model.stop()

        XCTAssertFalse(model.isLoadingAlbumMemberships)
        XCTAssertFalse(model.albumMembershipsLoadFailed)
        let requestedUIDs = await memberships.requestedUIDs
        XCTAssertEqual(requestedUIDs, [item.uid])
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private actor StaticAlbumMembershipProvider: PhotoAlbumMembershipProviding {
    let titles: [String]
    private(set) var requestedUIDs: [PhotoUID] = []

    init(titles: [String]) {
        self.titles = titles
    }

    func albumMembershipTitles(for photoUID: PhotoUID) async throws -> [String] {
        requestedUIDs.append(photoUID)
        return titles
    }
}

private actor RetryMetadataProvider: PhotoMetadataProvider {
    private(set) var requestCount = 0

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        requestCount += 1
        if requestCount == 1 { throw MetadataTestError.unavailable }
        return PhotoMetadata(filename: "IMG_0001.HEIC")
    }
}

private actor SuspendedMetadataProvider: PhotoMetadataProvider {
    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        try await Task.sleep(for: .seconds(10))
        return PhotoMetadata()
    }
}
