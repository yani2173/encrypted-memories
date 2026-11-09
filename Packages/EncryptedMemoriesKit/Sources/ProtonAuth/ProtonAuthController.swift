import AppleSecurityCore
import Foundation
import PhotosCore
import Security
import os

public protocol ProtonSessionStorage: Sendable {
    func load() throws -> ProtonSession?
    func save(_ session: ProtonSession) throws
    func clear() throws
    /// Moves a saved session to the store's protection class while it is readable. It never throws and never removes
    /// the session.
    func migrateAccessibilityIfNeeded() -> SessionKeychainStore.AccessibilityMigration
}

extension ProtonSessionStorage {
    /// A store without protection classes has nothing to move.
    public func migrateAccessibilityIfNeeded() -> SessionKeychainStore.AccessibilityMigration { .current }
}

extension SessionKeychainStore: ProtonSessionStorage {}

public protocol ProtonAuthenticating: Sendable {
    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession
}

extension ProtonForkAuthenticator: ProtonAuthenticating {}

public enum ProtonAuthState: Equatable, Sendable {
    case checking
    case signedOut(error: String?)
    case authenticating(ProtonForkAuthenticator.Progress)
    case signedIn(ProtonSession)

    public var session: ProtonSession? {
        guard case .signedIn(let session) = self else { return nil }
        return session
    }
}

/// Platform-neutral session lifecycle around Proton's fork-auth flow.
///
/// UI targets provide only the platform browser opener and presentation strings. Token/key-password
/// persistence, fork progress, cancellation, and state transitions stay shared across macOS, iOS, and iPadOS.
@MainActor
public final class ProtonAuthController {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "Session")

    public private(set) var state: ProtonAuthState = .checking

    private let store: any ProtonSessionStorage
    private let authenticator: any ProtonAuthenticating
    private let signInTimeout: Duration
    /// True where a background launch can find the device locked since its restart (iOS); there a lock denial keeps
    /// checking. Elsewhere it reports a sign-out as before, so no state waits for a retry that never comes.
    private let lockedReadIsChecking: Bool
    /// Learns every read of the saved session and every sign-out, for the background windows.
    private let sessionReads: BackgroundAccountReadiness?
    private var signInTask: Task<Void, Never>?
    private var signInTimeoutTask: Task<Void, Never>?
    private var signInAttemptID: UUID?

    public init(
        store: any ProtonSessionStorage = SessionKeychainStore(),
        authenticator: any ProtonAuthenticating,
        signInTimeout: Duration = .seconds(300),
        lockedReadIsChecking: Bool = false,
        sessionReads: BackgroundAccountReadiness? = nil
    ) {
        self.store = store
        self.sessionReads = sessionReads
        self.authenticator = authenticator
        self.signInTimeout = signInTimeout
        self.lockedReadIsChecking = lockedReadIsChecking
    }

    public var currentSession: ProtonSession? {
        state.session
    }

    @discardableResult
    public func bootstrap() -> ProtonAuthState {
        do {
            if let session = try store.load() {
                // The session was readable, so an item of an older class moves now; a failure keeps the session.
                let migration = store.migrateAccessibilityIfNeeded()
                if migration == .failed { Self.logger.error("Session protection class not updated; retried later") }
                sessionReads?.record(.readable)
                return setState(.signedIn(session))
            }
            sessionReads?.record(.absent)
            return setState(.signedOut(error: nil))
        } catch let error as AppleSecurityError
            where lockedReadIsChecking && error.status == errSecInteractionNotAllowed
        {
            // The device has not been unlocked since it started. The session exists but cannot be read yet: keep
            // checking, never report a sign-out. The app retries when protected data becomes available.
            sessionReads?.record(.unreadable)
            return setState(.checking)
        } catch {
            // A damaged or unsupported item cannot become readable by waiting: it reports a sign-out. The item itself
            // stays where it is; only an explicit sign-out removes it. A background window keeps its bounded wait.
            sessionReads?.record(.notYet)
            return setState(
                .signedOut(error: AuthFailurePresentation.message(for: error, context: .savedSessionRead)))
        }
    }

    public func signIn(
        openURL: @escaping @Sendable (URL) -> Void,
        onStateChange: @escaping @MainActor (ProtonAuthState) -> Void = { _ in }
    ) {
        signInTask?.cancel()
        signInTimeoutTask?.cancel()
        let attemptID = UUID()
        signInAttemptID = attemptID
        setState(.authenticating(.requestingLink), notify: onStateChange)
        signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failureContext = AuthFailurePresentation.Context.authentication
            do {
                let session = try await authenticator.authenticate(
                    openURL: openURL,
                    onProgress: { progress in
                        Task { @MainActor [weak self] in
                            guard self?.signInAttemptID == attemptID else { return }
                            self?.setState(.authenticating(progress), notify: onStateChange)
                        }
                    }
                )
                try Task.checkCancellation()
                guard signInAttemptID == attemptID else { return }
                failureContext = .sessionSave
                try store.save(session)
                finishSignInAttempt(attemptID)
                sessionReads?.record(.readable)
                setState(.signedIn(session), notify: onStateChange)
            } catch is CancellationError {
                guard signInAttemptID == attemptID else { return }
                finishSignInAttempt(attemptID)
                setState(.signedOut(error: nil), notify: onStateChange)
            } catch {
                guard signInAttemptID == attemptID else { return }
                finishSignInAttempt(attemptID)
                setState(
                    .signedOut(error: AuthFailurePresentation.message(for: error, context: failureContext)),
                    notify: onStateChange
                )
            }
        }
        let timeout = signInTimeout
        signInTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.signInAttemptID == attemptID else { return }
            self.signInTask?.cancel()
            self.signInTask = nil
            self.signInTimeoutTask = nil
            self.signInAttemptID = nil
            self.setState(
                .signedOut(error: Self.message(for: ProtonAuthError.timedOut)),
                notify: onStateChange
            )
        }
    }

    @discardableResult
    public func cancelSignIn() -> ProtonAuthState {
        signInTask?.cancel()
        signInTimeoutTask?.cancel()
        signInTask = nil
        signInTimeoutTask = nil
        signInAttemptID = nil
        return setState(.signedOut(error: nil))
    }

    @discardableResult
    public func signOut() -> ProtonAuthState {
        signInTask?.cancel()
        signInTimeoutTask?.cancel()
        signInTask = nil
        signInTimeoutTask = nil
        signInAttemptID = nil
        sessionReads?.record(.absent)
        do {
            try store.clear()
            return setState(.signedOut(error: nil))
        } catch {
            return setState(.signedOut(error: Self.message(for: error)))
        }
    }

    @discardableResult
    private func setState(
        _ newState: ProtonAuthState,
        notify: (@MainActor (ProtonAuthState) -> Void)? = nil
    ) -> ProtonAuthState {
        state = newState
        notify?(newState)
        return newState
    }

    private func finishSignInAttempt(_ attemptID: UUID) {
        guard signInAttemptID == attemptID else { return }
        signInTimeoutTask?.cancel()
        signInTask = nil
        signInTimeoutTask = nil
        signInAttemptID = nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
