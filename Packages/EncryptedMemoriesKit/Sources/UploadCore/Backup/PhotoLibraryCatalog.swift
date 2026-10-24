import Foundation

/// Platform-neutral local photo-library inventory. This is the persistent index of what the device
/// currently exposes for backup discovery (one row per logical asset), not a record of what is
/// already backed up - that stays the job of `UploadBackupStateStore`. Keeping the two separate is
/// deliberate: the catalog answers "what does the library look like and what changed since last
/// time?"; the backup state answers "which revisions are proven safe in Proton Drive?".
///
/// The model carries no PhotoKit types. The PhotoKit adapter maps `PHAsset` +
/// `PHAssetResource` into these plain values (roles travel as their stable string identity), so
/// this store is fully testable off-device and shared verbatim by iOS/iPadOS/macOS.

/// The broad media class of a catalogued asset. The Live-Photo flag is separate (a Live Photo is a
/// still `image` with a paired video resource), matching how the planner reasons about resources.
public enum PhotoLibraryCatalogMediaKind: String, Sendable, Equatable, Codable, CaseIterable {
    case image
    case video
}

/// One resource of a catalogued asset. `role` is the stable string identity of the adapter's
/// resource role (originalPhoto, fullSizePhoto, pairedVideo, …) so no PhotoKit enum leaks in and
/// additional resource roles remain representable.
public struct PhotoLibraryCatalogResource: Sendable, Equatable, Codable {
    public var role: String
    public var originalFilename: String
    public var mimeType: String?
    /// Stable ordinal among resources of the same role after the adapter's deterministic sort.
    public var ordinal: Int

    public init(role: String, originalFilename: String, mimeType: String? = nil, ordinal: Int = 0) {
        self.role = role
        self.originalFilename = originalFilename
        self.mimeType = mimeType
        self.ordinal = ordinal
    }
}

/// One catalogued asset plus its inventory bookkeeping. Everything above `firstSeenAt` is derived
/// from the library; `firstSeenAt`/`lastSeenAt`/`isRemoved`/`removedAt` are owned by the store.
public struct PhotoLibraryCatalogEntry: Sendable, Equatable {
    public var localIdentifier: String
    /// Stable iCloud identifier when the platform supplied one. It is metadata, not the local key,
    /// and does not participate in content-change classification.
    public var cloudIdentifier: String?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationSeconds: Double
    public var mediaKind: PhotoLibraryCatalogMediaKind
    public var isLivePhoto: Bool
    /// The person turned the Live effect of this Live Photo off. The store keeps it in the Live Photo column, so a
    /// row of an earlier build reads as Live playback on.
    public var livePlaybackOff: Bool
    public var resources: [PhotoLibraryCatalogResource]
    /// Structural fingerprint (resource roles + names + mime + dimensions + duration + live flag).
    /// A metadata-only change (favourite, album membership) leaves this untouched; the first real
    /// content edit changes the resource structure and moves it. Same value the planner fingerprints.
    public var contentFingerprint: Int64
    /// Cheap metadata revision derived from `modificationDate`. Drifts on any change PhotoKit dates,
    /// so a differing value is the signal that an asset is worth handing to the backup preflight.
    public var metadataRevision: Int64
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var isRemoved: Bool
    public var removedAt: Date?

    public init(
        localIdentifier: String,
        cloudIdentifier: String? = nil,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        mediaKind: PhotoLibraryCatalogMediaKind,
        isLivePhoto: Bool,
        livePlaybackOff: Bool = false,
        resources: [PhotoLibraryCatalogResource],
        contentFingerprint: Int64,
        metadataRevision: Int64,
        firstSeenAt: Date,
        lastSeenAt: Date,
        isRemoved: Bool = false,
        removedAt: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.mediaKind = mediaKind
        self.isLivePhoto = isLivePhoto
        self.livePlaybackOff = livePlaybackOff
        self.resources = resources
        self.contentFingerprint = contentFingerprint
        self.metadataRevision = metadataRevision
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.isRemoved = isRemoved
        self.removedAt = removedAt
    }
}

/// What an upsert did to the catalog. Drives whether the adapter emits a backup candidate.
public enum PhotoLibraryCatalogChange: Sendable, Equatable {
    /// No prior row for this identifier.
    case inserted
    /// A prior row existed but the content/metadata revision moved, or a removed asset reappeared.
    case changed
    /// A prior row existed and nothing backup-relevant changed - skip the expensive candidate path.
    case unchanged

    /// Inserted or changed assets are the only ones worth re-checking against the backup preflight.
    public var isCandidate: Bool { self != .unchanged }
}

