import Testing

@testable import TimelineCore

@Suite struct LibraryRefreshCoalescerTests {
    #if DEBUG
        @Test func overlappingRequestWaitsAndRunsExactlyOneFollowUpRefresh() async {
            let coalescer = LibraryRefreshCoalescer()
            let probe = BlockingRefreshProbe()

            let first = Task { await coalescer.request { await probe.refresh() } }
            await probe.waitUntilFirstRefreshStarts()
            let second = Task { await coalescer.request { await probe.refresh() } }
            let third = Task { await coalescer.request { await probe.refresh() } }
            while await coalescer.testingState().requestedGeneration < 3 { await Task.yield() }

            await probe.releaseFirstRefresh()

            #expect(await first.value == .refreshed(token: "published"))
            #expect(await second.value == .refreshed(token: "published"))
            #expect(await third.value == .refreshed(token: "published"))
            #expect(await probe.callCount == 2)
        }
    #endif

    @Test func completedDrainDoesNotRetainAStaleTask() async {
        let coalescer = LibraryRefreshCoalescer()
        let counter = RefreshCounter()

        #expect(await coalescer.request { await counter.refresh() } == .refreshed(token: "published"))
        #expect(await coalescer.request { await counter.refresh() } == .refreshed(token: "published"))
        #expect(await counter.value == 2)
    }

    #if DEBUG
        @Test func terminalOutcomeStopsOverlappingRequestsWithoutASecondProbe() async {
            let coalescer = LibraryRefreshCoalescer()
            let probe = BlockingRefreshProbe(firstOutcome: .terminal)

            let first = Task { await coalescer.request { await probe.refresh() } }
            await probe.waitUntilFirstRefreshStarts()
            let second = Task { await coalescer.request { await probe.refresh() } }
            let third = Task { await coalescer.request { await probe.refresh() } }
            while await coalescer.testingState().requestedGeneration < 3 { await Task.yield() }

            await probe.releaseFirstRefresh()

            #expect(await first.value == .terminal)
            #expect(await second.value == .terminal)
            #expect(await third.value == .terminal)
            #expect(await probe.callCount == 1)
        }

        @Test func publicRequestWaitsUntilCancellationJoinsOldDrain() async {
            let coalescer = LibraryRefreshCoalescer()
            let blocked = BlockingRefreshProbe()
            let replacement = RefreshCounter()
            let cancellation = CompletionProbe()

            let old = Task { await coalescer.request { await blocked.refresh() } }
            await blocked.waitUntilFirstRefreshStarts()
            let cancelTask = Task {
                await coalescer.cancel()
                await cancellation.markComplete()
            }
            while !(await coalescer.testingState().cancellationBarrierActive) { await Task.yield() }
            #expect(await cancellation.isComplete == false)
            let new = Task { await coalescer.request { await replacement.refresh() } }
            await Task.yield()
            #expect(await replacement.value == 0)
            await blocked.releaseFirstRefresh()
            await cancelTask.value

            #expect(await new.value == .refreshed(token: "published"))
            #expect(await replacement.value == 1)
            _ = await old.value
        }
    #endif
}

private actor RefreshCounter {
    private(set) var value = 0

    func refresh() -> LibraryChangeRefreshOutcome {
        value += 1
        return .refreshed(token: "published")
    }
}

private actor BlockingRefreshProbe {
    private let firstOutcome: LibraryChangeRefreshOutcome
    private(set) var callCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRefreshContinuation: CheckedContinuation<Void, Never>?

    init(firstOutcome: LibraryChangeRefreshOutcome = .refreshed(token: "published")) {
        self.firstOutcome = firstOutcome
    }

    func refresh() async -> LibraryChangeRefreshOutcome {
        callCount += 1
        guard callCount == 1 else { return .refreshed(token: "published") }

        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstRefreshContinuation = continuation
        }
        return firstOutcome
    }

    func waitUntilFirstRefreshStarts() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstRefresh() {
        firstRefreshContinuation?.resume()
        firstRefreshContinuation = nil
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}
