import DesignSystemCore
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// Exercise the production grid and chrome policies in a populated native navigation/tab hierarchy.
/// Attachments support OS visual comparison; they are not pixel-equality or physical-device acceptance.
final class MobileGridChromeTests: XCTestCase {
    @MainActor func testControllerTabBarIsFoundBehindCrowdedSubtree() throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let tabs = UITabBarController()
        let content = UIViewController()
        content.tabBarItem = UITabBarItem(title: "Library", image: nil, tag: 0)
        tabs.viewControllers = [content]
        window.rootViewController = tabs
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let bar = tabs.tabBar
        let container = try XCTUnwrap(bar.superview)
        let crowded = UIView(frame: container.bounds)
        for _ in 0..<400 {
            let view = UIView()
            view.isHidden = true
            crowded.addSubview(view)
        }
        container.insertSubview(crowded, belowSubview: bar)
        for _ in 0..<400 {
            let sibling = UIView()
            sibling.isHidden = true
            container.insertSubview(sibling, belowSubview: bar)
        }
        let frame = bar.convert(bar.bounds, to: window)
        guard bar.window === window, !bar.isHidden, bar.alpha > 0, !frame.isEmpty,
            frame.intersects(window.bounds)
        else {
            XCTFail("SETUP: controller bar must be visible in the window")
            return
        }
        let host = UIKitTimelineGridHostView()
        XCTAssertTrue(
            host.visibleTabBarFrames(in: window).contains { $0.frame == frame },
            "Controller bar must survive a crowded subtree")
    }

    @MainActor func testInsetFollowUpSkipsDetachedInactiveAndDeallocatedHosts() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let grid = UIKitTimelineGridHostView(frame: controller.view.bounds)
        controller.view.addSubview(grid)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #if DEBUG
            grid.setActive(false)
            try await Task.sleep(for: .milliseconds(100))
            let inactiveCount = grid.insetFollowUpCount
            grid.safeAreaInsetsDidChange()
            XCTAssertFalse(grid.insetFollowUpPending, "Inactive host must not schedule a follow-up")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(grid.insetFollowUpCount, inactiveCount, "Inactive host must not schedule a follow-up")
            grid.setActive(true)
            grid.safeAreaInsetsDidChange()
            grid.removeFromSuperview()
            let detachedCount = grid.insetFollowUpCount
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(grid.insetFollowUpCount, detachedCount, "Detached host must not execute a follow-up")
        #endif
        weak var released: UIKitTimelineGridHostView?
        autoreleasepool {
            let transient = UIKitTimelineGridHostView()
            controller.view.addSubview(transient)
            transient.safeAreaInsetsDidChange()
            transient.removeFromSuperview()
            released = transient
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(released, "A pending follow-up must not retain its host")
        grid.setActive(false)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }

    @MainActor func testInsetFollowUpSkipsAHostOutsideItsClippingAncestor() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let clipper = UIView(frame: controller.view.bounds)
        clipper.clipsToBounds = true
        controller.view.addSubview(clipper)
        let gridSize = CGSize(width: 320, height: 400)
        let grid = UIKitTimelineGridHostView(frame: CGRect(origin: .zero, size: gridSize))
        clipper.addSubview(grid)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #if DEBUG
            // Completely below the clipper's bounds: no layout pass can have a visible effect.
            grid.frame = CGRect(x: 0, y: clipper.bounds.maxY + 100, width: gridSize.width, height: gridSize.height)
            try await Task.sleep(for: .milliseconds(100))
            let outsideCount = grid.insetFollowUpCount
            grid.safeAreaInsetsDidChange()
            XCTAssertFalse(
                grid.insetFollowUpPending, "A host outside a clipping ancestor must not schedule a follow-up")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(
                grid.insetFollowUpCount, outsideCount, "A host outside a clipping ancestor must not run a follow-up")

            // Overlapping the clip area by a bounded amount keeps the host visible, so the follow-up must run.
            grid.frame = CGRect(x: 0, y: clipper.bounds.maxY - 50, width: gridSize.width, height: gridSize.height)
            try await Task.sleep(for: .milliseconds(100))
            let overlappingCount = grid.insetFollowUpCount
            grid.safeAreaInsetsDidChange()
            XCTAssertTrue(
                grid.insetFollowUpPending, "A host that overlaps the clipping ancestor must schedule a follow-up")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(
                grid.insetFollowUpCount - overlappingCount, 1,
                "A host that overlaps the clipping ancestor must run a follow-up")

            // A zero-size host inside the clip area cannot tell yet whether it is visible, so the follow-up
            // must still run exactly as it did before the clipping check existed.
            grid.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
            try await Task.sleep(for: .milliseconds(100))
            let zeroSizeCount = grid.insetFollowUpCount
            grid.safeAreaInsetsDidChange()
            XCTAssertTrue(
                grid.insetFollowUpPending, "A zero-size host inside the clip area must schedule a follow-up")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(
                grid.insetFollowUpCount - zeroSizeCount, 1,
                "A zero-size host inside the clip area must run a follow-up")
        #endif
        grid.setActive(false)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }

    @MainActor func testTabBarTraversalRespectsNodeAndDepthLimits() {
        let host = UIKitTimelineGridHostView()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let barFrame = CGRect(x: 0, y: 750, width: 400, height: 50)
        func windowWithHiddenViews(_ count: Int) -> UIWindow {
            let window = UIWindow(frame: bounds)
            window.isHidden = false
            for _ in 0..<count {
                let view = UIView()
                view.isHidden = true
                window.addSubview(view)
            }
            window.addSubview(UITabBar(frame: barFrame))
            return window
        }
        XCTAssertEqual(host.visibleTabBarFrames(in: windowWithHiddenViews(398)).map(\.visibleFrame), [barFrame])
        XCTAssertTrue(host.visibleTabBarFrames(in: windowWithHiddenViews(399)).isEmpty)

        func windowWithDepth(_ depth: Int) -> UIWindow {
            let window = UIWindow(frame: bounds)
            window.isHidden = false
            var parent: UIView = window
            for _ in 0..<depth {
                let child = UIView(frame: bounds)
                parent.addSubview(child)
                parent = child
            }
            parent.addSubview(UITabBar(frame: barFrame))
            return window
        }
        XCTAssertEqual(host.visibleTabBarFrames(in: windowWithDepth(39)).map(\.visibleFrame), [barFrame])
        XCTAssertTrue(host.visibleTabBarFrames(in: windowWithDepth(40)).isEmpty)
    }

    @MainActor func testFallbackFindsShallowBarBeforeCrowdedSubtree() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.isHidden = false
        let crowded = UIView(frame: window.bounds)
        for _ in 0..<400 { crowded.addSubview(UIView()) }
        window.addSubview(crowded)
        let bar = UITabBar(frame: CGRect(x: 0, y: 750, width: 400, height: 50))
        window.addSubview(bar)
        let host = UIKitTimelineGridHostView()
        XCTAssertTrue(host.visibleTabBarFrames(in: window).contains { $0.frame == bar.convert(bar.bounds, to: window) })
    }

    @MainActor func testNestedClipsAndHiddenAncestorsAffectBarVisibility() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.isHidden = false
        let outer = UIView(frame: CGRect(x: 0, y: 740, width: 100, height: 60))
        outer.clipsToBounds = true
        let inner = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        inner.clipsToBounds = true
        let bar = UITabBar(frame: CGRect(x: 0, y: 0, width: 400, height: 50))
        window.addSubview(outer)
        outer.addSubview(inner)
        inner.addSubview(bar)
        let host = UIKitTimelineGridHostView()
        let result = try XCTUnwrap(host.visibleTabBarFrames(in: window).first)
        XCTAssertEqual(result.frame, bar.convert(bar.bounds, to: window))
        XCTAssertEqual(result.visibleFrame, CGRect(x: 10, y: 750, width: 50, height: 50))
        outer.isHidden = true
        XCTAssertTrue(host.visibleTabBarFrames(in: window).isEmpty)
        outer.isHidden = false
        outer.alpha = 0
        XCTAssertTrue(host.visibleTabBarFrames(in: window).isEmpty)
    }

    @MainActor func testGridNewestRowReservesSpaceOnlyForAHorizontalBottomBar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: cacheDirectory), loader: ChromeProbeLoader())
        let items = (0..<120).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "bottom-bar-probe", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: TimeInterval($0)), mediaType: "image/jpeg")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.additionalSafeAreaInsets.bottom = 72
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let grid = UIKitTimelineGridHostView(frame: controller.view.bounds)
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(grid)
        defer {
            grid.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        grid.configure(items: items, contentRevision: 1, thumbnailFeed: feed)
        let bounds = controller.view.bounds
        let cases: [(String, CGRect?, Bool)] = [
            ("none", nil, false),
            ("vertical", CGRect(x: bounds.maxX - 72, y: bounds.minY, width: 72, height: bounds.height), false),
            ("bottom", CGRect(x: bounds.minX, y: bounds.maxY - 72, width: bounds.width, height: 72), true),
        ]
        for (name, frame, hasBottomBar) in cases {
            let bar: UITabBar?
            if let frame {
                let candidate = UITabBar(frame: frame)
                candidate.items = [UITabBarItem(title: "Library", image: nil, tag: 0)]
                controller.view.addSubview(candidate)
                bar = candidate
            } else {
                bar = nil
            }
            window.layoutIfNeeded()
            grid.setNeedsLayout()
            grid.layoutIfNeeded()
            grid.scrollToLatest(animated: false)
            try await Task.sleep(for: .milliseconds(350))
            let safeBottom = grid.safeAreaInsets.bottom
            let safeTop = grid.safeAreaInsets.top
            XCTAssertGreaterThan(safeBottom, 0, "\(name): test requires a nonzero system safe area")
            XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 72)
            let plan = try XCTUnwrap(grid.accessibilityFramePlan(), "\(name): grid plan")
            let last = try XCTUnwrap(plan.visibleSlots.first { $0.index == items.count - 1 }, "\(name): newest tile")
            XCTAssertGreaterThan(plan.contentSize.height, grid.bounds.height, "\(name): content must overflow")
            let rowGap = grid.bounds.height - (last.slotRect.maxY - grid.scrollView.contentOffset.y)
            let layoutGap = plan.gap
            let expectedInset = hasBottomBar ? safeBottom : 0
            let expectedRowGap = expectedInset + layoutGap
            let evidence =
                "\(name): safeTop=\(safeTop) safeBottom=\(safeBottom) inset=\(grid.scrollView.contentInset.bottom) expectedInset=\(expectedInset) layoutGap=\(layoutGap) rowGap=\(rowGap) expectedRowGap=\(expectedRowGap) bar=\(String(describing: frame))"
            print("issue921 " + evidence)
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "issue921-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(plan.contentSize.height - last.slotRect.maxY, layoutGap, accuracy: 0.5, evidence)
            XCTAssertEqual(grid.scrollView.contentInset.bottom, expectedInset, accuracy: 0.5, evidence)
            XCTAssertEqual(rowGap, expectedRowGap, accuracy: 1, evidence)
            XCTAssertEqual(grid.scrollView.contentInset.top, safeTop, accuracy: 0.5, evidence)
            bar?.removeFromSuperview()
        }
    }

    @MainActor func testHiddenTransparentAndClippedBarsDoNotReserveInset() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: cacheDirectory), loader: ChromeProbeLoader())
        let items = (0..<120).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "bar-change-probe", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: TimeInterval($0)), mediaType: "image/jpeg")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.additionalSafeAreaInsets.bottom = 72
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let grid = UIKitTimelineGridHostView(frame: controller.view.bounds)
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(grid)
        grid.configure(items: items, contentRevision: 1, thumbnailFeed: feed)
        defer {
            grid.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        let bounds = controller.view.bounds
        let bar = UITabBar(frame: CGRect(x: 0, y: bounds.maxY - 72, width: bounds.width, height: 72))
        bar.items = [UITabBarItem(title: "Library", image: nil, tag: 0)]
        controller.view.addSubview(bar)
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        #if DEBUG
            let followUpsBefore = grid.insetFollowUpCount
            for _ in 0..<10 { grid.safeAreaInsetsDidChange() }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(grid.insetFollowUpCount - followUpsBefore, 1, "Safe-area events must share one follow-up")
        #endif
        let safeBottom = grid.safeAreaInsets.bottom
        let viewport = grid.convert(grid.bounds, to: window)
        let bottomRegion = CGRect(
            x: viewport.minX, y: viewport.maxY - safeBottom, width: viewport.width, height: safeBottom)
        let actualBar = bar.convert(bar.bounds, to: window)
        guard safeBottom > 0, bar.window === window, !bar.isHidden, bar.alpha > 0,
            actualBar.width > actualBar.height, actualBar.intersects(bottomRegion)
        else {
            XCTFail("SETUP: visible horizontal bar must intersect the bottom safe area")
            return
        }
        guard abs(grid.scrollView.contentInset.bottom - safeBottom) <= 0.5 else {
            XCTFail("SETUP: visible bar must reserve the bottom safe area")
            return
        }
        bar.alpha = 0
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        XCTAssertEqual(grid.scrollView.contentInset.bottom, 0, accuracy: 0.5, "transparent bar must not reserve space")
        bar.alpha = 1
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        XCTAssertEqual(grid.scrollView.contentInset.bottom, safeBottom, accuracy: 0.5)
        bar.isHidden = true
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        XCTAssertEqual(grid.scrollView.contentInset.bottom, 0, accuracy: 0.5, "hidden bar must not reserve space")
        bar.isHidden = false
        bar.removeFromSuperview()

        let clip = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        clip.clipsToBounds = true
        controller.view.addSubview(clip)
        clip.addSubview(bar)
        let clippedBar = bar.convert(bar.bounds, to: window)
        let clipFrame = clip.convert(clip.bounds, to: window)
        guard clippedBar.intersects(bottomRegion), !clipFrame.intersects(clippedBar) else {
            XCTFail("SETUP: bar must intersect the bottom region while fully outside the clip")
            return
        }
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        XCTAssertEqual(
            grid.scrollView.contentInset.bottom, 0, accuracy: 0.5, "fully clipped bar must not reserve space")
    }

    @MainActor func testSelectionChromePreservesGridAndFloatingNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ThumbnailCache(rootDirectory: cacheDirectory)
        let feed = UIKitThumbnailFeed(cache: cache, loader: ChromeProbeLoader())
        let items = (0..<90).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "chrome-probe", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        for (index, item) in items.enumerated() {
            let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { context in
                UIColor(hue: CGFloat(index % 8) / 8, saturation: 0.55, brightness: 0.75, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
                for stripe in 0..<12 {
                    UIColor.white.withAlphaComponent(stripe.isMultiple(of: 2) ? 0.5 : 0.05).setFill()
                    context.fill(CGRect(x: 0, y: stripe * 20, width: 240, height: 10))
                }
            }
            await cache.store(try XCTUnwrap(bitmap.jpegData(compressionQuality: 1)), for: item.uid)
        }
        _ = await feed.warmDecoded(items.map(\.uid))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let state = ChromeProbeState()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(
            rootView: ChromeProbeShell(items: items, feed: feed, state: state))
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var originalGrid: UIKitTimelineGridHostView?
        var initialHorizontalSafeBottom: CGFloat?
        for (step, isSelecting) in [false, false, false, true, false].enumerated() {
            state.isSelecting = isSelecting
            state.showsLoadingCover = step == 0
            state.showsActivity = step < 2
            try await Task.sleep(for: .seconds(2))
            let grids = descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }
            XCTAssertEqual(grids.count, 1)
            let grid = try XCTUnwrap(grids.first)
            if let originalGrid {
                XCTAssertTrue(grid === originalGrid, "Selection must not remount the photo grid")
            } else {
                originalGrid = grid
                grid.scrollView.setContentOffset(CGPoint(x: 0, y: 350), animated: false)
            }
            XCTAssertEqual(grid.scrollView.topEdgeEffect.style, .soft)
            try await Task.sleep(for: .seconds(1))
            let tabBars = descendants(window).compactMap { $0 as? UITabBar }
            print(
                "issue921 selection step=\(step) safeBottom=\(grid.safeAreaInsets.bottom) inset=\(grid.scrollView.contentInset.bottom)"
            )
            // iPhone keeps a UITabBar; iPadOS renders its top tab bar with a system container view.
            if UIDevice.current.userInterfaceIdiom == .phone {
                let tabBar = try XCTUnwrap(tabBars.first)
                XCTAssertEqual(tabBar.isHidden, isSelecting, "Selection actions and root tabs must alternate")
            }
            XCTAssertTrue(state.readVerticalBarEdge, "The fixture must record the shared bar decision")
            let expectsVerticalBar = state.verticalBarEdge != nil
            if !isSelecting {
                let horizontalBar = tabBars.first(where: {
                    let frame = $0.convert($0.bounds, to: window)
                    return !$0.isHidden && frame.width > frame.height
                })
                let verticalBar = tabBars.first(where: {
                    let frame = $0.convert($0.bounds, to: window)
                    return !$0.isHidden && frame.height > frame.width
                })
                // The fixture derives the expected bar kind from the same environment value that the
                // app chrome reads (`verticalBarEdge`); skipping the checks below would let them pass
                // without checking anything.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    if expectsVerticalBar {
                        XCTAssertNotNil(verticalBar, "The phone fixture must show a vertical side bar")
                    } else {
                        XCTAssertNotNil(horizontalBar, "The phone fixture must show a horizontal bottom bar")
                    }
                }
                if expectsVerticalBar {
                    XCTAssertEqual(
                        grid.scrollView.contentInset.bottom, 0, accuracy: 0.5,
                        "A vertical side bar must not reserve the host's bottom inset")
                } else if let tabBar = horizontalBar {
                    let safeBottom = grid.safeAreaInsets.bottom
                    if step == 0 { initialHorizontalSafeBottom = safeBottom }
                    let viewport = grid.convert(grid.bounds, to: window)
                    let barFrame = tabBar.convert(tabBar.bounds, to: window)
                    let bottomRegion = CGRect(
                        x: viewport.minX, y: viewport.maxY - safeBottom,
                        width: viewport.width, height: safeBottom)
                    print(
                        "issue921 native-phone step=\(step) safeBottom=\(safeBottom) inset=\(grid.scrollView.contentInset.bottom) viewport=\(viewport) bar=\(barFrame)"
                    )
                    XCTAssertGreaterThan(safeBottom, 0, "Native bottom bar must produce a nonzero safe area")
                    XCTAssertGreaterThan(barFrame.width, barFrame.height, "Native tab bar must be horizontal")
                    XCTAssertTrue(
                        barFrame.intersects(bottomRegion), "Native tab bar must occupy the bottom safe area")
                    XCTAssertEqual(
                        grid.scrollView.contentInset.bottom, safeBottom, accuracy: 0.5,
                        "Native bottom tab bar must retain the host's bottom inset")
                }
            }
            if isSelecting, let initialHorizontalSafeBottom {
                XCTAssertNotEqual(
                    grid.safeAreaInsets.bottom, initialHorizontalSafeBottom, "Selection must change the safe area")
                XCTAssertEqual(
                    grid.scrollView.contentInset.bottom, 0, accuracy: 0.5, "Hidden tab bar must release the inset")
            }
            let navigationBar = try XCTUnwrap(descendants(window).compactMap { $0 as? UINavigationBar }.first)
            XCTAssertFalse(navigationBar.isHidden)
            let name = "chrome-iOS-\(UIDevice.current.systemVersion)-step-\(step)-selecting-\(isSelecting)"
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"],
                let data = shot.pngData()
            {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try? data.write(to: url.appendingPathComponent("\(name).png"))
            }
        }
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable final class ChromeProbeState {
    let selection = MobileGridSelectionController()
    var showsLoadingCover = true
    var showsActivity = true
    /// The bar decision that the app chrome reads; the fixture records it for the test assertions.
    var verticalBarEdge: HorizontalEdge?
    var readVerticalBarEdge = false
    var isSelecting: Bool {
        get { selection.isSelecting }
        set {
            selection.isSelecting = newValue
            if !newValue { selection.selected.removeAll() }
        }
    }
}

