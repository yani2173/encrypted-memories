import CoreGraphics
import Foundation
import ImageIO
import PhotosCore

private enum SequentialStreamControl: Error {
    case consumerFinished
}

/// Which of the producer and the decoder of one streamed decode finished first. A producer that the finished decoder
/// stopped reports no error.
private final class StreamRace: @unchecked Sendable {
    private let lock = NSLock()
    private var producerDone = false
    private var stoppedProducerAfterDecode = false
    private var reportedError: (any Error)?

    var producerError: (any Error)? { lock.withLock { reportedError } }

    func producerFinished(_ error: (any Error)?) {
        lock.withLock {
            producerDone = true
            if !stoppedProducerAfterDecode { reportedError = error }
        }
    }

    /// True when the producer still runs, so the decode stops it.
    func decoderFinished() -> Bool {
        lock.withLock {
            guard !producerDone else { return false }
            stoppedProducerAfterDecode = true
            return true
        }
    }
}

private func viewerSequentialGetBytes(
    _ info: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutableRawPointer,
    _ count: Int
) -> Int {
    guard let info else { return 0 }
    return Unmanaged<ViewerFullImageDecoder.SequentialByteQueue>.fromOpaque(info).takeUnretainedValue().read(
        into: buffer,
        count: count
    )
}

