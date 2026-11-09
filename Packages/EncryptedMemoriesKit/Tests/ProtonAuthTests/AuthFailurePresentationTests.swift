import AppleSecurityCore
import Foundation
import PhotosCore
import Security
import XCTest

@testable import ProtonAuth

final class AuthFailurePresentationTests: XCTestCase {
    @MainActor
    func testSessionReadFailuresUseReadReasonWithoutRemovingSession() {
        let errors: [any Error] = [
            AppleSecurityError(operation: .read, status: errSecNotAvailable),
            SessionKeychainError.invalidPayload,
            NSError(domain: "SessionReadExample", code: 7),
        ]
        for error in errors {
            let store = PresentationSessionStore(loadError: error)
            let reads = BackgroundAccountReadiness(grace: {})
            let controller = ProtonAuthController(
                store: store, authenticator: PresentationAuthenticator(), sessionReads: reads)

            XCTAssertEqual(
                controller.bootstrap(), .signedOut(error: L10n.string("auth.saved_sign_in_unreadable")))
            XCTAssertNil(controller.currentSession)
            XCTAssertEqual(store.clearCount(), 0)
            XCTAssertEqual(store.saveCount(), 0)
            XCTAssertEqual(reads.lastRead, .notYet)
        }
    }

    @MainActor
    func testAuthenticatorFailuresUseShortReasonWithoutSaving() async {
        let errors: [any Error] = [
            ProtonAuthError.apiError(code: 503, message: "Example service diagnostic"),
            ProtonAuthError.invalidResponse,
            ProtonAuthError.payloadDecryptionFailed,
            NSError(domain: "AuthenticationExample", code: 8),
        ]
        for error in errors {
            let store = PresentationSessionStore()
            let controller = ProtonAuthController(
                store: store, authenticator: PresentationAuthenticator(error: error))

            _ = await signIn(controller)

            XCTAssertEqual(controller.state, .signedOut(error: L10n.string("auth.sign_in_incomplete")))
            XCTAssertNil(controller.currentSession)
            XCTAssertEqual(store.saveCount(), 0)
            XCTAssertEqual(store.clearCount(), 0)
        }
    }

    @MainActor
    func testSaveFailuresUseSaveReasonAndNeverPublishSession() async {
        let errors: [any Error] = [
            AppleSecurityError(operation: .update, status: errSecMissingEntitlement),
            SessionKeychainError.verificationFailed,
        ]
        for error in errors {
            let store = PresentationSessionStore(saveError: error)
            let controller = ProtonAuthController(store: store, authenticator: PresentationAuthenticator())

            let states = await signIn(controller)

            XCTAssertEqual(controller.state, .signedOut(error: L10n.string("auth.sign_in_not_saved")))
            XCTAssertNil(controller.currentSession)
            XCTAssertFalse(states.contains { $0.session != nil })
            XCTAssertEqual(store.saveCount(), 1)
            XCTAssertTrue(store.savedSessions().isEmpty)
            XCTAssertEqual(store.clearCount(), 0)
        }
    }

    @MainActor
    func testLockedReadStillWaitsForProtectedData() {
        let store = PresentationSessionStore(
            loadError: AppleSecurityError(operation: .read, status: errSecInteractionNotAllowed))
        let reads = BackgroundAccountReadiness(grace: {})
        let controller = ProtonAuthController(
            store: store, authenticator: PresentationAuthenticator(), lockedReadIsChecking: true,
            sessionReads: reads)

        XCTAssertEqual(controller.bootstrap(), .checking)
        XCTAssertEqual(reads.lastRead, .unreadable)
        XCTAssertEqual(store.saveCount(), 0)
        XCTAssertEqual(store.clearCount(), 0)
    }

    @MainActor
    func testSuccessfulSignInPersistsBeforePublishing() async {
        let store = PresentationSessionStore()
        let controller = ProtonAuthController(store: store, authenticator: PresentationAuthenticator())
        let states = await signIn(controller) { state in
            if case .signedIn(let session) = state {
                XCTAssertEqual(store.savedSessions(), [session])
            }
        }

        XCTAssertEqual(controller.state, .signedIn(presentationSession))
        XCTAssertEqual(states.last, .signedIn(presentationSession))
        XCTAssertEqual(store.saveCount(), 1)
        XCTAssertEqual(store.clearCount(), 0)
    }

    @MainActor
    func testCancellationAndTimeoutKeepTheirSpecificBehavior() async {
        let cases: [(any Error, String?)] = [
            (CancellationError(), nil),
            (ProtonAuthError.timedOut, ProtonAuthError.timedOut.errorDescription),
            (ProtonAuthError.cancelled, ProtonAuthError.cancelled.errorDescription),
        ]
        for (error, message) in cases {
            let store = PresentationSessionStore()
            let controller = ProtonAuthController(
                store: store, authenticator: PresentationAuthenticator(error: error))
            _ = await signIn(controller)

            XCTAssertEqual(controller.state, .signedOut(error: message))
            XCTAssertEqual(store.saveCount(), 0)
        }
    }

    @MainActor
    private func signIn(
        _ controller: ProtonAuthController,
        observe: @escaping @MainActor (ProtonAuthState) -> Void = { _ in }
    ) async -> [ProtonAuthState] {
        let completed = expectation(description: "sign-in reaches a terminal state")
        var states: [ProtonAuthState] = []
        var isComplete = false
        controller.signIn(
            openURL: { _ in },
            onStateChange: { state in
                states.append(state)
                observe(state)
                switch state {
                case .signedIn, .signedOut:
                    isComplete = true
                    completed.fulfill()
                default: break
                }
            })
        await fulfillment(of: [completed], timeout: 5)
        if !isComplete { controller.cancelSignIn() }
        return states
    }
}

private let presentationSession = ProtonSession(
    uid: "example-user", accessToken: "example-access", refreshToken: "example-refresh", keyPassword: "example-key")

private struct PresentationAuthenticator: ProtonAuthenticating {
    var error: (any Error)?

    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession {
        if let error { throw error }
        return presentationSession
    }
}

private final class PresentationSessionStore: ProtonSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let loadError: (any Error)?
    private let saveError: (any Error)?
    private var saved: [ProtonSession] = []
    private var saves = 0
    private var clears = 0

    init(loadError: (any Error)? = nil, saveError: (any Error)? = nil) {
        self.loadError = loadError
        self.saveError = saveError
    }

    func load() throws -> ProtonSession? {
        if let loadError { throw loadError }
        return lock.withLock { saved.last }
    }

    func save(_ session: ProtonSession) throws {
        lock.withLock { saves += 1 }
        if let saveError { throw saveError }
        lock.withLock { saved.append(session) }
    }

    func clear() throws { lock.withLock { clears += 1 } }
    func saveCount() -> Int { lock.withLock { saves } }
    func clearCount() -> Int { lock.withLock { clears } }
    func savedSessions() -> [ProtonSession] { lock.withLock { saved } }
}
