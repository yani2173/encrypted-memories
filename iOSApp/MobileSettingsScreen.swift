import DesignSystemCore
import Foundation
import MLSearchCore
import MediaByteCache
import PhotoLibraryBackupAdapter
import PhotosCore
import PrivacyFeature
import ProtonDriveBackend
import SwiftUI
import TimelineCore

/// Account, library status, cache and sign-out settings for the mobile app.
struct MobileSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var sessionModel: MobileSessionModel
    /// Settings reads lightweight state from the `@Observable` model, so a large timeline snapshot does not
    /// invalidate this screen.
    @Environment(MobileLibraryModel.self) private var libraryModel
    /// Shared Proton account info populated by the backend's account-data cache.
    @State private var account = AccountInfo.shared

    @State private var cacheSize: Int64 = 0
    @State private var storagePressure: LibraryStoragePressure = .normal
    @State private var isClearingCache = false
    @State private var confirmSignOut = false
    @State private var confirmClearCache = false
    @State private var showsBugReport = false
    let showsDismissButton: Bool

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                tipJarSection
                featuresSection
                privacySection
                labsSection
                cacheSection
                supportSection
                signOutSection
                brandFooter
            }
            .mobileNavigationTitle(String(localized: "tab.settings"))
            .observesStoragePressure($storagePressure)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("action.done")) { dismiss() }
                    }
                    .mobileVisibilityPriority(.high)
                }
            }
            .task(id: CacheSizeObservation(scenePhase: scenePhase, caches: libraryModel.diskCaches)) {
                guard scenePhase == .active else { return }
                await libraryModel.diskCaches.followDiskChanges { await refreshCacheSize() }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await libraryModel.refreshAccountInfo()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(300))
                    } catch {
                        return
                    }
                    await libraryModel.refreshAccountInfo()
                }
            }
            .signOutConfirmation(isPresented: $confirmSignOut) { sessionModel.signOut() }
            .alert(
                String(localized: "settings.clear_cache_title"),
                isPresented: $confirmClearCache
            ) {
                Button(String(localized: "settings.clear_cache"), role: .destructive) { clearCache() }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "settings.clear_cache_message"))
            }
            .sheet(isPresented: $showsBugReport) { MobileBugReportSheet() }
        }
    }

    // MARK: - Sections

    /// Account identity and storage quota when the backend has decoded them.
    @ViewBuilder private var accountSection: some View {
        if account.primaryEmail != nil || (account.driveUsedSpaceBytes != nil && account.driveMaxSpaceBytes != nil) {
            Section(String(localized: "settings.section_account")) {
                if let email = account.primaryEmail {
                    LabeledContent(String(localized: "settings.account_email")) {
                        Text(email).foregroundStyle(ProtonColor.textWeak)
                    }
                }
                if let used = account.driveUsedSpaceBytes,
                    let max = account.driveMaxSpaceBytes,
                    max > 0
                {
                    let quota = ProtonStorageQuotaFormatter.presentation(
                        usedBytes: used,
                        maximumBytes: max
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(String(localized: "settings.storage")) {
                            Text(String(localized: "settings.storage_usage \(quota.used) \(quota.maximum)"))
                                .monospacedDigit()
                                .foregroundStyle(ProtonColor.textWeak)
                        }
                        ActivityProgressBar(
                            fraction: Double(min(used, max)) / Double(max),
                            accessibilityLabel: String(localized: "settings.storage"))
                    }
                }
            }
        }
    }

    private var tipJarSection: some View {
        Section {
            NavigationLink {
                MobileTipJarScreen()
            } label: {
                Label(L10n.string("settings.tip_jar_title"), systemImage: "heart")
            }
        }
    }

    /// User-facing product features live under one stable heading on iPhone and iPad. Each entry opens
    /// its own screen and shows its state as a short value.
    @ViewBuilder private var featuresSection: some View {
        let smartSearch = libraryModel.smartSearch
        let photoBackup = libraryModel.photoBackup
        let albumSync = libraryModel.albumSync
        if smartSearch != nil || photoBackup != nil || albumSync != nil {
            Section(String(localized: "settings.section_features")) {
                if let smartSearch {
                    NavigationLink {
                        MobileSmartSearchScreen(controller: smartSearch)
                    } label: {
                        LabeledContent {
                            Text(onOffSummary(smartSearch.snapshot.isEnabled))
                                .foregroundStyle(ProtonColor.textWeak)
                        } label: {
                            Label(MLSmartSearchPresentation.productName, systemImage: "sparkle.magnifyingglass")
                        }
                    }
                }
                if let photoBackup {
                    NavigationLink {
                        MobileBackupScreen(
                            controller: photoBackup,
                            uploadCoordinator: libraryModel.facade?.uploadCoordinator
                        )
                    } label: {
                        MobileBackupSettingsLabel(controller: photoBackup)
                    }
                }
                if let albumSync {
                    NavigationLink {
                        MobileAlbumSyncScreen(controller: albumSync)
                    } label: {
                        LabeledContent {
                            Text(albumSyncSummary(albumSync))
                                .foregroundStyle(ProtonColor.textWeak)
                        } label: {
                            Label(
                                String(localized: "settings.albumsync_title"), systemImage: "rectangle.stack.badge.plus"
                            )
                        }
                        .accessibilityIdentifier("albumsync.settings")
                    }
                }
            }
        }
    }

    private func onOffSummary(_ isOn: Bool) -> String {
        isOn ? L10n.string("settings.summary_on") : L10n.string("settings.summary_off")
    }

    private var privacySection: some View {
        Section {
            NavigationLink {
                Form { PrivacySettingsContent() }
                    .navigationTitle(L10n.string("settings.privacy_tab"))
            } label: {
                Label(L10n.string("settings.privacy_tab"), systemImage: "hand.raised")
            }
        }
    }

    private func albumSyncSummary(_ albumSync: AlbumSyncController) -> String {
        if !albumSync.isAvailable {
            return L10n.string("settings.summary_unavailable")
        }
        if albumSync.selectedAlbums.isEmpty {
            return onOffSummary(false)
        }
        return String(localized: "settings.albumsync_summary \(albumSync.selectedAlbums.count)")
    }

    /// Features to try before release. Labs stays visible when it offers nothing.
    private var labsSection: some View {
        Section {
            NavigationLink {
                MobileLabsScreen()
            } label: {
                Label(L10n.string("labs.title"), systemImage: "flask")
            }
        }
    }

    /// On-disk encrypted thumbnail-cache size and clear action.
    @ViewBuilder private var cacheSection: some View {
        Section {
            LabeledContent(String(localized: "settings.cache_size")) {
                Text(L10n.fileSize(cacheSize))
                    .monospacedDigit()
                    .foregroundStyle(ProtonColor.textWeak)
            }
            Button(role: .destructive) {
                confirmClearCache = true
            } label: {
                HStack {
                    Text(String(localized: "settings.clear_cache"))
                    Spacer()
                    if isClearingCache { ProgressSpinner() }
                }
            }
            .disabled(isClearingCache)
        } header: {
            Text(String(localized: "settings.section_cache"))
        } footer: {
            if storagePressure != .normal {
                Text(L10n.string("settings.storage_pressure"))
            }
        }
    }

    @ViewBuilder private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Label(L10n.string("action.sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder private var supportSection: some View {
        Section {
            Button {
                showsBugReport = true
            } label: {
                Label(L10n.string("settings.bug_report_action"), systemImage: "ladybug")
            }
        } footer: {
            Text(L10n.string("settings.bug_report_privacy"))
        }
    }

    @ViewBuilder private var brandFooter: some View {
        Section {
            EmptyView()
        } footer: {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    MemoriesBrandMark(height: 28)
                    Text(ProductBrand.displayName)
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textHint)
                    AppBuildInfoLabel()
                    Text(ProductBrand.madeInAustria)
                        .font(.caption2)
                        .foregroundStyle(ProtonColor.textHint)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Actions

    private func refreshCacheSize() async {
        cacheSize = await libraryModel.diskCaches.diskSizeBytes()
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await libraryModel.clearCache()
            await refreshCacheSize()
            isClearingCache = false
        }
    }
}

