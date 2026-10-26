import Foundation

/// How timeline and thumbnail work asks for admission in an iOS background window, in one place. The values suit
/// Proton's crypto v1.5. Crypto v2 and SDK 1.0 (end of 2026) make local crypto much cheaper; retune them here.
public enum LibraryBackgroundWorkTuning {
    /// Below backup (`.automatic`), so every backup item that waits takes the single heavy permit first.
    public static let intent: LibraryWorkIntent = .maintenance
    /// One timeline order pass decrypts the order data of every page it reads.
    public static let orderPassMemoryClass: LibraryWorkMemoryClass = .medium
    /// One crawl batch decodes a few thumbnails.
    public static let crawlBatchMemoryClass: LibraryWorkMemoryClass = .small

    public static var orderPass: LibraryWorkRequest {
        LibraryWorkRequest(workload: .timelineOrderPass, intent: intent, memoryClass: orderPassMemoryClass)
    }

    public static var crawlBatch: LibraryWorkRequest {
        LibraryWorkRequest(workload: .thumbnailCrawl, intent: intent, memoryClass: crawlBatchMemoryClass)
    }
}

/// The coordinator's single heavy permit, held for one quantum of work in an iOS background window. Work in such a
/// window runs only under this permit, so it never runs a heavy step beside another workload, and a waiting backup
/// item takes the permit first. Foreground work does not use it.
public final class LibraryBackgroundWindowPermit: Sendable {
    /// Why the work of a permit must stop.
    public enum Stop: Sendable, Equatable {
        case yielded(LibraryWorkYieldReason)
        /// The app returned to the foreground or was suspended.
        case windowEnded
    }

    public let lease: LibraryWorkLease
    private let runtimeState: LibraryRuntimeState
    private let released: PermitSignal

    private init(lease: LibraryWorkLease, runtimeState: LibraryRuntimeState, released: PermitSignal) {
        self.lease = lease
        self.runtimeState = runtimeState
        self.released = released
    }

    deinit { released.fire() }

    /// Waits for the permit while the app stays in its background window. Nil in the foreground and while suspended,
    /// when the window ends before the coordinator admits the work, and when the caller is cancelled. The wait never
    /// polls: the coordinator admits waiters on its own runtime changes.
    public static func acquire(
        _ request: LibraryWorkRequest, coordinator: LibraryResourceCoordinator, runtimeState: LibraryRuntimeState
    ) async -> LibraryBackgroundWindowPermit? {
        guard runtimeState.snapshot().executionOpportunity == .backgroundPermitted else { return nil }
        let admission = PermitAdmission()
        let released = PermitSignal()
        let holder = Task {
            _ = try? await coordinator.withHeavyPermit(request) { lease in
                // An admission that comes after the wait ended gives the permit back at once.
                guard admission.admit(lease) else { return }
                await released.wait()
            }
            admission.end()
        }
        let window = Task {
            for await snapshot in runtimeState.updates() where snapshot.executionOpportunity != .backgroundPermitted {
                if admission.end() { holder.cancel() }
                return
            }
        }
        let lease = await withTaskCancellationHandler {
            await admission.result()
        } onCancel: {
            if admission.end() { holder.cancel() }
        }
        window.cancel()
        guard let lease else { return nil }
        return LibraryBackgroundWindowPermit(lease: lease, runtimeState: runtimeState, released: released)
    }

    /// Waits until the work must stop: the lease yields, or the app leaves its background window. Nil when the caller
    /// is cancelled.
    public func nextStop() async -> Stop? {
        let lease = self.lease
        let runtimeState = self.runtimeState
        return await withTaskGroup(of: Stop?.self) { group in
            group.addTask { await lease.nextYield().map(Stop.yielded) }
            group.addTask {
                for await snapshot in runtimeState.updates()
                where snapshot.executionOpportunity != .backgroundPermitted {
                    return .windowEnded
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// True when the work must stop now: the lease yields, or the app left its background window. For a loop that
    /// checks at each step instead of waiting.
    public var mustStop: Bool {
        !lease.shouldContinue() || runtimeState.snapshot().executionOpportunity != .backgroundPermitted
    }

    /// Gives the permit back to the coordinator. Repeated calls are harmless.
    public func release() { released.fire() }
}

/// The admission of one wait for the permit: the lease once the coordinator admits it, or nil when the wait ended.
private final class PermitAdmission: @unchecked Sendable {
    private enum State {
        case waiting
        case admitted(LibraryWorkLease)
        case ended
    }

    private let lock = NSLock()
    private var state = State.waiting
    private var waiter: CheckedContinuation<LibraryWorkLease?, Never>?

    /// False when the wait already ended; the caller then gives the permit back.
    func admit(_ lease: LibraryWorkLease) -> Bool {
        let waiter = lock.withLock { () -> CheckedContinuation<LibraryWorkLease?, Never>?? in
            guard case .waiting = state else { return .none }
            state = .admitted(lease)
            defer { self.waiter = nil }
            return .some(self.waiter)
        }
        guard let waiter else { return false }
        waiter?.resume(returning: lease)
        return true
    }

    /// Ends a wait that has no lease yet. True when this call ended it.
    @discardableResult
    func end() -> Bool {
        let waiter = lock.withLock { () -> CheckedContinuation<LibraryWorkLease?, Never>?? in
            guard case .waiting = state else { return .none }
            state = .ended
            defer { self.waiter = nil }
            return .some(self.waiter)
        }
        guard let waiter else { return false }
        waiter?.resume(returning: nil)
        return true
    }

    func result() async -> LibraryWorkLease? {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> LibraryWorkLease?? in
                switch state {
                case .waiting:
                    waiter = continuation
                    return .none
                case .admitted(let lease): return .some(lease)
                case .ended: return .some(nil)
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Fires once; waiters before and after the firing return.
private final class PermitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            fired = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
