import PhotoViewerCore
import XCTest

/// Locks the shared one-finger drag-to-dismiss semantics for the viewer.
final class ViewerDragDismissPolicyTests: XCTestCase {
    func testEngagesOnlyOnVerticalDragWhileUnzoomed() {
        // A clear downward drag past the engage distance takes the media.
        XCTAssertTrue(ViewerDragDismissPolicy.engages(translation: CGSize(width: 4, height: 40), isZoomedIn: false))
        // A horizontal-dominant drag stays with the pager.
        XCTAssertFalse(ViewerDragDismissPolicy.engages(translation: CGSize(width: 60, height: 20), isZoomedIn: false))
        // A tiny jitter never grabs it.
        XCTAssertFalse(ViewerDragDismissPolicy.engages(translation: CGSize(width: 0, height: 5), isZoomedIn: false))
        // Zoomed media belongs to panning, never to dismiss.
        XCTAssertFalse(ViewerDragDismissPolicy.engages(translation: CGSize(width: 0, height: 80), isZoomedIn: true))
        // A degenerate reading never engages.
        XCTAssertFalse(
            ViewerDragDismissPolicy.engages(translation: CGSize(width: CGFloat.nan, height: 80), isZoomedIn: false))
    }

    func testSlightlyDiagonalDownwardSwipePrefersDismissWithoutStealingHorizontalPaging() {
        XCTAssertEqual(ViewerDragDismissPolicy.engageDistance, 8)
        XCTAssertEqual(ViewerDragDismissPolicy.verticalDominance, 0.9)
        XCTAssertTrue(
            ViewerDragDismissPolicy.engages(
                translation: CGSize(width: 40, height: 38), isZoomedIn: false))
        XCTAssertTrue(ViewerDragDismissPolicy.prefersDismissalAxis(velocity: CGSize(width: 400, height: 380)))
        XCTAssertFalse(ViewerDragDismissPolicy.prefersDismissalAxis(velocity: CGSize(width: 600, height: 200)))
        XCTAssertFalse(ViewerDragDismissPolicy.prefersDismissalAxis(velocity: .zero))
        XCTAssertFalse(
            ViewerDragDismissPolicy.prefersDismissalAxis(
                velocity: CGSize(width: CGFloat.nan, height: 400)))
    }

    func testProgressAndScaleTrackTheDragWithinBounds() {
        XCTAssertEqual(ViewerDragDismissPolicy.progress(translationY: 0, viewportHeight: 800), 0)
        XCTAssertEqual(ViewerDragDismissPolicy.progress(translationY: 400, viewportHeight: 800), 0.5, accuracy: 0.0001)
        // Clamped at 1 past a full-screen drag.
        XCTAssertEqual(ViewerDragDismissPolicy.progress(translationY: 1600, viewportHeight: 800), 1)

        // Scale starts at rest, shrinks with progress, and is floored so it never collapses.
        XCTAssertEqual(ViewerDragDismissPolicy.displayScale(progress: 0), 1)
        XCTAssertEqual(ViewerDragDismissPolicy.displayScale(progress: 1), ViewerDragDismissPolicy.minimumDisplayScale)
        XCTAssertGreaterThan(
            ViewerDragDismissPolicy.displayScale(progress: 0.5), ViewerDragDismissPolicy.minimumDisplayScale)
    }

    func testReleaseDismissesPastDistanceOrOnFastFlick() {
        let h: CGFloat = 800
        XCTAssertEqual(ViewerDragDismissPolicy.dismissDistanceFraction, 0.16)
        XCTAssertEqual(ViewerDragDismissPolicy.dismissVelocity, 750)
        // Far enough downward to dismiss.
        XCTAssertTrue(ViewerDragDismissPolicy.shouldDismiss(translationY: h * 0.25, velocityY: 0, viewportHeight: h))
        // Short but flicked fast to dismiss.
        XCTAssertTrue(ViewerDragDismissPolicy.shouldDismiss(translationY: 40, velocityY: 1500, viewportHeight: h))
        // Short and slow to spring back.
        XCTAssertFalse(ViewerDragDismissPolicy.shouldDismiss(translationY: 40, velocityY: 100, viewportHeight: h))
        // Upward drag never dismisses on velocity alone.
        XCTAssertFalse(ViewerDragDismissPolicy.shouldDismiss(translationY: -40, velocityY: 1500, viewportHeight: h))
        // Degenerate readings never close.
        XCTAssertFalse(
            ViewerDragDismissPolicy.shouldDismiss(translationY: CGFloat.nan, velocityY: 1500, viewportHeight: h))
    }
}
