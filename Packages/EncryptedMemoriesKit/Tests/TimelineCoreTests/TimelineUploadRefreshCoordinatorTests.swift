import Foundation
import Testing

@testable import TimelineCore

@Suite struct TimelineUploadRefreshCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func aCompletedExplicitRequestRetiresWithoutReplayingItsClosure() async {
        let scenario = AutomaticUploadScenario()
        await scenario.coordinator.request(refresh: { _ in
            await scenario.timeline.record(.zero)
            return nil
        })
        #expect(await scenario.timeline.waitForCount(1))
        let timeout = ContinuousClock.now + .seconds(5)
        while await scenario.timeline.times.count < 2,
            await scenario.coordinator.testingAutomaticState().workerActive, ContinuousClock.now < timeout
        {
            await Task.yield()
        }
        let callCount = await scenario.timeline.times.count
        let state = await scenario.coordinator.testingAutomaticState()
        #expect(callCount == 1)
        #expect(state.workerActive == false)
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func aCompletedAutomaticRequestDoesNotScheduleAnUnrequestedCycle() async {
        let scenario = AutomaticUploadScenario()
        await scenario.requestSignal(0)
        #expect(await scenario.timeline.waitForCount(1))
        let timeout = ContinuousClock.now + .seconds(5)
        while await scenario.coordinator.testingAutomaticState().workerActive,
            scenario.clock.pendingSleeps == 0, ContinuousClock.now < timeout
        {
            await Task.yield()
        }
        if scenario.clock.pendingSleeps > 0 {
            scenario.clock.advanceToNextSleep()
            #expect(await scenario.timeline.waitForCount(2))
        }
        let callCount = await scenario.timeline.times.count
        #expect(callCount == 1)
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRetiredIntervalCannotClearTheReplacementOwnersWait() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let sequence = ClockWaitSequence()
        let entered = AsyncGate()
        let cancellationSeen = AsyncGate()
        let release = AsyncGate()
        let old = UploadRefreshTimeline()
        let replacement = UploadRefreshTimeline()
        let manual = UploadRefreshTimeline()
        let dependency = TimelineRefreshClock(
            now: { clock.now }, sleep: { try await clock.dependency.sleep($0) },
            sleepUntil: { deadline in
                if await sequence.takeFirst() {
                    try await withTaskCancellationHandler {
                        await entered.open()
                        await release.wait()
                        try Task.checkCancellation()
                    } onCancel: {
                        Task { await cancellationSeen.open() }
                    }
                } else {
                    try await clock.dependency.sleepUntil(deadline)
                }
            }
        )
        let coordinator = TimelineUploadRefreshCoordinator(clock: dependency)
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await old.record(.zero)
            return nil
        })
        #expect(await old.waitForCount(1))
        clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await old.record(.seconds(6))
            return nil
        })
        await entered.wait()
        let cancellation = Task { await coordinator.cancel() }
        await cancellationSeen.wait()
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await replacement.record(clock.now - origin)
            return nil
        })
        #expect(await replacement.waitForCount(1))
        clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await replacement.record(clock.now - origin)
            return nil
        })
        #expect(await replacement.waitForNewLoadOrSleep(after: 1, clock: clock))
        await release.open()
        await cancellation.value
        await coordinator.request(refresh: { _ in
            await manual.record(clock.now - origin)
            return nil
        })
        #expect(await manual.waitForNewLoadOrSleep(after: 0, clock: clock))
        if await manual.times.isEmpty, clock.pendingSleeps > 0 { clock.advanceToNextSleep() }
        #expect(await manual.waitForCount(1))
        let observedManualTimes = await manual.times
        #expect(observedManualTimes == [.seconds(12)])
        #expect(await old.times == [.zero])
        await coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingFlushSnapshotsAreCoveredByTheLatestCompletedGeneration() async {
        let scenario = AutomaticUploadScenario()
        let release = AsyncGate()
        await scenario.startTwoSignals(secondRelease: release)
        let first = Task { await scenario.coordinator.flushAutomaticUploads() }
        #expect(await scenario.waitForFlushRegistration())
        #expect(await scenario.timeline.waitForCount(2))
        scenario.clock.advance(by: .seconds(6))
        await scenario.requestSignal(2)
        let second = Task { await scenario.coordinator.flushAutomaticUploads() }
        #expect(await scenario.waitForFlushRegistration(2))
        await release.open()
        #expect(await scenario.waitForWorkerRetirement())
        let state = await scenario.coordinator.testingAutomaticState()
        #expect(state.flushCount == 0, "The completed latest generation must cover both earlier flush snapshots")
        if state.flushCount > 0 {
            await scenario.coordinator.cancel()
            await first.value
            await second.value
            return
        }
        await first.value
        await second.value
        let flushedTimes = await scenario.timeline.times
        #expect(flushedTimes == [.zero, .seconds(6), .seconds(12)])
        scenario.clock.advance(by: .seconds(6))
        await scenario.requestSignal(3)
        #expect(await scenario.timeline.waitForNewLoadOrSleep(after: 3, clock: scenario.clock))
        if scenario.clock.pendingSleeps > 0 { scenario.clock.advanceToNextSleep() }
        #expect(await scenario.timeline.waitForCount(4))
        let laterTimes = await scenario.timeline.times
        #expect(laterTimes == [.zero, .seconds(6), .seconds(12), .seconds(72)])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedClockRegistrationKeepsTheAbsoluteAutomaticDeadline() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let entered = AsyncGate()
        let release = AsyncGate()
        let timeline = UploadRefreshTimeline()
        let delayed = TimelineRefreshClock(
            now: { clock.now },
            sleep: { duration in
                await entered.open()
                await release.wait()
                try await clock.dependency.sleep(duration)
            },
            sleepUntil: { deadline in
                await entered.open()
                await release.wait()
                try await clock.dependency.sleepUntil(deadline)
            }
        )
        let coordinator = TimelineUploadRefreshCoordinator(clock: delayed)
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin)
            return nil
        })
        #expect(await timeline.waitForCount(1))
        clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin)
            return nil
        })
        await entered.wait()
        clock.advance(by: .seconds(54))
        await release.open()
        #expect(await timeline.waitForNewLoadOrSleep(after: 1, clock: clock))
        if await timeline.times.count < 2, clock.pendingSleeps > 0 { clock.advanceToNextSleep() }
        #expect(await timeline.waitForCount(2))
        let observedTimes = await timeline.times
        #expect(observedTimes == [.zero, .seconds(60)])
        await coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func unexpectedConvergenceClockFailureReportsTheFailedAttempt() async {
        let clock = TimelineRefreshTestClock()
        let recorder = RefreshAttemptRecorder(failures: [.pendingInventoryVisibility])
        let dependency = TimelineRefreshClock(
            now: { clock.now }, sleep: { _ in throw ExpectedRefreshClockFailure() },
            sleepUntil: { _ in throw ExpectedRefreshClockFailure() }
        )
        let coordinator = TimelineUploadRefreshCoordinator(clock: dependency)
        await coordinator.requestAutomaticUpload(
            refresh: { await recorder.failure(at: $0) },
            observer: { await recorder.record($0) }
        )
        let timeout = ContinuousClock.now + .seconds(5)
        while await recorder.decisions.count < 2, ContinuousClock.now < timeout { await Task.yield() }
        #expect(await recorder.callCount == 1)
        #expect(await recorder.decisions == [.retry(after: .milliseconds(350)), .failed])
        await coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func laterAutomaticSignalsKeepTheOriginalAdmissionBoundary() async {
        let scenario = AutomaticUploadScenario()
        await scenario.startTwoSignals()
        scenario.clock.advance(by: .seconds(6))
        await scenario.requestSignal(2)
        for _ in 0..<3 {
            if await scenario.timeline.times.count >= 2 { break }
            #expect(scenario.clock.advanceToNextSleep())
            #expect(await scenario.timeline.waitForNewLoadOrSleep(after: 1, clock: scenario.clock))
        }
        #expect(await scenario.flush())
        let observedTimes = await scenario.timeline.times
        let contents = await scenario.timeline.contents
        #expect(observedTimes == [.zero, .seconds(60)])
        #expect(contents == [0, 2])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func manualWakeDoesNotWaitForAnAutomaticDeadline() async {
        let scenario = AutomaticUploadScenario()
        let manual = UploadRefreshTimeline()
        await scenario.startTwoSignals()
        await scenario.coordinator.request(refresh: { _ in
            await manual.record(scenario.clock.now - scenario.origin)
            return nil
        })
        #expect(await manual.waitForNewLoadOrSleep(after: 0, clock: scenario.clock))
        if await manual.times.isEmpty, scenario.clock.pendingSleeps > 0 {
            scenario.clock.advanceToNextSleep()
        }
        #expect(await manual.waitForCount(1))
        let manualTimes = await manual.times
        #expect(manualTimes == [.seconds(6)])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func forceFlushServesAcceptedWorkBeforeTheIntervalDeadline() async {
        let scenario = AutomaticUploadScenario()
        let release = AsyncGate()
        let completion = AutomaticFlushCompletion()
        await scenario.startTwoSignals(secondRelease: release)
        let flush = Task {
            await scenario.coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        #expect(await scenario.waitForFlushRegistration())
        #expect(await scenario.timeline.waitForNewLoadOrSleep(after: 1, clock: scenario.clock))
        if await scenario.timeline.times.count < 2, scenario.clock.pendingSleeps > 0 {
            scenario.clock.advanceToNextSleep()
        }
        #expect(await scenario.timeline.waitForCount(2))
        let observedTimes = await scenario.timeline.times
        #expect(observedTimes == [.zero, .seconds(6)])
        await release.open()
        #expect(await scenario.waitForWorkerRetirement())
        #expect(await scenario.coordinator.testingAutomaticState().flushCount == 0)
        // cancel() also releases a defective leftover waiter, so cleanup cannot hide a deadlock.
        await scenario.coordinator.cancel()
        await flush.value
        #expect(await completion.isComplete)
    }

    @Test(.timeLimit(.minutes(1)))
    func currentRequestIsRecheckedAfterAConvergenceWait() async {
        let scenario = AutomaticUploadScenario()
        let old = UploadRefreshTimeline()
        let new = UploadRefreshTimeline()
        await scenario.coordinator.request(refresh: { _ in
            await old.record(scenario.clock.now - scenario.origin)
            return .pendingInventoryVisibility
        })
        #expect(await scenario.clock.waitForSleepCount(1))
        scenario.clock.advance(by: .milliseconds(100))
        await scenario.coordinator.request(refresh: { _ in
            await new.record(scenario.clock.now - scenario.origin)
            return nil
        })
        scenario.clock.advanceToNextSleep()
        #expect(await new.waitForCount(1))
        let oldTimes = await old.times
        let newTimes = await new.times
        #expect(oldTimes == [.zero])
        #expect(newTimes == [.milliseconds(350)])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func anObserverReplacementDoesNotSleepOnTheSupersededResult() async {
        let scenario = AutomaticUploadScenario()
        let latest = UploadRefreshTimeline()
        await scenario.coordinator.request(
            refresh: { _ in .pendingInventoryVisibility },
            observer: { _ in
                await scenario.coordinator.request(refresh: { _ in
                    await latest.record(scenario.clock.now - scenario.origin)
                    return nil
                })
            }
        )
        #expect(await latest.waitForNewLoadOrSleep(after: 0, clock: scenario.clock))
        if await latest.times.isEmpty, scenario.clock.pendingSleeps > 0 {
            scenario.clock.advanceToNextSleep()
        }
        #expect(await latest.waitForCount(1))
        let observedTimes = await latest.times
        #expect(observedTimes == [.zero])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func unexpectedIntervalClockFailureReportsFailureWithoutAnotherLoad() async {
        let clock = TimelineRefreshTestClock()
        let recorder = RefreshAttemptRecorder(failures: [nil])
        let timeline = UploadRefreshTimeline()
        let dependency = TimelineRefreshClock(
            now: { clock.now }, sleep: { _ in throw ExpectedRefreshClockFailure() },
            sleepUntil: { _ in throw ExpectedRefreshClockFailure() }
        )
        let coordinator = TimelineUploadRefreshCoordinator(clock: dependency)
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(.zero)
            return nil
        })
        let timeout = ContinuousClock.now + .seconds(5)
        while await coordinator.testingAutomaticState().workerActive, ContinuousClock.now < timeout {
            await Task.yield()
        }
        clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(
            refresh: { _ in
                await timeline.record(.seconds(6))
                return nil
            },
            observer: { await recorder.record($0) }
        )
        let failureTimeout = ContinuousClock.now + .seconds(5)
        while await recorder.decisions.isEmpty, ContinuousClock.now < failureTimeout { await Task.yield() }
        #expect(await recorder.decisions == [.failed])
        #expect(await timeline.times == [.zero])
        await coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitRequestBypassesAnAutomaticWaitWithoutConsumingItsPendingWork() async {
        let scenario = AutomaticUploadScenario()
        let manual = UploadRefreshTimeline()
        await scenario.startTwoSignals()
        await scenario.coordinator.request(refresh: { _ in
            await manual.record(scenario.clock.now - scenario.origin)
            return nil
        })
        #expect(await manual.waitForCount(1))
        let manualTimes = await manual.times
        let automaticBeforeDeadline = await scenario.timeline.times
        #expect(manualTimes == [.seconds(6)])
        #expect(automaticBeforeDeadline == [.zero])

        scenario.clock.advance(by: .seconds(54))
        #expect(await scenario.flush())
        let automaticTimes = await scenario.timeline.times
        print("Manual bypass: automaticTimes=\(automaticTimes), waits=\(scenario.clock.requestedSleeps)")
        #expect(automaticTimes == [.zero, .seconds(60)])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticEndFlushPublishesTheLatestPendingSignalWithoutAnotherGeneration() async {
        let scenario = AutomaticUploadScenario()
        await scenario.startTwoSignals()
        scenario.clock.advance(by: .seconds(6))
        let previousCount = await scenario.timeline.times.count
        await scenario.requestSignal(2)
        #expect(await scenario.timeline.waitForNewLoadOrSleep(after: previousCount, clock: scenario.clock))
        let beforeFlush = await scenario.timeline.times
        #expect(beforeFlush == [.zero])
        #expect(await scenario.flush())
        let flushedTimes = await scenario.timeline.times
        let flushedContents = await scenario.timeline.contents
        #expect(flushedTimes == [.zero, .seconds(12)])
        #expect(flushedContents == [0, 2])
        #expect(await scenario.flush())
        #expect(await scenario.timeline.times.count == flushedTimes.count)
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticEndAtTheIntervalBoundaryJoinsTheSameActiveGeneration() async {
        let scenario = AutomaticUploadScenario()
        let secondRelease = AsyncGate()
        await scenario.startTwoSignals(secondRelease: secondRelease)
        scenario.clock.advance(by: .seconds(54))
        #expect(await scenario.timeline.waitForCount(2))
        let completion = AutomaticFlushCompletion()
        let flush = Task {
            await scenario.coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        await secondRelease.open()
        #expect(await completion.waitUntilComplete())
        await scenario.coordinator.cancel()
        await flush.value
        let observedTimes = await scenario.timeline.times
        let observedContents = await scenario.timeline.contents
        #expect(observedTimes == [.zero, .seconds(60)])
        #expect(observedContents == [0, 1], "The boundary end must not manufacture a third refresh")
    }

    @Test(.timeLimit(.minutes(1)))
    func oneHundredAutomaticSignalsAndBoundaryEndUseAtMostElevenLoads() async {
        let scenario = AutomaticUploadScenario()
        for signal in 0..<100 {
            if signal > 0 { scenario.clock.advance(by: .seconds(6)) }
            let previousCount = await scenario.timeline.times.count
            await scenario.requestSignal(signal)
            #expect(await scenario.timeline.waitForNewLoadOrSleep(after: previousCount, clock: scenario.clock))
        }
        scenario.clock.advance(by: .seconds(6))
        #expect(await scenario.flush())
        let observedTimes = await scenario.timeline.times
        let observedContents = await scenario.timeline.contents
        print(
            "Automatic upload workload: loads=\(observedTimes.count), latest=\(observedContents.last ?? -1), times=\(observedTimes)"
        )
        #expect(observedTimes.count <= 11)
        #expect(observedContents.last == 99)
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationRetiresPendingAutomaticWorkAndResetsTheNextOwner() async {
        let scenario = AutomaticUploadScenario()
        await scenario.startTwoSignals()
        let beforeCancellation = await scenario.timeline.times
        #expect(beforeCancellation == [.zero])
        await scenario.coordinator.cancel()
        scenario.clock.advance(by: .seconds(60))
        #expect(await scenario.flush())
        #expect(await scenario.timeline.times.count == beforeCancellation.count)

        let replacement = UploadRefreshTimeline()
        await scenario.coordinator.requestAutomaticUpload(refresh: { _ in
            await replacement.record(scenario.clock.now - scenario.origin)
            return nil
        })
        #expect(await replacement.waitForCount(1))
        let replacementTimes = await replacement.times
        #expect(replacementTimes == [.seconds(66)], "A retired owner's interval cannot delay a new owner")
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticConvergenceKeepsImmediateDefaultVisibilityFeedback() async {
        let scenario = AutomaticUploadScenario()
        let recorder = RefreshAttemptRecorder(failures: [.pendingInventoryVisibility, .pendingInventoryVisibility, nil])
        await scenario.coordinator.requestAutomaticUpload(
            refresh: { attempt in
                await scenario.timeline.record(scenario.clock.now - scenario.origin)
                return await recorder.failure(at: attempt)
            },
            observer: { await recorder.record($0) }
        )
        #expect(await scenario.clock.waitForSleepCount(1))
        #expect(scenario.clock.requestedSleeps == [.milliseconds(350)])
        scenario.clock.advance(by: .milliseconds(350))
        #expect(await scenario.clock.waitForSleepCount(2))
        #expect(scenario.clock.requestedSleeps == [.milliseconds(350), .milliseconds(650)])
        scenario.clock.advance(by: .milliseconds(650))
        #expect(await scenario.timeline.waitForCount(3))
        #expect(await scenario.flush())
        let observedTimes = await scenario.timeline.times
        #expect(observedTimes == [.zero, .milliseconds(350), .seconds(1)])
        #expect(await recorder.attempts == [0, 1, 2])
        #expect(
            await recorder.decisions == [
                .retry(after: .milliseconds(350)), .retry(after: .milliseconds(650)), .succeeded,
            ])
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticSupersessionKeepsAdmittedObserverAndDefersTheNextCycle() async {
        let scenario = AutomaticUploadScenario()
        let firstRelease = AsyncGate()
        let recorder = CoordinatorRaceRecorder()
        await scenario.coordinator.requestAutomaticUpload(
            refresh: { _ in
                await scenario.timeline.record(scenario.clock.now - scenario.origin, content: 0)
                await firstRelease.wait()
                return .cancelled
            },
            observer: { _ in await recorder.recordOldObservation() }
        )
        #expect(await scenario.timeline.waitForCount(1))
        scenario.clock.advance(by: .seconds(6))
        await scenario.coordinator.requestAutomaticUpload(
            refresh: { _ in
                await scenario.timeline.record(scenario.clock.now - scenario.origin, content: 1)
                return nil
            },
            observer: { _ in await recorder.recordNewObservation() }
        )
        await firstRelease.open()
        #expect(await scenario.timeline.waitForNewLoadOrSleep(after: 1, clock: scenario.clock))
        let beforeDeadline = await scenario.timeline.times
        #expect(beforeDeadline == [.zero])
        scenario.clock.advance(by: .seconds(54))
        #expect(await scenario.timeline.waitForCount(2))
        #expect(await scenario.flush())
        let observedTimes = await scenario.timeline.times
        #expect(observedTimes == [.zero, .seconds(60)])
        #expect(await recorder.oldObservations == 1)
        #expect(await recorder.newObservations == 1)
        await scenario.coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticCancellationJoinsTheAdmittedLoadAndSuppressesItsObserver() async {
        let release = AsyncGate()
        let recorder = CoordinatorRaceRecorder()
        let completion = AutomaticFlushCompletion()
        let coordinator = TimelineUploadRefreshCoordinator()
        await coordinator.requestAutomaticUpload(
            refresh: { _ in
                await recorder.markFirstStarted()
                while !Task.isCancelled { await Task.yield() }
                await recorder.markFirstCancelled()
                await release.wait()
                return .cancelled
            },
            observer: { _ in await recorder.recordOldObservation() }
        )
        await recorder.waitForFirstStart()
        let cancellation = Task {
            await coordinator.cancel()
            await completion.markComplete()
        }
        await recorder.waitForFirstCancellation()
        #expect(await completion.isComplete == false)
        await coordinator.flushAutomaticUploads()
        await release.open()
        await cancellation.value
        #expect(await completion.isComplete)
        #expect(await recorder.oldObservations == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationKeepsCompletionAndFlushPendingUntilHeldRefreshReturns() async {
        let release = AsyncGate()
        let refreshAdmitted = AutomaticFlushCompletion()
        let refreshFinished = AutomaticFlushCompletion()
        let cancellationCompletion = AutomaticFlushCompletion()
        let flushCompletion = AutomaticFlushCompletion()
        let recorder = CoordinatorRaceRecorder()
        let coordinator = TimelineUploadRefreshCoordinator()
        let heldRefresh = Task<TimelineRefreshFailureReason?, Never> {
            await release.wait()
            return .cancelled
        }
        await coordinator.requestAutomaticUpload(
            refresh: { _ in
                await refreshAdmitted.markComplete()
                let result = await heldRefresh.value
                await refreshFinished.markComplete()
                return result
            },
            observer: { _ in await recorder.recordOldObservation() }
        )
        let refreshWasAdmitted = await refreshAdmitted.waitUntilComplete()
        #expect(refreshWasAdmitted)
        let flush = Task {
            await coordinator.flushAutomaticUploads()
            await flushCompletion.markComplete()
        }
        let flushWasRegistered = await waitForAutomaticCoordinatorState(
            coordinator, flushCount: 1, workerActive: true)
        #expect(flushWasRegistered)
        let cancellation = Task {
            await coordinator.cancel()
            await cancellationCompletion.markComplete()
        }
        let cancellationWasAdmitted = await waitForAutomaticCoordinatorState(
            coordinator, flushCount: 0, workerActive: false)
        #expect(cancellationWasAdmitted)

        // These bounded observations run while the held refresh's release stays closed.
        async let cancellationObservation = cancellationCompletion.waitUntilComplete()
        async let flushObservation = flushCompletion.waitUntilComplete()
        let (cancelReturnedWhileHeld, flushReturnedWhileHeld) = await (
            cancellationObservation, flushObservation
        )
        #expect(cancelReturnedWhileHeld == false)
        #expect(flushReturnedWhileHeld == false)

        // Expectations continue through cleanup, including when cancellation returns too early.
        await release.open()
        _ = await heldRefresh.value
        let refreshDidFinish = await refreshFinished.waitUntilComplete()
        await cancellation.value
        await flush.value
        #expect(refreshDidFinish)
        #expect(await cancellationCompletion.isComplete)
        #expect(await flushCompletion.isComplete)
        #expect(await recorder.oldObservations == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticSignalsDeferOnlyTheNewCycleToSixtySeconds() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let firstRelease = AsyncGate()
        let timeline = UploadRefreshTimeline()
        let coordinator = TimelineUploadRefreshCoordinator(clock: clock.dependency)
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin)
            await firstRelease.wait()
            return nil
        })
        #expect(await timeline.waitForCount(1))
        #expect(await timeline.times == [.zero])
        clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin)
            return nil
        })
        await firstRelease.open()
        #expect(await timeline.waitForNewLoadOrSleep(after: 1, clock: clock))
        let beforeDeadline = await timeline.times
        #expect(beforeDeadline == [.zero], "A second automatic signal stays pending inside sixty seconds")
        #expect(clock.requestedSleeps == [.seconds(54)])
        clock.advance(by: .seconds(54))
        #expect(await timeline.waitForCount(2))
        let observedTimes = await timeline.times
        #expect(observedTimes == [.zero, .seconds(60)])
        await coordinator.flushAutomaticUploads()
        #expect(await timeline.times.count == 2)
        await coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticFlushWithoutAutomaticWorkDoesNotJoinAHeldManualLoad() async {
        let release = AsyncGate()
        let timeline = UploadRefreshTimeline()
        let completion = AutomaticFlushCompletion()
        let coordinator = TimelineUploadRefreshCoordinator()
        await coordinator.request(refresh: { _ in
            await timeline.record(.zero)
            await release.wait()
            return nil
        })
        #expect(await timeline.waitForCount(1))
        let flush = Task {
            await coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        #expect(await completion.waitUntilComplete(), "An automatic-only flush must return while manual work is held")
        #expect(await coordinator.testingAutomaticState().flushCount == 0)
        #expect(await timeline.times.count == 1)
        await release.open()
        await coordinator.cancel()
        await flush.value
    }

    @Test(.timeLimit(.minutes(1)))
    func acceptedAutomaticFlushCompletesWithoutAddingARequest() async {
        let release = AsyncGate()
        let timeline = UploadRefreshTimeline()
        let completion = AutomaticFlushCompletion()
        let coordinator = TimelineUploadRefreshCoordinator()
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(.zero)
            await release.wait()
            return nil
        })
        #expect(await timeline.waitForCount(1))
        let flush = Task {
            await coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        await release.open()
        await flush.value
        #expect(await completion.isComplete)
        #expect(await timeline.times == [.zero])
        await coordinator.flushAutomaticUploads()
        #expect(await timeline.times == [.zero], "Repeated end calls must not manufacture another request")
        await coordinator.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitUploadRequestKeepsImmediateFollowUp() async {
        let clock = TimelineRefreshTestClock()
        let origin = clock.now
        let firstRelease = AsyncGate()
        let timeline = UploadRefreshTimeline()
        let coordinator = TimelineUploadRefreshCoordinator(clock: clock.dependency)
        await coordinator.request(refresh: { _ in
            await timeline.record(clock.now - origin)
            await firstRelease.wait()
            return nil
        })
        #expect(await timeline.waitForCount(1))
        #expect(await timeline.times == [.zero])

        clock.advance(by: .seconds(6))
        await coordinator.request(refresh: { _ in
            await timeline.record(clock.now - origin)
            return nil
        })
        await firstRelease.open()
        // Both versions reach a positive boundary: an actual second load or the controlled interval wait.
        let timeout = ContinuousClock.now + .seconds(5)
        while await timeline.times.count < 2, clock.pendingSleeps == 0, ContinuousClock.now < timeout {
            await Task.yield()
        }
        #expect(await timeline.waitForCount(2))
        #expect(await timeline.times == [.zero, .seconds(6)], "Explicit requests retain an immediate fresh follow-up")
        #expect(clock.requestedSleeps.isEmpty)
        await coordinator.cancel()
        #expect(clock.pendingSleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func controlledClockPreservesConvergenceDelaysAndCancellation() async {
        let clock = TimelineRefreshTestClock()
        let recorder = RefreshAttemptRecorder(failures: [.pendingInventoryVisibility, .pendingInventoryVisibility, nil])
        let coordinator = TimelineUploadRefreshCoordinator(
            policy: .init(schedule: .init(delays: [.zero, .seconds(5), .seconds(10)])),
            clock: clock.dependency
        )
        await coordinator.request(
            refresh: { attempt in await recorder.failure(at: attempt) },
            observer: { attempt in await recorder.record(attempt) }
        )
        #expect(await clock.waitForSleepCount(1))
        #expect(await recorder.attempts == [0])
        #expect(clock.requestedSleeps == [.seconds(5)])
        clock.advance(by: .seconds(5))
        #expect(await clock.waitForSleepCount(2))
        #expect(await recorder.attempts == [0, 1])
        #expect(clock.requestedSleeps == [.seconds(5), .seconds(10)])
        await coordinator.cancel()
        #expect(clock.pendingSleeps == 0)
        clock.advance(by: .seconds(10))
        #expect(await recorder.callCount == 2)
    }

    @Test func retriesOnlyPendingVisibilityWithSharedSchedule() async {
        let recorder = RefreshAttemptRecorder(failures: [.pendingInventoryVisibility, .pendingInventoryVisibility, nil])
        let coordinator = TimelineUploadRefreshCoordinator(
            policy: .init(schedule: .init(delays: [.zero, .zero, .zero])))
        await coordinator.request(
            refresh: { attempt in await recorder.failure(at: attempt) },
            observer: { attempt in await recorder.record(attempt) }
        )
        await recorder.waitForAttempts(3)
        #expect(await recorder.attempts == [0, 1, 2])
        #expect(await recorder.decisions == [.retry(after: .zero), .retry(after: .zero), .succeeded])
        await coordinator.cancel()
    }

    @Test func repeatedSignalsJoinOneDrainAndCauseOneFollowUp() async {
        let recorder = RefreshAttemptRecorder(failures: [nil, nil])
        let coordinator = TimelineUploadRefreshCoordinator(policy: .init(schedule: .init(delays: [.zero])))
        await coordinator.request(refresh: { attempt in
            let result = await recorder.failure(at: attempt)
            if await recorder.callCount == 1 {
                await coordinator.request(refresh: { next in await recorder.failure(at: next) })
            }
            return result
        })
        await recorder.waitForCalls(2)
        #expect(await recorder.callCount == 2)
        await coordinator.cancel()
    }

    @Test func supersededCancelledResultRunsLatestRequestAndSkipsStaleObserver() async {
        let firstRelease = AsyncGate()
        let recorder = CoordinatorRaceRecorder()
        let coordinator = TimelineUploadRefreshCoordinator(policy: .init(schedule: .init(delays: [.zero])))

        await coordinator.request(
            refresh: { _ in
                await recorder.markFirstStarted()
                await firstRelease.wait()
                return .cancelled
            },
            observer: { _ in await recorder.recordOldObservation() }
        )
        await recorder.waitForFirstStart()
        await coordinator.request(
            refresh: { _ in
                await recorder.markSecondStarted()
                return nil
            },
            observer: { _ in await recorder.recordNewObservation() }
        )
        await firstRelease.open()
        await recorder.waitForNewObservation()

        #expect(await recorder.secondStarts == 1)
        #expect(await recorder.oldObservations == 0)
        #expect(await recorder.newObservations == 1)
        await coordinator.cancel()
    }

    @Test func cancelledWorkerCannotClearReplacementWorker() async {
        let firstRelease = AsyncGate()
        let secondRelease = AsyncGate()
        let recorder = CoordinatorRaceRecorder()
        let coordinator = TimelineUploadRefreshCoordinator(policy: .init(schedule: .init(delays: [.zero])))

        await coordinator.request(refresh: { _ in
            await recorder.markFirstStarted()
            while !Task.isCancelled { await Task.yield() }
            await recorder.markFirstCancelled()
            await firstRelease.wait()
            return .cancelled
        })
        await recorder.waitForFirstStart()
        let cancellation = Task { await coordinator.cancel() }
        await recorder.waitForFirstCancellation()

        await coordinator.request(refresh: { _ in
            await recorder.markSecondStarted()
            await secondRelease.wait()
            return nil
        })
        await recorder.waitForSecondStart()
        await firstRelease.open()
        await cancellation.value

        await coordinator.request(refresh: { _ in
            await recorder.markThirdStarted()
            return nil
        })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.thirdStarts == 0)

        await secondRelease.open()
        await recorder.waitForThirdStart()
        #expect(await recorder.thirdStarts == 1)
        await coordinator.cancel()
    }
}

