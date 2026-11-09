import AppleSecurityCore
import MediaFeedCore
import PhotosCore
import ProtonAuth
import Security
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// Signed-in acceptance of several windows through the production composition, wherever the platform supports
/// several scenes.
///
/// The shared account runtime receives an isolated, deterministic library (`MobileSignedInFixture`). The scene
/// roots, tab shell, timeline screens, grids, selection, search, viewer and the ordered sign-out teardown are the
/// production ones. Real second window scenes are opened and closed through UIKit. Toolbar and tab actions use
/// public UIKit controls; photo selection and opening use the production grid's callbacks.
final class MobileSignedInMultiwindowTests: XCTestCase {
    private var report: [String] = []

    @MainActor func testTwoWindowsShareOneAccountAndKeepIndependentUIState() async throws {
        try await verifyTwoWindowLifecycle(explicitSignOut: false)
    }

    @MainActor func testExplicitSignOutPurgesBeforeTwoWindowsReconfigure() async throws {
        try XCTSkipUnless(UIApplication.shared.supportsMultipleScenes, "the runtime must support multiple scenes")
        // The canonical unsigned test host has no Keychain entitlement. Probe a unique, empty service so
        // this check never reads an account credential. A locally signed simulator host exercises the purge.
        do {
            _ = try SessionKeychainStore(service: "fixture-capability-" + UUID().uuidString).load()
        } catch let error as AppleSecurityError where error.status == errSecMissingEntitlement {
            throw XCTSkip("explicit Keychain purge requires a signed simulator test host (errSecMissingEntitlement)")
        }
        try await verifyTwoWindowLifecycle(explicitSignOut: true)
    }

