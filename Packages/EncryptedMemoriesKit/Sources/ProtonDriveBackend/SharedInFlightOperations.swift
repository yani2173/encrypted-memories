import Foundation

/// Lets overlapping callers with the same key share one running operation. It keeps no finished result: a caller
/// that arrives after the operation ended starts a new one.
///
/// Each caller waits on its own. A cancelled caller stops waiting at once; the operation is cancelled only when no
/// caller waits for it any more. `invalidate()` detaches every running operation, so later callers start new ones,
/// while the callers that already wait keep the answer of the operation they joined. `invalidateAndJoin()` also
/// cancels the detached operations and waits until they ended, before their owner shuts the client down.
actor SharedInFlightOperations<Key: Hashable & Sendable, Value: Sendable> {
    private struct Flight {
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
    }

    private var flights: [UUID: Flight] = [:]
    private var current: [Key: UUID] = [:]

    func run(
        _ key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(key, waiterID: waiterID, continuation: continuation, operation: operation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// The callers that wait now, over all running operations.
    var waitingCallers: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }

    func invalidate() {
        current.removeAll()
    }

    func invalidateAndJoin() async {
        current.removeAll()
        let tasks = flights.values.compactMap(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func join(
        _ key: Key,
        waiterID: UUID,
        continuation: CheckedContinuation<Value, any Error>,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        if let flightID = current[key], flights[flightID] != nil {
            flights[flightID]?.waiters[waiterID] = continuation
        } else {
            let flightID = UUID()
            flights[flightID] = Flight(waiters: [waiterID: continuation])
            current[key] = flightID
            let task = Task { [weak self] in
                let result: Result<Value, any Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                await self?.complete(key, flightID: flightID, result: result)
            }
            flights[flightID]?.task = task
        }
        if Task.isCancelled {
            cancelWaiter(waiterID)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let (flightID, flight) = flights.first(where: { $0.value.waiters[waiterID] != nil }),
            let continuation = flights[flightID]?.waiters.removeValue(forKey: waiterID)
        else { return }
        if flight.waiters.count == 1 {
            // Nobody waits any more. A later caller must not join the cancelled operation; the operation stays in
            // `flights` until it ended, so a shutdown still joins it.
            current = current.filter { $0.value != flightID }
            flight.task?.cancel()
        }
        continuation.resume(throwing: CancellationError())
    }

    private func complete(_ key: Key, flightID: UUID, result: Result<Value, any Error>) {
        if current[key] == flightID {
            current[key] = nil
        }
        guard let flight = flights.removeValue(forKey: flightID) else { return }
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }
}
