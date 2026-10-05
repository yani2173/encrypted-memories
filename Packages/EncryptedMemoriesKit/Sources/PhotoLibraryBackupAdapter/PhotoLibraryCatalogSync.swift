import Foundation
import Photos
import UploadCore

/// Streams PhotoKit asset metadata in bounded chunks. The offset allows an interrupted full scan to resume
/// without retaining the full library in memory.
public protocol PhotoLibraryAssetEnumerator: Sendable {
    /// `identifiers == nil` enumerates the whole library newest-first; otherwise it fetches exactly
    /// those identifiers. `startOffset` skips that many assets from the newest-first start so an
    /// interrupted full scan can resume instead of restarting (ignored for a targeted fetch). Each
    /// yielded chunk is at most `chunkSize` assets so transient PhotoKit objects and catalog writes stay
    /// bounded for large libraries.
    func infoChunks(
        identifiers: [String]?, startOffset: Int, chunkSize: Int
    ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error>
    /// Cheap full-library identifier snapshot. Production reads only `localIdentifier`; source
    /// metadata and resources are materialized later in bounded chunks from the durable snapshot.
    func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error>
}

/// A bounded identifier page plus PhotoKit's stable fetch count. The total lets an OS execution
/// window observe real work during the cheap snapshot phase, before metadata creates queue rows.
public struct PhotoLibraryIdentifierChunk: Sendable, Equatable {
    public var identifiers: [String]
    public var totalCount: Int?

    public init(identifiers: [String], totalCount: Int? = nil) {
        self.identifiers = identifiers
        self.totalCount = totalCount.map { max(0, $0) }
    }
}

public extension PhotoLibraryAssetEnumerator {
    func infoChunks(identifiers: [String]?, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize)
    }

