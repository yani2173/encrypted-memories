import Foundation

#if DEBUG
    package enum SupportLockPath: Sendable, Equatable { case capture, validate }
    package enum SupportLockProbeScope {
        @TaskLocal package static var token: UUID?
    }
#endif

package final class ThumbnailDiagnosticLease: Sendable {}

/// A small, synchronous fence for cache writers that can outlive the operation that started them.
///
/// A destructive clear invalidates the captured token before it removes files. A writer that already
/// owns the fence finishes before the clear proceeds; a writer that arrives afterwards is rejected.
/// The lock covers the write closure, so checking a token and starting a write cannot be separated by
/// an invalidation race.
public final class CacheWriterGeneration: @unchecked Sendable {
    public struct Token: Sendable, Equatable, Hashable {
        fileprivate let value: UInt64
    }

    /// Stable owner lease. Unlike a writer token, this lease survives an ordinary cache clear and changes
    /// only when the configured account/session changes.
    public struct SessionToken: Sendable, Equatable, Hashable {
        fileprivate let value: UInt64
    }

    private let condition = NSCondition()
    private let diagnosticLock = NSLock()
    private var diagnosticLease: ThumbnailDiagnosticLease? = ThumbnailDiagnosticLease()
    #if DEBUG
        private let supportProbeLock = NSLock()
        private var supportProbe: (@Sendable (SupportLockPath, UUID?) -> Void)?

        package func setSupportLockProbeForTesting(_ probe: (@Sendable (SupportLockPath, UUID?) -> Void)?) {
            supportProbeLock.withLock { supportProbe = probe }
        }
    #endif
    private var value: UInt64 = 0
    private var sessionValue: UInt64 = 0
    private var invalidating = false

    public init() {}

    /// Captures the generation a long-lived loader or writer belongs to.
    public func capture() -> Token {
        condition.lock()
        while invalidating {
            condition.wait()
        }
        let token = Token(value: value)
        condition.unlock()
        return token
    }

    /// Captures the account/session lease for a long-lived owner. Ordinary destructive cache clears do not
    /// invalidate this lease; account reconfiguration does.
    public func captureSession() -> SessionToken {
        lockForSupportCapture()
        while invalidating {
            condition.wait()
        }
        let token = SessionToken(value: sessionValue)
        condition.unlock()
        return token
    }

    /// Captures the short-lived writer token and long-lived session lease under one boundary.
    public func captureLeases() -> (writer: Token, session: SessionToken) {
        condition.lock()
        while invalidating {
            condition.wait()
        }
        let leases = (Token(value: value), SessionToken(value: sessionValue))
        condition.unlock()
        return leases
    }

    /// Advances the generation. Call this before deleting the associated cache data.
    @discardableResult
    public func invalidate() -> Token {
        invalidateAndPerform {}.token
    }

    /// Invalidates the current generation and runs destructive maintenance while new captures wait.
    ///
    /// The condition is released while `operation` runs. This keeps normal token capture O(1) and avoids
    /// holding the generation lock across directory deletion or an LRU scan, while still closing the
    /// capture gap between invalidation and the associated crypto/file transition.
    @discardableResult
    public func invalidateAndPerform<T>(
        invalidatesSession: Bool = false,
        _ operation: () -> T
    ) -> (token: Token, sessionToken: SessionToken, result: T) {
        condition.lock()
        while invalidating {
            condition.wait()
        }
        diagnosticLock.withLock { diagnosticLease = nil }
        value &+= 1
        if invalidatesSession { sessionValue &+= 1 }
        invalidating = true
        let token = Token(value: value)
        let sessionToken = SessionToken(value: sessionValue)
        condition.unlock()

        let result = operation()

        condition.lock()
        invalidating = false
        diagnosticLock.withLock { diagnosticLease = ThumbnailDiagnosticLease() }
        condition.broadcast()
        condition.unlock()
        return (token, sessionToken, result)
    }

    /// Runs a short atomic operation in the captured generation. The operation is serialized with the
    /// invalidation boundary, but the generation lock is not held during unrelated maintenance.
    @discardableResult
    public func performIfCurrent<T>(_ token: Token, _ operation: () -> T) -> T? {
        condition.lock()
        guard !invalidating, value == token.value else {
            condition.unlock()
            return nil
        }
        let result = operation()
        condition.unlock()
        return result
    }

    public func isCurrent(_ token: Token) -> Bool {
        condition.lock()
        let current = !invalidating && value == token.value
        condition.unlock()
        return current
    }

    public func isCurrentSession(_ token: SessionToken) -> Bool {
        lockForSupportValidation()
        let current = !invalidating && sessionValue == token.value
        condition.unlock()
        return current
    }

    package func tryCaptureDiagnosticLease() -> ThumbnailDiagnosticLease? {
        guard diagnosticLock.try() else { return nil }
        defer { diagnosticLock.unlock() }
        return diagnosticLease
    }

    package func isCurrentDiagnosticLease(_ lease: ThumbnailDiagnosticLease) -> Bool {
        guard diagnosticLock.try() else { return false }
        defer { diagnosticLock.unlock() }
        return diagnosticLease === lease
    }

    private func lockForSupportCapture() {
        #if DEBUG
            let probe = supportProbeLock.withLock { supportProbe }
            probe?(.capture, SupportLockProbeScope.token)
        #endif
        condition.lock()
    }

    private func lockForSupportValidation() {
        #if DEBUG
            let probe = supportProbeLock.withLock { supportProbe }
            probe?(.validate, SupportLockProbeScope.token)
        #endif
        condition.lock()
    }
}
