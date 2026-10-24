import Foundation

/// Runs one operation for each item, at most `limit` at once, and keeps the item order in the answers.
///
/// Each item runs in its own unstructured task that the caller awaits before it returns, so no item outlives the call.
/// A cancellation of the caller cancels every running item and starts no further item. This replaces replenishing
/// task groups: with Swift 6.4 in optimized builds, a group child that catches the error of a cancelled read could
/// complete into a group that had already been destroyed (`swift::TaskGroup::offer` on freed memory).
public enum BoundedConcurrency {
    /// One answer for each item, in order. An item that never started because the caller was cancelled is nil.
    public static func map<Item: Sendable, Value: Sendable>(
        _ items: [Item], limit: Int, progress: (@Sendable (_ finished: Int) async -> Void)? = nil,
        _ operation: @escaping @Sendable (Item) async -> Value
    ) async -> [Value?] {
        await run(items, limit: limit, stopsOnFailure: false, progress: progress) { await operation($0) }
            .results.map { try? $0?.get() }
    }

    /// One answer for each item, in order. The first failure cancels the other items and is thrown once every running
    /// item has ended; `progress` counts no item after it. A cancelled caller gets `CancellationError` unless an item
    /// failed first.
    public static func throwingMap<Item: Sendable, Value: Sendable>(
        _ items: [Item], limit: Int, progress: (@Sendable (_ finished: Int) async -> Void)? = nil,
        _ operation: @escaping @Sendable (Item) async throws -> Value
    ) async throws -> [Value] {
        let run = await run(items, limit: limit, stopsOnFailure: true, progress: progress, operation)
        if let failure = run.firstFailure { throw failure }
        let values = run.results.compactMap { try? $0?.get() }
        guard values.count == items.count else { throw CancellationError() }
        return values
    }

    private static func run<Item: Sendable, Value: Sendable>(
        _ items: [Item], limit: Int, stopsOnFailure: Bool, progress: (@Sendable (Int) async -> Void)?,
        _ operation: @escaping @Sendable (Item) async throws -> Value
    ) async -> (results: [Result<Value, any Error>?], firstFailure: (any Error)?) {
        guard !items.isEmpty else { return ([], nil) }
        let state = BoundedRun<Value>(count: items.count)
        return await withTaskCancellationHandler {
            var next = 0
            var running = 0
            var finished = 0
            var firstFailure: (any Error)?
            func startNext() {
                guard next < items.count else { return }
                let item = items[next]
                guard state.start(next, { try await operation(item) }) else { return }
                next += 1
                running += 1
            }
            for _ in 0..<min(max(limit, 1), items.count) { startNext() }
            while running > 0 {
                let index = await state.nextEnded()
                running -= 1
                finished += 1
                if case .failure(let error) = await state.settle(index), stopsOnFailure, firstFailure == nil {
                    firstFailure = error
                    state.stop()
                }
                startNext()
                // After a failure the other items only end; the run reports no further progress.
                if firstFailure == nil { await progress?(finished) }
            }
            return (state.finish(), firstFailure)
        } onCancel: {
            state.stop()
        }
    }
}

/// The shared state of one run: the running tasks, the answers, and the order in which the tasks ended.
private final class BoundedRun<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Value, any Error>] = [:]
    private var results: [Result<Value, any Error>?]
    private var ended: [Int] = []
    private var waiter: CheckedContinuation<Int, Never>?
    private var stopped = false
    private var returned = false

    init(count: Int) { results = Array(repeating: nil, count: count) }

    /// Starts the item at `index` unless the run stopped. False when it did not start.
    func start(_ index: Int, _ operation: @escaping @Sendable () async throws -> Value) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            tasks[index] = Task {
                defer { self.ended(index) }
                return try await operation()
            }
            return true
        }
    }

    /// Cancels every running item and starts no further item.
    func stop() {
        let running = lock.withLock {
            stopped = true
            return Array(tasks.values)
        }
        running.forEach { $0.cancel() }
    }

    /// Waits until a running item has ended and returns its index.
    func nextEnded() async -> Int {
        await withCheckedContinuation { continuation in
            let index: Int? = lock.withLock {
                guard ended.isEmpty else { return ended.removeFirst() }
                waiter = continuation
                return nil
            }
            if let index { continuation.resume(returning: index) }
        }
    }

    /// Awaits the task of an ended item and records its answer.
    func settle(_ index: Int) async -> Result<Value, any Error> {
        guard let task = lock.withLock({ tasks.removeValue(forKey: index) }) else {
            preconditionFailure("BoundedConcurrency settled an item that it did not start")
        }
        let result = await task.result
        lock.withLock { results[index] = result }
        return result
    }

    /// The answers once every started item has ended.
    func finish() -> [Result<Value, any Error>?] {
        lock.withLock {
            returned = true
            return results
        }
    }

    private func ended(_ index: Int) {
        let waiter: CheckedContinuation<Int, Never>? = lock.withLock {
            #if DEBUG
                precondition(!returned, "a BoundedConcurrency item ended after the call returned")
            #endif
            guard let waiter = self.waiter else {
                ended.append(index)
                return nil
            }
            self.waiter = nil
            return waiter
        }
        waiter?.resume(returning: index)
    }
}