    func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error> {
        let source = infoChunks(identifiers: nil, startOffset: 0, chunkSize: chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        continuation.yield(
                            PhotoLibraryIdentifierChunk(
                                identifiers: chunk.map(\.localIdentifier)
                            ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Production enumerator over `PHAsset`. Metadata-only: `PHAssetResource.assetResources(for:)` is
/// synchronous and never downloads bytes, and we never touch image/video data or thumbnails here.
public struct PhotoKitAssetEnumerator: PhotoLibraryAssetEnumerator {
    public init() {}

    public func infoChunks(
        identifiers: [String]?, startOffset: Int, chunkSize: Int
    ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        let chunkSize = max(1, chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let fetchResult: PHFetchResult<PHAsset>
                if let identifiers {
                    fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                } else {
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    fetchResult = PHAsset.fetchAssets(with: options)
                }

                let total = fetchResult.count
                // Resume point: skip assets already observed by an earlier run of this scan epoch.
                // Clamped so a shrunk library (deletions since the cursor was saved) can't index past
                // the end; it just yields nothing and the epoch completes.
                var index = min(max(0, startOffset), total)
                while index < total {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let upperBound = min(index + chunkSize, total)
                    autoreleasepool {
                        let assets = (index..<upperBound).map { fetchResult.object(at: $0) }
                        let chunk = PhotoKitAssetMapper.infos(for: assets)
                        continuation.yield(chunk)
                    }
                    index = upperBound
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error> {
        let chunkSize = max(1, chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)
                var index = 0
                while index < result.count {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let upperBound = min(index + chunkSize, result.count)
                    let identifiers = autoreleasepool {
                        (index..<upperBound).map { result.object(at: $0).localIdentifier }
                    }
                    continuation.yield(
                        PhotoLibraryIdentifierChunk(
                            identifiers: identifiers,
                            totalCount: result.count
                        ))
                    index = upperBound
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Scans the photo library and persists observations in bounded chunks.
/// It enqueues candidates only for new or changed assets.
/// Queue rows are written before catalog rows, so a crash replays the chunk safely.
/// Removed assets are marked in the catalog and removed from queued or in-flight work.
/// PhotoKit enumeration and SQLite writes run off the main actor.
public struct PhotoLibraryCatalogSync: Sendable {
    private let store: any PhotoLibraryCatalogStore
    private let enumerator: any PhotoLibraryAssetEnumerator
    private let chunkSize: Int
    private let now: @Sendable () -> Date
    private let onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)?
    private let onRemoved: (@Sendable ([String]) async -> Void)?
    private let onFirstScanResumable: (@Sendable () -> Void)?

    /// `onFirstScanResumable` runs when the first full scan of the library has a durable snapshot, before its
    /// metadata chunks: from then on an interrupted first scan resumes at its cursor on the next pass. A later full
    /// scan never calls it; the caller starts such a rescan over.
    public init(
        store: any PhotoLibraryCatalogStore,
        enumerator: any PhotoLibraryAssetEnumerator = PhotoKitAssetEnumerator(),
        chunkSize: Int = 200,
        now: @Sendable @escaping () -> Date = { Date() },
        onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)? = nil,
        onRemoved: (@Sendable ([String]) async -> Void)? = nil,
        onFirstScanResumable: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.enumerator = enumerator
        self.chunkSize = max(1, chunkSize)
        self.now = now
        self.onProgress = onProgress
        self.onRemoved = onRemoved
        self.onFirstScanResumable = onFirstScanResumable
    }

    /// `identifiers == nil` = full library scan (resumable, mark-and-sweep removals); otherwise a
    /// targeted incremental scan (missing requested ids are marked removed). Returns the final tally.
    @discardableResult
    public func run(
        engine: any UploadBackupCandidateEnqueueing, identifiers: [String]? = nil
    ) async throws -> PhotoLibraryCatalogProgress {
        guard store.isOperational() else {
            throw UploadError.backend("Photo library catalog is unavailable")
        }
        let observedAt = now()
        var progress = PhotoLibraryCatalogProgress()

        // Targeted change-token scan: fetch the requested IDs and mark missing IDs removed.
        if let identifiers {
            progress.executionTotalUnitCount = Int64(identifiers.count)
            onProgress?(progress)
            var seen: Set<String>? = []
            for try await chunk in enumerator.infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize)
            {
                try Task.checkCancellation()
                try await ingest(chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &seen)
                progress.executionCompletedUnitCount = Int64(min(identifiers.count, seen?.count ?? 0))
                onProgress?(progress)
            }
            try Task.checkCancellation()
            let missing = Set(identifiers).subtracting(seen ?? [])
            if !missing.isEmpty {
                let result = store.markRemoved(Array(missing), removedAt: observedAt)
                guard result.succeeded else {
                    throw UploadError.backend("Photo library removals could not be saved")
                }
                await onRemoved?(Array(missing))
                progress.removed += result.affectedRows
            }
            progress.executionCompletedUnitCount = Int64(identifiers.count)
            onProgress?(progress)
            return progress
        }

        // Full library scan: stable and resumable across interruptions.
        // A numeric cursor over a live PHFetchResult is unsafe: deleting an earlier item shifts an
        // unseen item behind the cursor. Persist the epoch's identifiers first, then resolve that
        // immutable list in chunks. New assets are handled independently by persistent changes.
        let existingProgress = store.fullScanProgress()
        let isFirstScan = !store.hasCompletedFullScan()
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan state is unavailable")
        }
        var snapshotWorkUnits = 0
        let buildsSnapshotThisPass = existingProgress == nil
        if buildsSnapshotThisPass {
            guard store.beginFullScanSnapshot(epochStart: observedAt) else {
                throw UploadError.backend("Photo library scan snapshot could not be started")
            }
            do {
                for try await chunk in enumerator.identifierChunks(chunkSize: chunkSize) {
                    try Task.checkCancellation()
                    guard store.appendFullScanSnapshotIdentifiers(chunk.identifiers) else {
                        throw UploadError.backend("Photo library scan snapshot could not be saved")
                    }
                    snapshotWorkUnits += chunk.identifiers.count
                    if let totalCount = chunk.totalCount {
                        progress.executionTotalUnitCount = Int64(totalCount * 2)
                    }
                    progress.executionCompletedUnitCount = Int64(snapshotWorkUnits)
                    onProgress?(progress)
                }
                try Task.checkCancellation()
                guard store.finishFullScanSnapshot() else {
                    throw UploadError.backend("Photo library scan snapshot could not be published")
                }
            } catch {
                _ = store.clearFullScanResumePoint()
                throw error
            }
        }

        guard let resume = store.fullScanProgress() else {
            throw UploadError.backend("Photo library scan snapshot is unavailable")
        }
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan state is unavailable")
        }
        let epochStart = resume.epochStart
        let total = store.fullScanSnapshotCount()
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan snapshot could not be read")
        }
        if isFirstScan { onFirstScanResumable?() }
        var cursor = resume.cursor
        let metadataWorkBase = buildsSnapshotThisPass ? total : 0
        progress.executionTotalUnitCount = Int64(total + metadataWorkBase)
        progress.executionCompletedUnitCount = Int64(metadataWorkBase + cursor)
        onProgress?(progress)
        while cursor < total {
            try Task.checkCancellation()
            let identifiers = store.fullScanSnapshotIdentifiers(startingAt: cursor, limit: chunkSize)
            guard store.isOperational() else {
                throw UploadError.backend("Photo library scan snapshot could not be read")
            }
            guard !identifiers.isEmpty else {
                _ = store.clearFullScanResumePoint()
                throw UploadError.backend("Photo library scan snapshot is incomplete")
            }

            var seen: Set<String>? = []
            for try await chunk in enumerator.infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize)
            {
                try Task.checkCancellation()
                try await ingest(chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &seen)
            }
            try Task.checkCancellation()
            let missing = Set(identifiers).subtracting(seen ?? [])
            if !missing.isEmpty {
                let result = store.markRemoved(Array(missing), removedAt: observedAt)
                guard result.succeeded else {
                    throw UploadError.backend("Photo library removals could not be saved")
                }
                await onRemoved?(Array(missing))
                try Task.checkCancellation()
                progress.removed += result.affectedRows
            }
            cursor += identifiers.count
            guard store.recordFullScanProgress(PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: cursor))
            else {
                throw UploadError.backend("Photo library scan progress could not be saved")
            }
            progress.executionCompletedUnitCount = Int64(metadataWorkBase + cursor)
            onProgress?(progress)
        }

        // The enumeration reached the end, so the epoch is complete.
        try Task.checkCancellation()
        let sweep = store.sweepRemoved(notSeenAfter: epochStart, removedAt: observedAt)
        guard sweep.succeeded else {
            throw UploadError.backend("Photo library removal sweep could not be saved")
        }
        progress.removed += sweep.affectedRows
        guard store.completeFullScan() else {
            throw UploadError.backend("Photo library scan could not be completed")
        }
        progress.executionCompletedUnitCount = progress.executionTotalUnitCount ?? 0
        onProgress?(progress)
        return progress
    }

    /// Runs once per catalog. An earlier build can store an entry that lists a late rendered file next to a backup
    /// with the original as main photo; the scan then sees no change. This pass offers each stored edit that lists its
    /// rendered file to `reopenBackedUpRevisions` and queues the revisions it re-opens. It reads only local stores.
    /// The flag is set only after the last page, so a cancelled pass starts again.
    public func reconcileLateRendersOnce(engine: any UploadBackupCandidateEnqueueing) async throws {
        guard !store.hasReconciledLateRenders() else { return }
        var cursor: String?
        while true {
            try Task.checkCancellation()
            let page = store.presentEntries(afterLocalIdentifier: cursor, limit: chunkSize)
            guard store.isOperational() else {
                throw UploadError.backend("Photo library catalog could not be read")
            }
            guard let last = page.last else { break }
            let reopenings = page.compactMap { entry -> UploadBackupReopening? in
                let info = PhotoLibraryCatalogMapper.info(for: entry)
                // The catalog keeps no adjustment state; a listed rendered file next to the original marks the edit.
                guard PhotoBackupAssetPlanner.listsRender(info),
                    let formerMain = PhotoBackupAssetPlanner.originalSecondarySource(for: info),
                    let candidate = PhotoBackupAssetPlanner.candidate(for: info)
                else { return nil }
                return UploadBackupReopening(candidate: candidate, formerMain: formerMain)
            }
            if !reopenings.isEmpty {
                let pending = try await engine.reopenBackedUpRevisions(reopenings)
                if !pending.isEmpty { _ = try await engine.enqueueBatch(pending) }
            }
            cursor = last.localIdentifier
        }
        guard store.markLateRendersReconciled() else {
            throw UploadError.backend("Photo library catalog could not be updated")
        }
    }

    /// Classifies + enqueues one chunk, then durably advances the catalog. Queue rows are written
    /// before the catalog (`upsertBatch`) so a crash re-yields the asset rather than stranding it.
    private func ingest(
        _ chunk: [PhotoBackupAssetInfo],
        observedAt: Date,
        engine: any UploadBackupCandidateEnqueueing,
        progress: inout PhotoLibraryCatalogProgress,
        seen: inout Set<String>?
    ) async throws {
        let entries = chunk.map { PhotoLibraryCatalogMapper.entry(for: $0, observedAt: observedAt) }
        let changes = store.classifyBatch(entries)
        guard store.isOperational(), changes.count == entries.count else {
            throw UploadError.backend("Photo library catalog classification was incomplete")
        }
        var candidates: [UploadBackupAssetCandidate] = []
        var reopened: [UploadBackupReopening] = []
        candidates.reserveCapacity(entries.count)
        for (info, change) in zip(chunk, changes) {
            progress.scanned += 1
            if seen != nil { seen!.insert(info.localIdentifier) }
            switch change {
            case .inserted: progress.discovered += 1
            case .changed: progress.changed += 1
            case .unchanged: continue
            }
            if let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                candidates.append(candidate)
                if change == .changed, rendersLate(info) {
                    reopened.append(
                        UploadBackupReopening(
                            candidate: candidate,
                            formerMain: PhotoBackupAssetPlanner.originalSecondarySource(for: info)))
                }
            }
        }
        guard store.isOperational() else {
            throw UploadError.backend("Photo library catalog could not be read")
        }
        if !reopened.isEmpty { try await engine.reopenBackedUpRevisions(reopened) }
        _ = try await engine.enqueueBatch(candidates)
        try Task.checkCancellation()
        guard store.upsertBatch(entries) else {
            throw UploadError.backend("Photo library catalog could not be updated")
        }
    }

    /// An edit whose rendered file Photos lists only now. When Photos leaves the dates alone, its revision can
    /// equal one that an earlier build recorded as complete with the original as main photo.
    private func rendersLate(_ info: PhotoBackupAssetInfo) -> Bool {
        guard PhotoBackupAssetPlanner.listsRender(info), let stored = store.entry(for: info.localIdentifier) else {
            return false
        }
        return !PhotoBackupAssetPlanner.listsRender(PhotoLibraryCatalogMapper.info(for: stored))
    }
}
