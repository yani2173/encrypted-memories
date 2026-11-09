import Foundation

/// Streams supported files as backup candidates. The platform layer owns sandbox access for the
/// complete scan. A changed file modification date requires another content check.
public struct FolderBackupCatalog: UploadBackupAssetCatalog {
    public let folder: URL
    public let includeHidden: Bool
    let readAttributes: AttributeReader

    /// Reads the file attributes of one path.
    typealias AttributeReader = @Sendable (String) throws -> [FileAttributeKey: Any]

    public init(folder: URL, includeHidden: Bool = false) {
        self.init(folder: folder, includeHidden: includeHidden, readAttributes: Self.readAttributes(atPath:))
    }

    init(folder: URL, includeHidden: Bool, readAttributes: @escaping AttributeReader) {
        self.folder = folder
        self.includeHidden = includeHidden
        self.readAttributes = readAttributes
    }

    public func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        let readAttributes = readAttributes
        let iterator = FolderEnumerator.stream(
            folder,
            includeHidden: includeHidden
        ).makeAsyncIterator()
        return AsyncThrowingStream(unfolding: {
            while let entry = try await iterator.next() {
                try Task.checkCancellation()
                if entry.isSupported {
                    do {
                        return try Self.candidate(for: entry.url, readAttributes: readAttributes)
                    } catch {
                        if try FolderEnumerator.skipUnreadableEntry(error, in: entry.parent) { continue }
                        throw error
                    }
                }
            }
            return nil
        })
    }

    /// Creates one candidate from one file and reports attribute failures to the caller.
    public static func candidate(for url: URL) throws -> UploadBackupAssetCandidate {
        try candidate(for: url, readAttributes: readAttributes(atPath:))
    }

    @Sendable
    private static func readAttributes(atPath path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }

    static func candidate(
        for url: URL,
        readAttributes: AttributeReader
    ) throws -> UploadBackupAssetCandidate {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try readAttributes(url.path)
        } catch {
            throw FolderEnumerationError(
                operation: .attributes,
                url: url,
                error: error
            )
        }
        guard let modified = attributes[.modificationDate] as? Date else {
            throw FolderEnumerationError(
                operation: .attributes,
                url: url,
                failureClass: .transient,
                domain: "EncryptedMemories.FolderEnumeration",
                code: 1
            )
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let snapshot = UploadBackupAssetSnapshot(
            source: .file(url),
            revision: UploadBackupRevision(date: modified),
            editRevision: .unavailable,
            resourceCount: 1
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: url.lastPathComponent,
            byteCount: size
        )
    }

    /// Why one watched file does not enter the backup queue on return.
    public enum ReturnOutcome {
        /// The file is no longer on disk. It needs no backup and counts as done.
        case gone
        /// The file exists, but its attributes cannot be read. Its queue duty is owed.
        case unreadable(FolderEnumerationError.FailureClass)
        /// The file exists and its candidate enters the queue.
        case readable(UploadBackupAssetCandidate)
    }

    /// The one decision whether a watched file counts as returned: a file that is gone is done,
    /// a file whose attributes cannot be read is not.
    public static func returnOutcome(for url: URL) -> ReturnOutcome {
        do {
            return .readable(try candidate(for: url))
        } catch {
            let failure =
                error as? FolderEnumerationError
                ?? FolderEnumerationError(operation: .attributes, url: url, error: error)
            return failure.failureClass == .missing ? .gone : .unreadable(failure.failureClass)
        }
    }

    /// What a batch of returned watched files did.
    public struct ReturnBatch: Sendable, Equatable {
        /// The paths that count as returned: gone, outside every registered folder, or submitted
        /// to the queue. Every other path keeps its queue duty.
        public let returnedPaths: Set<String>
        /// How many files were submitted to the queue. The queue itself may still drop a row,
        /// for example an excluded source or a dismissed recheck, so this does not promise the
        /// row survived.
        public let queuedCount: Int

        public init(returnedPaths: Set<String>, queuedCount: Int) {
            self.returnedPaths = returnedPaths
            self.queuedCount = queuedCount
        }
    }

    /// Returns excluded watched files to the backup queue. A file outside every registered folder
    /// and a file that is gone need nothing and count as done. A file in a folder the app cannot
    /// read now, and a file whose attributes cannot be read, do not count as returned, so their
    /// queue duty stays with the coordinator. Readable files are enqueued even when another file
    /// of the batch could not be read. When the queue refuses the batch, no file counts as returned.
    public static func returnToBackup(
        paths: [String],
        scope: WatchedFolderScope,
        engine: UploadBackupSyncEngine
    ) async -> ReturnBatch {
        var candidates: [UploadBackupAssetCandidate] = []
        var returned = Set<String>()
        var queuedPaths = Set<String>()
        for path in paths {
            let url: URL
            switch scope.location(ofPath: path) {
            case .outside:
                returned.insert(path)
                continue
            case .unavailable: continue
            case .readable(let readable): url = readable
            }
            switch returnOutcome(for: url) {
            case .gone: returned.insert(path)
            case .unreadable: continue
            case .readable(let candidate):
                candidates.append(candidate)
                queuedPaths.insert(path)
            }
        }
        guard !candidates.isEmpty else { return ReturnBatch(returnedPaths: returned, queuedCount: 0) }
        do {
            _ = try await engine.enqueueBatch(candidates)
        } catch {
            return ReturnBatch(returnedPaths: [], queuedCount: 0)
        }
        return ReturnBatch(returnedPaths: returned.union(queuedPaths), queuedCount: candidates.count)
    }
}
