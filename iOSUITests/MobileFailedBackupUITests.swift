import XCTest

final class MobileFailedBackupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() { app.terminate() }

    private func openSheet(mode: String? = nil, language: String = "en") {
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesFailedBackupFixture",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US",
        ]
        if let mode { app.launchArguments.append(mode) }
        app.launch()
        let settings = app.buttons[language == "de" ? "Proton-Konto und Einstellungen" : "Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let attention = app.buttons["backup.failedItems"]
        let waiting = app.buttons["backup.waitingItems"]
        let details = attention.waitForExistence(timeout: 5) ? attention : waiting
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        XCTAssertTrue(
            section("continuesByItself").waitForExistence(timeout: 5)
                || section("actionNeeded").waitForExistence(timeout: 5))
    }

    private func section(_ name: String) -> XCUIElement {
        app.staticTexts["backup.issueSection.\(name)"]
    }

    private func row(_ filename: String) -> XCUIElement {
        app.staticTexts["backup.failedItem.\(filename)"]
    }

    /// A row that offers a decision carries the button trait.
    private func decisionRow(_ filename: String) -> XCUIElement {
        app.buttons["backup.failedItem.\(filename)"]
    }

    func testThreeSectionsShowReasonsAndPermanentDismissal() {
        openSheet()
        XCTAssertEqual(section("actionNeeded").label, "Action needed")
        XCTAssertTrue(row("accountStorage fixture.heic").exists)
        XCTAssertTrue(decisionRow("deletedElsewhere fixture.heic").exists)
        XCTAssertTrue(app.buttons["backup.retryUserResolvable.sheet"].exists)
        app.swipeUp()
        XCTAssertTrue(section("continuesByItself").waitForExistence(timeout: 5))
        XCTAssertEqual(section("continuesByItself").label, "Continues by itself")
        XCTAssertTrue(row("network fixture.heic").label.contains("Connection interrupted."))
        app.swipeUp()
        XCTAssertTrue(section("notPossible").waitForExistence(timeout: 5))
        XCTAssertEqual(section("notPossible").label, "Not possible")
        let permanent = row("unsupported fixture.heic")
        XCTAssertTrue(permanent.waitForExistence(timeout: 5))
        XCTAssertTrue(permanent.label.contains("This file type cannot be backed up."))
        let dismiss = app.buttons["backup.dismissFailedItem.swipe.unsupported fixture.heic"]
        func rowLeaves(within timeout: TimeInterval) -> Bool {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: permanent)
            return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
        }
        // On a slow simulator XCUITest can drop the tap on a swipe action while the row still slides, and a removal
        // can take longer than the wait. Swipe again only while the row is still there; a dismissal that never
        // removes it fails the test.
        for _ in 0..<2 where permanent.exists {
            permanent.swipeLeft()
            guard dismiss.waitForExistence(timeout: 5) else { continue }
            dismiss.tap()
            if rowLeaves(within: 20) { break }
        }
        XCTAssertTrue(rowLeaves(within: 10), "the dismissed row must leave the list")
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Fixture technical detail'"))
                .firstMatch.exists)
    }

    func testGermanSectionsAndReasons() {
        openSheet(language: "de")
        XCTAssertEqual(section("actionNeeded").label, "Handlung erforderlich")
        XCTAssertTrue(row("accountStorage fixture.heic").label.contains("Dein Proton-Speicher ist voll."))
        app.swipeUp()
        XCTAssertTrue(section("continuesByItself").waitForExistence(timeout: 5))
        XCTAssertEqual(section("continuesByItself").label, "Läuft von selbst weiter")
        app.swipeUp()
        XCTAssertTrue(section("notPossible").waitForExistence(timeout: 5))
        XCTAssertEqual(section("notPossible").label, "Nicht möglich")
        XCTAssertTrue(row("unsupported fixture.heic").label.contains("Dieser Dateityp kann nicht gesichert werden."))
    }

    func testAutomaticWaitHasNoTryAgain() {
        openSheet(mode: "-EncryptedMemoriesNetworkOnlyBackupFixture")
        XCTAssertTrue(row("network fixture.heic").exists)
        XCTAssertFalse(section("actionNeeded").exists)
        XCTAssertFalse(app.buttons["backup.retryUserResolvable.sheet"].exists)
    }

    func testDecisionAndPermanentRowsDoNotExposeTryAgain() {
        openSheet(mode: "-EncryptedMemoriesNoUserResolvableBackupFixture")
        XCTAssertTrue(decisionRow("deletedElsewhere fixture.heic").exists)
        XCTAssertFalse(app.buttons["backup.retryUserResolvable.sheet"].exists)
    }

    func testAccountStorageExposesTryAgainAndRunsTheSheetAction() {
        openSheet(mode: "-EncryptedMemoriesAccountStorageOnlyBackupFixture")
        let retry = app.buttons["backup.retryUserResolvable.sheet"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        // While a pass runs, the open list reloads every 5 seconds, so the button can take one reload to go away.
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
    }
}