private actor RefreshAttemptRecorder {
    private let failures: [TimelineRefreshFailureReason?]
    private(set) var callCount = 0
    private(set) var attempts: [Int] = []
    private(set) var decisions: [TimelineRefreshConvergenceDecision] = []

    init(failures: [TimelineRefreshFailureReason?]) { self.failures = failures }

    func failure(at attempt: Int) -> TimelineRefreshFailureReason? {
        defer { callCount += 1 }
        return failures[min(callCount, failures.count - 1)]
    }

    func record(_ value: TimelineUploadRefreshAttempt) {
        attempts.append(value.attempt)
        decisions.append(value.decision)
    }

    func waitForCalls(_ count: Int) async {
        while callCount < count { await Task.yield() }
    }

    func waitForAttempts(_ count: Int) async {
        while attempts.count < count { await Task.yield() }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CoordinatorRaceRecorder {
    private(set) var firstStarts = 0
    private(set) var firstCancellations = 0
    private(set) var secondStarts = 0
    private(set) var thirdStarts = 0
    private(set) var oldObservations = 0
    private(set) var newObservations = 0

    func markFirstStarted() { firstStarts += 1 }
    func markFirstCancelled() { firstCancellations += 1 }
    func markSecondStarted() { secondStarts += 1 }
    func markThirdStarted() { thirdStarts += 1 }
    func recordOldObservation() { oldObservations += 1 }
    func recordNewObservation() { newObservations += 1 }

    func waitForFirstStart() async {
        while firstStarts == 0 { await Task.yield() }
    }

    func waitForFirstCancellation() async {
        while firstCancellations == 0 { await Task.yield() }
    }

    func waitForSecondStart() async {
        while secondStarts == 0 { await Task.yield() }
    }

    func waitForThirdStart() async {
        while thirdStarts == 0 { await Task.yield() }
    }

    func waitForNewObservation() async {
        while newObservations == 0 { await Task.yield() }
    }
}

private actor UploadRefreshTimeline {
    private(set) var times: [Duration] = []
    private(set) var contents: [Int] = []

    func record(_ time: Duration, content: Int? = nil) {
        times.append(time)
        if let content { contents.append(content) }
    }

    func waitForNewLoadOrSleep(after count: Int, clock: TimelineRefreshTestClock) async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while times.count <= count, clock.pendingSleeps == 0, ContinuousClock.now < timeout { await Task.yield() }
        return times.count > count || clock.pendingSleeps > 0
    }

    func waitForCount(_ count: Int) async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while times.count < count, ContinuousClock.now < timeout { await Task.yield() }
        return times.count >= count
    }
}

