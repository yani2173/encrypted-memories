import XCTest

/// Restore All on the Album Sync problem list: consent with the count, Cancel, and an honest result.
final class MobileBulkRestoreUITests: XCTestCase {
    func testRestoreAllConfirmsTheCountAndKeepsAPhotoItCannotRestore() throws {
        try assertRestoreAll(
            language: "en",
            texts: .init(
                settings: "Proton Account and Settings", action: "Restore All (1)", title: "Restore 1 photo?",
                cancel: "Cancel", result: "0 of 1 photo restored. 1 unchanged.",
                detail: "Album sync adds restored photos to the album."))
    }

    func testGermanRestoreAllConfirmsTheCountAndKeepsAPhotoItCannotRestore() throws {
        try assertRestoreAll(
            language: "de",
            texts: .init(
                settings: "Proton-Konto und Einstellungen", action: "Alle wiederherstellen (1)",
                title: "1 Foto wiederherstellen?", cancel: "Abbrechen",
                result: "0 von 1 Foto wiederhergestellt. 1 unverändert.",
                detail: "Die Album-Synchronisierung fügt wiederhergestellte Fotos zum Album hinzu."))
    }

    private struct Texts {
        let settings, action, title, cancel, result, detail: String
    }

    private func assertRestoreAll(language: String, texts: Texts) throws {
        continueAfterFailure = false
        let app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesAlbumSyncReasonsFixture",
            "-EncryptedMemoriesAlbumSyncRestoreFixture", "-EncryptedMemoriesAlbumSyncBulkRestoreFixture",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US",
        ]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons[texts.settings]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let albumSync = app.buttons["albumsync.settings"]
        XCTAssertTrue(albumSync.waitForExistence(timeout: 10))
        albumSync.tap()
        let status = app.buttons["albumsync.notInAlbum.fixture-album-sync"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.tap()

        let photo = app.buttons["backup.failedItem.trashed fixture.heic"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        let bulk = app.buttons["backup.bulk.backUpAgain"]
        XCTAssertTrue(bulk.waitForExistence(timeout: 10))
        XCTAssertTrue(bulk.isEnabled)
        XCTAssertEqual(bulk.label, texts.action)
        bulk.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        XCTAssertTrue(app.alerts.staticTexts[texts.title].exists)
        app.alerts.buttons[texts.cancel].tap()
        XCTAssertTrue(bulk.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        XCTAssertTrue(photo.exists, "Cancel leaves the row unchanged")

        bulk.tap()
        let confirm = app.alerts.buttons["backup.bulk.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        try app.tapDialogButton("backup.bulk.confirm")
        let result = app.staticTexts["backup.bulk.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, texts.result, "A photo that stays deleted is never reported as restored")
        XCTAssertTrue(app.staticTexts[texts.detail].exists)
        XCTAssertTrue(photo.exists, "The photo that could not be restored keeps its row")
        app.buttons["backup.bulk.dismissResult"].tap()
        XCTAssertTrue(bulk.waitForExistence(timeout: XCUIApplication.dialogWaitTimeout))
        XCTAssertFalse(result.exists)
    }
}
