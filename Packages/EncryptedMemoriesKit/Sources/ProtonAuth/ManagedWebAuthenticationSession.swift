import AuthenticationServices
import Foundation

/// Owns Apple's managed browser session for the Proton fork-authentication flow.
///
/// Proton completes authentication through the existing fork polling endpoint, so the web session does not
/// require a callback URL. Platform apps supply only the native presentation anchor.
@MainActor
public final class ManagedWebAuthenticationSession {
    private var activeSession: ASWebAuthenticationSession?
    private var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public func start(
        url: URL,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding,
        onSessionEnd: @escaping @MainActor () -> Void
    ) -> Bool {
        cancel()
        generation &+= 1
        let sessionGeneration = generation
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == sessionGeneration else { return }
                self.activeSession = nil
                onSessionEnd()
            }
        }
        session.presentationContextProvider = presentationContextProvider
        activeSession = session

        guard session.start() else {
            activeSession = nil
            onSessionEnd()
            return false
        }
        return true
    }

    /// Keeps the browser only while the shared fork flow polls Proton; every other state ends it.
    public func follow(_ state: ProtonAuthState) {
        if case .authenticating = state { return }
        cancel()
    }

    public func cancel() {
        generation &+= 1
        let session = activeSession
        activeSession = nil
        session?.cancel()
    }
}

/// Adapts a platform-owned window lookup to AuthenticationServices without duplicating session behavior.
@MainActor
public final class ManagedWebAuthenticationPresentationContext: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private let anchorProvider: @MainActor () -> ASPresentationAnchor

    public init(anchorProvider: @escaping @MainActor () -> ASPresentationAnchor) {
        self.anchorProvider = anchorProvider
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorProvider()
    }
}