private actor AutomaticFlushCompletion {
    private(set) var isComplete = false

    func markComplete() { isComplete = true }

    func waitUntilComplete() async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while !isComplete, ContinuousClock.now < timeout { await Task.yield() }
        return isComplete
    }
}

private func waitForAutomaticCoordinatorState(
    _ coordinator: TimelineUploadRefreshCoordinator,
    flushCount: Int,
    workerActive: Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    repeat {
        let state = await coordinator.testingAutomaticState()
        if state.flushCount == flushCount, state.workerActive == workerActive { return true }
        await Task.yield()
    } while ContinuousClock.now < deadline
    return false
}

private struct AutomaticUploadScenario: Sendable {
    let clock: TimelineRefreshTestClock
    let origin: ContinuousClock.Instant
    let timeline = UploadRefreshTimeline()
    let coordinator: TimelineUploadRefreshCoordinator

    init() {
        let clock = TimelineRefreshTestClock()
        self.clock = clock
        origin = clock.now
        coordinator = TimelineUploadRefreshCoordinator(clock: clock.dependency)
    }

    func startTwoSignals(secondRelease: AsyncGate? = nil) async {
        let firstRelease = AsyncGate()
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin, content: 0)
            await firstRelease.wait()
            return nil
        })
        #expect(await timeline.waitForCount(1))
        clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin, content: 1)
            await secondRelease?.wait()
            return nil
        })
        await firstRelease.open()
        #expect(await timeline.waitForNewLoadOrSleep(after: 1, clock: clock))
    }

    func waitForFlushRegistration(_ count: Int = 1) async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while await coordinator.testingAutomaticState().flushCount < count, ContinuousClock.now < timeout {
            await Task.yield()
        }
        return await coordinator.testingAutomaticState().flushCount >= count
    }

    func waitForWorkerRetirement() async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while await coordinator.testingAutomaticState().workerActive, ContinuousClock.now < timeout {
            await Task.yield()
        }
        return await coordinator.testingAutomaticState().workerActive == false
    }

    func requestSignal(_ content: Int) async {
        await coordinator.requestAutomaticUpload(refresh: { _ in
            await timeline.record(clock.now - origin, content: content)
            return nil
        })
    }

    func flush() async -> Bool {
        let completion = AutomaticFlushCompletion()
        let task = Task {
            await coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        let completed = await completion.waitUntilComplete()
        if !completed { await coordinator.cancel() }
        await task.value
        return completed
    }
}

