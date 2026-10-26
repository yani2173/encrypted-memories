import GridCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import UIKit
import XCTest

@testable import TimelineUIKitFeature

final class MobileTimelineRevealTests: XCTestCase {
    /// "Show in Library" centers the photo between the bars, keeps it in view through a following change of the top
    /// inset, and leaves the position alone for a photo that is not in the grid.
    @MainActor func testARevealedPhotoIsCenteredAndStaysInView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let items = (0..<3_000).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "reveal-test", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0)), mediaType: "image/jpeg")
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.additionalSafeAreaInsets.top = 88
        let grid = UIKitTimelineGridHostView()
        controller.view = grid
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            grid.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        grid.configure(items: items, contentRevision: 1, thumbnailFeed: feed)
        window.layoutIfNeeded()
        let target = items[1_200].uid

        XCTAssertTrue(grid.revealItem(target))
        let center = try XCTUnwrap(visibleRect(of: 1_200, in: grid)).midY - grid.scrollView.contentOffset.y
        let insets = grid.safeAreaInsets
        let usableCenter = insets.top + (grid.bounds.height - insets.top - insets.bottom) / 2
        XCTAssertEqual(center, usableCenter, accuracy: 1)

        // The memories area opening or closing above the grid changes its top inset: the photo stays below the bar.
        controller.additionalSafeAreaInsets.top = 260
        window.layoutIfNeeded()
        let moved = try XCTUnwrap(visibleRect(of: 1_200, in: grid), "the revealed photo left the viewport")
        XCTAssertGreaterThanOrEqual(moved.minY - grid.scrollView.contentOffset.y, grid.safeAreaInsets.top - 1)

        let offset = grid.scrollView.contentOffset
        XCTAssertFalse(grid.revealItem(PhotoUID(volumeID: "reveal-test", nodeID: "missing")))
        XCTAssertEqual(grid.scrollView.contentOffset, offset, "a missing photo must not move the library")
    }

    @MainActor private func visibleRect(of index: Int, in grid: UIKitTimelineGridHostView) -> CGRect? {
        grid.accessibilityFramePlan()?.visibleSlots.first { $0.index == index }?.slotRect
    }
}
