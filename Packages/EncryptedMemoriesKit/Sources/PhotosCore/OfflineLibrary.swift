import Foundation

/// Persisted-settings keys + defaults for the Offline Photo Library and window/sidebar chrome.
/// Centralised here (in the SDK-agnostic core) so the App glue and the test target share one
/// source of truth - UserDefaults key strings drift silently otherwise.
public enum AppSettingsKey {
    /// Removes standard GPS metadata from copies that leave the library.
    public static let removeLocationWhenSharing = "EncryptedMemories.removeLocationWhenSharing"
    /// Allows MapKit maps and Apple place lookup for library locations.
    public static let mapAndPlacesEnabled = "EncryptedMemories.mapAndPlacesEnabled"
    /// Covers app windows before the system captures an inactive preview.
    public static let blurAppPreview = "EncryptedMemories.blurAppPreview"
    /// Offline Photo Library master switch. When on, full-resolution originals viewed in the photo viewer are
    /// persisted to the encrypted on-disk `originals` cache so reopening them (even after relaunch / offline) is
    /// instant. Grid thumbnails are mandatory infrastructure and crawl independently of this toggle.
    public static let offlineLibraryEnabled = "EncryptedMemories.offlineLibraryEnabled"
    /// Whether the offline originals disk cache is unbounded (no size cap). When false, `offlineOriginalsCapGB`
    /// bounds it and the least-recently-used originals are purged once the cap is exceeded.
    public static let offlineOriginalsCapUnlimited = "EncryptedMemories.offlineOriginalsCapUnlimited"
    /// Size cap (in gigabytes) for the offline originals disk cache when bounded.
    public static let offlineOriginalsCapGB = "EncryptedMemories.offlineOriginalsCapGB"
    /// User-resizable left sidebar width (points).
    public static let sidebarWidth = "EncryptedMemories.sidebarWidth"
    /// Whether the left sidebar is visible.
    public static let sidebarVisible = "EncryptedMemories.sidebarVisible"
    /// Saved main-window frame string (NSStringFromRect).
    public static let mainWindowFrame = "EncryptedMemories.mainWindowFrame"
    /// Size of the library map when it was last shown on this device, in points ("width,height"). Its presence
    /// allows loading the map's opening area at launch; a device whose person never opened the Map loads nothing.
    public static let libraryMapViewportSize = "EncryptedMemories.libraryMapViewportSize"
    /// Records that macOS showed the Full Disk Access setup before the first folder selection.
    public static let folderBackupFullDiskAccessIntroduced =
        "EncryptedMemories.folderBackupFullDiskAccessIntroduced"
    /// Explicit iOS opt-in. The display may stay awake only while the app is foreground-active and
    /// a photo-backup pass is doing work; background execution is governed separately by BGTask.
    public static let keepDisplayAwakeDuringForegroundBackup =
        "EncryptedMemories.keepDisplayAwakeDuringForegroundBackup"
    /// Lets the backup upload on cellular data and Personal Hotspot. Viewing and downloading are not affected.
    public static let backupUsesMobileData = "EncryptedMemories.backupUsesMobileData"
}

/// Fallbacks for preferences with no stored value, including on existing installations.
/// An explicit saved choice always wins; reading a fallback does not migrate preferences.
public enum AppSettingsDefault {
    /// Remove standard GPS metadata from shared and exported copies unless explicitly disabled.
    public static let removeLocationWhenSharing = true
    /// Keep Map and Places available unless explicitly disabled.
    public static let mapAndPlacesEnabled = true
    /// Hide the iOS and iPadOS App Switcher preview unless explicitly disabled.
    public static let blurAppPreview = true
    /// Offline Photo Library is **on by default**: viewed originals are kept locally (encrypted) up to the cap.
    /// Thumbnails are always crawled while signed in, regardless of this value.
    public static let offlineLibraryEnabled = true
    /// Bounded by default (no surprise unbounded disk growth).
    public static let offlineOriginalsCapUnlimited = false
    /// Default originals-cache cap: 5 GB.
    public static let offlineOriginalsCapGB = 5.0
    /// Auto-lock remains enabled unless the user explicitly opts in for a large foreground import.
    public static let keepDisplayAwakeDuringForegroundBackup = false
    /// Wait for Wi-Fi on expensive networks unless cellular backup is explicitly enabled.
    public static let backupUsesMobileData = false
}

/// One preference gate for every backup upload on an expensive network.
public enum BackupMobileDataPolicy {
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppSettingsKey.backupUsesMobileData) != nil else {
            return AppSettingsDefault.backupUsesMobileData
        }
        return defaults.bool(forKey: AppSettingsKey.backupUsesMobileData)
    }
}

