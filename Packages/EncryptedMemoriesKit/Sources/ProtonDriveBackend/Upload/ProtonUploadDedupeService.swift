import CryptoKit
import Foundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK
import UploadCore

// MARK: - HMAC

/// The Proton photo identity HMAC: HMAC-SHA256 over the message's UTF-8 bytes, keyed with the
/// decrypted photos-root hash key, lowercase hex - byte-identical to the reference clients
/// (CommonCrypto there, CryptoKit here; the algorithm is the same).
enum ProtonPhotoHMAC {
    static func hex(message: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Duplicate service

enum ProtonUploadDedupeError: LocalizedError {
    /// The photos root link carried no `FolderProperties.NodeHashKey` - without it no
    /// Proton-compatible identity can be computed, so dedupe (and upload preflight) must fail
    /// rather than guess.
    case missingRootHashKey

    var errorDescription: String? {
        switch self {
        case .missingRootHashKey: "The photo library's hash key is unavailable."
        }
    }
}

/// `UploadDuplicateChecking` over the real Proton account: resolves and caches the photos-root
/// hash key through the Drive key chain (share key, root node key, and decrypted `NodeHashKey`),
/// computes the identity HMACs, and queries the find-duplicates endpoint.
///
/// Privacy: never logs names, hashes, or key material - only counts.
actor ProtonUploadDedupeService: UploadDuplicateChecking {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private let photosClient: EncryptedMemoriesClient
    private let contentIndexStore: any UploadRemoteContentIndexStore
    private let lineageIndexStore: UploadRemoteLineageIndexStore?
    private let contextProvider: @Sendable () async throws -> PhotosShareContext

    struct Material: Sendable {
        let context: PhotosShareContext
        let rootKey: UnlockableKey
        let hashKey: Data
        let epoch: String
    }

    private var material: Material?
    private var materialTask: Task<Material, any Error>?
    private var remoteContentIndexTask: Task<Void, any Error>?
    private var remoteIndexProgressHandlers: [UUID: @Sendable (UploadRemoteIndexPreparationProgress) async -> Void] =
        [:]
    private var remoteContentIndexGeneration = 0
    private var lastRemoteContentRefreshAt: Date?
    /// The one lineage rebuild of this launch for each key epoch; every lineage read waits for it.
    private var lineageRebuilds: [String: Task<Void, Never>] = [:]
    private static let remoteContentIndexLifetime: TimeInterval = 15
    /// Four metadata requests overlap network latency without producing the unbounded request fan-out
    /// used by the reference client. Decryption and the transactional store update remain serialized.
    private static let remoteMetadataRequestConcurrency = 4
    private static let remoteMetadataWindow =
        UploadDedupePipeline.protonDuplicateBatchSize * remoteMetadataRequestConcurrency

    init(
        session: DriveSession,
        crypto: DriveCrypto,
        photosClient: EncryptedMemoriesClient,
        contentIndexStore: any UploadRemoteContentIndexStore,
        lineageIndexStore: UploadRemoteLineageIndexStore? = nil,
        contextProvider: @Sendable @escaping () async throws -> PhotosShareContext
    ) {
        self.session = session
        self.crypto = crypto
        self.photosClient = photosClient
        self.contentIndexStore = contentIndexStore
        self.lineageIndexStore = lineageIndexStore
        self.contextProvider = contextProvider
    }

    // MARK: UploadDuplicateChecking

    func nameHash(forCorrectedName name: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: name, key: try await resolveMaterial().hashKey)
    }

    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        let key = try await resolveMaterial().hashKey
        return names.map { ProtonPhotoHMAC.hex(message: $0, key: key) }
    }

    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: sha1Hex, key: try await resolveMaterial().hashKey)
    }

    func hashKeyEpoch() async throws -> String {
        try await resolveMaterial().epoch
    }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        let context = try await resolveMaterial().context
        let entries = try await session.findPhotoDuplicates(volumeID: context.volumeID, nameHashes: nameHashes)
        DebugLog.log("[Dedupe] duplicates query hashes=\(nameHashes.count) matches=\(entries.count)")
        return entries.map { entry in
            RemotePhotoDuplicate(
                nameHash: entry.hash,
                contentHash: entry.contentHash,
                linkState: entry.linkState.flatMap(RemotePhotoDuplicate.LinkState.init(rawValue:)),
                linkID: entry.linkID,
                clientUID: entry.clientUID
            )
        }
    }

    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID] {
        do {
            let matches = try await SDKCancellableOperation.run { [photosClient] cancellationToken in
                try await photosClient.findPhotoDuplicates(
                    name: correctedName,
                    sha1: sha1Digest,
                    cancellationToken: cancellationToken
                )
            } cancel: { [photosClient] cancellationToken in
                try? await photosClient.cancelFindPhotoDuplicates(cancellationToken: cancellationToken)
            }
            DebugLog.log("[Dedupe] SDK exact query matches=\(matches.count)")
            return matches.map { PhotoUID(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        } catch {
            // Keep the already-proven detailed endpoint as a compatibility fallback if the
            // fresh wrapper/native route fails.
            DebugLog.log("[Dedupe] SDK exact query unavailable; using detailed fallback - \(error)")
            return []
        }
    }

    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        try await findDuplicates(contentHash: contentHash, limit: 1).first
    }

    func findDuplicates(contentHash: String, limit: Int) async throws -> [RemotePhotoDuplicate] {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        let records = contentIndexStore.remoteContentRecords(
            contentHash: contentHash,
            hashKeyEpoch: material.epoch,
            limit: limit
        )
        let health = contentIndexStore.remoteContentIndexHealth(hashKeyEpoch: material.epoch)
        if records.isEmpty, case .degraded(_, let unresolvedCount) = health {
            DebugLog.log(
                "[Dedupe] content miss with incomplete remote metadata; continuing availability-first unresolved=\(unresolvedCount)"
            )
        }
        return try ProtonRemoteContentIndexLookup.duplicates(
            contentHash: contentHash,
            records: records,
            health: health
        )
    }

    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        let context = try await resolveMaterial().context
        let metadata = try await session.fetchAlbumPhotoMetadata(volumeID: context.volumeID, linkIDs: [mainLinkID])
        return try Self.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID, in: metadata)
    }

    /// A response without the main photo or its related list cannot prove "not related", and that answer uploads
    /// bytes. Proton always sends the list, also when it is empty.
    static func relatedPhotoLinkIDs(
        ofMainLinkID mainLinkID: String, in metadata: [AlbumPhotoMetadata]
    ) throws
        -> Set<String>
    {
        guard let main = metadata.first(where: { $0.link.linkID == mainLinkID }),
            main.photo?.hasCompleteRelatedPhotoLinkIDs == true
        else {
            throw UploadError.backend("Related photos of the main photo are unavailable")
        }
        return Set(main.relatedPhotoLinkIDs)
    }

    private func attributes(of link: AlbumPhotoLinkBody, material: Material) throws -> DedupeXAttr? {
        guard let nodeKey = link.nodeKey, let passphrase = link.nodePassphrase,
            let xAttr = link.xAttr ?? link.fileProperties?.activeRevision?.xAttr
        else { return nil }
        let key = try crypto.unlockNode(key: nodeKey, passphrase: passphrase, parent: material.rootKey)
        let data = try crypto.decryptXAttr(xAttr, node: key)
        return try JSONDecoder().decode(DedupeXAttr.self, from: data)
    }

    func modificationDate(ofMainLink linkID: String) async throws -> Date? {
        let material = try await resolveMaterial()
        let metadata = try await session.fetchPhotoLinksMetadata(
            shareID: material.context.shareID, linkIDs: [linkID])
        guard let main = metadata.first(where: { $0.linkID == linkID }), main.state == 1,
            let photo = main.fileProperties?.activeRevision?.photo, photo.mainPhotoLinkID == nil,
            let raw = try attributes(of: main, material: material)?.iOSPhotos?.modificationTime
        else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? standard.date(from: raw)
    }

    func compound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        let material = try await resolveMaterial()
        let metadata = try await session.fetchAlbumPhotoMetadata(
            volumeID: material.context.volumeID, linkIDs: [linkID])
        guard let main = metadata.first(where: { $0.link.linkID == linkID }),
            main.photo?.hasCompleteRelatedPhotoLinkIDs == true
        else { return nil }
        let related = Set(main.relatedPhotoLinkIDs)
        // Generic metadata carries State and MainPhotoLinkID, unlike the Photos compound response.
        let ids = related.union([linkID]).sorted()
        var resources: [AlbumPhotoLinkBody] = []
        for start in stride(from: 0, to: ids.count, by: UploadDedupePipeline.protonDuplicateBatchSize) {
            let end = min(start + UploadDedupePipeline.protonDuplicateBatchSize, ids.count)
            resources.append(
                contentsOf: try await session.fetchPhotoLinksMetadata(
                    shareID: material.context.shareID, linkIDs: Array(ids[start..<end])))
        }
        guard let currentMain = resources.first(where: { $0.linkID == linkID }), currentMain.state == 1,
            let role = currentMain.fileProperties?.activeRevision?.photo, role.mainPhotoLinkID == nil
        else { return nil }
        var files: [String: UploadRemoteCompound.File] = [:]
        for resource in resources {
            guard let resourceID = resource.linkID, related.contains(resourceID) || resourceID == linkID
            else { return nil }
            guard resource.state == 1,
                resource.fileProperties?.activeRevision?.photo?.mainPhotoLinkID
                    == (resourceID == linkID ? nil : linkID),
                let armoredName = resource.name, let mimeType = resource.mimeType, !mimeType.isEmpty,
                let sha1 = try attributes(of: resource, material: material)?.common?.digests?.sha1,
                UploadContentSHA1.digest(fromHex: sha1) != nil
            else { return nil }
            let clearName = try crypto.decryptName(armoredName, parent: material.rootKey)
            let correctedName = ProtonPhotoNameCorrection.correctedName(for: clearName)
            guard !correctedName.isEmpty, files[resourceID] == nil else { return nil }
            files[resourceID] = UploadRemoteCompound.File(
                linkID: resourceID,
                contentHash: ProtonPhotoHMAC.hex(message: sha1.lowercased(), key: material.hashKey),
                nameHash: ProtonPhotoHMAC.hex(message: correctedName, key: material.hashKey), mimeType: mimeType)
        }
        guard Set(files.keys) == related.union([linkID]), let mainFile = files[linkID],
            let tags = main.photo?.tags
        else { return nil }
        let attributes = try attributes(of: currentMain, material: material)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        let date = attributes?.iOSPhotos?.modificationTime.flatMap {
            fractional.date(from: $0) ?? standard.date(from: $0)
        }
        let captureDate = main.photo?.captureTime.flatMap { value -> Date? in
            value.isFinite ? Date(timeIntervalSince1970: value) : nil
        }
        return UploadRemoteCompound(
            main: mainFile, related: related.sorted().compactMap { files[$0] }, tags: Set(tags),
            externalIdentifier: attributes?.iOSPhotos?.iCloudID, captureDate: captureDate, modificationDate: date)
    }

    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        guard !linkIDs.isEmpty else { return [:] }
        let context = try await resolveMaterial().context
        do {
            return try await session.fetchLinkVisibility(shareID: context.shareID, linkIDs: linkIDs)
        } catch ProtonAuthError.apiError(let code, let message)
            where code == 408 || code == 429 || (500...599).contains(code)
        {
            // A busy service must not use up the retry budget of a photo.
            throw UploadError.retryableBackend(code: code, message: message)
        }
    }

    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        let health = contentIndexStore.remoteContentIndexHealth(hashKeyEpoch: material.epoch)
        guard health != .unavailable else {
            throw UploadError.backend("Remote duplicate index is unavailable")
        }
        return health
    }

    func activeMainLinkIDs(
        forExternalIdentifier identifier: String
    ) async throws -> (links: Set<String>, complete: Bool) {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        guard let lineageIndexStore else { return ([], false) }
        await prepareLineageIndex(material: material)
        let links = lineageIndexStore.activeMainLinkIDs(forExternalIdentifier: identifier, hashKeyEpoch: material.epoch)
        return (links, lineageHealth(material: material) == .complete)
    }

    func replacingMainLinkIDs(ofReplacedLink linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        guard let lineageIndexStore else { return ([], false) }
        await prepareLineageIndex(material: material)
        let links = lineageIndexStore.replacingMainLinkIDs(ofReplacedLink: linkID, hashKeyEpoch: material.epoch)
        return (links, lineageHealth(material: material) == .complete)
    }

    func externalIdentifier(ofMainLink linkID: String) async throws -> (identifier: String?, complete: Bool) {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        guard let lineageIndexStore else { return (nil, false) }
        await prepareLineageIndex(material: material)
        let identifier = lineageIndexStore.externalIdentifier(ofMainLink: linkID, hashKeyEpoch: material.epoch)
        return (identifier, lineageHealth(material: material) == .complete)
    }

    func replacedLinkIDs(ofReplacingMain linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        guard let lineageIndexStore else { return ([], false) }
        await prepareLineageIndex(material: material)
        let links = lineageIndexStore.replacedLinkIDs(ofReplacingMain: linkID, hashKeyEpoch: material.epoch)
        return (links, lineageHealth(material: material) == .complete)
    }

    /// The lineage index fills only in a full index build. An account indexed before the lineage index existed, or
    /// one whose lineage checkpoint fell behind, has none, so the first lineage read of a launch rebuilds the index
    /// once for each key epoch, and every lineage read waits for that rebuild. A store that cannot write never
    /// rebuilds. A failed rebuild leaves the index incomplete, so the reads stay unproven.
    private func prepareLineageIndex(material: Material) async {
        if let rebuild = lineageRebuilds[material.epoch] {
            await rebuild.value
            return
        }
        guard let lineageIndexStore, lineageIndexStore.acceptsWrites, lineageHealth(material: material) == .incomplete
        else { return }
        let rebuild = Task<Void, Never> {
            do {
                try await refreshRemoteContentIndex(material: material, rebuildsMissingLineage: true)
            } catch {
                DebugLog.log("[Dedupe] lineage index rebuild failed; reads remain incomplete - \(error)")
            }
        }
        lineageRebuilds[material.epoch] = rebuild
        await rebuild.value
    }

    /// Read after the lookup: a failed lookup marks the store incomplete.
    private func lineageHealth(material: Material) -> UploadRemoteLineageIndexHealth {
        lineageIndexStore?.health(
            hashKeyEpoch: material.epoch,
            contentCheckpoint: contentIndexStore.remoteContentIndexCheckpoint(hashKeyEpoch: material.epoch))
            ?? .incomplete
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        let token = UUID()
        remoteIndexProgressHandlers[token] = progress
        await progress(.init(phase: .loading))
        defer { remoteIndexProgressHandlers[token] = nil }
        let material = try await resolveMaterial()
        if let checkpoint = contentIndexStore.remoteContentIndexBuildCheckpoint(hashKeyEpoch: material.epoch) {
            await progress(.init(phase: .indexing, completed: checkpoint.cursor, total: checkpoint.total))
        }
        try await refreshRemoteContentIndex(material: material)
        guard contentIndexStore.remoteContentIndexHealth(hashKeyEpoch: material.epoch) != .unavailable else {
            throw UploadError.backend("Remote duplicate index is unavailable")
        }
        await progress(.init(phase: .ready))
    }

    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        guard !identities.isEmpty else { return [:] }
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        return contentIndexStore.remoteAssetRecords(
            for: identities,
            hashKeyEpoch: material.epoch
        )
    }

    func invalidateCachedRemoteState() async {
        remoteContentIndexGeneration += 1
        lastRemoteContentRefreshAt = nil
        remoteContentIndexTask?.cancel()
        remoteContentIndexTask = nil
        if let material {
            _ = contentIndexStore.invalidateRemoteContentIndexBuild(hashKeyEpoch: material.epoch)
        }
    }

    func recordUploaded(contentHash: String, remoteLinkID: String) async {
        guard let material = try? await resolveMaterial() else { return }
        _ = contentIndexStore.upsertRemoteContentRecord(
            UploadRemoteContentIndexRecord(
                contentHash: contentHash,
                hashKeyEpoch: material.epoch,
                remoteLinkID: remoteLinkID
            ))
    }

    // MARK: Key material

    /// Share bootstrap + root link fetch + key-chain decryption, resolved once and cached for the
    /// service's lifetime (the bridge is rebuilt on sign-in, so the cache can't outlive the
    /// account). Coalesced behind a task so concurrent first calls resolve once.
    private func resolveMaterial() async throws -> Material {
        if let material { return material }
        if let materialTask { return try await materialTask.value }
        let session = self.session
        let crypto = self.crypto
        let contextProvider = self.contextProvider
        let task = Task { () -> Material in
            let context = try await contextProvider()
            let bootstrap = try await session.getJSON("/drive/shares/\(context.shareID)", as: DedupeShareBootstrap.self)
            let shareKey = try crypto.unlockShare(key: bootstrap.key, passphrase: bootstrap.passphrase)
            let response = try await session.getJSON(
                "/drive/shares/\(context.shareID)/links/\(context.rootLinkID)",
                as: DedupeRootLinkResponse.self
            )
            guard let armoredHashKey = response.link.folderProperties?.nodeHashKey else {
                throw ProtonUploadDedupeError.missingRootHashKey
            }
            let nodeKey = try crypto.unlockNode(
                key: response.link.nodeKey,
                passphrase: response.link.nodePassphrase,
                parent: shareKey
            )
            let hashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: nodeKey).utf8)
            // Irreversible fingerprint for manifest validity - never the key itself.
            let epoch = SHA256.hash(data: hashKey).prefix(8).map { String(format: "%02x", $0) }.joined()
            DebugLog.log("[Dedupe] photos root hash key resolved (epoch \(epoch))")
            return Material(context: context, rootKey: nodeKey, hashKey: hashKey, epoch: epoch)
        }
        materialTask = task
        defer { materialTask = nil }
        do {
            let resolved = try await task.value
            material = resolved
            return resolved
        } catch {
            DebugLog.log("[Dedupe] hash key resolution FAILED - \(error)")
            throw error
        }
    }

    // MARK: Remote content index

    private func refreshRemoteContentIndex(material: Material, rebuildsMissingLineage: Bool = false) async throws {
        if !rebuildsMissingLineage, let lastRemoteContentRefreshAt,
            Date().timeIntervalSince(lastRemoteContentRefreshAt) < Self.remoteContentIndexLifetime
        {
            return
        }
        if let running = remoteContentIndexTask {
            try await running.value
            guard rebuildsMissingLineage else { return }
            // A rebuild runs after the refreshes that started before it, never beside them.
            if let newer = remoteContentIndexTask, newer != running { try await newer.value }
        }

        let session = self.session
        let crypto = self.crypto
        let store = self.contentIndexStore
        let lineageStore = self.lineageIndexStore
        let generation = remoteContentIndexGeneration
        let report: @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { [weak self] value in
            await self?.emitRemoteIndexProgress(value)
        }
        let task = Task {
            try await Self.refreshRemoteContentIndex(
                material: material, session: session, crypto: crypto, store: store,
                lineageStore: lineageStore, rebuildsMissingLineage: rebuildsMissingLineage, progress: report)
        }
        remoteContentIndexTask = task
        do {
            try await task.value
            guard remoteContentIndexGeneration == generation else { throw CancellationError() }
            if remoteContentIndexTask == task { remoteContentIndexTask = nil }
            lastRemoteContentRefreshAt = Date()
        } catch {
            if remoteContentIndexGeneration == generation, remoteContentIndexTask == task {
                remoteContentIndexTask = nil
            }
            throw error
        }
    }

    private func emitRemoteIndexProgress(_ value: UploadRemoteIndexPreparationProgress) async {
        for handler in remoteIndexProgressHandlers.values { await handler(value) }
    }

    static func refreshRemoteContentIndex(
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore,
        lineageStore: UploadRemoteLineageIndexStore?,
        rebuildsMissingLineage: Bool = false,
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        if let checkpoint = store.remoteContentIndexCheckpoint(hashKeyEpoch: material.epoch),
            store.hasRemoteAssetIndexCheckpoint(hashKeyEpoch: material.epoch),
            !rebuildsMissingLineage
                || lineageStore.map({
                    !$0.acceptsWrites || $0.hasCheckpoint(hashKeyEpoch: material.epoch, eventID: checkpoint.eventID)
                }) ?? true
        {
            try await applyRemoteEvents(
                from: checkpoint, material: material, session: session, crypto: crypto,
                store: store, lineageStore: lineageStore, progress: progress)
        } else {
            try await rebuildRemoteContentIndex(
                material: material, session: session, crypto: crypto,
                store: store, lineageStore: lineageStore, progress: progress)
        }
    }

    private static func rebuildRemoteContentIndex(
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore,
        lineageStore: UploadRemoteLineageIndexStore?,
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        await progress(.init(phase: .loading))
        let eventID = try await session.latestVolumeEventID(volumeID: material.context.volumeID)
        var sourceIDs = Set<String>()
        try await session.forEachPhotosListPage(volumeID: material.context.volumeID) { page in
            try Task.checkCancellation()
            for photo in page {
                sourceIDs.insert(photo.linkID)
                sourceIDs.formUnion(photo.relatedPhotos.map(\.linkID))
            }
        }
        let ids = sourceIDs.sorted()
        var sourceHasher = SHA256()
        for id in ids {
            sourceHasher.update(data: Data(id.utf8))
            sourceHasher.update(data: Data([0]))
        }
        let sourceFingerprint = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard
            let build = store.beginRemoteContentIndexBuild(
                hashKeyEpoch: material.epoch,
                eventID: eventID,
                sourceFingerprint: sourceFingerprint,
                total: ids.count,
                updatedAt: Date()
            )
        else {
            throw UploadError.backend("Remote duplicate index checkpoint could not be saved")
        }
        var lineageBuildReady = lineageStore?.prepareBuild(build, hashKeyEpoch: material.epoch) == true
        await progress(.init(phase: .indexing, completed: build.cursor, total: ids.count))
        let shareID = material.context.shareID
        let windows = stride(from: build.cursor, to: ids.count, by: remoteMetadataWindow).map {
            $0..<min($0 + remoteMetadataWindow, ids.count)
        }
        func prefetch(_ position: Int) -> Task<RemoteMetadataFetch, any Error>? {
            guard windows.indices.contains(position) else { return nil }
            let window = Array(ids[windows[position]])
            return Task { try await Self.fetchLinks(ids: window, shareID: shareID, session: session) }
        }
        // The metadata of the next window downloads while this window decrypts, so the network and the processor
        // work at the same time. Decryption and the store update stay serialized; each checkpoint stays in order.
        var nextFetch = prefetch(0)
        defer { nextFetch?.cancel() }
        for (position, range) in windows.enumerated() {
            try Task.checkCancellation()
            guard let currentFetch = nextFetch else { break }
            let fetched = try await withTaskCancellationHandler {
                try await currentFetch.value
            } onCancel: {
                currentFetch.cancel()
            }
            try Task.checkCancellation()
            nextFetch = prefetch(position + 1)
            let end = range.upperBound
            let window = Array(ids[range])
            var rows = try makeIndexRows(
                links: fetched.links,
                expectedActiveFileIDs: Set(window),
                endpointFailureIDs: fetched.endpointFailureIDs,
                material: material,
                crypto: crypto,
                generation: eventID
            )
            await repairUnresolvedRows(
                &rows,
                links: fetched.links,
                material: material,
                session: session,
                crypto: crypto
            )
            let external = rows.externalIdentitiesByLinkID.map {
                UploadRemoteExternalIdentityRecord(remoteLinkID: $0.key, externalIdentity: $0.value)
            }
            if lineageBuildReady, let lineageStore {
                lineageBuildReady = lineageStore.appendBuild(
                    identities: rows.lineageRows.identities, lineage: rows.lineageRows.lineage,
                    hashKeyEpoch: material.epoch, buildID: build.buildID, nextCursor: end,
                    unresolvedRemoteLinkIDs: rows.lineageRows.unresolvedLinkIDs)
            }
            guard
                store.appendRemoteContentIndexBuild(
                    records: rows.records,
                    unresolvedIssues: rows.unresolvedIssues,
                    externalIdentities: external,
                    hashKeyEpoch: material.epoch,
                    buildID: build.buildID,
                    nextCursor: end,
                    updatedAt: Date()
                )
            else {
                throw UploadError.backend("Remote duplicate index checkpoint could not be saved")
            }
            await progress(.init(phase: .indexing, completed: end, total: ids.count))
        }
        await progress(.init(phase: .applyingChanges, completed: ids.count, total: ids.count))
        let externalIdentities = store.stagedRemoteExternalIdentities(
            hashKeyEpoch: material.epoch,
            buildID: build.buildID
        )
        // The first pass establishes the deterministic checkpoint source. Re-read the relationship
        // pages after metadata is staged, but retain only the proof accumulator rather than the full
        // remote listing. Cross-page ambiguity remains global inside the accumulator.
        var proofAccumulator = RemotePhotoAssetProofBuilder.Accumulator(hashKeyEpoch: material.epoch)
        try await session.forEachPhotosListPage(volumeID: material.context.volumeID) { page in
            try Task.checkCancellation()
            proofAccumulator.append(
                photos: page,
                externalIdentitiesByLinkID: externalIdentities
            )
        }
        let remoteAssetRecords = proofAccumulator.finish()
        let checkpoint = UploadRemoteContentIndexCheckpoint(eventID: eventID, refreshedAt: Date())
        guard
            store.finishRemoteContentIndexBuild(
                remoteAssetRecords: remoteAssetRecords,
                hashKeyEpoch: material.epoch,
                buildID: build.buildID,
                checkpoint: checkpoint
            )
        else {
            throw UploadError.backend("Remote duplicate index could not be saved")
        }
        if let lineageStore {
            if !lineageBuildReady || !lineageStore.finishBuild(build, hashKeyEpoch: material.epoch) {
                DebugLog.log("[Dedupe] lineage index build could not be saved; reads remain incomplete")
            }
        }
        DebugLog.log(
            "[Dedupe] remote content index rebuilt links=\(ids.count)"
        )
    }

    private static func applyRemoteEvents(
        from checkpoint: UploadRemoteContentIndexCheckpoint,
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore,
        lineageStore: UploadRemoteLineageIndexStore?,
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { _ in }
    ) async throws {
        await progress(.init(phase: .applyingChanges))
        var eventID = checkpoint.eventID
        let eventLineageStore = lineageStore.flatMap {
            $0.hasCheckpoint(hashKeyEpoch: material.epoch, eventID: checkpoint.eventID) ? $0 : nil
        }
        while true {
            try Task.checkCancellation()
            let page = try await session.fetchVolumeEvents(
                volumeID: material.context.volumeID,
                since: eventID
            )
            if page.requiresRefresh {
                try await rebuildRemoteContentIndex(
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store,
                    lineageStore: lineageStore,
                    progress: progress
                )
                return
            }

            let relevant = page.events.filter { event in
                event.eventType == 0
                    || event.contextShareID == material.context.shareID
            }
            let removedIDs = Array(Set(relevant.map(\.linkID)))
            let activeFileIDs = Set(
                relevant.compactMap { event -> String? in
                    guard event.eventType != 0 else { return nil }
                    if let type = event.linkType, type != 2 { return nil }
                    if let state = event.linkState, state != 1 { return nil }
                    return event.linkID
                })
            let fetched = try await fetchLinks(
                ids: Array(activeFileIDs),
                shareID: material.context.shareID,
                session: session
            )
            var rows = try makeIndexRows(
                links: fetched.links,
                expectedActiveFileIDs: activeFileIDs,
                endpointFailureIDs: fetched.endpointFailureIDs,
                material: material,
                crypto: crypto,
                generation: page.eventID
            )
            for event in relevant where event.eventType != 0 {
                if event.linkType == nil || event.linkType == 2,
                    let state = event.linkState, state != 0 && state != 1 && state != 2
                {
                    rows.lineageRows.unresolvedLinkIDs.insert(event.linkID)
                }
            }
            await repairUnresolvedRows(
                &rows,
                links: fetched.links,
                material: material,
                session: session,
                crypto: crypto
            )
            let next = UploadRemoteContentIndexCheckpoint(eventID: page.eventID, refreshedAt: Date())
            guard
                store.applyRemoteContentIndexChanges(
                    upserting: rows.records,
                    upsertingRemoteAssetRecords: rows.remoteAssetRecords,
                    unresolvedIssues: rows.unresolvedIssues,
                    removingRemoteLinkIDs: removedIDs,
                    hashKeyEpoch: material.epoch,
                    expectedEventID: eventID,
                    checkpoint: next
                )
            else {
                throw UploadError.backend("Remote duplicate index changes could not be saved")
            }
            if let eventLineageStore,
                !eventLineageStore.applyChanges(
                    identities: rows.lineageRows.identities, lineage: rows.lineageRows.lineage,
                    removingRemoteLinkIDs: removedIDs, hashKeyEpoch: material.epoch,
                    expectedEventID: eventID, eventID: page.eventID,
                    unresolvedRemoteLinkIDs: rows.lineageRows.unresolvedLinkIDs)
            {
                DebugLog.log("[Dedupe] lineage index changes could not be saved; reads remain incomplete")
            }
            eventID = page.eventID
            if !page.hasMore { return }
        }
    }

    private struct RemoteMetadataFetch: Sendable {
        var links: [String: AlbumPhotoLinkBody]
        var endpointFailureIDs: Set<String>
    }

    private static func fetchLinks(
        ids: [String],
        shareID: String,
        session: DriveSession
    ) async throws -> RemoteMetadataFetch {
        guard !ids.isEmpty else { return RemoteMetadataFetch(links: [:], endpointFailureIDs: []) }
        let chunks = stride(from: 0, to: ids.count, by: UploadDedupePipeline.protonDuplicateBatchSize).map { start in
            Array(ids[start..<min(start + UploadDedupePipeline.protonDuplicateBatchSize, ids.count)])
        }
        var links: [String: AlbumPhotoLinkBody] = [:]
        links.reserveCapacity(ids.count)
        var endpointFailureIDs: Set<String> = []

        await withTaskGroup(of: ([AlbumPhotoLinkBody], [String]).self) { group in
            var nextChunk = 0

            func submitNext() {
                guard nextChunk < chunks.count else { return }
                let chunk = chunks[nextChunk]
                nextChunk += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (try await session.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: chunk), [])
                    } catch {
                        return ([], chunk)
                    }
                }
            }

            for _ in 0..<min(Self.remoteMetadataRequestConcurrency, chunks.count) {
                submitNext()
            }
            while let (batch, failedIDs) = await group.next() {
                for link in batch {
                    if let id = link.linkID { links[id] = link }
                }
                endpointFailureIDs.formUnion(failedIDs)
                submitNext()
            }
        }

        // One immediate targeted re-fetch repairs partial/missed metadata responses without ever
        // downloading originals. A second failure becomes a typed unresolved row below; it does not
        // turn an otherwise readable remote index into a global backup stop.
        let missing = ids.filter { links[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: UploadDedupePipeline.protonDuplicateBatchSize) {
            try Task.checkCancellation()
            let batch = Array(
                missing[start..<min(start + UploadDedupePipeline.protonDuplicateBatchSize, missing.count)])
            guard let retry = try? await session.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: batch) else {
                endpointFailureIDs.formUnion(batch)
                continue
            }
            for link in retry {
                if let id = link.linkID {
                    links[id] = link
                    endpointFailureIDs.remove(id)
                }
            }
        }
        if links.count < ids.count {
            DebugLog.log("[Dedupe] metadata re-fetch unresolved=\(ids.count - links.count)")
        }
        return RemoteMetadataFetch(links: links, endpointFailureIDs: endpointFailureIDs)
    }

    private struct RemoteContentIndexRows {
        var records: [UploadRemoteContentIndexRecord] = []
        var remoteAssetRecords: [UploadRemoteAssetIndexRecord] = []
        var unresolvedIssues: [UploadRemoteContentIndexIssue] = []
        var externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity] = [:]
        var lineageRows = RemotePhotoLineageRows()

        mutating func merge(_ other: Self) {
            records.append(contentsOf: other.records)
            unresolvedIssues.append(contentsOf: other.unresolvedIssues)
            externalIdentitiesByLinkID.merge(other.externalIdentitiesByLinkID) { _, new in new }
            lineageRows.merge(other.lineageRows)
        }
    }

    private static func makeIndexRows(
        links: [String: AlbumPhotoLinkBody],
        expectedActiveFileIDs: Set<String>,
        endpointFailureIDs: Set<String>,
        material: Material,
        crypto: DriveCrypto,
        generation: String,
        observedAt: Date = Date()
    ) throws -> RemoteContentIndexRows {
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardDateFormatter = ISO8601DateFormatter()
        standardDateFormatter.formatOptions = [.withInternetDateTime]
        func parseDate(_ value: String) -> Date? {
            fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
        }

        var records: [UploadRemoteContentIndexRecord] = []
        records.reserveCapacity(expectedActiveFileIDs.count)
        var unresolved: [UploadRemoteContentIndexIssue] = []
        func issue(_ id: String, _ reason: UploadRemoteContentIndexIssue.Reason) -> UploadRemoteContentIndexIssue {
            UploadRemoteContentIndexIssue(
                remoteLinkID: id,
                reason: reason,
                firstObservedAt: observedAt,
                lastObservedAt: observedAt,
                lastRepairAttemptAt: nil,
                indexGeneration: generation
            )
        }
        var externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity] = [:]
        externalIdentitiesByLinkID.reserveCapacity(expectedActiveFileIDs.count)
        var lineageRows = RemotePhotoLineageRows()
        for id in expectedActiveFileIDs {
            try Task.checkCancellation()
            guard let link = links[id] else {
                unresolved.append(issue(id, endpointFailureIDs.contains(id) ? .endpointFailure : .missingLinkMetadata))
                lineageRows.unresolvedLinkIDs.insert(id)
                continue
            }
            if link.type == nil || link.type == 2,
                let state = link.state, state != 0 && state != 1 && state != 2
            {
                lineageRows.unresolvedLinkIDs.insert(id)
            }
            guard link.type == nil || link.type == 2,
                link.state == nil || link.state == 1
            else {
                continue
            }
            guard let nodeKey = link.nodeKey, let nodePassphrase = link.nodePassphrase else {
                unresolved.append(issue(id, .missingKeyMetadata))
                lineageRows.unresolvedLinkIDs.insert(id)
                continue
            }
            guard let armoredXAttr = link.xAttr ?? link.fileProperties?.activeRevision?.xAttr else {
                unresolved.append(issue(id, .missingEncryptedAttributes))
                lineageRows.unresolvedLinkIDs.insert(id)
                continue
            }
            let fileKey: UnlockableKey
            let data: Data
            do {
                fileKey = try crypto.unlockNode(
                    key: nodeKey,
                    passphrase: nodePassphrase,
                    parent: material.rootKey
                )
                data = try crypto.decryptXAttr(armoredXAttr, node: fileKey)
            } catch {
                unresolved.append(issue(id, .decryptFailure))
                lineageRows.unresolvedLinkIDs.insert(id)
                continue
            }
            let attributes: DedupeXAttr
            do {
                attributes = try JSONDecoder().decode(DedupeXAttr.self, from: data)
            } catch {
                unresolved.append(issue(id, .invalidAttributes))
                lineageRows.unresolvedLinkIDs.insert(id)
                continue
            }
            lineageRows.merge(
                RemotePhotoLineageRows(
                    attributes: attributes, link: link, remoteLinkID: id, hashKeyEpoch: material.epoch))
            if let iOSPhotos = attributes.iOSPhotos,
                let cloudID = iOSPhotos.iCloudID,
                !cloudID.isEmpty,
                let rawDate = iOSPhotos.modificationTime,
                let modificationDate = parseDate(rawDate)
            {
                externalIdentitiesByLinkID[id] = UploadBackupExternalIdentity(
                    identifier: cloudID,
                    modificationDate: modificationDate
                )
            }
            guard let sha1 = attributes.common?.digests?.sha1?.lowercased(), !sha1.isEmpty else {
                unresolved.append(issue(id, .missingContentHash))
                continue
            }
            records.append(
                UploadRemoteContentIndexRecord(
                    contentHash: ProtonPhotoHMAC.hex(message: sha1, key: material.hashKey),
                    hashKeyEpoch: material.epoch,
                    remoteLinkID: id
                ))
        }

        return RemoteContentIndexRows(
            records: records,
            unresolvedIssues: unresolved,
            externalIdentitiesByLinkID: externalIdentitiesByLinkID,
            lineageRows: lineageRows
        )
    }

    /// One bounded repair attempt for rows whose xattrs did not yield a content hash. The remote
    /// encrypted name is decrypted locally, corrected exactly like an upload name, HMACed locally,
    /// and queried through Proton's existing duplicate endpoint. Only an exact returned LinkID may
    /// repair a row; no original bytes are downloaded.
    private static func repairUnresolvedRows(
        _ rows: inout RemoteContentIndexRows,
        links: [String: AlbumPhotoLinkBody],
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        attemptedAt: Date = Date()
    ) async {
        guard !rows.unresolvedIssues.isEmpty else { return }
        var linkIDsByNameHash: [String: Set<String>] = [:]
        for index in rows.unresolvedIssues.indices {
            rows.unresolvedIssues[index].lastRepairAttemptAt = attemptedAt
            let id = rows.unresolvedIssues[index].remoteLinkID
            guard let armoredName = links[id]?.name else { continue }
            do {
                let clearName = try crypto.decryptName(armoredName, parent: material.rootKey)
                let corrected = ProtonPhotoNameCorrection.correctedName(for: clearName)
                let nameHash = ProtonPhotoHMAC.hex(message: corrected, key: material.hashKey)
                linkIDsByNameHash[nameHash, default: []].insert(id)
            } catch {
                rows.unresolvedIssues[index].reason = .decryptFailure
            }
        }

        var repaired: [String: UploadRemoteContentIndexRecord] = [:]
        let hashes = linkIDsByNameHash.keys.sorted()
        for start in stride(from: 0, to: hashes.count, by: UploadDedupePipeline.protonDuplicateBatchSize) {
            let batch = Array(hashes[start..<min(start + UploadDedupePipeline.protonDuplicateBatchSize, hashes.count)])
            do {
                let duplicates = try await session.findPhotoDuplicates(
                    volumeID: material.context.volumeID,
                    nameHashes: batch
                )
                for duplicate in duplicates {
                    guard let linkID = duplicate.linkID,
                        let expectedLinkIDs = linkIDsByNameHash[duplicate.hash],
                        expectedLinkIDs.contains(linkID),
                        duplicate.linkState == nil || duplicate.linkState == 1,
                        let contentHash = duplicate.contentHash,
                        !contentHash.isEmpty
                    else { continue }
                    repaired[linkID] = UploadRemoteContentIndexRecord(
                        contentHash: contentHash,
                        hashKeyEpoch: material.epoch,
                        remoteLinkID: linkID
                    )
                }
            } catch {
                let failedHashes = Set(batch)
                for index in rows.unresolvedIssues.indices {
                    let linkID = rows.unresolvedIssues[index].remoteLinkID
                    if failedHashes.contains(where: { linkIDsByNameHash[$0]?.contains(linkID) == true }) {
                        rows.unresolvedIssues[index].reason = .endpointFailure
                    }
                }
            }
        }
        rows.records.append(contentsOf: repaired.values)
        rows.unresolvedIssues.removeAll { repaired[$0.remoteLinkID] != nil }

        if !rows.unresolvedIssues.isEmpty {
            let counts = Dictionary(grouping: rows.unresolvedIssues, by: \.reason)
                .map { "\($0.key.rawValue)=\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            DebugLog.log(
                "[Dedupe] degraded remote metadata unresolved=\(rows.unresolvedIssues.count) reasons=\(counts)"
            )
        }
    }
}

