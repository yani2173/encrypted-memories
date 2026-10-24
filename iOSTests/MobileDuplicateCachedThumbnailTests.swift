import CryptoKit
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import SwiftUI
import UIKit
import UploadFeature
import XCTest

@testable import EncryptedMemoriesMobile

@MainActor
final class MobileDuplicateCachedThumbnailTests: XCTestCase {
    func testDuplicatesListShowsTheCachedPhotoOutsideThePartialInventory() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let duplicates = try XCTUnwrap(fixture.library.duplicates)
        await duplicates.load()
        fixture.show(
            NavigationStack {
                MobileDuplicatesScreen(model: duplicates, feed: fixture.feed)
                    .environment(fixture.library).environment(MobileViewerRouter())
            })
        // The backend has no thumbnail or preview bytes, so a red image can only come from the encrypted cache.
        XCTAssertTrue(fixture.backend.thumbnails.isEmpty)
        try await waitUntil { hasRedPixels(fixture.root.view) }
        XCTAssertTrue(hasRedPixels(fixture.root.view), "the cached Duplicates tile must replace the loading glyph")
        XCTAssertNil(fixture.feed.memoryImage(for: fixture.item.uid), "the library grid remains unauthorized")
        XCTAssertTrue(fixture.feed.feedCore.openVisibleThumbnailAccessUIDs.contains(fixture.item.uid))
        fixture.show(Color.black)
        try await waitUntilRevoked(fixture.feed)
        let accepted = await fixture.feed.feedCore.requestPriority(fixture.item.uid)
        XCTAssertFalse(accepted)
    }

    func testDuplicatesViewerShowsTheCachedFirstFrameWithoutAPreview() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let duplicates = try XCTUnwrap(fixture.library.duplicates)
        fixture.show(
            MobilePhotoViewer(
                items: [fixture.item], startIndex: 0, context: .library,
                libraryModel: fixture.library, viewerRouter: MobileViewerRouter(),
                duplicateGroup: MobileDuplicateViewerGroup(model: duplicates)))
        // The backend has no thumbnail or preview bytes, so a red image can only come from the encrypted cache.
        XCTAssertTrue(fixture.backend.thumbnails.isEmpty)
        try await waitUntil { viewerHasRedImage(fixture.root.view) }
        XCTAssertTrue(viewerHasRedImage(fixture.root.view), "the first frame must come from the cached thumbnail")
        fixture.show(Color.black)
        try await waitUntilRevoked(fixture.feed)
        let accepted = await fixture.feed.feedCore.requestPriority(fixture.item.uid)
        XCTAssertFalse(accepted)
    }

    /// A full-screen cover over the viewer, such as the series selection, ends the viewer's thumbnail access; the
    /// filmstrip cell keeps its own. When the cover closes, the shown copy needs the viewer's access again.
    func testDuplicatesViewerReopensItsThumbnailAccessWhenACoverCloses() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let duplicates = try XCTUnwrap(fixture.library.duplicates)
        let uid = fixture.item.uid
        let openAccesses = { fixture.feed.feedCore.openVisibleThumbnailAccessUIDs }
        fixture.show(
            MobilePhotoViewer(
                items: [fixture.item], startIndex: 0, context: .library,
                libraryModel: fixture.library, viewerRouter: MobileViewerRouter(),
                duplicateGroup: MobileDuplicateViewerGroup(model: duplicates)))
        try await waitUntil { openAccesses() == [uid, uid] }
        XCTAssertEqual(openAccesses(), [uid, uid], "the viewer and its filmstrip cell read the shown copy")

        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        fixture.root.present(cover, animated: false)
        try await waitUntil { openAccesses() == [uid] }
        XCTAssertEqual(openAccesses(), [uid], "the cover ends the viewer's access")
        fixture.root.dismiss(animated: false)

        try await waitUntil { openAccesses() == [uid, uid] }
        XCTAssertEqual(openAccesses(), [uid, uid], "the viewer opens the access of the shown copy again")
        fixture.show(Color.black)
        try await waitUntilRevoked(fixture.feed)
    }

    func testDuplicatesViewerFilmstripShowsItsCachedCopyAndRevokesOnClose() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.show(
            MobileViewerFilmstrip(
                items: [fixture.item], selectedUID: fixture.item.uid, feed: fixture.feed, itemSide: 64,
                allowsVisibleDuplicateThumbnails: true, onSelect: { _ in }))
        // The backend has no thumbnail or preview bytes, so a red image can only come from the encrypted cache.
        XCTAssertTrue(fixture.backend.thumbnails.isEmpty)
        try await waitUntil { filmstripHasRedImage(fixture.root.view) }
        XCTAssertTrue(
            filmstripHasRedImage(fixture.root.view), "the visible filmstrip copy must render its encrypted cache")
        XCTAssertEqual(fixture.feed.feedCore.openVisibleThumbnailAccessUIDs, [fixture.item.uid])
        fixture.show(Color.black)
        try await waitUntilRevoked(fixture.feed)
        let accepted = await fixture.feed.feedCore.requestPriority(fixture.item.uid)
        XCTAssertFalse(accepted)
    }

    /// Polls until the condition holds. The limit only guards against a hang; a saturated hosted runner may need
    /// several seconds, so the tests prove the image source instead of measuring time.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(10), !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// SwiftUI tears a removed view down on a later main-actor turn.
    private func waitUntilRevoked(_ feed: UIKitThumbnailFeed) async throws {
        try await waitUntil { feed.feedCore.openVisibleThumbnailAccessUIDs.isEmpty }
        XCTAssertEqual(feed.feedCore.openVisibleThumbnailAccessUIDs, [], "a removed surface revokes its access")
    }

    private func viewerHasRedImage(_ view: UIView) -> Bool {
        if view is UICollectionView { return false }
        if let image = (view as? UIImageView)?.image?.cgImage, isRed(image) { return true }
        return view.subviews.contains { viewerHasRedImage($0) }
    }

    private func filmstripHasRedImage(_ view: UIView) -> Bool {
        if let strip = view as? MobileViewerFilmstripCollectionView {
            return strip.visibleCells.contains { imageIsRed($0) }
        }
        return view.subviews.contains { filmstripHasRedImage($0) }
    }

    private func imageIsRed(_ view: UIView) -> Bool {
        if let image = (view as? UIImageView)?.image?.cgImage, isRed(image) { return true }
        return view.subviews.contains { imageIsRed($0) }
    }

    private func hasRedPixels(_ view: UIView) -> Bool {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        guard let cg = image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                    bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return stride(from: 0, to: bytes.count, by: 4).contains { index in
                bytes[index] > 200 && bytes[index + 1] < 50 && bytes[index + 2] < 50 && bytes[index + 3] > 200
            }
        }
    }

    private func isRed(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        return pixel.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return bytes[0] > 200 && bytes[1] < 50 && bytes[2] < 50 && bytes[3] > 200
        }
    }

    @MainActor private final class Fixture {
        let seed: MobileSignedInFixture
        let library = MobileLibraryModel()
        let feed: UIKitThumbnailFeed
        let backend: MobileFixtureBackend
        let item: PhotoItem
        let root = UIHostingController(rootView: AnyView(Color.black))
        let window: UIWindow
        let previous: UIWindow?
        let directory: URL

        init() async throws {
            seed = try await MobileSignedInFixture(itemsPerSection: 2)
            item = seed.items[0]
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let cache = ThumbnailCache(rootDirectory: directory)
            cache.configure(accountUID: "fixture", key: SymmetricKey(size: .bits256))
            let red = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            }
            cache.storeToDisk(try XCTUnwrap(red.pngData()), for: item.uid)
            backend = MobileFixtureBackend(sections: seed.sections, thumbnails: [:])
            feed = UIKitThumbnailFeed(cache: cache, loader: backend)
            await feed.feedCore.setPrefetchEnabled(false)
            seed.install(
                into: library, backend: backend, sections: seed.sections,
                thumbnailFeed: feed, thumbnailCache: cache)
            library.installIsolatedDuplicatesForTesting(
                MobileFixtureDuplicates(groups: [Array(seed.items.prefix(2)).map(\.uid)]))
            let graph = LibrarySourceGraph()
            let source = LibrarySource(id: SourceID("partial"), capabilities: .readThumbnail)
            _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
            let change = try XCTUnwrap(graph.installCachedInventory([.complete(seed.items[2])], for: source.id))
            let bound = await feed.feedCore.bindDerivedDataEpoch(graph.runtimeEpoch)
            XCTAssertTrue(bound)
            _ = await feed.feedCore.reconcile(
                selected: change.selectedScope, analysis: change.analysisScope,
                retention: change.thumbnailRetentionScope)
            XCTAssertEqual(cache.diskFileCount(), 1)
            XCTAssertNil(feed.memoryImage(for: item.uid))
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = root
            window.makeKeyAndVisible()
        }

        func show(_ view: some View) { root.rootView = AnyView(view) }

        func close() {
            root.rootView = AnyView(Color.black)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            seed.removeCache()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
