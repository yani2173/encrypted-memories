import Foundation
import XCTest

@testable import PhotosCore

private struct SubmissionRefused: Error, Equatable {}

/// Whether `signal` fires within the event limit of the background-window tests.
private func happened(_ signal: AsyncTestSignal) async -> Bool {
    await signal.wait(limit: XCTestCase.backgroundWindowEventLimit)
}

/// The request route of the OS background tasks: the old call at once, the iOS 27 call off the main thread, in order.
@MainActor
final class BackgroundTaskRequestSubmitterTests: XCTestCase {
    private var cancels = 0
    /// Each report of a submission: nil for success, else the error.
    private var reports: [SubmissionRefused?] = []
    /// Each error of a request that a cancel overtook.
    private var errorsAfterCancel: [SubmissionRefused?] = []
    /// The order of the events of the end-of-window tests.
    private var log: [String] = []
    /// What `pendingSubmissionsEnded` returned.
    private var ended: Bool?
    private let diagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: false)

    private func makeSubmitter(
        predecessorDeadline: @escaping @Sendable () async -> Void = BackgroundTaskRequestSubmitter.defaultDeadline
    ) -> BackgroundTaskRequestSubmitter {
        BackgroundTaskRequestSubmitter(
            cancelRequest: { [weak self] in self?.cancels += 1 },
            onErrorAfterCancel: { [weak self] in self?.errorsAfterCancel.append($0 as? SubmissionRefused) },
            predecessorDeadline: predecessorDeadline,
            diagnostics: diagnostics)
    }

    private nonisolated static func runsOnTheMainThread() -> Bool { Thread.isMainThread }

    func testWithoutTheNewCallTheRequestIsSubmittedAtOnce() {
        let submitter = makeSubmitter()
        var submitted = 0

        submitter.submit(
            blocking: { submitted += 1 }, offMainThread: nil,
            completion: { [weak self] in self?.reports.append($0 as? SubmissionRefused) })

        XCTAssertEqual(submitted, 1)
        XCTAssertEqual(reports, [nil], "the old call reports before submit returns")
    }

    func testTheOldCallReportsItsError() {
        let submitter = makeSubmitter()

        submitter.submit(
            blocking: { throw SubmissionRefused() }, offMainThread: nil,
            completion: { [weak self] in self?.reports.append($0 as? SubmissionRefused) })

        XCTAssertEqual(reports, [SubmissionRefused()])
    }

    func testTheNewCallRunsOffTheMainThreadAndReportsItsError() async {
        let submitter = makeSubmitter()
        let onMainThread = LockedValue<Bool>()
        var blockingCalls = 0
        let reported = AsyncTestSignal()

        submitter.submit(
            blocking: { blockingCalls += 1 },
            offMainThread: {
                onMainThread.set(Self.runsOnTheMainThread())
                throw SubmissionRefused()
            },
            completion: { [weak self] in
                self?.reports.append($0 as? SubmissionRefused)
                reported.fire()
            })

        let reportedHappened = await happened(reported)
        XCTAssertTrue(reportedHappened, "the report of the new call did not happen")
        XCTAssertEqual(onMainThread.value, false, "the header forbids this call on the main thread")
        XCTAssertEqual(reports, [SubmissionRefused()])
        XCTAssertEqual(blockingCalls, 0)
    }

    func testTheNewCallReportsSuccess() async {
        let submitter = makeSubmitter()
        let reported = AsyncTestSignal()

        submitter.submit(
            blocking: {}, offMainThread: {},
            completion: { [weak self] in
                self?.reports.append($0 as? SubmissionRefused)
                reported.fire()
            })

        let reportedHappened = await happened(reported)
        XCTAssertTrue(reportedHappened, "the report of the new call did not happen")
        XCTAssertEqual(reports, [nil])
    }

    func testRequestsReachTheSchedulerInTheOrderOfSubmission() async {
        let submitter = makeSubmitter()
        let firstEntered = AsyncTestSignal()
        let releaseFirst = AsyncTestSignal()
        let secondEntered = AsyncTestSignal()
        let order = LockedValue<[Int]>()
        order.set([])
        let bothReported = AsyncTestSignal()

        submitter.submit(
            blocking: {},
            offMainThread: {
                firstEntered.fire()
                await releaseFirst.wait()
                order.set((order.value ?? []) + [1])
            },
            completion: { [weak self] in
                self?.reports.append($0 as? SubmissionRefused)
                if self?.reports.count == 2 { bothReported.fire() }
            })
        submitter.submit(
            blocking: {},
            offMainThread: {
                secondEntered.fire()
                order.set((order.value ?? []) + [2])
            },
            completion: { [weak self] in
                self?.reports.append($0 as? SubmissionRefused)
                if self?.reports.count == 2 { bothReported.fire() }
            })
        let firstEnteredHappened = await happened(firstEntered)
        XCTAssertTrue(firstEnteredHappened, "the first request did not happen")
        // The second request has no gate of its own: when it may run, it runs well within this time.
        let secondRanEarly = await secondEntered.wait(limit: .milliseconds(500))
        XCTAssertFalse(secondRanEarly, "the second request waits for the first")
        XCTAssertEqual(order.value, [])
        releaseFirst.fire()

        let bothReportedHappened = await happened(bothReported)
        XCTAssertTrue(bothReportedHappened, "both reports did not happen")
        XCTAssertEqual(order.value, [1, 2], "an older request never replaces a newer one")
    }

    #if DEBUG
        func testACancelWhileARequestIsOnItsWayCancelsItAgainWhenItLands() async {
            let submitter = makeSubmitter()
            let entered = AsyncTestSignal()
            let release = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    entered.fire()
                    await release.wait()
                },
                completion: { [weak self] in self?.reports.append($0 as? SubmissionRefused) })
            let enteredHappened = await happened(entered)
            XCTAssertTrue(enteredHappened, "the request did not happen")
            submitter.cancel()
            XCTAssertEqual(cancels, 1)
            release.fire()
            await submitter.lastSubmissionForTesting?.value

            XCTAssertEqual(cancels, 2, "a request that lands after the cancel must not stay scheduled")
            XCTAssertEqual(reports, [], "a cancelled request reports nothing")
            XCTAssertEqual(errorsAfterCancel, [])
        }
    #endif

    #if DEBUG
        func testTheErrorOfARequestThatACancelOvertookIsPassedOn() async {
            let submitter = makeSubmitter()
            let entered = AsyncTestSignal()
            let release = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    entered.fire()
                    await release.wait()
                    throw SubmissionRefused()
                },
                completion: { [weak self] in self?.reports.append($0 as? SubmissionRefused) })
            let enteredHappened = await happened(entered)
            XCTAssertTrue(enteredHappened, "the request did not happen")
            submitter.cancel()
            release.fire()
            await submitter.lastSubmissionForTesting?.value

            XCTAssertEqual(errorsAfterCancel, [SubmissionRefused()], "the error is not dropped")
            XCTAssertEqual(reports, [])
            XCTAssertEqual(cancels, 2)
        }
    #endif

    #if DEBUG
        func testARequestThatWaitsBehindACancelledOneIsNeverSent() async {
            let submitter = makeSubmitter()
            let entered = AsyncTestSignal()
            let release = AsyncTestSignal()
            let secondSent = LockedValue<Bool>()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    entered.fire()
                    await release.wait()
                },
                completion: { [weak self] in self?.reports.append($0 as? SubmissionRefused) })
            submitter.submit(
                blocking: {}, offMainThread: { secondSent.set(true) },
                completion: { [weak self] in self?.reports.append($0 as? SubmissionRefused) })
            let enteredHappened = await happened(entered)
            XCTAssertTrue(enteredHappened, "the first request did not happen")
            submitter.cancel()
            release.fire()
            await submitter.lastSubmissionForTesting?.value

            XCTAssertNil(secondSent.value, "the waiting request must not reach the scheduler after the cancel")
            XCTAssertEqual(reports, [])
            XCTAssertEqual(cancels, 2, "the cancel, and the first request again when it landed")
        }
    #endif

    func testTheEndOfAWindowWaitsUntilALateRequestReturned() async {
        let submitter = makeSubmitter()
        let entered = AsyncTestSignal()
        let release = AsyncTestSignal()

        submitter.submit(
            blocking: {},
            offMainThread: {
                entered.fire()
                await release.wait()
            },
            completion: { [weak self] _ in self?.log.append("submitted") })
        let waiter = Task {
            self.ended = await submitter.pendingSubmissionsEnded(deadline: { await AsyncTestSignal().wait() })
            self.log.append("returned")
        }
        let enteredHappened = await happened(entered)
        XCTAssertTrue(enteredHappened, "the request did not happen")
        release.fire()
        await waiter.value

        XCTAssertEqual(log, ["submitted", "returned"], "the wait ends only after the request returned")
        XCTAssertEqual(ended, true)
    }

    #if DEBUG
        func testTheEndOfAWindowStopsWaitingAtTheDeadline() async {
            let submitter = makeSubmitter()
            let entered = AsyncTestSignal()
            let release = AsyncTestSignal()
            let deadline = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    entered.fire()
                    await release.wait()
                },
                completion: { [weak self] _ in self?.log.append("submitted") })
            let enteredHappened = await happened(entered)
            XCTAssertTrue(enteredHappened, "the request did not happen")
            let waiting = AsyncTestSignal()
            let waiter = Task { () -> Bool in
                await submitter.pendingSubmissionsEnded(deadline: {
                    waiting.fire()
                    await deadline.wait()
                })
            }
            let waitingHappened = await happened(waiting)
            XCTAssertTrue(waitingHappened, "the wait did not start")
            deadline.fire()
            // The wait must end at the deadline while the request is still held; the bound only stops a hang.
            let ended = await boundedValue(of: waiter)
            release.fire()
            await submitter.lastSubmissionForTesting?.value

            XCTAssertEqual(ended, false, "the deadline, not the late request, ended the wait")
            XCTAssertEqual(log, ["submitted"])
            XCTAssertEqual(
                diagnostics.supportSnapshot().counters["backgroundWindows.endWaitTimedOut"], 1,
                "the support report counts the wait that ran into the limit")
        }
    #endif

    func testTheEndOfAWindowAlsoWaitsForARequestSubmittedDuringTheWait() async {
        let submitter = makeSubmitter()
        let firstEntered = AsyncTestSignal()
        let releaseFirst = AsyncTestSignal()
        let secondEntered = AsyncTestSignal()
        let releaseSecond = AsyncTestSignal()

        submitter.submit(
            blocking: {},
            offMainThread: {
                firstEntered.fire()
                await releaseFirst.wait()
            },
            completion: { [weak self] _ in self?.log.append("first") })
        let firstHappened = await happened(firstEntered)
        XCTAssertTrue(firstHappened, "the first request did not happen")
        let waiting = AsyncTestSignal()
        let waiter = Task {
            self.ended = await submitter.pendingSubmissionsEnded(deadline: {
                waiting.fire()
                await AsyncTestSignal().wait()
            })
            self.log.append("returned")
        }
        let waitingHappened = await happened(waiting)
        XCTAssertTrue(waitingHappened, "the wait did not start")
        // The expiry of a window, for example, reschedules while the end waits.
        submitter.submit(
            blocking: {},
            offMainThread: {
                secondEntered.fire()
                await releaseSecond.wait()
            },
            completion: { [weak self] _ in self?.log.append("second") })
        releaseFirst.fire()
        let secondHappened = await happened(secondEntered)
        XCTAssertTrue(secondHappened, "the second request did not happen")
        releaseSecond.fire()
        await waiter.value

        XCTAssertEqual(log, ["first", "second", "returned"], "the wait covers the request that came during it")
        XCTAssertEqual(ended, true)
    }

    #if DEBUG
        func testALateRequestOfAStoppedTaskDoesNotRemoveTheRequestOfTheRestart() async {
            let limit = AsyncTestSignal()
            let submitter = makeSubmitter(predecessorDeadline: { await limit.wait() })
            let firstEntered = AsyncTestSignal()
            let releaseFirst = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    firstEntered.fire()
                    await releaseFirst.wait()
                },
                completion: { [weak self] _ in self?.log.append("first") })
            let first = submitter.lastSubmissionForTesting
            let firstHappened = await happened(firstEntered)
            XCTAssertTrue(firstHappened, "the first request did not happen")
            submitter.cancel()  // the task stops
            submitter.submit(  // and starts again
                blocking: {}, offMainThread: {},
                completion: { [weak self] _ in self?.log.append("second") })
            limit.fire()
            await submitter.lastSubmissionForTesting?.value
            XCTAssertEqual(log, ["second"], "the request of the restart reached the scheduler")
            releaseFirst.fire()
            await first?.value

            XCTAssertEqual(cancels, 1, "the late request of the stopped task must not remove the newer request")
            XCTAssertEqual(log, ["second"])
        }
    #endif

    #if DEBUG
        func testALateRequestIsRemovedWhenTheTaskStoppedAgainAfterItsRestart() async {
            let limit = AsyncTestSignal()
            let submitter = makeSubmitter(predecessorDeadline: { await limit.wait() })
            let firstEntered = AsyncTestSignal()
            let releaseFirst = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    firstEntered.fire()
                    await releaseFirst.wait()
                },
                completion: { [weak self] _ in self?.log.append("first") })
            let first = submitter.lastSubmissionForTesting
            let firstHappened = await happened(firstEntered)
            XCTAssertTrue(firstHappened, "the first request did not happen")
            submitter.cancel()  // the task stops
            submitter.submit(  // starts again
                blocking: {}, offMainThread: {},
                completion: { [weak self] _ in self?.log.append("second") })
            limit.fire()
            await submitter.lastSubmissionForTesting?.value
            submitter.cancel()  // and stops again
            XCTAssertEqual(cancels, 2)
            releaseFirst.fire()
            await first?.value

            XCTAssertEqual(cancels, 3, "the task is stopped, so the late request must not stay pending")
            XCTAssertEqual(log, ["second"])
        }
    #endif

    #if DEBUG
        func testALateRequestIsRemovedWhenALaterOneOfTheSameRunWentAheadBeforeTheStop() async {
            let limit = AsyncTestSignal()
            let submitter = makeSubmitter(predecessorDeadline: { await limit.wait() })
            let firstEntered = AsyncTestSignal()
            let releaseFirst = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    firstEntered.fire()
                    await releaseFirst.wait()
                },
                completion: { [weak self] _ in self?.log.append("first") })
            let first = submitter.lastSubmissionForTesting
            let firstHappened = await happened(firstEntered)
            XCTAssertTrue(firstHappened, "the first request did not happen")
            submitter.submit(
                blocking: {}, offMainThread: {},
                completion: { [weak self] _ in self?.log.append("second") })
            limit.fire()
            await submitter.lastSubmissionForTesting?.value
            submitter.cancel()  // the task stops; no restart
            releaseFirst.fire()
            await first?.value

            XCTAssertEqual(cancels, 2, "the task is stopped, so the late request must not stay pending")
            XCTAssertEqual(log, ["second"])
        }
    #endif

    #if DEBUG
        func testTheEndOfAWindowWaitsForARequestThatALaterOneWentAheadOf() async {
            let limit = AsyncTestSignal()
            let submitter = makeSubmitter(predecessorDeadline: { await limit.wait() })
            let firstEntered = AsyncTestSignal()
            let releaseFirst = AsyncTestSignal()
            let deadline = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    firstEntered.fire()
                    await releaseFirst.wait()
                },
                completion: { [weak self] _ in self?.log.append("first") })
            let firstHappened = await happened(firstEntered)
            XCTAssertTrue(firstHappened, "the first request did not happen")
            submitter.submit(
                blocking: {}, offMainThread: {}, completion: { [weak self] _ in self?.log.append("second") })
            limit.fire()
            await submitter.lastSubmissionForTesting?.value
            let waiting = AsyncTestSignal()
            let waiter = Task { () -> Bool in
                await submitter.pendingSubmissionsEnded(deadline: {
                    waiting.fire()
                    await deadline.wait()
                })
            }
            let waitingHappened = await happened(waiting)
            XCTAssertTrue(waitingHappened, "the wait did not start")
            deadline.fire()
            let ended = await boundedValue(of: waiter)
            releaseFirst.fire()

            XCTAssertEqual(ended, false, "the first request is still on its way, so the wait ends at the deadline")
            XCTAssertEqual(diagnostics.supportSnapshot().counters["backgroundWindows.endWaitTimedOut"], 1)
        }
    #endif

    func testTheEndOfAWindowWaitsForAllItsRequestsWithinOneDeadline() async {
        let submitter = makeSubmitter(predecessorDeadline: { await AsyncTestSignal().wait() })
        let firstEntered = AsyncTestSignal()
        let releaseFirst = AsyncTestSignal()
        let secondEntered = AsyncTestSignal()
        let releaseSecond = AsyncTestSignal()
        let deadline = AsyncTestSignal()
        let deadlineStarts = LockedValue<Int>()
        deadlineStarts.set(0)

        submitter.submit(
            blocking: {},
            offMainThread: {
                firstEntered.fire()
                await releaseFirst.wait()
            },
            completion: { [weak self] _ in self?.log.append("first") })
        submitter.submit(
            blocking: {},
            offMainThread: {
                secondEntered.fire()
                await releaseSecond.wait()
            },
            completion: { [weak self] _ in self?.log.append("second") })
        let firstHappened = await happened(firstEntered)
        XCTAssertTrue(firstHappened, "the first request did not happen")
        let waiter = Task { () -> Bool in
            await submitter.pendingSubmissionsEnded(deadline: {
                deadlineStarts.set((deadlineStarts.value ?? 0) + 1)
                await deadline.wait()
            })
        }
        releaseFirst.fire()
        let secondHappened = await happened(secondEntered)
        XCTAssertTrue(secondHappened, "the second request did not happen")
        deadline.fire()
        let ended = await boundedValue(of: waiter)
        releaseSecond.fire()

        XCTAssertEqual(deadlineStarts.value, 1, "one deadline covers the whole wait")
        XCTAssertEqual(ended, false)
    }

    #if DEBUG
        func testARequestGoesAheadOfOneThatDoesNotReturnWithinTheLimit() async {
            let limit = AsyncTestSignal()
            let submitter = makeSubmitter(predecessorDeadline: { await limit.wait() })
            let firstEntered = AsyncTestSignal()
            let releaseFirst = AsyncTestSignal()
            let secondSent = AsyncTestSignal()

            submitter.submit(
                blocking: {},
                offMainThread: {
                    firstEntered.fire()
                    await releaseFirst.wait()
                },
                completion: { [weak self] _ in self?.log.append("first") })
            let firstHappened = await happened(firstEntered)
            XCTAssertTrue(firstHappened, "the first request did not happen")
            submitter.submit(
                blocking: {}, offMainThread: { secondSent.fire() },
                completion: { [weak self] _ in self?.log.append("second") })
            limit.fire()
            // The bound only stops a hang; the count below is the evidence.
            let sent = await happened(secondSent)
            let wentAhead = diagnostics.supportSnapshot().counters["backgroundWindows.requestWentAheadOfALateOne"]
            releaseFirst.fire()
            await submitter.lastSubmissionForTesting?.value

            XCTAssertEqual(wentAhead, 1, "the second request went ahead of the first, which did not return")
            XCTAssertTrue(sent)
            XCTAssertEqual(diagnostics.supportSnapshot().counters["backgroundWindows.endWaitTimedOut"], nil)
        }
    #endif

    func testTheEndOfAWindowWaitsAtMostTheFixedLimit() {
        XCTAssertEqual(BackgroundTaskRequestSubmitter.endOfWindowWaitLimit, .seconds(5))
    }

    #if DEBUG
        func testACancelBeforeARequestLeavesThatRequestScheduled() async {
            let submitter = makeSubmitter()
            let reported = AsyncTestSignal()

            submitter.cancel()
            submitter.submit(blocking: {}, offMainThread: {}, completion: { _ in reported.fire() })

            let reportedHappened = await happened(reported)
            XCTAssertTrue(reportedHappened, "the report of the new request did not happen")
            await submitter.lastSubmissionForTesting?.value
            XCTAssertEqual(cancels, 1)
        }
    #endif

    func testAQueryThatAnswersBeforeTheDeadlineReturnsItsAnswerFromOffTheMainThread() async {
        let deadline = AsyncTestSignal()

        let answer = await BackgroundTaskRequestSubmitter.answer(
            of: { Self.runsOnTheMainThread() }, deadline: { await deadline.wait() })

        XCTAssertEqual(answer, false, "the query answers, off the main thread")
        deadline.fire()
    }

    func testTheDeadlineEndsAQueryThatDoesNotAnswer() async {
        let releaseQuery = AsyncTestSignal()
        let queryEnded = AsyncTestSignal()

        let answer = await BackgroundTaskRequestSubmitter.answer(
            of: { () -> Int in
                // Bounded, so an answer that ignores its deadline fails here instead of hanging the test.
                _ = await releaseQuery.wait(limit: XCTestCase.backgroundWindowEventLimit)
                queryEnded.fire()
                return 1
            },
            deadline: {})

        XCTAssertNil(answer, "the deadline ends the wait without the answer")
        releaseQuery.fire()
        let ended = await happened(queryEnded)
        XCTAssertTrue(ended, "the late answer is dropped")
    }
}
