import Foundation
import Photos
import PhotosCore
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
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                return UpgradeTestPhotoLibrary.infoChunks(
                    identifiers: identifiers, startOffset: startOffset, chunkSize: chunkSize)
            }
        #endif
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
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                return UpgradeTestPhotoLibrary.identifierChunks(chunkSize: chunkSize)
            }
        #endif
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
/// Queue rows are written, and synced to disk, before catalog rows, so a crash or power loss replays the chunk safely.
/// Removed assets are marked in the catalog and removed from queued or in-flight work.
/// PhotoKit enumeration and SQLite writes run off the main actor.
public struct PhotoLibraryCatalogSync: Sendable {
    private let store: any PhotoLibraryCatalogStore
    private let enumerator: any PhotoLibraryAssetEnumerator
    private let chunkSize: Int
    private let now: @Sendable () -> Date
    private let onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)?
    private let onRemoved: (@Sendable ([String]) async -> Void)?

    public init(
        store: any PhotoLibraryCatalogStore,
        enumerator: any PhotoLibraryAssetEnumerator = PhotoKitAssetEnumerator(),
        chunkSize: Int = 200,
        now: @Sendable @escaping () -> Date = { Date() },
        onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)? = nil,
        onRemoved: (@Sendable ([String]) async -> Void)? = nil
    ) {
        self.store = store
        self.enumerator = enumerator
        self.chunkSize = max(1, chunkSize)
        self.now = now
        self.onProgress = onProgress
        self.onRemoved = onRemoved
    }

    /// One backup scan pass for the PhotoKit changes since the stored change token.
    /// Recently added or changed assets are enqueued first, then the full scan runs when the catalog needs one.
    /// `commitChanges` advances the change token once the changes are durably covered.
    ///
    /// A full scan commits the token as soon as its identifier snapshot is saved on disk: every asset that existed
    /// before the token is in that snapshot, and the catalog keeps the scan owed until it completes. The change
    /// history after the token then reports what changes while the scan is interrupted, so the next launch resumes
    /// the snapshot instead of starting again (#309).
    ///
    /// The token moves only when the queue rows of the pass survive a power loss. A catalog row without its queue row
    /// counts as unchanged, so the photo would never be backed up (#352).
    public func runPass(
        engine: any UploadBackupCandidateEnqueueing,
        changes: PhotoLibraryChangeMonitor.ChangeSet,
        onLibraryChange: @Sendable () async -> Void = {},
        commitChanges: @Sendable () -> Void
    ) async throws {
        let needsFullScan = changes.requiresFullRescan || !store.hasCompletedFullScan()
        guard store.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        // A rescan can follow a completed scan, for example after an expired change history. It is the only proof
        // that no asset was missed, so it stays owed even when a later pass stores a newer token.
        if changes.requiresFullRescan {
            guard store.markFullScanOwed() else {
                throw UploadError.backend("Photo library scan state could not be saved")
            }
        }

        // Enqueue recently added or changed assets first on every pass, including during backfill. A photo
        // saved by another app or edited while the initial full scan runs must not wait for it.
        if !changes.requiresFullRescan {
            let targeted = Array(Set(changes.changedIdentifiers + changes.deletedIdentifiers))
            if !targeted.isEmpty {
                _ = try await run(engine: engine, identifiers: targeted)
                await onLibraryChange()
            }
        }

        guard needsFullScan else {
            if await synchronizeQueueThenCatalog(engine: engine) { commitChanges() }
            return
        }
        if changes.requiresFullRescan {
            guard store.clearFullScanResumePoint() else {
                throw UploadError.backend("Photo library scan state could not be reset")
            }
        }
        _ = try await runFullScan(engine: engine, onSnapshotReady: commitChanges)
        await onLibraryChange()
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
                try await ingest(
                    chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &seen,
                    recheckMissingSources: true)
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

        return try await runFullScan(engine: engine, onSnapshotReady: {})
    }

    /// The full library scan. `onSnapshotReady` runs once the identifier snapshot of the scan is saved and synchronized
    /// to disk, before the first metadata read of this pass. When the synchronization fails, it runs after the scan
    /// completes and a second synchronization succeeds; otherwise it does not run.
    private func runFullScan(
        engine: any UploadBackupCandidateEnqueueing,
        onSnapshotReady: @Sendable () -> Void
    ) async throws -> PhotoLibraryCatalogProgress {
        let observedAt = now()
        var progress = PhotoLibraryCatalogProgress()

        // Full library scan: stable and resumable across interruptions.
        // A numeric cursor over a live PHFetchResult is unsafe: deleting an earlier item shifts an
        // unseen item behind the cursor. Persist the epoch's identifiers first, then resolve that
        // immutable list in chunks. New assets are handled independently by persistent changes.
        let existingProgress = store.fullScanProgress()
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
        // The token may move past the reason for this scan only when the owed scan, its snapshot, and the queue of this
        // pass survive a power loss; SQLite keeps most WAL commits durable only across app crashes.
        let snapshotIsDurable = await synchronizeQueueThenCatalog(engine: engine)
        if snapshotIsDurable { onSnapshotReady() }
        let epochStart = resume.epochStart
        let total = store.fullScanSnapshotCount()
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan snapshot could not be read")
        }
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
        // A token that stays is safe: the next pass reads the same changes again.
        let completionIsDurable = await synchronizeQueueThenCatalog(engine: engine)
        if !snapshotIsDurable && completionIsDurable { onSnapshotReady() }
        progress.executionCompletedUnitCount = progress.executionTotalUnitCount ?? 0
        onProgress?(progress)
        return progress
    }

    /// Makes the queue durable first and then the catalog, before the change token moves. Queue rows of new or changed
    /// photos are already durable when their commit returns, so a catalog row on disk never lacks its queue row (#352).
    private func synchronizeQueueThenCatalog(engine: any UploadBackupCandidateEnqueueing) async -> Bool {
        await engine.synchronizeQueueToDisk() && store.synchronizeToDisk()
    }

    /// Runs once per catalog. An earlier build can store an entry that lists a late rendered file next to a backup
    /// with the original as main photo; the scan then sees no change. This pass offers each stored edit that lists its
    /// rendered file to `reopenBackedUpRevisions` and queues the revisions it re-opens. It reads local stores, and the
    /// remote proof only for a photo that an earlier build settled through it.
    /// The flag is set only after the last page. Each page is saved as checked once its revisions are queued, so a
    /// later pass, also after a cancellation or a relaunch, continues after the last checked page (#356). When the
    /// remote proof cannot be read, the pass stops without an error and leaves the flag unset; the next pass starts at
    /// the failed page (#343).
    public func reconcileLateRendersOnce(engine: any UploadBackupCandidateEnqueueing) async throws {
        guard !store.hasReconciledLateRenders() else { return }
        // A failed read leaves the store not operational, and the first page below throws.
        var cursor = store.lateRenderSweepResumePoint()
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
                let pending: [UploadBackupAssetCandidate]
                do {
                    pending = try await engine.reopenBackedUpRevisions(reopenings, deferringWithoutRemoteProof: true)
                } catch is UploadBackupRemoteProofUnavailable {
                    return
                }
                if !pending.isEmpty { _ = try await engine.enqueueBatch(pending) }
            }
            cursor = last.localIdentifier
            guard store.recordLateRenderSweepResumePoint(last.localIdentifier) else {
                throw UploadError.backend("Photo library catalog could not be updated")
            }
        }
        guard store.markLateRendersReconciled() else {
            throw UploadError.backend("Photo library catalog could not be updated")
        }
    }

    /// Recovers unchanged catalog photos dropped by older builds or by a later missing-source discard.
    /// Reads only local stores. A page advances only after durable conditional queue inserts.
    /// A drop during the sweep changes the queue generation, so another pass checks the earlier pages again.
    public func reconcileMissingSources(engine: any UploadBackupCandidateEnqueueing) async throws {
        let generation = try await engine.missingSourceDiscardGeneration()
        let completed = store.reconciledMissingSourceGeneration()
        let progress = store.missingSourceSweepProgress()
        guard store.isOperational() else { throw UploadError.backend("Photo library catalog could not be read") }
        var sweep: PhotoLibraryMissingSourceSweepProgress
        if let progress {
            sweep = progress
        } else {
            guard completed != generation else { return }
            sweep = PhotoLibraryMissingSourceSweepProgress(generation: generation)
            guard store.recordMissingSourceSweepProgress(sweep) else {
                throw UploadError.backend("Photo library catalog could not be updated")
            }
        }
        while true {
            try Task.checkCancellation()
            let page = store.presentEntries(afterLocalIdentifier: sweep.afterLocalIdentifier, limit: chunkSize)
            guard store.isOperational() else { throw UploadError.backend("Photo library catalog could not be read") }
            guard let last = page.last else { break }
            let candidates = page.compactMap {
                PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: $0))
            }
            try await engine.enqueueMissingSources(candidates)
            sweep.afterLocalIdentifier = last.localIdentifier
            guard store.recordMissingSourceSweepProgress(sweep) else {
                throw UploadError.backend("Photo library catalog could not be updated")
            }
            await Task.yield()
        }
        guard store.completeMissingSourceSweep(generation: sweep.generation) else {
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
        seen: inout Set<String>?,
        recheckMissingSources: Bool = false
    ) async throws {
        let entries = chunk.map { PhotoLibraryCatalogMapper.entry(for: $0, observedAt: observedAt) }
        let changes = store.classifyBatch(entries)
        guard store.isOperational(), changes.count == entries.count else {
            throw UploadError.backend("Photo library catalog classification was incomplete")
        }
        var candidates: [UploadBackupAssetCandidate] = []
        var reopened: [UploadBackupReopening] = []
        var unchanged: [UploadBackupAssetCandidate] = []
        candidates.reserveCapacity(entries.count)
        for (info, change) in zip(chunk, changes) {
            progress.scanned += 1
            if seen != nil { seen!.insert(info.localIdentifier) }
            switch change {
            case .inserted: progress.discovered += 1
            case .changed: progress.changed += 1
            case .unchanged:
                if recheckMissingSources, let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                    unchanged.append(candidate)
                }
                continue
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
        if !unchanged.isEmpty { try await engine.enqueueChangedMissingSources(unchanged) }
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
