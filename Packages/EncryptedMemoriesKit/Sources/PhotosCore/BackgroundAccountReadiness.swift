import Foundation

/// What the app's last read of the saved sign-in found. Only that read decides it; the device's lock state is never
/// asked.
public enum BackgroundSessionRead: Equatable, Sendable {
    /// No read yet, or a read that decides nothing: a failed startup cleanup reads no session, and an error other
    /// than a locked Keychain may pass.
    case notYet
    /// The sign-in was read.
    case readable
    /// The Keychain refused the read because the device has not been unlocked since it started.
    case unreadable
    /// No sign-in is saved, or the person signed out.
    case absent
}

/// How a window's wait for an account service ended.
public enum BackgroundAccountWait<Service: AnyObject & Sendable>: Sendable {
    case ready(Service)
    /// The window cannot run: `.endedAtOnceLocked` or `.noAccount`.
    case cannotRun(BackgroundWindowOutcome)
    /// The service did not come within the limit, or the window's work was cancelled.
    case notReady

    /// The outcome of a window that got no service. An expiry decides first.
    public func outcomeWithoutService(didExpire: Bool) -> BackgroundWindowOutcome {
        if didExpire { return .expired }
        if case .cannotRun(let reason) = self { return reason }
        return .failed
    }
}

/// The reads of the saved sign-in, for the background windows of this process. A window that cannot get an account
/// ends early. After a refused read it first gives the app a grace to read again and then reads once itself: the
/// refused read can be older than the first unlock, or an unlock can follow it within seconds.
@MainActor
public final class BackgroundAccountReadiness {
    public static let shared = BackgroundAccountReadiness()
    /// How long a window whose last read was refused waits for another read before it reads once more itself. An
    /// unlock makes the app read again.
    public static let unreadableGrace: Duration = .seconds(5)

    public private(set) var lastRead: BackgroundSessionRead = .notYet
    private var reads = 0
    private var reread: (@MainActor () -> Void)?
    private let grace: @Sendable () async -> Void
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// `grace` returns when the wait for another read after a refused one ends; it must also return when its task is
    /// cancelled.
    public init(grace: @escaping @Sendable () async -> Void = BackgroundAccountReadiness.defaultGrace) {
        self.grace = grace
    }

    public static let defaultGrace: @Sendable () async -> Void = {
        try? await Task.sleep(for: BackgroundAccountReadiness.unreadableGrace)
    }

    /// The app's read of the saved sign-in, which records its result here. A window calls it at most once.
    public func installReread(_ reread: @escaping @MainActor () -> Void) {
        self.reread = reread
    }

    /// Records the result of a read of the saved sign-in, or a sign-out.
    public func record(_ read: BackgroundSessionRead) {
        lastRead = read
        reads += 1
        wakeWaiters()
    }

    /// Waits for `reference` until `timeout`. Ends early when no account can come: at once after a read that found no
    /// sign-in, and as locked only after a refused read, a grace of at most `unreadableGrace` for the app's next read
    /// (an unlock makes the app read again), and one read of the window's own that was refused too. A read that finds
    /// the sign-in, and the service, end the wait at once. A read that the app does not make keeps the bounded wait.
    public func wait<Service>(
        for reference: WeakAsyncReference<Service>, timeout: Duration
    ) async -> BackgroundAccountWait<Service> {
        let deadline = ContinuousClock.now + timeout
        let graceTimer = GraceTimer()
        defer { graceTimer.cancel() }
        var readsBeforeOwnRead: Int?
        while true {
            guard !Task.isCancelled else { return .notReady }
            if let service = reference.value { return .ready(service) }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return .notReady }
            switch lastRead {
            case .absent:
                return .cannotRun(.noAccount)
            case .unreadable where readsBeforeOwnRead.map { reads > $0 } == true:
                // The window's own read after the grace was refused too.
                return .cannotRun(.endedAtOnceLocked)
            case .unreadable where readsBeforeOwnRead == nil:
                // A refused read, fresh or old, first gets the grace, then one read of the window's own.
                guard graceTimer.isOver else {
                    graceTimer.start(grace) { [weak self] in self?.wakeWaiters() }
                    await nextChange(of: reference, within: remaining)
                    continue
                }
                readsBeforeOwnRead = reads
                reread?()
            case .unreadable, .notYet, .readable:
                await nextChange(of: reference, within: remaining)
            }
        }
    }

    /// Returns when the service comes, a read is recorded, the grace ends, `remaining` ends, or the task is cancelled.
    private func nextChange<Service>(of reference: WeakAsyncReference<Service>, within remaining: Duration) async {
        let id = UUID()
        let service = Task { @MainActor [weak self] in
            _ = await reference.whenReady(timeout: remaining)
            self?.endWait(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endWait(id) }
        }
        service.cancel()
    }

    private func wakeWaiters() {
        let ended = waiters.values
        waiters.removeAll()
        for waiter in ended { waiter.resume() }
    }

    private func endWait(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// The grace of one window: it starts once and ends once.
@MainActor
private final class GraceTimer {
    private(set) var isOver = false
    private var task: Task<Void, Never>?

    func start(_ grace: @escaping @Sendable () async -> Void, ended: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            await grace()
            guard let self, !Task.isCancelled else { return }
            self.isOver = true
            ended()
        }
    }

    func cancel() {
        task?.cancel()
    }
}
