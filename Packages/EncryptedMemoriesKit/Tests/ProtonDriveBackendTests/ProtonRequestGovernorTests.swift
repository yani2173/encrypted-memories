import Foundation
import PhotosCore
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("Proton request governor")
struct ProtonRequestGovernorTests {
    @Test(.enabled(if: D1SupportOverheadProbe.enabled))
    func benchmarkD1UncontendedGovernorCollectionOverhead() async throws {
        try await D1SupportOverheadProbe.pairs(workload: "governorUncontended") { enabled in
            let collector = SupportWorkMeasurements(enabled: enabled)
            let governor = ProtonRequestGovernor(
                configuration: Self.configuration(initial: 1, maximum: 1),
                workMeasurements: collector, summaryLog: { _ in })
            let (_, elapsed) = try await D1SupportOverheadProbe.timed {
                for _ in 0..<2048 {
                    let permit = try await governor.acquire(scope: .api)
                    await governor.finish(permit, statusCode: 200)
                }
            }
            let state = await governor.snapshot().api
            #expect(state.inFlight == 0 && state.queued == 0)
            let snapshot = collector.workMeasurementSupportSnapshot()
            if enabled {
                #expect(snapshot.governorWaits[0].admitted.reduce(0, +) == 2048)
                #expect(snapshot.governorWaits[0].cancelled.reduce(0, +) == 0)
            } else {
                #expect(snapshot == .unavailable)
            }
            return elapsed
        }
    }

    @Test(.enabled(if: D1SupportOverheadProbe.enabled))
    func benchmarkD1QueuedGovernorCollectionOverhead() async throws {
        let priorities: [ProtonRequestPriority] = [.maintenance, .background, .userInitiated, .immediate]
        let expected = (0..<256).flatMap { _ in ["0", "1", "3", "4"] }
        try await D1SupportOverheadProbe.pairs(workload: "governorQueuedFour") { enabled in
            let collector = SupportWorkMeasurements(enabled: enabled)
            let governor = ProtonRequestGovernor(
                configuration: Self.configuration(initial: 1, maximum: 1),
                workMeasurements: collector, summaryLog: { _ in })
            let order = OrderRecorder()
            let (_, elapsed) = try await D1SupportOverheadProbe.timed {
                for _ in 0..<256 {
                    let held = try await governor.acquire(scope: .api)
                    let waiters = priorities.map { priority in
                        Task {
                            let permit = try await governor.acquire(scope: .api, priority: priority)
                            await order.append(String(priority.rawValue))
                            await governor.finish(permit, statusCode: 200)
                        }
                    }
                    defer { for waiter in waiters { waiter.cancel() } }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while await governor.snapshot().api.queued < 4, ContinuousClock.now < deadline {
                        await Task.yield()
                    }
                    guard await governor.snapshot().api.queued == 4 else {
                        for waiter in waiters { waiter.cancel() }
                        await governor.finish(held, statusCode: 200)
                        for waiter in waiters { _ = try? await waiter.value }
                        throw D1SupportOverheadProbe.Failure.queueDidNotFill
                    }
                    await governor.finish(held, statusCode: 200)
                    for waiter in waiters { try await waiter.value }
                }
            }
            #expect(await order.values == expected)
            let state = await governor.snapshot().api
            #expect(state.inFlight == 0 && state.queued == 0)
            let snapshot = collector.workMeasurementSupportSnapshot()
            if enabled {
                #expect(snapshot.governorWaits[0].admitted.reduce(0, +) == 1280)
                #expect(snapshot.governorWaits[0].cancelled.reduce(0, +) == 0)
            } else {
                #expect(snapshot == .unavailable)
            }
            return elapsed
        }
    }

