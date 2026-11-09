import AVFoundation
import AVKit
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// The photo information inspector of the production viewer: a trailing column beside the media in a regular
/// width window and a sheet in a compact width window, with the same viewer, pager and photo kept mounted while
/// the window resizes between the two (Split View, Slide Over, Stage Manager). This does not simulate a hinge.
///
/// The viewer is presented through the production route (`MobileViewerRouter` -> `.fullScreenCover(item:)`, as
/// `MobileMainTabView` does), not hosted directly as a window root. A directly hosted viewer takes a synthetic
/// resize path (window frame plus trait overrides, no presentation container) in which the native inspector split
/// collapses but leaves its 360 pt trailing content inset behind whenever the main thread is contended, for
/// example by the previous test's account teardown. The presented route resets the inset in every probe.
///
/// The cover is presented without animation. With the animated presentation, iPadOS 27 laid the split out during
/// the transition and never applied the inspector's content inset (photo under the column, pager 1032). This
/// fixture verifies the width adaptation, not the OS presentation transition; that initial-inset miss is recorded
/// as an open iPadOS 27 finding (Onyx: viewer-inspector-compact-viewport-regression).
final class MobileViewerInspectorTests: XCTestCase {
    @MainActor func testVideoSurfaceStaysInsideHorizontalSafeArea() async throws {
        let clip = try await makeVideoClip()
        defer { try? FileManager.default.removeItem(at: clip) }
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2, includesVideo: true)
        defer { fixture.removeCache() }
        var backend = fixture.backend
        backend.streamingAssetLoader = { _ in
            let asset = AVURLAsset(url: clip)
            return StreamingVideoAsset(asset: asset, retaining: asset)
        }
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        let router = MobileViewerRouter()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIHostingController(rootView: ViewerPresentationHost(router: router, libraryModel: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let videoIndex = try XCTUnwrap(fixture.items.firstIndex(where: \.isVideo))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.presentation = MobileViewerPresentation(
                index: videoIndex, items: fixture.items, context: ViewerCollectionContext(filter: .all),
                showsInfoInitially: false)
        }
        try await Task.sleep(for: .seconds(2))
        let viewer = try XCTUnwrap(root.presentedViewController, "SETUP: viewer presented")
        viewer.additionalSafeAreaInsets.right = 80
        viewer.view.setNeedsLayout()
        viewer.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        func findPlayer(_ controller: UIViewController) -> AVPlayerViewController? {
            if let player = controller as? AVPlayerViewController { return player }
            return controller.children.lazy.compactMap { findPlayer($0) }.first
        }
        let player = try XCTUnwrap(findPlayer(viewer), "SETUP: native video player must be mounted")
        XCTAssertEqual(player.player?.currentItem?.status, .readyToPlay, "SETUP: the local clip must be playable")
        let safe = viewer.view.safeAreaLayoutGuide.layoutFrame
        let frame = player.view.convert(player.view.bounds, to: viewer.view)
        XCTAssertGreaterThan(viewer.view.bounds.maxX - safe.maxX, 50, "SETUP: horizontal safe area is required")
        print("issue924 video frame=\(frame) safe=\(safe)")
        XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 1, "Video must remain inside the horizontal safe area")
        XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 1)
    }

    @MainActor func testPausedVideoKeepsPlayerStreamAndSeekTimeAcrossResizes() async throws {
        try await verifyVideoContinuity(playing: false)
    }

    @MainActor func testPlayingVideoKeepsPlayerStreamAndProgressAcrossResizes() async throws {
        try await verifyVideoContinuity(playing: true)
    }

    /// Window resizing is a hosted baseline, not a simulated fold or display handoff.
    @MainActor private func verifyVideoContinuity(playing: Bool) async throws {
        let clip = try await makeVideoClip(frameCount: 60)
        defer { try? FileManager.default.removeItem(at: clip) }
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2, includesVideo: true)
        defer { fixture.removeCache() }
        let lifetime = ViewerVideoLifetimeProbe()
        var backend = fixture.backend
        backend.streamingAssetLoader = { uid in
            lifetime.recordLoad(uid)
            return StreamingVideoAsset(asset: AVURLAsset(url: clip), retaining: lifetime)
        }
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        let router = MobileViewerRouter()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let originalBounds = scene.coordinateSpace.bounds
        window.frame = originalBounds
        let root = UIHostingController(rootView: ViewerPresentationHost(router: router, libraryModel: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let videoIndex = try XCTUnwrap(fixture.items.firstIndex(where: \.isVideo))
        let uid = fixture.items[videoIndex].uid
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.presentation = MobileViewerPresentation(
                index: videoIndex, items: fixture.items, context: ViewerCollectionContext(filter: .all),
                showsInfoInitially: false)
        }
        func findPlayers(_ controller: UIViewController) -> [AVPlayerViewController] {
            if let player = controller as? AVPlayerViewController { return [player] }
            return controller.children.flatMap(findPlayers)
        }
        try await waitForVideo("SETUP: production viewer mounts one ready player") {
            guard let viewer = root.presentedViewController else { return false }
            let controllers = findPlayers(viewer)
            return controllers.count == 1 && controllers[0].player?.currentItem?.status == .readyToPlay
        }
        let viewer = try XCTUnwrap(root.presentedViewController)
        let controller = try XCTUnwrap(findPlayers(viewer).first)
        let player = try XCTUnwrap(controller.player)
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertGreaterThan(playerItem.duration.seconds, 30, "SETUP: clip must outlast the resize sequence")
        player.pause()
        let seekCompleted = await player.seek(
            to: CMTime(seconds: 8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seekCompleted, "SETUP: native seek must complete")
        try await waitForVideo("SETUP: pause and seek reach the requested position") {
            player.timeControlStatus == .paused && abs(player.currentTime().seconds - 8) < 0.1
        }
        if playing {
            player.play()
            try await waitForVideo("SETUP: video actually progresses before resizing") {
                player.timeControlStatus == .playing && player.currentTime().seconds > 8.2
            }
        }
        let sizes = [
            CGSize(width: 466, height: 678), CGSize(width: 951, height: 669), originalBounds.size,
        ]
        var report: [String] = []
        for (step, size) in sizes.enumerated() {
            let before = player.currentTime().seconds
            let traits: UIUserInterfaceSizeClass = size.width > 820 ? .regular : .compact
            window.traitOverrides.horizontalSizeClass = traits
            root.traitOverrides.horizontalSizeClass = traits
            viewer.traitOverrides.horizontalSizeClass = traits
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(window.bounds.size, size, "step \(step): the requested resize must occur")
            let mounted = findPlayers(viewer)
            XCTAssertEqual(mounted.count, 1, "step \(step): exactly one native controller stays mounted")
            XCTAssertTrue(mounted.first === controller, "step \(step): resize retains the native controller")
            XCTAssertTrue(controller.player === player, "step \(step): resize retains the player")
            XCTAssertTrue(player.currentItem === playerItem, "step \(step): resize retains the stream's item")
            XCTAssertEqual(lifetime.loadedUIDs, [uid], "step \(step): resize must not reload the stream")
            XCTAssertEqual(lifetime.closeCount, 0, "step \(step): resize must not close the live stream")
            XCTAssertEqual(router.presentation?.items[videoIndex].uid, uid)
            if playing {
                try await waitForVideo("step \(step): playback continues after resizing") {
                    player.timeControlStatus == .playing && player.currentTime().seconds > before + 0.2
                }
            } else {
                XCTAssertEqual(player.timeControlStatus, .paused, "step \(step): resize must not resume playback")
                XCTAssertEqual(player.currentTime().seconds, 8, accuracy: 0.1, "step \(step): seek time survives")
            }
            report.append("step=\(step) size=\(size) time=\(player.currentTime().seconds) playing=\(playing)")
        }
        withTransaction(transaction) { router.presentation = nil }
        try await waitForVideo("Closing the viewer releases its stream") { lifetime.closeCount == 1 }
        XCTAssertNil(player.currentItem, "Closing the viewer detaches the native item")
        XCTAssertEqual(lifetime.loadedUIDs, [uid])
        XCTAssertEqual(lifetime.closeCount, 1)
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = playing ? "playing-video-resize" : "paused-video-resize"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func waitForVideo(_ message: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try XCTUnwrap(condition() ? true : nil, message)
    }

    private func makeVideoClip(frameCount: Int = 3) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 160])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 160,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let data = CVPixelBufferGetBaseAddress(frame) {
            memset(data, 128, CVPixelBufferGetDataSize(frame))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<frameCount {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try XCTUnwrap(
                input.isReadyForMoreMediaData ? true : nil,
                "SETUP: frame \(index) was not accepted before the deadline; status=\(writer.status) error=\(String(describing: writer.error))"
            )
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "SETUP: local video generation must succeed")
        return url
    }

    @MainActor func testInspectorAdaptsBetweenColumnAndSheetWhileTheViewerStaysMounted() async throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad, "column-to-sheet adaptation requires an iPad window")
        try await verifyViewer(inspector: true)
    }

    @MainActor func testViewerPreservesPhotoAndZoomAcrossPhoneRotation() async throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone, "this probe covers phone safe areas during rotation")
        try await verifyViewer(inspector: false)
    }

    @MainActor private func verifyViewer(inspector: Bool) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let router = MobileViewerRouter()
        let fullBounds = scene.coordinateSpace.bounds
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = fullBounds
        let root = UIHostingController(rootView: ViewerPresentationHost(router: router, libraryModel: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        // Present without animation: see the type comment.
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            router.presentation = MobileViewerPresentation(
                index: 2, items: fixture.items, context: ViewerCollectionContext(filter: .all),
                showsInfoInitially: inspector)
        }
        try await Task.sleep(for: .seconds(2))
        let viewerHost = try XCTUnwrap(
            root.presentedViewController, "the router presents the production viewer as a full-screen cover")
        var report: [String] = []
        defer { writeArtifact("viewer-inspector-report.txt", Data(report.joined(separator: "\n").utf8)) }

        func pager() -> UIPageViewController? {
            var result: UIPageViewController?
            func walk(_ controller: UIViewController?) {
                guard let controller, result == nil else { return }
                if let pageController = controller as? UIPageViewController { result = pageController }
                controller.children.forEach(walk)
            }
            walk(viewerHost)
            return result
        }
        /// The zoomable media viewport of the current page: the UIScrollView of MobileZoomableImage, identified by
        /// its zoomable bounds (a plain UIScrollView defaults to equal minimum and maximum zoom scales).
        func zoomableViewport() throws -> UIScrollView {
            let pageController = try XCTUnwrap(pager(), "the production viewer hosts its UIPageViewController")
            let page = try XCTUnwrap(pageController.viewControllers?.first, "the pager hosts the current media page")
            var result: UIScrollView?
            func walk(_ view: UIView) {
                guard result == nil else { return }
                if let scrollView = view as? UIScrollView, scrollView.maximumZoomScale > scrollView.minimumZoomScale {
                    result = scrollView
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(page.view)
            return try XCTUnwrap(result, "the media page hosts the zoomable UIScrollView of MobileZoomableImage")
        }
        func layout(_ label: String) throws -> (viewportWidth: CGFloat, presented: Bool) {
            let pagerWidth = try XCTUnwrap(pager(), "the production viewer hosts its UIPageViewController").view.bounds
                .width
            let viewport = try zoomableViewport()
            let presented = viewerHost.presentedViewController != nil
            report.append(
                "\(label): window=\(Int(window.bounds.width)) controllerSizeClass=\(viewerHost.traitCollection.horizontalSizeClass.rawValue) pager=\(Int(pagerWidth)) viewport=\(Int(viewport.bounds.width)) presentedSheet=\(presented)"
            )
            return (viewport.bounds.width, presented)
        }
        let initialPager = try XCTUnwrap(pager(), "the production viewer hosts its UIPageViewController")
        let initialViewport = try zoomableViewport()
        let isRegular = window.traitCollection.horizontalSizeClass == .regular
        let initialSizeClass = window.traitCollection.horizontalSizeClass
        report.append("initial sizeClass regular=\(isRegular)")

        // Native chrome: the viewer's own navigation bar is mounted inside the cover, and the media surface keeps
        // the touch centre (the Live Photo press and the chrome tap land on the zoomable page, not on a bar).
        func viewerDescendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(viewerDescendants) }
        func verifyEdgeEffects(_ stage: String) throws {
            let strip = try XCTUnwrap(
                viewerDescendants(viewerHost.view).compactMap { $0 as? MobileViewerFilmstripCollectionView }.first,
                "The viewer must contain the route filmstrip")
            let pagerScroll = try XCTUnwrap(
                try XCTUnwrap(pager()).view.subviews.compactMap { $0 as? UIScrollView }.first,
                "The viewer must contain its native paging scroll view")
            for (name, scroll) in [
                ("filmstrip", strip as UIScrollView), ("pager", pagerScroll), ("photo", try zoomableViewport()),
            ] {
                XCTAssertTrue(scroll.leftEdgeEffect.isHidden, "\(stage): \(name) must hide its left edge effect")
                XCTAssertTrue(scroll.rightEdgeEffect.isHidden, "\(stage): \(name) must hide its right edge effect")
            }
        }
        try verifyEdgeEffects("initial")
        let viewerBars = viewerDescendants(viewerHost.view).filter { $0 is UINavigationBar }
        XCTAssertFalse(viewerBars.isEmpty, "the production viewer must mount a native navigation bar")
        let mediaCenter = initialViewport.convert(
            CGPoint(x: initialViewport.bounds.midX, y: initialViewport.bounds.midY), to: viewerHost.view)
        let centerHit = viewerHost.view.hitTest(mediaCenter, with: nil)
        XCTAssertTrue(
            centerHit.map { $0 === initialViewport || $0.isDescendant(of: initialViewport) } ?? false,
            "the media centre must hit-test to the zoomable page, not to chrome")
        let centerHitType = centerHit.map { String(describing: type(of: $0)) } ?? "nil"
        report.append("native chrome: navigationBars=\(viewerBars.count) centerHit=\(centerHitType)")

        func resize(_ bounds: CGRect, sizeClass: UIUserInterfaceSizeClass) {
            window.traitOverrides.horizontalSizeClass = sizeClass
            root.traitOverrides.horizontalSizeClass = sizeClass
            viewerHost.traitOverrides.horizontalSizeClass = sizeClass
            window.frame = bounds
            window.layoutIfNeeded()
        }

        // Regular width (iPad full window): the inspector is a trailing column, nothing is presented modally, and
        // the pager and its media viewport shrink beside the inspector. Compact width (iPhone, narrow iPad
        // window): the same information is a sheet over the
        // full-width media viewport.
        if inspector {
            let initial = try layout("initial")
            if isRegular {
                XCTAssertFalse(initial.presented, "regular width shows the inspector as a column, not a sheet")
                XCTAssertGreaterThanOrEqual(
                    window.bounds.width - initial.viewportWidth, 250,
                    "the media viewport leaves room for the inspector column")
            } else {
                XCTAssertTrue(initial.presented, "compact width shows the inspector as a sheet")
                XCTAssertEqual(
                    initial.viewportWidth, window.bounds.width, accuracy: 1,
                    "the media viewport fills the compact window")
            }
            snapshot(window, "viewer-inspector-\(isRegular ? "regular" : "compact")-initial")

            // Resize to a compact width and back; the viewer and its pager stay the same instances.
            let compactWidth = min(fullBounds.width, 420)
            // Changing a test UIWindow's frame does not change its scene's size-class traits.
            // Supply both inputs that a real compact iPad window receives from the system.
            let compactBounds = CGRect(x: 0, y: 0, width: compactWidth, height: fullBounds.height)
            resize(compactBounds, sizeClass: .compact)
            try await Task.sleep(for: .milliseconds(1500))
            let compact = try layout("compact")
            XCTAssertTrue(pager() === initialPager, "resizing must not remount the viewer pager")
            XCTAssertTrue(try zoomableViewport() === initialViewport, "resizing must not remount the current photo")
            // Native inspector adaptation differs by OS. It may hide the column on entering compact width.
            // If no sheet covers the photo, the photo must already fill the available width.
            if compact.presented {
                XCTAssertGreaterThan(compact.viewportWidth, 0)
            } else {
                XCTAssertEqual(compact.viewportWidth, compactWidth, accuracy: 1)
            }
            snapshot(window, "viewer-inspector-compact-after-resize")

            resize(fullBounds, sizeClass: initialSizeClass)
            try await Task.sleep(for: .milliseconds(1500))
            let restored = try layout("restored")
            XCTAssertTrue(pager() === initialPager, "resizing back must not remount the viewer pager")
            XCTAssertTrue(
                try zoomableViewport() === initialViewport, "resizing back must not remount the current photo")
            if isRegular {
                XCTAssertFalse(restored.presented, "regular width returns to the inspector column")
                XCTAssertGreaterThanOrEqual(window.bounds.width - restored.viewportWidth, 250)
            } else {
                XCTAssertTrue(restored.presented)
            }
            snapshot(window, "viewer-inspector-\(isRegular ? "regular" : "compact")-restored")

            resize(compactBounds, sizeClass: .compact)
            try await Task.sleep(for: .milliseconds(1500))
            if let sheet = viewerHost.presentedViewController {
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let bars = descendants(sheet.presentationController?.containerView ?? window).compactMap {
                    $0 as? UINavigationBar
                }
                let navigationItems = bars.flatMap { $0.items ?? [] }
                var toolbarItems: [UIBarButtonItem] = []
                for item in navigationItems {
                    toolbarItems.append(contentsOf: item.leftBarButtonItems ?? [])
                    toolbarItems.append(contentsOf: item.rightBarButtonItems ?? [])
                    for groups in [item.leadingItemGroups, item.centerItemGroups, item.trailingItemGroups] {
                        for group in groups { toolbarItems.append(contentsOf: group.barButtonItems) }
                    }
                }
                // This inspector's root toolbar has exactly one action: Close. SwiftUI does not expose its accessibility
                // label on the UIKit item in a hosted test. Require the unique action instead of guessing a private view.
                XCTAssertEqual(toolbarItems.count, 1, "the inspector root toolbar contains only its Close action")
                let closeItem = try XCTUnwrap(toolbarItems.first)
                let closeAction = try XCTUnwrap(closeItem.action)
                XCTAssertTrue(
                    UIApplication.shared.sendAction(closeAction, to: closeItem.target, from: closeItem, for: nil))
                try await Task.sleep(for: .milliseconds(1500))
            }
            let dismissed = try layout("compact-dismissed")
            XCTAssertFalse(dismissed.presented, "Close dismisses only the inspector")
            XCTAssertTrue(pager() === initialPager)
            XCTAssertTrue(try zoomableViewport() === initialViewport)
            XCTAssertEqual(dismissed.viewportWidth, compactWidth, accuracy: 1, "visible media fills the compact window")
            snapshot(window, "viewer-inspector-compact-dismissed")
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            let originalOrientation = scene.interfaceOrientation
            func rotate(to orientation: UIInterfaceOrientation) async throws {
                let mask: UIInterfaceOrientationMask =
                    switch orientation {
                    case .landscapeLeft: .landscapeLeft
                    case .landscapeRight: .landscapeRight
                    case .portraitUpsideDown: .portraitUpsideDown
                    default: .portrait
                    }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    XCTFail("viewer rotation failed: \(error.localizedDescription)")
                }
                for _ in 0..<50 where scene.interfaceOrientation != orientation {
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertEqual(scene.interfaceOrientation, orientation)
                window.frame = scene.coordinateSpace.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(750))
            }
            initialViewport.setZoomScale(2, animated: false)
            let zoom = initialViewport.zoomScale
            do {
                try await rotate(to: originalOrientation.isLandscape ? .portrait : .landscapeRight)
                XCTAssertTrue(pager() === initialPager)
                XCTAssertTrue(try zoomableViewport() === initialViewport)
                XCTAssertEqual(initialViewport.zoomScale, zoom, accuracy: 0.01, "rotation preserves the photo zoom")
                try verifyEdgeEffects("rotated")
                let usable = window.safeAreaLayoutGuide.layoutFrame
                let media = initialViewport.convert(initialViewport.bounds, to: window)
                XCTAssertEqual(
                    media.width, usable.width, accuracy: 1, "the photo uses the width between device safe areas")
                XCTAssertEqual(
                    media.midX, usable.midX, accuracy: 1, "the photo remains centered between device safe areas")
                report.append("rotated: media=\(media) usable=\(usable) zoom=\(initialViewport.zoomScale)")
                snapshot(window, "viewer-rotated-with-zoom")
            } catch {
                try? await rotate(to: originalOrientation)
                throw error
            }
            try await rotate(to: originalOrientation)
            XCTAssertEqual(initialViewport.zoomScale, zoom, accuracy: 0.01)
        }

        let previousPage = try XCTUnwrap(initialPager.viewControllers?.first)
        let nextPage = try XCTUnwrap(
            initialPager.dataSource?.pageViewController(initialPager, viewControllerAfter: previousPage))
        initialPager.setViewControllers([nextPage], direction: .forward, animated: false)
        initialPager.delegate?.pageViewController?(
            initialPager, didFinishAnimating: true, previousViewControllers: [previousPage], transitionCompleted: true)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(initialPager.viewControllers?.first === nextPage, "paging must show the next photo")
        XCTAssertFalse(try zoomableViewport() === initialViewport, "paging must mount the next photo viewport")
        try verifyEdgeEffects("after paging")

        let text = report.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "viewer-inspector-report"
        attachment.lifetime = .keepAlways
        add(attachment)
        writeArtifact("viewer-inspector-report.txt", Data(text.utf8))
    }

    @MainActor private func snapshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() { writeArtifact("\(name).png", data) }
    }

    private func writeArtifact(_ name: String, _ data: Data) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }
}

private final class ViewerVideoLifetimeProbe: VideoStreamLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private var loads: [PhotoUID] = []
    private var closes = 0

    var loadedUIDs: [PhotoUID] { lock.withLock { loads } }
    var closeCount: Int { lock.withLock { closes } }

    func recordLoad(_ uid: PhotoUID) { lock.withLock { loads.append(uid) } }
    func close() { lock.withLock { closes += 1 } }
}

/// The production viewer presentation: one `.fullScreenCover(item:)` bound to the viewer router, the way
/// `MobileMainTabView` presents `MobilePhotoViewer` (see `EncryptedMemoriesMobileApp.swift`).
private struct ViewerPresentationHost: View {
    let router: MobileViewerRouter
    let libraryModel: MobileLibraryModel

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .fullScreenCover(
                item: Binding(
                    get: { router.presentation },
                    set: { router.presentation = $0 }
                )
            ) { presentation in
                MobilePhotoViewer(
                    items: presentation.items,
                    startIndex: presentation.index,
                    context: presentation.context,
                    libraryModel: libraryModel,
                    viewerRouter: router,
                    showsInfoInitially: presentation.showsInfoInitially
                )
            }
    }
}
