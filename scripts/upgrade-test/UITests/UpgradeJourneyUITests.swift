import CoreGraphics
import ImageIO
import XCTest

#if os(macOS)
    import AppKit
#endif

/// Drives the installed app. This target has no app dependency and cannot replace the historical app.
final class UpgradeJourneyUITests: XCTestCase {
    private lazy var app: XCUIApplication = {
        #if os(macOS)
            return XCUIApplication(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"]!))
        #else
            return XCUIApplication(bundleIdentifier: "at.oncloud.encryptedmemories.upgrade-test")
        #endif
    }()
    private static func switchIsEnabled(_ value: Any?) -> Bool {
        if let value = value as? String { return value == "1" }
        if let value, type(of: value) is NSNumber.Type, let number = value as? NSNumber {
            return number == NSNumber(value: 1)
        }
        return false
    }

    func testSwitchValueRequiresExactOne() {
        for value: Any in ["1", NSNumber(value: 1)] {
            XCTAssertTrue(Self.switchIsEnabled(value), "Enabled value rejected: \(value)")
        }
        let disabled: [Any?] = [
            "0", NSNumber(value: 0), nil, "01", "true", NSNumber(value: 2),
            NSNumber(value: 1.5), NSNull(), [1], NSObject(), 1, 1.0, true,
        ]
        for value in disabled {
            XCTAssertFalse(Self.switchIsEnabled(value), "Unexpected enabled value: \(String(describing: value))")
        }
    }

    private var point: String { ProcessInfo.processInfo.environment["UPGRADE_POINT"]! }
    private var verifiesUpgrade: Bool { ProcessInfo.processInfo.environment["UPGRADE_PHASE"] == "verify" }

    private func hasSyntheticPixels(_ png: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let width = 16
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: width, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: width))
            var matching = 0
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                let red = Int(buffer[offset])
                let green = Int(buffer[offset + 1])
                let blue = Int(buffer[offset + 2])
                if abs(green - 80) < 15 && abs(blue - 180) < 15 && (20...220).contains(red) {
                    matching += 1
                }
            }
            return matching > width * width / 2
        }
    }

    private func indexedSearchIsComplete(resultCount: Int, visiblePhotoPNG: Data) -> Bool {
        resultCount == 8 && hasSyntheticPixels(visiblePhotoPNG)
    }

    private func visiblePhoto(in photos: XCUIElementQuery) -> XCUIElement? {
        #if os(iOS)
            let window = app.windows.firstMatch.frame
            let top = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? window.minY
            return photos.allElementsBoundByIndex.first {
                !$0.frame.isEmpty && window.contains($0.frame) && $0.frame.minY > top
            }
        #else
            guard let windows = try? SettingsWindowPlacement.windows(), let pid = try? ownedProcessIdentifier(),
                let visible = try? SettingsWindowPlacement.visibleDisplay()
            else { return nil }
            return photos.allElementsBoundByIndex.first { photo in
                !photo.frame.isEmpty
                    && SettingsWindowPlacement.isClear(photo.frame, windows: windows, ownedPID: pid, visible: visible)
            }
        #endif
    }

    func testPendingSearchCannotUseTheRetainedLibrary() throws {
        let photo = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGNQCNhCU8QwasGoBaMWjFowasGoBaMW"
                    + "jFowasGoBaMWDBULAFr4kD3OWQ/uAAAAAElFTkSuQmCC"))
        let pendingOverlay = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAJklEQVR4nO3NMQ0AAAwDoPo33arYsQQMkB6LQCAQ"
                    + "CAQCgUAg+BIMi1X0pjxKe0gAAAAASUVORK5CYII="))
        XCTAssertFalse(
            indexedSearchIsComplete(resultCount: 8, visiblePhotoPNG: pendingOverlay),
            "Eight retained accessibility elements beneath an opaque loading overlay are not completed results")
        XCTAssertTrue(indexedSearchIsComplete(resultCount: 8, visiblePhotoPNG: photo))
        for count in [0, 7, 9] {
            XCTAssertFalse(indexedSearchIsComplete(resultCount: count, visiblePhotoPNG: photo))
        }
    }

    /// Query the native search surface to prove that all eight saved index entries are usable.
    private func verifyIndexedSearchResults() throws {
        #if os(iOS)
            app.navigationBars.buttons.firstMatch.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            done.tap()
            app.tabBars.buttons["Search"].tap()
        #else
            app.typeKey("w", modifierFlags: .command)
        #endif
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The native search field is missing")
        #if os(macOS)
            try clickUncovered(search, name: "search field")
        #else
            search.tap()
        #endif
        search.typeText("fixture query\n")
        let results = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        let indexed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard results.count == 8, let photo = self.visiblePhoto(in: results) else { return false }
                return self.indexedSearchIsComplete(
                    resultCount: results.count, visiblePhotoPNG: photo.screenshot().pngRepresentation)
            }, object: nil)
        let result = XCTWaiter.wait(for: [indexed], timeout: 60)
        for attachment in [XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription)] {
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, "The saved index did not return all eight photos")
    }

    #if os(macOS)
        func testForeignWindowDragUncoversOnlyTheTargetWithSafePressAndRelease() throws {
            let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
            let frame = CGRect(x: 232, y: 94, width: 560, height: 608)
            let tab = CGRect(x: 565, y: 126, width: 55, height: 56)
            let settings = SettingsWindowPlacement.Window(pid: 1, layer: 0, frame: frame)
            let dialog = SettingsWindowPlacement.Window(
                pid: 2, layer: 8, frame: CGRect(x: 382, y: 118, width: 260, height: 250))
            for layer in [0, 8] {
                let window = SettingsWindowPlacement.Window(pid: 2, layer: layer, frame: dialog.frame)
                XCTAssertEqual(SettingsWindowPlacement.obstacles([window], ownedPID: 1).count, 1)
            }
            for layer in [-1, 9, 20, 1000] {
                let surface = SettingsWindowPlacement.Window(pid: 2, layer: layer, frame: screen)
                XCTAssertTrue(SettingsWindowPlacement.obstacles([surface], ownedPID: 1).isEmpty)
            }
            XCTAssertTrue(SettingsWindowPlacement.obstacles([settings], ownedPID: 1).isEmpty)
            let transparent = SettingsWindowPlacement.Window(pid: 2, layer: 8, alpha: 0, frame: screen)
            let offscreen = SettingsWindowPlacement.Window(pid: 2, layer: 8, isOnscreen: false, frame: screen)
            XCTAssertTrue(SettingsWindowPlacement.obstacles([transparent, offscreen], ownedPID: 1).isEmpty)

            let usable = CGRect(x: 8, y: 32, width: 1008, height: 728)
            let front = SettingsWindowPlacement.Window(pid: 2, layer: 8, frame: dialog.frame, order: 0)
            let owned = SettingsWindowPlacement.Window(pid: 1, layer: 0, frame: frame, order: 1)
            let behind = SettingsWindowPlacement.Window(pid: 3, layer: 0, frame: screen, order: 2)
            XCTAssertEqual(
                SettingsWindowPlacement.covering(tab, windows: [front, owned, behind], ownedPID: 1),
                [dialog.frame],
                "Only foreign windows in front of the owned window cover it")
            let stack = [front, owned, behind]
            XCTAssertFalse(SettingsWindowPlacement.isClear(tab, windows: stack, ownedPID: 1, visible: usable))
            let clearTab = tab.offsetBy(dx: 120, dy: 0)
            XCTAssertTrue(
                SettingsWindowPlacement.isClear(clearTab, windows: stack, ownedPID: 1, visible: usable),
                "A window behind the app must not count as covering")
            let outside = CGRect(x: 900, y: 720, width: 20, height: 20)
            XCTAssertNil(SettingsWindowPlacement.covering(outside, windows: [owned], ownedPID: 1))
            let narrow = screen.insetBy(dx: 400, dy: 0)
            XCTAssertFalse(SettingsWindowPlacement.isClear(clearTab, windows: stack, ownedPID: 1, visible: narrow))
            let plan = try XCTUnwrap(
                SettingsWindowPlacement.plan(
                    window: frame, target: tab, screen: screen, obstacles: [dialog.frame],
                    titleBarObstacles: [dialog.frame]))
            XCTAssertFalse(dialog.frame.contains(plan.start), "The drag must not press the system window")
            XCTAssertFalse(dialog.frame.contains(plan.end), "The drag must not release over the system window")
            XCTAssertTrue(SettingsWindowPlacement.titleBar(of: frame).contains(plan.start))
            XCTAssertTrue(SettingsWindowPlacement.titleBar(of: plan.window).contains(plan.end))
            XCTAssertTrue(usable.contains(plan.target))
            XCTAssertFalse(plan.target.intersects(dialog.frame), "The complete tab must leave the dialog")
            XCTAssertEqual(
                plan.window.origin, CGPoint(x: 232, y: dialog.frame.maxY + SettingsWindowPlacement.clearance),
                "A position that keeps the whole window clear wins over a shorter shift")
            XCTAssertGreaterThanOrEqual(
                SettingsWindowPlacement.separation(plan.window, from: dialog.frame), SettingsWindowPlacement.clearance)
            let shortfall = plan.target.offsetBy(dx: 0, dy: -9)
            XCTAssertGreaterThanOrEqual(
                SettingsWindowPlacement.separation(shortfall, from: dialog.frame), 16,
                "A 9-point drag shortfall must leave the target at least 16 points outside the dialog")

            let button = CGRect(x: frame.minX + 28, y: frame.minY + 168, width: 400, height: 22)
            let lower = try XCTUnwrap(
                SettingsWindowPlacement.plan(
                    window: frame, target: button, screen: screen, obstacles: [dialog.frame],
                    titleBarObstacles: [dialog.frame]))
            XCTAssertEqual(lower.window.minY, dialog.frame.maxY + SettingsWindowPlacement.clearance)
            XCTAssertFalse(lower.target.intersects(dialog.frame))
            XCTAssertTrue(usable.contains(lower.target))
            XCTAssertTrue(usable.contains(SettingsWindowPlacement.titleBar(of: lower.window)))
            XCTAssertGreaterThan(lower.window.maxY, screen.maxY, "Only the window bottom may leave the display")

            let pillar = CGRect(x: 382, y: 0, width: 260, height: 768)
            let beside = try XCTUnwrap(
                SettingsWindowPlacement.plan(
                    window: frame, target: tab, screen: screen, obstacles: [pillar], titleBarObstacles: [pillar]))
            XCTAssertEqual(beside.target.minX, pillar.maxX + SettingsWindowPlacement.clearance)
            XCTAssertFalse(pillar.contains(beside.start))
            XCTAssertFalse(pillar.contains(beside.end))

            let releaseBlocker = CGRect(x: 500, y: 405, width: 24, height: 12)
            let safeRelease = try XCTUnwrap(
                SettingsWindowPlacement.plan(
                    window: frame, target: tab, screen: screen, obstacles: [dialog.frame],
                    titleBarObstacles: [dialog.frame, releaseBlocker]))
            XCTAssertFalse(releaseBlocker.contains(safeRelease.start))
            XCTAssertFalse(releaseBlocker.contains(safeRelease.end))

            XCTAssertNil(
                SettingsWindowPlacement.plan(
                    window: frame, target: tab, screen: screen, obstacles: [], titleBarObstacles: []))
            let docked = CGRect(x: 232, y: 300, width: 560, height: 608)
            let toggle = CGRect(x: 700, y: 740, width: 40, height: 22)
            let raised = try XCTUnwrap(
                SettingsWindowPlacement.plan(
                    window: docked, target: toggle, screen: screen, obstacles: [], titleBarObstacles: []))
            XCTAssertTrue(usable.contains(raised.target), "A target behind the Dock must move into the visible area")
            XCTAssertNil(
                SettingsWindowPlacement.plan(
                    window: frame, target: tab, screen: screen, obstacles: [screen], titleBarObstacles: []))
            XCTAssertNil(
                SettingsWindowPlacement.plan(
                    window: frame, target: tab, screen: screen, obstacles: [dialog.frame],
                    titleBarObstacles: [screen]))
        }

        func testFailureIssueCarriesTheAppHierarchy() {
            let issue = XCTIssue(type: .assertionFailure, compactDescription: "fixture failure")
            let recorded = Self.issue(issue, withHierarchy: "Window, title: 'Settings'")
            XCTAssertEqual(recorded.attachments.map(\.name), ["App UI hierarchy - failure"])
            XCTAssertEqual(recorded.attachments.first?.lifetime, .keepAlways)
            XCTAssertEqual(recorded.compactDescription, "fixture failure")
        }

        static func issue(_ issue: XCTIssue, withHierarchy hierarchy: String) -> XCTIssue {
            var issue = issue
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "App UI hierarchy - failure"
            attachment.lifetime = .keepAlways
            issue.add(attachment)
            return issue
        }

        /// Every failing journey keeps the app hierarchy, including errors thrown before an assertion.
        override func record(_ issue: XCTIssue) {
            guard !recordsFailureHierarchy, ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"] != nil,
                [.runningForeground, .runningBackground].contains(app.state)
            else { return super.record(issue) }
            recordsFailureHierarchy = true
            defer { recordsFailureHierarchy = false }
            super.record(Self.issue(issue, withHierarchy: app.debugDescription))
        }
    #endif

    #if os(macOS)
        private var recordsFailureHierarchy = false

        private func ownedProcessIdentifier() throws -> Int32 {
            let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["UPGRADE_APP_PATH"])
            let ownedURL = URL(fileURLWithPath: appPath).standardizedFileURL
            let instances = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == ownedURL
            }
            guard instances.count == 1, let instance = instances.first else {
                throw SettingsWindowPlacement.failure("The exact owned app instance is missing or ambiguous")
            }
            return instance.processIdentifier
        }

        /// Clicks an owned control only while no foreign window covers it; it never sends input to that window.
        private func clickUncovered(_ control: XCUIElement, name: String) throws {
            guard
                SettingsWindowPlacement.isClear(
                    control.frame, windows: try SettingsWindowPlacement.windows(),
                    ownedPID: try ownedProcessIdentifier(),
                    visible: try SettingsWindowPlacement.visibleDisplay())
            else {
                throw SettingsWindowPlacement.failure(
                    "A foreign window, the menu bar or the Dock covers the \(name) control")
            }
            control.click()
        }

        /// Drags the owned window by an uncovered title-bar point until no foreign window covers the target.
        @MainActor
        private func uncover(_ target: XCUIElement, in window: XCUIElement, name: String) throws {
            let pid = try ownedProcessIdentifier()
            let visible = try SettingsWindowPlacement.visibleDisplay()
            for attempt in 1...2 {
                let windows = try SettingsWindowPlacement.windows()
                let matches = windows.filter {
                    $0.pid == pid && $0.layer == 0 && SettingsWindowPlacement.sameFrame($0.frame, window.frame)
                }
                guard matches.count == 1, let ownWindow = matches.first else {
                    throw SettingsWindowPlacement.failure("CoreGraphics did not identify the exact owned window")
                }
                let obstacles = SettingsWindowPlacement.obstacles(windows, ownedPID: pid).filter {
                    $0.order < ownWindow.order
                }
                let covered = obstacles.contains(where: { $0.frame.intersects(target.frame) })
                guard covered || !visible.contains(target.frame) else { break }
                SettingsWindowPlacement.log(
                    "before \(name) placement \(attempt)", windows: windows, window: window, target: target)
                retainHierarchy("before \(name) placement \(attempt)")
                let titleBarObstacles = windows.filter {
                    $0.order < ownWindow.order && SettingsWindowPlacement.isObstacleSurface($0)
                }.map(\.frame)
                guard
                    let plan = SettingsWindowPlacement.plan(
                        window: window.frame, target: target.frame,
                        screen: visible, obstacles: obstacles.map(\.frame),
                        titleBarObstacles: titleBarObstacles)
                else {
                    throw SettingsWindowPlacement.failure(
                        "No uncovered title-bar point or unobstructed on-screen \(name) position is available")
                }
                let origin = window.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(
                    CGVector(dx: plan.start.x - window.frame.minX, dy: plan.start.y - window.frame.minY))
                let end = origin.withOffset(
                    CGVector(dx: plan.end.x - window.frame.minX, dy: plan.end.y - window.frame.minY))
                start.click(forDuration: 0.5, thenDragTo: end)
                // Let the accessibility frame catch up with the moved window before the next measurement.
                let settled = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        (try? SettingsWindowPlacement.windows())?.contains(where: {
                            $0.pid == pid && $0.layer == 0
                                && SettingsWindowPlacement.sameFrame($0.frame, window.frame)
                        }) ?? false
                    }, object: nil)
                _ = XCTWaiter.wait(for: [settled], timeout: 3)
                SettingsWindowPlacement.log(
                    "after \(name) drag \(attempt)", windows: try SettingsWindowPlacement.windows(), window: window,
                    target: target)
                retainHierarchy("after \(name) drag \(attempt)")
            }
            let uncovered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard target.exists, target.isHittable, let current = try? SettingsWindowPlacement.windows()
                    else { return false }
                    return SettingsWindowPlacement.isClear(
                        target.frame, windows: current, ownedPID: pid, visible: visible)
                }, object: nil)
            guard XCTWaiter.wait(for: [uncovered], timeout: 10) == .completed else {
                throw SettingsWindowPlacement.failure("The \(name) control did not become uncovered and hittable")
            }
        }

        private func retainHierarchy(_ stage: String) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "App UI hierarchy - placement - " + stage
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    #endif

    #if os(macOS)
        @MainActor
    #endif
    func testInstalledAppJourney() throws {
        continueAfterFailure = false
        #if os(iOS)
            addUIInterruptionMonitor(withDescription: "Unexpected system UI in the synthetic journey") { _ in
                XCTFail("The synthetic journey requested system access instead of its offline input")
                return false
            }
        #endif
        #if os(macOS)
            let arguments = try XCTUnwrap(
                ProcessInfo.processInfo.environment["UPGRADE_APP_ARGUMENTS"]?.data(using: .utf8),
                "The owned app launch arguments are missing")
            app.launchArguments = try JSONDecoder().decode([String].self, from: arguments)
            app.launch()
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Library"].click()
            let larger = app.buttons["Larger thumbnails"]
            XCTAssertTrue(larger.waitForExistence(timeout: 60))
            try clickUncovered(larger, name: "Larger thumbnails")
        #else
            app.activate()
        #endif
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 60), "The saved account did not open its library")
        if point.hasPrefix("thumbnail.") {
            if verifiesUpgrade {
                let photos = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
                let visiblePhoto = try XCTUnwrap(
                    self.visiblePhoto(in: photos), "No complete photo tile is visible below the navigation bar")
                let rendered = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        self.hasSyntheticPixels(visiblePhoto.screenshot().pngRepresentation)
                    },
                    object: nil)
                let result = XCTWaiter.wait(for: [rendered], timeout: 60)
                for screenshot in [app.screenshot(), visiblePhoto.screenshot()] {
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(result, .completed, "The thumbnail did not render after the upgrade")
            }
            return
        }
        #if os(iOS)
            app.buttons["Proton Account and Settings"].tap()
            let title = point.hasPrefix("backup.") ? "Backup" : "Smart Search"
            let feature = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
            XCTAssertTrue(feature.waitForExistence(timeout: 10))
            feature.tap()
        #else
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "The Settings window is missing")
            // A foreign window can cover the window center; uncover() requires the tab itself to be hittable.
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in settings.exists && !settings.frame.isEmpty }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                "The Settings window did not appear")
            let title = point.hasPrefix("backup.") ? "Backup" : "Smart Search"
            let tab = settings.toolbars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            let acknowledged = {
                if title == "Backup" {
                    return tab.isSelected || settings.buttons["Enable Photos backup…"].exists
                        || settings.buttons["Turn off Photos backup"].exists
                }
                return settings.switches["smartsearch.toggle"].exists
            }
            app.activate()
            var placementError: Error?
            do {
                try SettingsPaneTestSupport.select(
                    title,
                    click: {
                        guard placementError == nil else { return }
                        do {
                            try self.uncover(tab, in: settings, name: title + " tab")
                            tab.click()
                        } catch { placementError = error }
                    },
                    isAcknowledged: { placementError == nil && acknowledged() },
                    waitForAcknowledgement: {
                        guard placementError == nil else { return false }
                        let selected = XCTNSPredicateExpectation(
                            predicate: NSPredicate { _, _ in acknowledged() }, object: nil)
                        return XCTWaiter.wait(for: [selected], timeout: 10) == .completed
                    })
            } catch { throw placementError ?? error }

        #endif
        if point.hasPrefix("backup.") {
            let enable = app.buttons["Enable Photos backup…"]
            if verifiesUpgrade {
                XCTAssertFalse(enable.exists, "The saved backup preference was lost")
                let settled = app.staticTexts["All files backed up"]
                XCTAssertTrue(settled.waitForExistence(timeout: 180), "Backup remains unfinished after the upgrade")
            } else {
                XCTAssertTrue(enable.waitForExistence(timeout: 10))
                #if os(macOS)
                    try uncover(enable, in: app.windows["Settings"], name: "Enable Photos backup")
                    enable.click()
                #else
                    enable.tap()
                #endif
            }
        } else {
            let toggle = app.switches["smartsearch.toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            if verifiesUpgrade {
                XCTAssertTrue(Self.switchIsEnabled(toggle.value), "The saved Smart Search preference was lost")
                XCTAssertTrue(
                    app.staticTexts["Smart Search is ready"].waitForExistence(timeout: 180),
                    "Smart Search did not resume its download and index")
                try verifyIndexedSearchResults()
            } else {
                #if os(macOS)
                    try uncover(toggle, in: app.windows["Settings"], name: "Smart Search switch")
                    toggle.click()
                #else
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                #endif
            }
        }
    }
}

