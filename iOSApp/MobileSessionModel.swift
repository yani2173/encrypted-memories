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

    let sessionStore = SessionKeychainStore()
    private let authController: ProtonAuthController
    /// The startup and sign-in guard shared with macOS: no session starts before the sign-out purge and cleanup ended.
    private let startupCleanup = ProtonAuthStartupCleanup()
    private var protectedDataObserver: NSObjectProtocol?
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
        self.authController = ProtonAuthController(
            store: sessionStore,
            authenticator: ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)
        )
        isCheckingSession = true
        statusText = L10n.string("auth.checking_session")
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.startupCleanup.succeeded {
                    self.beginStartupCleanup()
                } else {
                    self.bootstrapSessionIfNeeded()
                }
            }
        }
        beginStartupCleanup(plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded)
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
        guard UIApplication.shared.isProtectedDataAvailable else { return }
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

    /// A WhenUnlocked Keychain item is unavailable during an early launch before iOS releases
    /// protected data. Keep the session in the checking state and retry when the OS announces that
    /// the existing item can be read; this must never look like an account sign-out.
    private func bootstrapSessionIfNeeded() {
        guard !startupCleanup.isRunning, session == nil, !isSigningIn, !isSigningOut else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            apply(.checking)
            return
        }
        guard startupCleanup.succeeded else {
            apply(.signedOut(error: L10n.string("auth.sign_in_failed")))
            return
        }
        apply(authController.bootstrap())
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
