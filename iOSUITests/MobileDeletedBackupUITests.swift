import XCTest

final class MobileDeletedBackupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDeletedBackupFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// Keeps what the app shows when a wait fails: the whole hierarchy as text (the summary on the Backup screen and
    /// the rows or the empty, loading or unavailable state of the open sheet) and a screenshot. A failure of the
    /// list then names its cause.
    private func attachDiagnostics(named name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name): hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name): screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func openDecision() {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let attention = app.buttons["backup.failedItems"]
        XCTAssertTrue(attention.waitForExistence(timeout: 10))
        XCTAssertTrue(attention.label.contains("1"), "One parked photo must need attention")
        attention.tap()
        let row = decisionRow
        let rowAppeared = row.waitForExistence(timeout: 10)
        if !rowAppeared { attachDiagnostics(named: "Backup list without the decision row") }
        XCTAssertTrue(rowAppeared)
        row.tap()
        XCTAssertTrue(app.buttons["backup.keepDeleted.dialog"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
    }

    func testDialogActionCannotResolveBeforeTheDecisionIsPresented() throws {
        XCTAssertTrue(app.buttons["Proton Account and Settings"].waitForExistence(timeout: 60))
        XCTAssertThrowsError(try app.hittableDialogButton("backup.backUpAgain.dialog"))
    }

    func testKeepDeletedRemovesDecisionRowAndAttentionCount() throws {
        openDecision()
        try app.tapDialogButton("backup.keepDeleted.dialog")
        XCTAssertTrue(app.staticTexts["Nothing needs attention."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let attention = app.buttons["backup.failedItems"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: attention)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed)
        let deletionCount = app.buttons["backup.remoteDeletions"]
        XCTAssertTrue(deletionCount.waitForExistence(timeout: 5))
        XCTAssertTrue((deletionCount.value as? String)?.contains("1") == true)
    }

    func testBackUpAgainRetriesAnUnacknowledgedTap() throws {
        var taps = 0
        try backUpAgain { button in
            taps += 1
            if taps > 1 { button.tap() }
        }
        XCTAssertEqual(taps, 2, "Only an unacknowledged tap may be repeated")
    }

    func testBackUpAgainRemovesPermanentDecisionRow() throws {
        try backUpAgain()
    }

    func testAcknowledgedBackUpAgainTapIsNotRepeated() throws {
        var taps = 0
        try backUpAgain { _ in
            taps += 1
            // Confirm native input before returning, so the outer helper sees acknowledgement on its first callback.
            do {
                try app.tapDialogButton("backup.backUpAgain.dialog")
            } catch {
                XCTFail("The input callback must acknowledge the action: \(error)")
            }
            XCTAssertFalse(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        }
        XCTAssertEqual(taps, 1, "An acknowledged tap must not be repeated")
    }

    private func backUpAgain(tap: (XCUIElement) -> Void = { $0.tap() }) throws {
        openDecision()
        try app.tapDialogButton("backup.backUpAgain.dialog", tap: tap)
        assertBackUpAgainResolved()
    }

    private var decisionRow: XCUIElement {
        app.buttons["backup.failedItem.Deleted fixture.heic"].firstMatch
    }

    func testRowRemovalWaitRejectsAnUnresolvedDecision() {
        openDecision()
        XCTAssertEqual(waitForDecisionRowRemoval(), .timedOut, "An unresolved decision must remain in the list")
        XCTAssertTrue(decisionRow.exists)
    }

    private func waitForDecisionRowRemoval() -> XCTWaiter.Result {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: decisionRow)
        // A hosted accessibility snapshot stalled for 19.3 s; allow several cycles while diagnosis is pending.
        return XCTWaiter.wait(for: [gone], timeout: 60)
    }

    private func assertBackUpAgainResolved() {
        // The empty state replaces the list, so the row is gone as soon as the text shows; one check proves it.
        XCTAssertTrue(app.staticTexts["Nothing needs attention."].waitForExistence(timeout: 60))
        XCTAssertFalse(decisionRow.exists)
        XCTAssertFalse(app.buttons["backup.keepDeleted.dialog"].firstMatch.exists)
        XCTAssertFalse(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["backup.remoteDeletions"].exists)
    }
}
