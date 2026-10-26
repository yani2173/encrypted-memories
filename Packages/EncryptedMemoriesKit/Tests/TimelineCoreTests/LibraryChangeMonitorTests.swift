import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct LibraryChangeMonitorTests {
    @Test(.timeLimit(.minutes(1)))
    func legacyCustomPolicyKeepsImmediateTrailingRefreshes() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(
            provider: provider, policy: .init(interval: .seconds(5), failureInterval: .seconds(5)), initialToken: "a"
        ) {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        await provider.set("b")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(2))
        await provider.set("c")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(3))
        let observedTimes = await timeline.times
        #expect(observedTimes == [.seconds(5), .seconds(10)])
        #expect(await monitor.testingBaseline() == "c")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedClockRegistrationKeepsTheAbsoluteMonitorQuietDeadline() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let sequence = MonitorSleepSequence()
        let entered = TestSignal()
        let release = TestSignal()
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let dependency = TimelineRefreshClock(
            now: { clock.now },
            sleep: { duration in
                if await sequence.nextIsThird() {
                    await entered.signal()
                    await release.wait()
                }
                try await clock.dependency.sleep(duration)
            },
            sleepUntil: { deadline in
                await entered.signal()
                await release.wait()
                try await clock.dependency.sleepUntil(deadline)
            }
        )
        let monitor = LibraryChangeMonitor(clock: dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        await provider.set("b")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(2))
        await provider.set("c")
        clock.advance(by: .seconds(5))
        await entered.wait()
        clock.advance(by: .seconds(25))
        await release.signal()
        #expect(await timeline.waitForLoadOrSleep(after: 1, clock: clock))
        if await timeline.times.count < 2, clock.pendingSleeps > 0 { clock.advanceToNextSleep() }
        #expect(await clock.waitForSleepCount(4))
        let observedTimes = await timeline.times
        #expect(observedTimes == [.seconds(5), .seconds(35)])
        #expect(await monitor.testingBaseline() == "c")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedDeadlineAttemptsRetainTheFirstPendingChangeAcrossNewTokens() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("0")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "0") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            let count = await timeline.times.count
            return count == 2 || count == 3 ? .retry : .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...16 {
            await provider.set(String(tick))
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
            if tick == 14 || tick == 15 { #expect(await monitor.testingBaseline() == "1") }
        }
        let observedTimes = await timeline.times
        #expect(observedTimes == [.seconds(5), .seconds(70), .seconds(75), .seconds(80)])
        #expect(await monitor.testingBaseline() == "16")
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func overduePendingChangesKeepRetryBackoffAndRequireAPublishedRevision() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            switch await timeline.times.count {
            case 2, 3: return .retry
            case 4: return .refreshed(token: nil)
            default: return .refreshed(token: token)
            }
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...8 {
            if tick == 1 { await provider.set("b") }
            if tick == 2 { await provider.set("c") }
            if tick == 3 { await provider.set("d") }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        #expect(await monitor.testingBaseline() == "b")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(10))
        #expect(await monitor.testingBaseline() == "b")
        clock.advance(by: .seconds(10))
        #expect(await clock.waitForSleepCount(11))
        #expect(await monitor.testingBaseline() == "b")
        clock.advance(by: .seconds(20))
        #expect(await clock.waitForSleepCount(12))
        let observedTimes = await timeline.times
        #expect(observedTimes == [.seconds(5), .seconds(40), .seconds(45), .seconds(55), .seconds(75)])
        #expect(Array(clock.requestedSleeps.suffix(4)) == [.seconds(5), .seconds(10), .seconds(20), .seconds(5)])
        #expect(await monitor.testingBaseline() == "d")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func expiredBurstDeadlineDoesNotBypassAFilteredRouteDeferral() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return await timeline.times.count == 2 ? .refreshedWithoutRevision : .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...20 {
            if tick == 1 { await provider.set("b") }
            if tick == 2 { await provider.set("c") }
            if tick == 3 { await provider.set("d") }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        let beforeResume = await timeline.times
        #expect(beforeResume == [.seconds(5), .seconds(40)])
        #expect(await monitor.testingBaseline() == "b")
        await monitor.resumeDeferredRefresh()
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(22))
        let afterResume = await timeline.times
        #expect(afterResume == [.seconds(5), .seconds(40), .seconds(105)])
        #expect(await monitor.testingBaseline() == "d")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationRetiresThePendingBurstAndRestartKeepsFirstChangeFreshness() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        let refresh: @Sendable () async -> LibraryChangeRefreshOutcome = {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        await monitor.start(provider: provider, initialToken: "a", onChange: refresh)
        #expect(await clock.waitForSleepCount(1))
        await provider.set("b")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(2))
        await provider.set("c")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(3))
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
        clock.advance(by: .seconds(60))
        #expect(await timeline.times == [.seconds(5)])
        #expect(await monitor.testingBaseline() == "b")
        await monitor.start(provider: provider, initialToken: "a", onChange: refresh)
        #expect(await clock.waitForSleepCount(4))
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(5))
        let observedTimes = await timeline.times
        #expect(observedTimes == [.seconds(5), .seconds(75)])
        #expect(await monitor.testingBaseline() == "c")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func foreignBurstKeepsFirstRefreshImmediateAndCoalescesOnlyTrailingChanges() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let published = await provider.currentToken()
            await timeline.record(clock.now - origin, token: published)
            return .refreshed(token: published)
        }

        #expect(await clock.waitForSleepCount(1))
        for second in stride(from: 5, through: 70, by: 5) {
            switch second {
            case 5: await provider.set("b")
            case 10: await provider.set("c")
            case 15: await provider.set("d")
            case 70: await provider.set("e")
            default: break
            }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(second / 5 + 1))
            if second == 5 {
                #expect(await timeline.times == [.seconds(5)], "The isolated first change keeps five-second freshness")
            }
            if second == 15 || second == 35 {
                #expect(await timeline.times == [.seconds(5)], "Trailing changes wait for twenty-five seconds of quiet")
            }
            if second == 40 {
                #expect(await timeline.times == [.seconds(5), .seconds(40)])
                #expect(await monitor.testingBaseline() == "d")
            }
        }
        let observedTimes = await timeline.times
        let observedTokens = await timeline.tokens
        #expect(observedTimes == [.seconds(5), .seconds(40), .seconds(70)])
        #expect(observedTokens == ["b", "d", "e"], "A later isolated change refreshes on its next probe")
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func continuousForeignChangesCannotResetTheFirstDeferredDeadline() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("0")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "0") {
            let published = await provider.currentToken()
            await timeline.record(clock.now - origin, token: published)
            return .refreshed(token: published)
        }

        #expect(await clock.waitForSleepCount(1))
        for tick in 1...14 {
            await provider.set(String(tick))
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
            if tick == 13 {
                #expect(
                    await timeline.times == [.seconds(5)], "The first deferred change at ten seconds owns the deadline")
            }
        }
        let observedTimes = await timeline.times
        let observedTokens = await timeline.tokens
        #expect(
            observedTimes == [.seconds(5), .seconds(70)],
            "Sixty seconds from the first deferred change bounds the burst")
        #expect(observedTokens == ["1", "14"])
        #expect(await monitor.testingBaseline() == "14")
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func controlledClockPreservesForegroundProbeAndPublishedBaseline() async {
        let clock = TimelineRefreshTestClock()
        let provider = TokenProvider("new")
        let refreshes = Counter()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "old") {
            await refreshes.increment()
            return .refreshed(token: "new")
        }

        #expect(await clock.waitForSleepCount(1))
        #expect(clock.requestedSleeps == [.seconds(5)])
        #expect(await provider.probeCount == 0)
        clock.advance(by: .seconds(4))
        #expect(await refreshes.value == 0)
        clock.advance(by: .seconds(1))
        #expect(await clock.waitForSleepCount(2))
        #expect(await refreshes.value == 1)
        #expect(await monitor.testingBaseline() == "new")

        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(3))
        #expect(await refreshes.value == 1)
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func controlledClockPreservesUnacknowledgedRetryAndCancellation() async {
        let clock = TimelineRefreshTestClock()
        let provider = TokenProvider("new")
        let refreshes = Counter()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "old") {
            await refreshes.increment()
            return await refreshes.value == 1 ? .retry : .refreshed(token: "new")
        }

        #expect(await clock.waitForSleepCount(1))
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(2))
        #expect(await refreshes.value == 1)
        #expect(await monitor.testingBaseline() == "old")
        #expect(clock.requestedSleeps == [.seconds(5), .seconds(5)])

        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(3))
        #expect(await refreshes.value == 2)
        #expect(await monitor.testingBaseline() == "new")
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test func refreshesOnlyAfterOpaqueTokenChanges() async throws {
        let provider = TokenProvider("a")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(5), failureInterval: .milliseconds(5))
        ) {
            await counter.increment()
            return .refreshed(token: "b")
        }

        try await Task.sleep(for: .milliseconds(18))
        #expect(await counter.value == 0)

        await provider.set("b")
        let deadline = ContinuousClock.now + .seconds(2)
        while await counter.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test func stopAndRestartPreservesBaselineForChangesWhileSuspended() async throws {
        let provider = TokenProvider("a")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        let policy = LibraryChangePollingPolicy(
            interval: .milliseconds(5), failureInterval: .milliseconds(5))
        await monitor.start(provider: provider, policy: policy) {
            await counter.increment()
            return .refreshed(token: "b")
        }
        try await Task.sleep(for: .milliseconds(12))
        await monitor.stop()

        await provider.set("b")
        await monitor.restart(provider: provider, policy: policy) {
            await counter.increment()
            return .refreshed(token: "b")
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await counter.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test func failedRefreshDoesNotConsumeChangedToken() async throws {
        let provider = TokenProvider("a")
        let attempts = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(5), failureInterval: .milliseconds(5))
        ) {
            await attempts.increment()
            return await attempts.value > 1 ? .refreshed(token: "b") : .retry
        }

        try await Task.sleep(for: .milliseconds(12))
        await provider.set("b")
        let deadline = ContinuousClock.now + .seconds(2)
        while await attempts.value < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await attempts.value == 2)
        await monitor.stop()
    }

    @Test func theWaitForALibraryThatHasNotCaughtUpDoublesUpToItsLimit() {
        let policy = LibraryChangePollingPolicy.foreground
        let delays = (1...7).map { policy.refreshRetryDelay(afterRetries: $0) }

        #expect(
            delays == [.seconds(5), .seconds(10), .seconds(20), .seconds(30), .seconds(30), .seconds(30), .seconds(30)])
        // The listing lag of about 90 seconds needs about six loads, not eighteen.
        var waited = Duration.zero
        var loads = 0
        while waited < .seconds(90) {
            loads += 1
            waited += policy.refreshRetryDelay(afterRetries: loads)
        }
        #expect(loads <= 6)
        let fixed = LibraryChangePollingPolicy(interval: .seconds(5), failureInterval: .seconds(5))
        #expect(fixed.refreshRetryDelay(afterRetries: 4) == .seconds(5), "without a limit the wait stays the same")
    }

    @Test func aNewerEventTokenStartsTheWaitAgainAtTheShortestInterval() {
        let policy = LibraryChangePollingPolicy.foreground
        var count = LibraryChangeRetryCount()

        let behindB = (0..<5).map { _ in count.nextDelay(for: "b", policy: policy) }
        #expect(behindB == [.seconds(5), .seconds(10), .seconds(20), .seconds(30), .seconds(30)])
        #expect(count.nextDelay(for: "c", policy: policy) == .seconds(5), "a newer change waits the shortest time")
        #expect(count.nextDelay(for: "c", policy: policy) == .seconds(10))

        count.reset()
        #expect(count.nextDelay(for: "c", policy: policy) == .seconds(5), "a load that caught up starts again")
    }

    @Test(.timeLimit(.minutes(1)))
    func seededBaselineDetectsMutationBeforeFirstPoll() async {
        let provider = TokenProvider("new")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero),
            initialToken: "cached"
        ) {
            await counter.increment()
            return .refreshed(token: "new")
        }

        // The second probe proves that the first changed token was accepted and committed.
        await provider.waitUntilProbeCount(2)
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func restartDoesNotReplaceANewerRetainedBaselineWithStartupSeed() async {
        let provider = TokenProvider("a")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        let policy = LibraryChangePollingPolicy(
            interval: .zero, failureInterval: .zero)
        await monitor.start(provider: provider, policy: policy, initialToken: "a") {
            await counter.increment()
            return .refreshed(token: "b")
        }
        await provider.set("b")
        let countAfterMutation = await provider.probeCount
        // One probe observes the mutation. The next proves that the new baseline was committed.
        await provider.waitUntilProbeCount(countAfterMutation + 2)
        #expect(await counter.value == 1)
        await monitor.stop()

        let countBeforeRestart = await provider.probeCount
        await monitor.start(provider: provider, policy: policy, initialToken: "a") {
            await counter.increment()
            return .refreshed(token: "b")
        }
        await provider.waitUntilProbeCount(countBeforeRestart + 1)
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func stopWaitsForANonCooperativeProbeBeforeReturning() async {
        let provider = BlockingTokenProvider()
        let completion = CompletionProbe()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero)
        ) {
            Issue.record("A cancelled probe must not publish a library change")
            return .refreshed(token: "b")
        }

        await provider.waitUntilEntered()
        let stopTask = Task {
            await monitor.stop()
            await completion.markComplete()
        }
        await provider.waitUntilCancellationObserved()

        #expect(await completion.isComplete == false)
        await provider.release()
        await stopTask.value
        #expect(await completion.isComplete)
    }

    @Test(.timeLimit(.minutes(1)))
    func startDuringStopRunsAfterTheRetiringProbeReturns() async {
        let retiringProvider = BlockingTokenProvider()
        let replacementProvider = TokenProvider("replacement")
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: retiringProvider,
            policy: .init(interval: .zero, failureInterval: .zero)
        ) {
            Issue.record("A cancelled probe must not publish a library change")
            return .refreshed(token: "b")
        }

        await retiringProvider.waitUntilEntered()
        let stopTask = Task { await monitor.stop() }
        await retiringProvider.waitUntilCancellationObserved()

        // This request arrives while stop() is suspended on a non-cooperative probe.
        // It must become the active monitor after that probe retires, rather than being dropped.
        await monitor.start(
            provider: replacementProvider,
            policy: .init(interval: .zero, failureInterval: .zero)
        ) {
            .refreshed(token: "b")
        }
        await retiringProvider.release()
        await stopTask.value

        #expect(await replacementProvider.observesProbeCount(1))
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalScopeFailureRetiresTaskBeforeHostRecoveryRestartsMonitor() async {
        let provider = TerminalTokenProvider()
        let replacement = TokenProvider("replacement")
        let terminalCallbacks = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero),
            onTerminal: { _ in
                await terminalCallbacks.increment()
                await monitor.restart(
                    provider: replacement,
                    policy: .init(interval: .zero, failureInterval: .zero)
                ) {
                    .refreshed(token: "b")
                }
            },
            onChange: {
                Issue.record("A terminal scope failure must not publish a library change")
                return .refreshed(token: "b")
            }
        )

        await provider.waitUntilProbed()
        await replacement.waitUntilProbeCount(1)

        #expect(await provider.probeCount == 1)
        #expect(await terminalCallbacks.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalRefreshOutcomeRetiresTaskBeforeCallingHostRecovery() async {
        let provider = TokenProvider("new")
        let terminalCallbacks = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero),
            initialToken: "old",
            onTerminal: { _ in await terminalCallbacks.increment() },
            onChange: { .terminal }
        )

        await provider.waitUntilProbeCount(1)
        while await terminalCallbacks.value == 0 { await Task.yield() }

        #expect(await provider.probeCount == 1)
        #expect(await terminalCallbacks.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func unconfirmableRefreshIsNotRepeatedForTheSameTokenAndKeepsTheBaseline() async throws {
        let provider = TokenProvider("a")
        let refreshes = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: "a"
        ) {
            await refreshes.increment()
            return .refreshedWithoutRevision
        }

        await provider.set("b")
        await refreshes.waitUntil { $0 >= 1 }
        await provider.waitUntilProbeCount(await provider.probeCount + 20)
        #expect(await refreshes.value == 1)
        #expect(await monitor.testingBaseline() == "a")

        await provider.set("c")
        await refreshes.waitUntil { $0 >= 2 }
        await provider.waitUntilProbeCount(await provider.probeCount + 20)
        #expect(await refreshes.value == 2)
        #expect(await monitor.testingBaseline() == "a")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeRefreshesTheDeferredTokenAgainAndConfirmsIt() async throws {
        let provider = TokenProvider("a")
        let refreshes = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: "a"
        ) {
            await refreshes.increment()
            return await refreshes.value == 1 ? .refreshedWithoutRevision : .refreshed(token: "b")
        }

        await provider.set("b")
        await refreshes.waitUntil { $0 >= 1 }
        await provider.waitUntilProbeCount(await provider.probeCount + 20)
        #expect(await refreshes.value == 1)

        await monitor.resumeDeferredRefresh()
        await monitor.waitUntilBaseline("b")
        await provider.waitUntilProbeCount(await provider.probeCount + 20)
        #expect(await refreshes.value == 2)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeDuringARefreshKeepsTheTokenPendingForAnotherRefresh() async throws {
        let provider = TokenProvider("a")
        let refreshes = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: "a"
        ) {
            await refreshes.increment()
            if await refreshes.value == 1 {
                await monitor.resumeDeferredRefresh()
                return .refreshedWithoutRevision
            }
            return .refreshed(token: "b")
        }

        await provider.set("b")
        await monitor.waitUntilBaseline("b")
        #expect(await refreshes.value == 2)
        await monitor.stop()
    }
    @Test(.timeLimit(.minutes(1)))
    func matchedRefreshClosesTheFirstBurstBeforeTheNextBurst() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("0")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "0") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...21 {
            if tick <= 16 { await provider.set(String(tick)) }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        let observedTimes = await timeline.times
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
        #expect(
            observedTimes == [.seconds(5), .seconds(70), .seconds(105)],
            "A matched refresh closes the old burst before the next burst waits for quiet")
    }

    @Test(.timeLimit(.minutes(1)))
    func filteredRefreshClosesTheFirstBurstBeforeLaterFilteredChanges() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return await timeline.times.count == 1 ? .refreshed(token: token) : .refreshedWithoutRevision
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...27 {
            switch tick {
            case 1: await provider.set("b")
            case 2: await provider.set("c")
            case 20: await provider.set("d")
            case 21: await provider.set("e")
            case 22: await provider.set("f")
            default: break
            }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        let observedTimes = await timeline.times
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
        #expect(
            observedTimes == [.seconds(5), .seconds(35), .seconds(100), .seconds(135)],
            "A completed filtered refresh cannot make later filtered changes bypass quiet")
    }

    @Test(.timeLimit(.minutes(1)))
    func stableBaselineAfterUnpairedPublicationClosesTheFirstBurst() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            if await timeline.times.count == 2 {
                await provider.set("d")
                return .refreshed(token: "d")
            }
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...15 {
            switch tick {
            case 1: await provider.set("b")
            case 2: await provider.set("c")
            case 9: await provider.set("e")
            case 10: await provider.set("f")
            default: break
            }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        let observedTimes = await timeline.times
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
        #expect(
            observedTimes == [.seconds(5), .seconds(35), .seconds(45), .seconds(75)],
            "A stable published baseline closes the old burst before later changes")
    }

    @Test(.timeLimit(.minutes(1)))
    func aChangeAtExactlyTheQuietDeadlineRefreshesInsteadOfRestartingTheWait() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...7 {
            switch tick {
            case 1: await provider.set("b")  // refreshes at 5 seconds
            case 2: await provider.set("c")  // the first deferred change at 10 seconds: quiet deadline at 35 seconds
            case 7: await provider.set("d")  // arrives at exactly 35 seconds
            default: break
            }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        #expect(
            await timeline.times == [.seconds(5), .seconds(35)],
            "A change at exactly 25 seconds of quiet ends the burst; it does not start the wait again")
        #expect(await timeline.tokens == ["b", "d"])
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedProbeDuringAPendingBurstDoesNotWaitPastItsDeadline() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...7 {
            switch tick {
            case 1: await provider.set("b")
            case 2: await provider.set("c")  // the quiet deadline of this burst is 35 seconds
            case 6: await provider.failNextProbes(1)  // the probe at 30 seconds fails
            default: break
            }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
            if tick == 6 {
                #expect(
                    clock.requestedSleeps.last == .seconds(5),
                    "The failure wait of 30 seconds is cut to the 5 seconds left until the deadline")
            }
        }
        #expect(await timeline.times == [.seconds(5), .seconds(35)])
        #expect(await timeline.tokens == ["b", "c"])
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedProbeAtOrAfterTheDeadlineKeepsTheFullFailureWait() async {
        let clock = TimelineRefreshTestClock()
        let provider = TokenProvider("a")
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "a") { .refreshed(token: await provider.currentToken()) }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...7 {
            switch tick {
            case 1: await provider.set("b")
            case 2: await provider.set("c")
            case 7: await provider.failNextProbes(2)  // the probes at the deadline and after it fail
            default: break
            }
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        #expect(
            clock.requestedSleeps.last == .seconds(30),
            "A probe that fails exactly at the deadline adds no shorter wait: it is not polled every few seconds")
        clock.advance(by: .seconds(30))
        #expect(await clock.waitForSleepCount(9))
        #expect(
            clock.requestedSleeps.last == .seconds(30),
            "A probe that fails after the deadline waits the full failure interval as well")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aShortenedFailureWaitKeepsTheAbsoluteDeadlineWhenTheClockRegistersLate() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("a")
        let timeline = MonitorRefreshTimeline()
        let arm = HeldSleepArm()
        let entered = TestSignal()
        let release = TestSignal()
        let dependency = TimelineRefreshClock(
            now: { clock.now },
            sleep: { duration in
                if await arm.takeIfArmed() {
                    await entered.signal()
                    await release.wait()
                }
                try await clock.dependency.sleep(duration)
            },
            sleepUntil: { deadline in
                if await arm.takeIfArmed() {
                    await entered.signal()
                    await release.wait()
                }
                try await clock.dependency.sleepUntil(deadline)
            }
        )
        let monitor = LibraryChangeMonitor(clock: dependency)
        await monitor.start(provider: provider, initialToken: "a") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        await provider.set("b")
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(2))
        await provider.set("c")  // the first deferred change at 10 seconds: quiet deadline at 35 seconds
        for tick in 2...5 {
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        // The probe at 30 seconds fails. The clock registers the shortened wait only after 40 seconds.
        await arm.arm()
        await provider.failNextProbes(1)
        clock.advance(by: .seconds(5))
        await entered.wait()
        clock.advance(by: .seconds(10))
        await release.signal()
        #expect(await timeline.waitForLoadOrSleep(after: 1, clock: clock))
        if await timeline.times.count < 2, clock.pendingSleeps > 0 { clock.advanceToNextSleep() }
        #expect(await clock.waitForSleepCount(8))
        #expect(
            await timeline.times == [.seconds(5), .seconds(40)],
            "The wait ends at the deadline of 35 seconds, not five seconds after the late registration")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondContinuousBurstIsBoundedByItsOwnCap() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let provider = TokenProvider("0")
        let timeline = MonitorRefreshTimeline()
        let monitor = LibraryChangeMonitor(clock: clock.dependency)
        await monitor.start(provider: provider, initialToken: "0") {
            let token = await provider.currentToken()
            await timeline.record(clock.now - origin, token: token)
            return .refreshed(token: token)
        }
        #expect(await clock.waitForSleepCount(1))
        for tick in 1...27 {
            await provider.set(String(tick))
            clock.advance(by: .seconds(5))
            #expect(await clock.waitForSleepCount(tick + 1))
        }
        #expect(
            await timeline.times == [.seconds(5), .seconds(70), .seconds(135)],
            "Each burst is bounded by sixty seconds from its own first deferred change")
        #expect(await timeline.tokens == ["1", "14", "27"])
        await monitor.stop()
        #expect(clock.pendingSleeps == 0)
    }
}

