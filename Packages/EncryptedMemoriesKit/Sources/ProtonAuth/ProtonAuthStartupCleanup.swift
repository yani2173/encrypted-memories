import Foundation
import PhotosCore

/// The sign-in and startup guard shared by macOS, iOS and iPadOS. No saved session starts and no sign-in begins
/// before a pending sign-out purge and the cold-start cleanup have finished; a failed cleanup keeps sign-in closed
/// until a later cleanup succeeds. The apps keep their own state, presentation and platform checks.
@MainActor
public final class ProtonAuthStartupCleanup {
    /// What a sign-in request may do now.
    public enum SignInAdmission: Equatable, Sendable {
        /// No cleanup runs, the last one succeeded, and no sign-out purge is pending.
        case proceed
        /// A cleanup runs; it decides what follows.
        case waitForCleanup
        /// The last cleanup failed, or a sign-out purge is pending: clean up first, then sign in.
        case cleanUpFirst
    }

    /// True after a cleanup succeeded; false before the first one, while one runs, and after a failed one.
    public private(set) var succeeded = false
    private var task: Task<Void, Never>?
    private let claimPurge: () -> BackupLocalDataPurge.Claim?
    private let isPurgePending: () -> Bool
    private let run: @Sendable (BackupLocalDataPurge.Claim?, Bool?) async -> Bool

    public convenience init() {
        self.init(
            claimPurge: { BackupLocalDataPurge.claimSignOutPurge() },
            isPurgePending: { BackupLocalDataPurge.isPurgePending() },
            run: { claim, plaintextPurgeSucceeded in
                await ProtonAuthLocalDataPurge.performStartupOffMain(
                    claim: claim, plaintextPurgeSucceeded: plaintextPurgeSucceeded)
            })
    }

    init(
        claimPurge: @escaping () -> BackupLocalDataPurge.Claim?,
        isPurgePending: @escaping () -> Bool,
        run: @escaping @Sendable (BackupLocalDataPurge.Claim?, Bool?) async -> Bool
    ) {
        self.claimPurge = claimPurge
        self.isPurgePending = isPurgePending
        self.run = run
    }

    /// A cleanup runs now.
    public var isRunning: Bool { task != nil }

    /// Claims a pending sign-out purge and runs the cold-start cleanup away from the main actor. `finished` gets the
    /// result on the main actor after it is recorded. Returns false and does nothing while a cleanup runs.
    @discardableResult
    public func begin(plaintextPurgeSucceeded: Bool? = nil, finished: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard task == nil else { return false }
        let claim = claimPurge()
        succeeded = false
        let run = run
        task = Task { @MainActor [weak self] in
            let succeeded = await run(claim, plaintextPurgeSucceeded)
            guard let self else { return }
            self.succeeded = succeeded
            self.task = nil
            finished(succeeded)
        }
        return true
    }

    public func admitSignIn() -> SignInAdmission {
        if task != nil { return .waitForCleanup }
        guard succeeded, !isPurgePending() else { return .cleanUpFirst }
        return .proceed
    }

    /// Arms the local-data purge for an explicit sign-out, before the session is torn down, so the cleanup after the
    /// teardown and at the next launch wipes every account container. A transient session re-check never arms it.
    public static func armPurgeForSignOut() {
        BackupLocalDataPurge.requestPurgeOnSignOut(persistentDomainName: Bundle.main.bundleIdentifier)
    }
}
