import Foundation

/// Tracks the processing windows that still protect a particular controller's backup run.
@MainActor
public final class BackgroundBackupRunProtection {
    public static let shared = BackgroundBackupRunProtection()

    private struct Hold {
        weak var owner: AnyObject?
        let runID: String
    }

    private var holds: [UUID: Hold] = [:]

    #if DEBUG
        public var onHoldForTesting: (@MainActor (UUID) -> Void)?
        public var onReleaseAttemptForTesting: (@MainActor (UUID) -> Void)?
    #endif

    public init() {}

    /// Each processing window gets its own token, even when two windows hold the same run.
    public func hold(owner: AnyObject, runID: String) -> UUID {
        let token = UUID()
        holds[token] = Hold(owner: owner, runID: runID)
        #if DEBUG
            onHoldForTesting?(token)
        #endif
        return token
    }

    /// A completed, expired or cancelled window releases only its own token. Repeated releases do nothing.
    public func release(_ token: UUID) {
        #if DEBUG
            onReleaseAttemptForTesting?(token)
        #endif
        holds.removeValue(forKey: token)
    }

    public func isProtected(owner: AnyObject, runID: String) -> Bool {
        holds.values.contains { $0.owner === owner && $0.runID == runID }
    }
}
