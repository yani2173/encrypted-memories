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
    /// An unlock arrived while a cleanup ran; a failed run is repeated once before its result counts.
    private var retryRequested = false
    private var lockedDuringRun = false
    private let claimPurge: () -> BackupLocalDataPurge.Claim?
    private let isPurgePending: () -> Bool
    private let run: @Sendable (BackupLocalDataPurge.Claim?, Bool?) async -> Bool
    /// Whether the device's protected data can be read now. Always true where the app never runs locked (macOS).
    private let isProtectedDataAvailable: @MainActor () -> Bool

    /// `isProtectedDataAvailable` is the platform's answer; iOS passes the application's state.
    public convenience init(isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true }) {
        self.init(
            claimPurge: { BackupLocalDataPurge.claimSignOutPurge() },
            isPurgePending: { BackupLocalDataPurge.isPurgePending() },
            run: { claim, plaintextPurgeSucceeded in
                await ProtonAuthLocalDataPurge.performStartupOffMain(
                    claim: claim, plaintextPurgeSucceeded: plaintextPurgeSucceeded)
            },
            isProtectedDataAvailable: isProtectedDataAvailable)
    }

    init(
        claimPurge: @escaping () -> BackupLocalDataPurge.Claim?,
        isPurgePending: @escaping () -> Bool,
        run: @escaping @Sendable (BackupLocalDataPurge.Claim?, Bool?) async -> Bool,
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true }
    ) {
        self.claimPurge = claimPurge
        self.isPurgePending = isPurgePending
        self.run = run
        self.isProtectedDataAvailable = isProtectedDataAvailable
    }

    /// A cleanup runs now.
    public var isRunning: Bool { task != nil }

    /// Claims a pending sign-out purge and runs the cold-start cleanup away from the main actor, also on a locked device:
    /// it reads no session. `finished` gets the result on the main actor after it is recorded. Returns false and does
    /// nothing while a cleanup runs.
    @discardableResult
    public func begin(plaintextPurgeSucceeded: Bool? = nil, finished: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard task == nil else { return false }
        let claim = claimPurge()
        succeeded = false
        retryRequested = false
        lockedDuringRun = false
        let run = run
        task = Task { @MainActor [weak self] in
            var startedLocked = self?.isProtectedDataAvailable() == false
            var repeatedAfterUnlock = false
            var succeeded = await run(claim, plaintextPurgeSucceeded)
            // A cleanup that failed while the device was locked can succeed after the unlock that came meanwhile; its
            // failure must not reach the sign-in state first. Each retry request repeats a failed run once, and without
            // any unlock notification, a run that encountered a lock repeats once when protected data is available after it.
            while !succeeded, let self {
                if self.retryRequested {
                    self.retryRequested = false
                } else if startedLocked || self.lockedDuringRun, !repeatedAfterUnlock, self.isProtectedDataAvailable() {
                    repeatedAfterUnlock = true
                } else {
                    break
                }
                startedLocked = !self.isProtectedDataAvailable()
                self.lockedDuringRun = false
                succeeded = await run(self.claimPurge(), plaintextPurgeSucceeded)
            }
            guard let self else { return }
            self.succeeded = succeeded
            self.task = nil
            finished(succeeded)
        }
        return true
    }

    /// Asks a running cleanup to run once more if it fails, for example after the device was unlocked during it.
    /// Does nothing when no cleanup runs.
    public func requestRetryIfRunning() {
        if task != nil { retryRequested = true }
    }

    /// Remembers a lock during this run even if protected data becomes available before its result returns.
    public func noteProtectedDataUnavailable() {
        if task != nil { lockedDuringRun = true }
    }

    /// What the host shows once no cleanup runs. After a successful cleanup the saved session decides, also on a
    /// locked device, where the session is readable after the first unlock. After a failed one the app keeps checking
    /// while protected data cannot be read, so a locked device never looks signed out; then the sign-in failure shows.
    public func startupState(signInFailed: String, bootstrap: () -> ProtonAuthState) -> ProtonAuthState {
        guard succeeded else { return isProtectedDataAvailable() ? .signedOut(error: signInFailed) : .checking }
        return bootstrap()
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
