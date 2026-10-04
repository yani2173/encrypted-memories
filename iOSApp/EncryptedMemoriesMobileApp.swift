import DesignSystemCore
import DesignSystemUIKitAdapter
import Foundation
import LibraryRuntimeAppleAdapter
import MLSearchBackgroundAppleAdapter
import MLSearchCore
import MLSearchFeature
import MapUIKitAdapter
import Metal
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import TimelineCore
import TimelineUIKitAdapter
import UIKit
import UploadCore
import os

@main
struct EncryptedMemoriesMobileApp: App {
    private let metal3Supported: Bool

    init() {
        if let domain = Bundle.main.bundleIdentifier {
            BackupLocalDataPurge.prepareRequestedResetForLaunch(persistentDomainName: domain)
        }
        if BackupLocalDataPurge.isPurgePending() {
            PhotoBackupBackgroundCoordinator.shared.backupStopped()
            AppleSmartSearchBackgroundCoordinator.shared.stop()
        }
        let metal3Supported = MobileMetal3Runtime.isSupported()
        self.metal3Supported = metal3Supported
        MobileBuildProvenanceLog.noteCurrentBuild()
        guard metal3Supported else { return }

        AppleLibraryRuntimeAdapter.shared.install()
        MobileMetricKitCollector.shared.install()
        PhotoBackupBackgroundCoordinator.shared.register()
        AppleSmartSearchBackgroundCoordinator.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            if metal3Supported {
                MobileSupportedAppRoot()
            } else {
                ZStack {
                    ProtonColor.backgroundNorm.ignoresSafeArea()
                    MobileUnsupportedDeviceView()
                }
            }
        }
        .commands {
            MobileNavigationCommands()
        }
    }

    /// One shared reference for the BG task handler - the handler outlives any scene, so it must
    /// not capture SwiftUI-owned state. Set by `MobileLibraryModel` when the account is ready.
    @MainActor
    static func currentPhotoBackup() -> PhotoLibraryBackupController? {
        PhotoLibraryBackupSharedRef.shared.controller
    }
}

/// One window scene's root after the physical device passes the Metal 3 capability gate.
///
/// The account (session, library, backup, ML, caches) is process-wide and owned by `MobileAccountRuntime`.
/// This root attaches the scene to it and owns only scene state: the window anchor for presentations and
/// the celebration overlay of this window. Several iPad windows therefore share one account runtime while
/// keeping independent navigation, search, selection, scroll and viewer state.
private struct MobileSupportedAppRoot: View {
    private let runtime = MobileAccountRuntime.shared
    @State private var sceneContext = MobileSceneContext()
    @State private var confettiMotion = MobileConfettiMotion.shared
    @State private var tipJarCelebration = TipJarCelebrationCoordinator.shared
    @AppStorage(AppSettingsKey.blurAppPreview) private var blurAppPreview = AppSettingsDefault.blurAppPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MobileRootView()
            .environmentObject(runtime.sessionModel)
            .environment(runtime.libraryModel)
            .environment(sceneContext)
            .mobileSceneWindowAnchor(sceneContext)
            .onAppear {
                sceneContext.onWindowChange = { window in
                    if let window { MobilePrivacyPreviewShieldCenter.shared.register(window: window) }
                }
                updatePrivacyPreviewShield()
            }
            .onChange(of: scenePhase) { _, _ in updatePrivacyPreviewShield() }
            .onChange(of: blurAppPreview) { _, _ in updatePrivacyPreviewShield() }
            .background {
                TipJarCelebrationWindowOverlay(horizontalBias: confettiMotion.horizontalBias)
            }
            .task {
                runtime.start()
            }
            #if DEBUG
                .task {
                    await MobileUITestLaunch.installFixtureIfRequested(into: runtime)
                }
            #endif
            .task {
                await TipJarTransactionProcessor.shared.start()
            }
            .onChange(of: tipJarCelebration.activeCelebration?.id) { _, celebrationID in
                if celebrationID == nil || reduceMotion {
                    confettiMotion.stop()
                } else {
                    confettiMotion.start()
                }
            }
            .onChange(of: reduceMotion) { _, isReduced in
                if isReduced {
                    confettiMotion.stop()
                } else if tipJarCelebration.activeCelebration != nil {
                    confettiMotion.start()
                }
            }
            .onDisappear {
                confettiMotion.stop()
                sceneContext.onWindowChange = nil
            }
    }

    private func updatePrivacyPreviewShield() {
        if let window = sceneContext.window { MobilePrivacyPreviewShieldCenter.shared.register(window: window) }
        MobilePrivacyPreviewShieldCenter.shared.refreshAll(enabled: blurAppPreview)
    }
}

