import Foundation
import OSLog

/// One-time cold-launch removal of the system URL cache and cookie file that the SDK network client
/// wrote before it switched to an ephemeral session (#605). Nothing ever read them.
///
/// The purge never lists either container. It removes only the literal names below, directly inside
/// `Library/Caches/<bundle id>` and `Library/Cookies`. It refuses symbolic links at or below the
/// trusted app-container boundary. Every other entry stays, including the Core ML compile cache and app caches.
/// On macOS it runs only inside the app's sandbox container, where `Library/Cookies` is the app's own.
public enum UnusedNetworkStorePurge {
    static let completedKey = "network.unusedStorePurged.v1"
    static let urlCacheEntryNames = ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"]
    static let cookieFileName = "Cookies.binarycookies"
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "NetworkStorePurge")
    #if os(macOS)
        static let requiresSandboxContainer = true
    #else
        static let requiresSandboxContainer = false
    #endif

    /// The app's own Library, Caches directory and bundle identifier.
    public struct Location: Sendable, Equatable {
        let libraryDirectory: URL
        let cachesDirectory: URL
        let bundleIdentifier: String

        /// Resolved from the system search paths; nil when the system reports none.
        public static var current: Location? {
            let fm = FileManager.default
            guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first,
                let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
                let bundleIdentifier = Bundle.main.bundleIdentifier
            else { return nil }
            return Location(libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)
        }
    }

    public struct Result: Sendable, Equatable {
        public let removed: [URL]
        public let failed: [URL]

        public var succeeded: Bool { failed.isEmpty }
    }

    /// Runs the purge unless an earlier launch completed it. Returns nil when it did not run.
    /// Any failure leaves the completion flag unset, so the next cold launch tries again.
    @discardableResult
    public static func purgeOnce(defaults: UserDefaults = .standard, location: Location? = .current) -> Result? {
        purge(defaults: defaults, location: location, honorCompletedFlag: true)
    }

    /// Explicit sign-out verifies the named stores even after a completed startup purge.
    /// A refused location or a failed verification cannot count as successful sign-out.
    @discardableResult
    public static func purgeForSignOut(defaults: UserDefaults = .standard, location: Location? = .current) -> Result? {
        purge(defaults: defaults, location: location, honorCompletedFlag: false)
    }

    private static func purge(defaults: UserDefaults, location: Location?, honorCompletedFlag: Bool) -> Result? {
        guard let location else {
            if !honorCompletedFlag { defaults.removeObject(forKey: completedKey) }
            return nil
        }
        return purgeOnce(
            defaults: defaults,
            libraryDirectory: location.libraryDirectory,
            cachesDirectory: location.cachesDirectory,
            bundleIdentifier: location.bundleIdentifier,
            honorCompletedFlag: honorCompletedFlag,
            removeItem: { try TransientPlaintextPurge.removeWithoutFollowingLinks(at: $0, boundary: $0) }
        )
    }

    static func purgeOnce(
        defaults: UserDefaults,
        libraryDirectory: URL,
        cachesDirectory: URL,
        bundleIdentifier: String,
        requiresSandboxContainer: Bool = Self.requiresSandboxContainer,
        honorCompletedFlag: Bool = true,
        removeItem: (URL) throws -> Void
    ) -> Result? {
        guard !honorCompletedFlag || !defaults.bool(forKey: completedKey) else { return nil }
        defaults.removeObject(forKey: completedKey)
        // Both containers must sit in the app's own Library.
        guard
            !requiresSandboxContainer
                || isSandboxContainerLibrary(libraryDirectory, bundleIdentifier: bundleIdentifier),
            cachesDirectory.standardizedFileURL.deletingLastPathComponent().path
                == libraryDirectory.standardizedFileURL.path
        else { return nil }

        let trustedBoundary =
            requiresSandboxContainer
            ? libraryDirectory.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
            : libraryDirectory.standardizedFileURL.deletingLastPathComponent()
        var removed: [URL] = []
        var failed: [URL] = []
        let containers: [(parent: URL, name: String, entries: [String])] = [
            (cachesDirectory, bundleIdentifier, urlCacheEntryNames),
            (libraryDirectory, "Cookies", [cookieFileName]),
        ]
        for (parent, name, entries) in containers {
            let parent = parent.standardizedFileURL
            let container = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            // A name with `/` or `..` would leave the search-path directory.
            guard container.deletingLastPathComponent().path == parent.path, container.lastPathComponent == name else {
                failed.append(container)
                continue
            }
            let checkedContainer: URL
            do {
                guard let admitted = try checkedDirectory(container, within: trustedBoundary) else { continue }
                checkedContainer = admitted
            } catch {
                failed.append(container)
                continue
            }
            for entry in entries {
                let target = checkedContainer.appendingPathComponent(entry).standardizedFileURL
                do {
                    guard try itemState(at: target) != .missing else { continue }
                    // The postcondition decides success, including an entry removed before an error.
                    try? removeItem(target)
                    if try itemState(at: target) == .missing {
                        removed.append(target)
                    } else {
                        failed.append(target)
                    }
                } catch {
                    failed.append(target)
                }
            }
        }
        if failed.isEmpty {
            defaults.set(true, forKey: completedKey)
        } else {
            defaults.removeObject(forKey: completedKey)
            logger.error("Could not remove \(failed.count) unused network store entries; retrying at next launch.")
        }
        return Result(removed: removed, failed: failed)
    }

    /// iOS apps always run in their own container. A macOS app outside its own sandbox container
    /// (`Containers/<bundle id>/Data/Library`) shares `Library/Cookies` with other apps,
    /// so the purge must not run there.
    static func isSandboxContainerLibrary(_ library: URL, bundleIdentifier: String) -> Bool {
        let library = library.standardizedFileURL
        let data = library.deletingLastPathComponent()
        let container = data.deletingLastPathComponent()
        return library.lastPathComponent == "Library"
            && data.lastPathComponent == "Data"
            && container.lastPathComponent == bundleIdentifier
            && container.deletingLastPathComponent().lastPathComponent == "Containers"
    }

    /// Resolve aliases only above the admitted app-container boundary. Every component below it
    /// must be a directory entry, so a static ancestor link cannot redirect the literal deletion set.
    /// This check does not prevent concurrent replacement of an admitted filesystem entry.
    private static func checkedDirectory(_ directory: URL, within boundary: URL) throws -> URL? {
        guard directory.path.hasPrefix(boundary.path + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        switch try itemState(at: boundary) {
        case .missing: return nil
        case .directory: break
        case .other: throw CocoaError(.fileReadInvalidFileName)
        }
        var current = boundary.resolvingSymlinksInPath()
        for component in directory.pathComponents.dropFirst(boundary.pathComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            switch try itemState(at: current) {
            case .missing: return nil
            case .directory: break
            case .other: throw CocoaError(.fileReadInvalidFileName)
            }
        }
        return current
    }

    private static func itemState(at url: URL) throws -> LocalPurgeItemState {
        try LocalPurgeItemState.read(at: url)
    }
}

/// A successful metadata read means present. Only a missing-file error proves absence.
/// Unknown types remain other; they never become an eligible container directory.
enum LocalPurgeItemState {
    case missing, directory, other

    static func read(at url: URL) throws -> Self {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType == .typeDirectory ? .directory : .other
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return .missing
        }
    }
}