private struct TokenProbeFailure: Error {}

private actor HeldSleepArm {
    private var armed = false

    func arm() { armed = true }

    func takeIfArmed() -> Bool {
        defer { armed = false }
        return armed
    }
}

private actor TokenProvider: LibraryChangeTokenProvider {
    private var token: String
    private(set) var probeCount = 0
    private var failingProbes = 0
    private var probeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ token: String) { self.token = token }

    func set(_ token: String) { self.token = token }
    func currentToken() -> String { token }
    /// The next probes fail, as when the server is unreachable.
    func failNextProbes(_ count: Int) { failingProbes = count }

    func libraryChangeToken() async throws -> String {
        probeCount += 1
        if failingProbes > 0 {
            failingProbes -= 1
            throw TokenProbeFailure()
        }
        let completed = probeWaiters.filter { probeCount >= $0.count }
        probeWaiters.removeAll { probeCount >= $0.count }
        for waiter in completed {
            waiter.continuation.resume()
        }
        return token
    }

    func waitUntilProbeCount(_ count: Int) async {
        guard probeCount < count else { return }
        await withCheckedContinuation { continuation in
            probeWaiters.append((count, continuation))
        }
    }

    func observesProbeCount(_ count: Int, withinSchedulerTurns turns: Int = 10_000) async -> Bool {
        for _ in 0..<turns {
            if probeCount >= count { return true }
            await Task.yield()
        }
        return probeCount >= count
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }

    /// Bounded, so a regression fails an expectation instead of hanging the run.
    func waitUntil(_ condition: (Int) -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(value), ContinuousClock.now < deadline { await Task.yield() }
    }
}

