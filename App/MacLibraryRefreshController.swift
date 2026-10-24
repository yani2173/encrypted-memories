import Foundation
import Observation
import PhotosCore
import ProtonDriveBackend
import TimelineCore
import TimelineFeature
import UploadCore

/// Owns the Mac library refresh banner and the four refresh routes: after a manual upload, after a background
/// backup upload, on a menu request, and on a remote library change. Refresh and banner policy stay in the shared
/// Timeline types; this controller only sequences the Mac host work and publishes the banner state.
@MainActor
@Observable
final class MacLibraryRefreshController {
    /// The host objects one refresh uses. The view supplies them with every call.
    struct Host {
        let timelineModel: TimelineViewModel
        let model: AppModel
        let loadAlbums: @MainActor () async -> Void
        let scrollToItem: @MainActor (PhotoUID) -> Void
    }

    private var banner = LibraryRefreshBannerState()

    /// A refresh is running. Remote change polling waits while it is set.
    var isBusy: Bool { banner.isBusy }
    /// The tone of the current banner message. Tracked explicitly so the banner never compares localized text.
    var tone: LibraryRefreshBannerMessage.Tone? { banner.message?.tone }
    var message: String? { banner.message.map(Self.text(for:)) }

    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadGeneration: UInt64 = 0
    @ObservationIgnored private let backupRefreshCoordinator = TimelineUploadRefreshCoordinator()

    // MARK: - Routes

