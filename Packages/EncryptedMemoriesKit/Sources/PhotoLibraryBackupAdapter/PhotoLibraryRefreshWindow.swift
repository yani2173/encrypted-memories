import Foundation
import PhotosCore

/// One window of the iOS app refresh task: about 30 seconds in which the app only scans the photo library for the
/// backup, so that the next long window starts with a ready queue. It uploads nothing.
@MainActor
public enum PhotoLibraryRefreshWindow {
    /// How long the window waits for the account. The OS gives the whole window up to 30 seconds.
    public static let accountLimit: Duration = .seconds(15)
    /// The earliest start of the next refresh window, counted from the moment its request is planned.
    public static let nextRequestDelay: TimeInterval = 15 * 60

    /// Records the start of a refresh window.
    public static func begin(
        ledger: BackgroundWindowLedger = .shared, complete: @escaping (Bool) -> Void
    ) -> BackgroundWindowCompletion {
        BackgroundWindowCompletion(kind: .libraryRefresh, ledger: ledger, complete: complete)
    }

    /// Runs the window and returns how it ended. `scheduleNext` submits the next refresh request; it runs first. In Low
    /// Power Mode the window does nothing else. Then the account gets `accountLimit`. Backup off or paused ends the window
    /// through `backupStopped` or `backupPaused`, as the long window does. Then the scan runs until it ends or the
    /// window's end stops it. A visit's pass waiting for its first network path does not prevent this scan and stays
    /// waiting; the scan never starts its uploads. A scan that started calls `ensureLongWindowRequest` unless the window
    /// expired, so the next long window uploads what it queued; the short window keeps no timer of its own.
    public static func run(
        scheduleNext: () -> Void,
        isLowPowerModeOn: () -> Bool,
        startAccount: () -> Void,
        waitForController: (Duration) async -> BackgroundAccountWait<PhotoLibraryBackupController>,
        didExpire: () -> Bool,
        backupStopped: () -> Void,
        backupPaused: () -> Void,
        ensureLongWindowRequest: () async -> Void,
        onRunStarted: @escaping @MainActor (String) -> Void
    ) async -> BackgroundWindowOutcome {
        scheduleNext()
        guard !isLowPowerModeOn() else { return .notNeeded }
        let waitStart = ContinuousClock.now
        startAccount()
        let wait = await waitForController(accountLimit)
        BackgroundWorkLog.system.accountWait(.libraryRefresh, wait, waited: .now - waitStart)
        guard case .ready(let controller) = wait else { return wait.outcomeWithoutService(didExpire: didExpire()) }
        guard !didExpire() else { return .expired }
        guard controller.isEnabled else {
            backupStopped()
            return .notNeeded
        }
        guard !controller.isUserPaused else {
            backupPaused()
            return .notNeeded
        }
        // A scan that started may have queued photos, also when it stopped or failed later; the next long window
        // uploads them, so iOS must hold a request for one. An expired window ends at once instead.
        switch await controller.backgroundRefreshScan(onRunStarted: onRunStarted) {
        case .scanned:
            guard !didExpire() else { return .expired }
            await ensureLongWindowRequest()
            return .ran
        case .stopped:
            guard !didExpire() else { return .expired }
            await ensureLongWindowRequest()
            return .failed
        case .failed:
            if !didExpire() { await ensureLongWindowRequest() }
            return .failed
        case .notNeeded, .yielded: return .notNeeded
        case .couldNotStart: return .failed
        }
    }
}
