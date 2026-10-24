import AVFoundation
import Foundation
import MediaByteCache
import PhotosCore

/// Serves a Proton video to AVFoundation through cleartext byte-range requests.
/// Each request maps to the encrypted blocks that cover it, fetches only those blocks, decrypts them,
/// and returns a contiguous file-order window. Obsolete requests are cancelled on seek; encrypted disk
/// data and a small decrypted-block LRU avoid repeated fetches.
final class ProtonVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, VideoStreamReadAheadTuning,
    VideoStreamLifetime,
    @unchecked Sendable
{
    private let prepared: PreparedVideo
    private let source: PhotoVideoStreamSource
    private let crypto: DriveCrypto
    private let cache: VideoByteRangeCache
    private let admission: JoinedShutdownGate
    private let requestCause: ProtonRequestCauseBinding?
    /// Stable owner lease for this loader lifetime. A later lookup after clear cannot authorize an old loader.
    private let ownerGeneration: CacheWriterGeneration.Token
    private let publicationOwner = VideoCacheWriteOwner()
    private let decryptedCache = NSCache<NSNumber, NSData>()

    // In-flight serving tasks, keyed by the loading request, so a seek can cancel obsolete prefetch.
    private let lock = NSLock()
    private var isClosed = false
    private struct RequestTask {
        let id: UUID
        let task: Task<Void, Never>
        let completion: VideoLoadingRequestCompletion
    }
    private var tasks: [ObjectIdentifier: RequestTask] = [:]
    private struct PrefetchTask {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var prefetchTasks: [Int: PrefetchTask] = [:]
    private struct EncryptedFetch {
        let id: UUID
        let task: Task<(Data, Bool), Error>
        let completion: VideoPrefetchCompletion
        let priorityHandle: ProtonRequestGovernor.PriorityHandle
        let startedAsPrefetch: Bool
    }
    private var encryptedFetches: [Int: EncryptedFetch] = [:]
    /// How many ~4 MB blocks to warm ahead of the bytes AVFoundation just consumed. Deep enough that the
    /// network-fetch+decrypt read-ahead stays in front of playback (the shallow 4-block window micro-stalled
    /// higher-bitrate video). Paired with a roomier `decryptedCache` so warmed blocks survive until requested.
    /// Blocks warmed as decrypted data ahead of the served bytes. This is the hot window; it stays small
    /// because each entry holds about 4 MB of cleartext in memory.
    private let forwardPrefetchBlockCount = 8
    /// Blocks warmed beyond the hot window as encrypted bytes on disk. Deep enough for a high-bitrate clip
    /// to survive a slow stretch, cheap in memory because nothing is decrypted before it is needed.
    /// Sized from the clip's own bitrate once the player reports its duration.
    private var deepPrefetchBlockCount = 8
    /// Bound for a very high bitrate, so one clip cannot queue unbounded fetches.
    private static let deepPrefetchBlockLimit = 48
    /// Blocks warmed at open time, before AVFoundation asks for anything. The player decides on its own
    /// when playback can start without stalling (`automaticallyWaitsToMinimizeStalling`), and that decision
    /// is only as good as the bytes we can already serve: without this warm-up the first block is fetched
    /// and decrypted while the player is already waiting for it.
    private let openingPrefetchBlockCount = 6
    /// Clear offset the forward read-ahead window was last scheduled from. Lets a repeated request for
    /// the same position skip re-scanning the block map; a seek (any other offset) still re-schedules.
    private var lastForwardPrefetchOffset = -1

    init(
        prepared: PreparedVideo,
        source: PhotoVideoStreamSource,
        crypto: DriveCrypto,
        admission: JoinedShutdownGate,
        requestCause: ProtonRequestCauseBinding? = nil,
        cache: VideoByteRangeCache = .shared
    ) {
        self.prepared = prepared
        self.source = source
        self.crypto = crypto
        self.admission = admission
        self.requestCause = requestCause
        self.cache = cache
        self.ownerGeneration = cache.captureOwnerGeneration()
        super.init()
        // Keep the read-ahead window and recent blocks. At about 4 MB per block, the transient limit is 80 MB.
        decryptedCache.countLimit = 20
    }

    /// Sizes the deep read-ahead from the clip's average bitrate. A 4K clip needs several times the bytes of
    /// a 1080p clip for the same seconds of playback, and a small clip needs no deep window at all.
    ///
    /// This never delays playback: the extra blocks are fetched in the background at prefetch priority, and
    /// the player alone decides when it starts. A fast connection with a small clip therefore waits no longer
    /// than before; it simply has the whole file on disk sooner.
    func useReadAhead(forPlaybackDuration seconds: Double) {
        guard
            let bounded = VideoReadAheadWindow.blockCount(
                totalSize: prepared.totalSize,
                durationSeconds: seconds,
                blockCount: prepared.blocks.count,
                minimumBlocks: forwardPrefetchBlockCount,
                maximumBlocks: Self.deepPrefetchBlockLimit
            )
        else { return }
        let bytesPerSecond = Double(prepared.totalSize) / seconds
        let changed = lock.withLock { () -> Bool in
            guard !isClosed, bounded > deepPrefetchBlockCount else { return false }
            deepPrefetchBlockCount = bounded
            lastForwardPrefetchOffset = -1  // let the next served range schedule the wider window
            return true
        }
        guard changed else { return }
        PhotoDiagnostics.shared.emit(
            "VideoStream",
            [
                "uid": uidKey, "strategy": "readAhead",
                "blocks": "\(bounded)",
                "mbitPerSecond": String(format: "%.1f", bytesPerSecond * 8 / 1_000_000),
            ], throttleSeconds: 0.5)
    }

    /// Warms the start of the file and its last block before the player requests anything.
    ///
    /// The start carries the first samples. The last block matters because a container whose moov atom sits
    /// at the end makes AVFoundation read the tail first; serving that from a warm block removes one
    /// network round trip from every open.
    func primePlaybackStart() {
        let head = prepared.blockMap
            .forwardBlocks(afterClearOffset: -1, count: openingPrefetchBlockCount)
            .compactMap { prepared.block(at: $0.index) }
        // The first block and the tail gate the open, so they must not wait behind other prefetch work.
        for (position, block) in head.enumerated() {
            schedulePrefetch(
                block, reason: "open", priority: position == 0 ? .userInitiated : .foregroundPrefetch)
        }
        if let tail = prepared.blocks.last, !head.contains(where: { $0.index == tail.index }) {
            schedulePrefetch(tail, reason: "open-tail", priority: .userInitiated)
        }
    }

    func close() {
        // Never hold the loader lock while joining a cache publication.
        publicationOwner.close()
        let active = lock.withLock { () -> ([RequestTask], [PrefetchTask], [EncryptedFetch]) in
            guard !isClosed else { return ([], [], []) }
            isClosed = true
            let requests = Array(tasks.values)
            let prefetches = Array(prefetchTasks.values)
            let fetches = Array(encryptedFetches.values)
            tasks.removeAll()
            prefetchTasks.removeAll()
            encryptedFetches.removeAll()
            decryptedCache.removeAllObjects()
            return (requests, prefetches, fetches)
        }
        active.0.forEach {
            $0.task.cancel()
            $0.completion.finish(CancellationError())
        }
        active.1.forEach { $0.task.cancel() }
        active.2.forEach {
            $0.task.cancel()
            $0.completion.finish()
        }
    }

    deinit { close() }

    private func checkOpen() throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !isClosed else { throw CancellationError() }
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !lock.withLock({ isClosed }) else {
            loadingRequest.finishLoading(with: CancellationError() as NSError)
            return true
        }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = prepared.contentTypeUTI
            info.isByteRangeAccessSupported = true
            info.contentLength = Int64(prepared.totalSize)
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let key = ObjectIdentifier(loadingRequest)
        let taskID = UUID()
        let completion = VideoLoadingRequestCompletion { error in
            if let error {
                loadingRequest.finishLoading(with: error as NSError)
            } else {
                loadingRequest.finishLoading()
            }
        }
        let accepted = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.admitted { [self] in
                        try await self.serve(dataRequest, request: loadingRequest)
                    }
                    self.finishRequest(key: key, id: taskID, error: nil)
                } catch {
                    self.finishRequest(key: key, id: taskID, error: error)
                }
            }
            tasks[key] = RequestTask(id: taskID, task: task, completion: completion)
            return true
        }
        if !accepted { completion.finish(CancellationError()) }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        let request = lock.withLock { tasks.removeValue(forKey: key) }
        request?.completion.cancel()
        request?.task.cancel()
        // The read-ahead stays alive: AVFoundation also cancels for reasons other than a seek (for example
        // a full buffer), and the next served block re-schedules the window without duplicates.
        PhotoDiagnostics.shared.emit(
            "VideoStream",
            [
                "uid": uidKey, "strategy": "range", "cancelled": "true",
            ])
    }

    private func finishRequest(key: ObjectIdentifier, id: UUID, error: Error?) {
        let completion = lock.withLock { () -> VideoLoadingRequestCompletion? in
            guard tasks[key]?.id == id else { return nil }
            return tasks.removeValue(forKey: key)?.completion
        }
        completion?.finish(error)
    }

    // MARK: - Serving

    private func serve(
        _ dataRequest: AVAssetResourceLoadingDataRequest,
        request: AVAssetResourceLoadingRequest
    ) async throws {
        let offset = Int(dataRequest.currentOffset)
        let total = prepared.totalSize
        // Serve to the end of the resource only when AVFoundation requests it.
        let length =
            dataRequest.requestsAllDataToEndOfResource
            ? total - offset
            : Int(dataRequest.requestedOffset) + dataRequest.requestedLength - offset
        let slices = prepared.blockMap.slices(offset: offset, length: max(0, length))

        var served = 0
        var cacheHits = 0
        var cacheMisses = 0
        for slice in slices {
            try checkOpen()
            guard let block = prepared.block(at: slice.blockIndex) else {
                throw StreamingError.missingBlockForSlice(slice.blockIndex)
            }
            let (clear, hit) = try await decryptedBlock(block, priority: .immediate)
            if hit { cacheHits += 1 } else { cacheMisses += 1 }
            let from = slice.inBlock.lower
            let to = slice.inBlock.upper
            guard from < to else { continue }
            guard clear.count >= to else {
                throw StreamingError.decryptedBlockLengthMismatch(
                    blockIndex: block.index, expected: block.clearSize, actual: clear.count)
            }
            try lock.withLock {
                guard !isClosed, !Task.isCancelled else { throw CancellationError() }
                dataRequest.respond(with: clear.subdata(in: from..<to))
            }
            served += to - from
            // Per block, not per request: one open-ended request can span the whole file, and the
            // read-ahead must keep moving while it is served.
            scheduleForwardPrefetch(afterClearOffset: offset + served, reason: "blockServed")
        }
        if served == 0 {
            scheduleForwardPrefetch(afterClearOffset: offset, reason: "requestServed")
        }

        PhotoDiagnostics.shared.emit(
            "VideoStream",
            [
                "uid": uidKey,
                "strategy": "range",
                "contentLength": "\(total)",
                "contentType": prepared.contentTypeUTI,
                "rangeRequested": "\(offset)-\(offset + max(0, length))",
                "rangeServed": "\(offset)-\(offset + served)",
                "cacheHit": "\(cacheHits)",
                "cacheMiss": "\(cacheMisses)",
                "bytesServed": "\(served)",
            ])
    }

    /// Demand and prefetch claim the same encrypted fetch before any cache lookup.
    func decryptedBlock(
        _ block: VideoBlock, priority: ProtonRequestPriority
    ) async throws -> (Data, hit: Bool) {
        if priority == .immediate {
            return try await source.withDemandPriority { [self] in
                try await resolvedDecryptedBlock(block, priority: priority)
            }
        }
        return try await resolvedDecryptedBlock(block, priority: priority)
    }

    private func resolvedDecryptedBlock(
        _ block: VideoBlock, priority: ProtonRequestPriority
    ) async throws -> (Data, hit: Bool) {
        try checkOpen()
        let key = NSNumber(value: block.index)
        if let cached = decryptedCache.object(forKey: key) { return (cached as Data, true) }
        guard block.clearSize > 0 else { return (Data(), false) }
        let (encrypted, hit) = try await sharedEncryptedBlock(block, priority: priority)
        // One synchronous block decrypt owns publication. Concurrent range requests reuse its result.
        return try lock.withLock {
            guard !isClosed, !Task.isCancelled else { throw CancellationError() }
            if let cached = decryptedCache.object(forKey: key) { return (cached as Data, true) }
            let clear = try crypto.decryptBlock(encrypted, sessionKey: prepared.sessionKey)
            guard clear.count >= block.clearSize else {
                throw StreamingError.decryptedBlockLengthMismatch(
                    blockIndex: block.index, expected: block.clearSize, actual: clear.count)
            }
            decryptedCache.setObject(clear as NSData, forKey: key)
            return (clear, hit)
        }
    }

    private func sharedEncryptedBlock(
        _ block: VideoBlock, priority: ProtonRequestPriority, canRetryPrefetch: Bool = true
    ) async throws -> (Data, Bool) {
        try checkOpen()
        let fetch = try lock.withLock { () throws -> EncryptedFetch in
            guard !isClosed else { throw CancellationError() }
            if let existing = encryptedFetches[block.index] { return existing }
            let id = UUID()
            let completion = VideoPrefetchCompletion()
            let handle = ProtonRequestGovernor.PriorityHandle(priority: priority)
            let task = Task { [weak self] () throws -> (Data, Bool) in
                defer { completion.finish() }
                guard let self else { throw CancellationError() }
                defer {
                    self.lock.withLock {
                        if self.encryptedFetches[block.index]?.id == id {
                            self.encryptedFetches.removeValue(forKey: block.index)
                        }
                    }
                }
                return try await self.admitted { [self] in
                    try await self.fetchEncryptedBlock(block, priority: priority, priorityHandle: handle)
                }
            }
            let created = EncryptedFetch(
                id: id, task: task, completion: completion, priorityHandle: handle,
                startedAsPrefetch: priority != .immediate)
            encryptedFetches[block.index] = created
            return created
        }
        if priority == .immediate { await source.promoteDemand(fetch.priorityHandle) }
        do {
            try await fetch.completion.wait()
            try checkOpen()
            return try await fetch.task.value
        } catch {
            try checkOpen()
            guard priority == .immediate, fetch.startedAsPrefetch, canRetryPrefetch else { throw error }
            // Failed speculative work may be retried once by demand, inside the same upload suspension.
            return try await sharedEncryptedBlock(block, priority: priority, canRetryPrefetch: false)
        }
    }

    private func fetchEncryptedBlock(
        _ block: VideoBlock, priority: ProtonRequestPriority,
        priorityHandle: ProtonRequestGovernor.PriorityHandle
    ) async throws -> (Data, Bool) {
        let lookup = await cache.lookupAsync(uid: prepared.uid, block: block.index)
        try checkOpen()
        if let disk = lookup.encrypted { return (disk, true) }
        let encrypted = try await source.encryptedBlockData(
            block, priority: priority, priorityHandle: priorityHandle)
        try checkOpen()
        _ = await cache.storeAsync(
            uid: prepared.uid, block: block.index, encrypted: encrypted, ticket: lookup.ticket,
            ownerGeneration: ownerGeneration, publicationOwner: publicationOwner)
        try checkOpen()
        return (encrypted, false)
    }

    /// Starts warming the blocks immediately after the bytes AVFoundation just consumed. This matters
    /// on reopen/resume: the first requested range may be fully cached and play instantly, but without
    /// read-ahead the next uncached block is only requested when playback reaches the edge.
    ///
    /// Driven from a single point (after each served block) since served bytes reflect actual progress. The
    /// read-ahead set is found with a binary search instead of a linear filter over every block, and a
    /// repeat at the same `clearOffset` is skipped wholesale (a seek changes the offset and re-schedules).
    private func scheduleForwardPrefetch(afterClearOffset clearOffset: Int, reason: String) {
        let advanced = lock.withLock { () -> Bool in
            guard !isClosed, clearOffset != lastForwardPrefetchOffset else { return false }
            lastForwardPrefetchOffset = clearOffset
            return true
        }
        guard advanced else {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchDeduped")
            PhotoDiagnostics.shared.emit(
                "VideoStream",
                [
                    "uid": uidKey, "strategy": "prefetch", "reason": reason,
                    "scheduled": "false", "deduped": "true",
                ], throttleSeconds: 0.5)
            return
        }
        let deepCount = lock.withLock { deepPrefetchBlockCount }
        let window = prepared.blockMap
            .forwardBlocks(afterClearOffset: clearOffset, count: max(forwardPrefetchBlockCount, deepCount))
            .compactMap { prepared.block(at: $0.index) }
        guard !window.isEmpty else { return }
        for (position, block) in window.enumerated() {
            if position < forwardPrefetchBlockCount {
                schedulePrefetch(block, reason: reason)
            } else {
                // Beyond the hot window keep the bytes encrypted on disk. Decrypting them early would cost
                // about 4 MB of memory per block for content the player may never reach.
                scheduleEncryptedWarm(block, reason: reason)
            }
        }
    }

    /// Fetches one block's encrypted bytes into the disk cache without decrypting them.
    private func scheduleEncryptedWarm(_ block: VideoBlock, reason: String) {
        let key = NSNumber(value: block.index)
        guard decryptedCache.object(forKey: key) == nil else { return }
        let scheduled = lock.withLock { () -> Bool in
            guard !isClosed, prefetchTasks[block.index] == nil else { return false }
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.admitted { [self] in
                        _ = try await self.sharedEncryptedBlock(block, priority: .foregroundPrefetch)
                    }
                } catch is CancellationError {
                } catch {
                    PhotoDiagnostics.shared.emit(
                        "VideoStream",
                        [
                            "uid": self.uidKey, "strategy": "deepWarm",
                            "block": "\(block.index)", "reason": reason, "error": "\(error)",
                        ], throttleSeconds: 0.5)
                }
                self.lock.withLock {
                    guard self.prefetchTasks[block.index]?.id == taskID else { return }
                    self.prefetchTasks.removeValue(forKey: block.index)
                }
            }
            prefetchTasks[block.index] = PrefetchTask(id: taskID, task: task)
            return true
        }
        if scheduled { PhotoDiagnostics.shared.increment("perf.videoDeepWarmScheduled") }
    }

    private func schedulePrefetch(
        _ block: VideoBlock,
        reason: String,
        priority: ProtonRequestPriority = .foregroundPrefetch
    ) {
        let key = NSNumber(value: block.index)
        guard decryptedCache.object(forKey: key) == nil else {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchDeduped")
            return
        }

        let scheduled = lock.withLock { () -> Bool in
            guard !isClosed, prefetchTasks[block.index] == nil else { return false }
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let (_, hit) = try await self.admitted { [self] in
                        try await self.decryptedBlock(block, priority: priority)
                    }
                    PhotoDiagnostics.shared.emit(
                        "VideoStream",
                        [
                            "uid": self.uidKey,
                            "strategy": "prefetch",
                            "block": "\(block.index)",
                            "reason": reason,
                            "cacheHit": "\(hit)",
                        ], throttleSeconds: 0.5)
                } catch is CancellationError {
                } catch {
                    PhotoDiagnostics.shared.emit(
                        "VideoStream",
                        [
                            "uid": self.uidKey,
                            "strategy": "prefetch",
                            "block": "\(block.index)",
                            "reason": reason,
                            "error": "\(error)",
                        ], throttleSeconds: 0.5)
                }
                self.lock.withLock {
                    guard self.prefetchTasks[block.index]?.id == taskID else { return }
                    self.prefetchTasks.removeValue(forKey: block.index)
                }
            }
            prefetchTasks[block.index] = PrefetchTask(id: taskID, task: task)
            return true
        }
        if scheduled {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchScheduled")
            PhotoDiagnostics.shared.emit(
                "VideoStream",
                [
                    "uid": uidKey, "strategy": "prefetch", "reason": reason,
                    "block": "\(block.index)", "scheduled": "true", "deduped": "false",
                ], throttleSeconds: 0.5)
        } else {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchDeduped")
        }
    }

    private var uidKey: String { "\(prepared.uid.volumeID)~\(prepared.uid.nodeID)" }
}

extension ProtonVideoResourceLoader {
    /// Range loads run after the viewer's open call returned, so they name their own cause.
    fileprivate func admitted<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let requestCause else { return try await admission.withAdmission(operation) }
        return try await requestCause.run { try await admission.withAdmission(operation) }
    }
}