public enum ViewerFullImageDecoder {
    /// Decodes image bytes into a ready-to-upload/draw `CGImage`, optionally bounded to a maximum longest-side
    /// pixel size.
    ///
    /// `kCGImageSourceShouldCacheImmediately` forces rasterization during this call, so platform adapters can run
    /// it off the main actor and avoid a lazy decode during first draw. `kCGImageSourceCreateThumbnailWithTransform`
    /// bakes EXIF orientation.
    ///
    /// - Parameter maxPixelSize: when non-nil, the longest side is capped at `min(maxPixelSize, originalLongest)`
    ///   - the memory-bounded viewer display decode (screen-sized), so a huge original never decodes into a giant
    ///   image just because a page appeared. When nil (the default), the original pixel dimensions are preserved -
    ///   the full-quality path used for zoom/export.
    public static func decodeCGImage(_ data: Data, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize)
    }

    /// Decodes a streamed original through a bounded sequential data provider. Producer backpressure suspends
    /// asynchronously, while the blocking ImageIO consumer stays on a dedicated non-cooperative executor. The
    /// caller never aggregates the complete plaintext file in `Data`.
    public static func decodeStreamedCGImage(
        from provider: any OriginalByteStreamProvider,
        uid: PhotoUID,
        maxPixelSize: Int? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> CGImage? {
        let queue = SequentialByteQueue()
        let decoderResult = DecoderResultBox()
        streamingDecodeQueue.async {
            let result = Result {
                try Self.decodeFromSequentialProvider(queue: queue, maxPixelSize: maxPixelSize)
            }
            queue.consumerDidFinish()
            decoderResult.resolve(result)
        }

        // The producer and the decoder run as unstructured tasks that this call joins before it returns. A task group
        // child that catches the producer's error could complete into a destroyed group in Swift 6.4 optimized builds.
        let race = StreamRace()
        let producer = Task {
            try await provider.streamOriginalBytes(
                for: uid,
                onChunk: { try await queue.append($0) },
                onProgress: onProgress
            )
            queue.producerDidFinish()
        }
        let producerEnd = Task {
            race.producerFinished(Self.producerError(of: await producer.result, queue: queue))
        }
        let decoderEnd = Task {
            let result = await decoderResult.value()
            // The decoder can finish before the provider emits every byte; the producer then stops.
            if race.decoderFinished() { producer.cancel() }
            return result
        }

        let decoderOutcome = await withTaskCancellationHandler(
            operation: {
                await producerEnd.value
                return await decoderEnd.value
            },
            onCancel: {
                queue.cancel()
                producer.cancel()
            })
        if let producerError = race.producerError { throw producerError }
        try Task.checkCancellation()
        return try decoderOutcome.get()
    }

    /// The error of a finished producer that the decode reports. A consumer that finished early is no failure. A failure
    /// reaches the queue at once, so the blocking ImageIO consumer ends.
    private static func producerError(of result: Result<Void, any Error>, queue: SequentialByteQueue) -> (any Error)? {
        switch result {
        case .success:
            return nil
        case .failure(let error as SequentialStreamControl) where error == .consumerFinished:
            return nil
        case .failure(let error):
            queue.producerDidFail(error)
            return error
        }
    }

    private static func decodeFromSequentialProvider(
        queue: SequentialByteQueue,
        maxPixelSize: Int?
    ) throws -> CGImage? {
        // The provider is synchronous and never escapes this closure. Keep the queue alive explicitly instead of
        // transferring Swift ARC ownership through a C release callback; cancellation can make provider creation
        // or teardown fail early, and ownership must not depend on which CoreGraphics cleanup branch runs.
        withExtendedLifetime(queue) {
            let source = CGImageSourceCreateIncremental(nil)
            var callbacks = CGDataProviderSequentialCallbacks(
                version: 0,
                getBytes: viewerSequentialGetBytes,
                skipForward: nil,
                rewind: nil,
                releaseInfo: nil
            )
            let info = Unmanaged.passUnretained(queue).toOpaque()
            guard let dataProvider = CGDataProvider(sequentialInfo: info, callbacks: &callbacks) else {
                return nil
            }
            CGImageSourceUpdateDataProvider(source, dataProvider, true)
            return image(from: source, maxPixelSize: maxPixelSize)
        }
    }

    fileprivate final class SequentialByteQueue: @unchecked Sendable {
        private let condition = NSCondition()
        private let maxBufferedBytes = 4 * 1024 * 1024
        private var chunks: [Data] = []
        private var chunkIndex = 0
        private var chunkOffset = 0
        private var bufferedBytes = 0
        private var isProducerFinished = false
        private var isConsumerFinished = false
        private var isCancelled = false
        private var streamError: Error?
        private var producerWaiters: [UUID: CheckedContinuation<Bool, Error>] = [:]

        func append(_ data: Data) async throws {
            guard !data.isEmpty else { return }
            var offset = 0
            while offset < data.count {
                let pieceSize = min(maxBufferedBytes, data.count - offset)
                let piece: Data
                if offset == 0, pieceSize == data.count {
                    piece = data
                } else {
                    piece = Data(data[offset..<offset + pieceSize])
                }
                try await appendPiece(piece)
                offset += pieceSize
            }
        }

        func producerDidFinish() {
            condition.lock()
            isProducerFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func producerDidFail(_ error: Error) {
            condition.lock()
            guard !isCancelled else {
                condition.unlock()
                return
            }
            streamError = error
            isProducerFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func consumerDidFinish() {
            condition.lock()
            isConsumerFinished = true
            chunks.removeAll(keepingCapacity: false)
            chunkIndex = 0
            chunkOffset = 0
            bufferedBytes = 0
            let waiters = takeProducerWaitersLocked()
            condition.broadcast()
            condition.unlock()
            resume(waiters, with: .failure(SequentialStreamControl.consumerFinished))
        }

        func cancel() {
            condition.lock()
            isCancelled = true
            isProducerFinished = true
            chunks.removeAll(keepingCapacity: false)
            chunkIndex = 0
            chunkOffset = 0
            bufferedBytes = 0
            let waiters = takeProducerWaitersLocked()
            condition.broadcast()
            condition.unlock()
            resume(waiters, with: .failure(CancellationError()))
        }

        func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
            guard count > 0 else { return 0 }
            condition.lock()
            while chunkIndex >= chunks.count, !isProducerFinished, !isCancelled {
                condition.wait()
            }
            guard !isCancelled else {
                condition.unlock()
                return 0
            }
            var copied = 0
            while copied < count, chunkIndex < chunks.count {
                let chunk = chunks[chunkIndex]
                let available = chunk.count - chunkOffset
                let amount = min(count - copied, available)
                chunk.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    memcpy(buffer.advanced(by: copied), base.advanced(by: chunkOffset), amount)
                }
                copied += amount
                chunkOffset += amount
                bufferedBytes -= amount
                if chunkOffset == chunk.count {
                    chunkIndex += 1
                    chunkOffset = 0
                    if chunkIndex == chunks.count {
                        chunks.removeAll(keepingCapacity: true)
                        chunkIndex = 0
                    } else if chunkIndex >= 64, chunkIndex * 2 >= chunks.count {
                        chunks.removeFirst(chunkIndex)
                        chunkIndex = 0
                    }
                }
                if chunkIndex >= chunks.count, !isProducerFinished, !isCancelled { break }
            }
            let waiters = takeProducerWaitersLocked()
            condition.broadcast()
            condition.unlock()
            resume(waiters, with: .success(false))
            return copied
        }

        private func appendPiece(_ data: Data) async throws {
            let waiterID = UUID()
            while true {
                try Task.checkCancellation()
                let appended = try await withTaskCancellationHandler(
                    operation: {
                        try await withCheckedThrowingContinuation { continuation in
                            condition.lock()
                            let immediate: Result<Bool, Error>?
                            if Task.isCancelled || isCancelled {
                                immediate = .failure(CancellationError())
                            } else if isConsumerFinished {
                                immediate = .failure(SequentialStreamControl.consumerFinished)
                            } else if isProducerFinished {
                                immediate = .failure(streamError ?? SequentialStreamControl.consumerFinished)
                            } else if bufferedBytes + data.count <= maxBufferedBytes {
                                chunks.append(data)
                                bufferedBytes += data.count
                                condition.broadcast()
                                immediate = .success(true)
                            } else {
                                producerWaiters[waiterID] = continuation
                                immediate = nil
                            }
                            condition.unlock()
                            if let immediate { continuation.resume(with: immediate) }
                        }
                    },
                    onCancel: {
                        self.cancelProducerWaiter(waiterID)
                    })
                if appended { return }
            }
        }

        private func cancelProducerWaiter(_ id: UUID) {
            condition.lock()
            let waiter = producerWaiters.removeValue(forKey: id)
            condition.unlock()
            waiter?.resume(throwing: CancellationError())
        }

        private func takeProducerWaitersLocked() -> [CheckedContinuation<Bool, Error>] {
            let waiters = Array(producerWaiters.values)
            producerWaiters.removeAll(keepingCapacity: true)
            return waiters
        }

        private func resume(
            _ waiters: [CheckedContinuation<Bool, Error>],
            with result: Result<Bool, Error>
        ) {
            for waiter in waiters { waiter.resume(with: result) }
        }
    }

    private final class DecoderResultBox: @unchecked Sendable {
        typealias Value = Result<CGImage?, Error>

        private let lock = NSLock()
        private var didResolve = false
        private var storedResult: Value?
        private var waiter: CheckedContinuation<Value, Never>?

        func resolve(_ result: Value) {
            lock.lock()
            precondition(!didResolve, "streamed image decoder resolved more than once")
            didResolve = true
            storedResult = result
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: result)
        }

        func value() async -> Value {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let storedResult {
                    lock.unlock()
                    continuation.resume(returning: storedResult)
                } else {
                    precondition(waiter == nil, "streamed image decoder awaited more than once")
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private static let streamingDecodeQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.viewer-streamed-image-decoder",
        qos: .userInitiated
    )

    private static func image(from source: CGImageSource, maxPixelSize: Int?) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalLongest = max(
            props?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
        let target: Int
        if let maxPixelSize {
            target = originalLongest > 0 ? min(maxPixelSize, originalLongest) : maxPixelSize
        } else {
            target = originalLongest > 0 ? originalLongest : 100_000
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, target),
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return image
        }
        // A bounded request must never fall back to an unbounded original decode. Some formats do not expose
        // enough metadata for ImageIO's thumbnail path; returning nil preserves the caller's bounded-memory
        // contract and lets it keep the lower-resolution representation.
        guard maxPixelSize == nil else { return nil }
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, fallbackOptions as CFDictionary)
    }
}
