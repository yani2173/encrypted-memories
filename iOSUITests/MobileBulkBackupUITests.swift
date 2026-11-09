import XCTest

final class MobileBulkBackupUITests: XCTestCase {
    /// One short native journey covers new consent, cancellation, unchanged result and acknowledgement actions.
    func testBulkBackUpAgainConfirmsTheFullCountAndKeepsAnUnavailablePhoto() throws {
        continueAfterFailure = false
        let app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDeletedBackupFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        app.buttons["backup.settings"].tap()
        let attention = app.buttons["backup.failedItems"]
        XCTAssertTrue(attention.waitForExistence(timeout: 10))
        attention.tap()
        let bulk = app.buttons["backup.bulk.backUpAgain"]
        XCTAssertTrue(bulk.waitForExistence(timeout: 10))
        XCTAssertTrue(bulk.isEnabled)
        XCTAssertEqual(bulk.label, "Back Up Again (1)")
        bulk.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        XCTAssertTrue(app.alerts.staticTexts["Back up 1 photo again?"].exists)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(bulk.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        bulk.tap()
        let confirm = app.alerts.buttons["backup.bulk.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        try app.tapDialogButton("backup.bulk.confirm")
        let result = app.staticTexts["backup.bulk.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "0 of 1 photo queued for backup. 1 unchanged.")
        XCTAssertTrue(app.buttons["backup.failedItem.Deleted fixture.heic"].firstMatch.exists)
        app.buttons["backup.bulk.dismissResult"].tap()
        XCTAssertTrue(bulk.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        XCTAssertFalse(result.exists)
    }
}
