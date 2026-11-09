import MediaByteCache
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveBackend
import SwiftUI
import UIKit

/// Owns the iOS/iPadOS shell around the shared `ProtonAuthController`; authentication behavior remains in Core.
@MainActor
final class MobileSessionModel: ObservableObject {
    static let signInPrompt = String(localized: "auth.sign_in_prompt")

    @Published private(set) var session: ProtonSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isCheckingSession = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var statusText = MobileSessionModel.signInPrompt
    @Published private(set) var errorText: String?

    /// After the first unlock since a restart, a background window on a locked device can read the session.
    let sessionStore: SessionKeychainStore
    private let authController: ProtonAuthController
    /// The startup and sign-in guard shared with macOS: no session starts before the sign-out purge and cleanup ended.
    private let startupCleanup: ProtonAuthStartupCleanup
    private var protectedDataObserver: NSObjectProtocol?
    private var protectedDataUnavailableObserver: NSObjectProtocol?
    private let webAuthenticationSession = ManagedWebAuthenticationSession()
    /// The window of the scene that started sign-in. The managed browser must appear in that window, not in
    /// whichever window happens to be key when Proton returns the authentication URL.
    private var presentationAnchorProvider: (@MainActor () -> UIWindow?)?
    private lazy var webAuthenticationPresentationContext = ManagedWebAuthenticationPresentationContext {
        [weak self] in
        if let window = self?.presentationAnchorProvider?() {
            return window
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard
            let window = windows.first(where: \.isKeyWindow)
                ?? windows.first(where: { !$0.isHidden })
        else {
            preconditionFailure("Web authentication requires an attached application window")
        }
        return window
    }

    init(startupPlaintextPurgeSucceeded: Bool? = nil) {
        injectDefaultCryptoImplementation()
        sessionStore = SessionKeychainStore(accessibility: .afterFirstUnlockThisDeviceOnly)
        let authentication = AuthenticationFactory().make(store: sessionStore, sessionReads: .shared)
        authController = authentication.controller
        startupCleanup = authentication.cleanup
        isCheckingSession = true
        statusText = L10n.string("auth.checking_session")
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.startupCleanup.isRunning {
                    // The running cleanup may have failed on the locked device; it runs once more before it counts.
                    self.startupCleanup.requestRetryIfRunning()
                } else if !self.startupCleanup.succeeded {
                    self.beginStartupCleanup()
                } else {
                    self.bootstrapSessionIfNeeded()
                }
            }
        }
        protectedDataUnavailableObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startupCleanup.noteProtectedDataUnavailable()
            }
        }
        // A background window whose last read was refused asks for one more read before it ends.
        BackgroundAccountReadiness.shared.installReread { [weak self] in self?.bootstrapSessionIfNeeded() }
        beginStartupCleanup(plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded)
    }

    #if DEBUG
        /// Test seam, absent from release builds: a signed-out model around its own store. It begins no startup
        /// cleanup and observes no unlock, so a test never touches the process's saved session.
        init(isolatedStore: SessionKeychainStore) {
            sessionStore = isolatedStore
            let authentication = AuthenticationFactory().make(store: isolatedStore)
            authController = authentication.controller
            startupCleanup = authentication.cleanup
        }
    #endif

    /// Both initializers use the same platform policy. The key path names the UIKit source without a second
    /// test configuration; reading it does not start cleanup, read the Keychain or install an observer.
    @MainActor struct AuthenticationFactory {
        let lockedReadIsChecking = true
        let protectedDataSource = \UIApplication.isProtectedDataAvailable

        /// `sessionReads` learns each read of the saved session; only the process's own model passes it.
        func make(
            store: SessionKeychainStore, sessionReads: BackgroundAccountReadiness? = nil
        ) -> (controller: ProtonAuthController, cleanup: ProtonAuthStartupCleanup) {
            let source = protectedDataSource
            return (
                ProtonAuthController(
                    store: store, authenticator: ProtonForkAuthenticator(config: .externalDriveEncryptedMemories),
                    lockedReadIsChecking: lockedReadIsChecking, sessionReads: sessionReads),
                ProtonAuthStartupCleanup(isProtectedDataAvailable: { UIApplication.shared[keyPath: source] })
            )
        }
    }

    private func beginStartupCleanup(plaintextPurgeSucceeded: Bool? = nil, signInAfterCleanup: Bool = false) {
        guard !startupCleanup.isRunning else { return }
        #if DEBUG
            // UI tests run on the offline fixture account. A saved real account must never start behind it.
            guard !MobileUITestLaunch.isRequested else {
                isCheckingSession = false
                return
            }
        #endif
        apply(.checking)
        // The cleanup reads no session and deletes only transient files or an armed sign-out purge, so it also runs
        // on a locked device; a failure there waits for the unlock instead of closing sign-in.
        startupCleanup.begin(plaintextPurgeSucceeded: plaintextPurgeSucceeded) { [weak self] succeeded in
            guard let self else { return }
            if succeeded, signInAfterCleanup {
                self.signIn()
            } else {
                self.bootstrapSessionIfNeeded()
            }
        }
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        if let protectedDataUnavailableObserver {
            NotificationCenter.default.removeObserver(protectedDataUnavailableObserver)
        }
    }

    /// Starts sign-in from the scene that owns `presentationAnchor`. The anchor is kept for the deferred
    /// startup-cleanup retry so the browser still opens in the initiating window.
    func signIn(presentationAnchor: (@MainActor () -> UIWindow?)? = nil) {
        guard !isSigningOut else { return }
        if let presentationAnchor {
            presentationAnchorProvider = presentationAnchor
        }
        switch startupCleanup.admitSignIn() {
        case .waitForCleanup:
            return
        case .cleanUpFirst:
            beginStartupCleanup(signInAfterCleanup: true)
            return
        case .proceed:
            break
        }
        authController.signIn(
            openURL: { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.startWebAuthenticationSession(url: url)
                }
            },
            onStateChange: { [weak self] state in
                self?.apply(state)
            }
        )
    }

    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        AccountInfo.shared.clear()
        // Explicit user sign-out arms the local-data purge before tearing down the session, so the
        // post-teardown and next-launch checks wipe every account container. It stays unarmed for transient
        // session re-check; only here (see BackupLocalDataPurge).
        ProtonAuthStartupCleanup.armPurgeForSignOut()
        apply(authController.signOut())
    }

    func completeSignOutPresentation() {
        isSigningOut = false
    }

    private func startWebAuthenticationSession(url: URL) {
        webAuthenticationSession.start(
            url: url,
            presentationContextProvider: webAuthenticationPresentationContext
        ) { [weak self] in
            guard let self, self.isSigningIn else { return }
            self.apply(self.authController.cancelSignIn())
        }
    }

    private func apply(_ state: ProtonAuthState) {
        webAuthenticationSession.follow(state)
        switch state {
        case .checking:
            session = nil
            isSigningIn = false
            isCheckingSession = true
            isSigningOut = false
            errorText = nil
            statusText = L10n.string("auth.checking_session")
        case .signedOut(let error):
            session = nil
            isSigningIn = false
            isCheckingSession = false
            errorText = error
            statusText = error == nil ? Self.signInPrompt : L10n.string("auth.sign_in_failed")
        case .authenticating(let progress):
            session = nil
            isSigningIn = true
            isCheckingSession = false
            isSigningOut = false
            errorText = nil
            statusText = ProtonAuthProgressPresentation.status(for: progress)
        case .signedIn(let session):
            self.session = session
            isSigningIn = false
            isCheckingSession = false
            isSigningOut = false
            errorText = nil
            statusText = String(localized: "auth.signed_in")
        }
    }

    /// Before the first unlock since a restart the session item cannot be read. The bootstrap then keeps the checking
    /// state, and the app retries when the OS announces protected data; this must never look like a sign-out. After
    /// the first unlock, a locked device reads the session.
    private func bootstrapSessionIfNeeded() {
        guard !startupCleanup.isRunning, session == nil, !isSigningIn, !isSigningOut else { return }
        apply(
            startupCleanup.startupState(signInFailed: L10n.string("auth.sign_in_failed")) {
                authController.bootstrap()
            })
    }
}

#if DEBUG
    // MARK: - Isolated fixture (hosted tests only)

    extension MobileSessionModel {
        /// Publishes a session without keychain or network access. `nil` behaves like a completed sign-out:
        /// the shared account runtime observes the change and runs the ordinary library teardown. Debug builds only.
        func installIsolatedSession(_ session: ProtonSession?) {
            isCheckingSession = false
            isSigningIn = false
            errorText = nil
            self.session = session
            statusText = session == nil ? Self.signInPrompt : ""
        }
    }
#endif
