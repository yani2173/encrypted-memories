import XCTest

final class MobileExcludedBackupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        // The fixture backs up with access to Photos. An earlier test can leave that access unanswered; the system then
        // asks during this test, and the person allows it. A denial hides the settings of an enabled backup.
        app.resetAuthorizationStatus(for: .photos)
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow Full Access", "Vollen Zugriff erlauben"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesPausedBackupFixture",
            "-EncryptedMemoriesExcludedBackupFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The excluded photos live one level below the Backup settings. After the last one went back into the backup,
    /// the list stays open with its empty state, and the entry stays on the Backup settings.
    func testTheLastPhotoThatGoesBackIntoTheBackupLeavesTheListOpenAndEmpty() {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()

        let entry = app.buttons["backup.excludedPhotos"]
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "the Backup settings offer no excluded photos")
        XCTAssertTrue(entry.label.contains("1"), "one photo is excluded: \(entry.label)")
        XCTAssertFalse(app.buttons["Back Up Again"].exists, "the list is no longer on the Backup settings")
        entry.tap()

        let include = app.buttons["Back Up Again"]
        XCTAssertTrue(include.waitForExistence(timeout: 10), "the list shows no excluded photo")
        include.tap()
        XCTAssertTrue(
            app.staticTexts["No excluded photos"].waitForExistence(timeout: 10), "the list shows no empty state")
        XCTAssertTrue(app.navigationBars["Excluded from Backup"].exists, "the list closed after the last photo")

        app.backButton(to: "Backup").tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the entry left the open Backup settings")
        XCTAssertEqual(entry.label, "Excluded from Backup", "zero must not appear as a count")
    }
}