/// Restarts the cache-size observation when the scene becomes active or the account reload replaces the cache.
private struct CacheSizeObservation: Equatable {
    let scenePhase: ScenePhase
    let caches: ThumbnailCacheGroup
}

private struct MobileBugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var supportExport: MobileSharePayload?
    @State private var isPreparingReport = false
    @State private var errorMessage: String?

    private static let issueURL = URL(
        string: "https://github.com/OnCloud-at/encrypted-memories/issues"
    )!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.string("settings.bug_report_instructions"))
                    Button {
                        Task { await exportSupportReport() }
                    } label: {
                        HStack {
                            Label(
                                L10n.string("settings.bug_report_download"),
                                systemImage: "square.and.arrow.down"
                            )
                            Spacer()
                            if isPreparingReport { ProgressSpinner() }
                        }
                    }
                    .disabled(isPreparingReport)
                    Button {
                        openURL(Self.issueURL) { accepted in
                            if !accepted {
                                errorMessage = L10n.string("settings.bug_report_support_failed")
                            }
                        }
                    } label: {
                        Label(
                            L10n.string("settings.bug_report_support"),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                } footer: {
                    Text(L10n.string("settings.bug_report_privacy"))
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .mobileNavigationTitle(L10n.string("settings.bug_report_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("action.done")) { dismiss() }
                }
                .mobileVisibilityPriority(.high)
            }
            .mobileSharePresentation(payload: $supportExport)
        }
    }

    @MainActor private func exportSupportReport() async {
        guard !isPreparingReport else { return }
        isPreparingReport = true
        errorMessage = nil
        defer { isPreparingReport = false }
        do {
            let data = try await SupportDiagnosticsExporter.makeJSONData()
            guard let url = await MobileMediaExporter.exportSupportReport(data) else {
                errorMessage = L10n.string("settings.bug_report_export_failed")
                return
            }
            supportExport = MobileSharePayload(urls: [url])
        } catch {
            errorMessage = L10n.string("settings.bug_report_export_failed")
        }
    }
}

private struct MobileTipJarScreen: View {
    var body: some View {
        List {
            Section {
                TipJarView()
            } footer: {
                Text(L10n.string("settings.tip_jar_footer"))
            }
        }
        .mobileNavigationTitle(L10n.string("settings.tip_jar_title"))
    }
}

private struct MobileLabsScreen: View {
    var body: some View {
        List {
            LabsSettingsSection()
        }
        .mobileNavigationTitle(L10n.string("labs.title"))
    }
}
