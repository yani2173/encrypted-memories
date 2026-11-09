import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// The album chips of the folded details sit in a horizontal scroll view, which offers no width. A long album title
/// must still truncate at the chip's maximum width instead of widening the chip.
final class MobileViewerAlbumChipTests: XCTestCase {
    private let longTitle = String(repeating: "A very long album title ", count: 8)

    @MainActor private func width(of view: some View) -> CGFloat {
        // A horizontal scroll view proposes no width to its row; an unbounded fitting size models that offer.
        let host = UIHostingController(rootView: view)
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return host.sizeThatFits(in: unbounded).width
    }

    @MainActor func testALongTitleTruncatesAtTheMaximumWidth() {
        let capped = width(of: Text(longTitle).lineLimit(1).modifier(CappedWidth(maximum: 240)))
        XCTAssertLessThanOrEqual(capped, 240.5, "The chip label must not grow beyond its maximum")
        XCTAssertGreaterThan(capped, 200, "The capped label still uses the room it has")
    }

    @MainActor func testAShortTitleKeepsItsOwnWidth() {
        let ownWidth = width(of: Text("Lakes").lineLimit(1))
        let capped = width(of: Text("Lakes").lineLimit(1).modifier(CappedWidth(maximum: 240)))
        XCTAssertEqual(capped, ownWidth, accuracy: 0.5)
        XCTAssertLessThan(capped, 240)
    }

    @MainActor func testAccessibilitySizesKeepTheFullTitle() {
        // Without a maximum (the vertical list at accessibility sizes) the modifier adds no cap.
        let uncapped = width(of: Text(longTitle).lineLimit(1).modifier(CappedWidth(maximum: nil)))
        XCTAssertGreaterThan(uncapped, 240)
    }
}
