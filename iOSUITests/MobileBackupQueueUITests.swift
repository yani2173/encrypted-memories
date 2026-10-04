import XCTest

final class MobileBackupQueueUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesBackupQueueFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    private func openBackup() {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
    }

    private func row(_ filename: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "backup.queueItem.\(filename)").firstMatch
    }

    /// The system dialog can list a button twice in the accessibility tree; the visible copy is the hittable one.
    private func dialogButton(_ identifier: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: identifier)
        for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    func testQueueListsUploadingAndWaitingFilesButNotProblems() {
        openBackup()
        let queue = app.buttons["backup.queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
        queue.tap()

        let uploading = app.staticTexts["backup.queueSection.uploading"]
        XCTAssertTrue(uploading.waitForExistence(timeout: 10))
        XCTAssertEqual(uploading.label, "Uploading now")
        XCTAssertEqual(app.staticTexts["backup.queueSection.waiting"].label, "Up next")
        XCTAssertTrue(row("Uploading fixture.heic").label.contains("Uploading…"))
        XCTAssertTrue(row("Waiting fixture.heic").label.contains("Queued"))
        XCTAssertFalse(row("Network fixture.heic").exists, "a photo with a problem stays in the problem list")
    }

    func testTurningBackupOffAsksFirst() {
        openBackup()
        let disable = app.buttons["backup.disable"]
        if !disable.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(disable.waitForExistence(timeout: 5))

        disable.tap()
        let cancel = dialogButton("backup.disable.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(disable.waitForExistence(timeout: 5), "Cancel keeps the backup on")

        disable.tap()
        let confirm = dialogButton("backup.disable.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: disable)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "Turn off ends the backup")
        XCTAssertFalse(app.buttons["backup.queue"].exists)
    }
}
