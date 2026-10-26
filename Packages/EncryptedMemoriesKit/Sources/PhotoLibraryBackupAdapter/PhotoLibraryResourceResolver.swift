import Foundation
import Photos
import PhotosCore
import UniformTypeIdentifiers
import UploadCore
import os

/// Resolves a PhotoKit queue entry in two stages. It first streams each original only to compute its
/// identity (O(chunk) memory, no temp file). Core materializes verbatim bytes into the bounded temp
/// store only if dedupe returns `.upload`. An original that exists only in iCloud is the exception: its
/// identity pass downloads it once and stages it, and the upload reuses that file. HEIC stays HEIC and
/// MOV stays MOV; `PHImageManager` is never used.
public struct PhotoLibraryResourceResolver: BackupResourceResolving {
    /// A new photo the camera still processes (deferred photo processing: a `.photoProxy` resource, alone or
    /// next to a preliminary image) waits up to this long after its capture for the finished one. The change
    /// notification for the finished photo triggers its backup; no timer polls. One check at the end of the
    /// window backs up whatever version exists, so a photo whose processing never finishes still gets a copy.
    static let processingWaitWindow: TimeInterval = 600
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "Backup")

    private let tempStore: BackupTempFileStore
    private let cloudIdentifierProvider: @Sendable (String) -> String?

    public init(
        tempStore: BackupTempFileStore,
        cloudIdentifierProvider: @Sendable @escaping (String) -> String? = { _ in nil }
    ) {
        self.tempStore = tempStore
        self.cloudIdentifierProvider = cloudIdentifierProvider
    }

    public func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await resolve(entry, onPreparationProgress: { _ in })
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        try await resolve(entry, onPreparationProgress: onPreparationProgress, readAdmission: {})
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission
    ) async throws -> BackupResolvedResource? {
        try await resolve(
            entry, onPreparationProgress: onPreparationProgress, readAdmission: readAdmission,
            omittingMissingPairedVideo: false)
    }

    public func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission,
        omittingMissingPairedVideo: Bool
    ) async throws -> BackupResolvedResource? {
        try readAdmission()
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested { return try await UpgradeTestPhotoLibrary.resolve(entry) }
        #endif
        guard entry.source.kind == .photoLibraryAsset else {
            throw UploadError.backend("photo resolver received source kind \(entry.source.kind.rawValue)")
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [entry.source.identifier], options: nil)
        guard let asset = fetch.firstObject else {
            return nil  // A deleted or unselected asset has no queue work.
        }

        let info = PhotoKitAssetMapper.info(for: asset)
        // The camera still processes the photo while its resources list a proxy, whether it is the only image
        // or listed next to a preliminary one. Checked before planning, which never picks the proxy as primary.
        let age = asset.creationDate.map { Date().timeIntervalSince($0) } ?? .infinity
        if age < Self.processingWaitWindow {
            // Resource roles only, for checking deferred camera processing on a device; no names or identifiers.
            let roles = info.resources.map(\.role.rawValue).sorted().joined(separator: ",")
            Self.logger.notice("[Backup] new photo ageS=\(Int(age), privacy: .public) roles=\(roles, privacy: .public)")
        }
        if info.resources.contains(where: { $0.role == .photoProxy }), age < Self.processingWaitWindow,
            let created = asset.creationDate
        {
            throw UploadError.sourceNotReady(
                entry.originalFilename, until: created.addingTimeInterval(Self.processingWaitWindow))
        }
        if let until = PhotoBackupAssetPlanner.notReadyUntil(for: info, now: Date()) {
            // Edit state only, for checking edits on a device; no names or identifiers.
            let roles = info.resources.map(\.role.rawValue).sorted().joined(separator: ",")
            let editAge = info.adjustmentTimestamp.map { Int(Date().timeIntervalSince($0)) } ?? -1
            Self.logger.notice(
                "[Backup] edit not ready adjusted=\(info.hasAdjustments, privacy: .public) editAgeS=\(editAge, privacy: .public) roles=\(roles, privacy: .public)"
            )
            throw UploadError.sourceNotReady(entry.originalFilename, until: until)
        }
        guard let (plan, candidate) = try Self.livePlan(for: info, filename: entry.originalFilename) else {
            return nil
        }
        guard let primaryResource = PhotoKitAssetMapper.resource(for: plan.primary.role, of: asset) else {
            throw UploadError.sourceReportedMissing(plan.primary.uploadFilename)
        }

        // Stable descriptor dates: capture time drives the remote timeline; the descriptor's
        // modification date must not be the temp file's mtime (that would defeat manifest hash
        // reuse across re-exports), so it uses the asset's stable creation date.
        let captureDate = asset.creationDate ?? asset.modificationDate ?? Date()
        let cloudIdentifier = cloudIdentifierProvider(entry.source.identifier)
        let additionalMetadata = try PhotoLibraryUploadMetadataBuilder.metadata(
            for: asset,
            cloudIdentifier: cloudIdentifier
        )
        let traits = PhotoBackupAssetTraits(
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isPortrait: asset.mediaSubtypes.contains(.photoDepthEffect),
            isPanorama: asset.mediaSubtypes.contains(.photoPanorama),
            isRaw: UTType(primaryResource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        )
        // Track deferred exports so the runner can release them as soon as the entry settles.
        let exportedURLs = ExportedURLBox()
        var didResolve = false
        defer {
            if !didResolve {
                for url in exportedURLs.urls { tempStore.discard(url) }
            }
        }
        let resourceCount = max(1, 1 + plan.secondaries.count)
        let identityProgress: @Sendable (Int, Double) -> Void = { completedResources, fraction in
            let aggregate = (Double(completedResources) + min(1, max(0, fraction))) / Double(resourceCount)
            onPreparationProgress(.init(phase: .identity, fraction: aggregate))
        }
        let primaryIdentity = try await readIdentity(
            primaryResource,
            filename: plan.primary.uploadFilename,
            tracking: exportedURLs, readAdmission: readAdmission
        ) { fraction in
            identityProgress(0, fraction)
        }
        let primaryDescriptor = Self.identityDescriptor(
            source: candidate.snapshot.source,
            identity: primaryIdentity,
            filename: plan.primary.uploadFilename,
            stableDate: captureDate,
            tempStore: tempStore
        )
        let tempStore = self.tempStore
        let primaryMaterializer = Self.makeMaterializer(
            ResourceMaterialization(
                kind: .primary,
                ownerIdentifier: entry.source.identifier,
                role: plan.primary.role,
                ordinal: 0,
                filename: plan.primary.uploadFilename,
                expectedByteCount: primaryIdentity.byteCount,
                source: candidate.snapshot.source,
                stableDate: captureDate,
                modifiedAtResolve: asset.modificationDate,
                resourceIndex: 0,
                resourceCount: resourceCount
            ),
            refetch: .photos,
            staged: StagedExport(primaryIdentity.staged),
            tempStore: tempStore,
            tracking: exportedURLs,
            readAdmission: readAdmission
        )

        // A series main photo carries its members as secondaries. Each member's bytes and capture date come
        // from the member's own asset, not from the main photo.
        let burstMembers = PhotoKitAssetMapper.burstPlan(for: asset)?.members ?? []
        var secondaries: [BackupSecondaryResource] = []
        var omitsMissingPairedVideo = false
        for (secondaryIndex, item) in plan.secondaries.enumerated() {
            let owner: PHAsset
            let role: PhotoBackupAssetInfo.Resource.Role
            let ordinal: Int
            if item.role == .burstMember {
                guard burstMembers.indices.contains(item.ordinal),
                    let member = PhotoKitAssetMapper.asset(
                        withLocalIdentifier: burstMembers[item.ordinal].localIdentifier)
                else {
                    throw UploadError.sourceReportedMissing(item.uploadFilename)
                }
                owner = member
                role = burstMembers[item.ordinal].exportedRole
                ordinal = 0
            } else {
                owner = asset
                role = item.role
                ordinal = item.ordinal
            }
            let identity: IdentityResult
            do {
                guard let resource = PhotoKitAssetMapper.resource(for: role, ordinal: ordinal, of: owner) else {
                    throw UploadError.sourceReportedMissing(item.uploadFilename)
                }
                identity = try await readIdentity(
                    resource, filename: item.uploadFilename, tracking: exportedURLs, readAdmission: readAdmission
                ) { fraction in
                    identityProgress(secondaryIndex + 1, fraction)
                }
            } catch let error
                where Self.omitsSecondary(
                    item, failingWith: error, omittingMissingPairedVideo: omittingMissingPairedVideo)
            {
                // No names or identifiers, for checking on a device that only this video is left out.
                Self.logger.notice("[Backup] Live Photo video left out: Photos reports it missing after its checks")
                omitsMissingPairedVideo = true
                continue
            }
            let source = UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: entry.source.identifier,
                resource: item.sourceResource
            )
            let isBurstMember = item.role == .burstMember
            let stableDate = isBurstMember ? owner.creationDate ?? captureDate : captureDate
            let materializer = Self.makeMaterializer(
                ResourceMaterialization(
                    kind: .secondary(isBurstMember: isBurstMember),
                    ownerIdentifier: owner.localIdentifier,
                    role: role,
                    ordinal: ordinal,
                    filename: item.uploadFilename,
                    expectedByteCount: identity.byteCount,
                    source: source,
                    stableDate: stableDate,
                    modifiedAtResolve: owner.modificationDate,
                    resourceIndex: secondaryIndex + 1,
                    resourceCount: resourceCount
                ),
                refetch: .photos,
                staged: StagedExport(identity.staged),
                tempStore: tempStore,
                tracking: exportedURLs,
                readAdmission: readAdmission
            )
            secondaries.append(
                BackupSecondaryResource(
                    descriptor: Self.identityDescriptor(
                        source: source,
                        identity: identity,
                        filename: item.uploadFilename,
                        stableDate: stableDate,
                        tempStore: tempStore
                    ),
                    mediaType: item.mimeType
                        ?? SupportedMedia.mimeType(for: URL(fileURLWithPath: item.uploadFilename))
                        ?? "application/octet-stream",
                    additionalMetadata: isBurstMember
                        ? try PhotoLibraryUploadMetadataBuilder.metadata(
                            for: asset,
                            cloudIdentifier: cloudIdentifierProvider(entry.source.identifier),
                            memberCaptureDate: stableDate
                        )
                        : additionalMetadata,
                    materializeWithProgress: materializer
                ))
        }

        didResolve = true
        return BackupResolvedResource(
            candidate: candidate,
            descriptor: primaryDescriptor,
            mediaType: plan.primary.mimeType
                ?? SupportedMedia.mimeType(for: URL(fileURLWithPath: plan.primary.uploadFilename))
                ?? "application/octet-stream",
            additionalMetadata: additionalMetadata,
            tags: traits.protonTags,
            captureDate: captureDate,
            secondaries: secondaries,
            photoLibraryEditTime: info.adjustmentTimestamp,
            photoLibraryCreationDate: info.creationDate,
            // The mapping lookup is expensive (PHCloudIdentifier.h), so only an edit, which can replace another
            // device's photo, pays for it.
            // A reverted photo keeps its adjustment timestamp but has no adjustments, so it pays nothing.
            externalIdentifierIsUnique: info.hasAdjustments
                && Self.isUniqueCloudIdentifier(cloudIdentifier, localIdentifier: entry.source.identifier),
            materializeWithProgress: primaryMaterializer,
            cleanup: { for url in exportedURLs.urls { tempStore.discard(url) } },
            omitsMissingPairedVideo: omitsMissingPairedVideo
        )
    }

    /// True while Photos grants access and lists at least one asset. An empty asset query proves a source gone only then.
    static func libraryAnswersAssetQueries() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        let options = PHFetchOptions()
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).firstObject != nil
    }

    /// True when a photo that the backup could not resolve is gone from Photos: the library answers asset queries and
    /// does not list the photo. A library without access, on an offline volume or not loaded yet proves nothing, and a
    /// photo that Photos still lists, for example a series photo of another main photo, stays in the catalog.
    static func photosNoLongerLists(
        _ identifier: String,
        libraryAnswers: () -> Bool = libraryAnswersAssetQueries,
        listsAsset: (String) -> Bool = { PhotoKitAssetMapper.asset(withLocalIdentifier: $0) != nil }
    ) -> Bool {
        guard libraryAnswers() else { return false }
        return !listsAsset(identifier)
    }

    /// The backup plan of the asset as Photos lists it now. Nil when the asset has no backup work of its own: a series
    /// photo that belongs to another main photo. An asset that lists no main file takes the checks of a file that
    /// Photos reports as missing, so it never leaves the queue and comes back through catalog recovery on every pass.
    static func livePlan(
        for info: PhotoBackupAssetInfo, filename: String
    ) throws -> (PhotoBackupExportPlan, UploadBackupAssetCandidate)? {
        guard let plan = PhotoBackupAssetPlanner.exportPlan(for: info),
            let candidate = PhotoBackupAssetPlanner.candidate(for: info)
        else {
            if info.resources.contains(where: { $0.role == .burstMainReference }) { return nil }
            throw UploadError.sourceReportedMissing(filename)
        }
        return (plan, candidate)
    }

    /// True when the compound leaves out `item` after its read failed with `error`: only the Live Photo video, only
    /// when Photos reports it missing, and only on the last check that the runner allows a missing file. A file that
    /// waits for iCloud, a denied read, any other error, and every other resource keep their failure.
    static func omitsSecondary(
        _ item: PhotoBackupExportPlan.Item, failingWith error: any Error, omittingMissingPairedVideo: Bool
    ) -> Bool {
        guard omittingMissingPairedVideo, item.sourceResource == .livePairedVideo,
            case .sourceReportedMissing? = error as? UploadError
        else { return false }
        return true
    }

    private static func isUniqueCloudIdentifier(_ identifier: String?, localIdentifier: String) -> Bool {
        guard let identifier,
            let cloud = PHCloudIdentifier(archivalStringValue: identifier),
            let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [cloud])[cloud],
            case .success(let mapped) = mapping
        else { return false }
        return mapped == localIdentifier
    }

    /// Collects committed export URLs so the whole compound can be discarded in one cleanup call.
    /// A reference box (not an inout array) so it survives the async export hops and is captured
    /// by the `cleanup` closure.
    final class ExportedURLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func append(_ url: URL) { lock.withLock { stored.append(url) } }
        var urls: [URL] { lock.withLock { stored } }
    }

    private struct IdentityResult {
        let byteCount: Int64
        let sha1Digest: Data
        /// The original in the temp store when the identity pass had to download it from iCloud.
        let staged: ExportResult?
    }

    /// Gives the file that the identity pass staged to the first export of the resource, once. A later export of the
    /// same resource reads the original again.
    final class StagedExport: @unchecked Sendable {
        private let lock = NSLock()
        private var export: ExportResult?

        init(_ export: ExportResult?) { self.export = export }

        func take() -> ExportResult? {
            lock.withLock {
                defer { export = nil }
                return export
            }
        }
    }

    private static func identityDescriptor(
        source: UploadSourceIdentity,
        identity: IdentityResult,
        filename: String,
        stableDate: Date,
        tempStore: BackupTempFileStore
    ) -> UploadResourceDescriptor {
        return UploadResourceDescriptor(
            source: source,
            fileURL: tempStore.directory.appendingPathComponent(".not-materialized"),
            filename: filename,
            fileSize: identity.byteCount,
            modificationDate: stableDate,
            precomputedSHA1Digest: identity.sha1Digest
        )
    }

    private static func materializedDescriptor(
        source: UploadSourceIdentity,
        export: ExportResult,
        filename: String,
        stableDate: Date
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: export.url,
            filename: filename,
            fileSize: export.byteCount,
            modificationDate: stableDate,
            precomputedSHA1Digest: export.sha1Digest
        )
    }

    struct ExportResult {
        let url: URL
        let byteCount: Int64
        let sha1Digest: Data
    }

    /// How a deferred materialization reads its asset again. The two roles differ on purpose: the primary resource
    /// belongs to the asset that the queue entry names, which the default fetch of Photos lists. A secondary resource
    /// can belong to a series member, which the default fetch hides, so its lookup includes all series assets.
    struct MaterializationRefetch: Sendable {
        let primary: @Sendable (String) -> PHAsset?
        let secondary: @Sendable (String) -> PHAsset?

        static let photos = MaterializationRefetch(
            primary: { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject },
            secondary: { PhotoKitAssetMapper.asset(withLocalIdentifier: $0) }
        )
    }

    /// One resource that is exported after Core selected it for upload.
    struct ResourceMaterialization: Sendable {
        enum Kind: Sendable, Equatable {
            case primary
            case secondary(isBurstMember: Bool)
        }

        let kind: Kind
        /// The asset that owns the resource: the queue entry's asset, or the series member of a burst resource.
        let ownerIdentifier: String
        let role: PhotoBackupAssetInfo.Resource.Role
        let ordinal: Int
        let filename: String
        let expectedByteCount: Int64
        let source: UploadSourceIdentity
        let stableDate: Date
        /// The modification date of the owner when the identity pass read the resource.
        let modifiedAtResolve: Date?
        let resourceIndex: Int
        let resourceCount: Int
    }

    /// The deferred export of one resource, for the primary and every secondary resource alike. It reads the owner
    /// again at export time. A missing owner is a missing file, except for a series member: that is an asset of its
    /// own, and the main photo is still listed, so Photos reports the source missing.
    static func makeMaterializer(
        _ resource: ResourceMaterialization,
        refetch: MaterializationRefetch,
        staged: StagedExport,
        tempStore: BackupTempFileStore,
        tracking exportedURLs: ExportedURLBox,
        readAdmission: @escaping BackupResourceReadAdmission
    ) -> @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor {
        { progress in
            let currentAsset: PHAsset?
            switch resource.kind {
            case .primary: currentAsset = refetch.primary(resource.ownerIdentifier)
            case .secondary: currentAsset = refetch.secondary(resource.ownerIdentifier)
            }
            guard let currentAsset else {
                if resource.kind == .secondary(isBurstMember: true) {
                    throw UploadError.sourceReportedMissing(resource.filename)
                }
                throw UploadError.fileMissing(resource.filename)
            }
            guard
                let currentResource = PhotoKitAssetMapper.resource(
                    for: resource.role, ordinal: resource.ordinal, of: currentAsset
                )
            else {
                throw UploadError.sourceReportedMissing(resource.filename)
            }
            let export = try await Self.export(
                currentResource,
                uploadFilename: resource.filename,
                expectedBytes: resource.expectedByteCount,
                staged: staged,
                sourceUnchanged: currentAsset.modificationDate == resource.modifiedAtResolve,
                tempStore: tempStore,
                tracking: exportedURLs,
                readAdmission: readAdmission,
                onProgress: {
                    progress(
                        .init(
                            phase: .materializing,
                            fraction: $0,
                            resourceIndex: resource.resourceIndex,
                            resourceCount: resource.resourceCount
                        ))
                }
            )
            return Self.materializedDescriptor(
                source: resource.source,
                export: export,
                filename: resource.filename,
                stableDate: resource.stableDate
            )
        }
    }

    /// PhotoKit may report very fine-grained iCloud progress. One-percent buckets cap cross-actor/UI churn
    /// while still updating often enough that iOS can observe continued-processing liveness.
    private final class FractionProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastBucket = -1
        private let handler: @Sendable (Double) -> Void

        init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

        func publish(_ fraction: Double) {
            let clamped = min(1, max(0, fraction))
            let bucket = Int((clamped * 100).rounded(.down))
            let shouldPublish = lock.withLock {
                guard bucket > lastBucket else { return false }
                lastBucket = bucket
                return true
            }
            if shouldPublish { handler(Double(bucket) / 100) }
        }
    }

    /// Hashes one PhotoKit resource. An original on the device is read without network access and without temp I/O:
    /// the common path for a library that is already backed up. An original that exists only in iCloud downloads
    /// once: the same pass hashes it and stages it in the temp store, so its upload does not download it again.
    private func readIdentity(
        _ resource: PHAssetResource,
        filename: String,
        tracking exported: ExportedURLBox,
        readAdmission: @escaping BackupResourceReadAdmission,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> IdentityResult {
        let progressGate = FractionProgressGate(onProgress)
        let sha1 = UploadSHA1Accumulator()
        final class ReadBox: @unchecked Sendable {
            var bytes: Int64 = 0
        }
        let box = ReadBox()
        do {
            try await Self.requestData(
                for: resource, networkAccessAllowed: false, progressGate: progressGate
            ) { data in
                sha1.update(data)
                box.bytes += Int64(data.count)
            }
            progressGate.publish(1)
            return IdentityResult(byteCount: box.bytes, sha1Digest: sha1.finalizeDigest(), staged: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Not on this device (PhotoKit reports that network access is required). Any other local failure also
            // gets one networked pass, which reports the definitive error.
        }

        let knownSize = Self.knownSize(of: resource)
        let exactSize = Self.exactStagingSize(knownSize: knownSize, tempStore: tempStore)
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: filename, expectedBytes: exactSize)
        do {
            try await Self.requestData(
                for: resource, networkAccessAllowed: true, progressGate: progressGate, readAdmission: readAdmission
            ) { data in
                sink.receive(data)
            }
        } catch {
            sink.abandon()
            throw Self.normalizedPhotoKitError(error, filename: filename)
        }
        progressGate.publish(1)
        let result = sink.finish()
        Self.logger.notice(
            "[Backup] original from iCloud staged=\(result.stagedURL != nil, privacy: .public) sizeKnown=\(knownSize != nil, privacy: .public) exact=\(exactSize != nil, privacy: .public)"
        )
        let staged = result.stagedURL.map { url in
            exported.append(url)
            return ExportResult(url: url, byteCount: result.byteCount, sha1Digest: result.sha1Digest)
        }
        return IdentityResult(byteCount: result.byteCount, sha1Digest: result.sha1Digest, staged: staged)
    }

    /// Materializes one resource only after Core selected it for upload. It reuses the file the identity pass
    /// staged while the photo is unchanged; otherwise chunks go straight to the temp file and are hashed again so
    /// the runner can reject a source that changed after preflight.
    private static func export(
        _ resource: PHAssetResource,
        uploadFilename: String,
        expectedBytes: Int64,
        staged: StagedExport,
        sourceUnchanged: Bool,
        tempStore: BackupTempFileStore,
        tracking exported: ExportedURLBox,
        readAdmission: @escaping BackupResourceReadAdmission,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        if let export = staged.take() {
            // Counts how often a staged original is reused, to check on a device that one download is the rule.
            logger.notice("[Backup] staged original reused=\(sourceUnchanged, privacy: .public)")
            if sourceUnchanged {
                onProgress(1)
                return export
            }
            // The photo changed after its identity pass: read it again, so the runner compares current bytes.
            tempStore.discard(export.url)
        }
        // A file that cannot fit fails at once with the space it needs, not after part of the copy.
        try tempStore.ensureFreeSpace(forAdditionalBytes: expectedBytes)
        let partialURL = try tempStore.reserve(filename: uploadFilename, expectedBytes: expectedBytes)
        do {
            guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                throw UploadError.backend("PhotoKit export file could not be created")
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            let sha1 = UploadSHA1Accumulator()
            let progressGate = FractionProgressGate(onProgress)

            final class WriteBox: @unchecked Sendable {
                var bytes: Int64 = 0
            }
            let box = WriteBox()
            do {
                try await requestData(
                    for: resource, networkAccessAllowed: true, progressGate: progressGate, readAdmission: readAdmission
                ) { data in
                    try tempStore.recordWrite(to: partialURL, byteCount: data.count)
                    try handle.write(contentsOf: data)
                    sha1.update(data)
                    box.bytes += Int64(data.count)
                    if expectedBytes > 0 {
                        progressGate.publish(Double(box.bytes) / Double(expectedBytes))
                    }
                }
            } catch {
                throw normalizedPhotoKitError(error, filename: uploadFilename)
            }
            progressGate.publish(1)

            let finalURL = try tempStore.commit(partialURL)
            exported.append(finalURL)
            let digest = sha1.finalizeDigest()
            return ExportResult(url: finalURL, byteCount: box.bytes, sha1Digest: digest)
        } catch {
            tempStore.discard(partialURL)
            throw error
        }
    }

    /// Streams one PhotoKit resource into `receive`, which runs under the liveness guard's lock. A throwing `receive`
    /// ends the request with its error. PhotoKit errors arrive unchanged; callers normalize them.
    private static func requestData(
        for resource: PHAssetResource,
        networkAccessAllowed: Bool,
        progressGate: FractionProgressGate,
        readAdmission: @escaping BackupResourceReadAdmission = {},
        receive: @escaping (Data) throws -> Void
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = networkAccessAllowed
        let manager = PHAssetResourceManager.default()
        let networkAdmission: BackupResourceReadAdmission = {
            if networkAccessAllowed { try readAdmission() }
        }
        let liveness = PhotoKitResourceRequestLivenessGuard<PHAssetResourceDataRequestID>(
            requestAdmission: networkAdmission,
            cancelRequest: { manager.cancelDataRequest($0) }
        )
        options.progressHandler = {
            liveness.markActivity()
            progressGate.publish($0)
        }
        try await liveness.waitForCompletion {
            manager.requestData(for: resource, options: options) { data in
                liveness.receiveData { try receive(data) }
            } completionHandler: { error in
                liveness.complete(error: error)
            }
        }
    }

    /// The size an iCloud original may reserve for staging. Photos keeps its own copy of an original it downloads, and
    /// staging writes a second one, so the size counts only when both fit. Otherwise the original is only hashed now:
    /// the duplicate check never waits for space, because a photo already in Proton needs no copy at all.
    static func exactStagingSize(knownSize: Int64?, tempStore: BackupTempFileStore) -> Int64? {
        guard let knownSize, knownSize <= Int64.max / 2,
            tempStore.hasFreeSpace(forAdditionalBytes: knownSize * 2)
        else { return nil }
        return knownSize
    }

    /// The size PhotoKit reports before a download (iOS and macOS 27); nil before that or while unknown.
    static func knownSize(of resource: PHAssetResource) -> Int64? {
        if #available(iOS 27, macOS 27, *), let size = resource.dataSize, size > 0 {
            return Int64(size)
        }
        return nil
    }

    /// Converts stable PhotoKit failure codes into Core upload categories. Waits and storage conditions stay
    /// retryable. A file that Photos cannot hand out while the asset is still listed is checked again a few times and
    /// then shown as missing.
    static func normalizedPhotoKitError(_ error: Error, filename: String) -> Error {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain,
            let code = PHPhotosError.Code(rawValue: nsError.code)
        else { return error }

        switch code {
        case .identifierNotFound, .invalidResource:
            return UploadError.sourceReportedMissing(filename)
        case .missingResource:
            // A download from iCloud that stops part-way can also report a missing resource, so the photo is not
            // treated as gone at once.
            logger.notice("PhotoKit read reports a missing resource: PHPhotosError \(nsError.code, privacy: .public)")
            return UploadError.sourceReportedMissing(filename)
        case .accessRestricted, .accessUserDenied:
            return UploadError.permissionDenied(filename)
        case .networkAccessRequired, .networkError, .libraryVolumeOffline, .operationInterrupted:
            // The original is in iCloud or on an offline library volume: the backup waits and tries again by itself.
            // The wait is about Photos, not the Proton connection, so it must not slow down photos on the device.
            // The PhotoKit code is logged first, because support needs it to tell the four causes apart.
            logger.notice("PhotoKit read waits: PHPhotosError \(nsError.code, privacy: .public)")
            return UploadError.sourceUnavailable(filename)
        case .notEnoughSpace:
            return BackupTempFileStore.BackupTempFileError.diskBudgetExceeded
        default:
            return error
        }
    }
}
