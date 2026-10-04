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
        guard let plan = PhotoBackupAssetPlanner.exportPlan(for: info),
            let candidate = PhotoBackupAssetPlanner.candidate(for: info),
            let primaryResource = PhotoKitAssetMapper.resource(for: plan.primary.role, of: asset)
        else {
            return nil
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
            tracking: exportedURLs
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
        let primaryRole = plan.primary.role
        let primaryByteCount = primaryIdentity.byteCount
        let primaryStaged = StagedExport(primaryIdentity.staged)
        let modifiedAtResolve = asset.modificationDate
        let localIdentifier = entry.source.identifier
        let tempStore = self.tempStore
        let primaryMaterializer:
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor = {
                progress in
                guard
                    let currentAsset = PHAsset.fetchAssets(
                        withLocalIdentifiers: [localIdentifier], options: nil
                    ).firstObject,
                    let resource = PhotoKitAssetMapper.resource(for: primaryRole, of: currentAsset)
                else {
                    throw UploadError.fileMissing(plan.primary.uploadFilename)
                }
                let export = try await Self.export(
                    resource,
                    uploadFilename: plan.primary.uploadFilename,
                    expectedBytes: primaryByteCount,
                    staged: primaryStaged,
                    sourceUnchanged: currentAsset.modificationDate == modifiedAtResolve,
                    tempStore: tempStore,
                    tracking: exportedURLs,
                    onProgress: {
                        progress(
                            .init(
                                phase: .materializing,
                                fraction: $0,
                                resourceIndex: 0,
                                resourceCount: resourceCount
                            ))
                    }
                )
                return Self.materializedDescriptor(
                    source: candidate.snapshot.source,
                    export: export,
                    filename: plan.primary.uploadFilename,
                    stableDate: captureDate
                )
            }

        // A series main photo carries its members as secondaries. Each member's bytes and capture date come
        // from the member's own asset, not from the main photo.
        let burstMembers = PhotoKitAssetMapper.burstPlan(for: asset)?.members ?? []
        var secondaries: [BackupSecondaryResource] = []
        for (secondaryIndex, item) in plan.secondaries.enumerated() {
            let owner: PHAsset
            let role: PhotoBackupAssetInfo.Resource.Role
            let ordinal: Int
            if item.role == .burstMember {
                guard burstMembers.indices.contains(item.ordinal),
                    let member = PhotoKitAssetMapper.asset(
                        withLocalIdentifier: burstMembers[item.ordinal].localIdentifier)
                else {
                    throw UploadError.fileMissing(item.uploadFilename)
                }
                owner = member
                role = burstMembers[item.ordinal].exportedRole
                ordinal = 0
            } else {
                owner = asset
                role = item.role
                ordinal = item.ordinal
            }
            guard let resource = PhotoKitAssetMapper.resource(for: role, ordinal: ordinal, of: owner) else {
                throw UploadError.fileMissing(item.uploadFilename)
            }
            let identity = try await readIdentity(
                resource, filename: item.uploadFilename, tracking: exportedURLs
            ) { fraction in
                identityProgress(secondaryIndex + 1, fraction)
            }
            let source = UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: entry.source.identifier,
                resource: item.sourceResource
            )
            let isBurstMember = item.role == .burstMember
            let ownerIdentifier = owner.localIdentifier
            let stableDate = isBurstMember ? owner.creationDate ?? captureDate : captureDate
            let filename = item.uploadFilename
            let expectedByteCount = identity.byteCount
            let staged = StagedExport(identity.staged)
            let ownerModifiedAtResolve = owner.modificationDate
            let materializer: @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor = {
                progress in
                guard
                    let currentAsset = PhotoKitAssetMapper.asset(withLocalIdentifier: ownerIdentifier),
                    let currentResource = PhotoKitAssetMapper.resource(
                        for: role, ordinal: ordinal, of: currentAsset
                    )
                else {
                    throw UploadError.fileMissing(filename)
                }
                let export = try await Self.export(
                    currentResource,
                    uploadFilename: filename,
                    expectedBytes: expectedByteCount,
                    staged: staged,
                    sourceUnchanged: currentAsset.modificationDate == ownerModifiedAtResolve,
                    tempStore: tempStore,
                    tracking: exportedURLs,
                    onProgress: {
                        progress(
                            .init(
                                phase: .materializing,
                                fraction: $0,
                                resourceIndex: secondaryIndex + 1,
                                resourceCount: resourceCount
                            ))
                    }
                )
                return Self.materializedDescriptor(
                    source: source,
                    export: export,
                    filename: filename,
                    stableDate: stableDate
                )
            }
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
            cleanup: { for url in exportedURLs.urls { tempStore.discard(url) } }
        )
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
    private final class ExportedURLBox: @unchecked Sendable {
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
    private final class StagedExport: @unchecked Sendable {
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

    private struct ExportResult {
        let url: URL
        let byteCount: Int64
        let sha1Digest: Data
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
                for: resource, networkAccessAllowed: true, progressGate: progressGate
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
                    for: resource, networkAccessAllowed: true, progressGate: progressGate
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
        receive: @escaping (Data) throws -> Void
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = networkAccessAllowed
        let manager = PHAssetResourceManager.default()
        let liveness = PhotoKitResourceRequestLivenessGuard<PHAssetResourceDataRequestID>(
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

    /// Converts stable PhotoKit failure codes into Core upload categories. Network and storage conditions stay
    /// retryable; errors that prove the resource is gone remove it from backup work.
    static func normalizedPhotoKitError(_ error: Error, filename: String) -> Error {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain,
            let code = PHPhotosError.Code(rawValue: nsError.code)
        else { return error }

        switch code {
        case .missingResource, .identifierNotFound, .invalidResource:
            return UploadError.fileMissing(filename)
        case .accessRestricted, .accessUserDenied:
            return UploadError.permissionDenied(filename)
        case .networkAccessRequired, .networkError, .libraryVolumeOffline, .operationInterrupted:
            // The original is in iCloud or on an offline library volume: the backup waits and tries again by itself,
            // so these failures must use a transport code that the runner treats as transient, not burn its attempts.
            // The PhotoKit code is logged first, because support needs it to tell the four causes apart.
            logger.notice("PhotoKit read waits: PHPhotosError \(nsError.code, privacy: .public)")
            return UploadError.transport(code: NSURLErrorCannotLoadFromNetwork, message: nsError.localizedDescription)
        case .notEnoughSpace:
            return BackupTempFileStore.BackupTempFileError.diskBudgetExceeded
        default:
            return error
        }
    }
}