private struct ExpectedRefreshClockFailure: Error {}

private actor ClockWaitSequence {
    private var isFirst = true

    func takeFirst() -> Bool {
        defer { isFirst = false }
        return isFirst
    }
}

extension TimelineUploadRefreshCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func f1ExplicitStartsAfterHeldAutomaticRefreshBeforeRetryDelay() async {
        let h = F1F2Harness()
        let coordinator = TimelineUploadRefreshCoordinator(clock: h.dependency)
        let release = AsyncGate()
        let held = Task { await release.wait() }
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt)
                if attempt == 0 { await held.value }
                h.end()
                return attempt == 0 ? .pendingInventoryVisibility : nil
            },
            observer: { value in h.observe("auto.observe", value: value) }
        )
        #expect(await h.log.waitFor("auto.enter"), "SETUP: automatic refresh entered")
        h.clock.advance(by: .seconds(6))
        await coordinator.request(refresh: { attempt in
            h.begin("manual.enter", attempt: attempt)
            h.end()
            return nil
        })
        let boundary = h.log.count
        await release.open()
        let action = await h.log.waitForScheduling(after: boundary)
        #expect(action != nil, "SETUP: an actual scheduling event followed refresh completion")
        #expect(action?.name == "manual.enter", "F1A: explicit entry precedes automatic retry registration")
        if action?.name == "manual.enter" {
            #expect(action?.time == Duration.seconds(6))
            #expect(await h.log.waitFor("auto.observe"), "SETUP: suspended actual result resumes")
            #expect(await h.clock.waitForSleepCount(1), "SETUP: original retry delay registers")
            #expect(h.clock.requestedSleeps == [.milliseconds(350)])
        }
        await release.open()
        await held.value
        await coordinator.cancel()
        #expect(h.log.maximumActiveLoads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func f1ExplicitWakesRegisteredAutomaticRetryAndJoinsItsWait() async {
        let h = F1F2Harness()
        let releaseWaitReturn = AsyncGate()
        let heldWaitReturn = Task { await releaseWaitReturn.wait() }
        let dependency = TimelineRefreshClock(
            now: { h.clock.now },
            sleep: { duration in
                do { try await h.dependency.sleep(duration) } catch {
                    h.log.record("cancelled.wait.held", time: h.time)
                    await heldWaitReturn.value
                    throw error
                }
            },
            sleepUntil: { deadline in
                do { try await h.dependency.sleepUntil(deadline) } catch {
                    h.log.record("cancelled.wait.held", time: h.time)
                    await heldWaitReturn.value
                    throw error
                }
            }
        )
        let coordinator = TimelineUploadRefreshCoordinator(clock: dependency)
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt)
                h.end()
                return attempt == 0 ? .pendingInventoryVisibility : nil
            },
            observer: { value in h.observe("auto.observe", value: value) }
        )
        #expect(await h.clock.waitForSleepCount(1), "SETUP: automatic retry is registered")
        #expect(h.clock.requestedSleeps == [.milliseconds(350)])
        h.clock.advance(by: .milliseconds(100))
        await coordinator.request(refresh: { attempt in
            h.begin("manual.enter", attempt: attempt)
            h.end()
            return nil
        })
        // The cancelled wait itself stays noncooperatively held. No manual load may overlap it.
        let explicitEnteredWhileWaitWasHeld = await h.log.waitFor("manual.enter")
        #expect(explicitEnteredWhileWaitWasHeld == false)
        await releaseWaitReturn.open()
        // Virtual time still stays below350ms. This finite entry observation is the F1 behavior.
        let explicitEnteredAfterWaitRelease = await h.log.waitFor("manual.enter")
        #expect(explicitEnteredAfterWaitRelease == true, "F1B: explicit work wakes and joins the owned retry wait")
        if explicitEnteredAfterWaitRelease {
            #expect(h.log.events.filter { $0.name == "cancelled.wait.held" }.count == 1)
            let events = h.log.events
            let manual = events.firstIndex { $0.name == "manual.enter" }
            let waitExit = events.firstIndex { $0.name == "wait.exit" }
            #expect(waitExit != nil && manual != nil && waitExit! < manual!)
            #expect(events.first { $0.name == "manual.enter" }?.time == Duration.milliseconds(100))
            #expect(await h.clock.waitForSleepCount(2), "SETUP: suspended original deadline is registered again")
            h.clock.advance(by: .milliseconds(250))
            #expect(await h.log.waitFor("auto.enter", count: 2), "SETUP: same admitted cycle resumed")
            #expect(h.log.events.filter { $0.name == "auto.enter" }.map(\.time) == [.zero, .milliseconds(350)])
            #expect(h.log.events.filter { $0.name == "auto.enter" }.map(\.attempt) == [0, 1])
        }
        await releaseWaitReturn.open()
        await heldWaitReturn.value
        await coordinator.cancel()
        #expect(h.log.maximumActiveLoads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func f2AdmittedFeedbackKeepsItsPairAndLatestPairRunsNextRetry() async {
        let h = F1F2Harness()
        let coordinator = TimelineUploadRefreshCoordinator(clock: h.dependency)
        let release = AsyncGate()
        let held = Task { await release.wait() }
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt, content: 0)
                if attempt == 0 { await held.value }
                h.end()
                return attempt == 0 ? .pendingInventoryVisibility : nil
            },
            observer: { value in h.observe("a.observe", value: value, content: 0) }
        )
        #expect(await h.log.waitFor("auto.enter"), "SETUP: A entered")
        h.clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt, content: 1)
                h.end()
                return nil
            },
            observer: { value in h.observe("b.observe", value: value, content: 1) }
        )
        let boundary = h.log.count
        await release.open()
        let action = await h.log.waitForScheduling(after: boundary)
        #expect(action != nil, "SETUP: actual retry or interval registration")
        let admittedFeedbackCount = h.log.events.filter { $0.name == "a.observe" }.count
        #expect(admittedFeedbackCount == 1, "F2A: admitted A reports its own actual result")
        #expect(
            action?.delay == Duration.milliseconds(350),
            "F2A: latest pair continues admitted cycle, not a new 60-second cycle")
        if action?.delay == Duration.milliseconds(350) {
            #expect(await h.clock.waitForSleepCount(1), "SETUP: retry registered before advance")
            h.clock.advance(by: .milliseconds(350))
            #expect(await h.log.waitFor("b.observe"), "SETUP: actual B attempt completed")
            let loads = h.log.events.filter { $0.name == "auto.enter" }
            #expect(loads.map(\.content) == [0, 1])
            #expect(loads.map(\.attempt) == [0, 1])
            #expect(loads.map(\.time) == [.zero, .seconds(6) + .milliseconds(350)])
            #expect(
                h.log.events.filter { $0.name == "a.observe" }.map(\.decision) == [.retry(after: .milliseconds(350))])
            #expect(h.log.events.filter { $0.name == "b.observe" }.map(\.decision) == [.succeeded])
        }
        await release.open()
        await held.value
        await coordinator.cancel()
        #expect(h.log.maximumActiveLoads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func f2ContinuingSupersessionKeepsFeedbackAndTheOriginalAttemptBudget() async {
        let h = F1F2Harness()
        let coordinator = TimelineUploadRefreshCoordinator(clock: h.dependency)
        let gates = (0..<8).map { _ in AsyncGate() }
        let held = gates.map { gate in Task { await gate.wait() } }
        let delays = TimelineRefreshRetrySchedule.uploadDefault.delays
        func submit(_ content: Int) async {
            await coordinator.requestAutomaticUpload(
                refresh: { attempt in
                    h.begin("auto.enter", attempt: attempt, content: content)
                    if content < 8, held.indices.contains(attempt) { await held[attempt].value }
                    h.end()
                    return content < 8 ? .pendingInventoryVisibility : nil
                },
                observer: { value in h.observe("auto.observe", value: value, content: content) }
            )
        }
        await submit(0)
        #expect(await h.log.waitFor("auto.enter"), "SETUP: first admitted load entered")
        for attempt in 0..<8 {
            await submit(attempt + 1)
            let boundary = h.log.count
            await gates[attempt].open()
            if attempt < 7 {
                let action = await h.log.waitForScheduling(after: boundary)
                #expect(action != nil, "SETUP: actual automatic wait registration")
                let pairedFeedbackCount = h.log.events.filter {
                    $0.name == "auto.observe" && $0.attempt == attempt && $0.content == attempt
                }.count
                #expect(pairedFeedbackCount == 1, "F2B: continuing signals do not suppress admitted feedback")
                #expect(
                    action?.delay == delays[attempt + 1], "F2B: signals cannot reset convergence into a new admission")
                if action?.delay != delays[attempt + 1] {
                    for gate in gates { await gate.open() }
                    for task in held { await task.value }
                    await coordinator.cancel()
                    #expect(h.log.maximumActiveLoads == 1)
                    return
                }
                #expect(await h.clock.waitForSleepCount(attempt + 1), "SETUP: controlled retry registered")
                h.clock.advance(by: delays[attempt + 1])
                #expect(await h.log.waitFor("auto.enter", count: attempt + 2), "SETUP: next attempt entered")
            }
        }
        #expect(await h.log.waitFor("auto.observe", count: 8), "SETUP: terminal feedback completed")
        let loads = h.log.events.filter { $0.name == "auto.enter" }
        #expect(loads.map(\.attempt) == Array(0..<8))
        #expect(loads.map(\.content) == Array(0..<8))
        #expect(
            loads.map(\.time) == [
                .zero, .milliseconds(350), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
                .seconds(30),
            ])
        #expect(h.log.events.filter { $0.name == "auto.observe" }.last?.decision == .notYetVisible)
        #expect(
            await h.clock.waitForSleepCount(8), "SETUP: unattempted latest generation waits for the original boundary")
        #expect(h.clock.requestedSleeps.last == Duration.seconds(30))
        let completion = AutomaticFlushCompletion()
        let flush = Task {
            await coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        let flushed = await completion.waitUntilComplete()
        #expect(flushed, "SETUP: forced latest actual generation completed")
        for gate in gates { await gate.open() }
        for task in held { await task.value }
        await coordinator.cancel()
        await flush.value
        let finalLoads = h.log.events.filter { $0.name == "auto.enter" }
        #expect(finalLoads.count == 9)
        #expect(finalLoads.last?.content == 8)
        #expect(finalLoads.last?.attempt == 0)
        #expect(finalLoads.last?.time == Duration.seconds(30))
        #expect(h.log.maximumActiveLoads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func f2OlderSuccessDoesNotAcknowledgeTheNewerFlushTarget() async {
        let h = F1F2Harness()
        let coordinator = TimelineUploadRefreshCoordinator(clock: h.dependency)
        let releaseA = AsyncGate()
        let releaseB = AsyncGate()
        let heldA = Task { await releaseA.wait() }
        let heldB = Task { await releaseB.wait() }
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt, content: 0)
                await heldA.value
                h.end()
                return nil
            },
            observer: { value in h.observe("a.observe", value: value, content: 0) }
        )
        #expect(await h.log.waitFor("auto.enter"), "SETUP: A entered")
        h.clock.advance(by: .seconds(6))
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt, content: 1)
                await heldB.value
                h.end()
                return nil
            },
            observer: { value in h.observe("b.observe", value: value, content: 1) }
        )
        let boundary = h.log.count
        await releaseA.open()
        let action = await h.log.waitForScheduling(after: boundary)
        #expect(action != nil, "SETUP: pending B reaches the interval boundary")
        #expect(
            h.log.events.filter { $0.name == "a.observe" }.count == 1,
            "F2C: A reports its actual success without serving B")
        #expect(action?.delay == Duration.seconds(54))
        #expect(await h.clock.waitForSleepCount(1), "SETUP: pending B interval registered")
        let completion = AutomaticFlushCompletion()
        let flush = Task {
            await coordinator.flushAutomaticUploads()
            await completion.markComplete()
        }
        #expect(await h.log.waitFor("auto.enter", count: 2), "SETUP: forced B entered")
        #expect(
            await waitForAutomaticCoordinatorState(coordinator, flushCount: 1, workerActive: true),
            "SETUP: target B waiter registered")
        // The held B load cannot be acknowledged by A's completed success.
        let flushReturnedWhileBWasHeld = await completion.waitUntilComplete()
        #expect(flushReturnedWhileBWasHeld == false)
        await releaseB.open()
        #expect(await completion.waitUntilComplete(), "SETUP: B completion released its own waiter")
        await releaseA.open()
        await heldA.value
        await heldB.value
        await coordinator.cancel()
        await flush.value
        #expect(h.log.events.filter { $0.name == "auto.enter" }.map(\.content) == [0, 1])
        #expect(h.log.events.filter { $0.name == "b.observe" }.map(\.decision) == [.succeeded])
        #expect(h.log.maximumActiveLoads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func f1AlreadyAdmittedAutomaticObserverJoinsBeforeExplicitLoad() async {
        let h = F1F2Harness()
        let coordinator = TimelineUploadRefreshCoordinator(clock: h.dependency)
        let release = AsyncGate()
        let heldObserver = Task { await release.wait() }
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt)
                h.end()
                return nil
            },
            observer: { value in
                h.observe("auto.observe", value: value)
                await heldObserver.value
            }
        )
        #expect(await h.log.waitFor("auto.observe"), "SETUP: observer was admitted before explicit work")
        h.clock.advance(by: .seconds(6))
        await coordinator.request(refresh: { attempt in
            h.begin("manual.enter", attempt: attempt)
            h.end()
            return nil
        })
        let explicitEnteredWhileObserverHeld = await h.log.waitFor("manual.enter")
        #expect(explicitEnteredWhileObserverHeld == false)
        await release.open()
        #expect(await h.log.waitFor("manual.enter"), "SETUP: joined observer permits manual work")
        await heldObserver.value
        await coordinator.cancel()
        #expect(h.log.events.filter { $0.name == "manual.enter" }.map(\.time) == [.seconds(6)])
        #expect(h.log.maximumActiveLoads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func f1ObserverReentrySelectsExplicitBeforeAutomaticRetry() async {
        let h = F1F2Harness()
        let coordinator = TimelineUploadRefreshCoordinator(clock: h.dependency)
        await coordinator.requestAutomaticUpload(
            refresh: { attempt in
                h.begin("auto.enter", attempt: attempt)
                h.end()
                return attempt == 0 ? .pendingInventoryVisibility : nil
            },
            observer: { value in
                h.observe("auto.observe", value: value)
                if value.attempt == 0 {
                    await coordinator.request(refresh: { attempt in
                        h.begin("manual.enter", attempt: attempt)
                        h.end()
                        return nil
                    })
                }
            }
        )
        let action = await h.log.waitForScheduling(after: 0)
        #expect(action != nil, "SETUP: observer reentry yields an actual scheduling event")
        #expect(action?.name == "manual.enter", "F1_REENTRY: manual entry wins after its requesting observer returns")
        await coordinator.cancel()
        #expect(h.log.maximumActiveLoads == 1)
    }
}

