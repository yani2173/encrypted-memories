import Foundation

/// Ephemeral, bounded liveness for work performed before the SDK upload starts. Values are fractions rather
/// than byte counters because PhotoKit exposes truthful iCloud progress even when the final resource size is
/// not known yet. Callers quantize updates; no progress value is persisted.
public struct BackupResourcePreparationProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case identity, materializing }
    public let phase: Phase
    public let fraction: Double
    public let resourceIndex: Int
    public let resourceCount: Int

    public init(phase: Phase, fraction: Double, resourceIndex: Int = 0, resourceCount: Int = 1) {
        self.phase = phase
        self.fraction = min(1, max(0, fraction))
        self.resourceCount = max(1, resourceCount)
        self.resourceIndex = min(max(0, resourceIndex), self.resourceCount - 1)
    }

    /// Reserve the final 30% of an item for upload/finalization. A duplicate can jump from identity to
    /// terminal; a real upload continues monotonically once byte transfer catches this preparation floor.
    public var completedItemEquivalent: Double {
        switch phase {
        case .identity: return fraction * 0.45
        case .materializing:
            let aggregate = (Double(resourceIndex) + fraction) / Double(resourceCount)
            return 0.45 + aggregate * 0.25
        }
    }
}

public typealias BackupResourcePreparationHandler = @Sendable (BackupResourcePreparationProgress) -> Void

/// Value wrapper used by deferred async materializers. Closure parameters are non-escaping by default;
/// wrapping the callback lets PhotoKit retain it for the lifetime of an asynchronous resource request.
public struct BackupResourcePreparationReporter: Sendable {
    private let handler: BackupResourcePreparationHandler

    public init(_ handler: @escaping BackupResourcePreparationHandler) {
        self.handler = handler
    }

    public func callAsFunction(_ progress: BackupResourcePreparationProgress) {
        handler(progress)
    }
}

/// A resource whose upload descriptor can be materialized late. Primary and secondary resources share
/// one implementation: a progress materializer wins, a plain one runs without progress, and without
/// either the descriptor is already readable.
public protocol BackupResourceMaterializing: Sendable {
    var descriptor: UploadResourceDescriptor { get }
    var materializeWithProgress:
        (@Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor)?
    { get }
}

public extension BackupResourceMaterializing {
    func materializedDescriptor() async throws -> UploadResourceDescriptor {
        try await materializedDescriptor(onPreparationProgress: { _ in })
    }

    func materializedDescriptor(
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> UploadResourceDescriptor {
        if let materializeWithProgress {
            return try await materializeWithProgress(BackupResourcePreparationReporter(onPreparationProgress))
        }
        return descriptor
    }

    var hasDeferredMaterialization: Bool {
        materializeWithProgress != nil
    }
}

extension BackupResourceMaterializing {
    static func materializer(
        _ materialize: (@Sendable () async throws -> UploadResourceDescriptor)?,
        withProgress materializeWithProgress: (
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor
        )?
    ) -> (@Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor)? {
        if let materializeWithProgress {
            return materializeWithProgress
        }
        if let materialize {
            return { _ in try await materialize() }
        }
        return nil
    }
}

/// One secondary resource of a compound (a Live Photo's paired video): uploaded after the
/// primary with `mainPhotoUID` pointing at it, deduped through the same pipeline.
public struct BackupSecondaryResource: BackupResourceMaterializing {
    /// `descriptor.source.resource` must be a secondary role (e.g. `.livePairedVideo`).
    public let descriptor: UploadResourceDescriptor
    public let mediaType: String
    public let additionalMetadata: [PhotoUploadAdditionalMetadata]
    /// Optional deferred materialization. PhotoKit can hash originals in place for dedupe and only
    /// export bytes when Core has proven an upload is necessary. File-backed sources leave this nil.
    public let materializeWithProgress:
        (@Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor)?

