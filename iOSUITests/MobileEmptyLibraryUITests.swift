import XCTest

@MainActor
final class MobileEmptyLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    /// The backup sheet of the "empty" scenario reads the real Photos access of the simulator. A denied state that an
    /// earlier run left behind hides the enable button, so the test that needs it starts from an unanswered state.
    private func launch(_ scenario: String, resetPhotosAccess: Bool = false) {
        app = UITestApplication.make()
        if resetPhotosAccess { app.resetAuthorizationStatus(for: .photos) }
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesLibraryLoadFixture", scenario,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-EncryptedMemoriesDarkAppearance",
        ]
        app.launch()
    }

    func testCompletelyEmptyLibraryOpensBackupSettings() {
        launch("empty", resetPhotosAccess: true)
        XCTAssertTrue(app.staticTexts["No photos yet"].waitForExistence(timeout: 60))
        let backup = app.buttons["library.empty.backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 20))
        attachScreen("Empty library")
        backup.tap()
        XCTAssertTrue(app.buttons["Enable Photos backup…"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Done"].exists)
        attachScreen("Backup settings from the empty library")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No photos yet"].waitForExistence(timeout: 20))
    }

    func testEnabledBackupOffersNoSecondNextStep() {
        launch("backup-on")
        XCTAssertTrue(app.staticTexts["No photos yet"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["library.empty.backup"].exists)
    }

    func testUnavailableBackupOffersNoNextStep() {
        launch("unavailable")
        XCTAssertTrue(app.staticTexts["No photos yet"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["library.empty.backup"].exists)
    }

    func testMissingFirstPageShowsLoadingInsteadOfEmpty() {
        launch("pending")
        assertLoadingWithoutEmpty()
        attachScreen("First page pending")
    }

    func testFirstSignInShowsLoadingUntilPhotosArrive() {
        launch("later")
        assertLoadingWithoutEmpty()
        let photo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts["No photos yet"].exists)
        attachScreen("First sign-in after known photos arrive")
    }

    func testOfflineStartShowsOfflineInsteadOfEmpty() {
        launch("offline")
        XCTAssertTrue(app.staticTexts["Offline"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts["No photos yet"].exists)
        attachScreen("Offline first load")
    }

    func testFailedFirstLoadShowsFailureInsteadOfEmpty() {
        launch("failed")
        assertFailedWithoutEmpty()
    }

    func testFailedValidationOfEmptyCacheShowsFailureInsteadOfEmpty() {
        launch("cached-empty-failed")
        assertFailedWithoutEmpty()
    }

    private func assertLoadingWithoutEmpty() {
        // The shared loading cover exposes its localized label, rather than a container identifier.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Loading your library…'")).firstMatch
                .waitForExistence(timeout: 60)
        )
        XCTAssertFalse(app.staticTexts["No photos yet"].exists)
        XCTAssertFalse(app.buttons["library.empty.backup"].exists)
    }

    private func assertFailedWithoutEmpty() {
        XCTAssertTrue(app.staticTexts["Couldn’t load your library"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Fixture first load failed"].exists)
        XCTAssertFalse(app.staticTexts["No photos yet"].exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
        attachScreen("Failed first load")
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
