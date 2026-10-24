import AppKit
import DesignSystem
import DesignSystemCore
import LibraryRuntimeAppleAdapter
import MetalRenderingCore
import PhotoViewerFeature
import PhotosCore
import SwiftUI
import TimelineFeature

@main
struct EncryptedMemoriesApp: App {
    @NSApplicationDelegateAdaptor(EncryptedMemoriesAppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    private let metal3Supported: Bool

    init() {
        let metal3Supported = Metal3RuntimeCapability.supportsDefaultDevice()
        self.metal3Supported = metal3Supported
        if metal3Supported {
            AppleLibraryRuntimeAdapter.shared.install()
        }
        _model = State(initialValue: metal3Supported ? AppModel() : nil)
        // SwiftUI exposes no per-view tooltip delay. Use a responsive 400 ms AppKit delay.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    var body: some Scene {
        Window(L10n.string("library.title"), id: "library") {
            Group {
                if let model {
                    RootView(model: model)
                        .launchVeil(purpose: model.launchVeilPurpose, model: model)
                        .task {
                            model.bootstrap()
                            await TipJarTransactionProcessor.shared.start()
                        }
                } else {
                    Metal3UnsupportedDeviceView(productName: ProductBrand.displayName)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ProtonColor.backgroundNorm)
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            .background(WindowConfigurator())
            .background { TipJarCelebrationWindowOverlay() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model?.smartSearch?.noteConditionsChanged()
                model?.refreshLibrarySources()
                model?.photoBackupController?.applicationDidBecomeActive()
            }
        }
        .defaultSize(width: 1080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                if metal3Supported {
                    Button(L10n.string("albums.new_album_menu")) {
                        NotificationCenter.default.post(name: .encryptedMemoriesNewAlbum, object: nil)
                    }
                    Divider()
                    Button("menu.upload_photos") {
                        NotificationCenter.default.post(
                            name: .encryptedMemoriesUploadPhotos,
                            object: nil,
                            userInfo: uploadCommandUserInfo(trigger: .menu)
                        )
                    }
                    .keyboardShortcut("u", modifiers: [.command])
                    Button("menu.upload_folder") {
                        NotificationCenter.default.post(
                            name: .encryptedMemoriesUploadFolder,
                            object: nil,
                            userInfo: uploadCommandUserInfo(trigger: .menu)
                        )
                    }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    Divider()
                    Button("menu.show_uploads") {
                        NotificationCenter.default.post(
                            name: .encryptedMemoriesShowUploadQueue,
                            object: nil,
                            userInfo: uploadCommandUserInfo(trigger: .menu)
                        )
                    }
                }
            }
            CommandGroup(after: .sidebar) {
                if metal3Supported {
                    Button("menu.toggle_sidebar") {
                        NotificationCenter.default.post(name: .encryptedMemoriesToggleSidebar, object: nil)
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    Button("menu.refresh_library") {
                        NotificationCenter.default.post(name: .encryptedMemoriesRefreshLibrary, object: nil)
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
            OpenLibraryWindowCommands()
            PhotoViewerNavigationCommands()
        }

        // Use the native Settings scene so macOS owns the application menu command and shortcut.
        Settings {
            Group {
                if let model {
                    SettingsView(
                        isAccountAvailable: model.hasAuthenticatedAccount,
                        uploadCoordinator: model.facade?.uploadCoordinator,
                        backup: model.backupController,
                        photoBackup: model.photoBackupController,
                        albumSync: model.albumSyncController,
                        smartSearch: model.smartSearch,
                        appModel: model,
                        refreshAccountInfo: {
                            guard let facade = model.facade else { return }
                            try? await facade.refreshAccountInfo()
                        },
                        signOut: { model.signOut() }
                    )
                } else {
                    Metal3UnsupportedDeviceView(productName: ProductBrand.displayName)
                        .frame(minWidth: 520, minHeight: 360)
                        .background(ProtonColor.backgroundNorm)
                }
            }
            .background { TipJarCelebrationWindowOverlay() }
        }
    }
}

final class EncryptedMemoriesAppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceGuard = SingleInstanceGuard()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard singleInstanceGuard.acquire() else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppleLibraryRuntimeAdapter.shared.setExecutionOpportunity(.foregroundActive)
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppleLibraryRuntimeAdapter.shared.setExecutionOpportunity(.foregroundInactive)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate()
        if !LibraryWindowVisibilityController.shared.showLibrary() {
            sender.windows.first(where: { $0.identifier?.rawValue == "library" })?.makeKeyAndOrderFront(nil)
        }
        // The retained library window has been handled here; suppress AppKit's default untitled-window route.
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let libraryItem = NSMenuItem(
            title: L10n.string("library.title"),
            action: #selector(showLibraryFromDock(_:)),
            keyEquivalent: ""
        )
        libraryItem.target = self
        menu.addItem(libraryItem)
        return menu
    }

    @MainActor
    @objc private func showLibraryFromDock(_ sender: Any?) {
        NSApp.activate()
        if !LibraryWindowVisibilityController.shared.showLibrary() {
            NSApp.windows.first(where: { $0.identifier?.rawValue == "library" })?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Hides the library window without destroying its SwiftUI scene, preserving grid and navigation state.
@MainActor
private final class LibraryWindowVisibilityController: NSObject {
    static let shared = LibraryWindowVisibilityController()

    private var libraryWindow: NSWindow?
    private var delegateProxy: LibraryWindowDelegateProxy?

    func attach(to window: NSWindow) {
        if libraryWindow !== window {
            libraryWindow = window
            delegateProxy = nil
        }

        // SwiftUI may replace the native close button and its target when rebuilding toolbar chrome.
        // NSWindowDelegate is the durable AppKit close contract for the red control, Command-W and
        // File > Close. Keep SwiftUI's delegate behind a forwarding proxy and reinstall only if the
        // scene replaced it.
        if window.delegate !== delegateProxy {
            let proxy = LibraryWindowDelegateProxy(forwardingTo: window.delegate)
            delegateProxy = proxy
            window.delegate = proxy
        }
    }

    @discardableResult
    func showLibrary() -> Bool {
        guard let window = libraryWindow else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Intercepts only the close decision and forwards every other optional NSWindowDelegate callback to
/// SwiftUI's delegate. Returning false keeps the existing scene, AppModel and authenticated session alive.
@MainActor
private final class LibraryWindowDelegateProxy: NSObject, NSWindowDelegate {
    private weak var forwardedDelegate: (any NSWindowDelegate)?

    init(forwardingTo delegate: (any NSWindowDelegate)?) {
        forwardedDelegate = delegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
        return super.forwardingTarget(for: selector)
    }
}

/// Attaches window-level lifecycle controllers. Window chrome belongs to the SwiftUI scene declaration above;
/// mutating title-bar style here is not durable because SwiftUI can rebuild AppKit's title-bar hierarchy later.
private struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.windowChanged = { window in configure(window, context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        nsView.windowChanged = { window in configure(window, context.coordinator) }
        configure(nsView.window, context.coordinator)
    }

    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("library")
        coordinator.frameController.attach(to: window)
        LibraryWindowVisibilityController.shared.attach(to: window)
    }

    @MainActor final class Coordinator {
        let frameController = MainWindowFrameController(defaultSize: CGSize(width: 1080, height: 720))
    }
}

/// Previous photo, Next photo, Close and Show Original for the open viewer. The commands are disabled while no viewer
/// has focus, and Close carries the Esc equivalent, which the responder chain alone does not guarantee.
private struct PhotoViewerNavigationCommands: Commands {
    @FocusedValue(\.photoViewerNavigation) private var navigation

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button(L10n.string("a11y.previous_photo")) { navigation?.goPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(navigation?.canGoPrevious != true)
            Button(L10n.string("a11y.next_photo")) { navigation?.goNext() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(navigation?.canGoNext != true)
            Button(L10n.string("viewer.close_photo")) { navigation?.close() }
                .keyboardShortcut(.cancelAction)
                .disabled(navigation == nil)
            Divider()
            let showsOriginal = navigation?.isShowingOriginal == true
            Button(showsOriginal ? L10n.string("viewer.show_edited") : L10n.string("viewer.show_original")) {
                navigation?.toggleOriginal()
            }
            .disabled(navigation?.canShowOriginal != true)
        }
    }
}

private struct OpenLibraryWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button(L10n.string("library.title")) {
                if !LibraryWindowVisibilityController.shared.showLibrary() {
                    openWindow(id: "library")
                }
            }
            .keyboardShortcut("1", modifiers: [.command])
        }
    }
}

// MARK: - Launch veil
//
// The shared DesignSystem cover renders over the mounted app content. On macOS the complete host window becomes
// a non-opaque behind-window material so the desktop remains visible through the startup surface.

private enum LaunchVeilPurpose: Equatable {
    case authentication
    case libraryPreparation
    case signingOut

    var accessibilityLabel: String {
        switch self {
        case .authentication:
            L10n.string("login.sign_in_button")
        case .libraryPreparation:
            String(localized: "loading.building_library")
        case .signingOut:
            L10n.string("auth.signing_out")
        }
    }

    @MainActor
    func activityMessage(networkMonitor: NetworkMonitor) -> String? {
        switch self {
        case .authentication:
            nil
        case .libraryPreparation:
            networkMonitor.isOnline
                ? "\(L10n.string("library.title_activity")) …"
                : L10n.string("library.title_offline")
        case .signingOut:
            L10n.string("auth.signing_out")
        }
    }

    @MainActor
    func activityState(networkMonitor: NetworkMonitor) -> LibraryActivityBannerState {
        switch self {
        case .authentication:
            .working
        case .libraryPreparation:
            networkMonitor.isOnline ? .working : .offline
        case .signingOut:
            .working
        }
    }

    var allowsHardDismiss: Bool {
        self == .libraryPreparation
    }
}

private extension AppModel {
    var launchVeilPurpose: LaunchVeilPurpose? {
        switch auth {
        case .signedOut, .authenticating:
            .authentication
        case .signingOut:
            .signingOut
        case .signOutFailed:
            nil
        default:
            isPreparing ? .libraryPreparation : nil
        }
    }
}

private extension View {
    /// Keeps one frosted surface mounted through authentication and library preparation, switching only its
    /// centered content before it crossfades away to reveal the ready library.
    func launchVeil(purpose: LaunchVeilPurpose?, model: AppModel) -> some View {
        modifier(LaunchVeilModifier(purpose: purpose, model: model))
    }
}

private struct LaunchVeilModifier: ViewModifier {
    let purpose: LaunchVeilPurpose?
    let model: AppModel

    @State private var visible = true
    @State private var networkMonitor = NetworkMonitor.shared
    @Namespace private var libraryActivityTransition
    @State private var appearedAt = Date()
    @State private var dismissScheduled = false
    @State private var displayedPurpose: LaunchVeilPurpose = .libraryPreparation
    @State private var hardDismissGeneration = 0
    private let minShown: Double = 0.5
    /// Safety net: never trap the user behind the veil if preparation hangs (e.g. an offline/stalled first
    /// load that never reaches loaded/empty/failed). After this it fades regardless, revealing the UI behind.
    private let maxShown: Double = 8
    private var active: Bool { purpose != nil }

    func body(content: Content) -> some View {
        content
            .toolbarVisibility(visible ? .hidden : .automatic, for: .windowToolbar)
            .overlay {
                ZStack {
                    LibraryLoadingCover(
                        isPresented: visible,
                        accessibilityLabel: displayedPurpose.accessibilityLabel,
                        activityMessage: displayedPurpose.activityMessage(networkMonitor: networkMonitor),
                        activityState: displayedPurpose.activityState(networkMonitor: networkMonitor),
                        showsLoadingContent: displayedPurpose != .authentication
                    ) { isActive in
                        LibraryFrostedBackdrop(isActive: isActive)
                    }

                    if visible, displayedPurpose == .authentication {
                        LoginView(model: model)
                            .transition(.opacity)
                    }
                }
            }
            .libraryActivityTransition(
                namespace: libraryActivityTransition,
                loadingCoverPresented: visible
            )
            .onAppear {
                if let purpose { displayedPurpose = purpose }
                // A window born already-ready (a second window, or relaunch after the library loaded) must
                // never go transparent - only veil when there is genuinely something to prepare.
                if !active {
                    visible = false
                    dismissScheduled = true
                }
                scheduleDismissIfReady()
                if visible { scheduleHardDismissIfNeeded() }
            }
            .onChange(of: purpose) { _, newPurpose in
                hardDismissGeneration &+= 1
                if let newPurpose {
                    // A fresh preparation cycle, such as sign-out followed by re-login, re-raises the veil.
                    dismissScheduled = false
                    appearedAt = Date()
                    withAnimation(.easeInOut(duration: LibraryLoadingCoverMetrics.fadeDuration)) {
                        displayedPurpose = newPurpose
                        visible = true
                    }
                    scheduleHardDismissIfNeeded()
                } else {
                    scheduleDismissIfReady()
                }
            }
    }

    /// Once preparation has finished, keep the veil for the remainder of `minShown` (anti-flicker) and then
    /// crossfade it out. Runs at most once.
    private func scheduleDismissIfReady() {
        guard visible, !dismissScheduled, !active else { return }
        dismissScheduled = true
        let remaining = max(0, minShown - Date().timeIntervalSince(appearedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            withAnimation(.easeOut(duration: LibraryLoadingCoverMetrics.fadeDuration)) { visible = false }
        }
    }

    private func scheduleHardDismissIfNeeded() {
        guard displayedPurpose.allowsHardDismiss else { return }
        hardDismissGeneration &+= 1
        let generation = hardDismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + maxShown) {
            if visible, generation == hardDismissGeneration, displayedPurpose.allowsHardDismiss {
                withAnimation(.easeOut(duration: LibraryLoadingCoverMetrics.fadeDuration)) { visible = false }
            }
        }
    }
}

/// Reports window attachment synchronously. `NSViewRepresentable.updateNSView` may run before `window` exists;
/// `viewDidMoveToWindow` is the AppKit lifecycle point that closes that gap without a one-frame async dispatch.
@MainActor
private final class WindowAttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.auth {
        case .checking:
            ProtonLoadingView()
        case .signingOut:
            ProtonLoadingView(caption: L10n.string("auth.signing_out"))
        case .signOutFailed:
            SignOutFailureView(retry: model.retrySignOutCleanup)
        case .signedOut, .authenticating:
            Color.clear
        case .signedIn:
            signedIn
        }
    }

    @ViewBuilder private var signedIn: some View {
        switch model.backend {
        case .ready:
            if let facade = model.facade {
                MainView(model: model, facade: facade)
            } else {
                ProtonLoadingView(caption: String(localized: "loading.building_library"))
            }
        case .failed(let message):
            BackendErrorView(message: message, retry: { model.retryBackend() }, signOut: { model.signOut() })
        case .preparing, .idle:
            ProtonLoadingView(caption: String(localized: "loading.building_library"))
        }
    }
}

private struct SignOutFailureView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()
            ContentUnavailableView {
                Label {
                    Text(L10n.string("sign_out.cleanup_failed_title"))
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
            } description: {
                Text(L10n.string("sign_out.cleanup_failed_message"))
            } actions: {
                RetryButton(.prominent, action: retry)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BackendErrorView: View {
    let message: String
    let retry: () -> Void
    let signOut: () -> Void
    @State private var confirmSignOut = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 42))
                .foregroundStyle(ProtonColor.warning)
            Text("error.library_open_failed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                RetryButton(.prominent, action: retry).frame(minWidth: 120)
                Button(L10n.string("action.sign_out")) { confirmSignOut = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(ProtonColor.textHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
        .signOutConfirmation(isPresented: $confirmSignOut, onConfirm: signOut)
    }
}
