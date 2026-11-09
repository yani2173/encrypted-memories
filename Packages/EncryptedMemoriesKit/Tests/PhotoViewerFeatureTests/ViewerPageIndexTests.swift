import PhotosCore
import XCTest

@testable import PhotoViewerCore

final class ViewerPageIndexTests: XCTestCase {
    private let a = PhotoUID(volumeID: "v", nodeID: "a")
    private let b = PhotoUID(volumeID: "v", nodeID: "b")
    private let c = PhotoUID(volumeID: "v", nodeID: "c")

    func testPreservesRouteOrderAndResolvesFullUID() {
        let otherVolumeB = PhotoUID(volumeID: "other", nodeID: "b")
        let pages = ViewerPageIndex(orderedUIDs: [c, otherVolumeB, a, b])

        XCTAssertEqual(pages.orderedUIDs, [c, otherVolumeB, a, b])
        XCTAssertEqual(pages.uid(at: 1), otherVolumeB)
        XCTAssertEqual(pages.index(of: b), 3)
        XCTAssertEqual(pages.index(of: otherVolumeB), 1)
    }

    func testMissingUIDHasNoIndex() {
        let missing = PhotoUID(volumeID: "v", nodeID: "missing")
        let pages = ViewerPageIndex(orderedUIDs: [a, b])

        XCTAssertEqual(pages.index(of: missing), nil)
    }

    func testEmptyRouteHasNoPage() {
        let pages = ViewerPageIndex(orderedUIDs: [])

        XCTAssertNil(pages.uid(at: 0))
        XCTAssertNil(pages.index(of: a))
    }

    func testCompletedTrackpadSwipeResolvesOnePortablePageDirection() {
        var tracker = ViewerPageSwipeTracker()

        let beginning = tracker.consume(deltaX: 0, deltaY: 0, phase: .began)
        XCTAssertTrue(beginning.consumesEvent)
        XCTAssertNil(beginning.direction)
        XCTAssertNil(tracker.consume(deltaX: 30, deltaY: 2, phase: .changed).direction)
        let completion = tracker.consume(deltaX: 22, deltaY: 1, phase: .ended)

        XCTAssertTrue(completion.consumesEvent)
        XCTAssertEqual(completion.direction, .next)
        XCTAssertNil(
            tracker.consume(deltaX: 80, deltaY: 0, phase: .ended).direction,
            "one completed gesture must change at most one page")

        _ = tracker.consume(deltaX: 0, deltaY: 0, phase: .began)
        _ = tracker.consume(deltaX: -50, deltaY: -2, phase: .changed)
        XCTAssertEqual(tracker.consume(deltaX: -2, deltaY: 0, phase: .ended).direction, .previous)
    }

    func testTrackpadSwipeRejectsShortVerticalCancelledAndInvalidGestures() {
        var tracker = ViewerPageSwipeTracker()

        _ = tracker.consume(deltaX: 0, deltaY: 0, phase: .began)
        _ = tracker.consume(deltaX: -30, deltaY: 2, phase: .changed)
        XCTAssertNil(tracker.consume(deltaX: -10, deltaY: 1, phase: .ended).direction)

        _ = tracker.consume(deltaX: 0, deltaY: 0, phase: .began)
        let rejectedVertical = tracker.consume(deltaX: 20, deltaY: 60, phase: .changed)
        XCTAssertFalse(rejectedVertical.consumesEvent)
        let vertical = tracker.consume(deltaX: 40, deltaY: 10, phase: .ended)
        XCTAssertFalse(vertical.consumesEvent)
        XCTAssertNil(vertical.direction)

        _ = tracker.consume(deltaX: 0, deltaY: 0, phase: .began)
        _ = tracker.consume(deltaX: -80, deltaY: 0, phase: .changed)
        XCTAssertNil(tracker.consume(deltaX: 0, deltaY: 0, phase: .cancelled).direction)

        XCTAssertNil(tracker.consume(deltaX: .nan, deltaY: 0, phase: .changed).direction)
    }

    func testTrackpadSwipeNormalizesSystemScrollDirectionBeforePaging() {
        XCTAssertEqual(
            ViewerPageSwipeTracker.deviceRelativeDelta(12, directionWasInverted: false),
            12
        )
        XCTAssertEqual(
            ViewerPageSwipeTracker.deviceRelativeDelta(-12, directionWasInverted: true),
            12
        )
    }
}
