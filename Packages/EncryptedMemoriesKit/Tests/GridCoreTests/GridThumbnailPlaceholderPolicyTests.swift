import XCTest

@testable import GridCore

final class GridThumbnailPlaceholderPolicyTests: XCTestCase {
    func testOnlyVisibleLoadingTilesKeepAnimatingAndReduceMotionStops() {
        XCTAssertTrue(GridThumbnailPlaceholderPolicy.shouldAnimate(visibleLoadingCount: 2, reduceMotion: false))
        XCTAssertFalse(GridThumbnailPlaceholderPolicy.shouldAnimate(visibleLoadingCount: 0, reduceMotion: false))
        XCTAssertFalse(GridThumbnailPlaceholderPolicy.shouldAnimate(visibleLoadingCount: 2, reduceMotion: true))
    }

    func testLightMovesTowardLowerRight() {
        let first = GridThumbnailPlaceholderPolicy.lightPosition(at: 0.25)
        let later = GridThumbnailPlaceholderPolicy.lightPosition(at: 1.0)
        XCTAssertLessThan(first, later)
    }
}
