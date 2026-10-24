import Foundation
import PhotosCore

/// Hosted tests share `UserDefaults.standard` and run in parallel. Every test whose share, copy, or drag
/// result depends on the location preference takes this lease, so no other test changes the stored value
/// until the body finishes. The original value is restored afterwards.
@MainActor
enum SharingLocationPreferenceLease {
    private static var isHeld = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` with the preference stored as `value`, or removed when `value` is nil.
    static func with<T>(storedValue value: Bool?, _ body: @MainActor () async throws -> T) async throws -> T {
        while isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
        isHeld = true
        let defaults = UserDefaults.standard
        let key = AppSettingsKey.removeLocationWhenSharing
        let original = defaults.object(forKey: key)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            isHeld = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
