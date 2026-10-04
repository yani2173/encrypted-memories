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

/// One secondary resource of a compound (a Live Photo's paired video): uploaded after the
/// primary with `mainPhotoUID` pointing at it, deduped through the same pipeline.
public struct BackupSecondaryResource: Sendable {
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
        if let materializeWithProgress {
            self.materializeWithProgress = materializeWithProgress
        } else if let materialize {
            self.materializeWithProgress = { _ in try await materialize() }
        } else {
            self.materializeWithProgress = nil
        }
    }

    public func materializedDescriptor() async throws -> UploadResourceDescriptor {
        try await materializedDescriptor(onPreparationProgress: { _ in })
    }

    public func materializedDescriptor(
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> UploadResourceDescriptor {
        if let materializeWithProgress {
            return try await materializeWithProgress(BackupResourcePreparationReporter(onPreparationProgress))
        }
        return descriptor
    }

    public var hasDeferredMaterialization: Bool {
        materializeWithProgress != nil
    }
}

/// A queue entry rematerialized into everything the pipeline and uploader need. The queue stores
/// only identities and revisions; adapters rebuild the concrete resource when work actually runs
/// (after a relaunch the original export/URL may be gone, so this is the resume seam).
public struct BackupResolvedResource: Sendable {
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
        cleanup: (@Sendable () -> Void)? = nil
    ) {
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
        if let materializeWithProgress {
            self.materializeWithProgress = materializeWithProgress
        } else if let materialize {
            self.materializeWithProgress = { _ in try await materialize() }
        } else {
            self.materializeWithProgress = nil
        }
        self.cleanup = cleanup
    }

    public func materializedDescriptor() async throws -> UploadResourceDescriptor {
        try await materializedDescriptor(onPreparationProgress: { _ in })
    }

    public func materializedDescriptor(
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> UploadResourceDescriptor {
        if let materializeWithProgress {
            return try await materializeWithProgress(BackupResourcePreparationReporter(onPreparationProgress))
        }
        return descriptor
    }

    public var hasDeferredMaterialization: Bool {
        materializeWithProgress != nil
    }
}

/// Platform seam: turn a persisted queue entry back into a readable local resource.
/// Contract: return `nil` when the source is verifiably gone, which removes its queue work.
/// Throw for transient problems so the runner applies its retry policy.
public protocol BackupResourceResolving: Sendable {
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource?
    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource?
}

public extension BackupResourceResolving {
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
        guard let resolver = resolvers[entry.source.kind] else {
            throw UploadError.backend("no backup resolver registered for source kind \(entry.source.kind.rawValue)")
        }
        return try await resolver.resolve(entry)
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        guard let resolver = resolvers[entry.source.kind] else {
            throw UploadError.backend("no backup resolver registered for source kind \(entry.source.kind.rawValue)")
        }
        return try await resolver.resolve(entry, onPreparationProgress: onPreparationProgress)
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
