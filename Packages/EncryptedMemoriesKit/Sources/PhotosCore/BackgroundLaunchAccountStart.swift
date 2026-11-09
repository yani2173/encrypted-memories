import Foundation

/// iOS can launch the app for a background task without connecting a scene, and only a scene starts the account. The
/// app installs its one idempotent account start here. Every background window calls `ensureStarted()` before it
/// waits for the account's services; a scene that connects later finds the account running.
@MainActor
public final class BackgroundLaunchAccountStart {
    public static let shared = BackgroundLaunchAccountStart()

    private var start: (@MainActor () -> Void)?

    public init() {}

    /// The app's account start. It must be idempotent: a scene and several windows can call it.
    public func install(_ start: @escaping @MainActor () -> Void) {
        self.start = start
    }

    /// Starts the account through the installed start; without one it does nothing.
    public func ensureStarted() {
        start?()
    }

    /// A window whose work was cancelled before it began starts nothing. Returns whether the account start ran.
    @discardableResult
    public func ensureStarted(unlessCancelled cancelled: Bool) -> Bool {
        guard !cancelled else { return false }
        ensureStarted()
        return true
    }
}
