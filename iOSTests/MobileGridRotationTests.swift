import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// Rotating an iPhone to landscape and back must return the library grid to the same place. The probe hosts the
/// production grid below a native navigation bar and rotates the real window scene, so UIKit delivers its own
/// sequence of size and safe-area layouts.
final class MobileGridRotationTests: XCTestCase {
    @MainActor func testRotationRoundTripKeepsTheFirstRowBelowTheBarWithThreeColumns() async throws {
        try await assertRotationRoundTripKeepsPlace(level: nil, expectedColumns: 3)
    }

    @MainActor func testRotationRoundTripKeepsTheFirstRowBelowTheBarWithFiveColumns() async throws {
        try await assertRotationRoundTripKeepsPlace(level: 2, expectedColumns: 5)
    }

    /// In landscape the large top row can sit almost completely under the bar. The photo just below the bar is the
    /// place the person sees, so it must stay just below the taller portrait bar.
    @MainActor func testRotationToPortraitKeepsThePhotoBelowTheBarWhenTheTopRowSitsUnderIt() async throws {
        try await withRotationProbe(level: nil) { grid, rotate in
            try await rotate(.landscapeRight)
            let plan = try XCTUnwrap(grid.accessibilityFramePlan())
            XCTAssertEqual(plan.columns, 3)
            // A row starts 10 pt below the bar; the row above it sits under the bar except for its bottom edge.
            let usableTop = grid.safeAreaInsets.top
            let rowTop = (plan.pitch * 300).rounded()
            grid.scrollView.setContentOffset(
                CGPoint(x: 0, y: rowTop + plan.pitch - 10 - usableTop), animated: false)
            try await Task.sleep(for: .milliseconds(400))
            let before = try firstPhotoBelowBar(grid)
            XCTAssertEqual(before.offset, 10, accuracy: 1)

            try await rotate(.portrait)
            let after = try firstPhotoBelowBar(grid)
            let text =
                "before item=\(before.index) offset=\(before.offset) after item=\(after.index) offset=\(after.offset)"
            XCTAssertEqual(try XCTUnwrap(grid.accessibilityFramePlan()).columns, 3, text)
            XCTAssertEqual(after.index, before.index, "the first photo below the bar stays first\n\(text)")
            XCTAssertEqual(after.offset, before.offset, accuracy: 1, "its distance to the bar stays\n\(text)")
        }
    }

    @MainActor private func assertRotationRoundTripKeepsPlace(level: Int?, expectedColumns: Int) async throws {
        try await withRotationProbe(level: level) { grid, rotate in
            // The middle of the library, with the top row partly under the navigation bar.
            let pitch = try XCTUnwrap(grid.accessibilityFramePlan()).pitch
            grid.scrollView.setContentOffset(CGPoint(x: 0, y: (pitch * 300.6).rounded()), animated: false)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(try XCTUnwrap(grid.accessibilityFramePlan()).columns, expectedColumns)
            let before = try firstPhotoBelowBar(grid)

            try await rotate(.landscapeRight)
            let landscape = try firstPhotoBelowBar(grid)
            try await rotate(.portrait)
            let after = try firstPhotoBelowBar(grid)
            let plan = try XCTUnwrap(grid.accessibilityFramePlan())
            let text = """
                before item=\(before.index) offset=\(before.offset) pitch=\(pitch)
                landscape item=\(landscape.index) offset=\(landscape.offset)
                after item=\(after.index) offset=\(after.offset) columns=\(plan.columns)
                """

            XCTAssertEqual(plan.columns, expectedColumns, "the density stays\n\(text)")
            XCTAssertEqual(after.index, before.index, "the first photo below the bar stays first\n\(text)")
            XCTAssertEqual(after.offset, before.offset, accuracy: pitch, "the first row stays in place\n\(text)")
        }
    }

    /// Hosts the production grid with 3,000 photos in a portrait window, then runs `body` with the grid and a function
    /// that rotates the window scene. The scene returns to its original orientation afterwards.
    @MainActor private func withRotationProbe(
        level: Int?,
        _ body: (UIKitTimelineGridHostView, (UIInterfaceOrientation) async throws -> Void) async throws -> Void
    ) async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "rotation of the full window is iPhone only")
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let feed = UIKitThumbnailFeed(
            cache: ThumbnailCache(rootDirectory: cacheDirectory), loader: ChromeProbeLoader())
        let items = (0..<3_000).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "rotation-probe", nodeID: "\($0)"),
                captureTime: Date(timeIntervalSince1970: TimeInterval($0)), mediaType: "image/jpeg")
        }

        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let originalOrientation = scene.interfaceOrientation
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(
            rootView: RotationProbeShell(items: items, feed: feed, level: level))
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let rotate: (UIInterfaceOrientation) async throws -> Void = { orientation in
            let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscapeRight : .portrait
            // The system can report an error and still rotate, for example BSActionErrorDomain error 2 on a busy
            // runner. The reached orientation decides; a missed rotation is requested once more before the test fails.
            var errors: [String] = []
            for attempt in 1...2 where attempt == 1 || scene.interfaceOrientation != orientation {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    errors.append(error.localizedDescription)
                }
                for _ in 0..<50 where scene.interfaceOrientation != orientation {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            XCTAssertEqual(
                scene.interfaceOrientation, orientation, "rotation failed: \(errors.joined(separator: "; "))")
            try await Task.sleep(for: .milliseconds(1_000))
        }
        if originalOrientation != .portrait { try await rotate(.portrait) }
        try await Task.sleep(for: .seconds(1))

        let grid = try XCTUnwrap(descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.first)
        XCTAssertGreaterThan(grid.safeAreaInsets.top, 60, "the navigation bar covers the top of the grid")
        do {
            try await body(grid, rotate)
        } catch {
            if scene.interfaceOrientation != originalOrientation { try? await rotate(originalOrientation) }
            throw error
        }
        if scene.interfaceOrientation != originalOrientation { try await rotate(originalOrientation) }
    }

    /// The first photo whose top edge lies in the usable area below the navigation bar, with its distance to that edge.
    @MainActor private func firstPhotoBelowBar(
        _ grid: UIKitTimelineGridHostView
    ) throws -> (index: Int, offset: CGFloat) {
        let plan = try XCTUnwrap(grid.accessibilityFramePlan())
        let usableTop = grid.scrollView.contentOffset.y + grid.safeAreaInsets.top
        let slot = try XCTUnwrap(
            plan.visibleSlots.filter { $0.slotRect.minY >= usableTop - 0.5 }
                .min { ($0.slotRect.minY, $0.slotRect.minX) < ($1.slotRect.minY, $1.slotRect.minX) })
        return (slot.index, slot.slotRect.minY - usableTop)
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

/// The library route's chrome around the production grid: a tab bar, a navigation stack with a large title, and a
/// grid that extends below both bars.
private struct RotationProbeShell: View {
    let items: [PhotoItem]
    let feed: UIKitThumbnailFeed
    let level: Int?

    var body: some View {
        TabView {
            Tab("Mediathek", systemImage: "photo.on.rectangle") {
                NavigationStack {
                    UIKitTimelineGrid(items: items, thumbnailFeed: feed, level: level)
                        .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
                        .mobileNavigationTitle("Mediathek")
                }
            }
            Tab("Sammlungen", systemImage: "rectangle.stack") { Text("Sammlungen") }
        }
    }
}
