import AlbumSyncCore
import AppKit
import DesignSystem
import DesignSystemCore
import MLSearchCore
import MapFeature
import MediaCache
import PhotoLibraryBackupAdapter
import PhotosCore
import PrivacyFeature
import ProtonDriveBackend
import SwiftUI
import UploadCore
import UploadFeature

/// Native macOS settings window.
struct SettingsView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled

    let isAccountAvailable: Bool
    let uploadCoordinator: UploadCoordinator?
    let backup: FolderBackupController?
    let photoBackup: PhotoLibraryBackupController?
    let albumSync: AlbumSyncController?
    let smartSearch: MLSmartSearchController?
    /// The account model, for the photos excluded from backup.
    let appModel: AppModel
    let refreshAccountInfo: @MainActor () async -> Void
    let signOut: () -> Void

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 0) {
            MacSettingsTabs(tabs: tabs, selectedTab: $appModel.selectedSettingsTab)
            Divider()
            VStack(spacing: 2) {
                AppBuildInfoLabel()
                Text(ProductBrand.madeInAustria)
                    .font(.caption2)
                    .foregroundStyle(ProtonColor.textHint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .navigationTitle("sidebar.settings")
        .onChange(of: mapAndPlacesEnabled) { _, enabled in
            if !enabled {
                OfflineLibraryManager.shared.pauseMapAndPlaces()
                Task { await NativePlaceNameResolver.shared.cancelPending() }
            }
        }
        // Leave room for all German tab titles in the native toolbar.
        .frame(width: 660, height: 520)
        .task {
            await refreshAccountInfo()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await refreshAccountInfo()
            }
        }
    }

    private var tabs: [MacSettingsTabs.Tab] {
        var tabs: [MacSettingsTabs.Tab] = []
        if isAccountAvailable {
            tabs.append(
                .init(id: .account, title: String(localized: "settings.account_tab"), systemImage: "person.crop.circle")
                {
                    AccountSettingsTab(signOut: {
                        dismissWindow()
                        signOut()
                    })
                })
        }
        tabs.append(
            .init(id: .support, title: L10n.string("settings.support_tab"), systemImage: "heart") {
                SupportSettingsTab()
            })
        if isAccountAvailable {
            tabs.append(
                .init(
                    id: .library, title: String(localized: "settings.library_tab"),
                    systemImage: "photo.on.rectangle.angled"
                ) {
                    LibrarySettingsTab()
                })
            if let smartSearch {
                tabs.append(
                    .init(
                        id: .smartSearch, title: MLSmartSearchPresentation.productName,
                        systemImage: "sparkle.magnifyingglass"
                    ) {
                        SmartSearchSettingsTab(controller: smartSearch)
                    })
            }
            if let backup {
                tabs.append(
                    .init(
                        id: .backup, title: String(localized: "settings.backup_tab"),
                        systemImage: "arrow.triangle.2.circlepath.icloud"
                    ) {
                        BackupSettingsTab(
                            backup: backup, photoBackup: photoBackup, albumSync: albumSync,
                            uploadCoordinator: uploadCoordinator, appModel: appModel
                        )
                    })
            }
            tabs.append(
                .init(id: .privacy, title: L10n.string("settings.privacy_tab"), systemImage: "hand.raised") {
                    Form {
                        PrivacySettingsContent()
                        BugReportSettingsSection()
                    }
                    .formStyle(.grouped)
                })
            tabs.append(
                .init(id: .labs, title: L10n.string("labs.title"), systemImage: "flask") {
                    LabsSettingsTab()
                })
        }
        return tabs
    }
}

// MARK: - Folder backup

private struct BackupSettingsTab: View {
    @AppStorage(AppSettingsKey.folderBackupFullDiskAccessIntroduced)
    private var didIntroduceFullDiskAccess = false
    let backup: FolderBackupController
    let photoBackup: PhotoLibraryBackupController?
    let albumSync: AlbumSyncController?
    let uploadCoordinator: UploadCoordinator?
    let appModel: AppModel

