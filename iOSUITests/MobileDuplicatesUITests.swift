import UIKit
import XCTest

final class MobileDuplicatesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() { app.terminate() }

    /// Opens Duplicates with the two fixture groups.
    private func openDuplicates() {
        openDuplicates(fixture: "-EncryptedMemoriesDuplicatesFixture")
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))
    }

    private func openDuplicates(fixture: String, dark: Bool = false, extra: [String] = [], language: String = "en") {
        app.launchArguments =
            [
                "-EncryptedMemoriesUITestFixture", fixture, "-AppleLanguages", "(\(language))", "-AppleLocale",
                language == "de" ? "de_AT" : "en_US",
            ] + (dark ? ["-EncryptedMemoriesDarkAppearance"] : []) + extra
        app.launch()
        // Native tabs use buttons; the expanded iPad sidebar uses cells. The role can change with orientation.
        let collectionsTitle = language == "de" ? "Sammlungen" : "Collections"
        let collectionsButton = app.buttons[collectionsTitle].firstMatch
        let collectionsCell = app.cells[collectionsTitle].firstMatch
        let collectionsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in collectionsButton.exists || collectionsCell.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collectionsReady], timeout: 60), .completed)
        (collectionsButton.exists ? collectionsButton : collectionsCell).tap()

        // The list creates rows lazily; Utilities follows the Library rows below the fold on a phone.
        let entry = app.buttons["duplicates.entry"]
        for _ in 0..<4 where !entry.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
    }

    private func group(_ index: Int) -> XCUIElement {
        app.scrollViews["duplicates.group.\(index)"].firstMatch
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, message)
    }

    func testTheLibraryCheckShowsItsTitleAndProgressWhileNoDuplicateIsFound() {
        openDuplicates(fixture: "-EncryptedMemoriesDuplicatesCheckingFixture")

        XCTAssertTrue(app.staticTexts["Checking Your Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Duplicates appear here when it is done."].exists)
        let progress = app.progressIndicators["duplicates.checkProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "the check shows its progress")
        XCTAssertGreaterThanOrEqual(progress.frame.width, 120)
        XCTAssertLessThanOrEqual(progress.frame.width, 320)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1,234 of 15,000 photos'"))
                .firstMatch.exists
                || (progress.value as? String)?.contains("1,234 of 15,000 photos") == true,
            "the progress counts the checked photos")
        XCTAssertFalse(app.staticTexts["No Duplicates"].exists)
    }

    /// Keeps a screenshot of the groups and of the running library check in light and dark for the visual review.
    func testScreenshotsOfTheGroupsAndTheLibraryCheck() {
        for dark in [false, true] {
            openDuplicates(fixture: "-EncryptedMemoriesDuplicatesFixture", dark: dark)
            XCTAssertTrue(group(1).waitForExistence(timeout: 10))
            XCTAssertTrue(
                app.staticTexts["4 identical copies"].waitForExistence(timeout: 5), "the screen counts every copy")
            keepScreenshot("duplicates-ios-groups-\(dark ? "dark" : "light")")
            member(0, 1).tap()
            XCTAssertTrue(app.buttons["duplicates.viewer.merge"].waitForExistence(timeout: 10))
            keepScreenshot("duplicates-ios-viewer-\(dark ? "dark" : "light")")
            // The same viewer as the library opens it, for comparison.
            app.buttons["Close"].firstMatch.tap()
            app.buttons["Library"].firstMatch.tap()
            let photo = libraryPhotoBelowTheBars()
            XCTAssertTrue(photo.waitForExistence(timeout: 20))
            photo.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
            keepScreenshot("library-ios-viewer-\(dark ? "dark" : "light")")
            app.terminate()

            openDuplicates(fixture: "-EncryptedMemoriesDuplicatesCheckingFixture", dark: dark)
            XCTAssertTrue(app.staticTexts["Checking Your Library"].waitForExistence(timeout: 10))
            keepScreenshot("duplicates-ios-checking-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// A grid photo whose frame lies completely below the top bars. The first grid photo can sit partly under them,
    /// and a tap there scrolls the grid instead of opening the photo.
    private func libraryPhotoBelowTheBars() -> XCUIElement {
        let photos = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        for index in 0..<min(photos.count, 40) {
            let photo = photos.element(boundBy: index)
            if photo.frame.minY > window.minY + 160, photo.frame.maxY < window.maxY - 160 { return photo }
        }
        return photos.firstMatch
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRetryReloadsDuplicatesAfterAnInvalidatingMergeFailedToReload() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesFixture", extra: ["-EncryptedMemoriesDuplicatesReloadFailure"])
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))
        app.buttons["duplicates.merge.0"].tap()
        let retry = app.buttons["Try again"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The duplicates could not be loaded."].exists)
        XCTAssertFalse(group(0).exists, "invalidated rows stay hidden")
        XCTAssertFalse(app.buttons["duplicates.mergeAll"].isEnabled)
        keepScreenshot("duplicates-ios-reload-failed")

        retry.tap()
        XCTAssertTrue(group(1).waitForExistence(timeout: 10), "Retry restores the checked list")
        XCTAssertTrue(app.buttons["duplicates.mergeAll"].isEnabled)
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(app.staticTexts["4 identical copies"].exists)
    }

    func testRetryRestartsTheLibraryCheckAfterTwoServiceInterruptions() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesCheckingFixture",
            extra: ["-EncryptedMemoriesDuplicatesInterruptedCheck"])
        let retry = app.buttons["Try again"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "two interruptions must end waiting")
        XCTAssertTrue(app.staticTexts["The duplicates could not be loaded."].exists)
        XCTAssertFalse(app.staticTexts["Duplicates appear here when it is done."].exists)
        keepScreenshot("duplicates-ios-interrupted-check")

        retry.tap()
        XCTAssertTrue(app.staticTexts["No Duplicates"].waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
    }

    func testMergeRemovesTheGroupFromDuplicates() {
        openDuplicates()
        let merge = app.buttons["duplicates.merge.0"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()

        waitUntilGone(group(1), "the merged group leaves the list")
        XCTAssertTrue(group(0).exists, "the other group stays")
    }

    func testTheInitialCheckHidesCandidatesAndDisablesMergeAll() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesLargeFixture", extra: ["-EncryptedMemoriesDuplicatesSlowCheck"])
        let progress = app.progressIndicators["duplicates.loading"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Checking duplicates"].exists)
        XCTAssertFalse(group(0).exists, "unchecked candidates have no rows or per-group merge")
        XCTAssertFalse(app.staticTexts["No Duplicates"].exists)
        XCTAssertFalse(app.staticTexts["duplicates.copyCount"].exists)
        XCTAssertFalse(app.staticTexts["duplicates.metadataCheck"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Merge frees' OR label CONTAINS 'Merging all frees'")
            ).firstMatch.exists)

        let mergeAll = app.buttons["duplicates.mergeAll"]
        XCTAssertTrue(mergeAll.exists, "the toolbar action stays visible")
        XCTAssertFalse(mergeAll.isEnabled, "the final checked list must arrive first")
        XCTAssertFalse(app.buttons["duplicates.mergeAll.dialog"].exists)
    }

    func testTheInitialCheckUsesTheSlimLoadingLayout() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesLargeFixture", extra: ["-EncryptedMemoriesDuplicatesSlowCheck"])
        assertWaitingLayout()
    }

    func testLandscapeIPadCheckKeepsItsPercentageCenteredAndCapped() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "this probe covers a landscape iPad window")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesLargeFixture", extra: ["-EncryptedMemoriesDuplicatesSlowCheck"])
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        assertWaitingLayout()
    }

    private func assertWaitingLayout() {
        let progress = app.progressIndicators["duplicates.loading"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Checking duplicates"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Checking duplicates'")).count, 1)
        XCTAssertTrue(app.staticTexts["Looking for identical copies in your library."].exists)
        XCTAssertGreaterThanOrEqual(progress.frame.width, 120)
        XCTAssertLessThanOrEqual(progress.frame.width, 320)
        XCTAssertLessThanOrEqual(
            progress.frame.width, app.staticTexts["Looking for identical copies in your library."].frame.width)
        XCTAssertEqual(progress.label, "Checking duplicates", "VoiceOver names the bar after the waiting state")
        let percent = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '%'")).firstMatch
        XCTAssertTrue(percent.exists)
        XCTAssertEqual(percent.frame.midX, progress.frame.midX, accuracy: 1, "the percentage stays centered")
        print(
            "[Duplicates layout] window=\(app.windows.firstMatch.frame.width) bar=\(progress.frame.width) percentMidX=\(percent.frame.midX) barMidX=\(progress.frame.midX)"
        )
        keepScreenshot("duplicates-ios-slim-metadata-check")
    }

    func testTheInitialScanUsesTheSameSlimLoadingLayout() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesLargeFixture", extra: ["-EncryptedMemoriesDuplicatesSlowScan"])
        let progress = app.activityIndicators["duplicates.loading"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Checking duplicates"].exists)
        XCTAssertTrue(app.staticTexts["Looking for identical copies in your library."].exists)
        XCTAssertFalse(app.buttons["duplicates.mergeAll"].isEnabled)
        XCTAssertFalse(group(0).exists)
        XCTAssertEqual(
            progress.frame.midX, app.staticTexts["Looking for identical copies in your library."].frame.midX,
            accuracy: 1)
        keepScreenshot("duplicates-ios-slim-scan")
    }

    func testMergeAllUsesAnAlertWithShortLocalizedActionsAndCancelKeepsTheGroups() {
        for language in ["en", "de"] {
            openDuplicates(fixture: "-EncryptedMemoriesDuplicatesFixture", language: language)
            revealGroup(1)
            app.buttons["duplicates.mergeAll"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "Merge All uses a native alert")
            let confirm = alert.buttons["duplicates.mergeAll.dialog"].firstMatch
            let cancel = alert.buttons[language == "de" ? "Abbrechen" : "Cancel"].firstMatch
            XCTAssertTrue(confirm.exists)
            XCTAssertEqual(confirm.label, language == "de" ? "Zusammenführen" : "Merge")
            XCTAssertTrue(confirm.isEnabled)
            XCTAssertTrue(confirm.isHittable)
            XCTAssertTrue(cancel.isHittable)
            // SwiftUI exposes the Merge action and its same-frame child as two accessibility buttons.
            let visibleActions = Set(
                alert.buttons.allElementsBoundByIndex.map { "\($0.label)|\($0.frame)" })
            XCTAssertEqual(visibleActions.count, 2)
            XCTAssertTrue(
                alert.staticTexts[language == "de" ? "4 exakte Kopien zusammenführen?" : "Merge 4 Exact Copies?"].exists
            )
            let message = alert.staticTexts[
                language == "de"
                    ? "Die Kopien sind identisch. Ein Foto jeder Gruppe bleibt, mit Favoriten und Alben. 2 Fotos kommen in „Zuletzt gelöscht“."
                    : "The copies are identical. One photo of each group stays, with its favorites and albums. 2 photos move to Recently Deleted."
            ]
            XCTAssertTrue(message.exists)
            XCTAssertEqual(alert.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2)
            print(
                "[Duplicates alert] language=\(language) alert=\(alert.frame) confirm=\(confirm.frame) cancel=\(cancel.frame)"
            )
            keepScreenshot("duplicates-ios-merge-alert-\(language)")
            let textRegion = alert.scrollViews.firstMatch
            for _ in 0..<8 where message.frame.maxY > textRegion.frame.maxY + 2 { textRegion.swipeUp() }
            XCTAssertLessThanOrEqual(message.frame.maxY, textRegion.frame.maxY + 2, "the entire message can be read")
            XCTAssertTrue(confirm.isHittable)
            XCTAssertTrue(cancel.isHittable)
            keepScreenshot("duplicates-ios-merge-alert-message-end-\(language)")
            cancel.tap()
            waitUntilGone(alert, "Cancel dismisses the alert")
            revealGroup(0, scrollingUp: false)
            revealGroup(1)
            // A merge that Cancel failed to stop would remove the group.
            let merged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: group(1))
            XCTAssertEqual(XCTWaiter.wait(for: [merged], timeout: 4), .timedOut, "Cancel starts no merge")
            app.terminate()
        }
    }

    /// Large accessibility text can put a fixture group below the viewport; reach the real row by scrolling.
    private func revealGroup(_ index: Int, scrollingUp: Bool = true) {
        for _ in 0..<4 where !group(index).waitForExistence(timeout: 1) {
            if scrollingUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(group(index).waitForExistence(timeout: 10), "every fixture group remains in the list")
    }

    func testMergeAllMergesEveryGroupAfterTheConfirmation() throws {
        openDuplicates()
        let mergeAll = app.buttons["duplicates.mergeAll"]
        XCTAssertTrue(mergeAll.waitForExistence(timeout: 5))
        mergeAll.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let confirm = alert.buttons["duplicates.mergeAll.dialog"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        waitUntilGone(group(0), "every group leaves the list")
        XCTAssertTrue(app.staticTexts["No Duplicates"].waitForExistence(timeout: 5))
    }

    func testStopEndsMergeAllAfterTheRunningBatchAndKeepsTheOtherGroups() throws {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesLargeFixture", extra: ["-EncryptedMemoriesDuplicatesSlowMerge"])
        XCTAssertTrue(group(0).waitForExistence(timeout: 30))
        let mergeAll = app.buttons["duplicates.mergeAll"]
        XCTAssertTrue(mergeAll.waitForExistence(timeout: 5))
        mergeAll.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let confirm = alert.buttons["duplicates.mergeAll.dialog"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        XCTAssertTrue(app.staticTexts["Merging Duplicates"].waitForExistence(timeout: 30), "the progress row shows")
        let stop = app.buttons["duplicates.stopMerge"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        let notice = app.staticTexts
            .matching(
                NSPredicate(format: "label BEGINSWITH 'Merging stopped.' AND label ENDSWITH 'groups were merged.'")
            )
            .firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the notice counts the merged groups")
        app.alerts.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(group(0).waitForExistence(timeout: 5), "the groups that did not merge stay")
        XCTAssertFalse(app.buttons["duplicates.stopMerge"].exists)
    }

    private func member(_ group: Int, _ index: Int) -> XCUIElement {
        app.buttons["duplicates.member.\(group).\(index)"]
    }

    private func waitUntil(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, message)
    }

    func testTappingAPhotoOpensItWithItsGroupAndKeepsItThere() {
        openDuplicates()
        let ranked = member(0, 0)
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        XCTAssertTrue(ranked.isSelected, "the ranked photo is kept first")
        XCTAssertFalse(other.isSelected)
        XCTAssertTrue(other.label.hasPrefix("Copy 2 of 2"), "each copy says its position, got \(other.label)")

        other.tap()

        let keep = app.buttons["duplicates.viewer.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "a tap opens the photo with the merge tools")
        XCTAssertEqual(keep.label, "Keep This Copy")
        for action in ["Favorite", "Info"] {
            XCTAssertTrue(app.buttons[action].firstMatch.exists, "the viewer keeps the library action \(action)")
        }
        keep.tap()
        waitUntil(keep, "label == 'Kept'", "the shown photo is kept")

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        waitUntil(other, "isSelected == true", "the list keeps the photo chosen in the viewer")
        XCTAssertFalse(ranked.isSelected)
        XCTAssertTrue(other.label.contains(", kept"), "the kept copy says so, got \(other.label)")
    }

    func testMergeInTheViewerMergesTheGroupAndClosesTheViewer() {
        openDuplicates()
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let merge = app.buttons["duplicates.viewer.merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10))

        merge.tap()

        waitUntilGone(merge, "the viewer closes")
        waitUntilGone(group(1), "the merged group leaves the list")
        XCTAssertTrue(group(0).exists, "the other group stays")
    }

    func testSwipingDownClosesTheViewerOfAGroupLikeTheLibraryViewer() {
        openDuplicates()
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer opened")

        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 400)))

        waitUntilGone(close, "swiping down closes the viewer")
        XCTAssertTrue(group(0).waitForExistence(timeout: 10), "the duplicates return")
    }

    /// Closing the viewer returns to the list as it was; only opening the screen and pulling to refresh scan again.
    func testClosingTheViewerDoesNotScanTheLibraryAgain() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesFixture", extra: ["-EncryptedMemoriesDuplicatesRescanDropsGroup"])
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer opened")

        close.tap()

        XCTAssertTrue(group(0).waitForExistence(timeout: 10))
        // A scan after the viewer would drop the last group of this fixture.
        let dropped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: group(1))
        XCTAssertEqual(XCTWaiter.wait(for: [dropped], timeout: 4), .timedOut, "the list did not scan again")
    }

    func testPullToRefreshScansTheLibraryAgain() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesFixture", extra: ["-EncryptedMemoriesDuplicatesRescanDropsGroup"])
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))

        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)))

        waitUntilGone(group(1), "a refresh scans again and the fixture drops the last group")
    }

    func testASlowPullToRefreshFinishesAfterTheListBecomesProgress() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesFixture",
            extra: ["-EncryptedMemoriesDuplicatesRescanDropsGroup", "-EncryptedMemoriesDuplicatesSlowScan"])
        XCTAssertTrue(group(1).waitForExistence(timeout: 15))
        let top = app.staticTexts["duplicates.copyCount"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)))

        let progress = app.activityIndicators["duplicates.loading"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 3), "the refresh replaces the list while scanning")
        XCTAssertFalse(group(0).exists)
        keepScreenshot("duplicates-ios-slow-refresh-progress")
        XCTAssertTrue(group(0).waitForExistence(timeout: 15), "the cancellation-sensitive scan finishes")
        XCTAssertFalse(group(1).exists, "the successful refresh publishes its new result")
        XCTAssertFalse(app.staticTexts["The duplicates could not be loaded."].exists)
        XCTAssertFalse(app.buttons["Try again"].exists)
        XCTAssertFalse(progress.exists)
        keepScreenshot("duplicates-ios-slow-refresh-complete")
    }

    /// A group with more copies than fit scrolls sideways to its last copy; a group whose copies fit does not move.
    func testAWideGroupScrollsSidewaysAndAGroupThatFitsStays() {
        openDuplicates(fixture: "-EncryptedMemoriesDuplicatesWideFixture")
        let window = app.windows.firstMatch
        func isOnScreen(_ element: XCUIElement) -> Bool { element.exists && window.frame.contains(element.frame) }
        /// Drags across a row from its right edge to its left edge, as a finger does.
        func dragLeft(_ row: XCUIElement) {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        }
        let wide = group(0)
        XCTAssertTrue(wide.waitForExistence(timeout: 10))
        let first = member(0, 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let last = member(0, 11)
        XCTAssertFalse(isOnScreen(last), "the last copy starts beside the screen")
        let firstX = first.frame.minX

        for _ in 0..<8 where !isOnScreen(last) { dragLeft(wide) }
        XCTAssertTrue(last.waitForExistence(timeout: 5), "the row builds its last copy when it scrolls there")
        XCTAssertTrue(isOnScreen(last), "the row scrolls to its last copy: \(last.frame) in \(window.frame)")
        XCTAssertTrue(!first.exists || first.frame.minX < firstX, "the row moved sideways")

        let copy = member(1, 0)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(isOnScreen(member(1, 1)), "both copies fit")
        let copyX = copy.frame.minX
        dragLeft(group(1))
        XCTAssertEqual(copy.frame.minX, copyX, accuracy: 0.5, "a row that fits does not move sideways")
    }

    func testTheContextMenuKeepsAnotherPhoto() {
        openDuplicates()
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))

        other.press(forDuration: 1.2)
        let byIdentifier = app.buttons["duplicates.keepMenu"].firstMatch
        let keep = byIdentifier.waitForExistence(timeout: 5) ? byIdentifier : app.buttons["Keep This Copy"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "the context menu offers Keep This Copy")
        keep.tap()

        waitUntil(other, "isSelected == true", "the photo from the context menu is kept")
        XCTAssertFalse(member(0, 0).isSelected)
    }
}