    @MainActor private func verifyTwoWindowLifecycle(explicitSignOut: Bool) async throws {
        try XCTSkipUnless(
            UIApplication.shared.supportsMultipleScenes,
            "several windows of one app need iPadOS")
        let runtime = MobileAccountRuntime.shared
        let fixture = try await MobileSignedInFixture()
        defer {
            note(
                "cleanup: sessionSigningOut=\(runtime.sessionModel.isSigningOut) librarySigningOut=\(runtime.libraryModel.isSigningOut) cleanupFailed=\(runtime.libraryModel.signOutCleanupFailed) purgePending=\(BackupLocalDataPurge.isPurgePending()) sessionError=\(runtime.sessionModel.errorText ?? "none")"
            )
            fixture.clearSession()
            fixture.removeCache()
            writeReport()
        }
        let firstScene = try XCTUnwrap(
            windowScenes().first { $0.activationState == .foregroundActive } ?? windowScenes().first)
        let firstWindow = try XCTUnwrap(firstScene.keyWindow ?? firstScene.windows.first)
        let existingSessions = Set(windowScenes().map(\.session.persistentIdentifier))
        addTeardownBlock { @MainActor in
            // A thrown assertion must not leave fixture scenes active for the next suite.
            // A platform that refuses to close a scene keeps it; that refusal is not a test failure.
            for scene in self.windowScenes() where !existingSessions.contains(scene.session.persistentIdentifier) {
                if case .refused(let reason) = await MobileSceneCloser.close(scene) {
                    self.note("teardown: the platform kept a fixture scene: \(reason)")
                }
            }
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: firstScene.session))
            {
                error in XCTFail("original scene reactivation failed: \(error)")
            }
            try await self.waitUntil("original scene is active after teardown") {
                firstScene.activationState == .foregroundActive
            }
        }

        // 1. Signed-in production composition renders the shared library in the first window.
        fixture.install()
        let gridA = try await waitForGrid(in: firstWindow) {
            !$0.itemUIDs.isEmpty && $0.thumbnailFeed === fixture.feed
        }
        XCTAssertEqual(gridA.itemUIDs.count, fixture.items.count)
        XCTAssertTrue(gridA.thumbnailFeed === fixture.feed, "the grid must render the account's one feed")
        XCTAssertEqual(runtime.libraryModel.loadState, .contentReady(count: fixture.items.count))
        XCTAssertTrue(runtime.isStarted)
        note(
            "first window: production grid with \(gridA.itemUIDs.count) items, feed shared=\(gridA.thumbnailFeed === fixture.feed)"
        )
        snapshot(firstWindow, "signed-in-first-window")

        // 2. A real second window scene attaches to the same account and the same feed.
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication)) {
            XCTFail("second scene activation failed: \($0)")
        }
        let secondScene = try await waitForScene(notIn: existingSessions)
        let secondWindow = try await waitForWindow(in: secondScene)
        let gridB = try await waitForGrid(in: secondWindow)
        XCTAssertFalse(gridA === gridB, "each window hosts its own grid")
        XCTAssertTrue(gridB.thumbnailFeed === fixture.feed, "both windows share one thumbnail feed")
        XCTAssertTrue(gridB.thumbnailFeed?.feedCore === gridA.thumbnailFeed?.feedCore)
        XCTAssertTrue(MobileAccountRuntime.shared.libraryModel === runtime.libraryModel)
        try await waitUntil("both window scenes reach the shared activity ledger") {
            runtime.sceneLedger.phase(of: firstScene.session.persistentIdentifier) != nil
                && runtime.sceneLedger.phase(of: secondScene.session.persistentIdentifier) != nil
        }
        XCTAssertGreaterThanOrEqual(runtime.sceneLedger.sceneCount, 2)
        try await waitUntil("one window scene becomes active after the open transition") {
            windowScenes().contains { $0.activationState == .foregroundActive }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(runtime.appliedOpportunity, .foregroundActive)
        note("after open: first=\(name(firstScene.activationState)) second=\(name(secondScene.activationState))")
        snapshot(secondWindow, "signed-in-second-window")

        // 3. Hidden-scene probe (DUO-CR-2): while the first scene is in the background and the second is active,
        //    a thumbnail arrival must not make the hidden grid tick, decode or warm. Reactivation resumes it.
        if firstScene.activationState == .background {
            let ticksBefore = gridA.renderTickCount
            gridA.handleImagesAvailable()
            try await Task.sleep(for: .milliseconds(800))
            let ticksAfter = gridA.renderTickCount
            note(
                "hidden first-scene grid: ticks before=\(ticksBefore) after=\(ticksAfter) active=\(gridA.framePump.isActive)"
            )
            XCTAssertEqual(ticksAfter, ticksBefore, "a grid in a background scene must not run render/warm ticks")
            XCTAssertEqual(runtime.appliedOpportunity, .foregroundActive, "the visible window keeps the account active")
            XCTAssertEqual(runtime.sceneLedger.phase(of: firstScene.session.persistentIdentifier), .background)
        } else {
            note("hidden-scene probe skipped: first scene state \(name(firstScene.activationState))")
        }

        // 4. Independent UI state: scroll, selection and search live per window; the account stays one.
        //    Interactions happen in whichever window is on screen; the other keeps its own state untouched.
        let (frontWindow, frontGrid, backGrid) =
            secondScene.activationState == .foregroundActive
            ? (secondWindow, gridB, gridA) : (firstWindow, gridA, gridB)
        backGrid.scrollView.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        frontGrid.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotEqual(frontGrid.scrollView.contentOffset.y, backGrid.scrollView.contentOffset.y)
        XCTAssertNotEqual(frontGrid.currentScrollAnchor()?.itemID, backGrid.currentScrollAnchor()?.itemID)

        try await activate(label: L10n.string("action.select"), in: frontWindow)
        try await waitUntil("front grid enters selection mode") { frontGrid.selectionMode }
        frontGrid.onToggleSelection?(fixture.items[3])
        frontGrid.onToggleSelection?(fixture.items[4])
        try await waitUntil("front grid shows two selected photos") { frontGrid.selectedUIDs.count == 2 }
        XCTAssertFalse(backGrid.selectionMode, "selection mode belongs to one window")
        XCTAssertTrue(backGrid.selectedUIDs.isEmpty)
        snapshot(frontWindow, "front-window-selection")
        try await activate(label: L10n.string("action.done"), in: frontWindow)
        try await waitUntil("front grid leaves selection mode") { !frontGrid.selectionMode }

        // 5. Search in the front window filters only that window's search surface.
        try await selectTab(.search, in: frontWindow)
        let searchField = try await waitForSearchField(in: frontWindow)
        setSearchText("beta", in: searchField)
        let frontSearchGrid = try await waitForGrid(in: frontWindow) { grid in
            grid !== frontGrid && grid.itemUIDs.count == fixture.sections[1].items.count
        }
        XCTAssertTrue(frontSearchGrid.itemUIDs.allSatisfy { $0.nodeID.hasPrefix("beta-") })
        XCTAssertTrue(frontSearchGrid.thumbnailFeed === fixture.feed, "search renders through the same feed")
        XCTAssertEqual(backGrid.itemUIDs.count, fixture.items.count, "the other window keeps the full library")
        note(
            "front search 'beta' -> \(frontSearchGrid.itemUIDs.count) items; back window still \(backGrid.itemUIDs.count)"
        )
        snapshot(frontWindow, "front-window-search")
        setSearchText("", in: searchField)
        try await selectTab(.photos, in: frontWindow)
        try await waitUntil("front window returns to the photos grid") { frontGrid.window != nil }

        // 6. Viewer belongs to one window; Escape/close returns to the grid of that window only.
        frontGrid.onOpenPhoto?(fixture.items[7])
        try await waitUntil("front window presents the viewer") {
            frontWindow.rootViewController?.presentedViewController != nil
        }
        let otherWindow = frontWindow === firstWindow ? secondWindow : firstWindow
        XCTAssertNil(otherWindow.rootViewController?.presentedViewController, "the viewer belongs to one window")
        snapshot(frontWindow, "front-window-viewer")

        // 7. Sign-out with the viewer open tears the account down through the production path. The account state
        //    clears at once; the on-screen window drops its viewer and grid. A window in a background scene refreshes
        //    its hierarchy when it returns to the foreground (checked in step 9).
        if explicitSignOut {
            runtime.sessionModel.signOut()
        } else {
            fixture.clearSession()
        }
        try await waitUntil("account state clears after sign-out") {
            runtime.sessionModel.session == nil && runtime.libraryModel.thumbnailFeed == nil
                && runtime.libraryModel.loadState == .initial
        }
        try await waitUntil("the visible window leaves the library after sign-out") {
            grids(in: frontWindow).isEmpty && frontWindow.rootViewController?.presentedViewController == nil
        }
        if explicitSignOut {
            try await waitUntil("explicit sign-out finishes account cleanup") {
                !runtime.sessionModel.isSigningOut && !runtime.libraryModel.isSigningOut
                    && !runtime.libraryModel.signOutCleanupFailed
            }
            XCTAssertFalse(BackupLocalDataPurge.isPurgePending(), "successful purge clears the durable request")
        }
        XCTAssertEqual(fixture.feed.feedCore.activeUserInteractionOwnerCount(), 0, "no orphaned interaction owner")
        note(
            "sign-out: grids first=\(grids(in: firstWindow).count) second=\(grids(in: secondWindow).count) states first=\(name(firstScene.activationState)) second=\(name(secondScene.activationState))"
        )
        snapshot(frontWindow, "front-window-signed-out")

        // 8. Reconfiguring the same account restores both windows without a second runtime.
        fixture.install()
        let gridA2 = try await waitForGrid(in: firstWindow)
        let gridB2 = try await waitForGrid(in: secondWindow)
        XCTAssertTrue(gridA2.thumbnailFeed === fixture.feed)
        XCTAssertTrue(gridB2.thumbnailFeed === fixture.feed)
        XCTAssertTrue(MobileAccountRuntime.shared === runtime)
        XCTAssertTrue(runtime.isStarted)

        // 9. Closing the second window keeps the account; reopening a window attaches again.
        //    A closed window can be checked only where the platform closes the scene; the platform's answer
        //    decides, never the device idiom.
        let secondID = secondScene.session.persistentIdentifier
        switch await MobileSceneCloser.close(secondScene) {
        case .closed:
            try await waitUntil("closed window leaves the ledger") {
                runtime.sceneLedger.phase(of: secondID) == nil
            }
        case .refused(let reason):
            note("the platform kept the second scene, ledger departure not checked: \(reason)")
        }
        XCTAssertNotNil(runtime.libraryModel.thumbnailFeed, "closing a window must not sign the account out")
        XCTAssertTrue(runtime.isStarted)
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: firstScene.session)) {
            XCTFail("first scene re-activation failed: \($0)")
        }
        try await waitUntil("first scene returns to the foreground") {
            firstScene.activationState == .foregroundActive
        }
        // Reactivated window refreshes: it shows exactly one live grid of the reconfigured account and an arrival
        // wake ticks again.
        try await waitUntil("reactivated window shows the reconfigured library") {
            grids(in: firstWindow).count == 1 && grids(in: firstWindow).first?.thumbnailFeed === fixture.feed
        }
        // The window may rebuild its grid while the scene returns. Wake whichever grid the window shows now, and
        // count its ticks from the moment it appears.
        var probe = try XCTUnwrap(grids(in: firstWindow).first)
        var resumedBefore = probe.renderTickCount
        try await waitUntil("reactivated grid renders again") {
            guard let current = grids(in: firstWindow).first(where: { $0.thumbnailFeed === fixture.feed }) else {
                return false
            }
            if current !== probe {
                probe = current
                resumedBefore = current.renderTickCount
            }
            current.handleImagesAvailable()
            return current.renderTickCount > resumedBefore
        }
        note("reactivated first window: grid renders again (ticks \(resumedBefore) -> \(probe.renderTickCount))")
        let reopened = Set(windowScenes().map(\.session.persistentIdentifier))
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication)) {
            XCTFail("third scene activation failed: \($0)")
        }
        let thirdScene = try await waitForScene(notIn: reopened)
        let thirdWindow = try await waitForWindow(in: thirdScene)
        let gridC = try await waitForGrid(in: thirdWindow)
        XCTAssertTrue(gridC.thumbnailFeed === fixture.feed, "a reopened window attaches to the same account")
        note("reopened window renders \(gridC.itemUIDs.count) items from the shared feed")
        switch await MobileSceneCloser.close(thirdScene) {
        case .closed:
            try await waitUntil("reopened window leaves the ledger") {
                runtime.sceneLedger.phase(of: thirdScene.session.persistentIdentifier) == nil
            }
        case .refused(let reason):
            note("the platform kept the reopened scene, ledger departure not checked: \(reason)")
        }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: firstScene.session)) {
            _ in
        }
        try await waitUntil("first scene is active again") { firstScene.activationState == .foregroundActive }
        // The shared ledger follows the scene's phase asynchronously, and a scene the platform kept reports too.
        try await waitUntil("the account follows the active window") { runtime.appliedOpportunity == .foregroundActive }
    }

    // MARK: - Helpers

    private func note(_ line: String) {
        report.append(line)
    }

    private func name(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive: "foregroundActive"
        case .foregroundInactive: "foregroundInactive"
        case .background: "background"
        case .unattached: "unattached"
        @unknown default: "unknown"
        }
    }

    @MainActor private func windowScenes() -> [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func grids(in window: UIWindow) -> [UIKitTimelineGridHostView] {
        var roots: [UIView] = [window]
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            roots.append(presented.view)
            presenter = presented
        }
        return roots.flatMap(descendants).compactMap { $0 as? UIKitTimelineGridHostView }
    }

    @MainActor private func waitUntil(
        _ what: String, timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        note("TIMEOUT: \(what)")
        XCTFail("timed out: \(what)")
        throw MobileFixtureError.unavailable
    }

    @MainActor private func waitForGrid(
        in window: UIWindow, where predicate: @MainActor (UIKitTimelineGridHostView) -> Bool = { !$0.itemUIDs.isEmpty }
    ) async throws -> UIKitTimelineGridHostView {
        var found: UIKitTimelineGridHostView?
        try await waitUntil("grid appears in window") {
            found = grids(in: window).first(where: predicate)
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    @MainActor private func waitForScene(notIn existing: Set<String>) async throws -> UIWindowScene {
        var scene: UIWindowScene?
        try await waitUntil("new window scene connects") {
            scene = windowScenes().first { !existing.contains($0.session.persistentIdentifier) }
            return scene != nil
        }
        return try XCTUnwrap(scene)
    }

    @MainActor private func waitForWindow(in scene: UIWindowScene) async throws -> UIWindow {
        var window: UIWindow?
        try await waitUntil("new scene hosts the production window") {
            window = scene.windows.first { $0.rootViewController != nil }
            return window != nil
        }
        return try XCTUnwrap(window)
    }

    @MainActor private func waitForSearchField(in window: UIWindow) async throws -> UISearchTextField {
        var field: UISearchTextField?
        var requestedSearchPresentation = false
        try await waitUntil("search field appears") {
            field = descendants(window).compactMap { $0 as? UISearchTextField }.first
            if field == nil, !requestedSearchPresentation,
                let tabController = viewControllers(in: window).compactMap({ $0 as? UITabBarController }).first,
                let selectedSearch = tabController.selectedTab as? UISearchTab,
                selectedSearch.automaticallyActivatesSearch,
                let search = viewControllers(in: window)
                    .filter({ $0.viewIfLoaded?.window === window })
                    .compactMap({ $0.navigationItem.searchController }).first
            {
                // The iPadOS 27 fixture's programmatic tab selection leaves native search inactive.
                // Activate its real controller, then require the field in this window before typing.
                requestedSearchPresentation = true
                search.isActive = true
            }
            return field != nil
        }
        return try XCTUnwrap(field)
    }

    /// Types through the native search field the way the keyboard does: the text change reaches the search bar
    /// delegate, which SwiftUI bridges to the `.searchable` binding of that window.
    @MainActor private func setSearchText(_ text: String, in field: UISearchTextField) {
        field.text = text
        field.sendActions(for: .editingChanged)
        var view: UIView? = field
        while let current = view, !(current is UISearchBar) { view = current.superview }
        if let bar = view as? UISearchBar {
            bar.delegate?.searchBar?(bar, textDidChange: text)
        }
    }

    /// Activates the control with the given label inside a window the way a VoiceOver user or a pointer would:
    /// the accessibility element first, then the native bar button item, then any UIKit control with that label.
    @MainActor private func activate(label: String, in window: UIWindow) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while clock.now < deadline {
            if let element = accessibilityElement(labelled: label, in: window), element.accessibilityActivate() {
                note("activated '\(label)' through accessibility")
                try await Task.sleep(for: .milliseconds(600))
                return
            }
            if let item = barButtonItem(labelled: label, in: window), trigger(item) {
                note("activated '\(label)' through UIBarButtonItem")
                try await Task.sleep(for: .milliseconds(600))
                return
            }
            if let control = control(labelled: label, in: window) {
                control.sendActions(for: .touchUpInside)
                note("activated '\(label)' through UIControl")
                try await Task.sleep(for: .milliseconds(600))
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        note("DIAGNOSTICS for '\(label)': " + hierarchyDiagnostics(in: window))
        XCTFail("no activatable control labelled '\(label)' in window")
        throw MobileFixtureError.unavailable
    }

    /// Switches the native tab of one window: the tab label first, then the hosting tab bar controller.
    @MainActor private func selectTab(_ tab: MobileTab, in window: UIWindow) async throws {
        if let element = accessibilityElement(labelled: tab.title, in: window), element.accessibilityActivate() {
            note("selected tab '\(tab.title)' through accessibility")
            try await Task.sleep(for: .milliseconds(800))
            return
        }
        let index = MobileTab.allCases.firstIndex(of: tab) ?? 0
        if let controller = viewControllers(in: window).compactMap({ $0 as? UITabBarController }).first {
            if controller.tabs.indices.contains(index) {
                controller.selectedTab = controller.tabs[index]
            } else {
                controller.selectedIndex = index
            }
            note("selected tab '\(tab.title)' through UITabBarController (tabs=\(controller.tabs.count))")
            try await Task.sleep(for: .milliseconds(800))
            return
        }
        note(
            "DIAGNOSTICS tab '\(tab.title)': controllers="
                + viewControllers(in: window).map { String(describing: type(of: $0)) }.joined(separator: ","))
        XCTFail("no way to select tab '\(tab.title)'")
        throw MobileFixtureError.unavailable
    }

    @MainActor private func viewControllers(in window: UIWindow) -> [UIViewController] {
        var result: [UIViewController] = []
        func walk(_ controller: UIViewController?) {
            guard let controller else { return }
            result.append(controller)
            controller.children.forEach(walk)
            walk(controller.presentedViewController)
        }
        walk(window.rootViewController)
        return result
    }

    @MainActor private func barButtonItem(labelled label: String, in window: UIWindow) -> UIBarButtonItem? {
        for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
            for navigationItem in bar.items ?? [] {
                var items = (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                items += navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.centerItemGroups.flatMap(\.barButtonItems)
                items += navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                for item in items where matches(item, label: label) { return item }
            }
        }
        for toolbar in descendants(window).compactMap({ $0 as? UIToolbar }) {
            for item in toolbar.items ?? [] where matches(item, label: label) { return item }
        }
        return nil
    }

    @MainActor private func matches(_ item: UIBarButtonItem, label: String) -> Bool {
        if item.title == label || item.accessibilityLabel == label { return true }
        guard let custom = item.customView else { return false }
        if custom.accessibilityLabel == label { return true }
        return descendants(custom).contains { view in
            view.accessibilityLabel == label || (view as? UILabel)?.text == label
                || (view as? UIButton)?.titleLabel?.text == label
        }
    }

    @MainActor private func trigger(_ item: UIBarButtonItem) -> Bool {
        if let action = item.action, UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) {
            return true
        }
        if let custom = item.customView {
            if let control = descendants(custom).compactMap({ $0 as? UIControl }).first {
                control.sendActions(for: .touchUpInside)
                return true
            }
            if custom.accessibilityActivate() { return true }
        }
        return false
    }

    @MainActor private func control(labelled label: String, in window: UIWindow) -> UIControl? {
        descendants(window).compactMap { $0 as? UIControl }.first { control in
            control.accessibilityLabel == label || (control as? UIButton)?.titleLabel?.text == label
                || (control as? UIButton)?.configuration?.title == label
        }
    }

    @MainActor private func hierarchyDiagnostics(in window: UIWindow) -> String {
        var lines: [String] = ["voiceOver=\(UIAccessibility.isVoiceOverRunning)"]
        for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
            for navigationItem in bar.items ?? [] {
                let items =
                    (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                    + navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                for item in items {
                    let custom = item.customView.map { String(describing: type(of: $0)) } ?? "-"
                    let count = item.customView?.accessibilityElements?.count ?? -1
                    lines.append(
                        "bar item title=\(item.title ?? "-") a11y=\(item.accessibilityLabel ?? "-") custom=\(custom) a11yElements=\(count) action=\(item.action.map(String.init(describing:)) ?? "-")"
                    )
                }
            }
        }
        let controls = descendants(window).compactMap { $0 as? UIControl }
        lines.append(
            "controls=\(controls.count): "
                + controls.prefix(12).map { "\(type(of: $0))[\($0.accessibilityLabel ?? "-")]" }.joined(separator: ", ")
        )
        let labels = descendants(window).compactMap { $0.accessibilityLabel }.filter { !$0.isEmpty }
        lines.append("view labels: " + Array(Set(labels)).sorted().prefix(30).joined(separator: " | "))
        return lines.joined(separator: "\n  ")
    }

    @MainActor private func accessibilityElement(labelled label: String, in root: NSObject) -> NSObject? {
        if let view = root as? UIView {
            if view.isHidden || view.alpha < 0.01 { return nil }
            if view.accessibilityElementsHidden { return nil }
        }
        if root.isAccessibilityElement, root.accessibilityLabel == label {
            return root
        }
        if let container = root as? UIView {
            for element in container.accessibilityElements ?? [] {
                if let object = element as? NSObject, let match = accessibilityElement(labelled: label, in: object) {
                    return match
                }
            }
            for subview in container.subviews {
                if let match = accessibilityElement(labelled: label, in: subview) { return match }
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let object = root.accessibilityElement(at: index) as? NSObject,
                        let match = accessibilityElement(labelled: label, in: object)
                    {
                        return match
                    }
                }
            }
        }
        return nil
    }

    @MainActor private func snapshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() { writeArtifact("\(name).png", data) }
    }

    private func writeReport() {
        writeArtifact("multiwindow-report.txt", Data(report.joined(separator: "\n").utf8))
    }

    private func writeArtifact(_ name: String, _ data: Data) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }
}
