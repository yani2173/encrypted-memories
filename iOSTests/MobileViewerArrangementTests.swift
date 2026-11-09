import PhotoViewerCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// The viewer arrangement keeps today's layout while the display is whole: the lower part spans the bottom of the
/// safe area, the media ends where it starts, without the lower part the media fills the area, and the whole display
/// never counts as the folded layout. iOS 27.1 lays both parts out with an overlay arrangement view, earlier systems
/// with a bottom safe-area inset; on each system the same expectations hold.
final class MobileViewerArrangementTests: XCTestCase {
    @MainActor func testTheLowerPartShortensTheMediaWhileTheDisplayIsWhole() async throws {
        let shown = try await layout(showsLowerPart: true)
        let safe = shown.window.inset(by: shown.safeArea)
        XCTAssertEqual(shown.lowerPart.minX, safe.minX, accuracy: 1)
        XCTAssertEqual(shown.lowerPart.width, safe.width, accuracy: 1)
        XCTAssertEqual(shown.lowerPart.maxY, safe.maxY, accuracy: 1, "The lower part sits on the safe-area bottom")
        XCTAssertEqual(shown.media.maxY, shown.lowerPart.minY, accuracy: 1, "The media ends above the lower part")
        XCTAssertFalse(shown.isSideBySide, "The whole display is not the folded layout")

        let hidden = try await layout(showsLowerPart: false)
        XCTAssertEqual(hidden.media.maxY, safe.maxY, accuracy: 1, "Without the lower part the media fills the area")
        XCTAssertFalse(hidden.isSideBySide, "The whole display is not the folded layout")
    }

    @MainActor private func layout(
        showsLowerPart: Bool
    ) async throws -> (window: CGRect, safeArea: UIEdgeInsets, media: CGRect, lowerPart: CGRect, isSideBySide: Bool) {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let frames = ArrangementFrames()
        let height = ViewerChromeLayoutProfile.regular.stackedLowerPartHeight
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(
            rootView: MobileViewerArrangement(
                showsLowerPart: showsLowerPart,
                stackedLowerPartHeight: height,
                isSideBySide: Binding(get: { frames.isSideBySide }, set: { frames.isSideBySide = $0 })
            ) {
                Color.red.onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames.media = $0
                }
            } lowerPart: {
                Color.blue.frame(height: height)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        frames.lowerPart = $0
                    }
            } notice: {
                EmptyView()
            })
        window.isHidden = false
        defer { window.isHidden = true }
        // Measure once two layout passes report the same frames.
        var previous: (CGRect, CGRect) = (.null, .null)
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    window.layoutIfNeeded()
                    let current = (frames.media, frames.lowerPart)
                    defer { previous = current }
                    let hasLowerPart = !showsLowerPart || !current.1.isNull
                    return !current.0.isNull && hasLowerPart && current == previous
                }
            }, object: nil)
        await fulfillment(of: [settled], timeout: 10)
        return (window.bounds, window.safeAreaInsets, frames.media, frames.lowerPart, frames.isSideBySide)
    }
}

@MainActor private final class ArrangementFrames {
    var media = CGRect.null
    var lowerPart = CGRect.null
    var isSideBySide = false
}
