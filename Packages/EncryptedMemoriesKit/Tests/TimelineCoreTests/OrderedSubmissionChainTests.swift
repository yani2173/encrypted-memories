import Testing

@testable import TimelineCore

@Suite struct OrderedSubmissionChainTests {
    @Test(.timeLimit(.minutes(1)))
    func laterWorkWaitsForEarlierWorkToFinish() async {
        let chain = OrderedSubmissionChain()
        let events = SubmissionEvents()
        let release = SubmissionGate()
        chain.append {
            await events.record("first started")
            await release.wait()
            await events.record("first finished")
        }
        chain.append { await events.record("second") }
        chain.append { await events.record("third") }
        #expect(await events.waitForCount(1))
        // The later work must not start while the first work is held.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await events.all == ["first started"])
        await release.open()
        #expect(await events.waitForCount(4))
        #expect(await events.all == ["first started", "first finished", "second", "third"])
    }
}

private actor SubmissionEvents {
    private(set) var all: [String] = []

    func record(_ event: String) { all.append(event) }

    func waitForCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while all.count < count, ContinuousClock.now < deadline { await Task.yield() }
        return all.count >= count
    }
}

private actor SubmissionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