/// Narrow availability-first rule: an exact indexed match still wins; a readable index with remote
/// rows missing encrypted SHA-1 metadata permits upload on a content miss; local index failure does not.
enum ProtonRemoteContentIndexLookup {
    static func duplicate(
        contentHash: String,
        record: UploadRemoteContentIndexRecord?,
        health: UploadRemoteContentIndexHealth
    ) throws -> RemotePhotoDuplicate? {
        try duplicates(contentHash: contentHash, records: record.map { [$0] } ?? [], health: health).first
    }

    static func duplicates(
        contentHash: String,
        records: [UploadRemoteContentIndexRecord],
        health: UploadRemoteContentIndexHealth
    ) throws -> [RemotePhotoDuplicate] {
        guard !records.isEmpty || health != .unavailable else {
            throw UploadError.backend("Remote duplicate index is unavailable")
        }
        return records.map { record in
            RemotePhotoDuplicate(
                nameHash: "",
                contentHash: contentHash,
                linkState: .active,
                linkID: record.remoteLinkID
            )
        }
    }
}

// MARK: - Wire models (PascalCase JSON)

private struct DedupeShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case passphrase = "Passphrase"
    }
}

private struct DedupeRootLinkResponse: Decodable {
    let link: Link
    enum CodingKeys: String, CodingKey { case link = "Link" }

