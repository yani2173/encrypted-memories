import UIKit

extension UIApplication {
    /// The window scene in which a test builds its windows: the foreground-active one, else the first by identifier.
    ///
    /// `connectedScenes` is an unordered set. A platform that cannot close a second scene, like the iPhone Duo
    /// simulator, keeps it for the rest of the run and restores it at later launches. A test that took an arbitrary
    /// scene then sometimes built its window in a background scene with other traits.
    @MainActor var foregroundWindowScene: UIWindowScene? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