private enum MobileBuildProvenanceLog {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "BuildProvenance")

    static func noteCurrentBuild(bundle: Bundle = .main) {
        #if DEBUG
            let commit = bundle.object(forInfoDictionaryKey: AppBuildInfo.buildCommitInfoKey) as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            logger.notice("[BuildProvenance] commit=\(commit, privacy: .public) build=\(build, privacy: .public)")
        #endif
    }
}

/// Top-level mobile routes. The system adapts the tab shell to the available window size without duplicating
/// feature screens or Core logic.
enum MobileTab: CaseIterable, Hashable, Identifiable {
    case photos, collections, map, search

    var id: Self { self }

    var name: String {
        switch self {
        case .photos: "photos"
        case .collections: "collections"
        case .map: "map"
        case .search: "search"
        }
    }

    var title: String {
        switch self {
        case .photos: L10n.string("library.title")
        case .collections: String(localized: "tab.collections")
        case .map: String(localized: "tab.map")
        case .search: String(localized: "tab.search")
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .collections: "square.stack"
        case .map: "map"
        case .search: "magnifyingglass"
        }
    }
}

/// Low-noise `[UIHitch]` tab-transition log (state-change only), same subsystem/category as the grid host's
/// `[UIHitch]` lines so one `log stream` filtered to that category shows tab changes AND grid frame stalls.
enum MobileTabActivityLog {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "UIHitch")
    static func note(tab: MobileTab) {
        logger.notice("[UIHitch] event=tab tab=\(tab.name, privacy: .public)")
    }
}

/// Selects the top-level presentation: unsupported GPU shows a capability message, signed-out users see login,
/// and signed-in users enter the app.
enum MobileRootPresentation: Equatable {
    case unsupportedDevice
    case restoringSession
    case signedOut
    case signedIn

    static func resolve(
        metalSupported: Bool,
        isCheckingSession: Bool,
        hasSession: Bool
    ) -> Self {
        guard metalSupported else { return .unsupportedDevice }
        if isCheckingSession { return .restoringSession }
        return hasSession ? .signedIn : .signedOut
    }

    /// VoiceOver label of the restoring screen. The key lives in the app catalog, so `L10n` cannot resolve it.
    static var restoringSessionAccessibilityLabel: String { String(localized: "auth.checking_session") }
}

enum MobileSignOutCleanupPresentation: Equatable {
    case hidden
    case working
    case failed

    static func resolve(isSigningOut: Bool, cleanupFailed: Bool) -> Self {
        if cleanupFailed { return .failed }
        return isSigningOut ? .working : .hidden
    }
}

private struct MobileRootView: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    @Environment(MobileLibraryModel.self) private var libraryModel

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            switch MobileRootPresentation.resolve(
                // `EncryptedMemoriesMobileApp` gates this root before it is created.
                metalSupported: true,
                isCheckingSession: sessionModel.isCheckingSession,
                hasSession: sessionModel.session != nil
            ) {
            case .unsupportedDevice:
                MobileUnsupportedDeviceView()
            case .restoringSession:
                MobileLibraryLoadingView(
                    isPresented: true,
                    accessibilityLabel: MobileRootPresentation.restoringSessionAccessibilityLabel,
                    activityMessage: "\(L10n.string("library.title_activity")) …",
                    activityState: .working
                )
            case .signedOut:
                MobileLoginView()
            case .signedIn:
                MobileMainTabView()
                    .id(libraryModel.scopePresentationRevision)
            }
        }
        .overlay {
            switch MobileSignOutCleanupPresentation.resolve(
                isSigningOut: sessionModel.isSigningOut || libraryModel.isSigningOut,
                cleanupFailed: libraryModel.signOutCleanupFailed
            ) {
            case .hidden:
                EmptyView()
            case .working:
                MobileLibraryLoadingView(
                    isPresented: true,
                    accessibilityLabel: L10n.string("auth.signing_out"),
                    activityMessage: L10n.string("auth.signing_out"),
                    activityState: .working
                )
            case .failed:
                MobileSignOutFailureView(onRetry: libraryModel.retrySignOutCleanup)
            }
        }
    }
}

