import XCTest

final class MobilePagedBackupUITests: XCTestCase {
    func testLastPageIsReachableAndRow250KeepsItsDecisionAction() throws {
        let started = Date()
        continueAfterFailure = false
        let app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDeletedBackupFixture",
            "-EncryptedMemoriesDeletedBackupLargeFixture", "-EncryptedMemoriesProblemListSmoke",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let attention = app.buttons["backup.failedItems"]
        XCTAssertTrue(attention.waitForExistence(timeout: 30))
        attention.tap()
        let list = app.descendants(matching: .any).matching(identifier: "backup.problemList.fixture").firstMatch
        assertLoaded("loaded=5000;total=5000", list: list)

        let decision = row(250, in: app)
        assertHittable(decision)
        decision.tap()
        XCTAssertTrue(app.buttons["backup.keepDeleted.dialog"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        try app.tapDialogButton("backup.keepDeleted.dialog")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: decision)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 20), .completed)
        assertLoaded("loaded=4999;total=4999", list: list)

        let last = row(5_000, in: app)
        // Native lists can clamp the direct jump before the final row in a medium sheet.
        if !last.isHittable { list.swipeUp() }
        assertHittable(last)
        // The jump lands on estimated row heights; only the real end of the list proves the bar placement.
        let end = scrollToEnd(list, last: last)
        let area = app.otherElements["backup.problemList.actionArea"]
        XCTAssertTrue(area.exists, "The fixed action area must show at the end of the list")
        XCTAssertTrue(area.buttons["backup.bulk.backUpAgain"].exists, "The area must keep the bulk action")
        XCTAssertTrue(area.staticTexts["backup.bulk.count"].exists, "The area must keep the bulk count")
        // The area frame starts at the bar background, which `isHittable` cannot see covering a row.
        let barTop = area.frame.minY
        XCTAssertLessThanOrEqual(
            end.maxY, barTop, "At the end of the list, the last row \(end) must stay above the bar (top \(barTop))")
        last.tap()
        XCTAssertTrue(app.buttons["backup.keepDeleted.dialog"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Last page decision"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThan(Date().timeIntervalSince(started), 120, "The native wiring smoke test must stay short")
    }

    private func row(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["backup.failedItem.Deleted \(String(format: "%04d", number)) fixture.heic"].firstMatch
    }

    private func assertLoaded(_ value: String, list: XCUIElement) {
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: list)
        XCTAssertEqual(
            XCTWaiter.wait(for: [loaded], timeout: 30), .completed,
            "Expected \(value); observed \(String(describing: list.value))")
    }

    /// Swipes until a further swipe no longer moves the last row, which is the real end of the list.
    private func scrollToEnd(_ list: XCUIElement, last: XCUIElement) -> CGRect {
        var frame = settledFrame(of: last)
        for _ in 0..<4 {
            list.swipeUp()
            let next = settledFrame(of: last)
            if abs(next.minY - frame.minY) < 0.5 { return next }
            frame = next
        }
        XCTFail("The list did not reach its end; the last row is still at \(frame)")
        return frame
    }

    /// Returns the frame once two reads 0.5 s apart agree.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var previous = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            let current = element.frame
            if abs(current.minY - previous.minY) < 0.5 { return current }
            previous = current
        }
        XCTFail("The last row did not settle; last read \(previous)")
        return previous
    }

    private func assertHittable(_ row: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row.isHittable }, object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 20), .completed)
    }
}
