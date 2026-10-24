#if os(macOS)
    import AppKit
    import CryptoKit
    import MediaByteCache
    import MediaCache
    import PhotoViewerFeature
    import PhotosCore
    import SwiftUI
    import UploadFeature
    import XCTest

    @MainActor
    final class ExactDuplicateCachedThumbnailTests: XCTestCase {
        func testCachedDuplicatesTileRendersOutsideThePartialLibrary() async throws {
            let fixture = try await makeFixture()
            let host = NSHostingView(
                rootView: ExactDuplicateThumbnail(
                    uid: fixture.item.uid, side: 64, cornerRadius: 6,
                    thumbnails: ExactDuplicateThumbnails(feedCore: fixture.feed.feedCore)))
            let window = show(host, size: NSSize(width: 64, height: 64))
            defer { window.orderOut(nil) }
            try await waitUntil { isRed(host) }
            XCTAssertTrue(isRed(host), "the cached photo must replace the glyph")
            XCTAssertNil(fixture.feed.memoryImage(for: fixture.item.uid), "the grid remains unauthorized")
            XCTAssertEqual(fixture.feed.feedCore.openVisibleThumbnailAccessUIDs, [fixture.item.uid])
            window.contentView = NSView()
            try await waitUntilRevoked(fixture.feed)
            let accepted = await fixture.feed.feedCore.requestPriority(fixture.item.uid)
            XCTAssertFalse(accepted)
        }

        func testDuplicatesViewerShowsTheCachedThumbnailBeforeItsPreview() async throws {
            let fixture = try await makeFixture()
            let viewer = PhotoViewerModel(
                items: [fixture.item], index: 0, feed: fixture.feed, media: NoPreview(),
                allowsVisibleDuplicateThumbnails: true)
            defer { viewer.stop() }
            viewer.start()
            try await waitUntil { viewer.image != nil }
            XCTAssertNotNil(viewer.image, "the Duplicates viewer must show the cached first frame")
            XCTAssertFalse(viewer.isSharp, "this evidence must come from the thumbnail, not an original")
            XCTAssertEqual(fixture.feed.feedCore.openVisibleThumbnailAccessUIDs, [fixture.item.uid])
            viewer.stop()
            XCTAssertEqual(fixture.feed.feedCore.openVisibleThumbnailAccessUIDs, [], "closing the viewer revokes")
            let accepted = await fixture.feed.feedCore.requestPriority(fixture.item.uid)
            XCTAssertFalse(accepted)
        }

        func testDuplicatesViewerSidebarRendersTheCachedFilmstrip() async throws {
            let fixture = try await makeFixture()
            let viewer = PhotoViewerModel(
                items: [fixture.item], index: 0, feed: fixture.feed, media: NoPreview(),
                allowsVisibleDuplicateThumbnails: true)
            // Released after removal, as a closed viewer is, so SwiftUI dismantles the filmstrip.
            var host: NSHostingView<PhotoViewerView>? = NSHostingView(
                rootView: PhotoViewerView(model: viewer, onClose: {}, itemFilmstripLabel: "Copies"))
            let window = show(try XCTUnwrap(host), size: NSSize(width: 800, height: 600))
            defer {
                window.orderOut(nil)
                viewer.stop()
            }
            try await waitUntil { filmstripHasImage(try XCTUnwrap(host)) }
            XCTAssertTrue(
                filmstripHasImage(try XCTUnwrap(host)), "the visible sidebar tile must show its cached thumbnail")
            viewer.stop()
            XCTAssertEqual(
                fixture.feed.feedCore.openVisibleThumbnailAccessUIDs, [fixture.item.uid],
                "only the visible filmstrip copy keeps an access")
            window.contentView = NSView()
            host = nil
            try await waitUntilRevoked(fixture.feed)
            let accepted = await fixture.feed.feedCore.requestPriority(fixture.item.uid)
            XCTAssertFalse(accepted)
        }

        private func makeFixture() async throws -> (feed: ThumbnailFeed, item: PhotoItem) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let cache = ThumbnailCache(namespace: "duplicates-test", rootDirectory: root)
            cache.configure(accountUID: "fixture", key: SymmetricKey(size: .bits256))
            let item = PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: UUID().uuidString), captureTime: .distantPast,
                mediaType: "image/png")
            let image = NSImage(size: NSSize(width: 24, height: 24))
            image.lockFocus()
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            image.unlockFocus()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            cache.storeToDisk(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), for: item.uid)
            XCTAssertNotNil(cache.diskData(for: item.uid))
            let feed = ThumbnailFeed(cache: cache, loader: NoThumbnails())
            await feed.feedCore.setPrefetchEnabled(false)
            let graph = LibrarySourceGraph()
            let source = LibrarySource(id: SourceID("partial-library"), capabilities: .readThumbnail)
            _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
            let listed = PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "listed"), captureTime: .distantPast, mediaType: "image/png")
            let change = try XCTUnwrap(graph.installCachedInventory([.complete(listed)], for: source.id))
            let bound = await feed.feedCore.bindDerivedDataEpoch(graph.runtimeEpoch)
            XCTAssertTrue(bound)
            _ = await feed.feedCore.reconcile(
                selected: change.selectedScope, analysis: change.analysisScope,
                retention: change.thumbnailRetentionScope)
            XCTAssertEqual(cache.diskFileCount(), 1)
            XCTAssertNil(feed.memoryImage(for: item.uid))
            addTeardownBlock { await feed.feedCore.stopPrefetchAndWait() }
            return (feed, item)
        }

        /// Waits until `condition` holds. The deadline is only a guard against a hang: no test bounds how fast the
        /// image appears, because a loaded runner cannot promise a speed.
        private func waitUntil(_ condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while try !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// SwiftUI tears a removed view down on a later main-actor turn.
        private func waitUntilRevoked(_ feed: ThumbnailFeed) async throws {
            try await waitUntil { feed.feedCore.openVisibleThumbnailAccessUIDs.isEmpty }
            XCTAssertEqual(feed.feedCore.openVisibleThumbnailAccessUIDs, [], "a removed surface revokes its access")
        }

        private func show(_ view: NSView, size: NSSize) -> NSWindow {
            view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            return window
        }

        private func isRed(_ view: NSView) -> Bool {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.cgImage.map(centerIsRed) ?? false
        }

        /// Draws the center pixel into device RGB, so the check does not depend on the image's color space.
        private func centerIsRed(_ image: CGImage) -> Bool {
            let center = CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)
            guard let pixel = image.cropping(to: center) else { return false }
            var bytes = [UInt8](repeating: 0, count: 4)
            return bytes.withUnsafeMutableBytes { buffer in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return buffer[0] > 200 && buffer[1] < 80 && buffer[2] < 80 && buffer[3] > 200
            }
        }

        private func filmstripHasImage(_ view: NSView) -> Bool {
            view.layoutSubtreeIfNeeded()
            if let collection = view as? NSCollectionView {
                return collection.visibleItems().contains { hasImageLayer($0.view.layer) }
            }
            return view.subviews.contains { filmstripHasImage($0) }
        }

        private func hasImageLayer(_ layer: CALayer?) -> Bool {
            guard let layer else { return false }
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID,
                centerIsRed(contents as! CGImage)
            {
                return true
            }
            return (layer.sublayers ?? []).contains { hasImageLayer($0) }
        }

        private struct NoPreview: FullMediaProvider {
            func preview(for uid: PhotoUID) async throws -> Data { throw CancellationError() }
            func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data
            {
                throw CancellationError()
            }
        }

        private struct NoThumbnails: ThumbnailBatchLoader {
            func loadThumbnails(
                for uids: [PhotoUID], onLoaded: @escaping @Sendable (PhotoUID, Data) -> Void
            ) async
                -> ThumbnailBatchLoadResult
            {
                ThumbnailBatchLoadResult(
                    itemErrors: Dictionary(uniqueKeysWithValues: uids.map { ($0, "No thumbnail") }))
            }
        }
    }
#endif
