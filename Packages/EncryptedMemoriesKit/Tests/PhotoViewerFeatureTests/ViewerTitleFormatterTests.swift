import XCTest

@testable import PhotoViewerCore
@testable import PhotoViewerFeature

final class ViewerTitleFormatterTests: XCTestCase {
    private let german = Locale(identifier: "de_DE")
    private let english = Locale(identifier: "en_US")

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testPositionStringGermanGroupingAndConnector() {
        let s = ViewerTitleFormatter.positionString(index: 4453, total: 35666, locale: german)
        XCTAssertEqual(s, "4.454 von 35.666")  // 1-based index, German grouping + "von"
    }

    func testPositionStringEnglishConnector() {
        let s = ViewerTitleFormatter.positionString(index: 0, total: 22884, locale: english)
        XCTAssertEqual(s, "1 of 22,884")
    }

    func testDateTimeIsGermanWithUmConnector() {
        let title = ViewerTitleFormatter.make(
            captureDate: date("2026-06-17T16:53:58Z"),
            index: 22856, total: 22884, locale: german
        )
        XCTAssertTrue(title.line1.contains("2026"), title.line1)
        XCTAssertTrue(title.line1.contains(" um "), title.line1)
        XCTAssertEqual(title.line2, "22.857 von 22.884")
    }

    func testLocationGoesOnLineOneWithDateAndPositionBelow() {
        let title = ViewerTitleFormatter.make(
            captureDate: date("2026-06-06T13:45:00Z"),
            index: 4453, total: 35666, locationName: "Maria Laach am Jauerling", locale: german
        )
        XCTAssertEqual(title.line1, "Maria Laach am Jauerling")
        XCTAssertTrue(title.line2.contains("·"), title.line2)
        XCTAssertTrue(title.line2.contains("4.454 von 35.666"), title.line2)
    }

    func testWhitespaceOnlyLocationNameCountsAsNoName() {
        let names = ["", " ", "\t", "\n", "\u{00A0}", "\u{3000}", " \t\n\u{00A0}\u{3000} "]
        let withoutName = ViewerTitleFormatter.make(
            captureDate: date("2026-06-06T13:45:00Z"), index: 2, total: 10, locale: german)
        for name in names {
            let title = ViewerTitleFormatter.make(
                captureDate: date("2026-06-06T13:45:00Z"), index: 2, total: 10, locationName: name, locale: german)
            XCTAssertEqual(title, withoutName, "name \(name.unicodeScalars.map { $0.value })")
            let resolving = ViewerTitleFormatter.make(
                captureDate: date("2026-06-06T13:45:00Z"), index: 2, total: 10, locationName: name,
                locationIsResolving: true, locale: german)
            XCTAssertTrue(resolving.reservesLocationLine, "a blank name must not end the reserved headline")
        }
    }

    func testLocationNameWithTextIsShownExactlyAsGiven() {
        let title = ViewerTitleFormatter.make(
            captureDate: date("2026-06-06T13:45:00Z"), index: 2, total: 10, locationName: "  Wien\u{00A0}\n",
            locale: german)
        XCTAssertEqual(title.line1, "  Wien\u{00A0}\n")
        XCTAssertFalse(title.reservesLocationLine)
        XCTAssertNil(PlaceNameText.displayable(nil))
        XCTAssertEqual(PlaceNameText.displayable(" x "), " x ")
    }

    func testResolvingLocationReservesHeadlineAndKeepsDateOnSecondLine() {
        let title = ViewerTitleFormatter.make(
            captureDate: date("2026-06-06T13:45:00Z"),
            index: 2,
            total: 10,
            locationIsResolving: true,
            locale: german
        )

        XCTAssertTrue(title.reservesLocationLine)
        XCTAssertEqual(title.line1, " ")
        XCTAssertTrue(title.line2.contains("2026"), title.line2)
        XCTAssertTrue(title.line2.contains("3 von 10"), title.line2)
    }

    func testFilenameFallbackWhenNoDate() {
        let title = ViewerTitleFormatter.make(
            captureDate: nil, index: 0, total: 10, filename: "IMG_0001.jpg", locale: english
        )
        XCTAssertEqual(title.line1, "IMG_0001.jpg")
        XCTAssertEqual(title.line2, "1 of 10")
    }

    func testFallbackTitleIsLocalizedWhenNoDateOrFilename() {
        // The date-less/filename-less fallback now respects the locale: "Photo" (en) / "Foto" (de).
        let en = ViewerTitleFormatter.make(captureDate: nil, index: 0, total: 10, locale: english)
        XCTAssertEqual(en.line1, "Photo")
        let de = ViewerTitleFormatter.make(captureDate: nil, index: 0, total: 10, locale: german)
        XCTAssertEqual(de.line1, "Foto")
    }
}
