import XCTest

/// Measures scrolling through 1,500 groups of duplicates on the offline fixture account: the hitches of the scroll
/// animations and the peak memory of the app. Runs only when the test runner gets `DUPLICATES_PERF=1` (pass
/// `TEST_RUNNER_DUPLICATES_PERF=1` to xcodebuild), so the regular UI gate stays as fast as before.
final class MobileDuplicatesPerformanceTests: XCTestCase {
    func testScrollingFifteenHundredGroupsKeepsMemoryBounded() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DUPLICATES_PERF"] == "1", "Set DUPLICATES_PERF=1 to measure.")
        continueAfterFailure = false
        let app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDuplicatesLargeFixture", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        let collections = app.buttons["Collections"].firstMatch
        XCTAssertTrue(collections.waitForExistence(timeout: 60))
        collections.tap()
        let entry = app.buttons["duplicates.entry"]
        for _ in 0..<4 where !entry.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let first = app.descendants(matching: .any).matching(identifier: "duplicates.group.0").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the groups show")

        // Each pass flings further down the list; the first pass is a warm-up that XCTest leaves out.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(
            metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)],
            options: options
        ) {
            for _ in 0..<35 { app.swipeUp(velocity: .fast) }
        }
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after 1,500 groups")
    }
}
