import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// "Use Cellular Data" off: the backup waits on cellular data and Personal Hotspot, says "Waiting for Wi-Fi", and
/// never looks offline. With the setting on, cellular backup remains available.
final class BackupWaitingForWiFiTests: XCTestCase {
    private let policy = BackupThrottlePolicy(baseConcurrency: 6)

    private func inputs(expensive: Bool, usesMobileData: Bool, available: Bool = true) -> BackupThrottleInputs {
        BackupThrottleInputs(
            isNetworkAvailable: available, isNetworkExpensive: expensive, usesMobileData: usesMobileData)
    }

    private func waitingProgress(running: Bool, waitsForWiFi: Bool) -> BackupSyncProgress {
        var progress = BackupSyncProgress()
        progress.total = 10
        progress.uploaded = 4
        progress.waiting = 6
        progress.isRunning = running
        progress.isPausedByPolicy = true
        progress.isWaitingForWiFi = waitsForWiFi
        return progress
    }

    // MARK: - Policy

    func testPolicyHoldsUploadsOnlyWhenMobileDataIsOffOnAnExpensiveNetwork() {
        XCTAssertEqual(policy.maxConcurrentItems(for: inputs(expensive: true, usesMobileData: false)), 0)
        XCTAssertEqual(
            policy.maxConcurrentItems(for: inputs(expensive: true, usesMobileData: true)), 1,
            "with the setting on, cellular keeps the single-file backup")
        XCTAssertEqual(policy.maxConcurrentItems(for: inputs(expensive: false, usesMobileData: false)), 6)
        XCTAssertEqual(policy.maxConcurrentItems(for: inputs(expensive: false, usesMobileData: true)), 6)
    }

    func testOnlyAnOnlineExpensivePathWithMobileDataOffWaitsForWiFi() {
        XCTAssertTrue(inputs(expensive: true, usesMobileData: false).waitsForWiFi)
        XCTAssertFalse(inputs(expensive: true, usesMobileData: true).waitsForWiFi)
        XCTAssertFalse(inputs(expensive: false, usesMobileData: false).waitsForWiFi)
        XCTAssertFalse(
            inputs(expensive: true, usesMobileData: false, available: false).waitsForWiFi,
            "without a network path the backup is offline, not waiting for Wi-Fi")
        XCTAssertFalse(BackupThrottleInputs.unconstrained.waitsForWiFi)
    }

    func testRuntimeSnapshotMapsTheSharedNetworkSignal() {
        var snapshot = LibraryRuntimeSnapshot()
        snapshot.network = LibraryNetworkState(isReachable: true, isConstrained: false, isExpensive: true)

        let off = BackupThrottleInputs(runtime: snapshot, usesMobileData: false)
        XCTAssertTrue(off.isNetworkAvailable)
        XCTAssertTrue(off.isNetworkExpensive)
        XCTAssertTrue(off.waitsForWiFi)
        XCTAssertFalse(BackupThrottleInputs(runtime: snapshot, usesMobileData: true).waitsForWiFi)
    }

    func testUnknownNetworkWaitsOnlyWhileMobileDataIsOff() {
        let snapshot = LibraryRuntimeSnapshot(network: .undetermined)

        XCTAssertTrue(
            BackupThrottleInputs(runtime: snapshot, usesMobileData: false).waitsForWiFi,
            "before the first network path, the device may be on cellular data")
        let allowed = BackupThrottleInputs(runtime: snapshot, usesMobileData: true)
        XCTAssertFalse(allowed.waitsForWiFi)
        XCTAssertFalse(allowed.isNetworkExpensive, "with the setting on, nothing changes")
    }

    func testSettingIsOffByDefaultAndReadsSavedPreference() throws {
        let suite = "BackupWaitingForWiFiTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(BackupMobileDataPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AppSettingsKey.backupUsesMobileData)
        XCTAssertFalse(BackupMobileDataPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AppSettingsKey.backupUsesMobileData)
        XCTAssertTrue(BackupMobileDataPolicy.isEnabled(defaults: defaults))
    }

    func testUnsetPreferenceWaitsOnCellularAndResumesOnWiFiOrExplicitOptIn() throws {
        let suite = "BackupWaitingForWiFiTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let cellular = inputs(expensive: true, usesMobileData: BackupMobileDataPolicy.isEnabled(defaults: defaults))
        XCTAssertTrue(cellular.waitsForWiFi)
        XCTAssertEqual(policy.maxConcurrentItems(for: cellular), 0)
        let status = BackupStatus(
            progress: waitingProgress(running: false, waitsForWiFi: cellular.waitsForWiFi), isScanning: false)
        XCTAssertEqual(status.phase, .waitingForWiFi)
        let display = BackupStatusPresentation(status)
        XCTAssertEqual(display.localizedHeadline, L10n.string("backup.phase_waiting_wifi"))
        XCTAssertEqual(display.localizedWaitingForWiFiDetail, L10n.string("backup.detail_waiting_wifi"))
        XCTAssertNil(display.localizedRetryDetail)

        let wifi = inputs(expensive: false, usesMobileData: BackupMobileDataPolicy.isEnabled(defaults: defaults))
        XCTAssertTrue(status.endsWiFiWait(for: wifi))
        XCTAssertEqual(policy.maxConcurrentItems(for: wifi), 6)
        defaults.set(true, forKey: AppSettingsKey.backupUsesMobileData)
        let allowed = inputs(expensive: true, usesMobileData: BackupMobileDataPolicy.isEnabled(defaults: defaults))
        XCTAssertTrue(status.endsWiFiWait(for: allowed))
        XCTAssertEqual(policy.maxConcurrentItems(for: allowed), 1)
    }

