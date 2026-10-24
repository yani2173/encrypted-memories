import Foundation
import MLSearchCore

#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore
#endif

public enum MLArtifactTransportError: Error, Equatable {
    case httpStatus(Int)
    case notHTTPS
    case invalidContentRange
    case rangeUnsupported
    case responseTooLarge
    case responseTooSmall
    case unexpectedResponseURL
}

/// Resumable HTTPS transport for immutable model artifacts.
///
/// Transfers bounded ranges into an installer-owned partial file. A suspended app resumes at
/// the exact byte boundary without retaining a model-sized `Data` value in memory.
public struct URLSessionMLModelArtifactTransport: MLModelArtifactTransport {
    #if ENCRYPTED_MEMORIES_UPGRADE_TEST
        private static let chunkByteCount: Int64 = 8192
    #else
        private static let chunkByteCount: Int64 = 8 << 20
    #endif
    private let downloadClient: RangeDownloadClient

    public init(session: URLSession = MLModelNetworkSession.shared) {
        self.downloadClient = RangeDownloadClient(configuration: session.configuration)
    }

    /// The configuration of the session that performs the downloads.
    var downloadConfiguration: URLSessionConfiguration { downloadClient.configuration }

    public func download(
        from url: URL,
        to destination: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            guard UpgradeTestProbe.isLoopback(url) else { throw MLArtifactTransportError.notHTTPS }
        #else
            guard url.scheme?.lowercased() == "https" else { throw MLArtifactTransportError.notHTTPS }
        #endif
        guard expectedByteCount > 0 else { throw MLArtifactTransportError.responseTooSmall }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var offset = Self.fileSize(at: destination)
        if offset > expectedByteCount {
            try? fm.removeItem(at: destination)
            offset = 0
        }
        await progress(offset, expectedByteCount)

        while offset < expectedByteCount {
            try Task.checkCancellation()
            let end = min(expectedByteCount - 1, offset + Self.chunkByteCount - 1)
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            MLModelRequestIdentity.apply(to: &request)

            let (temporaryURL, response) = try await downloadClient.download(
                for: request,
                startingOffset: offset,
                expectedByteCount: expectedByteCount,
                progress: progress
            )
            defer { try? fm.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard MLModelRequestIdentity.isExactEndpoint(http.url, expected: url) else {
                throw MLArtifactTransportError.unexpectedResponseURL
            }

            switch http.statusCode {
            case 206:
                guard let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                    range.start == offset,
                    range.end >= range.start,
                    range.total == expectedByteCount,
                    range.end < expectedByteCount,
                    range.end - range.start + 1 <= end - offset + 1
                else {
                    throw MLArtifactTransportError.invalidContentRange
                }
                let received = Self.fileSize(at: temporaryURL)
                guard received > 0,
                    received == range.end - range.start + 1,
                    Self.contentLength(http.value(forHTTPHeaderField: "Content-Length")) == nil
                        || Self.contentLength(http.value(forHTTPHeaderField: "Content-Length")) == received,
                    offset + received <= expectedByteCount
                else {
                    throw MLArtifactTransportError.invalidContentRange
                }
                try Self.append(temporaryURL, to: destination)
                offset += received
                #if ENCRYPTED_MEMORIES_UPGRADE_TEST
                    UpgradeTestProbe.checkpoint("model.partial")
                #endif

            case 200 where offset == 0:
                let received = Self.fileSize(at: temporaryURL)
                guard received > 0, received == expectedByteCount else {
                    throw received > expectedByteCount
                        ? MLArtifactTransportError.responseTooLarge
                        : MLArtifactTransportError.responseTooSmall
                }
                if let contentLength = Self.contentLength(http.value(forHTTPHeaderField: "Content-Length")),
                    contentLength != received
                {
                    throw MLArtifactTransportError.responseTooSmall
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: temporaryURL, to: destination)
                applyLocalFileProtection(to: destination)
                offset = received
            case 200:
                // Do not keep both a partial and a full fallback response. Discard the partial;
                // the next retry starts cleanly against a server without Range support.
                try? fm.removeItem(at: destination)
                throw MLArtifactTransportError.rangeUnsupported
            default:
                throw MLArtifactTransportError.httpStatus(http.statusCode)
            }
            applyLocalFileProtection(to: destination)
            await progress(offset, expectedByteCount)
        }
    }

    private static func append(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.seekToEnd()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try output.write(contentsOf: data)
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let components = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            let dash = components[0].firstIndex(of: "-"),
            let start = Int64(components[0][..<dash]),
            let end = Int64(components[0][components[0].index(after: dash)...]),
            let total = Int64(components[1])
        else { return nil }
        return (start, end, total)
    }

    private static func contentLength(_ value: String?) -> Int64? {
        guard let value, let length = Int64(value), length >= 0 else { return nil }
        return length
    }

    /// Model weights are public, but user-selected downloads should remain unavailable before
    /// first unlock on devices that support file protection classes.
    private func applyLocalFileProtection(to url: URL) {
        #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }
}

/// Serializes progress callbacks for one range. URLSession's delegate queue is ordered, but the
/// shared Core callback is async; chaining tasks preserves monotonic delivery across that hop.
private final class RangeProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let startingOffset: Int64
    private let expectedByteCount: Int64
    private let progress: @Sendable (Int64, Int64?) async -> Void
    private var highestResponseByteCount: Int64 = -1
    private var tail = Task<Void, Never> {}

    init(
        startingOffset: Int64,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) {
        self.startingOffset = startingOffset
        self.expectedByteCount = expectedByteCount
        self.progress = progress
    }

    func enqueue(responseByteCount: Int64) -> Task<Void, Never> {
        lock.withLock {
            let boundedResponseBytes = max(0, responseByteCount)
            guard boundedResponseBytes > highestResponseByteCount else { return tail }
            highestResponseByteCount = boundedResponseBytes
            let cumulativeBytes = min(expectedByteCount, startingOffset + boundedResponseBytes)
            let previous = tail
            let progress = self.progress
            tail = Task {
                await previous.value
                await progress(cumulativeBytes, expectedByteCount)
            }
            return tail
        }
    }
}

/// Owns the classic URLSession download-task bridge. Unlike the async convenience return value,
/// its download delegate receives periodic byte callbacks while Foundation writes to disk.
private final class RangeDownloadClient: @unchecked Sendable {
    private let delegate: RangeDownloadSessionDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        let delegate = RangeDownloadSessionDelegate()
        let queue = OperationQueue()
        queue.name = "EncryptedMemories.MLModelRangeDownload"
        queue.maxConcurrentOperationCount = 1
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    var configuration: URLSessionConfiguration { session.configuration }

