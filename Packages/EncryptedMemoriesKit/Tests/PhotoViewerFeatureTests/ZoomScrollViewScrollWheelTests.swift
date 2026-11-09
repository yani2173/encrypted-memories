import AppKit
import PhotoViewerCore
import XCTest

@testable import PhotoViewerFeature

/// Drives the real `ZoomScrollView.scrollWheel(with:)` with synthetic trackpad events (precise deltas with scroll
/// phases), so the wiring between the AppKit view and the shared page swipe policy runs for real.
@MainActor
final class ZoomScrollViewScrollWheelTests: XCTestCase {
    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
    }

    private func makeView() -> (ZoomScrollView, SwipeLog) {
        let log = SwipeLog()
        let view = ZoomScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.allowsMagnification = true
        view.minMagnification = 1
        view.maxMagnification = 10
        view.onPageSwipe = { log.directions.append($0) }
        let imageView = NSImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        imageView.image = NSImage(size: NSSize(width: 400, height: 300))
        view.documentView = imageView
        return (view, log)
    }

    private func event(deltaX: Int32, deltaY: Int32 = 0, phase: Phase) throws -> NSEvent {
        let cg = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: deltaY, wheel2: deltaX, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// The direction that the policy must report for a rightward trackpad movement, whatever the system scroll setting.
    private func expectedDirection(for event: NSEvent) -> ViewerPageSwipeDirection {
        event.isDirectionInvertedFromDevice ? .previous : .next
    }

    private func swipe(_ view: ZoomScrollView) throws -> ViewerPageSwipeDirection {
        let begin = try event(deltaX: 0, phase: .began)
        view.scrollWheel(with: begin)
        view.scrollWheel(with: try event(deltaX: 30, deltaY: 2, phase: .changed))
        view.scrollWheel(with: try event(deltaX: 22, deltaY: 1, phase: .ended))
        return expectedDirection(for: begin)
    }

    func testACompletedTrackpadSwipeAtFitScaleReportsOnePageSwipe() throws {
        let (view, log) = makeView()

        let expected = try swipe(view)

        XCTAssertEqual(log.directions, [expected])
    }

    func testAShortSwipeAtFitScaleReportsNoPageSwipe() throws {
        let (view, log) = makeView()

        view.scrollWheel(with: try event(deltaX: 0, phase: .began))
        view.scrollWheel(with: try event(deltaX: 4, phase: .changed))
        view.scrollWheel(with: try event(deltaX: 2, phase: .ended))

        XCTAssertEqual(log.directions, [])
    }

    func testAZoomedImageKeepsTheScrollForPanningAndReportsNoPageSwipe() throws {
        let (view, log) = makeView()
        view.magnification = 3
        XCTAssertGreaterThan(view.magnification, view.minMagnification + 0.001)

        _ = try swipe(view)

        XCTAssertEqual(log.directions, [])
    }
}

@MainActor
private final class SwipeLog {
    var directions: [ViewerPageSwipeDirection] = []
}
