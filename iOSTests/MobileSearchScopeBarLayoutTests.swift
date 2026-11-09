import DesignSystemCore
import GridCore
import MLSearchCore
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

/// Hosted regression for issue #944: the search scope picker must leave a native-looking gap above
/// the first grid row, on iPhone and iPad alike. The scope picker appears when two or more scopes
/// are available and text entry activates the system search scope bar (`.onTextEntry`).
final class MobileSearchScopeBarLayoutTests: XCTestCase {
    /// While the picker is presented above the grid, the first row keeps the standard outer margin
    /// below the picker's chrome.
    @MainActor func testFirstGridRowKeepsGapBelowSearchScopeBar() async throws {
        let measurement = try await measureProbe(presentsScopePicker: true)
        let expectedGap = SquareTileGridEngine.standardOuterMargin
        XCTAssertGreaterThanOrEqual(
            measurement.gapBelowReference, expectedGap,
            "The first grid row must start at least \(expectedGap) points below the search scope picker. "
                + "Found \(measurement.gapBelowReference) points.")
    }

    /// The host is asked for the gap while no scope bar sits above the grid, because the system
    /// places the picker elsewhere (for example the bottom search placement). The first row must
    /// then keep the position it held before issue #944's gap existed: no phantom gap.
    @MainActor func testFirstGridRowStaysPutWhenNoScopeBarIsMeasured() async throws {
        let measurement = try await measureProbe(presentsScopePicker: false)
        XCTAssertEqual(
            measurement.firstRowTop, measurement.prePickerAnchor, accuracy: 0.5,
            "Without a scope bar above the grid the first row must keep its pre-#944 position "
                + "\(measurement.prePickerAnchor); found \(measurement.firstRowTop).")
    }

    /// Everything both tests need from one probe window: the reference bottom of the picker chrome,
    /// the first row's window-space top, and the row's position before issue #944's gap existed.
    private struct ProbeMeasurement {
        let referenceBottom: CGFloat
        let firstRowTop: CGFloat
        /// Window-space top of the grid's content origin: where the first row sat before the gap
        /// existed, because the layout origin was the safe-area top with no scope-bar clearance.
        let prePickerAnchor: CGFloat

        var gapBelowReference: CGFloat { firstRowTop - referenceBottom }
    }

