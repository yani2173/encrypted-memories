import Foundation

/// The one free-space query of the app. It reports space for work the person asked for, so purgeable
/// system data counts as free.
public enum DeviceStorage {
    public static func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// True when the volume that holds `url` has no free block for an ordinary process (`statfs` `f_bavail == 0`),
    /// `nil` when the volume cannot be queried. `availableCapacity` cannot answer this: it counts purgeable space as
    /// free, while a write fails as soon as the volume has no free block left.
    public static func volumeHasNoFreeBlocks(at url: URL) -> Bool? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return info.f_bavail == 0
    }

    /// True when a write failed because the volume is full, also when the error wraps the file-system error.
    public static func isOutOfSpace(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return true }
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) || nsError.code == Int(EDQUOT) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error else { return false }
        return isOutOfSpace(underlying)
    }
}

/// How full the device is. Optional caches stop growing at `low`; at `critical` they are cleared and
/// automatic work that writes large data pauses.
public enum LibraryStoragePressure: Int, Sendable, Equatable {
    case normal
    case low
    case critical

    private static let lowThreshold: Int64 = 2 << 30
    private static let criticalThreshold: Int64 = 512 << 20
    private static let recoveryMargin: Int64 = 256 << 20

    /// A level is left only after a margin above its threshold, so a device near a threshold does not flap.
    /// An unknown capacity keeps the previous level.
    public static func next(after previous: Self, availableBytes: Int64?) -> Self {
        guard let availableBytes else { return previous }
        if availableBytes < criticalThreshold { return .critical }
        if previous == .critical, availableBytes < criticalThreshold + recoveryMargin { return .critical }
        if availableBytes < lowThreshold { return .low }
        if previous != .normal, availableBytes < lowThreshold + recoveryMargin { return .low }
        return .normal
    }

    public func permitsDiskWrite(for cache: LibraryDiskCacheKind) -> Bool {
        switch self {
        case .normal: true
        case .low: cache == .thumbnail
        case .critical: false
        }
    }
}

/// Disk caches by importance. Grid thumbnails are the only cache the library needs to stay usable.
public enum LibraryDiskCacheKind: Sendable, Equatable {
    case thumbnail
    case preview
    case original
    case video

    public var evictsOnCritical: Bool { self != .thumbnail }
}
