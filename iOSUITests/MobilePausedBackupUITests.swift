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
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
        XCTAssertEqual(cellular.label, "Use Cellular Data")
        XCTAssertEqual(cellular.value as? String, "0", "the backup waits for Wi-Fi by default")
        cellular.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: cellular, "value == '1'"), "the switch does not turn on")
        cellular.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: cellular, "value == '0'"))
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
