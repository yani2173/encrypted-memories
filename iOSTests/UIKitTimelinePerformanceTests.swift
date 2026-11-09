import GridCore
import PhotosCore
import QuartzCore
import Testing
import UIKit

@testable import TimelineUIKitAdapter
@testable import TimelineUIKitFeature

@MainActor
private final class TestTimelineDisplayLink: UIKitTimelineDisplayLinkScheduling {
    var isPaused = true
    var preferredFrameRateRange = CAFrameRateRange.default
    private(set) var invalidationCount = 0
    var onInvalidated: (() -> Void)?
    let onFrame: (UIKitTimelineDisplayFrame) -> Void

    init(onFrame: @escaping (UIKitTimelineDisplayFrame) -> Void) {
        self.onFrame = onFrame
    }

    func invalidate() {
        invalidationCount += 1
        onInvalidated?()
    }

    func fire(timestamp: CFTimeInterval, interval: CFTimeInterval) {
        onFrame(
            UIKitTimelineDisplayFrame(
                timestamp: timestamp,
                targetTimestamp: timestamp + interval,
                duration: interval
            ))
    }
}

@MainActor
private final class TestTimelineDisplayLinkFactory {
    private(set) var links: [TestTimelineDisplayLink] = []

    func make(onFrame: @escaping (UIKitTimelineDisplayFrame) -> Void) -> any UIKitTimelineDisplayLinkScheduling {
        let link = TestTimelineDisplayLink(onFrame: onFrame)
        links.append(link)
        return link
    }
}

@MainActor
private func makeTestHost(
    outcomes: [GridRenderOutcome]
) -> (
    host: UIKitTimelineGridHostView,
    driver: UIKitTimelineDisplayLinkDriver,
    factory: TestTimelineDisplayLinkFactory,
    window: UIWindow
) {
    let factory = TestTimelineDisplayLinkFactory()
    let driver = UIKitTimelineDisplayLinkDriver { factory.make(onFrame: $0) }
    var outcomes = outcomes
    let host = UIKitTimelineGridHostView(displayLink: driver) {
        outcomes.isEmpty ? .drawn(hasPendingWork: false) : outcomes.removeFirst()
    }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    host.frame = window.bounds
    window.addSubview(host)
    host.layoutIfNeeded()
    return (host, driver, factory, window)
}

@MainActor
@Suite("UIKit timeline 120 Hz")
struct UIKitTimelinePerformanceTests {
    @Test func frameRatePolicyUsesAttachedDisplayCapability() {
        let sixty = UIKitTimelineFrameRatePolicy.preferredRange(maximumFramesPerSecond: 60)
        #expect(sixty.minimum == CAFrameRateRange.default.minimum)
        #expect(sixty.maximum == CAFrameRateRange.default.maximum)
        #expect(sixty.preferred == CAFrameRateRange.default.preferred)

        let oneTwenty = UIKitTimelineFrameRatePolicy.preferredRange(maximumFramesPerSecond: 120)
        #expect(oneTwenty.minimum == 80)
        #expect(oneTwenty.maximum == 120)
        #expect(oneTwenty.preferred == 120)
    }