    @Test func diagnosticWaitsCountAdmissionWithoutChangingTheQueue() async throws {
        let clock = TestClock()
        let measurements = SupportWorkMeasurements(now: { .seconds(clock.now.timeIntervalSince1970) })
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 1, maximum: 1), now: { clock.now },
            workMeasurements: measurements)
        let first = try await governor.acquire(scope: .api)
        let queued = Task { try await governor.acquire(scope: .api, priority: .maintenance) }
        defer { queued.cancel() }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }
        clock.now = clock.now.addingTimeInterval(2)
        await governor.finish(first, statusCode: 200)
        let second = try await queued.value
        await governor.finish(second, statusCode: 200)
        let state = measurements.workMeasurementSupportSnapshot().governorWaits[0]
        #expect(state.admitted == [1, 0, 0, 0, 1, 0, 0])
        #expect(state.cancelled.reduce(0, +) == 0)
        #expect(await governor.snapshot().api.inFlight == 0)
        #expect(await governor.snapshot().api.queued == 0)
    }

    @Test func diagnosticCancellationIsNotAnAdmission() async throws {
        let clock = TestClock()
        let measurements = SupportWorkMeasurements(now: { .seconds(clock.now.timeIntervalSince1970) })
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 1, maximum: 1), now: { clock.now },
            workMeasurements: measurements)
        let first = try await governor.acquire(scope: .api)
        let queued = Task { try await governor.acquire(scope: .api, priority: .maintenance) }
        defer { queued.cancel() }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }
        clock.now = clock.now.addingTimeInterval(0.125)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await governor.finish(first, statusCode: 200)
        let state = measurements.workMeasurementSupportSnapshot().governorWaits[0]
        #expect(state.admitted == [1, 0, 0, 0, 0, 0, 0])
        #expect(state.cancelled == [0, 0, 0, 1, 0, 0, 0])
        #expect(await governor.snapshot().api.inFlight == 0)
        #expect(await governor.snapshot().api.queued == 0)
    }

    @Test(arguments: [false, true])
    func demandedPrefetchOvertakesOtherWorkWithoutRestarting(promoteBeforeEnqueue: Bool) async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        let handle = ProtonRequestGovernor.PriorityHandle(priority: .foregroundPrefetch)
        let order = OrderRecorder()
        let other = Task {
            let permit = try await governor.acquire(scope: .storageDownload, priority: .userInitiated)
            await order.append("other")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        if promoteBeforeEnqueue { await governor.promote(handle, to: .immediate) }
        let prefetch = Task {
            let permit = try await governor.acquire(
                scope: .storageDownload, priority: .foregroundPrefetch, priorityHandle: handle)
            await order.append("prefetch")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 2 }
        await governor.promote(handle, to: .immediate)
        await governor.promote(handle, to: .immediate)
        #expect(await governor.snapshot().storageDownload.queued == 2)
        await governor.finish(first, statusCode: 200)
        try await prefetch.value
        try await other.value
        #expect(await order.values == ["prefetch", "other"])
        #expect(await governor.snapshot().storageDownload.inFlight == 0)
    }

    @Test func immediateWorkOvertakesQueuedBackgroundWork() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api, priority: .background)
        let order = OrderRecorder()

        let background = Task {
            let permit = try await governor.acquire(scope: .api, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        let immediate = Task {
            let permit = try await governor.acquire(scope: .api, priority: .immediate)
            await order.append("immediate")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().api.queued == 2 }

        await governor.finish(first, statusCode: 200)
        try await immediate.value
        try await background.value
        #expect(await order.values == ["immediate", "background"])
    }

    @Test func rateLimitReducesConcurrencyAndSuccessesRecoverIt() async throws {
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(
                initial: 4,
                maximum: 6,
                successWindow: 2
            ))

        for _ in 0..<3 {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
        let limited = try await governor.acquire(scope: .api)
        await governor.finish(limited, statusCode: 429, retryAfter: 0.001)

        var snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 2)
        #expect(snapshot.rateLimitedLastMinute == 1)
        #expect(snapshot.sustainableRateBeforeLastLimit == 3)
        #expect(snapshot.successfulRequestsPerSecondBeforeLastLimit == 3)
        #expect(snapshot.admissionInterval > 0)

        for _ in 0..<2 {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
        snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 3)
    }

    @Test func quietTimeRecoversFromARateLimitWithoutManySuccesses() async throws {
        let clock = TestClock()
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 4, maximum: 6, recoveryInterval: 5),
            now: { clock.now }
        )
        // Four requests run at once and all hit the limit; the cooldown admits nothing new meanwhile.
        var permits: [ProtonRequestGovernor.Permit] = []
        for _ in 0..<4 { permits.append(try await governor.acquire(scope: .api)) }
        for permit in permits { await governor.finish(permit, statusCode: 429, retryAfter: 0.001) }
        var snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 1)
        #expect(snapshot.admissionInterval == 2, "several 429s pace the scope at the 2 s ceiling")

        // One request every few seconds never reaches the success window; time alone must recover.
        clock.now = clock.now.addingTimeInterval(5)
        snapshot = await governor.snapshot().api
        #expect(snapshot.admissionInterval == 1)
        #expect(snapshot.concurrencyLimit == 2)

        clock.now = clock.now.addingTimeInterval(60)
        snapshot = await governor.snapshot().api
        #expect(snapshot.admissionInterval == 0)
        #expect(snapshot.concurrencyLimit == 4)

        // A viewer request after the quiet time starts at once.
        let permit = try await governor.acquire(scope: .api, priority: .immediate)
        await governor.finish(permit, statusCode: 200)

        // A new 429 paces the scope again.
        let limited = try await governor.acquire(scope: .api)
        await governor.finish(limited, statusCode: 429, retryAfter: 0.001)
        #expect(await governor.snapshot().api.admissionInterval > 0)
    }

    @Test func cancellingQueuedRequestDoesNotLeakAWaiter() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api)
        let queued = Task { try await governor.acquire(scope: .api, priority: .maintenance) }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        queued.cancel()
        do {
            _ = try await queued.value
            Issue.record("cancelled acquisition unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await governor.snapshot().api.queued == 0)
        await governor.finish(first, statusCode: 200)
        #expect(await governor.snapshot().api.inFlight == 0)
    }

    @Test func finishingSamePermitTwiceCannotReleaseAnotherRequest() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api)
        await governor.finish(first, statusCode: 200)
        let second = try await governor.acquire(scope: .api)
        let third = Task { try await governor.acquire(scope: .api) }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        await governor.finish(first, statusCode: 200)
        #expect(await governor.snapshot().api.inFlight == 1)
        #expect(await governor.snapshot().api.queued == 1)

        third.cancel()
        _ = try? await third.value
        await governor.finish(second, statusCode: 200)
    }

    @Test func sdkPriorityScopeSurvivesNativeTaskBoundary() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload, priority: .background)
        let order = OrderRecorder()
        let background = Task {
            let permit = try await governor.acquire(scope: .storageDownload, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }

        let scope = await governor.beginPriorityScope(.immediate)
        let sdkCallback = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await governor.acquire(scope: .storageDownload)
            }
            await order.append("visible")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 2 }
        await governor.finish(first, statusCode: 200)

        try await sdkCallback.value
        await governor.endPriorityScope(scope)
        try await background.value
        #expect(await order.values == ["visible", "background"])
    }

    @Test func explicitPrefetchRemainsBelowImmediateDemandDuringViewerPromotion() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload, priority: .background)
        let order = OrderRecorder()
        let viewerScope = await governor.beginPriorityScope(
            .immediate,
            promoting: [.storageDownload]
        )

        let prefetch = Task {
            let permit = try await governor.acquire(
                scope: .storageDownload,
                priority: .foregroundPrefetch
            )
            await order.append("prefetch")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }

        let immediate = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await governor.acquire(scope: .storageDownload)
            }
            await order.append("immediate")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 2 }

        await governor.finish(first, statusCode: 200)
        try await immediate.value
        try await prefetch.value
        await governor.endPriorityScope(viewerScope)
        #expect(await order.values == ["immediate", "prefetch"])
    }

    @Test func targetedPriorityDoesNotPromoteUnrelatedUpload() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageUpload, priority: .background)
        let order = OrderRecorder()
        let background = Task {
            let permit = try await governor.acquire(scope: .storageUpload, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        let scope = await governor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload]
        )
        let unrelated = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await governor.acquire(scope: .storageUpload)
            }
            await order.append("unrelated")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 2 }
        await governor.finish(first, statusCode: 200)

        try await background.value
        await governor.endPriorityScope(scope)
        try await unrelated.value
        #expect(await order.values == ["background", "unrelated"])
    }

    @Test func interactiveViewerScopeBlocksOnlyNewUploadsAndEndResumesThem() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let activeUpload = try await governor.acquire(scope: .storageUpload, priority: .background)
        let scope = await governor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        let queuedUpload = Task {
            try await governor.acquire(scope: .storageUpload, priority: .background)
        }
        try await Self.waitUntil {
            let snapshot = await governor.snapshot().storageUpload
            return snapshot.inFlight == 1 && snapshot.queued == 1
        }
        await governor.finish(activeUpload, statusCode: 200)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await governor.snapshot().storageUpload.inFlight == 0)
        #expect(await governor.snapshot().storageUpload.queued == 1)

        await governor.endPriorityScope(scope)
        let resumed = try await queuedUpload.value
        #expect(await governor.snapshot().storageUpload.inFlight == 1)
        await governor.finish(resumed, statusCode: 200)
    }

    @Test func priorityScopeSurvivesElapsedTimeAndEndsOnCompletion() async throws {
        let clock = TestClock()
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 1, maximum: 1),
            now: { clock.now }
        )
        let activeUpload = try await governor.acquire(scope: .storageUpload, priority: .background)
        let started = AsyncLatch()
        let complete = AsyncLatch()
        let interactive = Task {
            await governor.withPriorityScope(
                .immediate,
                promoting: [.api, .storageDownload],
                suspending: [.storageUpload]
            ) {
                await started.open()
                await complete.wait()
            }
        }
        await started.wait()
        let queuedUpload = Task {
            try await governor.acquire(scope: .storageUpload, priority: .background)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        await governor.finish(activeUpload, statusCode: 200)
        clock.now = clock.now.addingTimeInterval(2)
        _ = await governor.snapshot()

        #expect(await governor.snapshot().storageUpload.inFlight == 0)
        #expect(await governor.snapshot().storageUpload.queued == 1)
        await complete.open()
        await interactive.value
        let resumed = try await queuedUpload.value
        await governor.finish(resumed, statusCode: 200)
        #expect(await governor.snapshot().storageUpload.inFlight == 0)
    }

    @Test func boundedInteractiveRequestReleasesUploadAdmissionWhenCancelled() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let started = AsyncLatch()
        let interactive = Task {
            try await governor.withPriorityScope(
                .immediate,
                promoting: [],
                suspending: [.storageUpload]
            ) {
                await started.open()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await started.wait()
        let upload = Task { try await governor.acquire(scope: .storageUpload, priority: .background) }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        interactive.cancel()
        _ = try? await interactive.value
        let permit = try await upload.value
        #expect(await governor.snapshot().storageUpload.inFlight == 1)
        await governor.finish(permit, statusCode: 200)
    }

    @Test func structuredPriorityScopeReleasesUploadAdmissionWhenThrown() async throws {
        struct ExpectedFailure: Error {}

        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let started = AsyncLatch()
        let fail = AsyncLatch()
        let interactive = Task {
            let _: Void = try await governor.withPriorityScope(
                .immediate,
                promoting: [],
                suspending: [.storageUpload]
            ) {
                await started.open()
                await fail.wait()
                throw ExpectedFailure()
            }
        }
        await started.wait()
        let upload = Task { try await governor.acquire(scope: .storageUpload, priority: .background) }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        await fail.open()
        await #expect(throws: ExpectedFailure.self) { try await interactive.value }
        let permit = try await upload.value
        #expect(await governor.snapshot().storageUpload.inFlight == 1)
        await governor.finish(permit, statusCode: 200)
    }

    @Test func completedProducerKeepsStoragePermitUntilConsumerObservesEOF() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        let completion = StreamPermitCompletion(governor: governor, permit: first)
        let (source, producer) = AsyncStream<UInt8>.makeStream()
        producer.yield(1)
        producer.finish()
        let wrapped = PermitFinishingAsyncSequence(
            source: AnyAsyncSequence(source),
            completion: completion,
            responseStatusCode: 200,
            retryAfter: nil
        )
        var iterator: PermitFinishingAsyncSequence.Iterator? = wrapped.makeAsyncIterator()

        let second = Task { try await governor.acquire(scope: .storageDownload) }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        #expect(try await iterator?.next() == 1)
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        #expect(await governor.snapshot().storageDownload.queued == 1)

        #expect(try await iterator?.next() == nil)
        iterator = nil
        let secondPermit = try await second.value
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        await governor.finish(secondPermit, statusCode: 200)
    }

    @Test func thrownConsumerReleasesStoragePermitAsFailure() async throws {
        struct ExpectedFailure: Error {}
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        let completion = StreamPermitCompletion(governor: governor, permit: first)
        let source = AsyncThrowingStream<UInt8, Error> { continuation in
            continuation.finish(throwing: ExpectedFailure())
        }
        let wrapped = PermitFinishingAsyncSequence(
            source: AnyAsyncSequence(source),
            completion: completion,
            responseStatusCode: 200,
            retryAfter: nil
        )
        var iterator = wrapped.makeAsyncIterator()

        let second = Task { try await governor.acquire(scope: .storageDownload) }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        await #expect(throws: ExpectedFailure.self) { try await iterator.next() }

        let secondPermit = try await second.value
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        await governor.finish(secondPermit, statusCode: 200)
    }

    @Test func droppingUnconsumedStorageStreamReleasesPermitWithoutRetainingCompletion() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        weak var releasedCompletion: StreamPermitCompletion?
        do {
            let completion = StreamPermitCompletion(governor: governor, permit: first)
            releasedCompletion = completion
        }

        #expect(releasedCompletion == nil)
        try await Self.waitUntil { await governor.snapshot().storageDownload.inFlight == 0 }
        let second = Task { try await governor.acquire(scope: .storageDownload) }
        let secondPermit = try await second.value
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        await governor.finish(secondPermit, statusCode: 200)
    }

    @Test func retryAfterParsesSecondsAndHTTPDate() throws {
        let url = try #require(URL(string: "https://drive-api.proton.me/test"))
        let seconds = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "7"]
            ))
        #expect(ProtonRetryAfter.seconds(from: seconds) == 7)

        let now = Date(timeIntervalSince1970: 784_111_777)
        let date = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:49:47 GMT"]
            ))
        #expect(ProtonRetryAfter.seconds(from: date, now: now) == 10)
    }

    private static func configuration(
        initial: Int,
        maximum: Int,
        successWindow: Int = 32,
        recoveryInterval: TimeInterval = 5
    ) -> ProtonRequestGovernor.Configuration {
        let scope = ProtonRequestGovernor.Configuration.Scope(
            initialConcurrency: initial,
            maximumConcurrency: maximum
        )
        return .init(
            api: scope,
            storageDownload: scope,
            storageUpload: scope,
            successWindowForIncrease: successWindow,
            starvationPromotionInterval: 10,
            rateLimitRecoveryInterval: recoveryInterval
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition did not become true before timeout")
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private actor AsyncLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Opt-in Release measurements. The caller prepares fixtures and verifies results outside the timed interval.
enum D1SupportOverheadProbe {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_D1_OVERHEAD"] == "1"
    }

    enum Failure: Error { case queueDidNotFill }

    static func timed<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async rethrows -> (Value, Double) {
        let start = ContinuousClock.now
        let result = try await operation()
        let duration = start.duration(to: .now).components
        let nanoseconds = Double(duration.seconds) * 1e9 + Double(duration.attoseconds) / 1e9
        return (result, nanoseconds)
    }

    static func pairs(
        workload: String, sample: (Bool) async throws -> Double
    ) async throws {
        #if DEBUG
            Issue.record("Run the D1 overhead measurements with Release optimization")
            return
        #endif
        for block in 0..<2 {
            // Two predefined warm-up pairs, followed by twelve retained pairs. Both orders occur equally often.
            for index in 0..<14 {
                let enabledFirst = (index + block).isMultiple(of: 2)
                let first = try await sample(enabledFirst)
                let second = try await sample(!enabledFirst)
                #expect(first.isFinite && first > 0 && second.isFinite && second > 0)
                if index >= 2 {
                    let row: [String: Any] = [
                        "workload": workload, "block": block, "pair": index - 2,
                        "enabledFirst": enabledFirst ? 1 : 0,
                        "enabledNanoseconds": enabledFirst ? first : second,
                        "disabledNanoseconds": enabledFirst ? second : first,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print("D1_OVERHEAD_PAIR " + String(decoding: data, as: UTF8.self))
                }
            }
        }
    }
}
