import Foundation

/// One retry of an account's backend at a time. The owners of the earlier backend shut down before the next backend
/// starts, so two backends never work on the same account files, such as the duplicate-merge journal. A retry that
/// arrives while one runs waits for it and starts nothing itself.
@MainActor
public final class BackendRetrySequence {
    private var running: Task<Void, Never>?

    public init() {}

    /// The running retry. A recovery that replaces the backend on its own waits for it first.
    public var current: Task<Void, Never>? { running }

    /// Runs `retire`, waits for it, and then runs `start`, unless the retry was cancelled meanwhile.
    public func run(
        retire: @escaping @MainActor () async -> Void, start: @escaping @MainActor () -> Void
    ) async {
        if let running {
            await running.value
            return
        }
        let task = Task { @MainActor in
            await retire()
            guard !Task.isCancelled else { return }
            start()
        }
        running = task
        await task.value
        if running == task { running = nil }
    }

    /// Ends the running retry, for example at sign-out: it starts no backend afterwards. Returns it, so a teardown
    /// can wait for its retirement. A retry that starts after this call does not wait for the ended one, so the caller
    /// awaits the returned task before it lets the next backend start.
    @discardableResult
    public func cancel() -> Task<Void, Never>? {
        let task = running
        running = nil
        task?.cancel()
        return task
    }
}
