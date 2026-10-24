import XCTest

/// Empty Recently Deleted on the offline fixture account, which has no open duplicate merge.
final class MobileEmptyTrashUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-EncryptedMemoriesUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testEmptyRecentlyDeletedWithoutAnOpenMergeEmptiesTheList() {
        // The iOS 26 and 27 tab bars do not always expose a tab bar element; the tab is a button in both.
        let collections = app.buttons["Collections"].firstMatch
        XCTAssertTrue(collections.waitForExistence(timeout: 60))
        collections.tap()
        let recentlyDeleted = app.buttons["Recently Deleted"].firstMatch
        for _ in 0..<4 where !recentlyDeleted.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(recentlyDeleted.waitForExistence(timeout: 10))
        recentlyDeleted.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 20), "Recently Deleted lists the fixture photos")

        let more = app.buttons["More album actions"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let empty = app.buttons["Empty Recently Deleted"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        empty.tap()
        let confirm = app.alerts.buttons["Delete Permanently"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: firstPhoto)], timeout: 20), .completed,
            "Recently Deleted is empty")
        XCTAssertFalse(
            app.alerts["Couldn’t Empty Recently Deleted"].exists, "no merge is open, so emptying succeeds")
    }

    private var firstPhoto: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }
}
