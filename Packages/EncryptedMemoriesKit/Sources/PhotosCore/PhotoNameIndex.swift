import Foundation

/// The one text folding of library search: case and diacritics fold with a fixed locale, so a query and the text it
/// searches compare the same way on every device.
public enum SearchTextNormalization {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).lowercased()
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
}

/// The decrypted file names of the library, normalized for search. Memory only: the names on disk stay sealed in
/// `PhotoNameStore`.
///
/// Names are keyed by a process-local hash of the photo identity, so the index holds no copy of the long node and
/// volume identifiers. Most camera names fit into a small inline string, which keeps one entry to a few dozen bytes.
/// Two values are equal when they share a revision and storage; comparing them never walks the names.
public struct PhotoNameIndex: Sendable, Hashable {
    private final class Storage: Sendable {
        let names: [Int: String]
        let onLookup: (@Sendable () -> Void)?

        init(names: [Int: String], onLookup: (@Sendable () -> Void)?) {
            self.names = names
            self.onLookup = onLookup
        }
    }

    public let revision: UInt64
    private let storage: Storage

    public static let empty = PhotoNameIndex(normalizedNames: [:], revision: 0)

    /// Builds an index from decrypted names. Empty names stay out: they mark a photo whose name is known to be
    /// unreadable.
    public init(names: [PhotoUID: String], revision: UInt64) {
        var normalized = [Int: String](minimumCapacity: names.count)
        for (uid, name) in names where !name.isEmpty {
            normalized[Self.key(uid)] = SearchTextNormalization.normalize(name)
        }
        self.init(normalizedNames: normalized, revision: revision)
    }

    init(normalizedNames: [Int: String], revision: UInt64, onLookup: (@Sendable () -> Void)? = nil) {
        self.revision = revision
        storage = Storage(names: normalizedNames, onLookup: onLookup)
    }

    /// Test seam: the same names, with a callback for every lookup, so a test can count the work of one search.
    package func observingLookups(_ onLookup: @escaping @Sendable () -> Void) -> PhotoNameIndex {
        PhotoNameIndex(normalizedNames: storage.names, revision: revision, onLookup: onLookup)
    }

    public var count: Int { storage.names.count }
    public var isEmpty: Bool { storage.names.isEmpty }

    /// The normalized name of `uid`, or nil when the name is unknown.
    public func normalizedName(of uid: PhotoUID) -> String? {
        storage.onLookup?()
        return storage.names[Self.key(uid)]
    }

    static func key(_ uid: PhotoUID) -> Int { uid.hashValue }

    public static func == (lhs: PhotoNameIndex, rhs: PhotoNameIndex) -> Bool {
        lhs.revision == rhs.revision && lhs.storage === rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(revision)
        hasher.combine(ObjectIdentifier(storage))
    }
}

/// Optional backend capability: the file name index of the open library, for search. A screen calls
/// `endPhotoNameSearch()` when its query ends, so no decrypted names stay in memory outside a search.
public protocol PhotoNameSearchProvider: Sendable {
    func photoNameIndex() async -> PhotoNameIndex
    func endPhotoNameSearch() async
}