    public init(
        descriptor: UploadResourceDescriptor,
        mediaType: String,
        additionalMetadata: [PhotoUploadAdditionalMetadata] = [],
        materialize: (@Sendable () async throws -> UploadResourceDescriptor)? = nil,
        materializeWithProgress: (
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor
        )? = nil
    ) {
        self.descriptor = descriptor
        self.mediaType = mediaType
        self.additionalMetadata = additionalMetadata
        self.materializeWithProgress = Self.materializer(materialize, withProgress: materializeWithProgress)
    }
}

/// A queue entry rematerialized into everything the pipeline and uploader need. The queue stores
/// only identities and revisions; adapters rebuild the concrete resource when work actually runs
/// (after a relaunch the original export/URL may be gone, so this is the resume seam).
public struct BackupResolvedResource: BackupResourceMaterializing {
    /// Snapshot of the source revision recorded after a successful backup.
    /// It can be newer than the queued revision when the source changed after scanning.
    public let candidate: UploadBackupAssetCandidate
    /// Pipeline and upload input for the compound's primary resource.
    public let descriptor: UploadResourceDescriptor
    public let mediaType: String
    public let additionalMetadata: [PhotoUploadAdditionalMetadata]
    /// Proton tags that the source already knows for the main photo, such as an Apple Photos favorite. The runner
    /// adds the tags of the compound (Live Photo, series); the transport adds the video tag.
    public let tags: [Int]
    /// Best local capture-time evidence (file creation date for folder sync, PHAsset creation
    /// date for photo-library assets) - drives the remote timeline placement.
    public let captureDate: Date
    public let photoLibraryEditTime: Date?
    /// Secondary resources of the compound, uploaded after the primary settles. Empty for plain
    /// files and non-Live photo-library assets.
    public let secondaries: [BackupSecondaryResource]
    /// Optional deferred materialization for the primary resource. The descriptor already carries
    /// its streamed digest and byte count, so dedupe never needs a temp file for known duplicates.
    public let materializeWithProgress:
        (@Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor)?
    /// Releases any temporary exports this resource materialized (e.g. PhotoKit originals streamed
    /// into the temp store). The runner calls it once the entry settles - success, park, or revert -
    /// so exports are freed per item instead of piling up until the whole pass ends. `nil` when the
    /// resource points at a durable location the pipeline must not delete (e.g. a user's real file).
    public let cleanup: (@Sendable () -> Void)?
    /// The compound leaves out the Live Photo video that Photos still reports missing after the runner's checks, so
    /// the photo backs up without the Live Photo tag. Held in memory for this pass only; the queue never stores it.
    public let omitsMissingPairedVideo: Bool

    public init(
        candidate: UploadBackupAssetCandidate,
        descriptor: UploadResourceDescriptor,
        mediaType: String,
        additionalMetadata: [PhotoUploadAdditionalMetadata] = [],
        tags: [Int] = [],
        captureDate: Date,
        secondaries: [BackupSecondaryResource] = [],
        photoLibraryEditTime: Date? = nil,
        photoLibraryCreationDate: Date? = nil,
        externalIdentifierIsUnique: Bool = false,
        materialize: (@Sendable () async throws -> UploadResourceDescriptor)? = nil,
        materializeWithProgress: (
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor
        )? = nil,
        cleanup: (@Sendable () -> Void)? = nil,
        omitsMissingPairedVideo: Bool = false
    ) {
        self.omitsMissingPairedVideo = omitsMissingPairedVideo
        self.candidate = candidate
        let photos = additionalMetadata.first { $0.name == "iOS.photos" }.flatMap {
            try? JSONDecoder().decode(PhotoUploadMetadataEncoder.IOSPhotos.self, from: $0.utf8JsonValue)
        }
        self.photoLibraryEditTime = photoLibraryEditTime
        let originalRoles = ["photoKit.originalPhoto.", "photoKit.originalVideo."]
        let originals = Set(
            secondaries.compactMap { secondary -> String? in
                guard originalRoles.contains(where: secondary.descriptor.source.resource.rawValue.hasPrefix),
                    let digest = secondary.descriptor.precomputedSHA1Digest
                else { return nil }
                return UploadContentSHA1.hexString(digest: digest)
            })
        self.descriptor = descriptor.withPhotoLibraryIdentity(
            identifier: photos?.iCloudID ?? candidate.snapshot.externalIdentity?.identifier,
            edited: candidate.snapshot.editRevision == .unavailable, editTime: photoLibraryEditTime,
            creationDate: photoLibraryCreationDate, isUnique: externalIdentifierIsUnique,
            originalSHA1Hex: originals)
        self.mediaType = mediaType
        self.additionalMetadata = additionalMetadata
        self.tags = tags
        self.captureDate = captureDate
        self.secondaries = secondaries
        self.materializeWithProgress = Self.materializer(materialize, withProgress: materializeWithProgress)
        self.cleanup = cleanup
    }
}

/// Rechecks the runner's admission immediately before a source read starts network access.
public typealias BackupResourceReadAdmission = @Sendable () throws -> Void

/// Platform seam: turn a persisted queue entry back into a readable local resource.
/// Contract: return `nil` when the source is verifiably gone, which removes its queue work.
/// Throw for transient problems so the runner applies its retry policy.
public protocol BackupResourceResolving: Sendable {
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource?
    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource?
    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission
    ) async throws -> BackupResolvedResource?
    /// `omittingMissingPairedVideo` is true on the last check of a row whose file Photos reports missing. A resolver
    /// may then leave out a Live Photo video that Photos still reports missing and set `omitsMissingPairedVideo`.
    /// Every other failure throws as usual.
    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission,
        omittingMissingPairedVideo: Bool
    ) async throws -> BackupResolvedResource?
}

