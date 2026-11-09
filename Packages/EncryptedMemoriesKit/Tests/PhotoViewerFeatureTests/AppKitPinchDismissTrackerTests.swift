import AppKit
import XCTest

@testable import PhotoViewerFeature

final class AppKitPinchDismissTrackerTests: XCTestCase {
    private typealias Outcome = AppKitPinchDismissTracker.Outcome

    func testOnlyAnOutwardPinchStartsADismissAndTheGestureKeepsItUntilItEnds() {
        var tracker = AppKitPinchDismissTracker()

        XCTAssertFalse(tracker.claims(magnification: 0.2), "a pinch-in goes to the native zoom")
        XCTAssertFalse(tracker.claims(magnification: 0))
        XCTAssertTrue(tracker.claims(magnification: -0.01))

        XCTAssertEqual(tracker.handle(phase: .began, magnification: -0.01), .began)
        XCTAssertTrue(tracker.isDismissing)
        XCTAssertTrue(tracker.claims(magnification: 0.2), "a running dismiss claims every following event")

        XCTAssertEqual(tracker.handle(phase: .ended, magnification: 0), .ended(shouldClose: false))
        XCTAssertFalse(tracker.isDismissing)
        XCTAssertFalse(tracker.claims(magnification: 0.2))
    }

    func testProgressFallsFromFullscreenAsThePinchGoesOutwardAndIsClamped() {
        var tracker = AppKitPinchDismissTracker()

        XCTAssertEqual(tracker.handle(phase: .began, magnification: -0.01), .began)
        XCTAssertEqual(tracker.handle(phase: .changed, magnification: -0.25), .changed(progress: 0.75))
        XCTAssertEqual(tracker.handle(phase: .changed, magnification: -0.25), .changed(progress: 0.5))
        XCTAssertEqual(
            tracker.handle(phase: .changed, magnification: -0.9), .changed(progress: 0),
            "past the grid cell the progress stops at 0")
        XCTAssertEqual(
            tracker.handle(phase: .changed, magnification: 5), .changed(progress: 1),
            "pinching back in past fullscreen stops at 1")
    }

    func testReleaseClosesOnlyPastTheThresholdAndOnlyWhenTheGestureEnds() {
        var tracker = AppKitPinchDismissTracker()
        let threshold = AppKitPinchDismissTracker.closeProgress

        _ = tracker.handle(phase: .began, magnification: -0.01)
        _ = tracker.handle(phase: .changed, magnification: -threshold)
        XCTAssertEqual(
            tracker.handle(phase: .ended, magnification: 0), .ended(shouldClose: false),
            "exactly the threshold stays open")

        _ = tracker.handle(phase: .began, magnification: -0.01)
        _ = tracker.handle(phase: .changed, magnification: -(threshold + 0.01))
        XCTAssertEqual(tracker.handle(phase: .ended, magnification: 0), .ended(shouldClose: true))

        _ = tracker.handle(phase: .began, magnification: -0.01)
        _ = tracker.handle(phase: .changed, magnification: -0.5)
        XCTAssertEqual(
            tracker.handle(phase: .cancelled, magnification: 0), .ended(shouldClose: false),
            "a cancelled gesture never closes")
        XCTAssertFalse(tracker.isDismissing)
    }

    func testABeginRestartsTheProgressAndOtherPhasesDoNothing() {
        var tracker = AppKitPinchDismissTracker()

        _ = tracker.handle(phase: .began, magnification: -0.01)
        _ = tracker.handle(phase: .changed, magnification: -0.6)
        _ = tracker.handle(phase: .cancelled, magnification: 0)
        _ = tracker.handle(phase: .began, magnification: -0.01)
        XCTAssertEqual(tracker.handle(phase: .changed, magnification: -0.1), .changed(progress: 0.9))
        XCTAssertEqual(tracker.handle(phase: .stationary, magnification: -0.5), .none)
    }

    func testOutcomeReportsExactlyOneCallback() {
        var calls: [String] = []
        func report(_ outcome: Outcome) {
            outcome.report(
                began: { calls.append("began") },
                changed: { calls.append("changed \($0)") },
                ended: { calls.append("ended \($0)") })
        }

        report(.none)
        report(.began)
        report(.changed(progress: 0.5))
        report(.ended(shouldClose: true))

        XCTAssertEqual(calls, ["began", "changed 0.5", "ended true"])
    }
}