private struct F1F2Event: Sendable, Equatable {
    let name: String
    let time: Duration
    let attempt: Int
    let content: Int
    let delay: Duration
    let decision: TimelineRefreshConvergenceDecision?
}

private final class F1F2Log: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [F1F2Event] = []
    private var activeLoads = 0
    private var maximumLoads = 0

    var events: [F1F2Event] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }
    var maximumActiveLoads: Int { lock.withLock { maximumLoads } }

    func record(
        _ name: String, time: Duration, attempt: Int = -1, content: Int = -1,
        delay: Duration = .zero, decision: TimelineRefreshConvergenceDecision? = nil
    ) {
        lock.withLock {
            if name.hasSuffix(".enter") && name != "wait.enter" {
                activeLoads += 1
                maximumLoads = max(maximumLoads, activeLoads)
            }
            if name == "load.exit" { activeLoads -= 1 }
            storage.append(
                .init(name: name, time: time, attempt: attempt, content: content, delay: delay, decision: decision))
        }
    }

    func waitFor(_ name: String, count: Int = 1) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while events.filter({ $0.name == name }).count < count, ContinuousClock.now < deadline { await Task.yield() }
        return events.filter { $0.name == name }.count >= count
    }

    func waitForScheduling(after boundary: Int) async -> F1F2Event? {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if let action = events.dropFirst(boundary).first(where: {
                $0.name == "manual.enter" || $0.name == "wait.enter"
            }) {
                return action
            }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return nil
    }
}