    /// Mounts the probe window, enters text, waits for the layout to settle, and measures the first
    /// row. `presentsScopePicker` chooses whether the probe attaches the system scope picker; the
    /// grid always receives the gap request, exactly like the search tab does.
    @MainActor private func measureProbe(presentsScopePicker: Bool) async throws -> ProbeMeasurement {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: cacheDirectory), loader: ChromeProbeLoader())
        let items = (0..<40).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "scope-gap-probe", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: TimeInterval($0)),
                mediaType: "image/jpeg")
        }

        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let state = SearchScopeProbeState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: SearchScopeProbeShell(
                items: items, feed: feed, state: state, presentsScopePicker: presentsScopePicker))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        // Let the navigation bar and the search field mount first, then enter text so the scope
        // bar presents through `.onTextEntry` activation, exactly like the search tab does.
        try await waitUntil("the navigation bar and the search field to mount") {
            let views = descendants(window)
            return views.contains { $0 is UINavigationBar } && views.contains { $0 is UITextField }
        }
        state.text = "Fix"
        if presentsScopePicker {
            try await waitUntil("the search scope bar to present below the navigation bar") {
                descendants(window).contains { view in
                    guard view is UISegmentedControl else { return false }
                    let frame = view.convert(view.bounds, to: window)
                    return frame.height > 8 && frame.width > frame.height
                }
            }
        }
        window.layoutIfNeeded()

        let grids = descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }
        XCTAssertEqual(grids.count, 1, "Exactly one grid must be mounted")
        let grid = try XCTUnwrap(grids.first)

        // Walk the real UIKit hierarchy of this window. SwiftUI renders `.searchScopes` inside the
        // navigation search field's own hierarchy; the accessibility tree hides it (issue #944 probe).
        let allViews = descendants(window)
        var scopeBarCandidates: [UIView] = []
        var searchFields: [UITextField] = []
        var navigationBars: [UINavigationBar] = []
        for view in allViews {
            let className = NSStringFromClass(type(of: view))
            // The probe shell itself hosts the grid, so its window frame would swallow every
            // reference measurement. Only chrome that neither contains nor is contained by the
            // grid qualifies as picker chrome.
            let sharesHierarchyWithGrid = view === grid || grid.isDescendant(of: view) || view.isDescendant(of: grid)
            if !sharesHierarchyWithGrid, className.contains("Segment") || className.contains("Scope") {
                scopeBarCandidates.append(view)
            }
            if let field = view as? UITextField {
                searchFields.append(field)
            }
            if let bar = view as? UINavigationBar {
                navigationBars.append(bar)
            }
        }
        for candidate in scopeBarCandidates {
            print(
                "issue944 scopeCandidate \(NSStringFromClass(type(of: candidate))) frame="
                    + "\(candidate.convert(candidate.bounds, to: window))")
        }
        for field in searchFields {
            print(
                "issue944 searchField frame=\(field.convert(field.bounds, to: window)) text=\"\(field.text ?? "")\"")
        }
        for bar in navigationBars {
            print("issue944 navigationBar frame=\(bar.convert(bar.bounds, to: window))")
        }

        // Reference bottom of the picker chrome: the deepest visible scope candidate below the
        // search field, else the search field's own bottom. The grid's first row must start at
        // least the standard outer margin below that reference.
        let referenceBottom: CGFloat
        if let scopeBottom = scopeBarCandidates.map({ $0.convert($0.bounds, to: window).maxY }).max() {
            referenceBottom = scopeBottom
        } else if let field = searchFields.first(where: { ($0.text?.isEmpty ?? true) == false }) {
            referenceBottom = field.convert(field.bounds, to: window).maxY
        } else {
            XCTFail("Cannot locate the search field or the scope bar in the window hierarchy")
            throw MobileFixtureError.unavailable
        }
        print(
            "issue944 gridSafeAreaInsets=\(grid.safeAreaInsets) adjustedContentInset="
                + "\(grid.scrollView.adjustedContentInset) contentOffset=\(grid.scrollView.contentOffset)")

        grid.scrollToTop()
        // Wait for the render pass to catch up with the programmatic scroll: the first visible
        // slot must hold one position across two consecutive reads.
        var settledSlotTop: CGFloat?
        try await waitUntil("the first grid row to settle at the top anchor") {
            guard let plan = grid.accessibilityFramePlan(), !plan.visibleSlots.isEmpty,
                abs(grid.scrollView.contentOffset.y + grid.safeAreaInsets.top) < 0.5
            else { return false }
            let slotTop = plan.visibleSlots.map(\.slotRect.minY).min() ?? 0
            defer { settledSlotTop = slotTop }
            return settledSlotTop == slotTop
        }
        window.layoutIfNeeded()
        grid.layoutIfNeeded()
        print(
            "issue944 settled gridSafeAreaInsets=\(grid.safeAreaInsets) adjustedContentInset="
                + "\(grid.scrollView.adjustedContentInset) contentOffset=\(grid.scrollView.contentOffset)")
        let plan = try XCTUnwrap(grid.accessibilityFramePlan(), "Grid must have an accessibility plan")
        let sortedSlots = plan.visibleSlots.sorted { $0.slotRect.minY < $1.slotRect.minY }
        let firstSlot = try XCTUnwrap(sortedSlots.first, "Grid must show at least one slot")
        let firstRowTopInGridContent = firstSlot.slotRect.minY - grid.scrollView.contentOffset.y
        let firstRowTopInWindow = grid.convert(CGPoint(x: 0, y: firstRowTopInGridContent), to: window).y
        let prePickerAnchor = grid.convert(CGPoint(x: 0, y: 0), to: window).y + grid.safeAreaInsets.top
        let expectedGap = SquareTileGridEngine.standardOuterMargin
        let actualGap = firstRowTopInWindow - referenceBottom
        print(
            "issue944 referenceBottom=\(referenceBottom) firstRowTop=\(firstRowTopInWindow) actualGap=\(actualGap) "
                + "prePickerAnchor=\(prePickerAnchor) expectedGap=\(expectedGap)")
        let attachment = XCTAttachment(
            string: "issue944 gap \(actualGap) below \(referenceBottom), anchor \(prePickerAnchor)")
        attachment.lifetime = .keepAlways
        add(attachment)
        return ProbeMeasurement(
            referenceBottom: referenceBottom, firstRowTop: firstRowTopInWindow, prePickerAnchor: prePickerAnchor)
    }

    /// Polls `condition` until it holds, so a fast machine returns immediately and a slow one still
    /// gets the full ceiling instead of a fixed sleep (issue #1012's wait-helper pattern).
    @MainActor private func waitUntil(
        _ what: String, timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out after \(timeout): \(what)")
        throw MobileFixtureError.unavailable
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable final class SearchScopeProbeState {
    var text = ""
    var scope = MLSearchScope.all
}

struct SearchScopeProbeShell: View {
    let items: [PhotoItem]
    let feed: UIKitThumbnailFeed
    let state: SearchScopeProbeState
    /// False models a search placement whose scope picker never renders above the grid, for example
    /// the system's bottom search placement. The grid still receives the gap request.
    var presentsScopePicker = true

    var body: some View {
        NavigationStack {
            if presentsScopePicker {
                searchableGrid
                    .searchScopes(Bindable(state).scope, activation: .onTextEntry) {
                        Text("Alle").tag(MLSearchScope.all)
                        Text("Text").tag(MLSearchScope.text)
                    }
            } else {
                searchableGrid
            }
        }
    }

    private var searchableGrid: some View {
        UIKitTimelineGrid(
            items: items,
            thumbnailFeed: feed,
            level: 0,
            fillOrder: .topLeading,
            selectionMode: false,
            scopeBarGap: SquareTileGridEngine.standardOuterMargin
        )
        .ignoresSafeArea()
        .navigationTitle("Suche")
        .searchable(
            text: Bindable(state).text,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Suche")
        )
    }
}
