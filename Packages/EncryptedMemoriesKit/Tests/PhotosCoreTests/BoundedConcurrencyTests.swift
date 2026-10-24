import Foundation
import PhotosCore
import Testing

@Suite("Bounded concurrency")
struct BoundedConcurrencyTests {
    @Test func answersKeepTheItemOrderWhateverOrderTheItemsEnd() async throws {
        let items = Array(0..<24)
        let values = try await BoundedConcurrency.throwingMap(items, limit: 4) { item in
            try await Task.sleep(for: .microseconds(Int.random(in: 0...3_000)))
            return item * 10
        }
        #expect(values == items.map { $0 * 10 })
        let mapped = await BoundedConcurrency.map(items, limit: 4) { item in
            try? await Task.sleep(for: .microseconds(Int.random(in: 0...3_000)))
            return item + 1
        }
        #expect(mapped == items.map { $0 + 1 })
    }

    @Test func runsAtMostTheLimitAtOnceAndUsesTheWholeLimit() async {
        let probe = ConcurrencyProbe()
        _ = await BoundedConcurrency.map(Array(0..<20), limit: 3) { _ in
            probe.enter()
            try? await Task.sleep(for: .milliseconds(2))
            probe.leave()
        }
        #expect(probe.maximum == 3)
        #expect(probe.entered == 20)
    }

    @Test func reportsEachEndedItemInOrder() async {
        let reports = ConcurrencyProbe()
        let report: @Sendable (Int) async -> Void = { reports.record($0) }
        _ = await BoundedConcurrency.map(Array(0..<7), limit: 2, progress: report) { $0 }
        #expect(reports.recorded == Array(1...7))
    }

    @Test func theFirstFailureCancelsTheRunningItemsStartsNoOtherAndIsThrown() async {
        let probe = ConcurrencyProbe()
        await #expect(throws: ProbeError.self) {
            try await BoundedConcurrency.throwingMap(Array(0..<10), limit: 3) { item in
                probe.enter()
                defer { probe.leave() }
                if item == 0 {
                    try await Task.sleep(for: .milliseconds(5))
                    throw ProbeError()
                }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    probe.record(item)
                    throw error
                }
                return item
            }
        }
        #expect(probe.entered == 3, "no item starts after the failure")
        #expect(Set(probe.recorded) == [1, 2], "the running items were cancelled")
        #expect(probe.active == 0, "every item ended before the call returned")
    }

    @Test func progressCountsNoItemAfterTheFirstFailure() async {
        let reports = ConcurrencyProbe()
        let report: @Sendable (Int) async -> Void = { reports.record($0) }
        _ = try? await BoundedConcurrency.throwingMap(Array(0..<6), limit: 3, progress: report) { item in
            switch item {
            case 0:
                return item
            case 1:
                try await Task.sleep(for: .milliseconds(20))
                throw ProbeError()
            default:
                try await Task.sleep(for: .seconds(30))
                return item
            }
        }
        #expect(reports.recorded == [1])
    }

    @Test func cancellingTheCallerCancelsEveryItemAndStartsNoOther() async {
        let probe = ConcurrencyProbe()
        let started = Gate()
        let run = Task {
            await BoundedConcurrency.map(Array(0..<10), limit: 4) { item -> Int? in
                probe.enter()
                defer { probe.leave() }
                if probe.entered == 4 { started.open() }
                do {
                    try await Task.sleep(for: .seconds(30))
                    return item
                } catch {
                    probe.record(item)
                    return nil
                }
            }
        }
        await started.wait()
        run.cancel()
        let values = await run.value
        #expect(values.count == 10)
        #expect(values.allSatisfy { ($0 ?? nil) == nil })
        #expect(probe.entered == 4, "no item starts after the cancellation")
        #expect(Set(probe.recorded) == [0, 1, 2, 3])
        #expect(probe.active == 0, "every item ended before the call returned")
    }

    @Test func aCancelledCallerOfTheThrowingVariantGetsACancellationError() async {
        let started = Gate()
        let run = Task {
            try await BoundedConcurrency.throwingMap(Array(0..<6), limit: 2) { item in
                started.open()
                try? await Task.sleep(for: .seconds(30))
                return item
            }
        }
        await started.wait()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }

    @Test func aCallerCancelledBeforehandStartsNothing() async {
        let probe = ConcurrencyProbe()
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BoundedConcurrency.map(Array(0..<5), limit: 2) { item in
                probe.enter()
                probe.leave()
                return item
            }
        }
        #expect(await run.value == [nil, nil, nil, nil, nil])
        #expect(probe.entered == 0)
    }

    @Test func noItemsCallNothing() async throws {
        let probe = ConcurrencyProbe()
        let mapped = await BoundedConcurrency.map([Int](), limit: 4) { item in
            probe.enter()
            return item
        }
        let thrown = try await BoundedConcurrency.throwingMap([Int](), limit: 4) { item in
            probe.enter()
            return item
        }
        #expect(mapped.isEmpty)
        #expect(thrown.isEmpty)
        #expect(probe.entered == 0)
    }
}

private struct ProbeError: Error {}

/// Counts the items that run at once, and records values in the order they arrive.
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _active = 0
    private var _maximum = 0
    private var _entered = 0
    private var _recorded: [Int] = []

    var active: Int { lock.withLock { _active } }
    var maximum: Int { lock.withLock { _maximum } }
    var entered: Int { lock.withLock { _entered } }
    var recorded: [Int] { lock.withLock { _recorded } }

    func enter() {
        lock.withLock {
            _active += 1
            _entered += 1
            _maximum = max(_maximum, _active)
        }
    }

    func leave() { lock.withLock { _active -= 1 } }

    func record(_ value: Int) { lock.withLock { _recorded.append(value) } }
}

/// Opens once; `wait` returns when it is open.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if passes { continuation.resume() }
        }
    }
}