struct ChromeProbeShell: View {
    @Namespace private var activityTransition
    let items: [PhotoItem]
    let feed: UIKitThumbnailFeed
    let state: ChromeProbeState
    @Environment(\.verticalBarEdge) private var verticalBarEdge

    var body: some View {
        TabView {
            Tab("Mediathek", systemImage: "photo.on.rectangle") {
                NavigationStack {
                    UIKitTimelineGrid(
                        items: items, thumbnailFeed: feed, level: 0, fillOrder: .topLeading,
                        selectionMode: state.isSelecting
                    )
                    .ignoresSafeArea()
                    .overlay(alignment: .top) { TopFrostBar(height: 106) }
                    .mobileNavigationTitle("Mediathek")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        ToolbarItem(placement: .topBarTrailing) { Button("Auswählen") {} }
                        MobileSelectionToolbarItems(
                            selection: state.selection,
                            canAddToAlbum: true,
                            showAlbumPicker: .constant(false),
                            onShare: {},
                            onTrash: {},
                            albumPicker: { _ in EmptyView() }
                        )
                    }
                    .mobileSelectionBars(isSelecting: state.isSelecting)
                }
                .overlay {
                    LibraryActivityBannerOverlay(
                        isPresented: state.showsActivity,
                        message: "Mediathek wird geladen …",
                        bottomPadding: state.isSelecting ? 84 : 20
                    )
                }
            }
            Tab("Sammlungen", systemImage: "rectangle.stack") { Text("Sammlungen") }
            Tab("Karte", systemImage: "map") { Text("Karte") }
            Tab(role: .search) { NavigationStack { Text("Suche").searchable(text: .constant("")) } }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabViewStyle(.sidebarAdaptable)
        .mobileTabBarBackgroundPolicy()
        .tint(.purple)
        .overlay {
            MobileLibraryLoadingView(
                isPresented: state.showsLoadingCover,
                activityMessage: "Mediathek wird geladen …",
                activityState: .working
            )
        }
        .libraryActivityTransition(namespace: activityTransition, loadingCoverPresented: state.showsLoadingCover)
        .onAppear {
            state.verticalBarEdge = verticalBarEdge
            state.readVerticalBarEdge = true
        }
    }
}

struct ChromeProbeLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