/// Running tally of one catalog scan pass. Reported to the UI once per chunk. Wording contract: this is
/// inventory progress ("scanning"), it
/// never implies upload - only `BackupSyncProgress` may speak to backup work.
public struct PhotoLibraryCatalogProgress: Sendable, Equatable {
    /// Assets observed from the library this pass.
    public var scanned = 0
    /// Assets new to the catalog this pass.
    public var discovered = 0
    /// Assets whose content/metadata revision moved this pass.
    public var changed = 0
    /// Assets marked removed this pass (gone from the library / dropped from a limited selection).
    public var removed = 0
    /// Durable inventory work completed during this pass. This is intentionally separate from the
    /// user-facing backup count: platform execution windows need confirmation that the PhotoKit scan is
    /// advancing even before the first queue row exists.
    public var executionCompletedUnitCount: Int64 = 0
    /// Total inventory work for the current pass when PhotoKit supplied an exact fetch count.
    public var executionTotalUnitCount: Int64?

    public init(
        scanned: Int = 0,
        discovered: Int = 0,
        changed: Int = 0,
        removed: Int = 0,
        executionCompletedUnitCount: Int64 = 0,
        executionTotalUnitCount: Int64? = nil
    ) {
        self.scanned = scanned
        self.discovered = discovered
        self.changed = changed
        self.removed = removed
        self.executionCompletedUnitCount = max(0, executionCompletedUnitCount)
        self.executionTotalUnitCount = executionTotalUnitCount.map { max(0, $0) }
    }

    public var executionProgress: BackupExecutionProgress? {
        guard let total = executionTotalUnitCount, total > 0 else { return nil }
        return BackupExecutionProgress(
            completedUnitCount: executionCompletedUnitCount,
            totalUnitCount: total
        )
    }
}

/// Inventory totals for status/debug surfaces.
public struct PhotoLibraryCatalogSnapshot: Sendable, Equatable {
    public var total = 0
    public var present = 0
    public var removed = 0

    public init(total: Int = 0, present: Int = 0, removed: Int = 0) {
        self.total = total
        self.present = present
        self.removed = removed
    }
}

/// Result of a catalog mutation where zero affected rows is a valid success. Keeping the success
/// bit separate prevents SQLite failures from being mistaken for an empty removal set.
public struct PhotoLibraryCatalogMutationResult: Sendable, Equatable {
    public var affectedRows: Int
    public var succeeded: Bool

    public init(affectedRows: Int, succeeded: Bool) {
        self.affectedRows = max(0, affectedRows)
        self.succeeded = succeeded
    }
}

