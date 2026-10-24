import GridCore
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import UIKit
import XCTest

@testable import TimelineUIKitFeature

final class MobileTimelineOrderTests: XCTestCase {
    @MainActor func testVisibleCorrectionWaitsUntilOffscreenAndKeepsTheScrollAnchor() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let items = (0..<3_000).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "order-test", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0 / 2)), mediaType: "image/jpeg")
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
        grid.committedPhase = 1
        let pitch = try XCTUnwrap(grid.accessibilityFramePlan()).pitch
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: pitch * 300.6), animated: false)
        let before = try XCTUnwrap(grid.currentScrollAnchor())
        let index = try XCTUnwrap(grid.itemIndexByUID[before.itemID])
        let pair = index / 2 * 2
        var corrected = items
        corrected[pair].timelineOrder = .init(exactCaptureTime: items[pair].captureTime.addingTimeInterval(0.8))
        corrected[pair + 1].timelineOrder = .init(exactCaptureTime: items[pair + 1].captureTime.addingTimeInterval(0.1))
        corrected.sort(by: TimelineOrder.areInIncreasingOrder)

        grid.configure(items: corrected, contentRevision: 2, thumbnailFeed: feed)
        XCTAssertEqual(grid.itemUIDs, items.map(\.uid), "the visible photos keep their slots")
        XCTAssertEqual(grid.currentScrollAnchor()?.itemID, before.itemID)
        XCTAssertEqual(try XCTUnwrap(grid.currentScrollAnchor()).topOffset, before.topOffset, accuracy: 0.5)
        // A repeated publication does not consume or replace the pending correction.
        grid.configure(items: corrected, contentRevision: 2, thumbnailFeed: feed)
        XCTAssertEqual(grid.itemUIDs, items.map(\.uid))

        let targetOffset = pitch * 450.6
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
        XCTAssertEqual(grid.scrollView.contentOffset.y, targetOffset, accuracy: 0.5)
        let afterScroll = try XCTUnwrap(grid.currentScrollAnchor())
        // The scroll callback applies the pending order when all affected slots are outside the viewport.
        XCTAssertEqual(grid.itemUIDs, corrected.map(\.uid))
        XCTAssertEqual(grid.committedPhase, 1, "the zoom column phase also stays unchanged")
        XCTAssertEqual(grid.currentScrollAnchor()?.itemID, afterScroll.itemID)
        XCTAssertEqual(try XCTUnwrap(grid.currentScrollAnchor()).topOffset, afterScroll.topOffset, accuracy: 0.5)
    }
}
