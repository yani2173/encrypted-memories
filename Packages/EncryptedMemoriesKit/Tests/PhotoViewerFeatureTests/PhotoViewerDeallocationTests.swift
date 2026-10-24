import AlbumCore
import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerFeature
import PhotosCore
import XCTest

final class PhotoViewerDeallocationTests: XCTestCase {
    @MainActor
    func testStoppedViewerReleasesWhileMetadataReadIsSuspended() async {
        let provider = SuspendedViewerReads()
        var model: PhotoViewerModel? = makeViewer(metadata: provider)
        weak var released = model
        model?.toggleInfo()
        await fulfillment(of: [provider.requested], timeout: 5)

        model?.stop()
        model = nil
        XCTAssertNil(released, "A cancelled metadata read must not retain the closed viewer")
        await provider.resume()
    }

    @MainActor
    func testStoppedViewerReleasesWhileTitleReadIsSuspended() async {
        let provider = SuspendedViewerReads()
        var model: PhotoViewerModel? = makeViewer(metadata: provider)
        weak var released = model
        model?.refreshPlaceNames()
        await fulfillment(of: [provider.requested], timeout: 5)

        model?.stop()
        model = nil
        XCTAssertNil(released, "A cancelled title read must not retain the closed viewer")
        await provider.resume()
    }

    @MainActor
    func testStoppedViewerReleasesWhileAlbumMembershipReadIsSuspended() async {
        let provider = SuspendedViewerReads()
        var model: PhotoViewerModel? = makeViewer(memberships: provider)
        weak var released = model
        model?.toggleInfo()
        await fulfillment(of: [provider.requested], timeout: 5)

        model?.stop()
        model = nil
        XCTAssertNil(released, "A cancelled album read must not retain the closed viewer")
        await provider.resume()
    }

    @MainActor
    func testStoppedViewerReleasesWhileBurstReadIsSuspended() async {
        let provider = SuspendedViewerReads()
        var model: PhotoViewerModel? = makeViewer(bursts: provider)
        weak var released = model
        model?.start()
        await fulfillment(of: [provider.requested], timeout: 5)

        model?.stop()
        model = nil
        // The cancelled image debounce can finish while the burst provider remains suspended.
        for _ in 0..<200 {
            if released == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(released, "A cancelled burst read must not retain the closed viewer")
        await provider.resume()
    }

    private let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("viewer-deallocation-\(UUID().uuidString)", isDirectory: true)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    @MainActor
    private func makeViewer(
        metadata: (any PhotoMetadataProvider)? = nil,
        memberships: (any PhotoAlbumMembershipProviding)? = nil,
        bursts: (any BurstGroupProvider)? = nil
    ) -> PhotoViewerModel {
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "photo"), captureTime: .distantPast, mediaType: "image/jpeg",
            tags: bursts == nil ? [] : [.bursts])
        return PhotoViewerModel(
            items: [item], index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "viewer-deallocation", rootDirectory: cacheRoot),
                loader: EmptyViewerThumbnails()),
            media: UnusedViewerMedia(), metadataProvider: metadata, albumMembershipProvider: memberships,
            burstProvider: bursts)
    }
}

private actor SuspendedViewerReads: PhotoMetadataProvider, PhotoAlbumMembershipProviding, BurstGroupProvider {
    nonisolated let requested = XCTestExpectation(description: "The provider suspended its read")
    private var continuation: CheckedContinuation<Void, Never>?

    private func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested.fulfill()
        }
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        await suspend()
        return PhotoMetadata()
    }

    func albumMembershipTitles(for photoUID: PhotoUID) async throws -> [String] {
        await suspend()
        return []
    }

    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {
        await suspend()
        return []
    }

    func resume() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private struct EmptyViewerThumbnails: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

private struct UnusedViewerMedia: FullMediaProvider {
    func preview(for uid: PhotoUID) async throws -> Data { throw CancellationError() }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw CancellationError()
    }
}