/// Persistence seam for the local photo-library catalog. Implemented by a SQLite store in Core; the
/// PhotoKit adapter is the only writer of observations, and the backup engine reads candidates the
/// adapter produced from `isCandidate` classifications.
public protocol PhotoLibraryCatalogStore: Sendable {
    /// False after a persistence failure or close. Empty read results are trustworthy only while
    /// this remains true; scanners must stop rather than advance a cursor on a failed read.
    func isOperational() -> Bool
    func entry(for localIdentifier: String) -> PhotoLibraryCatalogEntry?
    /// Stable keyset page of present inventory rows. Used to rebuild or enrich the durable backup
    /// queue without touching PhotoKit bytes when the queue is incomplete after an app upgrade.
    func presentEntries(afterLocalIdentifier: String?, limit: Int) -> [PhotoLibraryCatalogEntry]
    /// Read-only classification of an observation against the stored row, without writing. The sync
    /// driver uses this to decide whether to enqueue a backup candidate before it advances the
    /// catalog, so the durable queue row is always written first.
    func classify(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange
    /// Batched form used by large scans. Stores should reuse one prepared statement and avoid
    /// decoding complete rows when only fingerprint, revision, and removal state are needed.
    func classifyBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange]
    /// Records one observation, preserving `firstSeenAt` and clearing any removed marker, and
    /// returns how it classified against the prior row.
    @discardableResult
    func upsert(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange
    /// Persists batched observations in one transaction. False means no catalog advancement was
    /// committed; callers must stop before advancing a scan cursor or change token.
    @discardableResult
    func upsertBatch(_ entries: [PhotoLibraryCatalogEntry]) -> Bool
    /// Marks the given present identifiers removed (targeted-scan deletions).
    @discardableResult
    func markRemoved(_ identifiers: [String], removedAt: Date) -> PhotoLibraryCatalogMutationResult
    /// Marks removed every present row not touched since `cutoff` (full-scan mark-and-sweep).
    @discardableResult
    func sweepRemoved(notSeenAfter cutoff: Date, removedAt: Date) -> PhotoLibraryCatalogMutationResult
    func snapshot() -> PhotoLibraryCatalogSnapshot
    func count() -> Int

    // MARK: Resumable full-scan state
    /// True once a full-library scan has completed at least once. An incremental (change-token) scan
    /// is only trusted after this; a token can exist before our own catalog knows the whole library.
    func hasCompletedFullScan() -> Bool
    /// Records that a full scan is owed until `completeFullScan()`, so `hasCompletedFullScan()` is false again.
    /// Set it before anything clears the previous scan: once the change token moves past the reason for the scan,
    /// this marker is the only record that the scan is still owed.
    @discardableResult
    func markFullScanOwed() -> Bool
    /// Makes every committed change survive a power loss. Returns false when that is not certain.
    func synchronizeToDisk() -> Bool
    /// The in-progress full-scan epoch, or nil if none is underway (the next full scan starts fresh).
    /// A full scan of a large library rarely finishes in one foreground/BG window; persisting this lets
    /// an interrupted scan resume from `cursor` instead of restarting, so it converges instead of
    /// looping forever and never marking itself complete.
    func fullScanProgress() -> PhotoLibraryFullScanProgress?
    /// Persists mid-scan progress so a resumed scan continues within the same epoch.
    @discardableResult
    func recordFullScanProgress(_ progress: PhotoLibraryFullScanProgress) -> Bool
    /// Marks the current full scan complete and clears the in-progress epoch.
    @discardableResult
    func completeFullScan() -> Bool
    /// Discards any in-progress epoch's resume point so the next full scan starts fresh from the
    /// beginning (used when a lost change token means the frontier can no longer be trusted).
    @discardableResult
    func clearFullScanResumePoint() -> Bool

    // MARK: One-time upgrade reconciliation
    /// True once the sync driver checked every present row that lists a rendered file against its backup.
    func hasReconciledLateRenders() -> Bool
    /// Marks the pass done and removes its resume point.
    @discardableResult
    func markLateRendersReconciled() -> Bool
    /// The last local identifier of the pages that an unfinished pass already checked, or nil to start at the first
    /// page.
    func lateRenderSweepResumePoint() -> String?
    @discardableResult
    func recordLateRenderSweepResumePoint(_ localIdentifier: String) -> Bool

    /// Missing-source reconciliation runs once on upgrade and again for each later discard generation.
    func reconciledMissingSourceGeneration() -> Int64?
    func missingSourceSweepProgress() -> PhotoLibraryMissingSourceSweepProgress?
    @discardableResult
    func recordMissingSourceSweepProgress(_ progress: PhotoLibraryMissingSourceSweepProgress) -> Bool
    @discardableResult
    func completeMissingSourceSweep(generation: Int64) -> Bool

    // MARK: Stable full-scan snapshot
    /// Starts replacing the in-progress scan snapshot. Appends are chunked to avoid one large in-memory
    /// identifier array.
    @discardableResult
    func beginFullScanSnapshot(epochStart: Date) -> Bool
    @discardableResult
    func appendFullScanSnapshotIdentifiers(_ identifiers: [String]) -> Bool
    /// Publishes the completely-built snapshot and creates its cursor at zero.
    @discardableResult
    func finishFullScanSnapshot() -> Bool
    func fullScanSnapshotIdentifiers(startingAt position: Int, limit: Int) -> [String]
    func fullScanSnapshotCount() -> Int
}

public extension PhotoLibraryCatalogStore {
    func reconciledMissingSourceGeneration() -> Int64? { nil }
    func missingSourceSweepProgress() -> PhotoLibraryMissingSourceSweepProgress? { nil }
    func recordMissingSourceSweepProgress(_ progress: PhotoLibraryMissingSourceSweepProgress) -> Bool { false }
    func completeMissingSourceSweep(generation: Int64) -> Bool { false }

    func isOperational() -> Bool { true }

    func presentEntries(afterLocalIdentifier: String?, limit: Int) -> [PhotoLibraryCatalogEntry] { [] }

    func classifyBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        entries.map(classify)
    }

    /// Photos lists no asset for this source any more: the person deleted it, or it lies outside a narrowed
    /// limited-access selection. The entry leaves the present inventory, so missing-source recovery does not queue it
    /// again; the next scan or Photos change that lists the asset brings it back.
    @discardableResult
    func recordUnavailableSource(_ source: UploadSourceIdentity, at date: Date) -> Bool {
        markRemoved([source.identifier], removedAt: date).succeeded
    }
}

/// Persisted progress of a resumable full-library scan (see `PhotoLibraryCatalogSync`).
public struct PhotoLibraryFullScanProgress: Sendable, Equatable {
    /// Start of the current scan epoch. The completion sweep uses this instant as its cutoff; never a
    /// single run's clock, so assets observed by an earlier run of the same epoch are not falsely
    /// swept as removed when a later run finishes the epoch.
    public var epochStart: Date
    /// Position in the stable identifier snapshot of the next asset to observe.
    public var cursor: Int
    public init(epochStart: Date, cursor: Int) {
        self.epochStart = epochStart
        self.cursor = cursor
    }
}

/// A sweep retains its original generation across interruptions. A later drop still requires another full sweep.
public struct PhotoLibraryMissingSourceSweepProgress: Sendable, Equatable {
    public var generation: Int64
    public var afterLocalIdentifier: String?

    public init(generation: Int64, afterLocalIdentifier: String? = nil) {
        self.generation = generation
        self.afterLocalIdentifier = afterLocalIdentifier
    }
}
