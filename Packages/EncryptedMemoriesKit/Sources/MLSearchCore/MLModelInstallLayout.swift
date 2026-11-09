import Foundation

/// On-disk layout of all Smart Search state for one account.
///
/// Everything Smart Search persists lives under one root directory:
///
/// ```
/// <root>/                            (e.g. …/Application Support/EncryptedMemories/<uid>/SmartSearch)
///   state.json                       lifecycle state (enabled, selection, journal)
///   ml-search-index-v1.sqlite(+wal/shm)  encrypted vector index
///   models/<modelID>/<revision>/     verified installed artifacts + install.json
///   runtime-cache/<modelID>/<revision>/ generated Core ML files that are rebuilt before use
///   tmp/                             partial downloads and staging dirs
/// ```
///
/// Purge deletes the root recursively. The single-root invariant is what makes "no known ML
/// artifact remains" provable. Nothing outside the root may ever be written by Smart Search,
/// and nothing inside it is shared with any other subsystem.
public struct MLModelInstallLayout: Sendable, Equatable {
    public static let installRecordFileName = "install.json"
    public static let stateFileName = "state.json"

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var stateFileURL: URL { rootDirectory.appendingPathComponent(Self.stateFileName) }
    public var modelsDirectory: URL { rootDirectory.appendingPathComponent("models", isDirectory: true) }
    public var runtimeCacheDirectory: URL {
        rootDirectory.appendingPathComponent("runtime-cache", isDirectory: true)
    }
    public var temporaryDirectory: URL { rootDirectory.appendingPathComponent("tmp", isDirectory: true) }
    public var indexDatabaseURL: URL { rootDirectory.appendingPathComponent(SQLiteMLIndexStore.databaseFileName) }
    public var derivedIndexDatabaseURL: URL {
        rootDirectory.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
    }

    /// SQLite sidecar files that must be part of any purge inventory.
    public var indexDatabaseFileURLs: [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: indexDatabaseURL.path + $0) }
    }

    public func modelDirectory(for id: MLModelID) -> URL {
        modelsDirectory.appendingPathComponent(safePathComponent(id.rawValue), isDirectory: true)
    }

    public func installDirectory(for id: MLModelID, revision: String) -> URL {
        modelDirectory(for: id).appendingPathComponent(safePathComponent(revision), isDirectory: true)
    }

    public func installRecordURL(for id: MLModelID, revision: String) -> URL {
        installDirectory(for: id, revision: revision).appendingPathComponent(Self.installRecordFileName)
    }

    public func runtimeCacheDirectory(for id: MLModelID, revision: String) -> URL {
        runtimeCacheModelDirectory(for: id)
            .appendingPathComponent(safePathComponent(revision), isDirectory: true)
    }

    public func runtimeCacheModelDirectory(for id: MLModelID) -> URL {
        runtimeCacheDirectory.appendingPathComponent(safePathComponent(id.rawValue), isDirectory: true)
    }

    /// Staging directory an install is assembled in before its atomic promotion.
    public func stagingDirectory(for id: MLModelID, revision: String) -> URL {
        temporaryDirectory.appendingPathComponent(
            "staging-\(safePathComponent(id.rawValue))-\(safePathComponent(revision))",
            isDirectory: true
        )
    }

    public func stagingDirectories(for id: MLModelID) -> [URL] {
        let prefix = "staging-\(safePathComponent(id.rawValue))-"
        let urls = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls?.filter { $0.lastPathComponent.hasPrefix(prefix) } ?? []
    }

    /// `true` iff `path` is a safe install-relative path: non-empty, relative, and free of
    /// `.`/`..` components. Manifest file names must pass this before touching the filesystem.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Flattens an identifier into one path component. Dots are not preserved because `.` and
    /// `..` have path semantics even when Foundation receives them as one component.
    private func safePathComponent(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }
}
