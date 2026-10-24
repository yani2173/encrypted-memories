import Foundation

/// Removes all local account data and derived caches during sign-out.
///
/// The purge is idempotent, clears every account root, and is shared by iOS and macOS.
/// Teardown must await completion before another login. Filesystem deletion must stay off the UI executor.
public enum BackupLocalDataPurge {
    private static let pendingKey = "backup.pendingSignOutPurge.v1"
    /// Written by the iOS Settings bundle; consumed only at cold launch, before feature composition.
    public static let resetOnNextLaunchKey = "app.resetOnNextLaunch"

    @discardableResult
    public static func prepareRequestedResetForLaunch(
        defaults: UserDefaults = .standard,
        persistentDomainName: String
    ) -> Bool {
        guard defaults.bool(forKey: resetOnNextLaunchKey) else { return false }
        // Reuse the crash-resumable file + Keychain transaction. Clearing preferences here prevents
        // new feature owners from retaining pre-reset settings while the asynchronous purge runs.
        requestPurgeOnSignOut(defaults: defaults, persistentDomainName: persistentDomainName)
        defaults.set(false, forKey: resetOnNextLaunchKey)
        return true
    }

    public struct Result: Sendable, Equatable {
        public let removedRoots: [URL]
        public let failedRoots: [URL]

        public var succeeded: Bool { failedRoots.isEmpty }
    }

    /// A synchronously claimed sign-out reset. The persisted request remains armed until every
    /// account store has closed and the complete purge succeeds. This prevents a fast re-login from
    /// cancelling an already-started cleanup or recreating a database underneath an async purge.
    public struct Claim: Sendable {
        private let roots: [URL]

        fileprivate init(roots: [URL]) {
            self.roots = roots
        }

        /// The persisted request is cleared only after every owned root is verifiably absent. A failed
        /// deletion therefore survives process termination and is retried before the next account opens.
        @discardableResult
        public func perform(
            defaults: UserDefaults = .standard,
            completesRequestOnSuccess: Bool = true
        ) -> Result {
            perform(
                defaults: defaults,
                completesRequestOnSuccess: completesRequestOnSuccess,
                removeItem: FileManager.default.removeItem(at:)
            )
        }

        func perform(
            defaults: UserDefaults,
            completesRequestOnSuccess: Bool,
            removeItem: (URL) throws -> Void
        ) -> Result {
            let result = BackupLocalDataPurge.purgeAllLocalAccountData(
                roots: roots,
                removeItem: removeItem
            )
            if result.succeeded, completesRequestOnSuccess {
                BackupLocalDataPurge.markPurgeCompleted(defaults: defaults)
            }
            return result
        }
    }

    /// Arms a persisted purge for explicit sign-out.
    /// Do not call it during generic session teardown; transient auth checks must not delete live backup data.
    /// The marker survives a crash and triggers cleanup at the next launch.
    public static func requestPurgeOnSignOut(
        defaults: UserDefaults = .standard,
        persistentDomainName: String? = nil
    ) {
        // Clear the app domain, then restore only the crash-recovery marker.
        if let persistentDomainName {
            defaults.removePersistentDomain(forName: persistentDomainName)
        }
        defaults.set(true, forKey: pendingKey)
    }

    public static func isPurgePending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingKey)
    }

    public static func markPurgeCompleted(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }

    /// Takes ownership of a pending explicit sign-out purge. Platform composition must call this
    /// before beginning asynchronous teardown, then perform the claim only after every account-scoped
    /// store has closed. The durable marker intentionally remains set until successful completion.
    public static func claimSignOutPurge(
        defaults: UserDefaults = .standard,
        roots: [URL]? = nil
    ) -> Claim? {
        guard isPurgePending(defaults: defaults) else { return nil }
        return Claim(roots: roots ?? localDataRoots())
    }

    /// If a sign-out purge is armed, run it now and disarm. Idempotent and safe to call from both the
    /// post-teardown path (stores already closed) and at launch (before any store opens). Returns
    /// whether a purge actually ran.
    @discardableResult
    public static func purgeIfSignOutRequested(defaults: UserDefaults = .standard, roots: [URL]? = nil) -> Bool {
        guard let claim = claimSignOutPurge(defaults: defaults, roots: roots) else { return false }
        return claim.perform(defaults: defaults).succeeded
    }

    /// The on-disk roots that hold account data or caches derived from it. `Application Support` holds
    /// the durable account containers; `Caches` holds regenerable thumbnail/byte caches.
    public static func localDataRoots() -> [URL] {
        let fm = FileManager.default
        var roots = [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
            .map { $0.appendingPathComponent("EncryptedMemories", isDirectory: true) }
        if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            roots.append(library.appendingPathComponent("Logs/EncryptedMemories", isDirectory: true))
        }
        roots.append(fm.temporaryDirectory.appendingPathComponent("ShareExports", isDirectory: true))
        return roots
    }

    /// Removes every local `EncryptedMemories` root. Best-effort per root so one failure never blocks the
    /// rest. Returns the roots removed and any roots that could not be removed.
    @discardableResult
    public static func purgeAllLocalAccountData(roots: [URL]? = nil) -> Result {
        purgeAllLocalAccountData(
            roots: roots,
            removeItem: FileManager.default.removeItem(at:)
        )
    }

    static func purgeAllLocalAccountData(
        roots: [URL]?,
        removeItem: (URL) throws -> Void
    ) -> Result {
        var removed: [URL] = []
        var failed: [URL] = []
        for root in roots ?? localDataRoots() {
            do {
                guard try LocalPurgeItemState.read(at: root) != .missing else { continue }
                try removeItem(root)
                if try LocalPurgeItemState.read(at: root) == .missing {
                    removed.append(root)
                } else {
                    failed.append(root)
                }
            } catch {
                failed.append(root)
            }
        }
        return Result(removedRoots: removed, failedRoots: failed)
    }
}
