import Foundation

/// The watched folders as a returned file sees them: the folders the app can read now, and every
/// folder the person registered, readable or not.
public struct WatchedFolderScope: Sendable, Equatable {
    /// Where one returned watched file lies.
    public enum Location: Sendable, Equatable {
        /// The file lies in a watched folder that the app can read now.
        case readable(URL)
        /// No registered folder holds the file: the folder it came from is no longer watched.
        case outside
        /// The file may lie in a registered folder that the app cannot read now, for example a
        /// folder that needs a new bookmark, or every folder after the folder backup shut down.
        case unavailable
    }

    /// Root paths of the folders the app can read now, each with a trailing slash.
    private let readableRoots: [String]
    /// Root paths of every registered folder, each with a trailing slash. Nil when a registered
    /// folder has no known path or the registry is not loaded, so no path is proven outside.
    private let registeredRoots: [String]?

    /// No folder is readable and no folder is known.
    public static let unavailable = WatchedFolderScope(readableRoots: [], registeredRoots: nil)

    /// `registered` holds the path of every registered folder, or nil when the registry could not
    /// be read. A path that is not absolute marks a folder whose location is unknown.
    public init(readable: [URL], registered: [String]?) {
        var registeredRoots: [String]?
        if let registered, registered.allSatisfy({ $0.hasPrefix("/") }) {
            registeredRoots = registered.map(Self.root)
        }
        self.init(readableRoots: readable.map { Self.root($0.path) }, registeredRoots: registeredRoots)
    }

    /// The registered folder bookmarks in a stored value. No stored value is a known empty list. A
    /// value of another type is damaged and gives nil, so no registered folder is known.
    public static func registeredBookmarks(storedValue: Any?) -> [Data]? {
        guard let storedValue else { return [] }
        return storedValue as? [Data]
    }

    private init(readableRoots: [String], registeredRoots: [String]?) {
        self.readableRoots = readableRoots
        self.registeredRoots = registeredRoots
    }

    /// The file behind a path, when it lies in a folder the app can read now.
    public func readableURL(forPath path: String) -> URL? {
        guard readableRoots.contains(where: { path.hasPrefix($0) }) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Only a path outside every known registered folder counts as outside.
    public func location(ofPath path: String) -> Location {
        if let url = readableURL(forPath: path) { return .readable(url) }
        guard let registeredRoots else { return .unavailable }
        return registeredRoots.contains(where: { path.hasPrefix($0) }) ? .unavailable : .outside
    }

    private static func root(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasSuffix("/") ? standardized : standardized + "/"
    }
}
