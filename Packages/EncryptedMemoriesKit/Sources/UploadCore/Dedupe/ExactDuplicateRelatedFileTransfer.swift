import Foundation
import PhotosCore

/// Source metadata plus the SDK photo's `activeRevision.claimedSize`.
/// Missing or negative sizes and a different streamed byte count fail the copy before an upload.
public struct ExactDuplicateRelatedFileSource: Sendable {
    public let metadata: SeriesMemberSource
    public let claimedSize: Int64?

    public init(metadata: SeriesMemberSource, claimedSize: Int64?) {
        self.metadata = metadata
        self.claimedSize = claimedSize
    }
}

/// The measured size and SHA-1 of completed staging. The caller uses both to construct its upload request.
public struct ExactDuplicateStagedFile: Sendable, Equatable {
    public let fileSize: Int64
    public let sha1: Data

    public static func read(at url: URL) throws -> Self {
        do {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0
            else { throw ExactDuplicateRelatedFileTransferError.copyFailed(.staging) }
            return Self(fileSize: size, sha1: try UploadContentSHA1.digest(ofFileAt: url))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExactDuplicateRelatedFileTransferError.copyFailed(.staging)
        }
    }
}

/// Owns transient plaintext only inside the app's temp store. It never moves or trashes a remote source.
public struct ExactDuplicateRelatedFileTransfer: Sendable {
    public typealias ByteConsumer = @Sendable (Data) async throws -> Void
    private let temporaryDirectory: URL
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let networkState: @Sendable () -> LibraryNetworkState
    private let stagingIO: RelatedFileStagingIO

    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        availableCapacity: @Sendable @escaping (URL) -> Int64? = DeviceStorage.availableCapacity(at:),
        networkState: @Sendable @escaping () -> LibraryNetworkState = { LibraryRuntimeState.shared.snapshot().network }
    ) {
        self.init(
            temporaryDirectory: temporaryDirectory, availableCapacity: availableCapacity,
            networkState: networkState, stagingIO: RelatedFileStagingIO())
    }

    init(
        temporaryDirectory: URL, availableCapacity: @Sendable @escaping (URL) -> Int64?,
        networkState: @Sendable @escaping () -> LibraryNetworkState, stagingIO: RelatedFileStagingIO
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.availableCapacity = availableCapacity
        self.networkState = networkState
        self.stagingIO = stagingIO
    }

    /// Creates an exclusive destination. On success the caller owns staging until upload or explicit discard.
    public func download(
        to destination: URL, allowsExpensiveNetwork: Bool,
        source: @Sendable () async throws -> ExactDuplicateRelatedFileSource,
        stream: @Sendable (@escaping ByteConsumer) async throws -> Void
    ) async throws -> SeriesMemberSource {
        var created = false
        var writer: RelatedFileWriter?
        do {
            try Task.checkCancellation()
            guard accepts(destination) else { throw failure(.staging) }
            var entry = stat()
            let exists = lstat(destination.path, &entry) == 0
            guard !exists, errno == ENOENT else { throw failure(exists ? .destination : .staging) }
            try checkNetwork(allowsExpensiveNetwork)
            let source = try await source()
            guard let size = source.claimedSize, size >= 0 else { throw failure(.size) }
            var parentIsDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: destination.deletingLastPathComponent().path, isDirectory: &parentIsDirectory),
                parentIsDirectory.boolValue
            else { throw failure(.staging) }
            // Query every time, including empty files. An unknown answer never permits the download.
            guard let free = availableCapacity(destination.deletingLastPathComponent()) else {
                throw failure(.capacityUnknown)
            }
            guard free >= size else { throw failure(.capacity) }
            try Task.checkCancellation()
            let opened = try RelatedFileWriter(destination: destination, expectedSize: size, io: stagingIO)
            created = true
            writer = opened
            try await stream { bytes in try await opened.append(bytes) }
            try Task.checkCancellation()
            try await opened.finish()
            try Task.checkCancellation()
            return source.metadata
        } catch {
            var cleanupFailed = false
            do { try await writer?.close() } catch { cleanupFailed = true }
            if created {
                do { try discard(destination) } catch { cleanupFailed = true }
            }
            if cleanupFailed { throw failure(.cleanup) }
            throw mapped(error, allowsExpensiveNetwork: allowsExpensiveNetwork)
        }
    }

    /// Takes ownership only of regular files inside both the configured staging store and the app temp store.
    /// Attempts removal after success, failure or cancellation; an already-absent file needs no cleanup.
    /// Other cleanup failures return copyFailed(.cleanup) instead of a UID or transfer error; the file may remain.
    /// Rejected paths stay unowned and untouched.
    /// The callback reserves its network internally and attaches that reservation before invoking its transport.
    public func upload(
        _ request: PhotoUploadRequest,
        using upload: @Sendable (PhotoUploadRequest) async throws -> PhotoUID
    ) async throws -> PhotoUID {
        guard accepts(request.fileURL) else { throw failure(.staging) }
        // A directory or symlink is not an owned staged file. Do not delete it on rejection.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: request.fileURL.path) } catch {
            throw mapped(error, allowsExpensiveNetwork: request.allowsExpensiveNetwork)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure(.staging) }
        let result: Result<PhotoUID, any Error>
        do {
            try Task.checkCancellation()
            let staged = try ExactDuplicateStagedFile.read(at: request.fileURL)
            guard request.mainPhotoUID != nil, request.expectedSHA1 == staged.sha1,
                request.fileSize == staged.fileSize, request.networkReservation == nil
            else { throw failure(.integrity) }
            try checkNetwork(request.allowsExpensiveNetwork)
            try Task.checkCancellation()
            let uid = try await upload(request)
            try Task.checkCancellation()
            result = .success(uid)
        } catch {
            result = .failure(mapped(error, allowsExpensiveNetwork: request.allowsExpensiveNetwork))
        }
        do { try discard(request.fileURL) } catch { throw failure(.cleanup) }
        return try result.get()
    }

    private func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let file = url.standardizedFileURL
        let path = file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent).path
        let root = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let appTemp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") && path.hasPrefix(appTemp + "/")
    }

    private func checkNetwork(_ allowsExpensiveNetwork: Bool) throws {
        let network = networkState()
        if !allowsExpensiveNetwork && (!network.isDetermined || network.isExpensive) {
            throw ExactDuplicateRelatedFileTransferError.waitingForWiFi
        }
        guard network.isReachable else { throw failure(.transfer) }
    }

    func discard(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError
            where error.code == .fileNoSuchFile
        { return }
    }

    private func mapped(_ error: any Error, allowsExpensiveNetwork: Bool, depth: Int = 0) -> any Error {
        if Task.isCancelled || containsCancellation(error, depth: depth) { return CancellationError() }
        if let error = error as? ExactDuplicateRelatedFileTransferError { return error }
        if case UploadError.accountStorageFull = error { return failure(.accountStorage) }
        let transportCode = transportCode(of: error)
        if !allowsExpensiveNetwork,
            transportCode == NSURLErrorDataNotAllowed || (error as? URLError)?.networkUnavailableReason == .expensive
        {
            return ExactDuplicateRelatedFileTransferError.waitingForWiFi
        }
        if depth < 8, let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error {
            return mapped(underlying, allowsExpensiveNetwork: allowsExpensiveNetwork, depth: depth + 1)
        }
        return failure(.transfer)
    }

    private func containsCancellation(_ error: any Error, depth: Int) -> Bool {
        if error is CancellationError || transportCode(of: error) == NSURLErrorCancelled { return true }
        guard depth < 8, let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error else {
            return false
        }
        return containsCancellation(underlying, depth: depth + 1)
    }

    private func transportCode(of error: any Error) -> Int? {
        if case UploadError.transport(let code, _) = error { return code }
        let urlError = error as NSError
        return urlError.domain == NSURLErrorDomain ? urlError.code : nil
    }

    private func failure(
        _ reason: ExactDuplicateRelatedFileTransferError.Failure
    ) -> ExactDuplicateRelatedFileTransferError {
        .copyFailed(reason)
    }
}

