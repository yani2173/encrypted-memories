import Foundation
import MLSearchCore
import PhotosCore
import Testing

@testable import EncryptedMemoriesMobile
@testable import MLSearchBackgroundAppleAdapter

/// The iOS request call of both background tasks, and how a Smart Search window ends.
@Suite @MainActor struct MobileBackgroundWindowTests {
    @Test func fromIOS27BothBackgroundTasksSubmitWithTheCallOffTheMainThread() throws {
        let iOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        try #require(ProcessInfo.processInfo.isOperatingSystemAtLeast(iOS27))
        #expect(PhotoBackupBackgroundCoordinator.offMainSubmission(earliestBeginDate: nil) != nil)
        #expect(PhotoBackupBackgroundCoordinator.offMainRefreshSubmission(earliestBeginDate: Date()) != nil)
        #expect(AppleSmartSearchBackgroundCoordinator.offMainSubmission(earliestBeginDate: Date()) != nil)
    }

    @Test func bothRequestsKeepTheDateFromTheMomentTheyWerePlanned() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let backup = PhotoBackupBackgroundCoordinator.processingRequest(earliestBeginDate: date)
        #expect(backup.earliestBeginDate == date)
        #expect(backup.requiresNetworkConnectivity)
        #expect(!backup.requiresExternalPower)
        let search = AppleSmartSearchBackgroundCoordinator.processingRequest(earliestBeginDate: date)
        #expect(search.earliestBeginDate == date, "the date counts from schedule(), not from the send")
        #expect(search.requiresExternalPower)
        #expect(!search.requiresNetworkConnectivity)
        let refresh = PhotoBackupBackgroundCoordinator.refreshRequest(earliestBeginDate: date)
        #expect(refresh.identifier == "at.oncloud.encryptedmemories.photo-backup.refresh")
        #expect(refresh.earliestBeginDate == date)
    }

    /// The expiration handler marks the expiry before it cancels. Whatever moment the expiry comes, the read never
    /// sees a cancel without the expiry that caused it.
    @Test func aSmartSearchEndNeverSeesTheCancelOfAnExpiryWithoutTheExpiry() {
        final class Window {
            var didExpire = false
            var isCancelled = false
            var reads = 0
            /// The expiry happens right after the first read, whichever value that read takes.
            func read(_ value: () -> Bool) -> Bool {
                let seen = value()
                reads += 1
                if reads == 1 {
                    didExpire = true
                    isCancelled = true
                }
                return seen
            }
        }
        let window = Window()
        let snapshot = AppleSmartSearchBackgroundCoordinator.endSnapshot(
            isCancelled: { window.read { window.isCancelled } }, didExpire: { window.read { window.didExpire } })
        #expect(window.reads == 2)
        #expect(!(snapshot.wasCancelled && !snapshot.didExpire), "a cancel seen without its expiry reads as failed")
        let end = AppleSmartSearchBackgroundCoordinator.windowEnd(
            result: .complete, didExpire: snapshot.didExpire, wasCancelled: snapshot.wasCancelled)
        #expect(end.outcome != .failed)
    }

    /// A pass that finished uncancelled is not reported as failed only because the window expired while its end waited
    /// for the scheduler; the ledger still records the expiry.
    @Test func aSmartSearchWindowThatExpiresWhileWaitingForTheSchedulerKeepsItsSuccess() {
        let after = AppleSmartSearchBackgroundCoordinator.windowEndAfterWait
        let expired = after((.ran, true), true)
        #expect(expired.outcome == .expired)
        #expect(expired.reportsSuccess == true)
        let failed = after((.failed, false), true)
        #expect(failed.outcome == .failed)
        #expect(failed.reportsSuccess == false)
        let quiet = after((.notNeeded, true), false)
        #expect(quiet.outcome == .notNeeded)
        #expect(quiet.reportsSuccess == true)
    }

    @Test func aSmartSearchWindowWithoutACatchUpFailsAsBeforeUnlessItExpired() {
        let end = AppleSmartSearchBackgroundCoordinator.windowEnd
        let stopped = end(nil, false, false)
        #expect(stopped.outcome == .failed, "a window that arrives after stop() fails")
        #expect(!stopped.reportsSuccess, "the OS hears failure for it, as before")
        #expect(end(nil, true, true).outcome == .expired)
        #expect(!end(nil, true, true).reportsSuccess)
        #expect(end(nil, false, true).outcome == .failed)
    }

    @Test func aSmartSearchCatchUpMapsToItsOutcome() {
        let end = AppleSmartSearchBackgroundCoordinator.windowEnd
        #expect(end(.complete, false, false).outcome == .ran)
        #expect(end(.deferred, false, false).outcome == .notNeeded)
        #expect(end(.cancelled, false, false).outcome == .failed)
        #expect(end(.complete, false, true).outcome == .failed)
        #expect(end(.complete, true, true).outcome == .expired)
        #expect(end(.deferred, true, false).outcome == .expired)
    }

    /// The OS hears what it heard before windows were recorded: success exactly when the catch-up was neither
    /// cancelled nor stopped, also when the window expired in the same moment.
    @Test func aSmartSearchWindowKeepsTheSuccessTheOSHeardBefore() {
        let end = AppleSmartSearchBackgroundCoordinator.windowEnd
        #expect(end(.complete, false, false).reportsSuccess)
        #expect(end(.deferred, false, false).reportsSuccess, "a deferred pass reports success, as before")
        let expiredAfterTheWork = end(.complete, true, false)
        #expect(expiredAfterTheWork.outcome == .expired)
        #expect(expiredAfterTheWork.reportsSuccess, "the expiry came after the work returned uncancelled")
        #expect(!end(.complete, false, true).reportsSuccess)
        #expect(!end(.cancelled, false, false).reportsSuccess)
        #expect(!end(.complete, true, true).reportsSuccess)
    }
}
