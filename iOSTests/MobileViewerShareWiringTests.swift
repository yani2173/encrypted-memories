import MediaFeedCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// The burst of the wiring tests: the filmstrip seeds two of the three members, so the seeded
/// filmstrip stays partial until the backend read completes it.
private enum ViewerShareSample {
    private static let members = ["share-lead", "share-second", "share-third"]

    static let lead = burstItem(members[0], afterReference: 0)
    static let second = burstItem(members[1], afterReference: 60)
    static let third = burstItem(members[2], afterReference: 120)
    static let plain = PhotoItem(
        uid: PhotoUID(volumeID: "fixture", nodeID: "share-plain"),
        captureTime: Date(timeIntervalSince1970: 1_700_000_000),
        mediaType: "image/jpeg"
    )
    static let livePhoto = PhotoItem(
        uid: PhotoUID(volumeID: "fixture", nodeID: "share-live"),
        captureTime: Date(timeIntervalSince1970: 1_700_000_000),
        mediaType: "image/heic",
        isLivePhoto: true,
        relatedVideoID: "share-live-motion"
    )
    /// The fixture backend answers video metadata only for its video node, so the viewer resolves this item as a video.
    static let video = PhotoItem(
        uid: PhotoUID(volumeID: "fixture", nodeID: MobileSignedInFixture.videoNodeID),
        captureTime: Date(timeIntervalSince1970: 1_700_000_000),
        mediaType: "video/quicktime",
        durationSeconds: 4
    )

    private static func burstItem(_ nodeID: String, afterReference seconds: TimeInterval) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "fixture", nodeID: nodeID),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: members
        )
    }
}

