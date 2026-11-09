import CoreGraphics
import Foundation

/// Width limits for the left sidebar. A stored width is read through `clamp(_:)` so the sidebar cannot
/// become unusably narrow or crowd the grid.
public enum SidebarMetrics {
    public static let minWidth: CGFloat = 180
    public static let maxWidth: CGFloat = 360
    public static let defaultWidth: CGFloat = 230

    public static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }

    /// The persisted width to use on launch: the saved value clamped, or the default when unset
    /// (`stored == 0`, which is what `UserDefaults.double(forKey:)` returns for a missing key).
    public static func resolved(stored: CGFloat) -> CGFloat {
        stored <= 0 ? defaultWidth : clamp(stored)
    }
}

public enum SidebarPersistence {
    public static func resolvedWidth(defaults: UserDefaults = .standard) -> CGFloat {
        SidebarMetrics.resolved(stored: CGFloat(defaults.double(forKey: AppSettingsKey.sidebarWidth)))
    }

    public static func resolvedVisible(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppSettingsKey.sidebarVisible) != nil else { return true }
        return defaults.bool(forKey: AppSettingsKey.sidebarVisible)
    }

    public static func saveVisible(_ visible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: AppSettingsKey.sidebarVisible)
    }
}
