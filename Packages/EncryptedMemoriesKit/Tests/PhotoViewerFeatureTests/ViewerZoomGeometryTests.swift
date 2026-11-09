import CoreGraphics
import XCTest

@testable import PhotoViewerCore

final class ViewerZoomGeometryTests: XCTestCase {
    private func assertSize(
        _ actual: CGSize, equals expected: CGSize, accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    func testAspectFitSupportsPortraitLandscapeAndSquareMedia() {
        assertSize(
            ViewerZoomGeometry.aspectFitSize(
                mediaSize: CGSize(width: 1080, height: 1920), viewportSize: CGSize(width: 390, height: 844)),
            equals: CGSize(width: 390, height: 693.3333333333334)
        )
        assertSize(
            ViewerZoomGeometry.aspectFitSize(
                mediaSize: CGSize(width: 1920, height: 1080),
                viewportSize: CGSize(width: 390, height: 844)),
            equals: CGSize(width: 390, height: 219.375)
        )
        assertSize(
            ViewerZoomGeometry.aspectFitSize(
                mediaSize: CGSize(width: 1000, height: 1000),
                viewportSize: CGSize(width: 390, height: 844)),
            equals: CGSize(width: 390, height: 390)
        )
    }

    func testCenteredInsetsCoverBothAxes() {
        let fit = ViewerZoomGeometry.aspectFitSize(
            mediaSize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 390, height: 844)
        )
        XCTAssertEqual(fit.width, 390, accuracy: 0.0001)

        let centered = ViewerZoomGeometry.centeredInsets(
            contentSize: fit, viewportSize: CGSize(width: 390, height: 844))
        XCTAssertEqual(centered.left, 0, accuracy: 0.0001)
        XCTAssertEqual(centered.right, 0, accuracy: 0.0001)
        XCTAssertEqual(centered.top, (844 - fit.height) / 2, accuracy: 0.0001)
        XCTAssertEqual(centered.bottom, centered.top, accuracy: 0.0001)
    }

    func testSettledOriginCentersSmallAxesAndClampsLargeAxes() {
        let viewport = CGSize(width: 390, height: 844)
        let content = CGSize(width: 1560, height: 877.5)
        let low = ViewerZoomGeometry.settledOrigin(
            proposedOrigin: CGPoint(x: -500, y: -500), contentSize: content, viewportSize: viewport)
        XCTAssertEqual(low.x, 0, accuracy: 0.0001)
        XCTAssertEqual(low.y, 0, accuracy: 0.0001)

        let high = ViewerZoomGeometry.settledOrigin(
            proposedOrigin: CGPoint(x: 2500, y: 1000), contentSize: content, viewportSize: viewport)
        XCTAssertEqual(high.x, content.width - viewport.width, accuracy: 0.0001)
        XCTAssertEqual(high.y, content.height - viewport.height, accuracy: 0.0001)

        let middle = ViewerZoomGeometry.settledOrigin(
            proposedOrigin: CGPoint(x: 400, y: 300), contentSize: content, viewportSize: viewport)
        XCTAssertEqual(middle.x, 400, accuracy: 0.0001)
        XCTAssertEqual(middle.y, content.height - viewport.height, accuracy: 0.0001)

        let smaller = CGSize(width: 200, height: 400)
        let centered = ViewerZoomGeometry.settledOrigin(
            proposedOrigin: CGPoint(x: 999, y: -999), contentSize: smaller, viewportSize: viewport)
        XCTAssertEqual(centered.x, (smaller.width - viewport.width) / 2, accuracy: 0.0001)
        XCTAssertEqual(centered.y, (smaller.height - viewport.height) / 2, accuracy: 0.0001)
    }

    func testVisibleAnchorRebasesAcrossRotationWithoutTransferringRawOffset() {
        let media = CGSize(width: 1600, height: 1200)
        let zoom: CGFloat = 4
        let oldViewport = CGSize(width: 390, height: 844)
        let oldFit = ViewerZoomGeometry.aspectFitSize(mediaSize: media, viewportSize: oldViewport)
        let oldContent = CGSize(width: oldFit.width * zoom, height: oldFit.height * zoom)
        let oldOrigin = CGPoint(x: 700, y: 160)
        let anchor = ViewerZoomGeometry.normalizedVisibleAnchor(
            contentOrigin: oldOrigin, contentSize: oldContent, viewportSize: oldViewport)

        let newViewport = CGSize(width: 844, height: 390)
        let newFit = ViewerZoomGeometry.aspectFitSize(mediaSize: media, viewportSize: newViewport)
        let newContent = CGSize(width: newFit.width * zoom, height: newFit.height * zoom)
        let rebased = ViewerZoomGeometry.rebasedOrigin(
            anchor: anchor, contentSize: newContent, viewportSize: newViewport)

        XCTAssertNotEqual(newFit, oldFit, "rotation must exercise a real aspect-fit content-size change")
        XCTAssertNotEqual(rebased, oldOrigin)
        XCTAssertEqual(
            (rebased.x + newViewport.width / 2) / newContent.width,
            anchor.x,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (rebased.y + newViewport.height / 2) / newContent.height,
            anchor.y,
            accuracy: 0.0001
        )
    }

    func testVideoZoomDetectionRequiresCurrentMediaToExceedFit() {
        let fit = CGRect(x: 0, y: 100, width: 390, height: 219.375)
        XCTAssertFalse(ViewerZoomGeometry.isZoomed(currentRect: fit, fitRect: fit))
        XCTAssertFalse(
            ViewerZoomGeometry.isZoomed(
                currentRect: CGRect(x: -0.5, y: 100, width: 391, height: 219.375), fitRect: fit))
        XCTAssertTrue(
            ViewerZoomGeometry.isZoomed(
                currentRect: CGRect(x: -195, y: 0, width: 780, height: 438.75), fitRect: fit))
    }

    func testInvalidAndNonFiniteInputReturnsSafeDefaults() {
        XCTAssertEqual(
            ViewerZoomGeometry.aspectFitSize(mediaSize: .zero, viewportSize: CGSize(width: 10, height: 10)), .zero)
        XCTAssertEqual(
            ViewerZoomGeometry.aspectFitSize(
                mediaSize: CGSize(width: CGFloat.infinity, height: 1), viewportSize: CGSize(width: 10, height: 10)),
            .zero)
        let invalidOrigin = ViewerZoomGeometry.settledOrigin(
            proposedOrigin: CGPoint(x: CGFloat.infinity, y: 0), contentSize: CGSize(width: 20, height: 20),
            viewportSize: CGSize(width: 10, height: 10))
        XCTAssertEqual(invalidOrigin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(invalidOrigin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(
            ViewerZoomGeometry.centeredInsets(
                contentSize: CGSize(width: CGFloat.nan, height: 1), viewportSize: CGSize(width: 10, height: 10)
            ).top,
            0)
    }
}
