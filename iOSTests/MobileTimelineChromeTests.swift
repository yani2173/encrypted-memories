import MLSearchCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// The library's native top bar through the production `MobileTimelineScreen`.
///
/// Outside selection the trailing bar holds the display-options menu and Select. Selection mode swaps the menu
/// slot for the bulk actions: iOS 26 shows the app-owned "More actions" menu in that slot, iOS 27 hands them to
/// the system overflow menu and leaves no invisible menu behind. The leading title must keep its position while
/// the slot content changes, and the bar must not carry the app ellipsis or an overflow entry outside selection.
final class MobileTimelineChromeTests: XCTestCase {
    private var report: [String] = []

    @MainActor func testLibraryAnchorAndSelectionSurviveDisplaySizedResizes() async throws {
        try await verifyGridStateContinuity(searching: false)
    }

    @MainActor func testSearchQueryResultsAnchorAndSelectionSurviveDisplaySizedResizes() async throws {
        try await verifyGridStateContinuity(searching: true)
    }

    @MainActor func testViewerKeepsPageZoomPanAndInfoAcrossDisplaySizedResizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 12)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let originalSize = scene.coordinateSpace.bounds.size
        window.frame = CGRect(origin: .zero, size: originalSize)
        let context = MobileSceneContext()
        context.attach(window: window)
        let router = MobileViewerRouter()
        let root = UIHostingController(
            rootView: TimelineContinuityHost(
                model: model, router: router, sceneContext: context, search: TimelineContinuitySearchState(),
                surface: .library))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitUntil("SETUP: the timeline is mounted before the viewer opens") {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.contains { !$0.itemUIDs.isEmpty }
        }
        let uid = fixture.items[2].uid
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.presentation = MobileViewerPresentation(
                index: 2, items: fixture.items, context: ViewerCollectionContext(filter: .all), showsInfoInitially: true
            )
        }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        func currentPager() -> UIPageViewController? {
            root.presentedViewController.flatMap { controllers($0).compactMap { $0 as? UIPageViewController }.first }
        }
        func currentPhotoViewport() -> UIScrollView? {
            guard let page = currentPager()?.viewControllers?.first else { return nil }
            return descendants(page.view).compactMap { $0 as? UIScrollView }.first {
                $0.maximumZoomScale > $0.minimumZoomScale
            }
        }
        try await waitUntil("SETUP: the production cover contains a zoomable photo") { currentPhotoViewport() != nil }
        let viewer = try XCTUnwrap(root.presentedViewController)
        let pager = try XCTUnwrap(currentPager())
        try await waitUntil("SETUP: Info and the media viewport finish their initial layout") {
            guard let viewport = currentPhotoViewport(), viewport.bounds.width > 0,
                let image = descendants(viewport).compactMap({ $0 as? UIImageView }).first, image.bounds.width > 0
            else { return false }
            return viewer.presentedViewController != nil || viewer.view.bounds.width - pager.view.bounds.width >= 200
        }
        let page = try XCTUnwrap(pager.viewControllers?.first)
        let viewport = try XCTUnwrap(currentPhotoViewport())
        let image = try XCTUnwrap(descendants(viewport).compactMap { $0 as? UIImageView }.first)
        XCTAssertNotNil(image.image, "SETUP: the viewport must contain the loaded photo")
        XCTAssertGreaterThanOrEqual(viewport.maximumZoomScale / viewport.minimumZoomScale, 3)
        viewport.setZoomScale(viewport.minimumZoomScale * 3, animated: false)
        viewport.layoutIfNeeded()
        let target = image.convert(CGPoint(x: image.bounds.width * 0.55, y: image.bounds.height * 0.45), to: viewport)
        viewport.setContentOffset(
            CGPoint(x: target.x - viewport.bounds.width / 2, y: target.y - viewport.bounds.height / 2), animated: false)
        func normalizedCentre() -> CGPoint {
            let point = viewport.convert(CGPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), to: image)
            return CGPoint(x: point.x / image.bounds.width, y: point.y / image.bounds.height)
        }
        let zoom = viewport.zoomScale / viewport.minimumZoomScale
        let centre = normalizedCentre()
        XCTAssertTrue(centre.x.isFinite && centre.y.isFinite)
        XCTAssertGreaterThan(abs(centre.x - 0.5), 0.01, "SETUP: the photo must be panned, not centred")
        let sizes = [
            CGSize(width: 466, height: 678), CGSize(width: 951, height: 669),
            CGSize(width: 678, height: 466), CGSize(width: 669, height: 951), originalSize,
        ]
        var viewportSizes: Set<String> = []
        var expectedCentre = centre
        for size in sizes {
            let widthClass: UIUserInterfaceSizeClass = size.width > 820 ? .regular : .compact
            window.traitOverrides.horizontalSizeClass = widthClass
            root.traitOverrides.horizontalSizeClass = widthClass
            viewer.traitOverrides.horizontalSizeClass = widthClass
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(window.bounds.size, size)
            XCTAssertTrue(root.presentedViewController === viewer, "The same cover must remain presented")
            XCTAssertTrue(currentPager() === pager)
            XCTAssertTrue(pager.viewControllers?.first === page, "Resizing must retain the current media page")
            XCTAssertTrue(currentPhotoViewport() === viewport)
            viewportSizes.insert("\(viewport.bounds.size)")
            XCTAssertEqual(router.presentation?.items[2].uid, uid)
            XCTAssertEqual(viewport.zoomScale / viewport.minimumZoomScale, zoom, accuracy: 0.01)
            let scaledImage = CGSize(
                width: image.bounds.width * viewport.zoomScale, height: image.bounds.height * viewport.zoomScale)
            let mediaSize = try XCTUnwrap(image.image).size
            let fitScale = min(viewport.bounds.width / mediaSize.width, viewport.bounds.height / mediaSize.height)
            let expectedImage = CGSize(
                width: mediaSize.width * fitScale * viewport.zoomScale,
                height: mediaSize.height * fitScale * viewport.zoomScale)
            XCTAssertTrue(expectedImage.width.isFinite && expectedImage.height.isFinite)
            XCTAssertGreaterThan(expectedImage.width, 0)
            XCTAssertGreaterThan(expectedImage.height, 0)
            XCTAssertEqual(scaledImage.width, expectedImage.width, accuracy: 1)
            XCTAssertEqual(scaledImage.height, expectedImage.height, accuracy: 1)
            let minX = min(0.5, viewport.bounds.width / (2 * expectedImage.width))
            let maxX = max(0.5, 1 - viewport.bounds.width / (2 * expectedImage.width))
            let minY = min(0.5, viewport.bounds.height / (2 * expectedImage.height))
            let maxY = max(0.5, 1 - viewport.bounds.height / (2 * expectedImage.height))
            let previousCentre = expectedCentre
            expectedCentre = CGPoint(
                x: min(max(previousCentre.x, minX), maxX), y: min(max(previousCentre.y, minY), maxY))
            let restored = normalizedCentre()
            XCTAssertEqual(
                restored.x, expectedCentre.x, accuracy: 0.01,
                "The same horizontal image feature stays centred within the actual pan bounds")
            XCTAssertEqual(
                restored.y, expectedCentre.y, accuracy: 0.01,
                "The same vertical image feature stays centred within the actual pan bounds")
            XCTAssertTrue(
                viewer.presentedViewController != nil || viewer.view.bounds.width - pager.view.bounds.width >= 200,
                "Info stays open as a sheet or a column")
            let measurement =
                "viewer size=\(size) viewport=\(viewport.bounds.size) scaledImage=\(scaledImage) zoom=\(viewport.zoomScale)"
                + " rangeX=\(minX)...\(maxX) rangeY=\(minY)...\(maxY) previous=\(previousCentre)"
                + " expected=\(expectedCentre) actual=\(restored)"
            print(measurement)
            report.append(measurement)
        }
        XCTAssertGreaterThanOrEqual(viewportSizes.count, 3, "SETUP: the media viewport must actually resize")
        withTransaction(transaction) { router.presentation = nil }
        try await waitUntil("Closing the viewer returns to the timeline") { root.presentedViewController == nil }
        XCTAssertTrue(
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.contains { !$0.itemUIDs.isEmpty })
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "viewer-state-resize"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// These are window-size inputs, not simulated folds or native display handoffs.
    @MainActor private func verifyGridStateContinuity(searching: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 80)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let originalSize = scene.coordinateSpace.bounds.size
        window.frame = CGRect(origin: .zero, size: originalSize)
        let sceneContext = MobileSceneContext()
        sceneContext.attach(window: window)
        let search = TimelineContinuitySearchState()
        let root = UIHostingController(
            rootView: TimelineContinuityHost(
                model: model, router: MobileViewerRouter(), sceneContext: sceneContext, search: search,
                surface: searching ? .search : .library)
        )
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(200))
        if searching { search.query = "June 2026" }
        let expectedUIDs = Set(searching ? fixture.sections[5].items.map(\.uid) : fixture.items.map(\.uid))
        let select = L10n.string("action.select")
        try await waitUntil("SETUP: the production projection shows the exact expected UID set") {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.contains {
                Set($0.itemUIDs) == expectedUIDs
            } && barItem(labelled: select, in: window) != nil
        }
        let grid = try XCTUnwrap(
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.first {
                Set($0.itemUIDs) == expectedUIDs
            })
        try await activate(label: select, in: window)
        try await waitUntil("SETUP: selection mode reaches the production grid") {
            barItem(labelled: L10n.string("action.done"), in: window) != nil
        }
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
        try await Task.sleep(for: .milliseconds(350))
        let initialPlan = try XCTUnwrap(grid.accessibilityFramePlan())
        let selectedItems = try initialPlan.visibleSlots.prefix(3).map { slot in
            try XCTUnwrap(fixture.items.first { $0.uid == grid.itemUIDs[slot.index] })
        }
        XCTAssertEqual(selectedItems.count, 3, "SETUP: three real projected photos must be available")
        let toggle = try XCTUnwrap(grid.onToggleSelection, "SETUP: use the production photo-selection callback")
        selectedItems.forEach(toggle)
        let selected = Set(selectedItems.map(\.uid))
        try await waitUntil("SETUP: all three selections reach the rendered production host") {
            grid.selectedUIDs == selected
        }
        let anchor = try XCTUnwrap(grid.currentScrollAnchor())
        let initialInsets = grid.safeAreaInsets
        let anchorBelowBar = anchor.topOffset - initialInsets.top
        let initialOrder = grid.itemUIDs
        print(
            "issue156 initial search=\(searching) window=\(window.bounds) grid=\(grid.bounds) safe=\(initialInsets) anchorY=\(anchor.topOffset)"
        )
        let query = search.query
        let scope = search.scope
        let sizes = [
            CGSize(width: 466, height: 678), CGSize(width: 951, height: 669),
            CGSize(width: 678, height: 466), CGSize(width: 669, height: 951), originalSize,
        ]
        var sideAtGeometry: [String: CGFloat] = [:]
        for cycle in 0..<2 {
            for size in sizes {
                let widthClass: UIUserInterfaceSizeClass = size.width > 820 ? .regular : .compact
                window.traitOverrides.horizontalSizeClass = widthClass
                root.traitOverrides.horizontalSizeClass = widthClass
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(350))
                let grids = descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }
                XCTAssertEqual(grids.count, 1)
                XCTAssertTrue(grids.first === grid, "A resize must retain the production grid")
                XCTAssertEqual(window.bounds.size, size, "SETUP: the requested dimensions must actually change")
                XCTAssertEqual(Set(grid.itemUIDs), expectedUIDs, "A resize must retain the exact result set")
                XCTAssertEqual(
                    grid.itemUIDs, initialOrder, "A resize must retain the result order without duplicate UIDs")
                XCTAssertEqual(grid.itemUIDs.count, expectedUIDs.count)
                XCTAssertEqual(grid.selectedUIDs, selected, "A resize must retain the exact selected UIDs")
                XCTAssertEqual(search.query, query)
                XCTAssertEqual(search.scope, scope)
                let plan = try XCTUnwrap(grid.accessibilityFramePlan())
                let slot = try XCTUnwrap(
                    plan.visibleSlots.first { grid.itemUIDs[$0.index] == anchor.itemID },
                    "The same witness photo must remain visible")
                print(
                    "issue156 search=\(searching) cycle=\(cycle) window=\(size) grid=\(grid.bounds.size) safe=\(grid.safeAreaInsets) columns=\(plan.columns) side=\(plan.slotSide) level=\(String(describing: grid.interactiveLevel)) witnessY=\(slot.slotRect.minY - grid.scrollView.contentOffset.y)"
                )
                XCTAssertEqual(
                    slot.slotRect.minY - grid.scrollView.contentOffset.y - grid.safeAreaInsets.top,
                    anchorBelowBar, accuracy: 1, "The witness photo keeps its distance below the top bar")
                let geometryKey = "\(grid.bounds.size)|\(grid.safeAreaInsets)"
                if let side = sideAtGeometry[geometryKey] {
                    XCTAssertEqual(slot.slotRect.width, side, accuracy: 0.5, "Equal usable geometry keeps its density")
                }
                sideAtGeometry[geometryKey] = slot.slotRect.width
                report.append(
                    "search=\(searching) cycle=\(cycle) size=\(size) anchor=\(anchor.itemID.nodeID) selected=\(selected.count)"
                )
            }
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = searching ? "search-state-resize" : "library-state-resize"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testSelectionModeSwapsTheTrailingMenuWithoutMovingTheTitle() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let sceneContext = MobileSceneContext()
        sceneContext.attach(window: window)
        let root = UIHostingController(
            rootView: MobileTimelineScreen(surface: .library)
                .environment(model)
                .environment(MobileViewerRouter())
                .environment(sceneContext)
        )
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            writeArtifact("timeline-chrome-report.txt", Data(report.joined(separator: "\n").utf8))
        }

        let selectLabel = L10n.string("action.select")
        let doneLabel = L10n.string("action.done")
        let optionsLabel = String(localized: "library.options")
        let appMoreLabel = String(localized: "selection.more_a11y")
        try await waitUntil("the production grid and its navigation bar appear") {
            !descendants(window).compactMap({ $0 as? UIKitTimelineGridHostView }).filter { !$0.itemUIDs.isEmpty }
                .isEmpty && barItem(labelled: selectLabel, in: window) != nil
        }
        try await Task.sleep(for: .milliseconds(800))

        let browsingLabels = barItemLabels(in: window)
        let browsingTitle = try XCTUnwrap(titleFrame(L10n.string("library.title"), in: window))
        report.append("browsing: items=\(browsingLabels) title=\(browsingTitle)")
        XCTAssertNotNil(barItem(labelled: optionsLabel, in: window), "the options menu is a bar item while browsing")
        XCTAssertNil(barItem(labelled: appMoreLabel, in: window), "the bulk-action menu stays out of the browsing bar")
        report.append("browsing: systemOverflow=\(systemOverflowIsMounted(in: window))")
        XCTAssertFalse(
            systemOverflowIsMounted(in: window),
            "no system overflow button while browsing: an empty overflow menu still shows the ellipsis")
        snapshot(window, "timeline-chrome-browsing")

        // Enter selection mode through the native Select item.
        try await activate(label: selectLabel, in: window)
        try await waitUntil("Done replaces Select") { barItem(labelled: doneLabel, in: window) != nil }
        try await Task.sleep(for: .milliseconds(800))
        let selectingLabels = barItemLabels(in: window)
        let selectingTitle = try XCTUnwrap(titleFrame(L10n.selectionCenterText(selectedCount: 0), in: window))
        report.append("selecting: items=\(selectingLabels) title=\(selectingTitle)")
        XCTAssertNil(
            accessibilityElement(labelled: optionsLabel, in: window),
            "the options menu leaves the bar in selection mode instead of hiding behind opacity")
        if #available(iOS 27.0, *) {
            XCTAssertNil(
                barItem(labelled: appMoreLabel, in: window),
                "iOS 27 moves the bulk actions into the system overflow menu; no app ellipsis remains")
            report.append("selecting: systemOverflow=\(systemOverflowIsMounted(in: window))")
            XCTAssertTrue(
                systemOverflowIsMounted(in: window),
                "iOS 27 shows the system overflow button once the bulk actions join it")
        } else {
            XCTAssertNotNil(
                barItem(labelled: appMoreLabel, in: window),
                "iOS 26 keeps the app-owned bulk-action menu in the trailing slot")
        }
        // The selection count replaces the route title. iOS 26.5 lays the longer title out 2 pt further right
        // (measured on iPhone 17 Pro Max; the shift stayed at 2 pt with both trailing menus mounted, so the slot swap
        // is not the cause). iOS 27 keeps it in place. A larger shift is a real title jump.
        let titleTolerance: CGFloat
        if #available(iOS 27.0, *) {
            titleTolerance = 1
        } else {
            titleTolerance = 2.5
        }
        XCTAssertEqual(
            selectingTitle.minX, browsingTitle.minX, accuracy: titleTolerance, "the leading title must not jump")
        XCTAssertEqual(selectingTitle.midY, browsingTitle.midY, accuracy: 1, "the leading title must not jump")
        snapshot(window, "timeline-chrome-selecting")

        // Leave selection mode; the options menu returns to its slot.
        try await activate(label: doneLabel, in: window)
        try await waitUntil("Select replaces Done") { barItem(labelled: selectLabel, in: window) != nil }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(barItem(labelled: optionsLabel, in: window), "the options menu returns after Done")
        let restoredTitle = try XCTUnwrap(titleFrame(L10n.string("library.title"), in: window))
        XCTAssertEqual(restoredTitle.minX, browsingTitle.minX, accuracy: 1)
        report.append("restored: items=\(barItemLabels(in: window)) title=\(restoredTitle)")
    }

    // MARK: - Helpers

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func barItems(in window: UIWindow) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
            for navigationItem in bar.items ?? [] {
                items += (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                items += navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.centerItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.pinnedTrailingGroup?.barButtonItems ?? []
            }
        }
        return items
    }

    @MainActor private func label(of item: UIBarButtonItem) -> String? {
        if let title = item.title, !title.isEmpty { return title }
        if let label = item.accessibilityLabel, !label.isEmpty { return label }
        guard let custom = item.customView else { return nil }
        if let label = custom.accessibilityLabel, !label.isEmpty { return label }
        return descendants(custom).lazy.compactMap { view -> String? in
            if let label = view.accessibilityLabel, !label.isEmpty { return label }
            if let text = (view as? UILabel)?.text, !text.isEmpty { return text }
            return (view as? UIButton)?.titleLabel?.text
        }.first
    }

    @MainActor private func barItemLabels(in window: UIWindow) -> [String] {
        barItems(in: window).compactMap(label(of:))
    }

    @MainActor private func barItem(labelled label: String, in window: UIWindow) -> UIBarButtonItem? {
        barItems(in: window).first { item in
            if item.title == label || item.accessibilityLabel == label { return true }
            guard let custom = item.customView else { return false }
            if custom.accessibilityLabel == label { return true }
            return descendants(custom).contains { view in
                view.accessibilityLabel == label || (view as? UILabel)?.text == label
                    || (view as? UIButton)?.titleLabel?.text == label
            }
        }
    }

    /// Whether a navigation bar carries system overflow content. SwiftUI's `ToolbarOverflowMenu` fills
    /// `UINavigationItem.additionalOverflowItems`, and UIKit shows the ellipsis whenever that property is set. The
    /// check does not depend on the localized title of the overflow button.
    @MainActor private func systemOverflowIsMounted(in window: UIWindow) -> Bool {
        descendants(window).compactMap { $0 as? UINavigationBar }
            .flatMap { $0.items ?? [] }
            .contains { $0.additionalOverflowItems != nil }
    }

    /// The frame of the navigation bar's title label in window coordinates.
    @MainActor private func titleFrame(_ title: String, in window: UIWindow) -> CGRect? {
        for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
            if let label = descendants(bar).compactMap({ $0 as? UILabel }).first(where: { $0.text == title }) {
                return label.convert(label.bounds, to: window)
            }
        }
        return nil
    }

    @MainActor private func accessibilityElement(labelled label: String, in root: UIView) -> UIView? {
        if root.isHidden || root.alpha < 0.01 || root.accessibilityElementsHidden { return nil }
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        for subview in root.subviews {
            if let match = accessibilityElement(labelled: label, in: subview) { return match }
        }
        return nil
    }

    /// Activates a bar item the way a pointer or VoiceOver would: the item's action, then its custom control.
    @MainActor private func activate(label: String, in window: UIWindow) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while clock.now < deadline {
            if let item = barItem(labelled: label, in: window) {
                if let action = item.action,
                    UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
                {
                    report.append("activated '\(label)' through UIBarButtonItem")
                    return
                }
                if let custom = item.customView {
                    if let control = descendants(custom).compactMap({ $0 as? UIControl }).first {
                        control.sendActions(for: .touchUpInside)
                        report.append("activated '\(label)' through UIControl")
                        return
                    }
                    if let element = accessibilityElement(labelled: label, in: custom), element.accessibilityActivate()
                    {
                        report.append("activated '\(label)' through accessibility")
                        return
                    }
                }
            }
            if let element = accessibilityElement(labelled: label, in: window), element.accessibilityActivate() {
                report.append("activated '\(label)' through window accessibility")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        report.append("DIAGNOSTICS for '\(label)': items=\(barItemLabels(in: window))")
        XCTFail("no activatable bar item labelled '\(label)'")
        throw MobileFixtureError.unavailable
    }

    @MainActor private func waitUntil(
        _ what: String, timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        report.append("TIMEOUT: \(what)")
        XCTFail("timed out: \(what)")
        throw MobileFixtureError.unavailable
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

@MainActor @Observable private final class TimelineContinuitySearchState {
    var query = ""
    var scope: MLSearchScope = .all
}

@MainActor private struct TimelineContinuityHost: View {
    let model: MobileLibraryModel
    let router: MobileViewerRouter
    let sceneContext: MobileSceneContext
    let search: TimelineContinuitySearchState
    let surface: MobileTimelineSurface

    var body: some View {
        MobileTimelineScreen(
            surface: surface, searchText: Binding(get: { search.query }, set: { search.query = $0 }),
            searchScope: Binding(get: { search.scope }, set: { search.scope = $0 })
        )
        .environment(model)
        .environment(router)
        .environment(sceneContext)
        .fullScreenCover(item: Binding(get: { router.presentation }, set: { router.presentation = $0 })) {
            presentation in
            MobilePhotoViewer(
                items: presentation.items, startIndex: presentation.index, context: presentation.context,
                libraryModel: model, viewerRouter: router, showsInfoInitially: presentation.showsInfoInitially)
        }
    }
}