public extension BackupResourceResolving {
    /// A resolver without Live Photo videos resolves the whole entry and never leaves anything out.
    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission,
        omittingMissingPairedVideo: Bool
    ) async throws -> BackupResolvedResource? {
        try await resolve(entry, onPreparationProgress: onPreparationProgress, readAdmission: readAdmission)
    }

    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission
    ) async throws -> BackupResolvedResource? {
        try readAdmission()
        return try await resolve(entry, onPreparationProgress: onPreparationProgress)
    }

    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        try await resolve(entry)
    }
}

/// Routes each queue entry to the resolver for its source kind, so one runner can drain a
/// queue containing mixed sources (folder files + photo-library assets) without semantic forks.
public struct CompositeBackupResourceResolver: BackupResourceResolving {
    private let resolvers: [UploadSourceIdentity.Kind: any BackupResourceResolving]

    public init(_ resolvers: [UploadSourceIdentity.Kind: any BackupResourceResolving]) {
        self.resolvers = resolvers
    }

    public func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await resolver(for: entry).resolve(entry)
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        try await resolver(for: entry).resolve(entry, onPreparationProgress: onPreparationProgress)
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission
    ) async throws -> BackupResolvedResource? {
        try await resolver(for: entry).resolve(
            entry, onPreparationProgress: onPreparationProgress, readAdmission: readAdmission)
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission,
        omittingMissingPairedVideo: Bool
    ) async throws -> BackupResolvedResource? {
        try await resolver(for: entry).resolve(
            entry, onPreparationProgress: onPreparationProgress, readAdmission: readAdmission,
            omittingMissingPairedVideo: omittingMissingPairedVideo)
    }

    private func resolver(for entry: UploadBackupSyncQueueEntry) throws -> any BackupResourceResolving {
        guard let resolver = resolvers[entry.source.kind] else {
            throw UploadError.backend("no backup resolver registered for source kind \(entry.source.kind.rawValue)")
        }
        return resolver
    }
}

/// The file-URL resolver shared by every platform's folder/file backup path. Reads current
/// attributes so a file edited after the scan is backed up as it exists now. Security-scoped
/// access (macOS sandbox bookmarks) is session-scoped by the platform layer around the whole
/// sync pass - this resolver only touches the file system.
public struct FileBackupResourceResolver: BackupResourceResolving {
    public init() {}

    public func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard entry.source.kind == .fileURL else {
            throw UploadError.backend("unsupported backup source kind \(entry.source.kind.rawValue)")
        }
        let url = URL(fileURLWithPath: entry.source.identifier)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }

        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let fileFallback = UploadCaptureDateReader.fileSystemFallback(from: attributes, default: modified)
        let captureDate = await UploadCaptureDateReader.captureDate(for: url, fallback: fileFallback)
        let filename = url.lastPathComponent

        let snapshot = UploadBackupAssetSnapshot(
            source: entry.source,
            revision: UploadBackupRevision(date: modified),
            editRevision: .unavailable,
            resourceCount: 1
        )
        let descriptor = UploadResourceDescriptor(
            source: entry.source,
            fileURL: url,
            filename: filename,
            fileSize: fileSize,
            modificationDate: modified
        )
        return BackupResolvedResource(
            candidate: UploadBackupAssetCandidate(snapshot: snapshot, originalFilename: filename, byteCount: fileSize),
            descriptor: descriptor,
            mediaType: SupportedMedia.mimeType(for: url) ?? "application/octet-stream",
            captureDate: captureDate
        )
    }
}