/// Shared tab hierarchy; the system adapts its presentation for iPhone and iPad.
private struct MobileMainTabView: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    @Environment(MobileSceneContext.self) private var sceneContext
    @State private var selection: MobileTab = .photos
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var searchActivity: LibraryRuntimeActivityRegistration?
    @State private var networkMonitor = NetworkMonitor.shared
    @Namespace private var libraryActivityTransition
    /// Viewer presentation lives above the adaptive shell so a live iPad resize cannot dismiss open media.
    @State private var viewerRouter = MobileViewerRouter()

    /// Covers navigation chrome until the initial library surface is ready.
    private var showsLibraryLoadingCover: Bool {
        guard libraryModel.loadState.isLoading else { return false }
        return networkMonitor.isOnline || !libraryModel.items.isEmpty
    }

    private var suggestionsRevision: String {
        SmartSearchDiscoveryScheduler.revisionKey(
            timelineRevision: libraryModel.timelineRevision, favoriteUIDs: libraryModel.favoriteUIDs,
            coordinateCount: libraryModel.locationIndex.coordinates.count, smartSearch: libraryModel.smartSearch,
            coordinateRevision: libraryModel.locationIndex.revision
        ) + "|librarySettled:\(libraryModel.allowsAutomaticSuggestionRefresh)"
            + "|cacheContentSettled:\(libraryModel.allowsSuggestionCacheRestore)"
            + "|mapAndPlaces:\(mapAndPlacesEnabled)"
    }

    private func updateSearchActivity() {
        if selection == .search, scenePhase == .active,
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            if searchActivity?.isActive != true { searchActivity = LibraryRuntimeState.shared.beginActivity(.search) }
        } else {
            searchActivity?.end()
            searchActivity = nil
        }
    }

    private var loadingActivityMessage: String {
        networkMonitor.isOnline
            ? "\(L10n.string("library.title_activity")) …"
            : L10n.string("library.title_offline")
    }

    private var loadingActivityState: LibraryActivityBannerState {
        networkMonitor.isOnline ? .working : .offline
    }

    var body: some View {
        @Bindable var sceneContext = sceneContext
        let shell = MobileAdaptiveTabShell(
            selection: $selection, searchText: $searchText, mapAndPlacesEnabled: mapAndPlacesEnabled
        )
        shell.environment(viewerRouter)
            .task(id: suggestionsRevision) {
                updateSearchActivity()
                libraryModel.searchSuggestions.update(
                    sections: libraryModel.sections, timelineRevision: libraryModel.timelineRevision,
                    favoriteUIDs: libraryModel.favoriteUIDs,
                    coordinates: MapAndPlacesPolicy.suggestionCoordinates(
                        libraryModel.locationIndex.coordinates, enabled: mapAndPlacesEnabled),
                    smartSearch: libraryModel.smartSearch,
                    libraryIsSettled: libraryModel.allowsAutomaticSuggestionRefresh,
                    cacheContentIsSettled: libraryModel.allowsSuggestionCacheRestore,
                    coordinateRevision: libraryModel.locationIndex.revision
                )
            }
            .onChange(of: selection, initial: true) { _, _ in updateSearchActivity() }
            .onChange(of: mapAndPlacesEnabled) { _, enabled in
                if enabled {
                    libraryModel.resumeMapAndPlaces()
                } else {
                    if selection == .map { selection = .photos }
                    libraryModel.pauseMapAndPlaces()
                    Task { await NativePlaceNameResolver.shared.cancelPending() }
                }
            }
            .onChange(of: scenePhase) { _, _ in updateSearchActivity() }
            .onChange(of: searchText) { _, _ in updateSearchActivity() }
            .onDisappear {
                searchActivity?.end()
                searchActivity = nil
            }
            .overlay {
                MobileLibraryLoadingView(
                    isPresented: showsLibraryLoadingCover,
                    activityMessage: loadingActivityMessage,
                    activityState: loadingActivityState
                )
            }
            // Above the tab bar, so an undo stays reachable on every tab.
            .overlay {
                UndoNoticeOverlay(
                    notice: Binding(get: { libraryModel.undoNotice }, set: { libraryModel.undoNotice = $0 }),
                    bottomPadding: 72
                )
            }
            .libraryActivityTransition(
                namespace: libraryActivityTransition,
                loadingCoverPresented: showsLibraryLoadingCover
            )
            // Keyboard and menu commands target the focused window; each window publishes its own tab state.
            .focusedSceneValue(
                \.mobileSceneCommands,
                MobileSceneCommandTarget(
                    selectTab: { tab in
                        if tab != .map || mapAndPlacesEnabled { selection = tab }
                    },
                    openSettings: { sceneContext.settingsPresented = true }
                )
            )
            // Settings is a scene-level presentation so the toolbar button and the command open it over any tab.
            .sheet(isPresented: $sceneContext.settingsPresented) {
                MobileSettingsScreen(showsDismissButton: true)
            }
            .fullScreenCover(
                item: Binding(
                    get: { viewerRouter.presentation },
                    set: { viewerRouter.presentation = $0 }
                )
            ) { presentation in
                MobilePhotoViewer(
                    items: presentation.items,
                    startIndex: presentation.index,
                    context: presentation.context,
                    libraryModel: libraryModel,
                    viewerRouter: viewerRouter,
                    showsInfoInitially: presentation.showsInfoInitially,
                    followsLibraryReplacements: presentation.followsLibraryReplacements
                )
            }
            .onChange(of: networkMonitor.didRecentlyRestoreConnection) { _, restored in
                guard restored else { return }
                libraryModel.refreshLibrarySources()
            }
            // The brand tint sits outside the Settings sheet and viewer cover, so their content inherits it through
            // the SwiftUI environment. A tint set only inside the tab shell does not reach them when built with the
            // Xcode 27.0 SDK: Settings icons fell back to system blue.
            .tint(ProtonColor.primary)
    }
}

