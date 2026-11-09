import XCTest

@testable import UploadCore

@MainActor
final class EditedOriginalRevertResumeSlotTests: XCTestCase {
    func testAStartRunsTheResumeOnceAndReportsItsSummary() async throws {
        let slot = EditedOriginalRevertResumeSlot()
        let runs = Counter()
        let reported = expectation(description: "the summary is reported")
        var received: [Int] = []

        slot.start(
            resume: {
                await runs.increment()
                return makeSummary(finished: 2)
            },
            report: {
                received.append($0.finished)
                reported.fulfill()
            })

        await fulfillment(of: [reported], timeout: 10)
        let count = await runs.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(received, [2])
    }

    /// A second start replaces the first: the first resume sees its cancellation and reports nothing, and the second
    /// runs exactly once.
    func testASecondStartCancelsTheFirstAndRunsTheSecondOnce() async throws {
        let slot = EditedOriginalRevertResumeSlot()
        let firstRuns = Counter()
        let secondRuns = Counter()
        let firstRunning = expectation(description: "the first resume runs")
        let firstCancelled = expectation(description: "the first resume sees its cancellation")
        let secondReported = expectation(description: "the second summary is reported")
        var received: [Int] = []

        slot.start(
            resume: {
                await firstRuns.increment()
                firstRunning.fulfill()
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                firstCancelled.fulfill()
                return makeSummary(finished: 1)
            },
            report: { received.append($0.finished) })
        await fulfillment(of: [firstRunning], timeout: 10)

        slot.start(
            resume: {
                await secondRuns.increment()
                return makeSummary(finished: 2)
            },
            report: {
                received.append($0.finished)
                secondReported.fulfill()
            })

        await fulfillment(of: [firstCancelled, secondReported], timeout: 10)
        let first = await firstRuns.value
        let second = await secondRuns.value
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(received, [2], "only the second summary is reported")
    }

    func testCancelEndsARunningResumeAndReportsNothing() async throws {
        let slot = EditedOriginalRevertResumeSlot()
        let running = expectation(description: "the resume runs")
        let cancelled = expectation(description: "the resume sees its cancellation")
        var received: [Int] = []

        slot.start(
            resume: {
                running.fulfill()
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                cancelled.fulfill()
                return makeSummary(finished: 1)
            },
            report: { received.append($0.finished) })
        await fulfillment(of: [running], timeout: 10)

        slot.cancel()

        await fulfillment(of: [cancelled], timeout: 10)
        // Give the cancelled task every chance to reach its report, then prove with a second resume that the main
        // actor ran past it: the first report would sit in `received` before the second one.
        for _ in 0..<20 { await Task.yield() }
        let sentinel = expectation(description: "the second summary is reported")
        slot.start(
            resume: { makeSummary(finished: 9) },
            report: {
                received.append($0.finished)
                sentinel.fulfill()
            })
        await fulfillment(of: [sentinel], timeout: 10)
        XCTAssertEqual(received, [9], "the cancelled resume reported nothing")
    }
}

private func makeSummary(finished: Int) -> EditedOriginalRevertResumeSummary {
    EditedOriginalRevertResumeSummary(finished: finished, failures: [], readFailure: nil)
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
