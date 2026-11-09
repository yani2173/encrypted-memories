import DesignSystemCore
import Foundation
import MediaCacheUIKitAdapter
import PhotoLibraryBackupAdapter
import Photos
import PhotosCore
import PhotosUI
import SwiftUI
import UIKit
import UploadCore
import UploadFeature

/// Backup settings for iOS and iPadOS. The shared `PhotoLibraryBackupController` owns every state and
/// action; this screen is layout only.
struct MobileBackupScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    let controller: PhotoLibraryBackupController
    let uploadCoordinator: UploadCoordinator?

    var body: some View {
        let excludedCount = libraryModel.excludedPendingTiles.count
        List {
            MobilePhotoBackupSections(controller: controller, excludedCount: excludedCount)
            if let uploadCoordinator {
                MobileManualUploadCheckSection(
                    status: BackupStatus(manualUploadCheck: uploadCoordinator.preparationStatus)
                )
            }
        }
        .mobileNavigationTitle(String(localized: "settings.section_backup"))
    }
}

/// The photos excluded from the backup, one level below the Backup settings.
private struct MobileExcludedPhotosScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel

    var body: some View {
        PendingExcludedPhotosList(
            tiles: libraryModel.excludedPendingTiles,
            thumbnail: PhotoKitLocalThumbnailLoader(request: PhotoKitPlatformImages.request).listThumbnail(for:)
        ) { tile in
            // The pending grid answers with a cancellation error when it refuses the photo, so any thrown
            // error means the photo did not go back into the backup.
            (try? await libraryModel.restoreItems([tile.item])) != nil
        }
        .mobileNavigationTitle(L10n.string("backup.excluded_title"))
    }
}

/// The Backup entry of the settings list. Its value uses the same stabilized status as the backup
/// screen, so a short scan does not make the value flicker.
struct MobileBackupSettingsLabel: View {
    let controller: PhotoLibraryBackupController
    @State private var rowModel = BackupStatusRowModel()

    var body: some View {
        let summary = BackupSettingsSummary(
            isAvailable: controller.isAvailable,
            isEnabled: controller.isEnabled,
            isUserPaused: controller.isUserPaused,
            display: rowModel.displayed
        )
        LabeledContent {
            Text(summary.localizedValue)
                .foregroundStyle(summary.needsAttention ? .orange : ProtonColor.textWeak)
        } label: {
            Label(String(localized: "settings.section_backup"), systemImage: "icloud.and.arrow.up")
        }
        .accessibilityIdentifier("backup.settings")
        .onAppear { rowModel.ingest(controller.status) }
        .onChange(of: controller.status) { _, status in rowModel.ingest(status) }
        .onDisappear { rowModel.cancel() }
    }
}

/// Status of the duplicate check that runs before manual uploads. The section appears only while the
/// check runs or has results.
private struct MobileManualUploadCheckSection: View {
    let status: BackupStatus

    var body: some View {
        let total = status.totalConsidered ?? 0
        if status.isActive || total > 0 || status.needsAttentionCount > 0 {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: status.isActive ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                        .foregroundStyle(status.isActive ? ProtonColor.primary : ProtonColor.textWeak)
                        .frame(width: 18)
                        .spinsWhileActive(status.isActive)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(status.localizedTitle)
                                .foregroundStyle(ProtonColor.textNorm)
                            Spacer()
                            if total > 0 {
                                Text(L10n.string("settings.upload_check_progress \(status.checked) \(total)"))
                                    .font(.footnote)
                                    .foregroundStyle(ProtonColor.textWeak)
                                    .monospacedDigit()
                            }
                        }
                        if total > 0 {
                            if let fraction = status.fractionCompleted {
                                ActivityProgressBar(fraction: fraction, accessibilityLabel: status.localizedTitle)
                            } else {
                                ProgressSpinner()
                            }
                            details
                        } else if status.needsAttentionCount > 0 {
                            details
                        }
                    }
                }
            } header: {
                Text(L10n.string("settings.backup_uploads_section"))
            } footer: {
                Text(L10n.string("settings.upload_check_idle_help"))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.alreadyBackedUp > 0 {
                Text(L10n.string("settings.upload_check_duplicates \(status.alreadyBackedUp)"))
            }
            if status.needsAttentionCount > 0 {
                Text(L10n.string("settings.upload_check_attention \(status.needsAttentionCount)"))
            }
        }
        .font(.footnote)
        .foregroundStyle(ProtonColor.textWeak)
        .monospacedDigit()
    }
}