private struct MobileAdaptiveTabShell: View {
    @Binding var selection: MobileTab
    @Binding var searchText: String
    let mapAndPlacesEnabled: Bool
    /// Bumped when the already-active Photos tab is retapped, so the timeline scrolls to the newest photos.
    @State private var photosScrollSignal = 0
    @State private var searchScope: MLSearchScope = .all

    /// A custom selection binding makes an already-active Photos-tab retap observable. The route and grid
    /// remain mounted; only the newest-photo scroll signal changes.
    private var tabSelection: Binding<MobileTab> {
        Binding {
            selection
        } set: { newValue in
            if newValue == .photos, selection == .photos {
                photosScrollSignal &+= 1
            }
            selection = newValue
        }
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(MobileTab.photos.title, systemImage: MobileTab.photos.systemImage, value: MobileTab.photos) {
                MobileTimelineScreen(
                    surface: .library,
                    isActive: selection == .photos,
                    scrollToLatestSignal: photosScrollSignal
                )
            }
            Tab(
                MobileTab.collections.title, systemImage: MobileTab.collections.systemImage,
                value: MobileTab.collections
            ) {
                MobileCollectionsScreen()
            }
            if mapAndPlacesEnabled {
                Tab(MobileTab.map.title, systemImage: MobileTab.map.systemImage, value: MobileTab.map) {
                    MobileMapScreen()
                }
            }
            Tab(value: MobileTab.search, role: .search) {
                MobileSearchTabScreen(
                    isActive: selection == .search,
                    searchText: $searchText,
                    searchScope: $searchScope
                )
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        // One native container for every width, the Photos-app shell: a bottom tab bar in compact windows, the
        // system's top tab bar with its sidebar toggle in regular iPad windows (and the iPhone Duo inner display).
        // The four routes stay the same in both forms; `TabSection` album lists are not added because album
        // routes are per-scene navigation state, not tabs. The tab bar keeps the default compression: every tab
        // is a navigation-focused browsing surface (HIG: only task-oriented views minimize the tab bar), and the
        // Metal grid is a UIKit scroll view that the SwiftUI minimize behavior does not observe.
        .tabViewStyle(.sidebarAdaptable)
        .tint(ProtonColor.primary)
        .mobileTabBarBackgroundPolicy()
        .onChange(of: selection) { _, tab in
            MobileTabActivityLog.note(tab: tab)
        }
    }
}

/// The semantic search presentation belongs to the search tab's own navigation content. Attaching
/// `.searchable` to the parent `TabView` propagates ordinary top search chrome into the library on iOS 26.
private struct MobileSearchTabScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    let isActive: Bool
    @Binding var searchText: String
    @Binding var searchScope: MLSearchScope
    @State private var history = TimelineSearchHistory()
    /// Structured suggestions that were selected from the landing, keyed by their title in the history.
    @State private var historySuggestions: [String: TimelineSearchSuggestion] = [:]
    @State private var recentRepresentatives: [String: PhotoUID] = [:]
    @State private var activeSuggestion: TimelineSearchSuggestion?
    private var discovery: SmartSearchDiscoveryModel { libraryModel.searchSuggestions.discovery }