private struct F1F2Harness: Sendable {
    let clock: TimelineRefreshTestClock
    let log = F1F2Log()
    private let origin: ContinuousClock.Instant

    init() {
        let clock = TimelineRefreshTestClock()
        self.clock = clock
        origin = clock.now
    }
    var time: Duration { clock.now - origin }

    var dependency: TimelineRefreshClock {
        .init(
            now: { clock.now },
            sleep: { duration in
                log.record("wait.enter", time: time, delay: duration)
                do {
                    try await clock.dependency.sleep(duration)
                    log.record("wait.exit", time: time)
                } catch {
                    log.record("wait.exit", time: time)
                    throw error
                }
            },
            sleepUntil: { deadline in
                log.record("wait.enter", time: time, delay: max(.zero, deadline - clock.now))
                do {
                    try await clock.dependency.sleepUntil(deadline)
                    log.record("wait.exit", time: time)
                } catch {
                    log.record("wait.exit", time: time)
                    throw error
                }
            }
        )
    }

    func begin(_ name: String, attempt: Int, content: Int = -1) {
        log.record(name, time: time, attempt: attempt, content: content)
    }
    func end() { log.record("load.exit", time: time) }
    func observe(_ name: String, value: TimelineUploadRefreshAttempt, content: Int = -1) {
        log.record(name, time: time, attempt: value.attempt, content: content, decision: value.decision)
    }
}