/// Verifies the viewer's Share wiring through the rendered control: the real button drives
/// `shareCurrentItem`, whose burst cases must refuse to share a partially known series. The
/// fixture backend answers burst groups from an injected closure, so the filmstrip reaches the
/// states a real account can: in flight, failed, and loaded.
@MainActor
final class MobileViewerShareWiringTests: XCTestCase {
    func testShareWaitsForTheInFlightReadAndThenOffersTheWholeSeries() async throws {
        let gate = AsyncGate()
        let fixture = try await Fixture(
            items: [ViewerShareSample.lead, ViewerShareSample.second],
            burstLoader: { _ in
                await gate.arriveAndWait()
                return [ViewerShareSample.lead, ViewerShareSample.second, ViewerShareSample.third]
            },
            releaseOnClose: { gate.open() })
        defer { fixture.close() }

        try await waitUntil { gate.arrivals >= 1 }
        XCTAssertTrue(gate.arrivals >= 1, "the burst read must actually start")

        // While the read is in flight the control is dimmed.
        let dimmedWhileLoading = try await fixture.waitForShareEnabledState(false)
        XCTAssertTrue(dimmedWhileLoading, "Share must be dimmed while the burst read is in flight")

        // The dimmed control takes no activation: nothing is shared, refused, or failed. The same
        // activations share the whole series below once the control is enabled again.
        for _ in 0..<20 {
            _ = fixture.tryActivatingShare()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fixture.probe.events, [], "a dimmed Share must not start any share decision")
        XCTAssertTrue(fixture.alertControllers().isEmpty, "waiting is silent: no alert while the read is in flight")

        // Once the filmstrip settled, the same control shares the complete series.
        let settledShare: [MobileViewerShareDecisionProbe.Event] = [
            .shared(
                nodeIDs: [
                    ViewerShareSample.lead.uid.nodeID, ViewerShareSample.second.uid.nodeID,
                    ViewerShareSample.third.uid.nodeID,
                ],
                failureMessage: String(localized: "viewer.share_failed_photos"))
        ]
        gate.open()
        let enabledWhenSettled = try await fixture.waitForShareEnabledState(true)
        XCTAssertTrue(enabledWhenSettled, "Share must become available once the series is loaded")
        // The control accepts the activation only once the read finished, so keep offering the
        // press until the settled filmstrip produces the share.
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(15) {
            _ = fixture.tryActivatingShare()
            if fixture.probe.events.contains(where: { $0 == settledShare[0] }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(
            fixture.probe.events.filter(\.isShared), settledShare,
            "once the filmstrip settled, the share must offer the complete series")
    }

    func testShareAfterAFailedReadShowsTheBurstFailureAndSharesNothing() async throws {
        struct ReadFailure: Error {}
        let fixture = try await Fixture(
            items: [ViewerShareSample.lead, ViewerShareSample.second],
            burstLoader: { _ in throw ReadFailure() })
        defer { fixture.close() }

        // The read fails shortly after the viewer mounts. Until then Share is dimmed and takes no
        // activation, so pressing continues until the failed read enables Share again and the
        // press shows the burst failure.
        let failure = String(localized: "viewer.share_burst_load_failed")
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(15) {
            _ = fixture.tryActivatingShare()
            if fixture.probe.events.contains(where: \.isBurstReadFailed) { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(
            fixture.probe.events,
            [.burstReadFailed(message: failure)],
            "a failed burst read must produce the burst failure, not a share of the partial filmstrip")
        let failureShown = try await fixture.waitForAlert(containing: failure)
        XCTAssertTrue(failureShown, "the burst failure must become visible to the person")
    }

    func testShareAfterAFailedReadReadsTheBurstAgainAndSharesTheWholeSeries() async throws {
        struct ReadFailure: Error {}
        let whole = [ViewerShareSample.lead, ViewerShareSample.second, ViewerShareSample.third]
        let gate = AsyncGate()
        let reads = ReadCounter()
        // The first read fails; the read that the Share tap starts succeeds once the gate opens.
        let fixture = try await Fixture(
            items: [ViewerShareSample.lead, ViewerShareSample.second],
            burstLoader: { _ in
                if reads.next() == 1 { throw ReadFailure() }
                await gate.arriveAndWait()
                return whole
            },
            releaseOnClose: { gate.open() })
        defer { fixture.close() }

        try await waitUntil { reads.count == 1 }
        let enabledAfterFailure = try await fixture.waitForShareEnabledState(true)
        XCTAssertTrue(enabledAfterFailure, "Share is available after the failed read")
        XCTAssertTrue(fixture.tryActivatingShare())

        // The tap reads the burst again, and Share is dimmed while that read runs.
        try await waitUntil { gate.arrivals >= 1 }
        XCTAssertEqual(reads.count, 2, "a Share tap after a failed read must read the burst again")
        let dimmedWhileReading = try await fixture.waitForShareEnabledState(false)
        XCTAssertTrue(dimmedWhileReading, "Share must be dimmed while the burst is read again")
        XCTAssertEqual(fixture.probe.events, [], "nothing is shared or refused while the read runs")

        gate.open()
        let wholeShare = MobileViewerShareDecisionProbe.Event.shared(
            nodeIDs: whole.map(\.uid.nodeID), failureMessage: String(localized: "viewer.share_failed_photos"))
        try await waitUntil { !fixture.probe.events.isEmpty }
        XCTAssertEqual(fixture.probe.events, [wholeShare], "the tap shares the whole series once it is read")
        XCTAssertTrue(fixture.alertControllers().isEmpty, "a successful read shows no failure")
    }

    func testShareAfterAFailedReadShowsTheNoticeAgainWhenTheNewReadFails() async throws {
        struct ReadFailure: Error {}
        let reads = ReadCounter()
        let fixture = try await Fixture(
            items: [ViewerShareSample.lead, ViewerShareSample.second],
            burstLoader: { _ in
                _ = reads.next()
                throw ReadFailure()
            })
        defer { fixture.close() }

        try await waitUntil { reads.count == 1 }
        let enabledAfterFailure = try await fixture.waitForShareEnabledState(true)
        XCTAssertTrue(enabledAfterFailure, "Share is available after the failed read")
        XCTAssertTrue(fixture.tryActivatingShare())

        let failure = String(localized: "viewer.share_burst_load_failed")
        try await waitUntil { !fixture.probe.events.isEmpty }
        XCTAssertEqual(reads.count, 2, "a Share tap after a failed read must read the burst again")
        XCTAssertEqual(fixture.probe.events, [.burstReadFailed(message: failure)])
        let failureShown = try await fixture.waitForAlert(containing: failure)
        XCTAssertTrue(failureShown, "a failed new read shows the burst notice again")
    }

    func testClosingTheViewerDuringTheShareRereadSharesNothing() async throws {
        struct ReadFailure: Error {}
        let whole = [ViewerShareSample.lead, ViewerShareSample.second, ViewerShareSample.third]
        let gate = AsyncGate()
        let reads = ReadCounter()
        // The first read fails; the read that the Share tap starts waits until the viewer is closed.
        let fixture = try await Fixture(
            items: [ViewerShareSample.lead, ViewerShareSample.second],
            burstLoader: { _ in
                if reads.next() == 1 { throw ReadFailure() }
                await gate.arriveAndWait()
                return whole
            },
            releaseOnClose: { gate.open() })
        defer { fixture.close() }

        try await waitUntil { reads.count == 1 }
        let enabledAfterFailure = try await fixture.waitForShareEnabledState(true)
        XCTAssertTrue(enabledAfterFailure, "Share is available after the failed read")
        XCTAssertTrue(fixture.tryActivatingShare())
        try await waitUntil { gate.arrivals >= 1 }

        fixture.router.presentation = nil
        try await waitUntil { fixture.root.presentedViewController == nil }
        XCTAssertNil(fixture.root.presentedViewController, "the viewer closed while the read ran")

        // The read finishes after the viewer closed; its result must not share anything.
        gate.open()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(fixture.probe.events, [], "a closed viewer shares nothing")
    }

    func testShareOfAPartlyKnownBurstThatTheReadDoesNotConfirmShowsTheBurstFailure() async throws {
        // The filmstrip seeds two of the three members, and the read answers with no photo.
        let fixture = try await Fixture(
            items: [ViewerShareSample.lead, ViewerShareSample.second],
            burstLoader: { _ in [] })
        defer { fixture.close() }

        let failure = String(localized: "viewer.share_burst_load_failed")
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(15) {
            _ = fixture.tryActivatingShare()
            if !fixture.probe.events.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(
            fixture.probe.events, [.burstReadFailed(message: failure)],
            "two of three photos must not be shared as the whole burst")
        let failureShown = try await fixture.waitForAlert(containing: failure)
        XCTAssertTrue(failureShown, "the burst failure must become visible to the person")
    }

    func testAPhotoWhoseOnlyOtherMemberIsNoFrameSharesThePhoto() async throws {
        // The photo declares itself and the adjustment data of its edit; the read finds one frame.
        let page = PhotoItem(
            uid: PhotoUID(volumeID: "fixture", nodeID: "share-edited"),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: ["share-edited", "share-edit-data"]
        )
        let loneFrame = PhotoItem(
            uid: page.uid, captureTime: page.captureTime, mediaType: "image/jpeg", tags: [.bursts],
            burstMemberIDs: ["share-edited"])
        let fixture = try await Fixture(items: [page], burstLoader: { _ in [loneFrame] })
        defer { fixture.close() }

        // Share is dimmed while the read runs, so keep offering the press until the share happens.
        let photoShare = MobileViewerShareDecisionProbe.Event.shared(
            nodeIDs: [page.uid.nodeID], failureMessage: String(localized: "viewer.share_failed"))
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(15) {
            _ = fixture.tryActivatingShare()
            if !fixture.probe.events.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(fixture.probe.events.filter(\.isShared), [photoShare])
        XCTAssertFalse(
            fixture.probe.events.contains(where: \.isBurstReadFailed),
            "one frame shares the photo without a burst notice")
    }

    func testASinglePlainPhotoKeepsTheGenericShareRoute() async throws {
        let fixture = try await Fixture(items: [ViewerShareSample.plain], burstLoader: { _ in [] })
        defer { fixture.close() }

        let reacted = try await activateShareWhenEnabled(fixture)
        XCTAssertTrue(reacted)
        let plainShare: [MobileViewerShareDecisionProbe.Event] = [
            .shared(
                nodeIDs: [ViewerShareSample.plain.uid.nodeID],
                failureMessage: String(localized: "viewer.share_failed"))
        ]
        try await waitUntil { fixture.probe.events.contains(where: { $0 == plainShare[0] }) }
        XCTAssertEqual(fixture.probe.events.filter(\.isShared), plainShare, "one photo names the photo")
    }

    func testALivePhotoSharesAsOnePhoto() async throws {
        let fixture = try await Fixture(items: [ViewerShareSample.livePhoto], burstLoader: { _ in [] })
        defer { fixture.close() }

        let reacted = try await activateShareWhenEnabled(fixture)
        XCTAssertTrue(reacted)
        // The still and its motion file are one photo to the person, so the failure names a photo.
        let liveShare = MobileViewerShareDecisionProbe.Event.shared(
            nodeIDs: [ViewerShareSample.livePhoto.uid.nodeID],
            failureMessage: String(localized: "viewer.share_failed"))
        try await waitUntil { fixture.probe.events.contains(liveShare) }
        XCTAssertEqual(fixture.probe.events.filter(\.isShared), [liveShare])
    }

    func testASingleVideoNamesTheVideoWhenSharingFails() async throws {
        let fixture = try await Fixture(items: [ViewerShareSample.video], burstLoader: { _ in [] })
        defer { fixture.close() }

        let reacted = try await activateShareWhenEnabled(fixture)
        XCTAssertTrue(reacted)
        let videoShare = MobileViewerShareDecisionProbe.Event.shared(
            nodeIDs: [ViewerShareSample.video.uid.nodeID],
            failureMessage: String(localized: "viewer.share_failed_video"))
        try await waitUntil { fixture.probe.events.contains(videoShare) }
        XCTAssertEqual(fixture.probe.events.filter(\.isShared), [videoShare])
    }

    // MARK: - Harness

    private static let shareLabel = String(localized: "viewer.share_action")

    /// Suspends an awaiting burst-group read until `open()` runs. `arrivals` proves the read started.
    /// The lock is taken only in synchronous helpers: `NSLock` must not be used across an `await`.
    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrivalCount = 0

        var arrivals: Int { lock.withLock { arrivalCount } }

        func arriveAndWait() async {
            if recordArrivalAndCheckOpen() { return }
            await withCheckedContinuation { continuation in
                if !enqueueUnlessOpen(continuation) { continuation.resume() }
            }
        }

        func open() {
            let resumed = lock.withLock {
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            resumed.forEach { $0.resume() }
        }

        private func recordArrivalAndCheckOpen() -> Bool {
            lock.withLock {
                arrivalCount += 1
                return isOpen
            }
        }

        /// Returns false when the gate is already open, so the caller resumes at once.
        private func enqueueUnlessOpen(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.withLock {
                guard !isOpen else { return false }
                waiters.append(continuation)
                return true
            }
        }
    }

    /// Counts burst-group reads across the fixture backend's concurrent calls.
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }

        /// Records one read and returns its number, starting at 1.
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    /// Polls until the condition holds. The limit only guards against a hang; a saturated hosted
    /// runner may need several seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(15), !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Tries the Share control until it accepts the activation, which the burst cases dim while the
    /// filmstrip knowledge is unsettled.
    private func activateShareWhenEnabled(_ fixture: Fixture) async throws -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(15) {
            if fixture.tryActivatingShare() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Hosts the viewer in its own window over the fixture account, through the production
    /// full-screen-cover presentation of the router, like `MobileMainTabView` presents it.
    @MainActor
    private final class Fixture {
        let seed: MobileSignedInFixture
        let library = MobileLibraryModel()
        let backend: MobileFixtureBackend
        let probe = MobileViewerShareDecisionProbe()
        let router = MobileViewerRouter()
        let root = UIHostingController(rootView: AnyView(Color.black))
        let window: UIWindow
        let previous: UIWindow?
        private let releaseOnClose: () -> Void

        init(
            items: [PhotoItem],
            burstLoader: @escaping @Sendable (PhotoUID) async throws -> [PhotoItem],
            releaseOnClose: @escaping () -> Void = {}
        ) async throws {
            seed = try await MobileSignedInFixture(itemsPerSection: 1)
            self.releaseOnClose = releaseOnClose
            let section = TimelineSection(
                id: "share-wiring", date: ViewerShareSample.plain.captureTime, title: "Share Wiring",
                items: items)
            backend = MobileFixtureBackend(sections: [section], thumbnails: [:], burstGroupLoader: burstLoader)
            await seed.feed.feedCore.setPrefetchEnabled(false)
            seed.install(
                into: library, backend: backend, sections: [section],
                thumbnailFeed: seed.feed, thumbnailCache: seed.cache)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = root
            window.makeKeyAndVisible()
            // The production route presents the viewer: `MobileMainTabView` binds one
            // `.fullScreenCover(item:)` to the router. A viewer hosted directly as a window
            // root takes a synthetic layout path in which the bottom toolbar never mounts,
            // so the fixture mirrors the production presentation like the inspector suite.
            root.rootView = AnyView(
                ViewerSharePresentationHost(router: router, libraryModel: library)
                    .environment(\.mobileViewerShareProbeForTesting, probe))
            router.presentation = MobileViewerPresentation(
                index: 0, items: items, context: .library)
        }

        func tryActivatingShare() -> Bool {
            let label = MobileViewerShareWiringTests.shareLabel
            if let element = accessibilityElement(labelled: label, in: window), element.accessibilityActivate() {
                return true
            }
            if let item = barButtonItem(labelled: label, in: window), trigger(item) { return true }
            if let control = shareBarButtonControl() {
                control.sendActions(for: .touchUpInside)
                return true
            }
            activationFailures += 1
            if activationFailures % 25 == 1 { print("share-activation diagnostics: \(hierarchyDiagnostics())") }
            return false
        }

        /// The enabled state of the mounted Share control, or nil while it is not mounted.
        func shareIsEnabled() -> Bool? {
            let label = MobileViewerShareWiringTests.shareLabel
            if let item = barButtonItem(labelled: label, in: window) { return item.isEnabled }
            if let control = shareBarButtonControl() { return control.isEnabled }
            if let element = accessibilityElement(labelled: label, in: window) {
                return !element.accessibilityTraits.contains(.notEnabled)
            }
            return nil
        }

        /// Waits until the mounted Share control reaches the expected enabled state.
        func waitForShareEnabledState(_ enabled: Bool) async throws -> Bool {
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(15) {
                if shareIsEnabled() == enabled { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            print("share-enabled diagnostics: \(hierarchyDiagnostics())")
            return false
        }

        /// The bottom bar is the system floating bar: the Share item mounts as a bar-button
        /// control that carries the share symbol and the toolbar action, with no accessibility
        /// label in this environment. The symbol identifies it.
        private func shareBarButtonControl() -> UIControl? {
            descendants(window).compactMap { $0 as? UIControl }.first { control in
                guard String(describing: type(of: control)).contains("BarButton") else { return false }
                guard control.isUserInteractionEnabled else { return false }
                let description = String(describing: control)
                return description.contains("square.and.arrow.up")
            }
        }

        private var activationFailures = 0

        private func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }

        /// Every view controller in the presented chain, including embedded children, so toolbar
        /// items that SwiftUI mounts on a hosting controller surface in diagnostics.
        private func allViewControllers(from controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(allViewControllers(from:))
                + (controller.presentedViewController.map(allViewControllers(from:)) ?? [])
        }

        private func barButtonItem(labelled label: String, in window: UIWindow) -> UIBarButtonItem? {
            func matches(_ item: UIBarButtonItem) -> Bool {
                if item.title == label || item.accessibilityLabel == label { return true }
                guard let custom = item.customView else { return false }
                if custom.accessibilityLabel == label { return true }
                return descendants(custom).contains { view in
                    view.accessibilityLabel == label || (view as? UILabel)?.text == label
                }
            }
            for bar in descendants(window).compactMap({ $0 as? UIToolbar }) {
                for item in bar.items ?? [] where matches(item) { return item }
            }
            for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
                for navigationItem in bar.items ?? [] {
                    var items = (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                    items += navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
                    items += navigationItem.centerItemGroups.flatMap(\.barButtonItems)
                    items += navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                    for item in items where matches(item) { return item }
                }
            }
            return nil
        }

        private func trigger(_ item: UIBarButtonItem) -> Bool {
            if let action = item.action, UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
            {
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

        private func hierarchyDiagnostics() -> String {
            var lines = ["window=\(window.frame)"]
            for toolbar in descendants(window).compactMap({ $0 as? UIToolbar }) {
                lines.append(
                    "toolbar frame=\(toolbar.frame) items=\((toolbar.items ?? []).map { $0.accessibilityLabel ?? $0.title ?? "-" })"
                )
            }
            for bar in descendants(window).compactMap({ $0 as? UINavigationBar }) {
                for navigationItem in bar.items ?? [] {
                    let items =
                        (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                        + navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                    for item in items {
                        let custom = item.customView.map { String(describing: type(of: $0)) } ?? "-"
                        lines.append(
                            "bar item title=\(item.title ?? "-") a11y=\(item.accessibilityLabel ?? "-") custom=\(custom) action=\(item.action.map(String.init(describing:)) ?? "-")"
                        )
                    }
                }
            }
            let classes = descendants(window).map { String(describing: type(of: $0)) }
            lines.append("classes=\(classes.joined(separator: ","))")
            if let rootViewController = window.rootViewController {
                for controller in allViewControllers(from: rootViewController) {
                    let name = String(describing: type(of: controller))
                    let toolbarItems = (controller.toolbarItems ?? []).map { $0.accessibilityLabel ?? $0.title ?? "-" }
                    let navigationTitle = controller.navigationItem.title ?? "-"
                    let rightItems = (controller.navigationItem.rightBarButtonItems ?? []).map {
                        "\($0.accessibilityLabel ?? $0.title ?? "-")"
                    }
                    lines.append(
                        "vc=\(name) navTitle=\(navigationTitle) toolbar=\(toolbarItems) right=\(rightItems)")
                }
            }
            for view in descendants(window) where String(describing: type(of: view)).contains("BarButton") {
                lines.append(
                    "barView=\(view) frame=\(view.frame) enabled=\(view.isUserInteractionEnabled) a11y=\(view.accessibilityLabel ?? "-")"
                )
            }
            let labelled = descendants(window).filter { $0.accessibilityLabel != nil }
            lines.append("labels=\(labelled.map { "\($0.accessibilityLabel!):\(type(of: $0))" })")
            return lines.joined(separator: "\n")
        }

        func alertControllers() -> [UIAlertController] {
            var result: [UIAlertController] = []
            func walk(_ controller: UIViewController?) {
                guard let controller else { return }
                if let alert = controller as? UIAlertController { result.append(alert) }
                controller.children.forEach(walk)
                walk(controller.presentedViewController)
            }
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for sceneWindow in scene.windows {
                    walk(sceneWindow.rootViewController)
                }
            }
            return result
        }

        func waitForAlert(containing message: String) async throws -> Bool {
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(15) {
                if alertControllers().contains(where: { ($0.title ?? "").contains(message) }) { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        private func accessibilityElement(labelled label: String, in rootObject: NSObject) -> NSObject? {
            if let view = rootObject as? UIView {
                if view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden { return nil }
            }
            if rootObject.isAccessibilityElement, rootObject.accessibilityLabel == label {
                return rootObject
            }
            if let container = rootObject as? UIView {
                for element in container.accessibilityElements ?? [] {
                    if let object = element as? NSObject,
                        let match = accessibilityElement(labelled: label, in: object)
                    {
                        return match
                    }
                }
                for subview in container.subviews {
                    if let match = accessibilityElement(labelled: label, in: subview) { return match }
                }
            } else {
                let count = rootObject.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let object = rootObject.accessibilityElement(at: index) as? NSObject,
                            let match = accessibilityElement(labelled: label, in: object)
                        {
                            return match
                        }
                    }
                }
            }
            return nil
        }

        func close() {
            releaseOnClose()
            router.presentation = nil
            root.rootView = AnyView(Color.black)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            seed.removeCache()
        }
    }
}

/// The production viewer presentation: one `.fullScreenCover(item:)` bound to the viewer router, the
/// way `MobileMainTabView` presents `MobilePhotoViewer` (see `EncryptedMemoriesMobileApp.swift`).
private struct ViewerSharePresentationHost: View {
    let router: MobileViewerRouter
    let libraryModel: MobileLibraryModel

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .fullScreenCover(
                item: Binding(
                    get: { router.presentation },
                    set: { router.presentation = $0 }
                )
            ) { presentation in
                MobilePhotoViewer(
                    items: presentation.items,
                    startIndex: presentation.index,
                    context: presentation.context,
                    libraryModel: libraryModel,
                    viewerRouter: router
                )
            }
    }
}

extension MobileViewerShareDecisionProbe.Event {
    var isShared: Bool {
        if case .shared = self { return true }
        return false
    }

    var isBurstReadFailed: Bool {
        if case .burstReadFailed = self { return true }
        return false
    }
}

/// The share failure text names what the share carries. The resolved media kind decides before the
/// timeline hint, like the viewer page does.
final class MobileViewerShareFailureTextTests: XCTestCase {
    private static func item(_ nodeID: String, mediaType: String) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "fixture", nodeID: nodeID),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            mediaType: mediaType)
    }

    func testTheTextFollowsTheSeriesAndTheResolvedKind() {
        let photo = Self.item("photo", mediaType: "image/jpeg")
        let video = Self.item("video", mediaType: "video/quicktime")
        let photos = String(localized: "viewer.share_failed_photos")
        let onePhoto = String(localized: "viewer.share_failed")
        let oneVideo = String(localized: "viewer.share_failed_video")
        let cases: [(String, [PhotoItem], Bool, [PhotoUID: MediaKind], String)] = [
            ("a video whose hint says photo", [photo], false, [photo.uid: .video], oneVideo),
            ("a photo whose hint says video", [video], false, [video.uid: .image], onePhoto),
            ("an unresolved video", [video], false, [:], oneVideo),
            ("an unresolved photo", [photo], false, [:], onePhoto),
            ("a series with a video", [photo, video], true, [video.uid: .video], photos),
            ("no item", [], false, [:], onePhoto),
        ]
        for (name, items, series, kinds, expected) in cases {
            XCTAssertEqual(
                MobileViewerShareFailureText.message(for: items, expandedSingleSeries: series, resolvedKinds: kinds),
                expected, name)
        }
    }
}