    deinit {
        session.invalidateAndCancel()
    }

    func download(
        for request: URLRequest,
        startingOffset: Int64,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(
                    task: task,
                    startingOffset: startingOffset,
                    expectedByteCount: expectedByteCount,
                    progress: progress,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class RangeDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private final class PendingDownload: @unchecked Sendable {
        let continuation: CheckedContinuation<(URL, URLResponse), any Error>
        let reporter: RangeProgressReporter
        var downloadedURL: URL?
        var fileError: (any Error)?

        init(
            continuation: CheckedContinuation<(URL, URLResponse), any Error>,
            reporter: RangeProgressReporter
        ) {
            self.continuation = continuation
            self.reporter = reporter
        }
    }

    private let lock = NSLock()
    private var pending: [Int: PendingDownload] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func register(
        task: URLSessionDownloadTask,
        startingOffset: Int64,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void,
        continuation: CheckedContinuation<(URL, URLResponse), any Error>
    ) {
        let reporter = RangeProgressReporter(
            startingOffset: startingOffset,
            expectedByteCount: expectedByteCount,
            progress: progress
        )
        lock.withLock {
            pending[task.taskIdentifier] = PendingDownload(
                continuation: continuation,
                reporter: reporter
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let download = lock.withLock { pending[downloadTask.taskIdentifier] }
        _ = download?.reporter.enqueue(responseByteCount: totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let download = lock.withLock({ pending[downloadTask.taskIdentifier] }) else { return }
        let ownedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("encryptedmemories-ml-range-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: ownedURL)
            download.downloadedURL = ownedURL
        } catch {
            download.fileError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let download = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        let finalReport = download.reporter.enqueue(responseByteCount: task.countOfBytesReceived)
        let response = task.response
        Task {
            await finalReport.value
            if let error {
                if let downloadedURL = download.downloadedURL {
                    try? FileManager.default.removeItem(at: downloadedURL)
                }
                if (error as? URLError)?.code == .cancelled {
                    download.continuation.resume(throwing: CancellationError())
                } else {
                    download.continuation.resume(throwing: error)
                }
            } else if let fileError = download.fileError {
                download.continuation.resume(throwing: fileError)
            } else if let downloadedURL = download.downloadedURL, let response {
                download.continuation.resume(returning: (downloadedURL, response))
            } else {
                download.continuation.resume(throwing: URLError(.unknown))
            }
        }
    }
}

/// Default catalogs use this session for the process lifetime; production never invalidates it.
/// Artifact transports copy its configuration into their owned download sessions.
/// Keep no URL cache; ephemeral cookies and credentials remain in memory only.
public enum MLModelNetworkSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
