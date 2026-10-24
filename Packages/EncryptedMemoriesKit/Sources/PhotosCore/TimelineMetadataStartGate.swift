import Foundation

/// Holds the timeline metadata pass while the first full remote index build of a launch runs, so the two
/// whole-library metadata reads do not overlap. A waiter returns when the gate opens, after `startLimit` while no
/// build has started, after `limit` in any case, or on cancellation. An open gate stays open for the launch.
public final class TimelineMetadataStartGate: @unchecked Sendable {
    /// A backup that is off, waits for a network, or has no runnable photo starts no build.
    public static let defaultStartLimit: Duration = .seconds(2 * 60)
    public static let defaultLimit: Duration = .seconds(15 * 60)

    private enum State { case waitingForBuild, building, open }

    private let lock = NSLock()
    private let startLimit: Duration
    private let limit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var state = State.waitingForBuild
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var timer: Task<Void, Never>?

    public convenience init(startLimit: Duration = defaultStartLimit, limit: Duration = defaultLimit) {
        self.init(startLimit: startLimit, limit: limit, sleep: { try await Task.sleep(for: $0) })
    }

    /// The sleeper is a test seam: a test holds each wait and releases it, so no assertion depends on the speed of
    /// the machine.
    init(startLimit: Duration, limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.startLimit = startLimit
        self.limit = max(limit, startLimit)
        self.sleep = sleep
    }

    /// The first full build began; from now on only `limit` bounds the wait.
    public func buildStarted() {
        lock.withLock {
            if state == .waitingForBuild { state = .building }
        }
    }

    /// The build finished or failed, or this launch has no first full build.
    public func open() {
        let (resumed, timer) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Task<Void, Never>?) in
            guard state != .open else { return ([], nil) }
            state = .open
            defer {
                waiters = [:]
                self.timer = nil
            }
            return (Array(waiters.values), self.timer)
        }
        timer?.cancel()
        resumed.forEach { $0.resume() }
    }

    public func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let admitted = lock.withLock { () -> Bool in
                    guard state != .open, !Task.isCancelled else { return false }
                    waiters[id] = continuation
                    if timer == nil {
                        timer = Task { [weak self, startLimit, limit, sleep] in
                            try? await sleep(startLimit)
                            if self?.isBuilding == true { try? await sleep(limit - startLimit) }
                            self?.open()
                        }
                    }
                    return true
                }
                if !admitted { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    private var isBuilding: Bool {
        lock.withLock { state == .building }
    }
}