/// One preference gate for every outbound original-media copy.
public enum PrivacyExportPolicy {
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppSettingsKey.removeLocationWhenSharing) != nil else {
            return AppSettingsDefault.removeLocationWhenSharing
        }
        return defaults.bool(forKey: AppSettingsKey.removeLocationWhenSharing)
    }
}

/// One shared admission rule for every location-to-Apple consumer.
public enum MapAndPlacesPolicy {
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppSettingsKey.mapAndPlacesEnabled) != nil else {
            return AppSettingsDefault.mapAndPlacesEnabled
        }
        return defaults.bool(forKey: AppSettingsKey.mapAndPlacesEnabled)
    }

    public static func suggestionCoordinates(_ coordinates: [PhotoCoordinate], enabled: Bool) -> [PhotoCoordinate] {
        enabled ? coordinates : []
    }

    public static func allowsLocationCrawl(enabled: Bool, itemCount: Int) -> Bool {
        enabled && itemCount > 0
    }
}

/// Shared admission rule for the native iOS and iPadOS preview covers.
public enum PrivacyPreviewPolicy {
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppSettingsKey.blurAppPreview) == nil
            ? AppSettingsDefault.blurAppPreview
            : defaults.bool(forKey: AppSettingsKey.blurAppPreview)
    }

    public static func shouldCover(enabled: Bool, isSceneActive: Bool, isWindowVisible: Bool) -> Bool {
        enabled && (!isSceneActive || !isWindowVisible)
    }
}

/// Pure admission rule for the iOS idle-timer adapter. Keeping this in Core makes the three
/// required conditions independently testable without importing UIKit.
public enum BackupDisplayWakePolicy {
    public static func shouldKeepDisplayAwake(
        userOptedIn: Bool,
        applicationIsForegroundActive: Bool,
        backupIsActivelyProcessing: Bool
    ) -> Bool {
        userOptedIn && applicationIsForegroundActive && backupIsActivelyProcessing
    }
}

/// Optional backend capability: report how many photo rows the local metadata store (the SQLite
/// timeline cache) currently holds. Surfaced as "metadata rows" on the Developer/Cache page.
public protocol LibraryStatsProvider: Sendable {
    func metadataRowCount() async -> Int
}

/// Aggregated, displayable state of the on-disk offline cache. All fields are plain values so the view layer
/// and tests can use them without touching the cache actors.
public struct OfflineCacheStatus: Sendable, Equatable {
    public var offlineEnabled: Bool
    public var totalAssets: Int
    public var metadataRows: Int
    public var thumbnailsOnDisk: Int
    public var thumbnailsMissing: Int
    public var ramDecodedEstimate: Int
    public var prefetchQueueDepth: Int
    public var activePrefetchJobs: Int
    public var prefetchPausedReason: String
    public var failedThumbnailCount: Int
    public var cacheSizeBytes: Int64
    public var previewCacheSizeBytes: Int64
    /// On-disk size of the encrypted full-resolution originals cache (0 when the offline library is off / empty).
    public var originalsCacheSizeBytes: Int64
    public var lastError: String?

    public init(
        offlineEnabled: Bool = false,
        totalAssets: Int = 0,
        metadataRows: Int = 0,
        thumbnailsOnDisk: Int = 0,
        thumbnailsMissing: Int = 0,
        ramDecodedEstimate: Int = 0,
        prefetchQueueDepth: Int = 0,
        activePrefetchJobs: Int = 0,
        prefetchPausedReason: String = "none",
        failedThumbnailCount: Int = 0,
        cacheSizeBytes: Int64 = 0,
        previewCacheSizeBytes: Int64 = 0,
        originalsCacheSizeBytes: Int64 = 0,
        lastError: String? = nil
    ) {
        self.offlineEnabled = offlineEnabled
        self.totalAssets = totalAssets
        self.metadataRows = metadataRows
        self.thumbnailsOnDisk = thumbnailsOnDisk
        self.thumbnailsMissing = thumbnailsMissing
        self.ramDecodedEstimate = ramDecodedEstimate
        self.prefetchQueueDepth = prefetchQueueDepth
        self.activePrefetchJobs = activePrefetchJobs
        self.prefetchPausedReason = prefetchPausedReason
        self.failedThumbnailCount = failedThumbnailCount
        self.cacheSizeBytes = cacheSizeBytes
        self.previewCacheSizeBytes = previewCacheSizeBytes
        self.originalsCacheSizeBytes = originalsCacheSizeBytes
        self.lastError = lastError
    }

    /// Disk thumbnail coverage as a 0…1 fraction. An empty or hydrating library reports zero.
    public var thumbnailCoverage: Double {
        guard totalAssets > 0 else { return 0 }
        return min(1, Double(thumbnailsOnDisk) / Double(totalAssets))
    }

    public var totalCacheSizeBytes: Int64 { cacheSizeBytes + previewCacheSizeBytes + originalsCacheSizeBytes }
}
