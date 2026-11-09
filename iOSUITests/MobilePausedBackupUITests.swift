import XCTest

final class MobilePausedBackupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesPausedBackupFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    private func tile(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testAWaitingPhotoSaysThatTheBackupIsPausedUntilItResumes() {
        let paused = tile(labelContaining: ", Backup paused")
        XCTAssertTrue(paused.waitForExistence(timeout: 60), "the waiting photo does not say that the backup is paused")
        // "Photo, <date>" names the same tile after the resume.
        let photo = String(paused.label.dropLast(", Backup paused".count))

        app.buttons["Proton Account and Settings"].tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let resume = app.buttons["backup.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "the paused backup offers no resume")
        resume.tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: resume)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed)
        app.backButton(to: "Settings").tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", photo)).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the waiting photo left the grid")
        XCTAssertFalse(tile(labelContaining: "Backup paused").exists, "the photo still says that the backup is paused")
    }

    func testCellularDataSwitchIsOffByDefaultAndCanBeTurnedOn() {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()

        let cellular = app.switches["backup.useMobileData"]
        XCTAssertTrue(cellular.waitForExistence(timeout: 10), "the backup settings offer no cellular data switch")
        XCTAssertTrue(
            app.buttons["backup.excludedPhotos"].exists, "the empty excluded list remains available")
        XCTAssertEqual(cellular.label, "Use Cellular Data")
        XCTAssertEqual(cellular.value as? String, "0", "the backup waits for Wi-Fi by default")
        cellular.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: cellular, "value == '1'"), "the switch does not turn on")
        cellular.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: cellular, "value == '0'"))
    }

    func testExcludedPhotosStandImmediatelyBeforeCellularDataAndBeforeTurningBackupOff() throws {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()

        XCTAssertTrue(app.buttons["backup.excludedPhotos"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["backup.useMobileData"].exists)
        XCTAssertTrue(app.buttons["Turn off Photos backup"].exists)
        let cells = app.cells.allElementsBoundByIndex
        let excluded = try XCTUnwrap(cells.firstIndex { $0.buttons["backup.excludedPhotos"].exists })
        let cellular = try XCTUnwrap(cells.firstIndex { $0.switches["backup.useMobileData"].exists })
        let turnOff = try XCTUnwrap(cells.firstIndex { $0.buttons["Turn off Photos backup"].exists })
        let excludedFooter = try XCTUnwrap(
            cells.firstIndex {
                $0.staticTexts["Photos you deleted before they were backed up."].exists
            })
        XCTAssertEqual(excluded + 1, excludedFooter, "the excluded group footer must follow its row")
        XCTAssertEqual(excludedFooter + 1, cellular, "Cellular Data must follow the excluded group footer")
        XCTAssertLessThan(excluded, turnOff, "the excluded list must stand before Turn off Photos backup")

        let footer = app.staticTexts["Photos you deleted before they were backed up."]
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "the excluded group needs its own footer")
        let cellularFooter = try XCTUnwrap(
            cells.firstIndex {
                $0.staticTexts["Applies to backups, also on Personal Hotspot. Viewing photos is not affected."].exists
            })
        let display = try XCTUnwrap(
            cells.firstIndex {
                $0.staticTexts["Keep display on during active backup"].exists
            })
        XCTAssertLessThan(cellular, cellularFooter)
        XCTAssertLessThan(cellularFooter, display)
        XCTAssertLessThan(display, turnOff)
    }

    func testExcludedPhotosAreAvailableWhenEmptyAndHiddenWithBackupOff() {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()

        let entry = app.buttons["backup.excludedPhotos"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the empty excluded list must remain available")
        XCTAssertEqual(entry.label, "Excluded from Backup", "zero must not appear as a count")
        entry.tap()
        XCTAssertTrue(app.staticTexts["No excluded photos"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Photos you delete before they are backed up appear here."].exists)
        app.backButton(to: "Backup").tap()

        let disable = app.buttons["Turn off Photos backup"]
        app.swipeUp()
        XCTAssertTrue(disable.waitForExistence(timeout: 5))
        disable.tap()
        XCTAssertTrue(app.buttons["Enable Photos backup…"].waitForExistence(timeout: 10), "backup must be off")
        XCTAssertFalse(entry.exists, "the excluded list must be hidden while photo backup is off")
        XCTAssertFalse(app.staticTexts["Photos you deleted before they were backed up."].exists)
        XCTAssertFalse(app.switches["backup.useMobileData"].exists)
    }

    func testExcludedPhotosRemainAvailableWithDeniedPhotosAccess() {
        app.terminate()
        // This existing fixture installs an enabled controller whose Photos access is denied.
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDeletedBackupFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let entry = app.buttons["backup.excludedPhotos"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertEqual(entry.label, "Excluded from Backup")
        entry.tap()
        XCTAssertTrue(app.staticTexts["No excluded photos"].waitForExistence(timeout: 10))
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
