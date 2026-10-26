import XCTest

/// Taps through On This Day on the offline fixture account. The fixture adds two photos from today one year ago and
/// one from two years ago.
final class MobileOnThisDayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-EncryptedMemoriesOnThisDayFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testTheMemoriesOfThisDayOpenBrowseAndShowTheirPhotoInTheLibrary() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "the library grid shows no photo")
        let toggle = app.buttons["library.memories.toggle"]
        XCTAssertTrue(wait(for: toggle, "isEnabled == true", timeout: 10), "the calendar control stays disabled")
        toggle.tap()

        let lastYear = app.buttons["library.memories.card.1"]
        XCTAssertTrue(lastYear.waitForExistence(timeout: 10), "the area shows no stack for one year ago")
        XCTAssertTrue(app.buttons["library.memories.card.2"].exists, "the area shows no stack for two years ago")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '1 year ago'")).firstMatch
                .exists, "the stack names no year")
        let position = app.staticTexts["library.memories.position.1"]
        XCTAssertEqual(position.label, "1 of 2")

        // Browsing a stack changes only its card.
        app.buttons["library.memories.next.1"].tap()
        XCTAssertTrue(wait(for: position, "label == '2 of 2'"), "the next card did not come on top")
        XCTAssertFalse(app.buttons["library.memories.next.1"].isEnabled, "browsing must not wrap around")
        XCTAssertEqual(app.staticTexts["library.memories.position.2"].label, "1 of 1")

        // The card opens in the viewer; closing it returns to the same card.
        lastYear.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        close.tap()
        XCTAssertTrue(wait(for: position, "label == '2 of 2'", timeout: 10), "the stack lost its card")

        // Show in Library closes the area and reveals the photo in the ordinary library.
        app.buttons["library.memories.showInLibrary.1"].tap()
        XCTAssertTrue(wait(for: lastYear, "exists == false", timeout: 10), "the area stayed open")
        let year = Calendar(identifier: .gregorian).component(
            .year, from: Calendar.current.date(byAdding: .year, value: -1, to: Date())!)
        let revealed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Photo, ' AND label CONTAINS %@", String(year))
        ).firstMatch
        XCTAssertTrue(revealed.waitForExistence(timeout: 10), "the photo from one year ago is not in view")
        XCTAssertTrue(revealed.isHittable, "the revealed photo is covered")
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Grid photos are accessibility elements named "Photo, <date>".
    private var firstPhoto: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }
}
