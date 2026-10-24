import Foundation

/// A typed filesystem failure from folder discovery.
public struct FolderEnumerationError: Error, LocalizedError, Sendable, Equatable {
    public enum Operation: String, Sendable, Equatable {
        case resourceValues
        case readDirectory
        case attributes
    }

    public enum FailureClass: String, Sendable, Equatable {
        case permissionDenied
        case missing
        case transient
    }

    public let operation: Operation
    public let url: URL
    public let failureClass: FailureClass
    public let domain: String
    public let code: Int

    public init(operation: Operation, url: URL, error: any Error) {
        let nsError = error as NSError
        self.init(
            operation: operation,
            url: url,
            failureClass: Self.classify(nsError),
            domain: nsError.domain,
            code: nsError.code
        )
    }

    public init(
        operation: Operation,
        url: URL,
        failureClass: FailureClass,
        domain: String,
        code: Int
    ) {
        self.operation = operation
        self.url = url
        self.failureClass = failureClass
        self.domain = domain
        self.code = code
    }

    public var path: String { url.path }

    public var errorDescription: String? {
        "Folder enumeration failed while \(operation.rawValue) at \(path) "
            + "(class: \(failureClass.rawValue), domain: \(domain), code: \(code))"
    }

    /// Root-level access failures require the user to select the registered folder again.
    public func requiresRootAccessRenewal(for root: URL) -> Bool {
        guard failureClass == .permissionDenied || failureClass == .missing else { return false }
        return url.standardizedFileURL == root.standardizedFileURL
    }

    private static func classify(_ error: NSError) -> FailureClass {
        if error.domain == NSCocoaErrorDomain {
            if error.code == NSFileReadNoPermissionError { return .permissionDenied }
            if error.code == NSFileReadNoSuchFileError { return .missing }
        }
        if error.domain == NSPOSIXErrorDomain {
            if error.code == Int(POSIXErrorCode.EACCES.rawValue)
                || error.code == Int(POSIXErrorCode.EPERM.rawValue)
            {
                return .permissionDenied
            }
            if error.code == Int(POSIXErrorCode.ENOENT.rawValue) { return .missing }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return classify(underlying)
        }
        return .transient
    }
}

/// Recursively discovers uploadable media inside a folder.
///
/// Hidden entries and symbolic links are skipped. Package bundles are not traversed. Each directory
/// uses a stable, case-insensitive path order.
public enum FolderEnumerator {
    struct Entry: Sendable, Equatable {
        let url: URL
        let isSupported: Bool
    }

    struct Stream: AsyncSequence {
        typealias Element = Entry

        struct AsyncIterator: AsyncIteratorProtocol, Sendable {
            private let traversal: Traversal

            fileprivate init(traversal: Traversal) {
                self.traversal = traversal
            }

            func next() async throws -> Entry? {
                try Task.checkCancellation()
                let entry = try await Task.detached(priority: .utility) { [traversal] in
                    try traversal.next()
                }.value
                try Task.checkCancellation()
                return entry
            }
        }

        private let folder: URL
        private let includeHidden: Bool
        private let fileManager: FileManager

        fileprivate init(
            folder: URL,
            includeHidden: Bool,
            fileManager: FileManager
        ) {
            self.folder = folder
            self.includeHidden = includeHidden
            self.fileManager = fileManager
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(
                traversal: Traversal(
                    folder: folder,
                    includeHidden: includeHidden,
                    fileManager: fileManager
                )
            )
        }
    }

    static func stream(
        _ folder: URL,
        includeHidden: Bool = false,
        fileManager: FileManager = .default
    ) -> Stream {
        Stream(folder: folder, includeHidden: includeHidden, fileManager: fileManager)
    }

    fileprivate final class Traversal: @unchecked Sendable {
        private struct DirectoryFrame {
            let children: [URL]
            var nextIndex = 0
        }

        private let fileManager: FileManager
        private let options: FileManager.DirectoryEnumerationOptions
        private let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
        ]
        private var nextDirectory: URL?
        private var frames: [DirectoryFrame] = []

        init(folder: URL, includeHidden: Bool, fileManager: FileManager) {
            self.fileManager = fileManager
            self.options = includeHidden ? [] : [.skipsHiddenFiles]
            self.nextDirectory = folder
        }

        private let lock = NSLock()

        func next() throws -> Entry? {
            try lock.withLock { try nextLocked() }
        }

        private func nextLocked() throws -> Entry? {
            while true {
                if let directory = nextDirectory {
                    nextDirectory = nil
                    try pushDirectory(directory)
                    continue
                }
                guard !frames.isEmpty else { return nil }
                if frames[frames.count - 1].nextIndex >= frames[frames.count - 1].children.count {
                    frames.removeLast()
                    continue
                }

                let frameIndex = frames.count - 1
                let url = frames[frameIndex].children[frames[frameIndex].nextIndex]
                frames[frameIndex].nextIndex += 1
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: Set(keys))
                } catch {
                    throw FolderEnumerationError(
                        operation: .resourceValues,
                        url: url,
                        error: error
                    )
                }

                // Do not traverse package bundles or symbolic links.
                if values.isPackage == true || values.isSymbolicLink == true { continue }
                if values.isRegularFile == true {
                    return Entry(url: url, isSupported: SupportedMedia.isSupported(url))
                }
                if values.isDirectory == true {
                    try pushDirectory(url)
                }
            }
        }

        private func pushDirectory(_ directory: URL) throws {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: options
                )
            } catch {
                throw FolderEnumerationError(
                    operation: .readDirectory,
                    url: directory,
                    error: error
                )
            }
            frames.append(DirectoryFrame(children: children.sorted(by: FolderEnumerator.deterministicPathOrder)))
        }
    }

    private static func deterministicPathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        switch lhs.path.localizedCaseInsensitiveCompare(rhs.path) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.path < rhs.path
        }
    }
}