/// File operations shared by shipping transfers and callers with a different filesystem implementation.
struct RelatedFileStagingIO: Sendable {
    var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    var close: @Sendable (FileHandle) throws -> Void = { try $0.close() }
}

/// Serializes bounded writes even if a transport invokes its consumer concurrently.
private actor RelatedFileWriter {
    private var handle: FileHandle?
    private let expectedSize: Int64
    private var written: Int64 = 0
    private let io: RelatedFileStagingIO

    init(destination: URL, expectedSize: Int64, io: RelatedFileStagingIO) throws {
        let descriptor = open(destination.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if error.code == .EEXIST { throw ExactDuplicateRelatedFileTransferError.copyFailed(.destination) }
            throw ExactDuplicateRelatedFileTransferError.copyFailed(
                DeviceStorage.isOutOfSpace(error) ? .capacity : .staging)
        }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.expectedSize = expectedSize
        self.io = io
    }

    func append(_ bytes: Data) throws {
        try Task.checkCancellation()
        guard let handle else { throw ExactDuplicateRelatedFileTransferError.copyFailed(.staging) }
        guard Int64(bytes.count) <= expectedSize - written else {
            throw ExactDuplicateRelatedFileTransferError.copyFailed(.size)
        }
        try performIO { try io.write(handle, bytes) }
        written += Int64(bytes.count)
    }

    func finish() throws {
        try close()
        guard written == expectedSize else { throw ExactDuplicateRelatedFileTransferError.copyFailed(.size) }
    }

    func close() throws {
        guard let handle else { return }
        self.handle = nil
        try performIO { try io.close(handle) }
    }

    private func performIO(_ operation: () throws -> Void) throws {
        do { try operation() } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExactDuplicateRelatedFileTransferError.copyFailed(
                DeviceStorage.isOutOfSpace(error) ? .capacity : .staging)
        }
    }
}