    @Test func generatedApplicationManifestEnablesHighRefreshRates() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool == true)
    }

    @Test func driverPausesAndResumesOneInstalledLinkUntilFinalTeardown() {
        let factory = TestTimelineDisplayLinkFactory()
        let driver = UIKitTimelineDisplayLinkDriver { factory.make(onFrame: $0) }
        var frames = 0

        driver.start(maximumFramesPerSecond: 120) { _ in frames += 1 }
        #expect(driver.installationCount == 1)
        #expect(factory.links.count == 1)
        #expect(!factory.links[0].isPaused)
        factory.links[0].fire(timestamp: 1, interval: 1.0 / 120.0)
        #expect(frames == 1)

        driver.pause()
        #expect(factory.links[0].isPaused)
        #expect(factory.links[0].invalidationCount == 0)
        driver.start(maximumFramesPerSecond: 60) { _ in frames += 1 }
        #expect(driver.installationCount == 1)
        #expect(factory.links.count == 1)
        #expect(!factory.links[0].isPaused)
        #expect(factory.links[0].preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum)

        driver.stop()
        #expect(factory.links[0].invalidationCount == 1)
    }

    @Test func warmDraggingAndDecelerationFramesDoNotRebuildTheDisplayLink() throws {
        let setup = makeTestHost(outcomes: Array(repeating: .drawn(hasPendingWork: false), count: 8))
        let link = try #require(setup.factory.links.first)
        let base = CACurrentMediaTime()

        setup.host.scrollViewWillBeginDragging(setup.host.scrollView)
        for index in 0..<3 {
            setup.host.requestRender()
            link.fire(timestamp: base + Double(index) / 120.0, interval: 1.0 / 120.0)
            #expect(setup.driver.isRunning)
        }
        setup.host.scrollViewDidEndDragging(setup.host.scrollView, willDecelerate: true)
        for index in 3..<6 {
            setup.host.requestRender()
            link.fire(timestamp: base + Double(index) / 120.0, interval: 1.0 / 120.0)
            #expect(setup.driver.isRunning)
        }
        setup.host.scrollViewDidEndDecelerating(setup.host.scrollView)
        link.fire(timestamp: base + 6.0 / 120.0, interval: 1.0 / 120.0)

        #expect(!setup.driver.isRunning)
        #expect(setup.driver.installationCount == 1)
        #expect(link.invalidationCount == 0)
        _ = setup.window
    }

    @Test func stationaryGesturePausesAndNextScrollResumesTheInstalledLink() throws {
        let setup = makeTestHost(outcomes: [.drawn(hasPendingWork: false)])
        let link = try #require(setup.factory.links.first)
        let base = CACurrentMediaTime()
        setup.host.scrollViewWillBeginDragging(setup.host.scrollView)
        link.fire(timestamp: base, interval: 1.0 / 120.0)
        #expect(setup.driver.isRunning)

        // The gesture remains active, but no scroll offset or image changed before the next tick.
        link.fire(timestamp: base + 1.0 / 120.0, interval: 1.0 / 120.0)
        #expect(setup.host.scrollInputActive)
        #expect(!setup.driver.isRunning)
        #expect(!setup.host.framePump.shouldTick)

        setup.host.scrollViewDidScroll(setup.host.scrollView)
        #expect(setup.driver.isRunning)
        #expect(setup.host.framePump.shouldTick)
        link.fire(timestamp: base + 1, interval: 1.0 / 120.0)
        #expect(!setup.host.framePump.shouldTick)
        #expect(setup.driver.installationCount == 1)
        #expect(link.invalidationCount == 0)
        _ = setup.window
    }

    @Test func abandonedDriverInvalidatesAfterReleaseOutsideMainActor() async throws {
        let factory = TestTimelineDisplayLinkFactory()
        let (events, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await Task.detached {
            let driver = await MainActor.run {
                let driver = UIKitTimelineDisplayLinkDriver { factory.make(onFrame: $0) }
                driver.start(maximumFramesPerSecond: 120) { _ in }
                factory.links[0].onInvalidated = {
                    completion.yield(())
                    completion.finish()
                }
                return driver
            }
            withExtendedLifetime(driver) {}
        }.value
        for await _ in events {}
        #expect(try #require(factory.links.first).invalidationCount == 1)
    }

    @Test func hostTeardownInvalidatesLinkOnMainActor() async throws {
        let factory = TestTimelineDisplayLinkFactory()
        let (events, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do {
            let driver = UIKitTimelineDisplayLinkDriver { factory.make(onFrame: $0) }
            let host = UIKitTimelineGridHostView(displayLink: driver) { .drawn(hasPendingWork: false) }
            driver.start(maximumFramesPerSecond: 120) { _ in }
            factory.links[0].onInvalidated = {
                completion.yield(())
                completion.finish()
            }
            withExtendedLifetime(host) {}
        }
        for await _ in events {}
        #expect(try #require(factory.links.first).invalidationCount == 1)
    }

    @Test func trueIdleBackgroundAndDetachPauseWithoutInvalidating() throws {
        let setup = makeTestHost(outcomes: Array(repeating: .drawn(hasPendingWork: false), count: 4))
        let link = try #require(setup.factory.links.first)

        link.fire(timestamp: CACurrentMediaTime(), interval: 1.0 / 60.0)
        #expect(!setup.driver.isRunning)
        setup.host.requestRender()
        #expect(setup.driver.isRunning)

        setup.host.hostSceneDidEnterBackground()
        #expect(!setup.driver.isRunning)
        #expect(link.invalidationCount == 0)
        setup.host.hostSceneWillEnterForeground()
        #expect(setup.driver.isRunning)
        #expect(setup.driver.installationCount == 1)

        setup.host.setActive(false)
        #expect(!setup.driver.isRunning)
        setup.host.requestRender()
        #expect(!setup.driver.isRunning)
        setup.host.setActive(true)
        #expect(setup.driver.isRunning)
        #expect(setup.driver.installationCount == 1)

        setup.host.removeFromSuperview()
        #expect(!setup.driver.isRunning)
        #expect(link.invalidationCount == 0)
        setup.window.addSubview(setup.host)
        #expect(setup.driver.isRunning)
        #expect(setup.driver.installationCount == 1)
    }

    @Test func inactiveHostReattachedToForegroundRefreshesSceneStateBeforeActivation() throws {
        let setup = makeTestHost(outcomes: [.drawn(hasPendingWork: false)])
        setup.host.hostSceneDidEnterBackground()
        setup.host.setActive(false)
        setup.host.removeFromSuperview()
        // This host misses the scene's foreground notification while it has no window. Reattachment must
        // refresh the scene state even though its tab stays inactive until the following selection.
        setup.window.addSubview(setup.host)
        #expect(!setup.driver.isRunning)
        setup.host.setActive(true)
        #expect(setup.driver.isRunning)
        #expect(setup.driver.installationCount == 1)
    }

    @Test func repeatedEncodingFailuresStopTheLinkAfterABoundedRetry() throws {
        let failing = makeTestHost(outcomes: Array(repeating: .encodingFailed, count: 10))
        let link = try #require(failing.factory.links.first)
        let base = CACurrentMediaTime()
        var fired = 0
        while failing.driver.isRunning, fired < 10 {
            link.fire(timestamp: base + Double(fired) / 120.0, interval: 1.0 / 120.0)
            fired += 1
        }
        #expect(!failing.driver.isRunning)
        #expect(fired == GridFramePump.maximumEncodingRetries + 1)
    }

    @Test func drawableRetryAndInvalidationDuringFrameKeepTheSameLink() throws {
        let retry = makeTestHost(outcomes: [.noDrawable, .drawn(hasPendingWork: false)])
        let retryLink = try #require(retry.factory.links.first)
        let retryBase = CACurrentMediaTime()
        retryLink.fire(timestamp: retryBase, interval: 1.0 / 120.0)
        #expect(retry.driver.isRunning)
        retryLink.fire(timestamp: retryBase + 1.0 / 120.0, interval: 1.0 / 120.0)
        #expect(!retry.driver.isRunning)
        #expect(retry.driver.installationCount == 1)

        let factory = TestTimelineDisplayLinkFactory()
        let driver = UIKitTimelineDisplayLinkDriver { factory.make(onFrame: $0) }
        weak var weakHost: UIKitTimelineGridHostView?
        var draws = 0
        let host = UIKitTimelineGridHostView(displayLink: driver) {
            draws += 1
            if draws == 1 { weakHost?.requestRender() }
            return .drawn(hasPendingWork: false)
        }
        weakHost = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        let link = try #require(factory.links.first)
        let invalidationBase = CACurrentMediaTime()
        link.fire(timestamp: invalidationBase, interval: 1.0 / 120.0)
        #expect(driver.isRunning)
        link.fire(timestamp: invalidationBase + 1.0 / 120.0, interval: 1.0 / 120.0)
        #expect(!driver.isRunning)
        #expect(draws == 2)
        #expect(driver.installationCount == 1)
    }

    @Test func cadenceTracks60And120HzMissesAndExcludesIdle() {
        var tracker = DisplayCadenceTracker()
        let sixty = 1.0 / 60.0
        tracker.note(
            frame: UIKitTimelineDisplayFrame(timestamp: 1, targetTimestamp: 1 + sixty, duration: sixty),
            phase: .dragging,
            drew: true,
            completedAt: 1 + sixty / 2
        )
        tracker.note(
            frame: UIKitTimelineDisplayFrame(timestamp: 1 + sixty, targetTimestamp: 1 + 2 * sixty, duration: sixty),
            phase: .dragging,
            drew: true,
            completedAt: 1 + 1.5 * sixty
        )
        #expect(tracker.snapshot.intervalSamples == 1)
        #expect(abs(tracker.snapshot.intervalTotal - sixty) < 0.000_001)
        #expect(tracker.snapshot.intervalMisses == 0)

        tracker.note(
            frame: UIKitTimelineDisplayFrame(timestamp: 10, targetTimestamp: 10.5, duration: 0.5),
            phase: .idle,
            drew: false,
            completedAt: 10
        )
        let afterIdle = tracker.snapshot
        let oneTwenty = 1.0 / 120.0
        tracker.note(
            frame: UIKitTimelineDisplayFrame(timestamp: 20, targetTimestamp: 20 + oneTwenty, duration: oneTwenty),
            phase: .decelerating,
            drew: true,
            completedAt: 20 + 2 * oneTwenty
        )
        tracker.note(
            frame: UIKitTimelineDisplayFrame(
                timestamp: 20 + 2 * oneTwenty,
                targetTimestamp: 20 + 3 * oneTwenty,
                duration: oneTwenty
            ),
            phase: .decelerating,
            drew: true,
            completedAt: 20 + 4 * oneTwenty
        )
        #expect(tracker.snapshot.intervalSamples == afterIdle.intervalSamples + 1)
        #expect(tracker.snapshot.intervalMisses == 1)
        #expect(tracker.snapshot.deadlineMisses == 2)
    }

    @Test func presentationTimingSeparatesIntervalsDropsAndLateFrames() {
        let accumulator = PresentationTimingAccumulator()
        accumulator.note(presentedTime: 1, targetTimestamp: 1, targetInterval: 1.0 / 120.0)
        accumulator.note(
            presentedTime: 1 + 1.0 / 120.0,
            targetTimestamp: 1 + 1.0 / 120.0,
            targetInterval: 1.0 / 120.0
        )
        accumulator.note(presentedTime: nil, targetTimestamp: 2, targetInterval: 1.0 / 120.0)
        accumulator.note(presentedTime: 2.02, targetTimestamp: 2, targetInterval: 1.0 / 120.0)

        let snapshot = accumulator.drain()
        #expect(snapshot.presented == 3)
        #expect(snapshot.dropped == 1)
        #expect(snapshot.intervalSamples == 2)
        #expect(snapshot.late == 1)
        #expect(accumulator.drain() == PresentationTimingSnapshot())
    }

    @Test func accessibilityUpdatesFramesIncrementallyAndSemanticsOnlyForRealInputs() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let provider = UIKitTimelineGridAccessibilityProvider(container: container)
        let original = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "one"),
            captureTime: Date(timeIntervalSince1970: 100),
            mediaType: "image/jpeg"
        )
        let second = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "two"),
            captureTime: Date(timeIntervalSince1970: 200),
            mediaType: "image/jpeg"
        )
        func slot(_ index: Int, y: CGFloat) -> GridSlot {
            let rect = CGRect(x: 0, y: y, width: 80, height: 80)
            return GridSlot(
                index: index, section: 0, item: index, column: 0, row: index,
                slotRect: rect, viewportRect: rect
            )
        }

        provider.rebuild(
            items: [original, second],
            visibleSlots: [slot(0, y: 0)],
            selectedUIDs: [],
            selectionMode: false,
            localizationIdentifier: "en",
            frameForSlot: \.viewportRect
        )
        let element = try #require(provider.elements.first)
        #expect(provider.membershipUpdateCount == 1)
        #expect(element.semanticUpdateCount == 1)

        provider.rebuild(
            items: [original, second],
            visibleSlots: [slot(0, y: 12)],
            selectedUIDs: [],
            selectionMode: false,
            localizationIdentifier: "en",
            frameForSlot: \.viewportRect
        )
        #expect(provider.membershipUpdateCount == 1)
        #expect(element.semanticUpdateCount == 1)
        #expect(element.accessibilityFrameInContainerSpace.origin.y == 12)

        provider.rebuild(
            items: [original, second],
            visibleSlots: [slot(0, y: 12)],
            selectedUIDs: [original.uid],
            selectionMode: true,
            localizationIdentifier: "en",
            frameForSlot: \.viewportRect
        )
        #expect(element.semanticUpdateCount == 2)

        let changedMetadata = PhotoItem(
            uid: original.uid,
            captureTime: Date(timeIntervalSince1970: 300),
            mediaType: "video/quicktime"
        )
        provider.rebuild(
            items: [changedMetadata, second],
            visibleSlots: [slot(0, y: 12)],
            selectedUIDs: [original.uid],
            selectionMode: true,
            localizationIdentifier: "en",
            frameForSlot: \.viewportRect
        )
        #expect(element.semanticUpdateCount == 3)
        provider.rebuild(
            items: [changedMetadata, second],
            visibleSlots: [slot(0, y: 12)],
            selectedUIDs: [original.uid],
            selectionMode: true,
            localizationIdentifier: "de",
            frameForSlot: \.viewportRect
        )
        #expect(element.semanticUpdateCount == 4)

        provider.rebuild(
            items: [changedMetadata, second],
            visibleSlots: [slot(1, y: 12)],
            selectedUIDs: [],
            selectionMode: false,
            localizationIdentifier: "de",
            frameForSlot: \.viewportRect
        )
        #expect(provider.membershipUpdateCount == 2)
        #expect(provider.elements.first?.uid == second.uid)

        let oldElement = try #require(provider.elements.first)
        let replacementContainer = UIView(frame: container.frame)
        provider.container = replacementContainer
        provider.rebuild(
            items: [changedMetadata, second],
            visibleSlots: [slot(1, y: 24)],
            selectedUIDs: [],
            selectionMode: false,
            localizationIdentifier: "de",
            frameForSlot: \.viewportRect
        )
        let replacementElement = try #require(provider.elements.first)
        #expect(provider.membershipUpdateCount == 3)
        #expect(replacementElement !== oldElement)
        #expect(replacementElement.accessibilityContainer as? UIView === replacementContainer)
    }
}