    struct Link: Decodable {
        let nodeKey: String
        let nodePassphrase: String
        let folderProperties: FolderProperties?
        enum CodingKeys: String, CodingKey {
            case nodeKey = "NodeKey"
            case nodePassphrase = "NodePassphrase"
            case folderProperties = "FolderProperties"
        }

        struct FolderProperties: Decodable {
            let nodeHashKey: String?
            enum CodingKeys: String, CodingKey { case nodeHashKey = "NodeHashKey" }
        }
    }
}

// MARK: - Duplicates endpoint (DriveSession)

/// One row of `DuplicateHashes` from the find-duplicates endpoint. `linkState`: 0 = draft,
/// 1 = active, 2 = trashed, absent = deleted.
struct PhotoDuplicateEntry: Decodable {
    let hash: String
    let contentHash: String?
    let linkState: Int?
    let clientUID: String?
    let linkID: String?
    enum CodingKeys: String, CodingKey {
        case hash = "Hash"
        case contentHash = "ContentHash"
        case linkState = "LinkState"
        case
            clientUID = "ClientUID"
        case linkID = "LinkID"
    }
}

private struct PhotoDuplicatesResponse: Decodable {
    let duplicateHashes: [PhotoDuplicateEntry]?
    enum CodingKeys: String, CodingKey { case duplicateHashes = "DuplicateHashes" }
}

extension DriveSession {
    /// Queries which of `nameHashes` already exist in the photo volume - the Proton duplicate
    /// check. Callers batch to Proton's request size (150); this sends one request.
    func findPhotoDuplicates(volumeID: String, nameHashes: [String]) async throws -> [PhotoDuplicateEntry] {
        guard !nameHashes.isEmpty else { return [] }
        let data = try await send(
            "/drive/volumes/\(volumeID)/photos/duplicates",
            method: "POST",
            body: ["NameHashes": nameHashes],
            retryOnRateLimit: true
        )
        return (try JSONDecoder().decode(PhotoDuplicatesResponse.self, from: data)).duplicateHashes ?? []
    }
}