// MARK: - Photos library backup (shared cross-platform controller, native mobile presentation)

/// Enable/permission/progress sections for Photos-library backup. All state, counts, and wording come
/// from the shared `PhotoLibraryBackupController` + `BackupStatus`; this view is layout only.
private struct MobilePhotoBackupSections: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MobileSceneContext.self) private var sceneContext
    @AppStorage(AppSettingsKey.keepDisplayAwakeDuringForegroundBackup)
    private var keepDisplayAwake = AppSettingsDefault.keepDisplayAwakeDuringForegroundBackup
    @State var controller: PhotoLibraryBackupController
    let excludedCount: Int
    @State private var rowModel = BackupStatusRowModel()
    @State private var showFailedList = false
    @State private var confirmsDisable = false

    var body: some View {
        if !controller.isAvailable {
            Section {
                Text(String(localized: "settings.photos_backup_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
            }
        } else if !controller.isEnabled {
            Section {
                if controller.accessState == .denied || controller.accessState == .restricted {
                    Text(String(localized: "settings.photos_backup_denied_ios"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button(String(localized: "settings.photos_backup_open_settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    Button(L10n.string("settings.photos_backup_enable")) {
                        Task {
                            await PhotoBackupBackgroundCoordinator.shared.enableBackup(controller: controller)
                        }
                    }
                    .foregroundStyle(ProtonColor.primary)
                }
            } footer: {
                Text(L10n.string("settings.photos_backup_explainer"))
            }
        } else {
            Section {
                statusRow
                    // The row contains several independent actions. Borderless buttons keep the row style
                    // from forwarding one tap to every action.
                    .buttonStyle(.borderless)

                if let message = controller.lastMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.accessState == .limited {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("settings.photos_backup_limited"))
                            .font(.footnote)
                            .foregroundStyle(ProtonColor.textWeak)
                        Button(String(localized: "settings.photos_backup_manage_selection")) {
                            presentLimitedLibraryPicker()
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text(String(localized: "settings.photos_backup_background_note"))
            }
        }

        if controller.isEnabled {
            Section {
                NavigationLink {
                    MobileExcludedPhotosScreen()
                } label: {
                    PendingExcludedPhotosEntryLabel(count: excludedCount)
                }
                .accessibilityIdentifier("backup.excludedPhotos")
            } footer: {
                Text(L10n.string("settings.backup_excluded_footer"))
            }
        }

        if controller.isAvailable && controller.isEnabled {
            BackupMobileDataSection(onChange: { controller.mobileDataSettingDidChange() })

            Section {
                NavigationLink {
                    MobileBackupQueueScreen(controller: controller)
                } label: {
                    Label(L10n.string("backup.queue_title"), systemImage: "list.bullet")
                }
                .accessibilityIdentifier("backup.queue")
            }

            Section {
                Toggle(isOn: $keepDisplayAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.photos_backup_keep_display_awake"))
                        Text(L10n.string("settings.photos_backup_keep_display_awake_detail"))
                            .font(.caption)
                            .foregroundStyle(ProtonColor.textWeak)
                    }
                }
                .onChange(of: keepDisplayAwake) { _, _ in
                    PhotoBackupBackgroundCoordinator.shared.displayPreferenceDidChange()
                }
            }

            Section {
                Button(L10n.string("settings.photos_backup_disable"), role: .destructive) {
                    confirmsDisable = true
                }
                .accessibilityIdentifier("backup.disable")
                .confirmationDialog(
                    L10n.string("settings.photos_backup_disable_confirm_title"),
                    isPresented: $confirmsDisable,
                    titleVisibility: .visible
                ) {
                    Button(L10n.string("settings.photos_backup_disable"), role: .destructive) {
                        PhotoBackupBackgroundCoordinator.shared.backupStopped()
                        controller.disableBackup()
                    }
                    .accessibilityIdentifier("backup.disable.confirm")
                    Button(L10n.string("action.cancel"), role: .cancel) {}
                        .accessibilityIdentifier("backup.disable.cancel")
                } message: {
                    Text(L10n.string("settings.photos_backup_disable_confirm_message"))
                }
            }
        }
    }

    /// Keeps the headline and detail slots stable while text changes. `BackupStatusPresentation` supplies
    /// localized wording and counts for every platform.
    @ViewBuilder private var statusRow: some View {
        let display = rowModel.displayed

        // Icon, headline, and action share the headline's first line; details stay below.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BackupStatusIcon(display.accessory)
                .frame(width: 20, height: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(display.localizedHeadline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ProtonColor.textNorm)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: display.headlineKey)

                statusDetails(display)

                if let reason = display.localizedWaitingForWiFiDetail {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(ProtonColor.textWeak)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let preparation = controller.scanIndexPreparation {
                    MobileBackupIndexProgress(preparation: preparation)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let retry = display.localizedRetryDetail {
                    Text(retry)
                        .font(.caption)
                        .foregroundStyle(ProtonColor.textWeak)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let systemIssue = display.localizedSystemIssue {
                    Text(systemIssue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let dedupeWarning = display.localizedDedupeWarning {
                    Text(dedupeWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let attention = display.localizedAttention {
                    // Tappable: opens a plain-language list of exactly which files failed and why.
                    Button {
                        showFailedList = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(attention)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("backup.failedItems")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let waiting = display.localizedWaitingDetail {
                    Button {
                        showFailedList = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(waiting)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(ProtonColor.textWeak)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("backup.waitingItems")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if controller.isUserPaused {
                    Button(L10n.string("settings.photos_backup_resume")) {
                        Task {
                            await controller.resumeBackup()
                            PhotoBackupBackgroundCoordinator.shared.backupResumed(controller: controller)
                        }
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("backup.resume")
                } else if controller.isSyncing {
                    Button(L10n.string("settings.photos_backup_pause")) {
                        PhotoBackupBackgroundCoordinator.shared.backupPaused()
                        controller.pauseBackup()
                    }
                    .font(.footnote)
                } else {
                    Button(String(localized: "settings.photos_backup_sync_now")) {
                        Task {
                            await controller.retryFailedAndSync()
                        }
                    }
                    .font(.footnote)
                }
                if let skipped = display.localizedRemoteDeletionDetail {
                    InfoButton(title: L10n.string("backup.remote_deletions_info_title"), message: skipped)
                        .accessibilityIdentifier("backup.remoteDeletions")
                        .accessibilityValue(skipped)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: display.detailLayout
        )
        .onAppear { rowModel.ingest(controller.status) }
        .onChange(of: controller.status) { _, status in rowModel.ingest(status) }
        .onDisappear { rowModel.cancel() }
        .sheet(isPresented: $showFailedList) {
            MobileFailedBackupSheet(controller: controller)
        }
    }

    /// Scanning and terminal states stay compact. A known-total active pass expands once, then
    /// reserves its internal subtitle/transfer/bar slots so per-file updates cannot pump the row.
    @ViewBuilder private func statusDetails(_ display: BackupStatusPresentation) -> some View {
        if display.detailLayout == .progress {
            VStack(alignment: .leading, spacing: 3) {
                subtitleSlot(display, reservesSpace: true)
                transferSlot(display, reservesSpace: true)
                leftSlot(display)
                progressSlot(display)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                subtitleSlot(display, reservesSpace: false)
                transferSlot(display, reservesSpace: false)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder private func subtitleSlot(
        _ display: BackupStatusPresentation,
        reservesSpace: Bool
    ) -> some View {
        if reservesSpace {
            let subtitle = display.localizedSubtitle
            Text(verbatim: subtitle ?? "\u{00a0}")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(subtitle == nil ? 0 : 1)
                .accessibilityHidden(subtitle == nil)
        } else if let subtitle = display.localizedSubtitle {
            Text(subtitle)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func transferSlot(
        _ display: BackupStatusPresentation,
        reservesSpace: Bool
    ) -> some View {
        if reservesSpace {
            let transfer = display.localizedTransferDetail
            Text(verbatim: transfer ?? "\u{00a0}")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.primary)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(transfer == nil ? 0 : 1)
                .accessibilityHidden(transfer == nil)
        } else if let transfer = display.localizedTransferDetail {
            Text(transfer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.primary)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Items left and upload speed. The slot is always present in the progress layout, so a changing speed or a
    /// vanishing count cannot move the bar.
    @ViewBuilder private func leftSlot(_ display: BackupStatusPresentation) -> some View {
        let left = display.localizedLeftLine
        Text(verbatim: left ?? "\u{00a0}")
            .font(.caption.monospacedDigit())
            .foregroundStyle(ProtonColor.textWeak)
            .contentTransition(.numericText())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(display.localizedLeftAccessibilityLabel ?? "")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityHidden(left == nil)
            .accessibilityIdentifier("backup.left")
    }

    /// Determinate bar matching the percentage directly above it while bytes move; otherwise it shows
    /// queue-wide completion. An empty reserved slot keeps the row stable. Scanning stays barless.
    @ViewBuilder private func progressSlot(_ display: BackupStatusPresentation) -> some View {
        if let fraction = display.progressBarFraction, display.isActive || display.accessory == .paused {
            ActivityProgressBar(fraction: fraction, accessibilityLabel: display.localizedProgressBarLabel)
                .frame(height: 4)
        } else {
            Color.clear.frame(height: 4)
        }
    }

    /// The system's limited-library selection UI (iOS/iPadOS only - the picker is UIKit-hosted,
    /// which is exactly why this call lives in the app layer, not the shared adapter).
    private func presentLimitedLibraryPicker() {
        guard let presenter = sceneContext.topmostPresenter else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }
}

/// Progress of the Proton index that a first backup builds before it can tell which photos still need an upload.
private struct MobileBackupIndexProgress: View {
    let preparation: UploadRemoteIndexPreparationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preparation.localizedDetail)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
            if let fraction = preparation.fractionCompleted {
                ProgressView(value: fraction)
                    .tint(ProtonColor.primary)
            }
            Text(L10n.string("backup.detail_preparing_index_once"))
                .font(.caption)
                .foregroundStyle(ProtonColor.textWeak)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("backup.indexProgress")
    }
}

/// The files that the backup uploads now and the ones that wait their turn, each with a preview of its photo.
/// Photos with a problem stay in the problem sheet; the shared `BackupQueueList` decides which rows belong here.
private struct MobileBackupQueueScreen: View {
    let controller: PhotoLibraryBackupController
    @State private var list: BackupQueueList?
    private let thumbnails = PhotoKitLocalThumbnailLoader(request: PhotoKitPlatformImages.request)

    var body: some View {
        Group {
            if let list {
                if list.isEmpty, controller.status.phase == .scanning {
                    // A first scan writes no queue row until the Proton index is ready; the list is not done.
                    ContentUnavailableView {
                        Label(L10n.string("backup.phase_scanning"), systemImage: "magnifyingglass")
                    } description: {
                        if let preparation = controller.scanIndexPreparation {
                            MobileBackupIndexProgress(preparation: preparation)
                                .frame(maxWidth: 320)
                        }
                    }
                    .accessibilityIdentifier("backup.queueScanning")
                } else if list.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("backup.queue_empty"), systemImage: "checkmark.shield")
                    }
                } else {
                    List {
                        section(.uploading, items: list.uploading, hiddenCount: 0)
                        section(.waiting, items: list.waiting, hiddenCount: list.hiddenWaitingCount)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .mobileNavigationTitle(L10n.string("backup.queue_title"))
        // A new pass restarts the reads; without a pass, the queue changes only through the person's actions.
        .task(id: controller.isSyncing) {
            await controller.followQueueList { list = $0 }
        }
    }

    @ViewBuilder private func section(
        _ phase: BackupQueueList.Phase, items: [BackupQueueList.Item], hiddenCount: Int
    ) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        PendingPhotoThumbnail(uid: item.previewUID, load: thumbnails.listThumbnail(for:))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: phase == .uploading ? "arrow.up.circle.fill" : "clock.fill")
                                    .foregroundStyle(phase == .uploading ? ProtonColor.primary : ProtonColor.textWeak)
                                    .font(.caption)
                                    .background(Circle().fill(.background))
                                    .offset(x: 4, y: 4)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.filename)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.localizedState)
                                .font(.caption)
                                .foregroundStyle(ProtonColor.textWeak)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("backup.queueItem.\(item.filename)")
                }
                if hiddenCount > 0 {
                    Text(L10n.string("backup.queue_more \(hiddenCount)"))
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textWeak)
                        .monospacedDigit()
                }
            } header: {
                Text(phase.localizedTitle)
                    .accessibilityIdentifier("backup.queueSection.\(phase.rawValue)")
            }
        }
    }
}

/// Tapping "N nicht gesichert" opens this: a plain-language list of exactly which files failed and
/// why. Deleted-from-device files are marked permanent (retrying can't help and no retry is offered
/// for them); everything else can be retried here and is also auto-retried on the next app launch.
/// An album row opens the same sheet with its last-run photos and restores a trashed copy through the shared
/// controller. Sync now on the album row retries the album.
struct MobileFailedBackupSheet: View {
    enum Source {
        case backup(PhotoLibraryBackupController)
        case album(AlbumSyncController, albumID: String)
    }

    let source: Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pagedList: BackupProblemListSession
    @State private var sessionSourceID: String
    @State private var previews = Self.makePreviews()
    @State private var deletionItem: BackupFailedItem?
    @State private var personReadTask: Task<Void, Never>?

    init(controller: PhotoLibraryBackupController) {
        source = .backup(controller)
        _pagedList = State(initialValue: controller.makeProblemListSession())
        _sessionSourceID = State(initialValue: "backup-\(ObjectIdentifier(controller))")
    }

    init(albumSync: AlbumSyncController, albumID: String) {
        source = .album(albumSync, albumID: albumID)
        _pagedList = State(initialValue: albumSync.makeProblemListSession(albumID: albumID))
        _sessionSourceID = State(initialValue: "album-\(ObjectIdentifier(albumSync))-\(albumID)")
    }

    private static func makePreviews() -> BackupProblemPreviewModel {
        #if DEBUG
            if MobileUITestLaunch.isRequested {
                return BackupProblemPreviewModel { uid in
                    await MobileSignedInFixture.backupProblemThumbnail(for: uid)
                }
            }
        #endif
        return BackupProblemPreviewModel(
            load: PhotoKitLocalThumbnailLoader.problemListPreviews(
                request: PhotoKitPlatformImages.request
            ).listThumbnail(for:))
    }

    private var controller: PhotoLibraryBackupController? {
        if case .backup(let controller) = source { controller } else { nil }
    }

    private var sourceID: String {
        switch source {
        case .backup(let controller): "backup-\(ObjectIdentifier(controller))"
        case .album(let controller, let albumID): "album-\(ObjectIdentifier(controller))-\(albumID)"
        }
    }

    private var sourceIsSelected: Bool {
        if case .album(let controller, let albumID) = source {
            return controller.selectedAlbumIDs.contains(albumID)
        }
        return true
    }

    private struct FollowKey: Equatable {
        let session: ObjectIdentifier
        let source: String
        let backup: BackupStatus.ProblemListKey?
        let album: UUID?
    }

    private var followKey: FollowKey {
        let albumRevision: UUID?
        if case .album(let controller, _) = source {
            albumRevision = controller.problemListRevision
        } else {
            albumRevision = nil
        }
        return FollowKey(
            session: ObjectIdentifier(pagedList), source: sourceID,
            backup: controller?.status.problemListKey, album: albumRevision)
    }

    private var items: [BackupFailedItem] {
        guard sessionSourceID == sourceID, sourceIsSelected else { return [] }
        return pagedList.rows.map(\.item)
    }

    private var presentation: BackupProblemListModel.Presentation {
        guard sessionSourceID == sourceID else { return .loading }
        guard sourceIsSelected else { return .empty }
        let expectsItems: Bool
        switch source {
        case .backup(let controller): expectsItems = controller.status.needsAttentionCount > 0
        case .album(let controller, let albumID):
            expectsItems = controller.selectedAlbums.first { $0.id == albumID }?.hasNeedsAttention == true
        }
        return pagedList.presentation(expectsItems: expectsItems)
    }

    private func makeSession() -> BackupProblemListSession {
        switch source {
        case .backup(let controller): controller.makeProblemListSession()
        case .album(let controller, let albumID): controller.makeProblemListSession(albumID: albumID)
        }
    }

    private func prepareSession() {
        guard sessionSourceID != sourceID || pagedList.isRetired else { return }
        let previous = pagedList
        pagedList = makeSession()
        sessionSourceID = sourceID
        personReadTask?.cancel()
        Task { await previous.shutdown() }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch presentation {
                case .loading, .unavailable, .empty:
                    BackupProblemListStateView(presentation) {
                        pagedList.requestRefresh()
                    }
                case .list:
                    List {
                        BackupProblemSections(rows: pagedList.rows) { item in
                            BackupProblemRow(item: item, showsFailureDetail: true, previews: previews)
                                .onAppear { pagedList.requestNextPage(near: item) }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if offersDecision(item) { deletionItem = item }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(offersDecision(item) ? .isButton : [])
                                .accessibilityIdentifier("backup.failedItem.\(item.filename)")
                                .contextMenu {
                                    if offersDecision(item) {
                                        deletionActions(for: item, place: "menu")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if offersDecision(item) {
                                        deletionActions(for: item, place: "swipe")
                                    } else if item.isDismissible, let controller {
                                        Button(
                                            item.isPermanent
                                                ? L10n.string("backup.failed_item_dismiss")
                                                : L10n.string("backup.failed_item_ignore")
                                        ) {
                                            controller.dismissFailedItem(item)
                                            pagedList.dismissItem(id: item.id)
                                        }
                                        .tint(ProtonColor.textWeak)
                                        .accessibilityIdentifier(
                                            "backup.dismissFailedItem.swipe.\(item.filename)")
                                    }
                                }
                        }
                    }
                    #if DEBUG
                        .modifier(PagingFixtureDriver(session: pagedList))
                    #endif
                }
            }
            // Inside the stack, so the List insets its last rows above the fixed area instead of under it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BackupProblemActionArea(message: sessionSourceID == sourceID ? pagedList.fixedActionMessage : nil) {
                    if sessionSourceID == sourceID, let controller {
                        BulkPhotoActionControls(
                            runner: controller.bulkPhotoActions, count: pagedList.decisionCount,
                            isAvailable: { controller.isBulkBackUpAgainAvailable },
                            prepare: { await controller.prepareBackUpAgain() },
                            start: { controller.startBackUpAgain($0) }
                        )
                        .id(ObjectIdentifier(controller))
                    } else if sessionSourceID == sourceID, case .album(let albumSync, let albumID) = source {
                        BulkPhotoActionControls(
                            runner: albumSync.bulkPhotoActions, action: .restore, count: pagedList.decisionCount,
                            isAvailable: { albumSync.isBulkRestoreAvailable(albumID: albumID) },
                            ownsActivity: { albumSync.bulkRestoreAlbumID == albumID },
                            prepare: { await albumSync.prepareRestore(albumID: albumID) },
                            start: { albumSync.startRestore($0, albumID: albumID) }
                        )
                        .id(sourceID)
                    }
                }
                // One container frame that starts at the bar background; the inner elements keep their identifiers.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("backup.problemList.actionArea")
            }
            .mobileNavigationTitle(
                controller == nil
                    ? AlbumSyncController.SelectedAlbum.localizedProblemSheetTitle(for: items)
                    : L10n.string("backup.failed_sheet_title")
            )
            .toolbar {
                ProminentToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(L10n.string("backup.failed_sheet_done"), systemImage: "checkmark").textBarItem()
                    }
                }
                .mobileVisibilityPriority(.high)
                if let controller, items.offersUserRetry {
                    ToolbarItem(placement: .confirmationAction) {
                        RetryButton(.system) {
                            Task {
                                await controller.retryUserResolvableWork()
                                dismiss()
                            }
                        }
                        .accessibilityIdentifier("backup.retryUserResolvable.sheet")
                    }
                }
            }
        }
        .confirmationDialog(
            deletionItem?.issue == .remoteDeletion
                ? L10n.string("contextmenu.restore") : L10n.string("backup.issue_deleted_elsewhere"),
            isPresented: Binding(
                get: { deletionItem != nil }, set: { if !$0 { deletionItem = nil } }),
            titleVisibility: .visible
        ) {
            if let deletionItem { deletionActions(for: deletionItem, place: "dialog") }
            Button(L10n.string("action.cancel"), role: .cancel) { deletionItem = nil }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .task(id: followKey) {
            guard sessionSourceID == sourceID, sourceIsSelected else { return }
            switch source {
            case .backup(let controller): await controller.followProblemList(session: pagedList)
            case .album:
                pagedList.requestRefresh()
                await pagedList.waitUntilIdle()
            }
        }
        .onAppear { prepareSession() }
        .onChange(of: sourceID) { _, _ in prepareSession() }
        .backupProblemPreviews(previews)
        .onDisappear {
            personReadTask?.cancel()
            let session = pagedList
            Task { await session.shutdown() }
        }
    }

    #if DEBUG
        /// The smoke test jumps through the same pager instead of synthesizing thousands of scroll gestures.
        private struct PagingFixtureDriver: ViewModifier {
            let session: BackupProblemListSession

            private var isRequested: Bool {
                MobileUITestLaunch.isRequested
                    && ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesProblemListSmoke")
            }

            func body(content: Content) -> some View {
                if isRequested {
                    ScrollViewReader { scroll in
                        content
                            .accessibilityIdentifier("backup.problemList.fixture")
                            .accessibilityValue(Text(verbatim: "loaded=\(session.rows.count);total=\(session.total)"))
                            .task(id: session.total) {
                                await session.waitUntilIdle()
                                while !Task.isCancelled, session.rows.count < session.total {
                                    let previousCount = session.rows.count
                                    session.requestNextPage()
                                    await session.waitUntilIdle()
                                    guard session.rows.count > previousCount else { return }
                                }
                                guard !Task.isCancelled, session.rows.count == session.total else { return }
                                let filename =
                                    session.total == 5_000
                                    ? "Deleted 0250 fixture.heic" : "Deleted 5000 fixture.heic"
                                guard let row = session.rows.first(where: { $0.item.filename == filename }) else {
                                    return
                                }
                                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                                guard !Task.isCancelled else { return }
                                scroll.scrollTo(row.id, anchor: .top)
                            }
                    }
                } else {
                    content
                }
            }
        }
    #endif

    private func offersDecision(_ item: BackupFailedItem) -> Bool {
        switch source {
        case .backup: item.issue == .deletedElsewhere
        case .album: item.issue == .remoteDeletion
        }
    }

    @ViewBuilder
    /// `place` keeps the identifiers of the dialog, swipe, and menu copies of the actions distinct.
    private func deletionActions(for item: BackupFailedItem, place: String) -> some View {
        if let controller {
            Button(L10n.string("backup.keep_deleted")) {
                pagedList.resolveDecision(item) { controller.keepDeleted(item) }
                refreshAfterDecision()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("backup.keepDeleted.\(place)")
            Button(L10n.string("backup.back_up_again")) {
                pagedList.resolveDecision(item) { controller.backUpAgain(item) }
                refreshAfterDecision()
            }
            .accessibilityIdentifier("backup.backUpAgain.\(place)")
        } else if case .album(let albumSync, let albumID) = source {
            Button(L10n.string("contextmenu.restore")) {
                deletionItem = nil
                personReadTask?.cancel()
                personReadTask = Task { await albumSync.restorePhotoFromProblemList(item, albumID: albumID) }
            }
            .disabled(
                (place != "dialog" && !albumSync.canRestorePhotos(albumID: albumID))
                    || albumSync.bulkPhotoActions.isRunning
            )
            .accessibilityIdentifier("albumsync.restore.\(place)")
        }
    }

    private func refreshAfterDecision() {
        deletionItem = nil
    }
}