    // MARK: - Status

    func testStatusSaysWaitingForWiFiWhileMobileDataIsOffOnAnExpensiveNetwork() {
        for running in [true, false] {
            let status = BackupStatus(
                progress: waitingProgress(running: running, waitsForWiFi: true), isScanning: false)
            XCTAssertEqual(status.phase, .waitingForWiFi, "running: \(running)")
            XCTAssertEqual(status.titleKey, "backup.phase_waiting_wifi")
            XCTAssertNotNil(status.localizedDetail)
            XCTAssertFalse(status.isActive)
        }
    }

    func testOtherPolicyPausesKeepTheirExistingPhase() {
        XCTAssertEqual(
            BackupStatus(progress: waitingProgress(running: true, waitsForWiFi: false), isScanning: false).phase,
            .paused)
        XCTAssertEqual(
            BackupStatus(progress: waitingProgress(running: false, waitsForWiFi: false), isScanning: false).phase,
            .waiting)
    }

    func testUserPauseOutranksTheWiFiWait() {
        let status = BackupStatus(
            progress: waitingProgress(running: false, waitsForWiFi: true), isScanning: false, isUserPaused: true)
        XCTAssertEqual(status.phase, .paused)
    }

    func testWiFiWaitStaysVisibleNextToFailedPhotos() {
        var progress = waitingProgress(running: false, waitsForWiFi: true)
        progress.failed = 1
        let status = BackupStatus(progress: progress, isScanning: false)
        XCTAssertEqual(status.phase, .waitingForWiFi)
        XCTAssertEqual(BackupStatusPresentation(status).attentionCount, 1, "the failed photo stays reachable")
    }

    func testWiFiWaitEndsOnWiFiOrWhenTheSettingIsTurnedOn() {
        let waiting = BackupStatus(progress: waitingProgress(running: false, waitsForWiFi: true), isScanning: false)
        XCTAssertFalse(waiting.endsWiFiWait(for: inputs(expensive: true, usesMobileData: false)))
        XCTAssertTrue(waiting.endsWiFiWait(for: inputs(expensive: false, usesMobileData: false)), "Wi-Fi or Ethernet")
        XCTAssertTrue(waiting.endsWiFiWait(for: inputs(expensive: true, usesMobileData: true)), "setting turned on")

        let other = BackupStatus(progress: waitingProgress(running: false, waitsForWiFi: false), isScanning: false)
        XCTAssertFalse(other.endsWiFiWait(for: inputs(expensive: false, usesMobileData: true)))
    }

    func testAnOfflinePathDoesNotEndTheWiFiWait() {
        let waiting = BackupStatus(progress: waitingProgress(running: false, waitsForWiFi: true), isScanning: false)
        for usesMobileData in [false, true] {
            XCTAssertFalse(
                waiting.endsWiFiWait(for: inputs(expensive: false, usesMobileData: usesMobileData, available: false)),
                "A returned path must be reachable before it can end the Wi-Fi wait")
        }
    }

    // MARK: - Shared wording and symbol

    func testPresentationHasItsOwnHeadlineAccessoryAndReason() {
        let display = BackupStatusPresentation(
            BackupStatus(progress: waitingProgress(running: false, waitsForWiFi: true), isScanning: false))
        XCTAssertEqual(display.headlineKey, "backup.phase_waiting_wifi")
        XCTAssertEqual(display.accessory, .waitingForWiFi)
        XCTAssertFalse(display.isActive)
        XCTAssertEqual(display.localizedHeadline, L10n.string("backup.phase_waiting_wifi"))
        XCTAssertNotEqual(display.localizedHeadline, L10n.string("backup.phase_paused"))
        XCTAssertEqual(display.localizedWaitingForWiFiDetail, L10n.string("backup.detail_waiting_wifi"))
        XCTAssertNil(display.localizedRetryDetail, "the backup resumes on Wi-Fi, not at a time")
        XCTAssertEqual(display.localizedSubtitle, L10n.string("backup.progress_backed_up \(4) \(10)"))

        let paused = BackupStatusPresentation(
            BackupStatus(progress: waitingProgress(running: true, waitsForWiFi: false), isScanning: false))
        XCTAssertNil(paused.localizedWaitingForWiFiDetail)
    }

    func testSymbolIsNeverAnOfflineSymbol() {
        let symbol = BackupStatus.waitingForWiFiSymbolName
        XCTAssertFalse(["wifi.slash", "icloud.slash"].contains(symbol))
        XCTAssertEqual(symbol, "antenna.radiowaves.left.and.right.slash")
    }

    func testSettingsSummaryNamesTheWiFiWait() {
        let display = BackupStatusPresentation(
            BackupStatus(progress: waitingProgress(running: false, waitsForWiFi: true), isScanning: false))
        let summary = BackupSettingsSummary(isAvailable: true, isEnabled: true, isUserPaused: false, display: display)
        XCTAssertEqual(summary, .waitingForWiFi)
        XCTAssertEqual(summary.localizedValue, L10n.string("backup.phase_waiting_wifi"))
        XCTAssertFalse(summary.needsAttention)
    }
}
