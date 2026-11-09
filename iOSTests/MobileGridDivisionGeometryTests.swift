import GridCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import TimelineUIKitAdapter
import UIKit
import XCTest

@testable import TimelineUIKitFeature

final class MobileGridDivisionGeometryTests: XCTestCase {
    @MainActor func testProfileChangeComparesTheDisplayedTileSizes() throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 867, height: 669)
        window.isHidden = false
        defer { window.isHidden = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let items = (0..<120).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "division-profile", nodeID: String($0)), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        let host = UIKitTimelineGridHostView(frame: window.bounds)
        window.addSubview(host)
        defer {
            host.setActive(false)
            host.removeFromSuperview()
        }
        host.configure(items: items, thumbnailFeed: feed, fillOrder: .topLeading, initialViewportPlacement: .oldest)
        host.layoutIfNeeded()
        let sourceProfile = host.currentProfile()
        XCTAssertEqual(sourceProfile.id, "touchRegularTimeline")
        XCTAssertEqual(sourceProfile.defaultLevel, 1)
        let sourceEngine = host.currentEngine(profile: sourceProfile)
        let sourceWidth = UIKitTimelineGridProfileAdapter.layoutSize(
            forBounds: host.bounds, safeAreaInsets: host.safeAreaInsets
        ).width
        XCTAssertEqual(sourceWidth, 867)
        // Touch-regular level 1 uses 6 columns with a gap of 3, so its tile side is (867 - 3 x 5) / 6 = 142.
        XCTAssertEqual(
            sourceEngine.resolvedMetrics(level: 1, width: sourceWidth).slotSide, 142, accuracy: 0.001)
        host.frame.size.width = 402
        let targetProfile = host.currentProfile()
        XCTAssertEqual(targetProfile.id, "touchCompactTimeline")
        let targetEngine = host.currentEngine(profile: targetProfile)
        let targetWidth = UIKitTimelineGridProfileAdapter.layoutSize(
            forBounds: host.bounds, safeAreaInsets: host.safeAreaInsets
        ).width
        XCTAssertEqual(targetWidth, 402)
        // Touch-compact tile sides at 402 are 201, (402 - 3 x 2) / 3 = 132, 78.4 and 55.71, so level 1 stays
        // the closest match to the 142 pt tiles of the source profile.
        XCTAssertEqual(
            targetEngine.resolvedMetrics(level: 1, width: targetWidth).slotSide, 132, accuracy: 0.001)
        XCTAssertEqual(host.interactiveLevel, 1, "Profile changes compare the tile sizes actually displayed")
    }

    @MainActor func testGridUsesFullWidthAndKeepsHitTargetsInBothLayoutDirections() throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 867, height: 669)
        window.isHidden = false
        defer { window.isHidden = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let items = (0..<120).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "division-probe", nodeID: String($0)), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        let frame = CGRect(x: 0, y: 0, width: 867, height: 669)
        let profile = UIKitTimelineGridProfileAdapter().profile(forBounds: frame)
        // The removed vertical division spanned the half-way columns; the full-width layout must still show a
        // photo there instead of a reserved gap.
        let formerDivisionMidX: CGFloat = 455.116 + 20
        var previousRects: [CGRect]?
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            let host = UIKitTimelineGridHostView(frame: frame)
            host.semanticContentAttribute = direction
            window.addSubview(host)
            defer {
                host.setActive(false)
                host.removeFromSuperview()
            }
            host.configure(
                items: items, thumbnailFeed: feed, level: profile.defaultLevel, gridProfile: profile,
                fillOrder: .topLeading, initialViewportPlacement: .oldest)
            host.setNeedsLayout()
            host.layoutIfNeeded()
            let plan = try XCTUnwrap(host.accessibilityFramePlan())
            XCTAssertEqual(plan.columns, 6)
            XCTAssertFalse(plan.visibleSlots.isEmpty)
            let row = plan.visibleSlots.filter { $0.row == 0 }
            XCTAssertEqual(row.map(\.slotRect.minX).min(), 0)
            XCTAssertEqual(try XCTUnwrap(row.map(\.slotRect.maxX).max()), frame.width, accuracy: 1e-9)
            for slot in plan.visibleSlots {
                let point = CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY)
                XCTAssertEqual(host.item(at: point)?.uid, items[slot.index].uid)
            }
            let witness = try XCTUnwrap(plan.visibleSlots.first)
            XCTAssertNotNil(host.item(at: CGPoint(x: formerDivisionMidX, y: witness.slotRect.midY)))
            let rects = plan.visibleSlots.map(\.slotRect)
            if let previousRects { XCTAssertEqual(rects, previousRects, "Hardware frames must not be mirrored twice") }
            previousRects = rects
            host.scrollView.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
            let anchor = try XCTUnwrap(host.currentScrollAnchor())
            host.setNeedsLayout()
            host.layoutIfNeeded()
            let relaid = try XCTUnwrap(host.accessibilityFramePlan())
            let anchored = try XCTUnwrap(relaid.visibleSlots.first { items[$0.index].uid == anchor.itemID })
            XCTAssertEqual(anchored.slotRect.minY - host.scrollView.contentOffset.y, anchor.topOffset, accuracy: 1)
        }
    }
}