extension LibraryChangeMonitor {
    fileprivate func waitUntilBaseline(_ token: String) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while testingBaseline() != token, ContinuousClock.now < deadline { await Task.yield() }
    }
}

private actor BlockingTokenProvider: LibraryChangeTokenProvider {
    private let entered = TestSignal()
    private let cancellationObserved = TestSignal()
    private let releaseSignal = TestSignal()

    func libraryChangeToken() async throws -> String {
        await entered.signal()
        while !Task.isCancelled {
            await Task.yield()
        }
        await cancellationObserved.signal()
        await releaseSignal.wait()
        return "cancelled-probe"
    }

    func waitUntilEntered() async { await entered.wait() }
    func waitUntilCancellationObserved() async { await cancellationObserved.wait() }
    func release() async { await releaseSignal.signal() }
}

private struct ExpectedTerminalLibraryChangeError: LibraryChangeTerminalError {}

private actor TerminalTokenProvider: LibraryChangeTokenProvider {
    private(set) var probeCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func libraryChangeToken() async throws -> String {
        probeCount += 1
        waiter?.resume()
        waiter = nil
        throw ExpectedTerminalLibraryChangeError()
    }

    func waitUntilProbed() async {
        guard probeCount == 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor TestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Shared by the two refresh suites. Advances release only deadlines that the test reaches.
final class TimelineRefreshTestClock: @unchecked Sendable {
    private struct Sleep {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: Sleep] = [:]
    private var requests: [Duration] = []

    var dependency: TimelineRefreshClock {
        .init(
            now: { self.now }, sleep: { try await self.sleep(for: $0) },
            sleepUntil: { try await self.sleep(until: $0) }
        )
    }

    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var requestedSleeps: [Duration] { lock.withLock { requests } }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    @discardableResult
    func advanceToNextSleep() -> Bool {
        guard let deadline = lock.withLock({ sleepers.values.map(\.deadline).min() }) else { return false }
        advance(by: max(.zero, deadline - now))
        return true
    }

    func advance(by duration: Duration) {
        let completed = lock.withLock {
            instant += duration
            let due = sleepers.filter { $0.value.deadline <= instant }
            for id in due.keys { sleepers.removeValue(forKey: id) }
            return due.values.map(\.continuation)
        }
        for continuation in completed { continuation.resume() }
    }

    func waitForSleepCount(_ count: Int) async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while requestedSleeps.count < count, ContinuousClock.now < timeout { await Task.yield() }
        return requestedSleeps.count >= count
    }

    private func sleep(for duration: Duration) async throws {
        try await sleep(until: now + duration)
    }

    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admission = lock.withLock {
                    guard !Task.isCancelled else { return (cancelled: true, elapsed: false) }
                    requests.append(max(.zero, deadline - instant))
                    guard deadline > instant else { return (cancelled: false, elapsed: true) }
                    sleepers[id] = Sleep(deadline: deadline, continuation: continuation)
                    return (cancelled: false, elapsed: false)
                }
                if admission.cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if admission.elapsed {
                    continuation.resume()
                }
            }
        } onCancel: {
            let removed = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            removed?.continuation.resume(throwing: CancellationError())
        }
    }
}

private actor MonitorRefreshTimeline {
    private(set) var times: [Duration] = []
    private(set) var tokens: [String] = []

    func waitForLoadOrSleep(after count: Int, clock: TimelineRefreshTestClock) async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while times.count <= count, clock.pendingSleeps == 0, ContinuousClock.now < timeout { await Task.yield() }
        return times.count > count || clock.pendingSleeps > 0
    }

    func record(_ time: Duration, token: String) {
        times.append(time)
        tokens.append(token)
    }
}

private actor MonitorSleepSequence {
    private var count = 0

    func nextIsThird() -> Bool {
        count += 1
        return count == 3
    }
}
