import XCTest

/// Exercises the system's actual bar layout, without identifying a device or changing its pose.
final class MobileVerticalBarsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    func testPhotosStayBesideAVerticalBarInTheLibrary() throws {
        let column = try requireVerticalTabColumn()
        assertPhotosStayBeside(column, named: "Library beside the vertical bar")
    }

    func testPhotosStayBesideAVerticalBarInSelection() throws {
        let column = try requireVerticalTabColumn()
        let select = app.barButton(titled: "Select")
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        XCTAssertTrue(app.barButton(titled: "Done").waitForExistence(timeout: 10))
        assertPhotosStayBeside(column, named: "Selection beside the vertical bar")
    }

    private func requireVerticalTabColumn() throws -> CGRect {
        waitForPhotos()
        guard let column = try app.verticalTabColumn() else {
            throw XCTSkip("This geometry check requires the system to present the tabs vertically")
        }
        return column
    }

    func testSelectAndDoneStayReachableAndDoneLeadsTheVerticalTabs() throws {
        waitForPhotos()
        let column = try app.verticalTabColumn()
        let select = app.barButton(titled: "Select")
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        keepGeometryEvidence(named: "Select before entering selection")
        print("[Vertical bar] Select frame=\(select.frame) enabled=\(select.isEnabled) hittable=\(select.isHittable)")
        if let column {
            XCTAssertEqual(
                select.frame.midX, column.midX, accuracy: 2, "Select must stay inside the vertical bar column")
        }
        select.tap()

        let done = app.barButton(titled: "Done")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        if let column {
            XCTAssertEqual(done.frame.midX, column.midX, accuracy: 2, "Done must stay inside the vertical bar column")
            XCTAssertLessThanOrEqual(done.frame.maxY, column.minY, "Done must lead the tabs")
        }
        done.tap()
        XCTAssertTrue(select.waitForExistence(timeout: 10), "Done did not end selection")
    }

    func testTheViewerKeepsCloseAboveItsVerticalActionsAndClosesAgain() throws {
        waitForPhotos()
        let column = try app.verticalTabColumn()
        let photo = try app.visiblePhoto(beside: column)
        photo.tap()

        let close = app.barButton(titled: "Close")
        let share = app.barButton(titled: "Share")
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The viewer did not open")
        XCTAssertTrue(share.waitForExistence(timeout: 10), "The viewer has no Share action")
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(share.isHittable)
        if column != nil {
            XCTAssertEqual(close.frame.midX, share.frame.midX, accuracy: 2)
            XCTAssertLessThanOrEqual(close.frame.maxY, share.frame.minY, "Close must lead the viewer actions")
        }
        close.tap()
        waitForPhotos()
        XCTAssertTrue(app.barButton(titled: "Select").exists, "Close did not return to the library")
    }

    func testSettingsDoneRemainsReachableOnEitherBarAxis() {
        waitForPhotos()
        let settings = app.barButton(titled: "Proton Account and Settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let done = app.barButton(titled: "Done")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.barButton(titled: "Select").waitForExistence(timeout: 10))
    }

    func testAlbumCreationKeepsCancelAndCreateReachable() {
        waitForPhotos()
        app.tab(titled: "Collections").tap()
        let newAlbum = app.barButton(titled: "Create Album")
        XCTAssertTrue(newAlbum.waitForExistence(timeout: 10))
        newAlbum.tap()
        let createEntry = app.collectionViews.buttons["Create Album"].firstMatch
        XCTAssertTrue(createEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(createEntry.isEnabled)
        createEntry.tap()
        let name = app.textFields["Album name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let cancel = app.barButton(titled: "Cancel")
        let create = app.barButton(titled: "Create")
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(create.exists)
        XCTAssertFalse(create.isEnabled)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        newAlbum.tap()
        XCTAssertTrue(createEntry.waitForExistence(timeout: 10))
        createEntry.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Toolbar Album")
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(create.isHittable)
        create.tap()
        let createdDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [createdDismissed], timeout: 10), .completed)
        let createdAlbum = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Toolbar Album'")).firstMatch
        // Collections creates album rows lazily, below the smart categories on a short display.
        for _ in 0..<4 where !createdAlbum.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(createdAlbum.waitForExistence(timeout: 10), "Create did not add the album")
    }

    func testAlbumPickerCancelKeepsTheViewerOpen() throws {
        waitForPhotos()
        try app.visiblePhoto(beside: app.verticalTabColumn()).tap()
        let addToAlbum = app.barButton(titled: "Add to Album")
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10))
        addToAlbum.tap()
        let cancel = app.barButton(titled: "Cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(
            app.barButton(titled: "Close").waitForExistence(timeout: 10), "Cancel did not return to the viewer")
        XCTAssertTrue(addToAlbum.exists)
    }

    func testBugReportDoneReturnsToSettings() throws {
        waitForPhotos()
        app.barButton(titled: "Proton Account and Settings").tap()
        let report = app.barButton(titled: "Report a bug")
        for _ in 0..<5 where !report.exists || !report.isHittable { app.swipeUp() }
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        report.tap()
        XCTAssertTrue(app.barButton(titled: "Download support file").waitForExistence(timeout: 10))
        // Settings also has Done behind this sheet. Choose the button in the presented surface.
        let done = try XCTUnwrap(
            app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.first {
                $0.isHittable
            }, "The report sheet has no reachable Done")
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(report.waitForExistence(timeout: 10), "Done did not return to Settings")
    }

    /// The viewer keeps the area behind a vertical bar black instead of extending the photo into it (#924).
    func testTheViewerKeepsTheAreaBehindAVerticalBarBlack() throws {
        let column = try requireVerticalTabColumn()
        try app.visiblePhoto(beside: column).tap()
        XCTAssertTrue(app.barButton(titled: "Close").waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let barIsTrailing = column.midX > window.midX
        let edge = CGPoint(x: barIsTrailing ? window.maxX - 2 : window.minX + 2, y: window.midY)
        let photo = CGPoint(
            x: barIsTrailing ? (window.minX + column.minX) / 2 : (column.maxX + window.maxX) / 2, y: window.midY)
        // Check the edge only after the photo shows, so that a black frame before the photo cannot pass.
        var readError: Error?
        let photoShows = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                do {
                    let pixel = try self.app.screenshotPixel(at: photo, in: window)
                    return pixel.prefix(3).max() ?? 0 > 20
                } catch {
                    readError = error
                    return false
                }
            }, object: nil)
        let result = XCTWaiter.wait(for: [photoShows], timeout: 10)
        keepGeometryEvidence(named: "Viewer area behind the vertical bar")
        if let readError { throw readError }
        XCTAssertEqual(result, .completed, "SETUP: the viewer shows no photo")
        let pixel = try app.screenshotPixel(at: edge, in: window)
        XCTAssertLessThanOrEqual(pixel.prefix(3).max() ?? 255, 20, "The vertical bar shows the photo instead of black")
    }

    private var photos: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
    }

    private func waitForPhotos() {
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 60), "The library shows no photo")
    }

    private func assertPhotosStayBeside(_ column: CGRect, named name: String) {
        let window = app.windows.firstMatch.frame
        // Check every on-screen photo, including a clipped row. Do not exclude the overlapping column.
        let visible = photos.allElementsBoundByIndex.filter {
            let frame = $0.frame.intersection(window)
            return !frame.isNull && frame.width > 0 && frame.height > 0
        }
        keepGeometryEvidence(named: name)
        XCTAssertFalse(visible.isEmpty, "No visible photo was checked")
        for photo in visible {
            if column.midX > window.midX {
                XCTAssertLessThanOrEqual(photo.frame.maxX, column.minX + 1, "A photo extends under the vertical bar")
            } else {
                XCTAssertGreaterThanOrEqual(photo.frame.minX, column.maxX - 1, "A photo extends under the vertical bar")
            }
        }
    }

    private func keepGeometryEvidence(named name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + ": hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
