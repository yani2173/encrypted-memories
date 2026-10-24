import XCTest

/// Taps through the iOS app like a person does, on the offline fixture account: no Proton account, no network.
/// The app runs in English so the tests can find controls by their visible names.
final class MobileLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testLibraryShowsThePhotosOfTheAccount() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "the library grid shows no photo")
        XCTAssertTrue(app.buttons["Select"].exists)
    }

    func testAPhotoOpensInTheViewerAndClosesAgain() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        close.tap()

        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")
    }

    /// Swiping down closes the viewer for a video too, also while its stream cannot play.
    func testSwipingDownOnAVideoClosesTheViewer() {
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 60), "the library grid shows no video")
        firstVideo.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the viewer did not open")

        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 400)))

        XCTAssertTrue(
            wait(for: app.buttons["Close"], "exists == false", timeout: 20), "swiping down did not close the viewer")
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 10), "the library did not return")
    }

    func testTheAlbumButtonOfTheViewerAddsTheOpenPhotoToAnAlbum() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()

        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10), "the viewer shows no album button")
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10), "the album list did not open")
        XCTAssertTrue(album.isEnabled, "the photo is in the album before it was added")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false", timeout: 20), "adding the photo did not close the album list")

        // The album list opens again and marks the album that already holds the photo.
        addToAlbum.tap()
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: album, "isEnabled == false"), "the album does not hold the photo")
    }

    /// Every fixture photo is an edit with an original. The More menu shows the original, marks it with a badge, and
    /// returns to the edited version.
    func testTheViewerShowsTheOriginalOfAnEditedPhotoAndTheEditAgain() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the viewer did not open")

        let more = app.buttons.matching(NSPredicate(format: "label == 'More actions' OR label == 'More'")).firstMatch
        let showOriginal = app.buttons["Show Original"]
        // The viewer asks for the original once the photo stayed on screen and the app admits the ask, so the item
        // appears after a wait of unknown length, also while the library still loads on a slow runner.
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the viewer shows no More menu")
        more.tap()
        XCTAssertTrue(showOriginal.waitForExistence(timeout: 30), "the More menu offers no Show Original")
        showOriginal.tap()

        let badge = app.descendants(matching: .any)["Showing the original"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the original carries no badge")

        more.tap()
        let showEdited = app.buttons["Show Edited"]
        XCTAssertTrue(showEdited.waitForExistence(timeout: 10), "the More menu offers no Show Edited")
        showEdited.tap()
        XCTAssertTrue(wait(for: badge, "exists == false", timeout: 10), "the edited version still carries the badge")
    }

    func testSelectingPhotosShowsTheirActionsAndDoneEndsTheSelection() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Select"].tap()
        firstPhoto.tap()

        XCTAssertTrue(wait(for: firstPhoto, "isSelected == true"), "the tapped photo is not selected")
        XCTAssertTrue(app.buttons["Share selected items"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move selected items to Trash"].isEnabled)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: firstPhoto, "isSelected == false"), "Done must clear the selection")
    }

    func testTabsSwitchToCollectionsBackToTheLibraryAndToSearch() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))

        app.tabBars.buttons["Collections"].tap()
        XCTAssertTrue(
            wait(for: firstPhoto, "exists == false", timeout: 20), "the library grid stays visible under Collections")

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")

        // The search tab turns the tab bar into a search field, so it comes last.
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search shows no search field")
    }

    /// The end of the search suggestions scrolls clear of the bottom search field, so the Smart Search hint can be read
    /// with the keyboard up and with the keyboard down.
    func testTheSmartSearchHintScrollsAboveTheSearchField() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.tabBars.buttons["Search"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search shows no search field")
        // The fixture account has Smart Search off, so the hint ends the suggestions.
        let hint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Turn on Smart Search'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 30), "the suggestions show no Smart Search hint")

        // Recent searches make the suggestions longer than the space above the keyboard.
        for query in ["Spring", "Winter", "Summer"] {
            searchField.tap()
            searchField.typeText(query + "\n")
            let clear = searchField.buttons.firstMatch
            if clear.waitForExistence(timeout: 5) { clear.tap() }
        }
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "the suggestions did not return after the searches")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard is not up")

        scrollSuggestionsToTheEnd()
        XCTAssertLessThanOrEqual(
            hint.frame.maxY, searchField.frame.minY, "the search field above the keyboard covers the end of the list")

        // Dragging the list down dismisses the keyboard; the field returns to the tab bar.
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 550)))
        XCTAssertTrue(wait(for: app.keyboards.firstMatch, "exists == false", timeout: 20), "the keyboard did not close")
        scrollSuggestionsToTheEnd()
        XCTAssertLessThanOrEqual(
            hint.frame.maxY, searchField.frame.minY, "the search field in the tab bar covers the end of the list")
    }

    private func scrollSuggestionsToTheEnd() {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)))
        }
        // The list bounces back to its end before the frames are compared.
        sleep(1)
    }

    func testReturningFromBackgroundRestoresTheViewerWithPreviewProtection() {
        app.terminate()
        app.launchArguments += ["-EncryptedMemories.blurAppPreview", "YES"]
        app.launch()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
    }

    func testPrivacyPreviewSwitchPersistsAfterClosingSettings() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()

        let previewSwitch = app.switches["Blur App Preview"]
        XCTAssertTrue(previewSwitch.waitForExistence(timeout: 5))
        let initialValue = try XCTUnwrap(previewSwitch.value as? String)
        XCTAssertEqual(initialValue, "1", "Blur App Preview defaults on")
        let changedValue = initialValue == "0" ? "1" : "0"
        previewSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: previewSwitch, "value == '\(changedValue)'"))

        app.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Blur App Preview"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(initialValue)'"))
    }

    func testPrivacySwitchHidesTheMapTab() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        XCTAssertTrue(app.tabBars.buttons["Map"].exists)

        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let mapSwitch = app.switches["Map and Places"]
        XCTAssertTrue(mapSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(mapSwitch.value as? String, "1")
        mapSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: mapSwitch, "value == '0'"))
        app.buttons["Settings"].tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(wait(for: app.tabBars.buttons["Map"], "exists == false", timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
    }

    func testRemoveLocationSwitchPersistsAfterClosingSettings() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()

        let removeLocationSwitch = app.switches["Remove location when sharing"]
        XCTAssertTrue(removeLocationSwitch.waitForExistence(timeout: 5))
        let originalValue = try XCTUnwrap(removeLocationSwitch.value as? String)
        XCTAssertEqual(originalValue, "1", "Remove location when sharing defaults on")
        removeLocationSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changedValue = originalValue == "0" ? "1" : "0"
        XCTAssertTrue(wait(for: removeLocationSwitch, "value == '\(changedValue)'"))

        app.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Remove location when sharing"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(originalValue)'"))
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Grid photos are accessibility elements named "Photo, <date>".
    private var firstPhoto: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }

    /// Grid videos are named "Video, <date>".
    private var firstVideo: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video, '")).firstMatch
    }
}
