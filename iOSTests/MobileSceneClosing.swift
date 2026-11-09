import UIKit

/// How the platform answered a request to close a window scene.
enum MobileSceneClosing: Equatable {
    /// The session is gone and its scene disconnected.
    case closed
    /// The platform reported an error, or the scene stayed connected for the whole wait.
    case refused(String)
}

/// Closes a window scene in a test and reports what the platform did.
///
/// Some simulators connect a second scene on request but cannot destroy it again: UIKit logs
/// "Failed to dismiss UIScene ... This functionality is not supported" and the scene stays. A test must
/// not assert the effects of a closed window when the platform refused to close it, and it must not guess
/// from the device idiom. The platform's own answer decides.
@MainActor enum MobileSceneCloser {
    private final class Reply {
        var error: String?
    }

    static func close(
        _ scene: UIWindowScene, timeout: Duration = .seconds(10)
    ) async -> MobileSceneClosing {
        let identifier = scene.session.persistentIdentifier
        let reply = Reply()
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
            let message = error.localizedDescription
            Task { @MainActor in reply.error = message }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let stillConnected = UIApplication.shared.connectedScenes.contains {
                $0.session.persistentIdentifier == identifier
            }
            if !stillConnected { return .closed }
            if let error = reply.error { return .refused(error) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .refused("the scene stayed connected for \(timeout)")
    }
}
