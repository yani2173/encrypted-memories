import Foundation
import PhotosCore
import Testing

@testable import ProtonAuth

@Suite("Shared auth lifecycle")
struct ProtonAuthControllerTests {
    @MainActor
    @Test func bootstrapRestoresWithoutRewritingPersistedSession() {
        let session = ProtonSession(uid: "uid-restored", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let store = FakeSessionStore(initial: session)
        let controller = ProtonAuthController(store: store, authenticator: FakeAuthenticator(session: session))

        #expect(controller.bootstrap() == .signedIn(session))
        #expect(controller.currentSession == session)
        #expect(store.savedSessions().isEmpty)
    }

    @MainActor
    @Test func bootstrapSurfacesKeychainReadFailure() {
        let store = FakeSessionStore(loadError: FakeStoreError.unavailable)
        let controller = ProtonAuthController(store: store, authenticator: FakeAuthenticator())

        #expect(controller.bootstrap() == .signedOut(error: L10n.string("auth.saved_sign_in_unreadable")))
    }

    @MainActor
    @Test func aSignOutTellsTheBackgroundWindowsThatNoAccountIsSignedIn() {
        let session = ProtonSession(uid: "uid-signed-out", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let reads = BackgroundAccountReadiness(grace: {})
        let controller = ProtonAuthController(
            store: FakeSessionStore(initial: session), authenticator: FakeAuthenticator(), sessionReads: reads)
        controller.bootstrap()
        #expect(reads.lastRead == .readable)
        controller.signOut()
        #expect(reads.lastRead == .absent)
    }

    @MainActor
    @Test func aSignOutWhoseRemovalFailedStillTellsTheBackgroundWindowsThatNoAccountIsSignedIn() {
        let session = ProtonSession(uid: "uid-signed-out", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let reads = BackgroundAccountReadiness(grace: {})
        let controller = ProtonAuthController(
            store: FakeSessionStore(initial: session, clearError: FakeStoreError.unavailable),
            authenticator: FakeAuthenticator(), sessionReads: reads)
        controller.bootstrap()
        guard case .signedOut(let error) = controller.signOut() else {
            Issue.record("the sign-out ends the account")
            return
        }
        #expect(error != nil)
        #expect(reads.lastRead == .absent)
    }

    @MainActor
    @Test func aSignInTellsTheBackgroundWindowsThatTheSignInIsReadable() async {
        let session = ProtonSession(uid: "uid-new", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let reads = BackgroundAccountReadiness(grace: {})
        let controller = ProtonAuthController(
            store: FakeSessionStore(), authenticator: FakeAuthenticator(session: session), sessionReads: reads)
        controller.bootstrap()
        #expect(reads.lastRead == .absent)
        controller.signIn(openURL: { _ in })
        #expect(await waitUntil { controller.state == .signedIn(session) })
        #expect(reads.lastRead == .readable)
    }

    @MainActor
    @Test func signInPublishesProgressPersistsSessionAndOpensURL() async {
        let session = ProtonSession(uid: "uid-signed-in", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let signInURL = URL(string: "https://account.proton.me/desktop/login")!
        let store = FakeSessionStore()
        let openedURL = URLRecorder()
        let controller = ProtonAuthController(
            store: store,
            authenticator: FakeAuthenticator(
                session: session,
                signInURL: signInURL,
                progress: [.waitingForBrowser, .finalizing]
            )
        )
        var states: [ProtonAuthState] = []

        controller.signIn(
            openURL: { url in
                Task { await openedURL.record(url) }
            },
            onStateChange: { state in
                states.append(state)
            }
        )

        #expect(await waitUntil { controller.state == .signedIn(session) })
        #expect(await openedURL.value() == signInURL)
        #expect(store.savedSessions() == [session])
        #expect(states.contains(.authenticating(.requestingLink)))
        #expect(states.contains(.authenticating(.waitingForBrowser)))
        #expect(states.contains(.authenticating(.finalizing)))
        #expect(states.last == .signedIn(session))
    }

    @MainActor
    @Test func signInFailurePublishesSignedOutErrorWithoutSaving() async {
        let store = FakeSessionStore()
        let controller = ProtonAuthController(
            store: store,
            authenticator: FakeAuthenticator(error: FakeAuthError.offline)
        )

        controller.signIn(openURL: { _ in })

        #expect(
            await waitUntil {
                controller.state == .signedOut(error: L10n.string("auth.sign_in_incomplete"))
            })
        #expect(store.savedSessions().isEmpty)
    }

    @MainActor
    @Test func signInDoesNotPublishSignedInWhenPersistenceFails() async {
        let session = ProtonSession(uid: "uid-not-persisted", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let store = FakeSessionStore(saveError: FakeStoreError.unavailable)
        let controller = ProtonAuthController(store: store, authenticator: FakeAuthenticator(session: session))

        controller.signIn(openURL: { _ in })

        #expect(
            await waitUntil {
                controller.state == .signedOut(error: L10n.string("auth.sign_in_not_saved"))
            })
        #expect(controller.currentSession == nil)
    }

    @MainActor
    @Test func signInHardTimeoutReturnsToRetryableSignedOutState() async {
        let store = FakeSessionStore()
        let controller = ProtonAuthController(
            store: store,
            authenticator: HangingAuthenticator(),
            signInTimeout: .milliseconds(25)
        )

        controller.signIn(openURL: { _ in })

        #expect(
            await waitUntil {
                controller.state == .signedOut(error: ProtonAuthError.timedOut.errorDescription)
            })
        #expect(store.savedSessions().isEmpty)
    }

    @MainActor
    @Test func cancellingSignInSuppressesThePendingTimeout() async {
        let controller = ProtonAuthController(
            store: FakeSessionStore(),
            authenticator: HangingAuthenticator(),
            signInTimeout: .milliseconds(50)
        )

        controller.signIn(openURL: { _ in })
        #expect(controller.cancelSignIn() == .signedOut(error: nil))
        try? await Task.sleep(for: .milliseconds(75))

        #expect(controller.state == .signedOut(error: nil))
    }

    @MainActor
    @Test func signOutClearsSharedStore() {
        let session = ProtonSession(uid: "uid-out", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let store = FakeSessionStore(initial: session)
        let controller = ProtonAuthController(store: store, authenticator: FakeAuthenticator(session: session))
        _ = controller.bootstrap()

        #expect(controller.signOut() == .signedOut(error: nil))
        #expect(controller.currentSession == nil)
        #expect(store.clearCount() == 1)
    }
}

@MainActor
private func waitUntil(_ predicate: @escaping () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

private final class FakeSessionStore: ProtonSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProtonSession?
    private var saved: [ProtonSession] = []
    private var clears = 0
    private let loadError: Error?
    private let saveError: Error?
    private let clearError: Error?

    init(
        initial: ProtonSession? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil,
        clearError: Error? = nil
    ) {
        stored = initial
        self.loadError = loadError
        self.saveError = saveError
        self.clearError = clearError
    }

    func load() throws -> ProtonSession? {
        if let loadError { throw loadError }
        return lock.withLock { stored }
    }

    func save(_ session: ProtonSession) throws {
        if let saveError { throw saveError }
        lock.withLock {
            stored = session
            saved.append(session)
        }
    }

    func clear() throws {
        if let clearError { throw clearError }
        lock.withLock {
            stored = nil
            clears += 1
        }
    }

    func savedSessions() -> [ProtonSession] {
        lock.withLock { saved }
    }

    func clearCount() -> Int {
        lock.withLock { clears }
    }
}

private struct FakeAuthenticator: ProtonAuthenticating {
    let session: ProtonSession
    let signInURL: URL
    let progress: [ProtonForkAuthenticator.Progress]
    let error: Error?

    init(
        session: ProtonSession = ProtonSession(uid: "uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        signInURL: URL = URL(string: "https://account.proton.me/desktop/login")!,
        progress: [ProtonForkAuthenticator.Progress] = [],
        error: Error? = nil
    ) {
        self.session = session
        self.signInURL = signInURL
        self.progress = progress
        self.error = error
    }

    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession {
        if let error { throw error }
        openURL(signInURL)
        for progress in progress {
            onProgress(progress)
            await Task.yield()
        }
        return session
    }
}

private struct HangingAuthenticator: ProtonAuthenticating {
    func authenticate(
        openURL _: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession {
        onProgress(.waitingForBrowser)
        try await Task.sleep(for: .seconds(60))
        return ProtonSession(uid: "late", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
    }
}

private actor URLRecorder {
    private var recorded: URL?

    func record(_ url: URL) {
        recorded = url
    }

    func value() -> URL? {
        recorded
    }
}

private enum FakeAuthError: LocalizedError {
    case offline

    var errorDescription: String? {
        "offline"
    }
}

private enum FakeStoreError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "session store unavailable"
    }
}
