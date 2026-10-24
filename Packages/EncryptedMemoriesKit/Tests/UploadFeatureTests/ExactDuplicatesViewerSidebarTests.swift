#if os(macOS)
    import AppKit
    import MediaByteCache
    import MediaCache
    import Observation
    import PhotoViewerFeature
    import PhotosCore
    import SwiftUI
    import XCTest

    /// The Mac viewer with a filmstrip, of a group of duplicates and of a burst, in a window laid out like the library
    /// window: the split-view sidebar, the viewer beside it that moves with the sidebar, and the window toolbar with
    /// Keep This Copy and Merge. Showing or hiding the sidebar, also at other window widths, must finish its layout.
    /// A layout that never finishes makes AppKit raise an exception after more Update Constraints passes than the
    /// window has views, which stops the app.
    @MainActor
    final class ExactDuplicatesViewerSidebarTests: XCTestCase {
        func testShowingAndHidingTheSidebarBesideTheViewerOfAGroupFinishesItsLayout() async throws {
            let items = Self.photos(tags: [], burstMembers: [])
            let viewer = PhotoViewerModel(items: items, index: 1, feed: try makeFeed(), media: ColorMedia())
            defer { viewer.stop() }
            try await assertTheSidebarTogglesBeside(viewer, itemFilmstripLabel: "Identical copies")
        }

        func testShowingAndHidingTheSidebarBesideTheViewerOfABurstFinishesItsLayout() async throws {
            let items = Self.photos(tags: [.bursts], burstMembers: ["photo-0", "photo-1", "photo-2"])
            let viewer = PhotoViewerModel(
                items: items, index: 1, feed: try makeFeed(), media: ColorMedia(),
                burstProvider: BurstMembers(items: items))
            defer { viewer.stop() }
            try await assertTheSidebarTogglesBeside(viewer, itemFilmstripLabel: nil)
        }

        private func assertTheSidebarTogglesBeside(
            _ viewer: PhotoViewerModel, itemFilmstripLabel: String?
        ) async throws {
            // The minimum width of the viewer must not follow the width that the viewer measured. A minimum that
            // follows it lets the viewer shrink only a little in each layout pass, and the sidebar toggle below
            // would then stop the test process instead of failing this test.
            let minimumWidths = try await minimumWidths(of: viewer, itemFilmstripLabel: itemFilmstripLabel)
            XCTAssertEqual(minimumWidths.count, 2)
            guard let first = minimumWidths.first, minimumWidths.allSatisfy({ $0 == first }), first < 320 else {
                XCTFail("The minimum width of the viewer follows its measured width: \(minimumWidths)")
                return
            }

            let sidebar = SidebarState()
            let controller = NSHostingController(
                rootView: SidebarWindowRoute(sidebar: sidebar, viewer: viewer, itemFilmstripLabel: itemFilmstripLabel))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1_080, height: 720))
            Self.showUnseen(window)
            defer { window.orderOut(nil) }
            await Self.waitForFilmstrip(beside: sidebar, in: controller.view)
            XCTAssertTrue(viewer.hasBurstFilmstrip || itemFilmstripLabel != nil)

            for width in [1_080.0, 900, 1_300, 1_080] {
                window.setContentSize(NSSize(width: width, height: 720))
                for _ in 0..<2 {
                    await Self.toggle(sidebar, laidOutIn: controller.view)
                }
            }
            await Self.toggle(sidebar, laidOutIn: controller.view)
            XCTAssertEqual(sidebar.visibility, .detailOnly)

            // The filmstrip panel keeps its look: 20 points from each side of the viewer, its photos 12 points inside.
            controller.view.layoutSubtreeIfNeeded()
            let strip = try XCTUnwrap(Self.filmstrip(in: controller.view), "no filmstrip")
            let frame = strip.convert(strip.bounds, to: nil)
            XCTAssertEqual(frame.minX, 32, accuracy: 1)
            XCTAssertEqual(frame.width, 1_080 - 64, accuracy: 1)
        }

        /// The minimum width of the viewer alone, after it laid out at 1,080 and at 1,300 points.
        private func minimumWidths(
            of viewer: PhotoViewerModel, itemFilmstripLabel: String?
        ) async throws -> [CGFloat] {
            let controller = NSHostingController(
                rootView: PhotoViewerView(model: viewer, onClose: {}, itemFilmstripLabel: itemFilmstripLabel))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            Self.showUnseen(window)
            defer { window.orderOut(nil) }
            var widths: [CGFloat] = []
            for width in [1_080.0, 1_300] {
                window.setContentSize(NSSize(width: width, height: 720))
                await Self.waitForFilmstrip(in: controller.view, x: 32, width: width - 64)
                controller.view.layoutSubtreeIfNeeded()
                widths.append(controller.sizeThatFits(in: NSSize(width: 0, height: 720)).width)
            }
            return widths
        }

        /// Puts `window` on screen, so AppKit lays it out like the library window, but invisible and without taking
        /// clicks: the test runs while the person works on this Mac.
        private static func showUnseen(_ window: NSWindow) {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        }

        /// Toggles the sidebar with the library window's real animation, waits until SwiftUI reports the animation
        /// removed, and then until the filmstrip and the sidebar pane reached their frames. A completion that never
        /// comes ends the wait after 5 seconds.
        private static func toggle(_ sidebar: SidebarState, laidOutIn view: NSView) async {
            await withCheckedContinuation { continuation in
                let resumption = Resumption(continuation)
                let timeout = Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    print("ExactDuplicatesViewerSidebarTests: no animation completion after 5 s")
                    resumption.resume()
                }
                withAnimation(.easeInOut(duration: 0.22), completionCriteria: .removed) {
                    sidebar.toggle()
                } completion: {
                    timeout.cancel()
                    resumption.resume()
                }
            }
            await waitForFilmstrip(beside: sidebar, in: view)
        }

        /// The library window route: the viewer starts beside a visible sidebar. AppKit collapses the sidebar pane of
        /// the split view while the sidebar is hidden, and opens it to a width that stops changing while it shows.
        private static func waitForFilmstrip(beside sidebar: SidebarState, in view: NSView) async {
            let hidden = sidebar.visibility == .detailOnly
            let leading: CGFloat = hidden ? 0 : 220
            await waitForFilmstrip(in: view, x: leading + 32, width: view.bounds.width - leading - 64) {
                guard let pane = sidebarSplit(in: view)?.arrangedSubviews.first else { return nil }
                let paneHidden = pane.isHidden || pane.frame.width < 1
                guard paneHidden == hidden else { return nil }
                return paneHidden ? 0 : pane.frame.width
            }
        }

        /// Waits until the filmstrip in `view` shows at `x` with `width` in window coordinates, and `pane` reports the
        /// same value, on three polls in a row, polling every 10 ms. `pane` returns nil while it is not ready. A layout
        /// that keeps a measured width in view state reaches this frame only after that state changed, so the wait
        /// also covers such an update. After 5 seconds the wait ends with a log line, and the checks after it decide.
        private static func waitForFilmstrip(
            in view: NSView, x: CGFloat, width: CGFloat, pane: () -> CGFloat? = { 0 }
        ) async {
            let deadline = ContinuousClock.now + .seconds(5)
            var polls = 0
            var lastPane: CGFloat?
            var frame: CGRect?
            while polls < 3, ContinuousClock.now < deadline, !Task.isCancelled {
                view.layoutSubtreeIfNeeded()
                frame = filmstrip(in: view).map { $0.convert($0.bounds, to: nil) }
                let paneState = pane()
                if let frame, abs(frame.minX - x) < 1, abs(frame.width - width) < 1, let paneState,
                    paneState == lastPane || polls == 0
                {
                    polls += 1
                } else {
                    polls = 0
                }
                lastPane = paneState
                try? await Task.sleep(for: .milliseconds(10))
            }
            if polls < 3 {
                let last = frame.map { "\($0)" } ?? "none"
                let paneText = lastPane.map { "\($0)" } ?? "not ready"
                print(
                    "ExactDuplicatesViewerSidebarTests: filmstrip not at x \(x), width \(width) after 5 s; "
                        + "last frame \(last), sidebar pane \(paneText)")
            }
        }

        private func makeFeed() throws -> ThumbnailFeed {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("duplicates-viewer-sidebar-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return ThumbnailFeed(
                cache: ThumbnailCache(namespace: "duplicates-viewer-sidebar-\(UUID().uuidString)", rootDirectory: root),
                loader: ColorThumbnails())
        }

        private static func photos(tags: Set<PhotoTag>, burstMembers: [String]) -> [PhotoItem] {
            (0..<3).map {
                PhotoItem(
                    uid: PhotoUID(volumeID: "v", nodeID: "photo-\($0)"),
                    captureTime: Date(timeIntervalSince1970: 1_749_456_000), mediaType: "image/png", tags: tags,
                    burstMemberIDs: burstMembers)
            }
        }

        /// The split view of the navigation split view; its first pane is the sidebar. The viewer's inspector has its
        /// own split view, which contains the filmstrip.
        private static func sidebarSplit(in view: NSView) -> NSSplitView? {
            let strip = filmstrip(in: view)
            func search(_ view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView, strip.map({ !$0.isDescendant(of: split) }) ?? true { return split }
                for subview in view.subviews {
                    if let found = search(subview) { return found }
                }
                return nil
            }
            return search(view)
        }

        /// The scroll view of the native filmstrip collection.
        private static func filmstrip(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSCollectionView { return scroll }
            for subview in view.subviews {
                if let found = filmstrip(in: subview) { return found }
            }
            return nil
        }
    }

    /// Resumes a waiting test once, from whichever event comes first.
    @MainActor
    private final class Resumption {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// The members of one burst, as the library knows them.
    struct BurstMembers: BurstGroupProvider {
        let items: [PhotoItem]
        func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { items }
    }

    @Observable @MainActor
    private final class SidebarState {
        var visibility: NavigationSplitViewVisibility = .all

        func toggle() { visibility = visibility == .detailOnly ? .all : .detailOnly }
    }

    /// The library window of the Mac app around the viewer: the viewer is a sibling of the split view and moves
    /// beside the floating sidebar with the sidebar's curve.
    private struct SidebarWindowRoute: View {
        @Bindable var sidebar: SidebarState
        let viewer: PhotoViewerModel
        let itemFilmstripLabel: String?
        private static let sidebarWidth: CGFloat = 220

        var body: some View {
            ZStack {
                NavigationSplitView(columnVisibility: $sidebar.visibility) {
                    List { Text(verbatim: "Library") }
                        .navigationSplitViewColumnWidth(Self.sidebarWidth)
                } detail: {
                    Color.clear
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(verbatim: "Vienna").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(verbatim: "June 9, 2025").font(.system(size: 11)).lineLimit(1)
                        }
                        .fixedSize()
                        .padding(.horizontal, 16)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                        } label: {
                            Label("Keep This Copy", systemImage: "checkmark.circle")
                        }
                        Button {
                        } label: {
                            Label("Merge", systemImage: "arrow.triangle.merge")
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }
                        Button {
                        } label: {
                            Label("Favorite", systemImage: "heart")
                        }
                    }
                }
                PhotoViewerView(model: viewer, onClose: {}, itemFilmstripLabel: itemFilmstripLabel)
                    .padding(.leading, sidebar.visibility == .detailOnly ? 0 : Self.sidebarWidth)
                    .animation(.easeInOut(duration: 0.22), value: sidebar.visibility)
            }
        }
    }
#endif