    var body: some View {
        MobileTimelineScreen(
            surface: .search,
            isActive: isActive,
            searchText: $searchText,
            searchScope: $searchScope,
            searchLanding: MobileSearchLandingContent(
                recents: recents,
                discovery: discovery,
                isUpdatingSuggestions: libraryModel.searchSuggestions.isRefreshing,
                onSelectRecent: selectRecent,
                onSelectSuggestion: select,
                onClearHistory: clearHistory
            ),
            activeSearchSuggestion: activeSuggestion
        )
        .searchable(
            text: $searchText,
            prompt: Text(L10n.string("search.prompt \(L10n.string("library.title"))"))
        )
        .smartSearchScopes(
            scope: $searchScope,
            availableScopes: libraryModel.smartSearch?.availableSearchScopes ?? [.all],
            isEnabled: libraryModel.smartSearch?.snapshot.isSearchAvailable == true
        )
        .onSubmit(of: .search) { record(searchText) }
        .onChange(of: searchText) { _, text in
            // Editing the text leaves the structured suggestion and returns to ordinary search.
            if let activeSuggestion, !activeSuggestion.owns(searchText: text) {
                self.activeSuggestion = nil
            }
        }
        .onChange(of: discoveryContent) { _, _ in rebindActiveSuggestion() }
        .onChange(of: libraryModel.smartSearch?.snapshot) { _, _ in rebindActiveSuggestion() }
        .onChange(of: discovery.settledGeneration) { _, _ in rebindActiveSuggestion() }
        .onChange(of: ObjectIdentifier(discovery)) { _, _ in rebindActiveSuggestion() }
        .task(id: recentRepresentativesRevision) {
            let sections = libraryModel.sections
            let typedQueries = history.queries.prefix(6).filter { historySuggestions[$0] == nil }
            let representatives: [String: PhotoUID] = await Task.detached(priority: .utility) {
                var representatives: [String: PhotoUID] = [:]
                for query in typedQueries {
                    guard !Task.isCancelled else { return [:] }
                    representatives[query] = TimelineSearch.filter(sections, query: query).last?.items.last?.uid
                }
                return representatives
            }.value
            guard !Task.isCancelled else { return }
            recentRepresentatives = representatives
        }
    }

    /// A structured entry is shown through its current, displayable version, which also provides the preview.
    /// While the suggestions are not current it stays visible without a preview and cannot be selected. It is
    /// hidden only when it cannot work. Typed entries are always shown.
    private var recents: [MobileSearchRecentEntry] {
        history.queries.compactMap { query in
            guard let stored = historySuggestions[query] else {
                return MobileSearchRecentEntry(
                    query: query,
                    representativeUID: recentRepresentatives[query],
                    suggestion: nil
                )
            }
            switch discovery.rebind(
                stored, content: discoveryContent, snapshot: libraryModel.smartSearch?.snapshot)
            {
            case .keep(let current):
                return MobileSearchRecentEntry(
                    query: query,
                    representativeUID: current.representativeUID,
                    suggestion: current
                )
            case .pending:
                // The last thumbnail stays while its item still exists. A visual concept shows none: its
                // sensitive gate is not confirmed for the current library.
                let lastRepresentative =
                    stored.kind == .concept
                    ? nil : stored.representativeUID.flatMap { libraryModel.snapshot.index(of: $0) == nil ? nil : $0 }
                return MobileSearchRecentEntry(
                    query: query,
                    representativeUID: lastRepresentative,
                    suggestion: stored,
                    isAvailable: false
                )
            case .drop:
                return nil
            }
        }
    }