#if os(macOS)
    enum SettingsWindowPlacement {
        struct Window {
            var pid: Int32
            var layer: Int
            var alpha: Double = 1
            var isOnscreen: Bool = true
            var frame: CGRect
            var order: Int = 0
            var owner: String = "unavailable"
        }

        struct Drag {
            var start: CGPoint
            var end: CGPoint
            var window: CGRect
            var target: CGRect
        }

        static func isObstacleSurface(_ window: Window) -> Bool {
            window.isOnscreen && window.alpha > 0 && window.layer >= 0
                && window.layer <= Int(CGWindowLevelForKey(.modalPanelWindow))
        }

        static func obstacles(_ windows: [Window], ownedPID: Int32) -> [Window] {
            windows.filter { $0.pid != ownedPID && isObstacleSurface($0) }
        }

        /// The main display area without the menu bar and Dock, in CoreGraphics top-left coordinates.
        static func visibleDisplay() throws -> CGRect {
            guard let screen = NSScreen.screens.first else { throw failure("AppKit reports no display") }
            let visible = screen.visibleFrame
            return CGRect(
                x: visible.minX, y: screen.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        }

        /// Foreign obstacles in front of the frontmost owned normal window that contains the target centre;
        /// nil when no owned window contains it. Windows behind the app never count as covering it.
        static func covering(_ target: CGRect, windows: [Window], ownedPID: Int32) -> [CGRect]? {
            let centre = CGPoint(x: target.midX, y: target.midY)
            guard
                let owner = windows.filter({ $0.pid == ownedPID && $0.layer == 0 && $0.frame.contains(centre) })
                    .min(by: { $0.order < $1.order })
            else { return nil }
            return obstacles(windows, ownedPID: ownedPID).filter { $0.order < owner.order }.map(\.frame)
        }

        static func isClear(_ target: CGRect, windows: [Window], ownedPID: Int32, visible: CGRect) -> Bool {
            guard !target.isEmpty, visible.contains(target),
                let covering = covering(target, windows: windows, ownedPID: ownedPID)
            else { return false }
            return !covering.contains(where: { $0.intersects(target) })
        }

        /// A window drag moves the window a few points less than the pointer; hosted runs measured up to 9 points.
        /// This distance keeps every target at least 16 points outside an obstacle after such a shortfall.
        static let clearance: CGFloat = 32

        static func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
                && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
        }

        static func titleBar(of window: CGRect) -> CGRect {
            CGRect(x: window.minX, y: window.minY, width: window.width, height: 32)
        }

        /// Distance by which `rect` lies outside `obstacle` along the best separating axis; negative when they overlap.
        static func separation(_ rect: CGRect, from obstacle: CGRect) -> CGFloat {
            max(
                rect.minX - obstacle.maxX, obstacle.minX - rect.maxX,
                rect.minY - obstacle.maxY, obstacle.minY - rect.maxY)
        }

        /// Plans a drag that moves a covered target at least `clearance` away from every obstacle. It prefers
        /// positions where the whole window keeps that distance, and otherwise the shortest move that clears the
        /// target. The title bar and the target stay in the visible display area without the menu bar and Dock;
        /// only the bottom of the window may leave it. Press and release avoid every window in front of the
        /// owned window and every obstacle.
        static func plan(
            window: CGRect, target: CGRect, screen: CGRect,
            obstacles: [CGRect], titleBarObstacles: [CGRect]
        ) -> Drag? {
            let usable = CGRect(
                x: screen.minX + 8, y: screen.minY + 32, width: screen.width - 16, height: screen.height - 40)
            guard !window.isEmpty, !target.isEmpty,
                obstacles.contains(where: { $0.intersects(target) }) || !usable.contains(target)
            else { return nil }
            let offset = CGPoint(x: target.minX - window.minX, y: target.minY - window.minY)
            var xs = [window.minX, usable.maxX - window.width, usable.minX]
            var ys = [window.minY, usable.minY]
            for obstacle in obstacles {
                xs += [
                    obstacle.maxX + clearance, obstacle.minX - clearance - window.width,
                    obstacle.maxX + clearance - offset.x, obstacle.minX - clearance - target.width - offset.x,
                ]
                ys += [
                    obstacle.maxY + clearance, obstacle.minY - clearance - window.height,
                    obstacle.maxY + clearance - offset.y, obstacle.minY - clearance - target.height - offset.y,
                ]
            }
            let candidates = ys.flatMap { y in xs.map { x in CGPoint(x: x, y: y) } }.sorted {
                let left = hypot($0.x - window.minX, $0.y - window.minY)
                let right = hypot($1.x - window.minX, $1.y - window.minY)
                return left != right ? left < right : ($0.y, $0.x) < ($1.y, $1.x)
            }
            let starts = [0.5, 0.25, 0.75, 0.4, 0.6].map {
                CGPoint(x: window.minX + window.width * $0, y: window.minY + 12)
            }
            let blocked = obstacles + titleBarObstacles
            for wholeWindowClear in [true, false] {
                for origin in candidates {
                    let moved = CGRect(origin: origin, size: window.size)
                    let movedTarget = target.offsetBy(dx: origin.x - window.minX, dy: origin.y - window.minY)
                    guard moved.minX >= usable.minX, moved.maxX <= usable.maxX,
                        usable.contains(titleBar(of: moved)), usable.contains(movedTarget),
                        obstacles.allSatisfy({ separation(movedTarget, from: $0) >= clearance }),
                        !wholeWindowClear || obstacles.allSatisfy({ separation(moved, from: $0) >= clearance })
                    else { continue }
                    for start in starts
                    where usable.contains(start) && !titleBarObstacles.contains(where: { $0.contains(start) }) {
                        let end = CGPoint(x: start.x + origin.x - window.minX, y: start.y + origin.y - window.minY)
                        if !blocked.contains(where: { $0.contains(end) }) {
                            return Drag(start: start, end: end, window: moved, target: movedTarget)
                        }
                    }
                }
            }
            return nil
        }

        static func windows() throws -> [Window] {
            guard let records = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            else { throw failure("CoreGraphics could not list on-screen windows") }
            return try records.enumerated().map { index, record in
                guard let pid = record[kCGWindowOwnerPID as String] as? NSNumber,
                    let layer = record[kCGWindowLayer as String] as? NSNumber,
                    let alpha = record[kCGWindowAlpha as String] as? NSNumber,
                    let onScreen = record[kCGWindowIsOnscreen as String] as? Bool,
                    let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { throw failure("CoreGraphics returned incomplete window geometry") }
                return Window(
                    pid: pid.int32Value, layer: layer.intValue, alpha: alpha.doubleValue,
                    isOnscreen: onScreen, frame: frame, order: index,
                    owner: record[kCGWindowOwnerName as String] as? String ?? "unavailable")
            }
        }

        static func log(_ stage: String, windows: [Window], window: XCUIElement, target: XCUIElement) {
            let facts: [String: Any] = [
                "stage": stage, "windowFrame": NSStringFromRect(window.frame),
                "point": ProcessInfo.processInfo.environment["UPGRADE_POINT"] ?? "",
                "phase": ProcessInfo.processInfo.environment["UPGRADE_PHASE"] ?? "",
                "targetFrame": NSStringFromRect(target.frame), "targetIsHittable": target.isHittable,
                "onScreenWindowsFrontToBack": windows.map {
                    [
                        "frontToBackIndex": $0.order, "ownerPID": $0.pid, "ownerName": $0.owner,
                        "layer": $0.layer, "alpha": $0.alpha, "isOnscreen": $0.isOnscreen,
                        "bounds": [
                            "X": $0.frame.minX, "Y": $0.frame.minY,
                            "Width": $0.frame.width, "Height": $0.frame.height,
                        ],
                    ] as [String: Any]
                },
            ]
            let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
            print("SETTINGS_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
        }

        static func failure(_ message: String) -> NSError {
            NSError(domain: "SettingsWindowPlacement", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
#endif
