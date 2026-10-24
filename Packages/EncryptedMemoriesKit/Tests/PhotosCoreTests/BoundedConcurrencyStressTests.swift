import Foundation
import PhotosCore
import Testing

/// Stress of `BoundedConcurrency` in an optimized build, with the item shapes of its callers. It runs only when
/// `EM_CONCURRENCY_STRESS=1` is set, so the regular test run stays fast:
/// `EM_CONCURRENCY_STRESS=1 swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG
/// --filter BoundedConcurrencyStressTests` (`-DDEBUG` keeps the test hooks of other suites compiling).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EM_CONCURRENCY_STRESS"] == "1"))
struct BoundedConcurrencyStressTests {
    static let iterations = 1_000
    static let drivers = 4
    static let items = Array(0..<343)
    static let lanes = 4

    /// The non-throwing fan-out of `ExactDuplicateFinder.groupFacts` and `ProtonUploadDedupeService.fetchLinks`: an
    /// item catches the error of its cancelled read, the shape that let a task group child complete into a destroyed
    /// group.
    @Test func boundedMapCatchingCancelledReads() async {
        let tally = await Self.drive { admission, progress in
            let report: @Sendable (Int) async -> Void = { await progress.report($0) }
            let values = await BoundedConcurrency.map(Self.items, limit: Self.lanes, progress: report) { item -> Int? in
                do {
                    try Task.checkCancellation()
                    return try await Self.read(item, admission: admission)
                } catch {
                    return nil
                }
            }
            let complete = values.compactMap { $0 ?? nil }
            return complete.count == Self.items.count ? complete : nil
        }
        #expect(tally.complete > 0)
        #expect(tally.wrong == 0)
    }

    /// The throwing fan-out of `ExactDuplicateFinder.visibility` and `SDKAlbumCatalogBackend.loadNodes`, each item a
    /// nested fan-out: the first failure ends the read.
    @Test func nestedThrowingBoundedMap() async {
        let tally = await Self.drive { admission, progress in
            let report: @Sendable (Int) async -> Void = { await progress.report($0) }
            let starts = Array(stride(from: 0, to: Self.items.count, by: 2))
            let pairs = try? await BoundedConcurrency.throwingMap(starts, limit: Self.lanes, progress: report) {
                start in
                try await BoundedConcurrency.throwingMap(Array(start..<min(start + 2, Self.items.count)), limit: 2) {
                    try await Self.read($0, admission: admission, failing: true)
                }
            }
            return pairs?.flatMap { $0 }
        }
        #expect(tally.complete > 0)
        #expect(tally.wrong == 0)
    }

    struct Tally: Sendable {
        var complete = 0
        var wrong = 0
    }

    /// Runs `pass` `iterations` times on `drivers` concurrent drivers at user-initiated priority, and cancels about
    /// half of the passes at a random moment.
    static func drive(
        _ pass: @escaping @Sendable (StressAdmission, StressProgress) async -> [Int]?
    ) async -> Tally {
        let expected = items.map { $0 * 2 }
        return await withTaskGroup(of: Tally.self) { drivers in
            for _ in 0..<Self.drivers {
                drivers.addTask {
                    var tally = Tally()
                    for _ in 0..<(iterations / Self.drivers) {
                        let admission = StressAdmission(permits: 2)
                        let progress = await StressProgress()
                        let task = Task(priority: .userInitiated) { await pass(admission, progress) }
                        if Bool.random() {
                            try? await Task.sleep(for: .microseconds(Int.random(in: 0...20_000)))
                            task.cancel()
                        }
                        if let values = await task.value {
                            if values == expected { tally.complete += 1 } else { tally.wrong += 1 }
                        }
                    }
                    return tally
                }
            }
            return await drivers.reduce(into: Tally()) {
                $0.complete += $1.complete
                $0.wrong += $1.wrong
            }
        }
    }

    /// One remote read: an admission like `ProtonRequestGovernor.acquire`, then a short random wait.
    static func read(_ item: Int, admission: StressAdmission, failing: Bool = false) async throws -> Int {
        try await admission.acquire()
        do {
            try await Task.sleep(for: .microseconds(Int.random(in: 0...300)))
        } catch {
            await admission.release()
            throw error
        }
        await admission.release()
        if failing, Int.random(in: 0..<20_000) == 0 { throw URLError(.timedOut) }
        return item * 2
    }
}

/// Permits like `ProtonRequestGovernor`: an actor-held continuation under a cancellation handler whose cancel hops
/// back onto the actor. The actor checks its executor after each resumption (swiftlang/swift#92915).
actor StressAdmission {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var granted = 0

    init(permits: Int) { available = permits }

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if available > 0 {
                    available -= 1
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        preconditionIsolated("the admission resumed off its actor")
        granted += 1
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// The main-actor progress sink of the Duplicates screen.
@MainActor final class StressProgress {
    private(set) var completed = 0

    func report(_ completed: Int) { self.completed = completed }
}
