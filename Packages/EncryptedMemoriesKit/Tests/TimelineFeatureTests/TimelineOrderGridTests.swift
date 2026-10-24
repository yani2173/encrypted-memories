import AppKit
import GridCore
import Metal
import PhotosCore
import XCTest

@testable import TimelineFeature

@MainActor
final class TimelineOrderGridTests: XCTestCase {
    private func gridFixture() throws -> (MetalGridScrollHost, NSWindow, [PhotoItem], Int) {
        _ = NSApplication.shared
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let items = (0..<3_000).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "order-test", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0 / 2)), mediaType: "image/jpeg")
        }
        let host = try XCTUnwrap(
            MetalGridScrollHost(device: device, dataSource: OrderGridSource(items), gridProfile: .testRegularTimeline))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.scrollToFlatIndex(900)
        let y = try XCTUnwrap(
            host.coordinator.settleScrollOffsetY(
                toLevel: host.coordinator.level,
                anchorContentPoint: CGPoint(x: 400, y: host.coordinator.scrollOriginY + 300),
                viewportPoint: CGPoint(x: 20, y: 300)))
        host.coordinator.clipView?.scroll(to: CGPoint(x: 0, y: y))
        let phase = try XCTUnwrap(host.coordinator.currentPhase())
        return (host, window, items, phase)
    }

    func testUnchangedGridRevisionRefreshesVideoMetadataWithoutRebuildingTheGrid() throws {
        let (host, window, items, phase) = try gridFixture()
        defer {
            host.removeFromSuperview()
            window.contentView = nil
        }
        let before = try XCTUnwrap(host.currentScrollAnchor())
        let index = try XCTUnwrap(host.coordinator.flatIndex(forUID: before.itemID))
        let frame = try XCTUnwrap(host.coordinator.cellContentRect(forFlatIndex: index))
        var enriched = items
        enriched[index] = PhotoItem(
            uid: items[index].uid, captureTime: items[index].captureTime,
            mediaType: "video/quicktime", durationSeconds: 2.5)
        let coordinator = MetalProductionGridView.Coordinator()
        coordinator.host = host
        coordinator.allItems = items
        coordinator.dataRevision = 1
        let accessibility = MetalGridAccessibilityProvider(host: host, coordinator: host.coordinator)
        accessibility.items = items
        coordinator.a11y = accessibility
        var rebuilds = 0
        coordinator.receiveContent(
            items: enriched, revision: 1, routeGeneration: 0, initialViewport: .newest, markers: [],
            makeSource: {
                rebuilds += 1
                return OrderGridSource(enriched)
            })
        XCTAssertEqual(coordinator.allItems[index], enriched[index])
        XCTAssertTrue(coordinator.allItems[index].isVideo)
        XCTAssertEqual(accessibility.items[index], enriched[index])
        XCTAssertEqual(rebuilds, 0)
        XCTAssertEqual(host.coordinator.currentPhase(), phase)
        XCTAssertEqual(try XCTUnwrap(host.coordinator.cellContentRect(forFlatIndex: index)), frame)
        XCTAssertEqual(host.currentScrollAnchor()?.itemID, before.itemID)
        XCTAssertEqual(try XCTUnwrap(host.currentScrollAnchor()).topOffset, before.topOffset, accuracy: 0.5)
    }

    func testMetadataThatKeepsTheOrderAlsoKeepsTheVisibleFramesAndZoomPhase() throws {
        let (host, window, items, phase) = try gridFixture()
        defer {
            host.removeFromSuperview()
            window.contentView = nil
        }
        XCTAssertNotEqual(phase, 0, "exercise a noncanonical zoom column phase")
        let before = try XCTUnwrap(host.currentScrollAnchor())
        let index = try XCTUnwrap(host.coordinator.flatIndex(forUID: before.itemID))
        let frame = try XCTUnwrap(host.coordinator.cellContentRect(forFlatIndex: index))
        var enriched = items
        for index in enriched.indices {
            enriched[index].timelineOrder = .init(
                exactCaptureTime: items[index].captureTime.addingTimeInterval(index.isMultiple(of: 2) ? 0.1 : 0.8))
        }
        XCTAssertEqual(enriched.sorted(by: TimelineOrder.areInIncreasingOrder).map(\.uid), items.map(\.uid))
        let coordinator = MetalProductionGridView.Coordinator()
        coordinator.host = host
        coordinator.allItems = items
        coordinator.dataRevision = 1
        coordinator.receiveContent(
            items: enriched, revision: 2, routeGeneration: 0, initialViewport: .newest, markers: [],
            makeSource: { OrderGridSource(enriched) })
        XCTAssertEqual(coordinator.allItems, enriched)
        XCTAssertEqual(host.coordinator.currentPhase(), phase)
        XCTAssertEqual(try XCTUnwrap(host.coordinator.cellContentRect(forFlatIndex: index)), frame)
        XCTAssertEqual(host.currentScrollAnchor()?.itemID, before.itemID)
        XCTAssertEqual(try XCTUnwrap(host.currentScrollAnchor()).topOffset, before.topOffset, accuracy: 0.5)
    }

    func testVisibleCorrectionWaitsUntilOffscreenAndKeepsTheScrollAnchor() throws {
        let (host, window, items, phase) = try gridFixture()
        defer {
            host.removeFromSuperview()
            window.contentView = nil
        }
        let before = try XCTUnwrap(host.currentScrollAnchor())
        let pair = try XCTUnwrap(host.coordinator.flatIndex(forUID: before.itemID)) / 2 * 2
        var corrected = items
        corrected[pair].timelineOrder = .init(exactCaptureTime: items[pair].captureTime.addingTimeInterval(0.8))
        corrected[pair + 1].timelineOrder = .init(exactCaptureTime: items[pair + 1].captureTime.addingTimeInterval(0.1))
        corrected.sort(by: TimelineOrder.areInIncreasingOrder)
        let coordinator = MetalProductionGridView.Coordinator()
        coordinator.host = host
        coordinator.allItems = items
        coordinator.dataRevision = 1
        let receive = {
            coordinator.receiveContent(
                items: corrected, revision: 2, routeGeneration: 0,
                initialViewport: .newest, markers: [], makeSource: { OrderGridSource(corrected) })
        }
        receive()
        XCTAssertEqual(coordinator.allItems, items)
        XCTAssertEqual(host.currentScrollAnchor()?.itemID, before.itemID)
        XCTAssertEqual(try XCTUnwrap(host.currentScrollAnchor()).topOffset, before.topOffset, accuracy: 0.5)
        receive()
        XCTAssertEqual(coordinator.allItems, items)

        var scrolledAnchor: GridScrollAnchor<PhotoUID>?
        host.onViewportChanged = {
            if scrolledAnchor == nil { scrolledAnchor = host.currentScrollAnchor() }
            coordinator.viewportChanged()
        }
        host.scrollToFlatIndex(1_350)
        XCTAssertEqual(coordinator.allItems, corrected)
        XCTAssertEqual(host.coordinator.currentPhase(), phase)
        XCTAssertEqual(host.coordinator.uid(atFlatIndex: pair), corrected[pair].uid)
        let expected = try XCTUnwrap(scrolledAnchor)
        XCTAssertEqual(host.currentScrollAnchor()?.itemID, expected.itemID)
        XCTAssertEqual(try XCTUnwrap(host.currentScrollAnchor()).topOffset, expected.topOffset, accuracy: 0.5)
    }
}

@MainActor
private final class OrderGridSource: MetalGridDataSource {
    let label = "order-test"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?
    init(_ items: [PhotoItem]) {
        sectionCounts = [items.count]
        flatUIDs = items.map(\.uid)
    }
    func hasImage(for uid: PhotoUID) -> Bool { false }
    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
}