    /// Refreshes after a manual upload until the uploaded photo appears. A newer upload replaces the running refresh.
    func scheduleUploadRefresh(_ event: UploadCompletedEvent, host: Host) {
        uploadGeneration &+= 1
        let generation = uploadGeneration
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            await runUploadRefresh(event, generation: generation, host: host)
            guard generation == uploadGeneration else { return }
            uploadTask = nil
        }
    }

    /// Refreshes after background backup uploaded new library items. Repeated signals coalesce in the shared
    /// coordinator.
    func scheduleBackupUploadRefresh(host: Host) {
        banner.beginBackupUploadRefresh()
        Task {
            await backupRefreshCoordinator.request(
                refresh: { attempt in
                    await self.performBackupUploadRefreshAttempt(attempt: attempt, host: host)
                },
                observer: { state in
                    await self.applyBackupUploadRefresh(state)
                }
            )
        }
    }

    /// Runs the menu refresh unless another refresh is already running.
    func refreshManually(host: Host) {
        Task { await performManualRefresh(host: host) }
    }

    /// Runs one refresh for a remote library change. Returns `.retry` while an upload refresh owns the timeline.
    func performRemoteLibraryRefresh(host: Host) async -> LibraryChangeRefreshOutcome {
        // The five-second token-driven comparison is routine synchronization, not user-facing progress. Keep the
        // gate for refresh serialization, but show the shared bottom banner only if the refreshed projection
        // actually schedules thumbnail or GPS work (observed by `backgroundLibraryActivityActive`).
        guard uploadTask == nil, banner.beginRemoteRefresh() else { return .retry }
        let result = await host.timelineModel.refreshLibrary()
        if result.failureReason == .scopeAccessLost {
            banner.finishRemoteRefresh(succeeded: false)
            return .terminal
        }
        OfflineLibraryManager.shared.liveAssetCount = host.timelineModel.allItems.count
        await host.loadAlbums()
        host.model.refreshLibrarySources()
        reconcileNewAssetThumbnails(result.addedUIDs, host: host)
        let succeeded = result.errorMessage == nil
        banner.finishRemoteRefresh(succeeded: succeeded)
        return succeeded ? result.refreshedOutcome : .retry
    }

    /// Stops a coalesced backup refresh when the library view disappears.
    func cancelBackupUploadRefresh() {
        let coordinator = backupRefreshCoordinator
        Task { await coordinator.cancel() }
    }

    /// Adds thumbnails for newly visible library items to the offline originals and thumbnail reconciliation.
    func reconcileNewAssetThumbnails(_ addedUIDs: [PhotoUID], host: Host) {
        OfflineLibraryManager.shared.reconcileNewAssetThumbnails(
            currentUIDs: host.timelineModel.wholeLibraryUIDs,
            addedUIDs: addedUIDs
        )
    }

    // MARK: - Refresh passes

    private func performBackupUploadRefreshAttempt(attempt: Int, host: Host) async -> TimelineRefreshFailureReason? {
        let result = await host.timelineModel.refreshLibrary()
        if await recoverBackendAfterScopeAccessLoss(ifNeeded: result, host: host) { return .cancelled }
        OfflineLibraryManager.shared.liveAssetCount = host.timelineModel.allItems.count
        reconcileNewAssetThumbnails(result.addedUIDs, host: host)
        logUploadRefresh(uploadedNode: "backup", attempt: attempt, result: result)
        return result.failureReason
    }

    private func applyBackupUploadRefresh(_ state: TimelineUploadRefreshAttempt) {
        scheduleDismissal(banner.applyBackupUploadRefresh(state.decision))
    }

    private func runUploadRefresh(_ event: UploadCompletedEvent, generation: UInt64, host: Host) async {
        banner.beginUploadRefresh()
        let schedule = TimelineRefreshRetrySchedule.uploadDefault.delays
        for (attempt, delay) in schedule.enumerated() {
            guard generation == uploadGeneration, !Task.isCancelled else { return }
            if delay > .zero {
                banner.waitForUploadRefresh()
                try? await Task.sleep(for: delay)
            }
            let result = await host.timelineModel.refreshAfterUpload(uploadedUID: event.uploadedUID)
            guard generation == uploadGeneration, !Task.isCancelled else { return }
            if await recoverBackendAfterScopeAccessLoss(ifNeeded: result, host: host) { return }
            OfflineLibraryManager.shared.liveAssetCount = host.timelineModel.allItems.count
            reconcileNewAssetThumbnails(result.addedUIDs, host: host)
            if event.destination.usesAlbum {
                await host.loadAlbums()
            }
            logUploadRefresh(uploadedNode: event.uploadedUID.nodeID, attempt: attempt, result: result)
            if let found = result.foundItem {
                scheduleDismissal(banner.finishUploadRefresh(found: true))
                host.scrollToItem(found.uid)
                return
            }
        }
        scheduleDismissal(banner.finishUploadRefresh(found: false))
    }

    private func performManualRefresh(host: Host) async {
        guard banner.beginManualRefresh() else { return }
        let result = await host.timelineModel.refreshLibrary()
        if await recoverBackendAfterScopeAccessLoss(ifNeeded: result, host: host) { return }
        OfflineLibraryManager.shared.liveAssetCount = host.timelineModel.allItems.count
        await host.loadAlbums()
        reconcileNewAssetThumbnails(result.addedUIDs, host: host)
        logUploadRefresh(uploadedNode: "-", attempt: 0, result: result)
        scheduleDismissal(banner.finishManualRefresh(succeeded: result.errorMessage == nil))
    }

    /// Clears the banner and hands a lost Drive scope to the account model. Returns `true` when recovery ran.
    private func recoverBackendAfterScopeAccessLoss(
        ifNeeded result: TimelineRefreshResult,
        host: Host
    ) async -> Bool {
        guard result.failureReason == .scopeAccessLost else { return false }
        banner.loseScopeAccess()
        await host.model.recoverBackendAfterScopeAccessLoss()
        return true
    }

    private func scheduleDismissal(_ dismissal: LibraryRefreshBannerState.Dismissal?) {
        guard let dismissal else { return }
        Task { @MainActor in
            try? await Task.sleep(for: dismissal.delay)
            banner.dismiss(dismissal)
        }
    }

    private static func text(for message: LibraryRefreshBannerMessage) -> String {
        switch message {
        case .refreshing: return String(localized: "library.refreshing")
        case .refreshingAfterUpload: return String(localized: "upload.refreshing_after_upload")
        case .waitingForRefresh: return String(localized: "upload.waiting_for_refresh")
        case .refreshed: return String(localized: "library.refreshed")
        case .uploaded: return String(localized: "upload.uploaded")
        case .refreshFailed: return String(localized: "library.refresh_failed")
        case .notYetIndexed: return String(localized: "upload.not_yet_indexed")
        }
    }

    private func logUploadRefresh(uploadedNode: String, attempt: Int, result: TimelineRefreshResult) {
        let line = """
            [UploadRefresh] uploadedNode=\(uploadedNode) attempt=\(attempt) found=\(result.found) \
            timelineCountBefore=\(result.timelineCountBefore) timelineCountAfter=\(result.timelineCountAfter) \
            filter=\(result.filterDescription) elapsedMs=\(Int(result.elapsedMs)) error=\(result.errorMessage ?? "-")
            """
        DebugLog.log(line)
    }
}
