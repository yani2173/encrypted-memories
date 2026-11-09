import GridCore
import UIKit
import XCTest

@testable import TimelineUIKitFeature

/// The UIKit grid host hands the display's active reserved regions to the shared layout policy. The iPhone Duo
/// simulator starts closed, where the outer camera occludes the display; the fold needs the partly open pose.
final class MobileGridReservedRegionTests: XCTestCase {
    @MainActor func testGridHostReadsTheActiveReservedRegionsOfItsWindow() throws {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
            guard #available(iOS 27.1, *) else { throw XCTSkip("Reserved regions need iOS 27.1") }
            let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let host = UIKitTimelineGridHostView(frame: window.bounds)
            window.addSubview(host)
            window.isHidden = false
            defer { window.isHidden = true }
            host.layoutIfNeeded()

            let reported = [UIView.ReservedRegion.Kind.division, .occlusion].flatMap { kind in
                host.reservedRegions(kind: kind).filter { $0.isActive && !$0.frame.isEmpty }.map(\.frame)
            }
            try XCTSkipIf(reported.isEmpty, "This display reports no active reserved region")
            let exclusions = host.reservedRegionLayout.exclusions
            XCTAssertEqual(exclusions.count, reported.count)
            for frame in reported {
                XCTAssertTrue(exclusions.contains(frame), "The grid misses the reserved region \(frame)")
            }
            // A moved mark stays out of the bars: the visible part excludes the scroll view's content insets.
            let insets = host.scrollView.adjustedContentInset
            XCTAssertGreaterThan(insets.top, 0, "The status bar insets the grid")
            XCTAssertEqual(host.reservedRegionLayout.bounds, host.bounds.inset(by: insets))
        #else
            throw XCTSkip("The SDK has no reserved regions")
        #endif
    }
}
