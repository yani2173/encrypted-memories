import XCTest

/// An album row with photos outside the Proton album opens the shared problem list with one reason per photo.
final class MobileAlbumSyncReasonsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() { app.terminate() }

    private func openAlbumSync(language: String = "en", restoreFixture: Bool = false) {
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesAlbumSyncReasonsFixture",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US",
        ]
        if restoreFixture { app.launchArguments.append("-EncryptedMemoriesAlbumSyncRestoreFixture") }
        app.launch()
        let settings = app.buttons[language == "de" ? "Proton-Konto und Einstellungen" : "Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let albumSync = app.buttons["albumsync.settings"]
        XCTAssertTrue(albumSync.waitForExistence(timeout: 10))
        albumSync.tap()
    }

    private func row(_ filename: String) -> XCUIElement {
        app.descendants(matching: .any)["backup.failedItem.\(filename)"].firstMatch
    }

    func testAlbumRowOpensPhotoReasonsWithoutTryAgain() {
        openAlbumSync()
        let status = app.buttons["albumsync.notInAlbum.fixture-album-sync"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("2 photos not in the album"))
        status.tap()

        XCTAssertTrue(app.navigationBars["Photos not in the album"].waitForExistence(timeout: 5))
        let attach = row("attach fixture.heic")
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        XCTAssertTrue(attach.label.contains("Could not be added to the Proton album."))
        XCTAssertTrue(row("network fixture.heic").label.contains("Connection interrupted."))
        // Sync now on the album row is the retry; the sheet offers none.
        XCTAssertFalse(app.buttons["backup.retryUserResolvable.sheet"].exists)
    }

    func testGermanAlbumRowAndReasons() {
        openAlbumSync(language: "de")
        let status = app.buttons["albumsync.notInAlbum.fixture-album-sync"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("2 Fotos nicht im Album"))
        status.tap()

        XCTAssertTrue(app.navigationBars["Fotos nicht im Album"].waitForExistence(timeout: 5))
        let attach = row("attach fixture.heic")
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        XCTAssertTrue(attach.label.contains("Konnte nicht zum Proton-Album hinzugefügt werden."))
    }

    func testDeletedAlbumPhotoOffersRestoreAndRetainsTheRowWhenUnavailable() throws {
        try assertRestoreAction(language: "en")
    }

    func testGermanDeletedAlbumPhotoOffersRestoreAndRetainsTheRowWhenUnavailable() throws {
        try assertRestoreAction(language: "de")
    }

    private func assertRestoreAction(language: String) throws {
        openAlbumSync(language: language, restoreFixture: true)
        let status = app.buttons["albumsync.notInAlbum.fixture-album-sync"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.tap()
        let photo = row("trashed fixture.heic")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let reason = language == "de" ? "Übersprungen: in Proton Drive gelöscht" : "Skipped: deleted in Proton Drive"
        XCTAssertTrue(photo.label.contains(reason))
        photo.tap()
        let restore = app.buttons["albumsync.restore.dialog"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "The deleted photo must offer the Restore action")
        let action = try app.hittableDialogButton("albumsync.restore.dialog")
        XCTAssertEqual(action.label, language == "de" ? "Wiederherstellen" : "Restore")
        XCTAssertFalse(app.buttons["backup.backUpAgain.dialog"].exists)
        try app.tapDialogButton("albumsync.restore.dialog")
        let error = app.staticTexts["albumsync.restoreError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(
            error.label, language == "de" ? "Wiederherstellen nicht möglich." : "Couldn't restore this photo.")
        XCTAssertTrue(photo.exists, "An unavailable restore must retain the problem row")
        XCTAssertTrue(photo.label.contains(reason))
        XCTAssertFalse(app.buttons["backup.backUpAgain.dialog"].exists)
    }
}
