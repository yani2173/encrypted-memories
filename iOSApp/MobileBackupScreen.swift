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
        List {
            MobilePhotoBackupSections(controller: controller)
            if !libraryModel.excludedPendingTiles.isEmpty {
                PendingExcludedPhotosSection(
                    tiles: libraryModel.excludedPendingTiles,
                    thumbnail: PhotoKitLocalThumbnailLoader(request: PhotoKitPlatformImages.request).listThumbnail(for:)
                ) { tile in
                    try? await libraryModel.restoreItems([tile.item])
                }
            }
            if let uploadCoordinator {
                MobileManualUploadCheckSection(
                    status: BackupStatus(manualUploadCheck: uploadCoordinator.preparationStatus)
                )
            }
        }
        .mobileNavigationTitle(String(localized: "settings.section_backup"))
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
                        .spinsWhileActive(status.isActive, period: 1.7)
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
                                ProgressView(value: fraction)
                                    .tint(ProtonColor.primary)
                            } else {
                                ProgressView()
                                    .tint(ProtonColor.primary)
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
            statusIcon(display)
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

    /// The row's single icon. Only `.activity` spins - there is never a second activity indicator.
    @ViewBuilder private func statusIcon(_ display: BackupStatusPresentation) -> some View {
        switch display.accessory {
        case .activity:
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(ProtonColor.primary)
                .spinsWhileActive(true, period: 1.7)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(ProtonColor.textWeak)
        case .waiting:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(ProtonColor.textWeak)
        case .notice:
            Image(systemName: "info.circle")
                .foregroundStyle(ProtonColor.textWeak)
        case .success:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(ProtonColor.primary)
        case .idle:
            Image(systemName: "checkmark.shield")
                .foregroundStyle(ProtonColor.textWeak)
        }
    }

    /// Determinate bar matching the percentage directly above it while bytes move; otherwise it shows
    /// queue-wide completion. An empty reserved slot keeps the row stable. Scanning stays barless.
    @ViewBuilder private func progressSlot(_ display: BackupStatusPresentation) -> some View {
        if let fraction = display.progressBarFraction, display.isActive || display.accessory == .paused {
            ProgressView(value: fraction)
                .tint(ProtonColor.primary)
                .frame(height: 4)
                .accessibilityLabel(display.localizedProgressBarLabel ?? "")
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

/// The files that the backup uploads now and the ones that wait their turn. Photos with a problem stay in the
/// problem sheet; the shared `BackupQueueList` decides which rows belong here.
private struct MobileBackupQueueScreen: View {
    let controller: PhotoLibraryBackupController
    @State private var list: BackupQueueList?

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
                        Image(systemName: phase == .uploading ? "arrow.up.circle" : "clock")
                            .foregroundStyle(phase == .uploading ? ProtonColor.primary : ProtonColor.textWeak)
                            .font(.body)
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
/// An album row opens the same sheet with its last run's photos. That list is read-only: the row's
/// Sync now is its retry.
struct MobileFailedBackupSheet: View {
    enum Source {
        case backup(PhotoLibraryBackupController)
        case album(AlbumSyncController, albumID: String)
    }

    let source: Source
    @Environment(\.dismiss) private var dismiss
    @State private var backupItems: [BackupFailedItem] = []
    @State private var deletionItem: BackupFailedItem?

    init(controller: PhotoLibraryBackupController) {
        source = .backup(controller)
    }

    init(albumSync: AlbumSyncController, albumID: String) {
        source = .album(albumSync, albumID: albumID)
    }

    private var controller: PhotoLibraryBackupController? {
        if case .backup(let controller) = source { controller } else { nil }
    }

    private var items: [BackupFailedItem] {
        switch source {
        case .backup: backupItems
        case .album(let albumSync, let albumID):
            albumSync.selectedAlbums.first { $0.id == albumID }?.problems ?? []
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("backup.failed_sheet_empty"), systemImage: "checkmark.shield")
                    }
                } else {
                    List {
                        ForEach(BackupIssueSection.allCases) { section in
                            let sectionItems = items.filter { $0.category.section == section }
                            if !sectionItems.isEmpty {
                                Section {
                                    ForEach(sectionItems) { item in
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: item.category.symbolName)
                                                .foregroundStyle(item.isPermanent ? ProtonColor.textWeak : .orange)
                                                .font(.body)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.filename)
                                                    .font(.subheadline)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Text(item.reason)
                                                    .font(.caption)
                                                    .foregroundStyle(ProtonColor.textWeak)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                if let retryDescription = item.retryDescription {
                                                    Text(retryDescription)
                                                        .font(.caption2)
                                                        .foregroundStyle(ProtonColor.textWeak)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 2)
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
                                            } else if item.isPermanent, let controller {
                                                Button(L10n.string("backup.failed_item_dismiss")) {
                                                    controller.dismissFailedItem(item)
                                                    backupItems.removeAll { $0.id == item.id }
                                                }
                                                .tint(ProtonColor.textWeak)
                                                .accessibilityIdentifier(
                                                    "backup.dismissFailedItem.swipe.\(item.filename)")
                                            }
                                        }
                                    }
                                } header: {
                                    Text(section.localizedTitle)
                                        .accessibilityIdentifier("backup.issueSection.\(section.rawValue)")
                                }
                            }
                        }
                    }
                }
            }
            .mobileNavigationTitle(
                controller == nil
                    ? L10n.string("albumsync.problem_sheet_title") : L10n.string("backup.failed_sheet_title")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("backup.failed_sheet_done")) { dismiss() }
                }
                .mobileVisibilityPriority(.high)
                if let controller, items.offersUserRetry {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("backup.failed_sheet_retry")) {
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
            L10n.string("backup.issue_deleted_elsewhere"),
            isPresented: Binding(
                get: { deletionItem != nil }, set: { if !$0 { deletionItem = nil } }),
            titleVisibility: .visible
        ) {
            if let deletionItem { deletionActions(for: deletionItem, place: "dialog") }
            Button(L10n.string("action.cancel"), role: .cancel) { deletionItem = nil }
        }
        .presentationDetents([.medium, .large])
        // A photo can need the person while the list is open; Try again then appears.
        .task(id: controller?.status.problemListKey) {
            guard let controller else { return }
            await controller.followProblemList { backupItems = $0 }
        }
    }

    /// Only the backup list offers the deleted-elsewhere decision; the album list is read-only.
    private func offersDecision(_ item: BackupFailedItem) -> Bool {
        controller != nil && item.issue == .deletedElsewhere
    }

    @ViewBuilder
    /// `place` keeps the identifiers of the dialog, swipe, and menu copies of the actions distinct.
    private func deletionActions(for item: BackupFailedItem, place: String) -> some View {
        if let controller {
            Button(L10n.string("backup.keep_deleted")) {
                controller.keepDeleted(item)
                refreshAfterDecision(item, controller: controller)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("backup.keepDeleted.\(place)")
            Button(L10n.string("backup.back_up_again")) {
                controller.backUpAgain(item)
                refreshAfterDecision(item, controller: controller)
            }
            .accessibilityIdentifier("backup.backUpAgain.\(place)")
        }
    }

    private func refreshAfterDecision(_ item: BackupFailedItem, controller: PhotoLibraryBackupController) {
        deletionItem = nil
        Task {
            backupItems = await controller.problemItems().filter { $0.id != item.id || $0.issue == .deletedElsewhere }
        }
    }
}