    private var discoveryContent: SmartSearchContentIdentity {
        SmartSearchContentIdentity(
            timelineRevision: libraryModel.timelineRevision,
            favoriteUIDs: libraryModel.favoriteUIDs
        )
    }

    /// Keeps a selected suggestion current after a library change, a search availability change or a finished
    /// refresh. A suggestion that can no longer work is left; this clears only its title, never typed text.
    private func rebindActiveSuggestion() {
        guard let activeSuggestion else { return }
        switch discovery.rebind(
            activeSuggestion, content: discoveryContent, snapshot: libraryModel.smartSearch?.snapshot)
        {
        case .keep(let current):
            if current != activeSuggestion {
                self.activeSuggestion = current
                if current.query != activeSuggestion.query {
                    // The title changed: the old title must not stay as a structured recent entry.
                    historySuggestions[activeSuggestion.query] = nil
                    // The new title can already be in the history. The initializer keeps its first occurrence
                    // only, so the identifiers of the recent entries stay unique.
                    history = TimelineSearchHistory(
                        queries: history.queries.map { $0 == activeSuggestion.query ? current.query : $0 })
                }
                historySuggestions[current.query] = current
                if !current.owns(searchText: searchText) {
                    searchText = current.query
                }
            }
        case .pending:
            break
        case .drop:
            self.activeSuggestion = nil
            if activeSuggestion.owns(searchText: searchText) {
                searchText = ""
            }
        }
    }

    private func select(_ suggestion: TimelineSearchSuggestion) {
        if suggestion.matchingUIDs != nil {
            activeSuggestion = suggestion
            historySuggestions[suggestion.query] = suggestion
        } else {
            activeSuggestion = nil
        }
        searchText = suggestion.query
        record(suggestion.query)
    }

    private func selectRecent(_ entry: MobileSearchRecentEntry) {
        guard let stored = entry.suggestion else {
            activeSuggestion = nil
            searchText = entry.query
            record(entry.query)
            return
        }
        // Replay a structured entry only through its current, displayable version. Its title is never run as
        // a text search, so an entry that cannot work now does nothing.
        guard
            case .keep(let current) = discovery.rebind(
                stored, content: discoveryContent, snapshot: libraryModel.smartSearch?.snapshot)
        else { return }
        select(current)
    }

    private func record(_ query: String) {
        var next = history
        next.record(query)
        guard next != history else { return }
        history = next
        // Keep structured entries only while their title is still in the bounded history.
        historySuggestions = historySuggestions.filter { next.queries.contains($0.key) }
    }

    private func clearHistory() {
        history.clear()
        historySuggestions = [:]
        recentRepresentatives = [:]
    }

    private var recentRepresentativesRevision: String {
        "\(libraryModel.timelineRevision)|\(history.queries.joined(separator: "\u{1F}"))"
    }
}

/// Hardware-keyboard and iPadOS menu-bar commands. They act on the focused window through the target that
/// `MobileMainTabView` publishes, so two windows never share navigation state.
private struct MobileNavigationCommands: Commands {
    @FocusedValue(\.mobileSceneCommands) private var target
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "tab.settings")) {
                target?.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(target == nil)
        }
        CommandMenu(String(localized: "menu.go")) {
            ForEach(Array(MobileTab.allCases.filter { $0 != .map || mapAndPlacesEnabled }.enumerated()), id: \.element)
            { index, tab in
                Button(tab.title) {
                    target?.selectTab(tab)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(target == nil)
            }
            Divider()
            Button(MobileTab.search.title) {
                target?.selectTab(.search)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(target == nil)
        }
    }
}

private struct MobileUnsupportedDeviceView: View {
    var body: some View {
        Metal3UnsupportedDeviceView(productName: ProductBrand.displayName)
    }
}

/// Metal 3 capability gate (a genuine hardware capability check, not a platform fork - the simulator reports
/// capable via `UIKitTimelineMetalCapability`).
enum MobileMetal3Runtime {
    static func isSupported() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return UIKitTimelineMetalCapability.supportsTimelineGrid(device: device)
    }
}