    /// Apple Photos items through PhotoKit, watched-folder files through QuickLook.
    private var excludedThumbnail: @Sendable (PhotoUID) async -> CGImage? {
        let photos = PhotoKitLocalThumbnailLoader(request: PhotoKitPlatformImages.request)
        let files = appModel.backupController.map { PendingFolderMedia(access: $0.pendingAccess) }
        return { uid in
            if uid.localPendingNamespace == .file {
                return await files?.thumbnails(for: [uid], maxPixelSize: 120)[uid]?.image
            }
            return await photos.listThumbnail(for: uid)
        }
    }

    var body: some View {
        Form {
            if let photoBackup {
                Section {
                    PhotoLibraryBackupSection(controller: photoBackup)
                } header: {
                    Text("settings.photos_backup_section")
                }
            }
            if !appModel.excludedPendingTiles.isEmpty {
                PendingExcludedPhotosSection(
                    tiles: appModel.excludedPendingTiles,
                    thumbnail: excludedThumbnail
                ) { tile in
                    await appModel.pendingGrid?.restore([tile.item.uid])
                }
            }
            if let albumSync {
                Section {
                    AlbumSyncSection(controller: albumSync)
                } header: {
                    Text("settings.albumsync_section")
                }
            }
            Section {
                if backup.folders.isEmpty {
                    Text("settings.backup_no_folders")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("settings.backup_full_disk_access_setup")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(backup.folders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayPath)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if folder.needsRenewal {
                                Text("settings.backup_folder_stale")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            backup.removeFolder(folder.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(backup.isSyncing)
                    }
                }
                Button("settings.backup_add_folder") { beginFolderSelection() }
                    .disabled(backup.isSyncing)
                if !backup.folders.isEmpty {
                    Divider()
                    if !backup.isAvailable {
                        Text("settings.backup_unavailable")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        folderSyncStatus
                    }
                }
            } header: {
                Text("settings.backup_folders_section")
            }

            BackupMobileDataSection { photoBackup?.mobileDataSettingDidChange() }

            // Show manual-upload status only while it is actionable or contains results.
            if let uploadCoordinator {
                let manualStatus = BackupStatus(manualUploadCheck: uploadCoordinator.preparationStatus)
                if manualStatus.isActive || (manualStatus.totalConsidered ?? 0) > 0
                    || manualStatus.needsAttentionCount > 0
                {
                    Section {
                        BackupStatusSummaryRow(status: manualStatus)
                    } header: {
                        Text(L10n.string("settings.backup_uploads_section"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Presents the shared backup status for folder sync.
    @ViewBuilder
    private var folderSyncStatus: some View {
        let status = backup.status
        HStack(alignment: .firstTextBaseline) {
            if status.phase == .waitingForWiFi {
                Image(systemName: BackupStatus.waitingForWiFiSymbolName)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.localizedTitle)
                    .font(.system(size: 12, weight: .medium))
                if let detail = status.localizedDetail {
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if backup.isSyncing {
                Button("settings.backup_stop") { backup.stopSync() }
            } else {
                Button("settings.backup_sync_now") { backup.syncNow() }
                    .disabled(backup.folders.isEmpty)
            }
        }
        if status.isActive || status.phase == .paused {
            if let fraction = status.fractionCompleted {
                ActivityProgressBar(fraction: fraction, accessibilityLabel: status.localizedTitle)
            } else {
                ProgressSpinner()  // Totals are unknown during scanning.
            }
            if let name = status.currentItemName {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let total = status.totalConsidered, total > 0 {
            VStack(alignment: .leading, spacing: 3) {
                Text("settings.backup_backed_up \(status.backedUp) \(status.backupTargetCount ?? total)")
                if status.skippedRemoteDeletions > 0 {
                    Text("settings.backup_row_skipped_deleted \(status.skippedRemoteDeletions)")
                }
                if status.sourceMissing > 0 {
                    Text("settings.backup_row_source_missing \(status.sourceMissing)")
                }
                if status.waitingRetry > 0 {
                    Text("settings.backup_row_blocked \(status.waitingRetry)")
                }
                if status.failed > 0 {
                    Text("settings.backup_row_failed \(status.failed)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let message = backup.lastMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func beginFolderSelection() {
        guard !didIntroduceFullDiskAccess else {
            pickFolder()
            return
        }

        didIntroduceFullDiskAccess = true
        let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        guard let settingsURL, NSWorkspace.shared.open(settingsURL) else {
            pickFolder()
            return
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.backup_add_folder_prompt", comment: "folder picker confirm button")
        if panel.runModal() == .OK, let url = panel.url {
            backup.addFolder(url)
        }
    }
}

// MARK: - Account

private struct AccountSettingsTab: View {
    let signOut: () -> Void

    @State private var account = AccountInfo.shared
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                if let used = account.driveUsedSpaceBytes,
                    let max = account.driveMaxSpaceBytes,
                    max > 0
                {
                    let quota = ProtonStorageQuotaFormatter.presentation(
                        usedBytes: used,
                        maximumBytes: max
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("settings.storage_used").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(quota.used) / \(quota.maximum)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ActivityProgressBar(
                            fraction: Double(min(used, max)) / Double(max),
                            accessibilityLabel: String(localized: "settings.storage_used"))
                    }
                } else {
                    Text("settings.storage_unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.storage_section")
            }

            Section {
                Button(L10n.string("action.sign_out"), role: .destructive) { confirmSignOut = true }
                Text("settings.sign_out_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.account_section")
            }
        }
        .formStyle(.grouped)
        .signOutConfirmation(isPresented: $confirmSignOut, onConfirm: signOut)
    }
}

// MARK: - Support

private struct SupportSettingsTab: View {
    var body: some View {
        Form {
            Section {
                TipJarView()
                    .padding(.vertical, 8)
            } header: {
                Text(L10n.string("settings.tip_jar_title"))
            } footer: {
                Text(L10n.string("settings.tip_jar_footer"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Library / Cache

private struct LibrarySettingsTab: View {
    @State private var offline = OfflineLibraryManager.shared
    @AppStorage(AppSettingsKey.offlineOriginalsCapUnlimited) private var capUnlimited = AppSettingsDefault
        .offlineOriginalsCapUnlimited
    @AppStorage(AppSettingsKey.offlineOriginalsCapGB) private var capGB = AppSettingsDefault.offlineOriginalsCapGB
    @State private var confirmDelete = false
    @State private var confirmDisableOffline = false
    @State private var deleting = false
    @State private var cacheSize: Int64 = 0
    @State private var originalsSize: Int64 = 0
    @State private var storagePressure: LibraryStoragePressure = .normal

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { offline.offlineEnabled }, set: { setOffline($0) })) {
                    Text("settings.offline_library_toggle")
                }
                Text("settings.offline_library_help")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.library_offline_section")
            }

            Section {
                Picker("settings.cache_limit_section", selection: $capUnlimited) {
                    Text("settings.cache_limit_bounded").tag(false)
                    Text("settings.cache_limit_unlimited").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: capUnlimited) { _, _ in applyCap() }

                if !capUnlimited {
                    HStack {
                        Slider(value: $capGB, in: 1...50, step: 1) { editing in if !editing { applyCap() } }
                        Text("\(Int(capGB)) GB")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text("settings.cache_limit_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.cache_limit_section")
            }
            .disabled(!offline.offlineEnabled)

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.offline_cache_label").font(.system(size: 12, weight: .medium))
                        Text(L10n.fileSize(cacheSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        if deleting {
                            ProgressSpinner()
                        } else {
                            Text("settings.delete_offline_cache_button")
                        }
                    }
                    .disabled(deleting)
                }
                Text("settings.cache_deletion_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.storage_section")
            } footer: {
                if storagePressure != .normal {
                    Text(L10n.string("settings.storage_pressure"))
                }
            }
        }
        .formStyle(.grouped)
        .observesStoragePressure($storagePressure)
        .task(id: offline.diskCaches) {
            await offline.diskCaches.followDiskChanges { await refreshSize() }
        }
        .alert("alert.delete_offline_cache_title", isPresented: $confirmDelete) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button("action.delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("alert.delete_offline_cache_message \(L10n.fileSize(cacheSize))")
        }
        .alert("settings.disable_offline_title", isPresented: $confirmDisableOffline) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button("settings.disable_offline_confirm", role: .destructive) {
                offline.setOfflineEnabled(false)
                Task {
                    await offline.purgeOriginalsCache()
                    await refreshSize()
                }
            }
        } message: {
            Text("settings.disable_offline_message \(L10n.fileSize(originalsSize))")
        }
    }

    private func setOffline(_ on: Bool) {
        if on {
            offline.setOfflineEnabled(true)
            return
        }
        if originalsSize > 0 {
            confirmDisableOffline = true
        } else {
            offline.setOfflineEnabled(false)
            Task {
                await offline.purgeOriginalsCache()
                await refreshSize()
            }
        }
    }

    private func applyCap() {
        offline.setOriginalsCap(unlimited: capUnlimited, gigabytes: capGB)
        Task { await refreshSize() }
    }

    private func refreshSize() async {
        let status = await OfflineLibraryManager.shared.refreshStatus()
        cacheSize = status.totalCacheSizeBytes
        originalsSize = status.originalsCacheSizeBytes
    }

    private func delete() async {
        deleting = true
        await OfflineLibraryManager.shared.deleteOfflineCache()
        await refreshSize()
        deleting = false
    }
}

/// Renders Photos-library backup consent, permission, and status state.
private struct PhotoLibraryBackupSection: View {
    let controller: PhotoLibraryBackupController
    @State private var rowModel = BackupStatusRowModel()
    @State private var showFailedList = false

    var body: some View {
        Group {
            if !controller.isAvailable {
                Text("settings.backup_unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !controller.isEnabled {
                Text(L10n.string("settings.photos_backup_explainer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if controller.accessState == .denied || controller.accessState == .restricted {
                        Text("settings.photos_backup_denied_macos")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(L10n.string("settings.photos_backup_enable")) {
                        Task { await controller.enableBackup() }
                    }
                }
            } else {
                let display = rowModel.displayed
                // Icon, headline, and action share the headline's first line; details stay below.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    statusIcon(display)
                        .frame(width: 18, height: 20, alignment: .center)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.localizedHeadline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ProtonColor.textNorm)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        subtitleSlot(display)
                        transferSlot(display)
                        leftSlot(display)
                        if let reason = display.localizedWaitingForWiFiDetail {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(ProtonColor.textWeak)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if let retry = display.localizedRetryDetail {
                            Text(retry)
                                .font(.caption)
                                .foregroundStyle(ProtonColor.textWeak)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if let systemIssue = display.localizedSystemIssue {
                            Text(systemIssue)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
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
                            Button {
                                showFailedList = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(attention)
                                        .font(.caption)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if let waiting = display.localizedWaitingDetail {
                            Button {
                                showFailedList = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(waiting)
                                        .font(.caption)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                }
                                .foregroundStyle(ProtonColor.textWeak)
                            }
                            .buttonStyle(.plain)
                        }

                        progressSlot(display)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 8) {
                        if controller.isUserPaused {
                            Button(L10n.string("settings.photos_backup_resume")) {
                                Task { await controller.resumeBackup() }
                            }
                        } else if controller.isSyncing {
                            Button(L10n.string("settings.photos_backup_pause")) { controller.pauseBackup() }
                        } else {
                            Button("settings.backup_sync_now") {
                                Task { await controller.retryFailedAndSync() }
                            }
                        }
                        if let skipped = display.localizedRemoteDeletionDetail {
                            InfoButton(title: L10n.string("backup.remote_deletions_info_title"), message: skipped)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                if controller.accessState == .limited {
                    Text(L10n.string("settings.photos_backup_limited"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let message = controller.lastMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(L10n.string("settings.photos_backup_disable")) { controller.disableBackup() }
                        .controlSize(.small)
                }
                .sheet(isPresented: $showFailedList) {
                    MacFailedBackupSheet(controller: controller)
                }
            }
        }
        .onAppear { rowModel.ingest(controller.status) }
        .onChange(of: controller.status) { _, status in rowModel.ingest(status) }
        .onDisappear { rowModel.cancel() }
    }

    /// Active backup status keeps fixed subtitle, transfer, and progress slots so row geometry stays stable.
    @ViewBuilder private func subtitleSlot(_ display: BackupStatusPresentation) -> some View {
        if display.isActive {
            let subtitle = display.localizedSubtitle
            Text(verbatim: subtitle ?? "\u{00a0}")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
                .opacity(subtitle == nil ? 0 : 1)
                .accessibilityHidden(subtitle == nil)
        } else if let subtitle = display.localizedSubtitle {
            Text(subtitle)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder private func transferSlot(_ display: BackupStatusPresentation) -> some View {
        if display.isActive {
            let transfer = display.localizedTransferDetail
            Text(verbatim: transfer ?? "\u{00a0}")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.primary)
                .contentTransition(.numericText())
                .opacity(transfer == nil ? 0 : 1)
                .accessibilityHidden(transfer == nil)
        } else if let transfer = display.localizedTransferDetail {
            Text(transfer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.primary)
                .contentTransition(.numericText())
        }
    }

    /// Items left and upload speed. The progress layout reserves the slot, so a changing speed cannot move the bar.
    @ViewBuilder private func leftSlot(_ display: BackupStatusPresentation) -> some View {
        if display.detailLayout == .progress {
            let left = display.localizedLeftLine
            Text(verbatim: left ?? "\u{00a0}")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
                .accessibilityLabel(display.localizedLeftAccessibilityLabel ?? "")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityHidden(left == nil)
        }
    }

    @ViewBuilder private func progressSlot(_ display: BackupStatusPresentation) -> some View {
        Group {
            if let fraction = display.progressBarFraction,
                display.isActive || display.accessory == .paused
            {
                ActivityProgressBar(fraction: fraction, accessibilityLabel: display.localizedProgressBarLabel)
                    .controlSize(.small)
            } else {
                Color.clear
            }
        }
        .frame(height: 4)
        .padding(.top, 3)
        .accessibilityHidden(display.progressBarFraction == nil)
    }

    /// Match the mobile status vocabulary and its Proton semantic color roles.
    @ViewBuilder private func statusIcon(_ display: BackupStatusPresentation) -> some View {
        switch display.accessory {
        case .activity:
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(ProtonColor.primary)
                .spinsWhileActive(true)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        case .waiting:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        case .waitingForWiFi:
            Image(systemName: BackupStatus.waitingForWiFiSymbolName)
                .foregroundStyle(.secondary)
        case .notice:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        case .success:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(ProtonColor.primary)
        case .idle:
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
        }
    }
}

/// Native macOS presentation over the same shared failed-item and retry contracts as iOS/iPadOS.
/// An album row opens the same sheet with its last run's photos. That list is read-only: the row's
/// Sync now is its retry.
private struct MacFailedBackupSheet: View {
    enum Source {
        case backup(PhotoLibraryBackupController)
        case album(AlbumSyncController, albumID: String)
    }

    let source: Source
    @Environment(\.dismiss) private var dismiss
    @State private var problemList = BackupProblemListModel()
    @State private var personReadTask: Task<Void, Never>?
    @State private var readOrder = BackupProblemListReadOrder()

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
        case .backup: problemList.items
        case .album(let albumSync, let albumID):
            albumSync.selectedAlbums.first { $0.id == albumID }?.problems ?? []
        }
    }

    /// What the sheet shows. The backup list never says that nothing needs attention while the summary counts items.
    private var presentation: BackupProblemListModel.Presentation {
        if let controller {
            return problemList.presentation(expectsItems: controller.status.needsAttentionCount > 0)
        }
        return items.isEmpty ? .empty : .list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    controller == nil
                        ? AlbumSyncController.SelectedAlbum.localizedProblemSheetTitle(for: items)
                        : L10n.string("backup.failed_sheet_title")
                )
                .font(.headline)
                Spacer()
                if let controller, items.offersUserRetry {
                    RetryButton(.system) {
                        Task {
                            await controller.retryUserResolvableWork()
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("backup.retryUserResolvable.sheet")
                }
                Button(L10n.string("backup.failed_sheet_done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            switch presentation {
            case .loading:
                ProgressView(L10n.string("loading.content"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("backup.failedSheet.loading")
            case .unavailable:
                ContentUnavailableView {
                    Label(L10n.string("backup.failed_sheet_unavailable"), systemImage: "exclamationmark.triangle")
                } actions: {
                    Button(L10n.string("action.retry")) {
                        guard let controller else { return }
                        problemList.beginReading()
                        readList(of: controller)
                    }
                    .accessibilityIdentifier("backup.failedSheet.retry")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    L10n.string("backup.failed_sheet_empty"),
                    systemImage: "checkmark.shield"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .list:
                List {
                    BackupProblemSections(items: items) { item in
                        BackupProblemRow(item: item) {
                            if let controller, item.issue == .deletedElsewhere {
                                Button(L10n.string("backup.keep_deleted")) {
                                    controller.keepDeleted(item)
                                    readList(of: controller)
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.string("backup.keep_deleted"))
                                Button(L10n.string("backup.back_up_again")) {
                                    controller.backUpAgain(item)
                                    readList(of: controller, afterDecision: item)
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.string("backup.back_up_again"))
                            } else if let controller, item.isPermanent {
                                Button {
                                    controller.dismissFailedItem(item)
                                    problemList.dismissItem(id: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.string("backup.failed_item_dismiss"))
                            }
                        }
                    }
                }
                if controller != nil {
                    Text(L10n.string("backup.failed_sheet_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(width: 520, height: 380)
        // A photo can need the person while the list is open; Try again then appears.
        .task(id: controller?.status.problemListKey) {
            guard let controller else { return }
            await controller.followProblemList(
                order: readOrder, { problemList.replaceItems($0) }, ifUnavailable: { problemList.markUnavailable() })
        }
        .onDisappear { personReadTask?.cancel() }
    }

    /// A person's action reads the list like the automatic follow does. The sheet keeps the task, so closing the
    /// sheet or a newer action ends it.
    private func readList(of controller: PhotoLibraryBackupController, afterDecision item: BackupFailedItem? = nil) {
        personReadTask?.cancel()
        personReadTask = Task {
            await controller.readProblemList(
                order: readOrder, afterDecision: item, { problemList.replaceItems($0) },
                ifUnavailable: { problemList.markUnavailable() })
        }
    }
}

/// Renders selected local-album mappings from the shared sync controller.
/// Removing a row keeps the Proton album and its mapping.
private struct AlbumSyncSection: View {
    let controller: AlbumSyncController
    @State private var showPicker = false
    @State private var problemListAlbumID: String?

    var body: some View {
        if !controller.isAvailable {
            Text("settings.backup_unavailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            if controller.selectedAlbums.isEmpty {
                Text(L10n.string("settings.albumsync_explainer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(controller.selectedAlbums) { album in
                selectedRow(album)
            }
            if controller.isSyncing {
                syncProgress
            }
            if controller.accessState == .denied || controller.accessState == .restricted {
                Text("settings.photos_backup_denied_macos")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let message = controller.lastMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(controller.lastMessageStyle == .information ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    showPicker = true
                } label: {
                    Label(L10n.string("settings.albumsync_add_albums"), systemImage: "plus")
                }
                Spacer()
                if controller.isSyncing {
                    Button("settings.backup_stop") { controller.stopSync() }
                } else {
                    Button(L10n.string("settings.albumsync_sync_all")) { controller.syncSelected() }
                        .disabled(controller.selectedAlbums.isEmpty)
                }
            }
            .sheet(isPresented: $showPicker) {
                AlbumPickerSheet(controller: controller)
            }
            .sheet(
                isPresented: Binding(
                    get: { problemListAlbumID != nil }, set: { if !$0 { problemListAlbumID = nil } })
            ) {
                if let problemListAlbumID {
                    MacFailedBackupSheet(albumSync: controller, albumID: problemListAlbumID)
                }
            }
            .alert(
                L10n.string("settings.albumsync_conflict_title"),
                isPresented: conflictPresented
            ) {
                if let conflict = controller.pendingConflict, conflict.existing.count == 1,
                    let existing = conflict.existing.first
                {
                    Button(L10n.string("settings.albumsync_use_existing")) {
                        controller.resolveConflict(useExisting: existing.id)
                    }
                }
                Button(L10n.string("action.cancel"), role: .cancel) {
                    controller.resolveConflict(useExisting: nil)
                }
            } message: {
                if let conflict = controller.pendingConflict {
                    if conflict.existing.count > 1 {
                        Text(L10n.string("settings.albumsync_conflict_multiple"))
                    } else {
                        Text(L10n.string("settings.albumsync_conflict_message \(conflict.album.title)"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedRow(_ album: AlbumSyncController.SelectedAlbum) -> some View {
        let isActive = controller.isSyncing && controller.progress.localAlbumID == album.id
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let count = album.assetCount {
                        Text(L10n.string("settings.albumsync_photo_count \(count)"))
                    }
                    if !isActive, album.showsProblemList {
                        // Opens the shared problem list with this album's photos; Sync now is the retry.
                        Button {
                            problemListAlbumID = album.id
                        } label: {
                            HStack(spacing: 2) {
                                Text(album.localizedRowStatusDescription)
                                Image(systemName: "chevron.right").font(.system(size: 9))
                            }
                            .foregroundStyle(rowStateColor(album, isActive: isActive))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("albumsync.notInAlbum.\(album.id)")
                    } else {
                        Text(isActive ? controller.progress.localizedTitle : album.localizedRowStatusDescription)
                            .foregroundStyle(rowStateColor(album, isActive: isActive))
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                ProgressSpinner()
            } else if album.state == .needsDecision {
                Button(L10n.string("settings.albumsync_decide")) { controller.presentConflict(albumID: album.id) }
                    .controlSize(.small)
            }
            Button {
                controller.removeFromSelection(album.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .help(L10n.string("settings.albumsync_remove"))
            .accessibilityLabel(Text(L10n.string("settings.albumsync_remove")))
        }
    }

    private func rowStateColor(_ album: AlbumSyncController.SelectedAlbum, isActive: Bool) -> Color {
        if isActive { return .secondary }
        if album.hasNeedsAttention { return .orange }
        switch album.state {
        case .missingLocally, .needsDecision: return .orange
        case .notSynced, .synced: return .secondary
        }
    }

    private var syncProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail = controller.progress.localizedDetail {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressSpinner()
        }
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: { controller.pendingConflict != nil },
            set: { presented in
                if !presented, controller.pendingConflict != nil {
                    controller.resolveConflict(useExisting: nil)
                }
            }
        )
    }
}

/// The album picker. Confirmation replaces the full selection.
/// Opening the sheet is the explicit user action that may trigger the photo-access prompt.
private struct AlbumPickerSheet: View {
    let controller: AlbumSyncController
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Set<String> = []
    @State private var searchText = ""
    @State private var didLoad = false

    private var filteredAlbums: [LocalAlbumSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return controller.availableAlbums }
        return controller.availableAlbums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("settings.albumsync_picker_title"))
                    .font(.headline)
                TextField(L10n.string("settings.albumsync_picker_search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()

            Divider()

            if controller.isLoadingAlbums && !didLoad {
                Spacer()
                ProgressView()
                Spacer()
            } else if controller.accessState == .denied || controller.accessState == .restricted {
                Spacer()
                Text("settings.photos_backup_denied_macos")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
                Spacer()
            } else if filteredAlbums.isEmpty {
                Spacer()
                Text(L10n.string("settings.albumsync_picker_empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(filteredAlbums) { album in
                    Toggle(isOn: draftBinding(album.id)) {
                        HStack {
                            Text(album.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(L10n.string("settings.albumsync_photo_count \(album.assetCount)"))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text(L10n.string("settings.albumsync_picker_selected \(draft.count)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("action.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("settings.albumsync_picker_apply")) {
                    controller.applySelection(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
        .task {
            await controller.loadAvailableAlbums()
            if !didLoad {
                draft = controller.selectedAlbumIDs
                didLoad = true
            }
        }
    }

    private func draftBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.contains(id) },
            set: { checked in
                if checked { draft.insert(id) } else { draft.remove(id) }
            }
        )
    }
}

/// Compact status row over the shared Core `BackupStatus` model (used for the manual upload
/// queue's pre-upload check). Idle is explanatory text only; a standalone "Ready" row is not
/// useful for this section.
private struct BackupStatusSummaryRow: View {
    let status: BackupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsStatusHeader {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text(status.localizedTitle)
                    } icon: {
                        Image(systemName: status.isActive ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                            .spinsWhileActive(status.isActive)
                    }
                    .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if total > 0 {
                        Text(L10n.string("settings.upload_check_progress \(status.checked) \(total)"))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let total = status.totalConsidered, total > 0 {
                if let fraction = status.fractionCompleted {
                    ActivityProgressBar(fraction: fraction, accessibilityLabel: status.localizedTitle)
                } else {
                    ProgressSpinner()
                }
                VStack(alignment: .leading, spacing: 2) {
                    if status.alreadyBackedUp > 0 {
                        Text(L10n.string("settings.upload_check_duplicates \(status.alreadyBackedUp)"))
                    }
                    if status.needsAttentionCount > 0 {
                        Text(L10n.string("settings.upload_check_attention \(status.needsAttentionCount)"))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                Text(L10n.string("settings.upload_check_idle_help"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var total: Int {
        status.totalConsidered ?? 0
    }

    private var showsStatusHeader: Bool {
        status.isActive || total > 0 || status.needsAttentionCount > 0
    }
}

// MARK: - Labs

private struct LabsSettingsTab: View {
    var body: some View {
        Form {
            LabsSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Report a problem

/// The entry to the support report, at the bottom of the Privacy tab.
private struct BugReportSettingsSection: View {
    @State private var showsBugReport = false

    var body: some View {
        Section {
            Button {
                showsBugReport = true
            } label: {
                Label(L10n.string("settings.bug_report_action"), systemImage: "ladybug")
            }
            .sheet(isPresented: $showsBugReport) {
                MacBugReportSheet()
            }
        } footer: {
            Text(L10n.string("settings.bug_report_privacy"))
        }
    }
}

private struct MacBugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isPreparingReport = false
    @State private var errorMessage: String?

    private static let issueURL = URL(
        string: "https://github.com/OnCloud-at/encrypted-memories/issues"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("settings.bug_report_title"))
                .font(.title2.bold())

            Text(L10n.string("settings.bug_report_instructions"))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("settings.bug_report_privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(L10n.string("action.done"), role: .cancel) { dismiss() }
                Spacer()
                Button {
                    Task { await exportSupportReport() }
                } label: {
                    if isPreparingReport {
                        ProgressSpinner()
                    } else {
                        Text(L10n.string("settings.bug_report_download"))
                    }
                }
                .disabled(isPreparingReport)
                Button(L10n.string("settings.bug_report_support")) {
                    if !NSWorkspace.shared.open(Self.issueURL) {
                        errorMessage = L10n.string("settings.bug_report_support_failed")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @MainActor private func exportSupportReport() async {
        guard !isPreparingReport else { return }
        isPreparingReport = true
        errorMessage = nil
        defer { isPreparingReport = false }
        do {
            let data = try await SupportDiagnosticsExporter.makeJSONData()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Encrypted-Memories-Support.json"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            try OriginalExportWriter.writeData(data, to: url)
        } catch {
            errorMessage = L10n.string("settings.bug_report_export_failed")
        }
    }
}
