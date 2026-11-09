import MetalGridComposeCore
import Testing

@Suite struct MetalGridPlaceholderScrollTests {
    @Test func newlyVisibleLoadingTilesStartOneNewBoundedSweepAtScrollEnd() {
        var pulse = expiredPulse()
        var scroll = MetalGridPlaceholderScrollTracker<String>()
        scroll.began(visibleIDs: ["old"])
        #expect(
            scroll.ended(
                visibleIDs: ["old", "new"], isVisible: true, reduceMotion: false,
                isLoading: { _ in true }, pulse: &pulse))
        pulse.update(loadingCount: 2, now: 10)
        #expect(pulse.isAnimating, "The expired sweep must restart for a newly visible loading photo")
        #expect(
            !scroll.ended(
                visibleIDs: ["old", "new"], isVisible: true, reduceMotion: false,
                isLoading: { _ in true }, pulse: &pulse),
            "One scroll-end notification cannot restart the sweep twice")
        pulse.update(loadingCount: 2, now: 10 + MetalGridPlaceholderPulse.maximumDuration)
        #expect(!pulse.isAnimating, "A scroll restart keeps the existing episode bound")
    }

    @Test func unchangedFailedHiddenAndReducedMotionTilesDoNotRestart() {
        verifyNoRestart(start: nil, end: ["new"], loading: ["new"])
        verifyNoRestart(start: ["old"], end: ["old"], loading: ["old"])
        verifyNoRestart(start: ["old"], end: ["old", "failed", "unavailable"], loading: ["old"])
        verifyNoRestart(start: ["old"], end: ["new"], loading: ["new"], visible: false)
        verifyNoRestart(start: ["old"], end: ["new"], loading: ["new"], reduceMotion: true)
    }

    @Test func hidingTheGridRetiresAnUnfinishedScroll() {
        var pulse = expiredPulse()
        var scroll = MetalGridPlaceholderScrollTracker<String>()
        scroll.began(visibleIDs: ["old"])
        scroll.reset()
        #expect(
            !scroll.ended(
                visibleIDs: ["new"], isVisible: true, reduceMotion: false,
                isLoading: { _ in true }, pulse: &pulse))
        pulse.update(loadingCount: 1, now: 10)
        #expect(!pulse.isAnimating)
    }

    private func verifyNoRestart(
        start: [String]?, end: [String], loading: Set<String>, visible: Bool = true, reduceMotion: Bool = false
    ) {
        var pulse = expiredPulse()
        var scroll = MetalGridPlaceholderScrollTracker<String>()
        if let start { scroll.began(visibleIDs: start) }
        #expect(
            !scroll.ended(
                visibleIDs: end, isVisible: visible, reduceMotion: reduceMotion,
                isLoading: loading.contains, pulse: &pulse))
        pulse.update(loadingCount: loading.count, now: 10)
        #expect(!pulse.isAnimating)
    }

    private func expiredPulse() -> MetalGridPlaceholderPulse {
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(loadingCount: 1, now: 0)
        pulse.update(loadingCount: 1, now: MetalGridPlaceholderPulse.maximumDuration)
        #expect(!pulse.isAnimating)
        return pulse
    }
}
