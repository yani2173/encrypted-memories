import Foundation

/// Cold-launch cleanup for plaintext created solely for the system share sheet.
///
/// The purge is deliberately incapable of accepting an arbitrary deletion target: it always appends
/// the literal `ShareExports` child to the supplied temporary directory, verifies containment, and
/// removes directory entries without traversing symbolic links.
public enum TransientPlaintextPurge {
    public struct Result: Sendable, Equatable {
        public let directory: URL
        public let succeeded: Bool

        public init(directory: URL, succeeded: Bool) {
            self.directory = directory
            self.succeeded = succeeded
        }
    }

    @discardableResult
    public static func purgeShareExports(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Result {
        let parent = temporaryDirectory.standardizedFileURL
        let directory = parent.appendingPathComponent("ShareExports", isDirectory: true).standardizedFileURL
        guard directory.lastPathComponent == "ShareExports",
            directory.deletingLastPathComponent().standardizedFileURL == parent
        else {
            return Result(directory: directory, succeeded: false)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return Result(directory: directory, succeeded: true)
        }
        do {
            try removeWithoutFollowingLinks(at: directory, boundary: directory)
            return Result(
                directory: directory,
                succeeded: !FileManager.default.fileExists(atPath: directory.path)
            )
        } catch {
            return Result(directory: directory, succeeded: false)
        }
    }

    static func removeWithoutFollowingLinks(at url: URL, boundary: URL) throws {
        let standardized = url.standardizedFileURL
        let boundaryPath = boundary.standardizedFileURL.path
        let path = standardized.path
        guard path == boundaryPath || path.hasPrefix(boundaryPath + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let values = try standardized.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true || values.isDirectory != true {
            try FileManager.default.removeItem(at: standardized)
            return
        }

        for child in try FileManager.default.contentsOfDirectory(
            at: standardized,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) {
            try removeWithoutFollowingLinks(at: child, boundary: boundary)
        }
        try FileManager.default.removeItem(at: standardized)
    }
}
