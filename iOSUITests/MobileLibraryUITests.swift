import UIKit
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
        if name.contains("testLargeGridFixtureRetainsSelectionWhileDenseRowScrolls") {
            app.launchArguments += ["-EncryptedMemoriesLargeGridFixture", "-EncryptedMemoriesDenseGridSmoke"]
        }
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    /// Device Hub sets the native pose manually; this test verifies the long library and real dense scrolling.
    func testLargeGridFixtureRetainsSelectionWhileDenseRowScrolls() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 90))
        let firstPosition = firstPhoto.value as? String ?? ""
        let positionDigits = firstPosition.filter(\.isNumber)
        XCTAssertTrue(
            positionDigits.hasSuffix("3601"),
            "Six sections contain 3,600 photos and the existing video; position=\(firstPosition)")
        app.buttons["Select"].tap()
        let window = app.windows.firstMatch
        let windowSnapshot = try window.snapshot()
        func photoSnapshots(in node: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
            let own: [any XCUIElementSnapshot] =
                node.elementType == .button && node.label.hasPrefix("Photo, ") ? [node] : []
            return own + node.children.flatMap { photoSnapshots(in: $0) }
        }
        let photos = photoSnapshots(in: windowSnapshot)
        XCTAssertGreaterThan(photos.count, 0)
        // Metal photo elements have frames but do not report hittability. Use the visible projection's upper third.
        let witnessIndex = photos.count / 3
        let witness = photos[witnessIndex]
        XCTAssertTrue(windowSnapshot.frame.contains(witness.frame), "The witness must be a complete visible tile")
        let witnessY = witness.frame.midY
        // The production accessibility provider preserves engine order, so every row is contiguous.
        let lower = max(0, witnessIndex - 20)
        let upper = min(photos.count, witnessIndex + 20)
        let row = (lower..<upper).map { photos[$0] }
            .filter { abs($0.frame.midY - witnessY) < 0.5 }
        XCTAssertEqual(row.count, 20, "The production compact grid must actually reach its densest 20-column level")
        let label = witness.label
        let position = witness.value as? String
        let witnessElement = app.buttons.matching(
            NSPredicate(format: "label == %@ AND value == %@", label, position ?? "")
        ).firstMatch
        witnessElement.tap()
        XCTAssertTrue(wait(for: witnessElement, "isSelected == true"))
        let oldY = witness.frame.midY
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)
        let selected = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", label, position ?? ""))
            .firstMatch
        XCTAssertTrue(wait(for: selected, "isSelected == true"))
        XCTAssertGreaterThan(selected.frame.midY, oldY + 20, "The dense row must actually scroll")
    }

    func testLibraryShowsThePhotosOfTheAccount() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "the library grid shows no photo")
        XCTAssertTrue(app.buttons["Select"].exists)
    }

    /// The top leading corner names the dates of the photos on screen, also after scrolling.
    func testTheLibraryShowsTheDatesOfTheVisiblePhotos() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let dates = app.descendants(matching: .any)["library.visibleDates"]
        XCTAssertTrue(dates.waitForExistence(timeout: 10), "the library shows no date label")
        XCTAssertTrue(
            wait(for: dates, "label MATCHES '.*[0-9]{4}.*'"), "the date label names no year: \(dates.label)")

        app.windows.firstMatch.swipeDown()
        XCTAssertTrue(dates.waitForExistence(timeout: 10), "the date label disappeared after scrolling")
    }

    func testAPhotoOpensInTheViewerAndClosesAgain() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        close.tap()

        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")
    }

    func testViewerKeepsTheVerticalBarBackgroundBlack() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        guard let column = try app.verticalTabColumn() else {
            throw XCTSkip("The window has no vertical tab column")
        }
        try app.visiblePhoto(beside: column).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        func pixel(x: CGFloat, y: CGFloat) throws -> [UInt8] {
            let rect = CGRect(x: CGFloat(image.width) * x, y: CGFloat(image.height) * y, width: 1, height: 1)
            let point = try XCTUnwrap(image.cropping(to: rect))
            var rgba: [UInt8] = [0, 0, 0, 0]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(
                    CGContext(
                        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(point, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba
        }
        let photo = try pixel(x: 0.25, y: 0.45)
        XCTAssertGreaterThan(photo[0], 50, "SETUP: the purple fixture photo must be visible")
        let barBackground = try pixel(x: 0.98, y: 0.45)
        XCTAssertLessThan(barBackground[0], 25, "The background beyond the photo must be black")
        XCTAssertLessThan(barBackground[1], 25)
        XCTAssertLessThan(barBackground[2], 25)
    }

    #if ISSUE924_EXPECT_VERTICAL
        func testExpectedVerticalTabColumnIsPresent() throws {
            XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
            XCTAssertNotNil(try app.verticalTabColumn(), "The expected vertical tab column must be present")
        }
    #endif

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

    /// The viewer asks again silently after a rate limit and shows no message for it. A failure that a new attempt can
    /// change offers Try again, and one that no attempt changes offers none. The scenario argument makes the fixture
    /// rate-limit the first preparation, fail the second in a changeable way and every later one for good.
    func testTheFailedVideoOffersTryAgainOnlyWhenAnotherAttemptCanChangeIt() {
        app.terminate()
        app.launchArguments += ["-EncryptedMemoriesVideoFailureScenario"]
        app.launch()
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 60), "the library grid shows no video")
        firstVideo.tap()

        let tryAgain = app.buttons["Try again"]
        XCTAssertTrue(
            tryAgain.waitForExistence(timeout: 30), "a failure that a new attempt can change offers no Try again")
        XCTAssertTrue(app.staticTexts["The video couldn’t be played."].exists, "the silent retry did not run")
        XCTAssertFalse(app.staticTexts["Proton is busy right now."].exists, "the rate limit showed a message")

        tryAgain.tap()
        XCTAssertTrue(
            app.staticTexts["The video couldn’t be decrypted."].waitForExistence(timeout: 20),
            "Try again did not prepare the video again")
        XCTAssertFalse(app.buttons["Try again"].exists, "a failure that no new attempt changes still offers Try again")
    }

    func testTheAlbumButtonOfTheViewerAddsTheOpenPhotoToAnAlbum() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()

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

    func testTheGridContextMenuOpensAndCancelsTheAlbumPicker() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).press(forDuration: 1.2)
        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10), "the context menu has no album action")
        addToAlbum.tap()
        let cancel = app.barButton(titled: "Cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the album picker did not open")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Grid context menu album picker hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(cancel.isHittable)
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(album.frame), "The first album must fit inside the context menu list")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")
        cancel.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "Cancel did not return to the library")
    }

    func testAlbumPickerShowsItsFirstAlbumWithoutScrolling() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(album.frame), "The first album must fit inside the visible list")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false", timeout: 20))
    }

    func testAlbumPickerShowsItsEmptyStateWithoutScrolling() throws {
        app.terminate()
        app.launchArguments += ["-EncryptedMemoriesEmptyAlbumFixture"]
        app.launch()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let empty = app.staticTexts["No albums yet"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(.staticText, identifier: "No albums yet").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(empty.frame), "The empty state must fit inside the visible list")
        XCTAssertTrue(empty.isHittable, "The empty state must be visible without scrolling")
    }

    func testSelectionToolbarShowsTheFirstAlbumWithoutScrolling() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let column = try app.verticalTabColumn()
        app.barButton(titled: "Select").tap()
        try app.visiblePhoto(beside: column).tap()
        let addToAlbum = app.barButton(titled: "Add to Album")
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.frame.contains(album.frame), "The first album must fit inside the visible selection list")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false", timeout: 20))
    }

    /// In landscape the album picker keeps a usable width, its Cancel button stays in the bar instead of an overflow
    /// menu, and the creation form keeps its Create & Add button in the bar. The photo is selected in portrait, where
    /// the bar helpers know every native tab layout; the selection stays when the device turns.
    func testAlbumPickerKeepsCancelAndCreateInTheBarInLandscape() throws {
        // A teardown block also runs after a failed assertion, so later tests never start in landscape.
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let column = try app.verticalTabColumn()
        app.barButton(titled: "Select").tap()
        try app.visiblePhoto(beside: column).tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let turned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        // The window, not the device, decides: a display that keeps its portrait window has no landscape layout.
        try XCTSkipUnless(XCTWaiter.wait(for: [turned], timeout: 5) == .completed, "The window stays in portrait")
        let addToAlbum = app.barButton(titled: "Add to Album")
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let newAlbum = app.buttons["New Album"].firstMatch
        XCTAssertTrue(newAlbum.waitForExistence(timeout: 10), "the album picker did not open")
        let list = app.collectionViews.containing(.button, identifier: "New Album").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        attachScreen(named: "Landscape album picker")
        print("[Album landscape] window=\(app.windows.firstMatch.frame) list=\(list.frame)")
        XCTAssertGreaterThanOrEqual(list.frame.width, 300, "The picker must keep a usable width")
        let cancel = app.barButton(titled: "Cancel")
        XCTAssertTrue(cancel.exists && cancel.isHittable, "Cancel must stay directly in the bar")
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10), "the picker shows no album")
        XCTAssertTrue(album.isHittable, "The first album must be directly tappable")

        newAlbum.tap()
        let create = app.barButton(titled: "Create & Add")
        XCTAssertTrue(create.waitForExistence(timeout: 10), "the creation form did not open")
        attachScreen(named: "Landscape album creation form")
        XCTAssertTrue(create.isHittable, "Create & Add must stay directly in the bar")
    }

    private func attachScreen(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    /// Every fixture photo is an edit with an original. The More menu shows the original, marks it with a badge, and
    /// returns to the edited version.
    func testTheViewerShowsTheOriginalOfAnEditedPhotoAndTheEditAgain() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the viewer did not open")

        let more = app.viewerMoreButton
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

    func testSelectingPhotosShowsTheirActionsAndDoneEndsTheSelection() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let column = try app.verticalTabColumn()
        app.buttons["Select"].tap()
        let selectedPhoto = try app.visiblePhoto(beside: column)
        selectedPhoto.tap()

        XCTAssertTrue(wait(for: selectedPhoto, "isSelected == true"), "the tapped photo is not selected")
        XCTAssertTrue(app.buttons["Share selected items"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move selected items to Trash"].isEnabled)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: selectedPhoto, "isSelected == false"), "Done must clear the selection")
    }

    func testSelectionAppearsOnlyOnPhotoGrids() {
        func capture(_ phase: String) {
            let ax = XCTAttachment(string: app.debugDescription)
            ax.name = "Grid selection AX " + phase
            ax.lifetime = .keepAlways
            add(ax)

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Grid selection screen " + phase
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        func tapVisibleCenter(_ element: XCUIElement, name: String) -> Bool {
            XCTAssertTrue(element.exists, "\(name) must exist")
            guard element.exists else { return false }

            let frame = element.frame
            let window = app.windows.firstMatch.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let safePoint = !frame.isEmpty && window.contains(center)
            XCTAssertTrue(safePoint, "\(name) center must be inside the window")
            guard safePoint else { return false }

            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }

        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "Library grid must load")
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 10), "Library must offer Select")
        app.tab(titled: "Search").tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search field must open")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "Search must show the keyboard")
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)).tap()
            XCTAssertTrue(wait(for: keyboard, "exists == false", timeout: 10), "Keyboard must close")
        }

        XCTAssertTrue(app.staticTexts["For You"].waitForExistence(timeout: 30), "Suggestions must be visible")
        XCTAssertTrue(wait(for: firstPhoto, "exists == false", timeout: 10), "Suggestions must replace the grid")
        let suggestion = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Spring 2026'")
        ).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "Fixture suggestion must be present")
        capture("suggestions")
        XCTAssertFalse(app.buttons["Select"].exists, "Suggestions must not offer Select")

        guard tapVisibleCenter(suggestion, name: "Suggestion") else { return }
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 30), "Suggestion must show a photo grid")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 10), "Result grid must offer Select")
        }
        capture("results")

        if UIDevice.current.userInterfaceIdiom == .phone {
            let submit = keyboard.buttons["Search"]
            XCTAssertTrue(submit.waitForExistence(timeout: 10), "Keyboard Search must exist")
            submit.tap()
            XCTAssertTrue(wait(for: keyboard, "exists == false", timeout: 10), "Keyboard must close")
        }
        XCTAssertFalse(keyboard.exists, "The keyboard must not cover the Library tap")
        guard !keyboard.exists else { return }
        let library = app.tab(titled: "Library")
        guard tapVisibleCenter(library, name: "Library tab") else { return }
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 30), "Library grid must return")

        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10), "Library must still offer Select")
        guard tapVisibleCenter(select, name: "Select") else { return }
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Selection must offer Done")
        guard tapVisibleCenter(done, name: "Done") else { return }
        XCTAssertTrue(select.waitForExistence(timeout: 10), "Done must end selection")
        capture("library")
    }

    func testTabsSwitchToCollectionsBackToTheLibraryAndToSearch() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))

        app.tab(titled: "Collections").tap()
        XCTAssertTrue(
            wait(for: firstPhoto, "exists == false", timeout: 20), "the library grid stays visible under Collections")

        app.tab(titled: "Library").tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")

        // The search tab turns the tab bar into a search field, so it comes last.
        app.tab(titled: "Search").tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search shows no search field")
    }

    func testSearchTabActivatesAndReturnsToLibrary() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.tab(titled: "Search").tap()
        let field = app.searchFields.firstMatch
        let fieldExists = field.waitForExistence(timeout: 10)
        XCTAssertTrue(fieldExists, "Search tab must show a search field")
        guard fieldExists else { return }
        let keyboard = app.keyboards.firstMatch
        let keyboardExists = keyboard.waitForExistence(timeout: 10)
        XCTAssertTrue(keyboardExists, "Search tab must focus the keyboard")
        guard keyboardExists else { return }
        if UIDevice.current.userInterfaceIdiom == .phone {
            field.typeText("Spring")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let openScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            openScreenshot.name = "Search open with keyboard"
            openScreenshot.lifetime = .keepAlways
            add(openScreenshot)
            let valueBeforeOutsideTap = field.value as? String
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)).tap()
            XCTAssertTrue(wait(for: keyboard, "exists == false", timeout: 10), "Outside tap must hide keyboard")
            XCTAssertTrue(field.exists, "Search field must remain after the outside tap")
            XCTAssertEqual(field.value as? String, valueBeforeOutsideTap, "Outside tap must not change the search text")
            XCTAssertFalse(app.buttons["Close"].exists, "Outside tap must not open the viewer")
            let search = app.tab(titled: "Search")
            XCTAssertTrue(search.exists && search.isSelected, "Search tab must remain selected after outside tap")
            let outsideScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            outsideScreenshot.name = "Search after outside tap"
            outsideScreenshot.lifetime = .keepAlways
            add(outsideScreenshot)
            let ax = XCTAttachment(string: app.debugDescription)
            ax.name = "Search dismissal hierarchy"
            ax.lifetime = .keepAlways
            add(ax)
            let library = app.tab(titled: "Library")
            XCTAssertTrue(library.exists, "Library tab must exist to end search")
            guard library.exists else { return }
            let frame = library.frame
            let window = app.windows.firstMatch.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let safePoint = !frame.isEmpty && window.contains(point)
            XCTAssertTrue(safePoint, "Library tap point must be inside the window")
            guard safePoint else { return }
            library.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(wait(for: library, "isSelected == true", timeout: 10), "Library must be selected")
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), "Native search Close must exist")
            XCTAssertEqual(app.buttons.matching(identifier: "Close").count, 1, "Close must be unique")
            let frame = close.frame
            let window = app.windows.firstMatch.frame
            let keyboardFrame = keyboard.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let ax = XCTAttachment(string: app.debugDescription)
            ax.name = "Search close hierarchy"
            ax.lifetime = .keepAlways
            add(ax)
            XCTAssertTrue(!frame.isEmpty && window.contains(point), "Close center must be in the window")
            XCTAssertFalse(keyboardFrame.contains(point), "Close center must be outside the keyboard")
            XCTAssertFalse(field.frame.contains(point), "Close center must be outside the text field")
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            XCTFail("Unsupported device idiom for search dismissal")
            return
        }
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "Library did not return")
        XCTAssertTrue(wait(for: app.searchFields.firstMatch, "exists == false", timeout: 10), "Search field remains")
        app.tab(titled: "Search").tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search must reactivate")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Search must refocus the keyboard")
    }

    /// The end of the search suggestions scrolls clear of the bottom search field, so the Smart Search hint can be read
    /// with the keyboard up and with the keyboard down.
    func testTheSmartSearchHintScrollsAboveTheSearchField() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.tab(titled: "Search").tap()
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

    func testReturningFromBackgroundRestoresTheViewerWithPreviewProtection() throws {
        app.terminate()
        app.launchArguments += ["-EncryptedMemories.blurAppPreview", "YES"]
        app.launch()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
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

        app.backButton(to: "Settings").tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Blur App Preview"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(initialValue)'"))
    }

    func testPrivacySwitchHidesTheMapTab() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        let geometry = XCTAttachment(string: app.debugDescription)
        geometry.name = "Map tab role and bar geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let mapTab = try app.verifiedTab(titled: "Map")
        let libraryTab = try app.verifiedTab(titled: "Library")
        XCTAssertTrue(mapTab.exists)

        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let mapSwitch = app.switches["Map and Places"]
        XCTAssertTrue(mapSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(mapSwitch.value as? String, "1")
        mapSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: mapSwitch, "value == '0'"))
        app.backButton(to: "Settings").tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(wait(for: mapTab, "exists == false", timeout: 20))
        XCTAssertTrue(libraryTab.exists)
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

        app.backButton(to: "Settings").tap()
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
