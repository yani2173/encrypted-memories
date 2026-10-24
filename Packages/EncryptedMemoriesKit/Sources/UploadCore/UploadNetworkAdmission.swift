import Foundation

/// Keeps uploads that must avoid expensive networks apart from uploads that may use them.
///
/// The SDK sends the requests of every upload through one HTTP client, which lets an upload request use an expensive
/// network while any running upload may use one. So the two kinds never run at the same time, also on Wi-Fi, where
/// the device can switch to cellular data during a transfer. Uploads of one kind run side by side.
///
/// An upload that may use expensive networks, for example one that the person started, waits until the running
/// uploads of the other kind end; it never stops them. While it waits, no new upload of the other kind starts, so a
/// backup cannot keep the person waiting without end. A backup can wait as long as the person keeps starting uploads.
public final class UploadNetworkAdmission: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let mayUseExpensiveNetwork: Bool
        let continuation: CheckedContinuation<UploadNetworkReservation, any Error>
    }

    private let lock = NSLock()
    private var runningAvoiding = 0
    private var runningMayUse = 0
    private var waiters: [Waiter] = []

    public init() {}

    /// Waits until an upload of this kind may start. A cancelled wait throws `CancellationError` at once. Release the
    /// reservation when the upload ends, also when it throws.
    public func reserve(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let started = lock.withLock { () -> Bool? in
                    if Task.isCancelled { return nil }
                    guard canStart(mayUseExpensiveNetwork: allowsExpensiveNetwork) else {
                        waiters.append(
                            Waiter(id: id, mayUseExpensiveNetwork: allowsExpensiveNetwork, continuation: continuation))
                        return false
                    }
                    start(mayUseExpensiveNetwork: allowsExpensiveNetwork)
                    return true
                }
                switch started {
                case nil: continuation.resume(throwing: CancellationError())
                case true?: continuation.resume(returning: reservation(allowsExpensiveNetwork))
                case false?: break
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
            // A waiting upload that may use expensive networks held back the other kind; those may start now.
            if waiter?.mayUseExpensiveNetwork == true { admitWaiters() }
        }
    }

    /// The uploads that wait for their reservation now.
    var waitingCount: Int { lock.withLock { waiters.count } }

    /// True when the reservation came from this admission.
    public func issued(_ reservation: UploadNetworkReservation) -> Bool {
        reservation.admission === self
    }

    fileprivate func release(mayUseExpensiveNetwork: Bool) {
        lock.withLock {
            if mayUseExpensiveNetwork {
                runningMayUse = max(0, runningMayUse - 1)
            } else {
                runningAvoiding = max(0, runningAvoiding - 1)
            }
        }
        admitWaiters()
    }

    private func reservation(_ allowsExpensiveNetwork: Bool) -> UploadNetworkReservation {
        UploadNetworkReservation(admission: self, allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    /// Call with the lock held.
    private func canStart(mayUseExpensiveNetwork: Bool) -> Bool {
        if mayUseExpensiveNetwork { return runningAvoiding == 0 }
        return runningMayUse == 0 && !waiters.contains { $0.mayUseExpensiveNetwork }
    }

    /// Call with the lock held.
    private func start(mayUseExpensiveNetwork: Bool) {
        if mayUseExpensiveNetwork { runningMayUse += 1 } else { runningAvoiding += 1 }
    }

    private func admitWaiters() {
        let admitted = lock.withLock { () -> [Waiter] in
            var admitted: [Waiter] = []
            // Waiters that may use expensive networks first, so they hold back the other kind.
            for preferMayUse in [true, false] {
                var index = 0
                while index < waiters.count {
                    let waiter = waiters[index]
                    if waiter.mayUseExpensiveNetwork == preferMayUse,
                        canStart(mayUseExpensiveNetwork: waiter.mayUseExpensiveNetwork)
                    {
                        waiters.remove(at: index)
                        start(mayUseExpensiveNetwork: waiter.mayUseExpensiveNetwork)
                        admitted.append(waiter)
                    } else {
                        index += 1
                    }
                }
            }
            return admitted
        }
        for waiter in admitted {
            waiter.continuation.resume(returning: reservation(waiter.mayUseExpensiveNetwork))
        }
    }
}

/// One upload's place in `UploadNetworkAdmission`. Hand it to the upload in `PhotoUploadRequest.networkReservation`
/// and release it when the upload ends. A second release does nothing.
public final class UploadNetworkReservation: @unchecked Sendable {
    fileprivate let admission: UploadNetworkAdmission
    public let allowsExpensiveNetwork: Bool
    private let lock = NSLock()
    private var released = false

    fileprivate init(admission: UploadNetworkAdmission, allowsExpensiveNetwork: Bool) {
        self.admission = admission
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
    }

    /// True until the reservation is released.
    public var isActive: Bool { lock.withLock { !released } }

    public func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if first { admission.release(mayUseExpensiveNetwork: allowsExpensiveNetwork) }
    }
}
