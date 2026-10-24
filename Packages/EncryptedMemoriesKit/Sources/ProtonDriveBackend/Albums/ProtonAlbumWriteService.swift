import CryptoKit
import Foundation
import PhotosCore

// MARK: - Attach requests / outcomes

/// One photo to attach to an album. `sha1Hex` (from the upload identity manifest) lets the service
/// compute the album-context `ContentHash` without fetching + decrypting the photo's XAttr; when
/// nil the service falls back to the XAttr digest. The item fails locally if neither exists because
/// Proton's album payload contract requires `ContentHash`.
struct AlbumAttachRequestItem: Sendable, Equatable {
    let uid: PhotoUID
    let sha1Hex: String?

    init(uid: PhotoUID, sha1Hex: String? = nil) {
        self.uid = uid
        self.sha1Hex = sha1Hex
    }
}

/// Per-photo outcome of an add-to-album batch. `alreadyMember` (Proton "already exists") counts as
/// success for sync purposes - re-running a sync converges instead of erroring.
enum AlbumAttachItemOutcome: Sendable, Equatable {
    case attached
    case alreadyMember
    case failed(code: Int?, message: String)
}

struct AlbumAttachResult: Sendable {
    var outcomes: [String: AlbumAttachItemOutcome] = [:]  // keyed by photo link id

    var attachedCount: Int { outcomes.values.filter { $0 == .attached }.count }
    var alreadyMemberCount: Int { outcomes.values.filter { $0 == .alreadyMember }.count }
    var failedCount: Int {
        outcomes.values.filter { if case .failed = $0 { true } else { false } }.count
    }
    var firstFailureMessage: String? {
        for value in outcomes.values { if case .failed(_, let message) = value { return message } }
        return nil
    }
}

enum ProtonAlbumWriteError: LocalizedError {
    /// The account exposes no usable address key to sign with - album writes cannot proceed.
    case noSigningKey
    /// The photos root carried no hash key - no Proton-compatible name hash can be computed.
    case missingRootHashKey
    /// The album link carried no decryptable hash key - photos cannot be hashed into it.
    case missingAlbumHashKey
    /// The create-album response did not contain the new album's link id.
    case malformedCreateResponse
    /// The add-multiple response body could not be decoded (absent, malformed, or no `Responses`
    /// array). The per-item remote outcome is unknown, so the batch must not report success.
    case malformedAddResponse

    var errorDescription: String? {
        switch self {
        case .noSigningKey: "No signing key is available for this account."
        case .missingRootHashKey: "The photo library's hash key is unavailable."
        case .missingAlbumHashKey: "The album's hash key is unavailable."
        case .malformedCreateResponse: "The server response for the new album was incomplete."
        case .malformedAddResponse: "The server response for the album update was incomplete."
        }
    }
}

private enum AlbumPayloadPreparationError: Error {
    case linkMetadataUnavailable
    case relatedMetadataUnavailable
    case contentHashUnavailable
}

/// Result of strictly evaluating a main link's response rows: either a settled outcome, or a
/// request to retry the group because the server reported part of the related set missing.
private enum MainResponseEvaluation {
    case outcome(AlbumAttachItemOutcome)
    case retryMissing([String])
}

// MARK: - Service

/// Performs direct album writes with Proton node cryptography.
/// Re-encrypts existing photo metadata for the album without moving media bytes.
/// Logs only counts and error codes, never names, hashes, passphrases, or key material.
actor ProtonAlbumWriteService {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private nonisolated let admission: JoinedShutdownGate?
    private nonisolated let requestCause: ProtonRequestCauseBinding?
    private let contextProvider: @Sendable () async throws -> PhotosShareContext

    /// Proton's normal add-multiple batch target. A single related-photo group can exceed this
    /// target and remains atomic rather than being split.
    static let addBatchSize = 10
    /// The web client's chunk size for `links/fetch_metadata`.
    private static let metadataBatchSize = 150
    /// Crypto preparation uses independent key rings, but remains bounded to avoid an unbounded
    /// burst of gopenpgp work for a large selection.
    private static let payloadPreparationConcurrency = 4

    private struct RootMaterial: Sendable {
        let context: PhotosShareContext
        let rootKey: UnlockableKey
        let rootHashKey: Data
        let signer: DriveCryptoSigner
    }

    private struct AlbumMaterial: Sendable {
        let key: UnlockableKey
        let hashKey: Data
    }

    private struct PreparedAttachPayload: Sendable {
        let linkID: String
        let name: String
        let hash: String
        let nodePassphrase: String
        let nameSignatureEmail: String
        let contentHash: String

        var dictionary: [String: Any] {
            [
                "LinkID": linkID,
                "Name": name,
                "Hash": hash,
                "NodePassphrase": nodePassphrase,
                "NameSignatureEmail": nameSignatureEmail,
                "ContentHash": contentHash,
            ]
        }
    }

    private struct PreparedPhotoGroup: Sendable {
        let mainLinkID: String
        var payloads: [PreparedAttachPayload]
    }

    private struct PreparedPhotoGroupOutcome: Sendable {
        let mainLinkID: String
        let group: PreparedPhotoGroup?
        let failureMessage: String?
    }

    private var rootMaterial: RootMaterial?
    private var rootMaterialTask: Task<RootMaterial, any Error>?
    private var albumMaterials: [String: AlbumMaterial] = [:]

    init(
        session: DriveSession,
        crypto: DriveCrypto,
        admission: JoinedShutdownGate? = nil,
        requestCause: ProtonRequestCauseBinding? = nil,
        contextProvider: @Sendable @escaping () async throws -> PhotosShareContext
    ) {
        self.session = session
        self.crypto = crypto
        self.admission = admission
        self.requestCause = requestCause
        self.contextProvider = contextProvider
    }

    private nonisolated func withAdmission<T: Sendable>(
        _ operation: @escaping @Sendable (isolated ProtonAlbumWriteService) async throws -> T
    ) async throws -> T {
        guard let requestCause else { return try await admitted(operation) }
        return try await requestCause.run { try await admitted(operation) }
    }

    private nonisolated func admitted<T: Sendable>(
        _ operation: @escaping @Sendable (isolated ProtonAlbumWriteService) async throws -> T
    ) async throws -> T {
        guard let admission else { return try await operation(self) }
        return try await admission.withAdmission { [self] in
            try await operation(self)
        }
    }

    // MARK: Create

    /// Creates an album named `name` in the photos volume and returns its link id. The caller has
    /// already validated/trimmed the name (`AlbumsRepository`).
    func createAlbum(name: String) async throws -> String {
        try await withAdmission { service in
            try await service.createAlbumImpl(name: name)
        }
    }

    private func createAlbumImpl(name: String) async throws -> String {
        let material = try await resolveRootMaterial()

        let passphrase = try crypto.randomBase64Token()
        let nodeKeyArmored = try crypto.generateLockedNodeKey(passphrase: passphrase)
        let albumKey = UnlockableKey(armored: nodeKeyArmored, passphrase: passphrase)
        let (nodePassphrase, nodePassphraseSignature) = try crypto.encryptWithDetachedSignature(
            text: passphrase, to: material.rootKey, signer: material.signer
        )
        let hashKeyToken = try crypto.randomBase64Token()
        let nodeHashKey = try crypto.encryptAndSign(text: hashKeyToken, to: albumKey, signer: material.signer)
        let encryptedName = try crypto.encryptAndSign(text: name, to: material.rootKey, signer: material.signer)
        let nameHash = ProtonPhotoHMAC.hex(message: name, key: material.rootHashKey)

        let albumLinkID = try await session.createAlbum(
            volumeID: material.context.volumeID,
            link: [
                "Name": encryptedName,
                "Hash": nameHash,
                "NodePassphrase": nodePassphrase,
                "NodePassphraseSignature": nodePassphraseSignature,
                "SignatureEmail": material.signer.email,
                "NodeKey": nodeKeyArmored,
                "NodeHashKey": nodeHashKey,
            ]
        )
        albumMaterials[albumLinkID] = AlbumMaterial(key: albumKey, hashKey: Data(hashKeyToken.utf8))
        DebugLog.log("[AlbumWrite] album created ✓")
        return albumLinkID
    }

    // MARK: Add photos

    /// Adds existing photos to `albumID`, re-encrypting their link metadata to the album key.
    /// Returns per-photo outcomes; throws only for whole-request failures (auth/network/album
    /// material) - per-item failures are reported, never masked.
    func attach(_ items: [AlbumAttachRequestItem], albumID: String) async throws -> AlbumAttachResult {
        try await withAdmission { service in
            try await service.attachImpl(items, albumID: albumID)
        }
    }

    private func attachImpl(_ items: [AlbumAttachRequestItem], albumID: String) async throws -> AlbumAttachResult {
        var result = AlbumAttachResult()
        try Task.checkCancellation()
        guard !items.isEmpty else { return result }
        let material = try await resolveRootMaterial()
        try Task.checkCancellation()
        let album = try await resolveAlbumMaterial(albumID: albumID, root: material)
        try Task.checkCancellation()

        // The Photos metadata endpoint exposes each main photo's related link IDs. Proton requires a
        // Live Photo / burst main and every related link in the same add request; sending only the
        // visible timeline link is rejected with code 2000.
        let ids = items.map(\.uid.nodeID)
        var metadata = try await fetchAlbumPhotoMetadata(volumeID: material.context.volumeID, linkIDs: ids)
        try Task.checkCancellation()
        let relatedIDs = Set(metadata.values.flatMap(\.relatedPhotoLinkIDs)).subtracting(metadata.keys)
        if !relatedIDs.isEmpty {
            metadata.merge(
                try await fetchAlbumPhotoMetadata(
                    volumeID: material.context.volumeID,
                    linkIDs: relatedIDs.sorted()
                ),
                uniquingKeysWith: { current, _ in current }
            )
            try Task.checkCancellation()
        }

        var groups: [PreparedPhotoGroup] = []
        groups.reserveCapacity(items.count)
        let prepared = try await Self.prepareGroups(
            items: items,
            metadata: metadata,
            root: material.rootKey,
            album: album,
            signer: material.signer,
            crypto: crypto,
            maximumConcurrency: Self.payloadPreparationConcurrency
        )
        for outcome in prepared {
            try Task.checkCancellation()
            guard let group = outcome.group else {
                result.outcomes[outcome.mainLinkID] = .failed(
                    code: nil,
                    message: outcome.failureMessage ?? "album payload preparation failed"
                )
                continue
            }
            groups.append(group)
        }

        for batch in Self.batches(groups) {
            try Task.checkCancellation()
            let responses = try await session.addToAlbum(
                volumeID: material.context.volumeID,
                albumLinkID: albumID,
                albumData: batch.flatMap(\.payloads).map(\.dictionary)
            )
            for group in batch {
                switch Self.evaluateMainResponse(responses, mainLinkID: group.mainLinkID) {
                case .outcome(let outcome):
                    result.outcomes[group.mainLinkID] = outcome
                case .retryMissing(let missing):
                    result.outcomes[group.mainLinkID] = try await retryGroupOnce(
                        group,
                        missingLinkIDs: missing,
                        albumID: albumID,
                        root: material,
                        album: album
                    )
                }
            }
        }
        DebugLog.log(
            "[AlbumWrite] attach n=\(items.count) ok=\(result.attachedCount) member=\(result.alreadyMemberCount) failed=\(result.failedCount)"
        )
        return result
    }

    private nonisolated static func prepareGroups(
        items: [AlbumAttachRequestItem],
        metadata: [String: AlbumPhotoMetadata],
        root: UnlockableKey,
        album: AlbumMaterial,
        signer: DriveCryptoSigner,
        crypto: DriveCrypto,
        maximumConcurrency: Int
    ) async throws -> [PreparedPhotoGroupOutcome] {
        guard !items.isEmpty else { return [] }

        return try await withThrowingTaskGroup(
            of: (Int, PreparedPhotoGroupOutcome).self,
            returning: [PreparedPhotoGroupOutcome].self
        ) { group in
            var nextIndex = 0
            var ordered = [(Int, PreparedPhotoGroupOutcome)?](repeating: nil, count: items.count)

            func addNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    let outcome = try await Self.prepareGroup(
                        item: items[index],
                        metadata: metadata,
                        root: root,
                        album: album,
                        signer: signer,
                        crypto: crypto
                    )
                    return (index, outcome)
                }
            }

            for _ in 0..<min(max(1, maximumConcurrency), items.count) {
                addNext()
            }
            while let (index, outcome) = try await group.next() {
                ordered[index] = (index, outcome)
                addNext()
            }
            return ordered.compactMap { $0?.1 }
        }
    }

    private nonisolated static func prepareGroup(
        item: AlbumAttachRequestItem,
        metadata: [String: AlbumPhotoMetadata],
        root: UnlockableKey,
        album: AlbumMaterial,
        signer: DriveCryptoSigner,
        crypto: DriveCrypto
    ) async throws -> PreparedPhotoGroupOutcome {
        try Task.checkCancellation()
        let mainLinkID = item.uid.nodeID
        guard let main = metadata[mainLinkID] else {
            return PreparedPhotoGroupOutcome(
                mainLinkID: mainLinkID,
                group: nil,
                failureMessage: "link metadata unavailable"
            )
        }

        let groupIDs = [mainLinkID] + main.relatedPhotoLinkIDs.filter { $0 != mainLinkID }
        var payloads: [PreparedAttachPayload] = []
        payloads.reserveCapacity(groupIDs.count)
        do {
            for groupID in groupIDs {
                try Task.checkCancellation()
                guard let photo = metadata[groupID] else {
                    throw AlbumPayloadPreparationError.relatedMetadataUnavailable
                }
                let requestItem =
                    groupID == mainLinkID
                    ? item
                    : AlbumAttachRequestItem(
                        uid: PhotoUID(volumeID: item.uid.volumeID, nodeID: groupID)
                    )
                payloads.append(
                    try await makeAttachPayload(
                        item: requestItem,
                        metadata: photo,
                        root: root,
                        album: album,
                        signer: signer,
                        crypto: crypto
                    )
                )
            }
        } catch {
            if error is CancellationError { throw error }
            return PreparedPhotoGroupOutcome(
                mainLinkID: mainLinkID,
                group: nil,
                failureMessage: "album payload preparation failed"
            )
        }
        return PreparedPhotoGroupOutcome(
            mainLinkID: mainLinkID,
            group: PreparedPhotoGroup(mainLinkID: mainLinkID, payloads: payloads),
            failureMessage: nil
        )
    }

    private func fetchAlbumPhotoMetadata(
        volumeID: String,
        linkIDs: [String]
    ) async throws -> [String: AlbumPhotoMetadata] {
        var result: [String: AlbumPhotoMetadata] = [:]
        for start in stride(from: 0, to: linkIDs.count, by: Self.metadataBatchSize) {
            try Task.checkCancellation()
            let end = min(start + Self.metadataBatchSize, linkIDs.count)
            let fetched = try await session.fetchAlbumPhotoMetadata(
                volumeID: volumeID,
                linkIDs: Array(linkIDs[start..<end])
            )
            try Task.checkCancellation()
            for metadata in fetched {
                try Task.checkCancellation()
                guard let id = metadata.link.linkID else { continue }
                result[id] = metadata
            }
        }
        return result
    }

    private nonisolated static func makeAttachPayload(
        item: AlbumAttachRequestItem,
        metadata: AlbumPhotoMetadata,
        root: UnlockableKey,
        album: AlbumMaterial,
        signer: DriveCryptoSigner,
        crypto: DriveCrypto
    ) async throws -> PreparedAttachPayload {
        let link = metadata.link
        guard let linkID = link.linkID, let armoredName = link.name,
            let nodeKey = link.nodeKey, let nodePassphrase = link.nodePassphrase
        else {
            throw AlbumPayloadPreparationError.linkMetadataUnavailable
        }
        try Task.checkCancellation()
        let clearName = try crypto.decryptName(armoredName, parent: root)
        try Task.checkCancellation()
        let clearPassphrase = try crypto.decryptPassphrase(nodePassphrase, parent: root)
        try Task.checkCancellation()
        let newName = try crypto.encryptAndSign(text: clearName, to: album.key, signer: signer)
        try Task.checkCancellation()
        let newPassphrase = try crypto.encrypt(text: clearPassphrase, to: album.key)
        try Task.checkCancellation()
        guard
            let sha1 = try await resolveSHA1Hex(
                item: item,
                revisionXAttr: metadata.activeRevisionXAttr,
                link: link,
                nodeKey: nodeKey,
                nodePassphrase: nodePassphrase,
                root: root,
                crypto: crypto
            )
        else {
            throw AlbumPayloadPreparationError.contentHashUnavailable
        }
        try Task.checkCancellation()
        return PreparedAttachPayload(
            linkID: linkID,
            name: newName,
            hash: ProtonPhotoHMAC.hex(message: clearName, key: album.hashKey),
            nodePassphrase: newPassphrase,
            nameSignatureEmail: signer.email,
            contentHash: ProtonPhotoHMAC.hex(message: sha1, key: album.hashKey)
        )
    }

    private func retryGroupOnce(
        _ group: PreparedPhotoGroup,
        missingLinkIDs: [String],
        albumID: String,
        root: RootMaterial,
        album: AlbumMaterial
    ) async throws -> AlbumAttachItemOutcome {
        try Task.checkCancellation()
        let existing = Set(group.payloads.map(\.linkID))
        let missing = missingLinkIDs.filter { !existing.contains($0) }
        guard !missing.isEmpty else {
            return .failed(code: 2000, message: "related photo set remained incomplete")
        }
        let metadata = try await fetchAlbumPhotoMetadata(
            volumeID: root.context.volumeID,
            linkIDs: missing
        )
        try Task.checkCancellation()
        var retry = group
        for linkID in missing {
            try Task.checkCancellation()
            guard let photo = metadata[linkID] else {
                return .failed(code: 2000, message: "related photo metadata unavailable")
            }
            retry.payloads.append(
                try await Self.makeAttachPayload(
                    item: AlbumAttachRequestItem(
                        uid: PhotoUID(volumeID: root.context.volumeID, nodeID: linkID)
                    ),
                    metadata: photo,
                    root: root.rootKey,
                    album: album,
                    signer: root.signer,
                    crypto: crypto
                )
            )
        }
        try Task.checkCancellation()
        let responses = try await session.addToAlbum(
            volumeID: root.context.volumeID,
            albumLinkID: albumID,
            albumData: retry.payloads.map(\.dictionary)
        )
        // The Missing retry is attempted exactly once. A second Missing verdict is an
        // unconfirmed mutation and must surface as failure, not as attached.
        switch Self.evaluateMainResponse(responses, mainLinkID: group.mainLinkID) {
        case .outcome(let outcome):
            return outcome
        case .retryMissing:
            return .failed(code: 2000, message: "related photo set remained incomplete")
        }
    }

    private static func batches(_ groups: [PreparedPhotoGroup]) -> [[PreparedPhotoGroup]] {
        var result: [[PreparedPhotoGroup]] = []
        var current: [PreparedPhotoGroup] = []
        var currentSize = 0
        for group in groups {
            let size = group.payloads.count
            if !current.isEmpty, currentSize + size > addBatchSize {
                result.append(current)
                current = []
                currentSize = 0
            }
            current.append(group)
            currentSize += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Strict evaluation of the main link's echoed response row. Success requires exactly one
    /// unambiguous row for the main link carrying a recognized code (1000 attached, 2500 already a
    /// member). Anything else - absent, duplicate, contradictory, or code-less - is an unconfirmed
    /// mutation and must surface as failure, never as attached.
    private static func evaluateMainResponse(
        _ responses: [AlbumAddItemResponse],
        mainLinkID: String
    ) -> MainResponseEvaluation {
        let mainRows = responses.filter { $0.linkID == mainLinkID }
        guard mainRows.count == 1, let status = mainRows.first?.response else {
            let absent = mainRows.isEmpty
            return .outcome(
                .failed(
                    code: nil,
                    message:
                        absent
                        ? "album response missing for the requested item"
                        : "album response was ambiguous for the requested item"
                ))
        }
        if status.code == 2000, let missing = status.details?.missing, !missing.isEmpty {
            return .retryMissing(missing)
        }
        // The existing album contract treats 2500 as idempotent membership, including the
        // server's explanatory Error text. Tightening that known status would regress retries.
        if status.code == 2500 { return .outcome(.alreadyMember) }
        if status.code == 1000 {
            guard status.error?.isEmpty != false else {
                return .outcome(.failed(code: 1000, message: "unconfirmed album response"))
            }
            return .outcome(.attached)
        }
        if status.code == 2000 {
            return .outcome(
                .failed(
                    code: 2000, message: status.error.flatMap { $0.isEmpty ? nil : $0 } ?? "unconfirmed album response")
            )
        }
        return .outcome(
            .failed(
                code: status.code,
                message: "unconfirmed album response"
            ))
    }

    /// The link identifiers of the album's primary photos.
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await withAdmission { service in
            try await service.childMainLinkIDsImpl(albumID: albumID)
        }
    }

    private func childMainLinkIDsImpl(albumID: String) async throws -> Set<String> {
        let material = try await resolveRootMaterial()
        let entries = try await session.fetchAlbumPhotos(volumeID: material.context.volumeID, albumLinkID: albumID)
        return Set(entries.map(\.linkID))
    }

    // MARK: SHA1 resolution (for ContentHash)

    private nonisolated static func resolveSHA1Hex(
        item: AlbumAttachRequestItem,
        revisionXAttr: String?,
        link: AlbumPhotoLinkBody,
        nodeKey: String,
        nodePassphrase: String,
        root: UnlockableKey,
        crypto: DriveCrypto
    ) async throws -> String? {
        try Task.checkCancellation()
        if let sha1 = item.sha1Hex, !sha1.isEmpty { return sha1.lowercased() }
        // Fallback: the SHA1 digest Proton clients store in the (revision) XAttr.
        guard let armoredXAttr = revisionXAttr ?? link.xAttr ?? link.fileProperties?.activeRevision?.xAttr else {
            return nil
        }
        try Task.checkCancellation()
        guard let photoKey = try? crypto.unlockNode(key: nodeKey, passphrase: nodePassphrase, parent: root),
            let data = try? crypto.decryptXAttr(armoredXAttr, node: photoKey),
            let digest = (try? JSONDecoder().decode(AlbumXAttrDigests.self, from: data))?.common?.digests?.sha1,
            !digest.isEmpty
        else {
            return nil
        }
        try Task.checkCancellation()
        return digest.lowercased()
    }

    // MARK: Key material

    private func resolveRootMaterial() async throws -> RootMaterial {
        if let rootMaterial { return rootMaterial }
        if let rootMaterialTask { return try await rootMaterialTask.value }
        let session = self.session
        let crypto = self.crypto
        let contextProvider = self.contextProvider
        let task = Task { () -> RootMaterial in
            let context = try await contextProvider()
            let bootstrap = try await session.getJSON(
                "/drive/shares/\(context.shareID)", as: AlbumShareBootstrap.self
            )
            let shareKey = try crypto.unlockShare(key: bootstrap.key, passphrase: bootstrap.passphrase)
            let rootLink = try await session.getJSON(
                "/drive/shares/\(context.shareID)/links/\(context.rootLinkID)", as: AlbumRootLinkResponse.self
            )
            guard let armoredHashKey = rootLink.link.folderProperties?.nodeHashKey else {
                throw ProtonAlbumWriteError.missingRootHashKey
            }
            let rootKey = try crypto.unlockNode(
                key: rootLink.link.nodeKey, passphrase: rootLink.link.nodePassphrase, parent: shareKey
            )
            let rootHashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: rootKey).utf8)
            guard let signer = crypto.signer(preferredAddressID: bootstrap.addressID) else {
                throw ProtonAlbumWriteError.noSigningKey
            }
            DebugLog.log("[AlbumWrite] root material resolved ✓")
            return RootMaterial(context: context, rootKey: rootKey, rootHashKey: rootHashKey, signer: signer)
        }
        rootMaterialTask = task
        defer { rootMaterialTask = nil }
        let resolved = try await task.value
        rootMaterial = resolved
        return resolved
    }

    /// Album key + decrypted hash key: from the create-path cache when we just made the album,
    /// otherwise fetched + decrypted from the album link (albums are children of the photos root,
    /// so their passphrase decrypts with the root key - same chain the album title decryption uses).
    private func resolveAlbumMaterial(albumID: String, root: RootMaterial) async throws -> AlbumMaterial {
        if let cached = albumMaterials[albumID] { return cached }
        let response = try await session.getJSON(
            "/drive/shares/\(root.context.shareID)/links/\(albumID)", as: AlbumLinkResponse.self
        )
        let link = response.link
        guard let armoredHashKey = link.folderProperties?.nodeHashKey ?? link.albumProperties?.nodeHashKey else {
            throw ProtonAlbumWriteError.missingAlbumHashKey
        }
        let albumKey = try crypto.unlockNode(key: link.nodeKey, passphrase: link.nodePassphrase, parent: root.rootKey)
        let hashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: albumKey).utf8)
        let material = AlbumMaterial(key: albumKey, hashKey: hashKey)
        albumMaterials[albumID] = material
        return material
    }
}

// MARK: - Wire models (PascalCase JSON)

private struct AlbumShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    let addressID: String?
    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case passphrase = "Passphrase"
        case addressID = "AddressID"
    }
}

private struct AlbumRootLinkResponse: Decodable {
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

private struct AlbumLinkResponse: Decodable {
    let link: Link
    enum CodingKeys: String, CodingKey { case link = "Link" }
    struct Link: Decodable {
        let nodeKey: String
        let nodePassphrase: String
        let folderProperties: HashKeyProps?
        let albumProperties: HashKeyProps?
        enum CodingKeys: String, CodingKey {
            case nodeKey = "NodeKey"
            case nodePassphrase = "NodePassphrase"
            case
                folderProperties = "FolderProperties"
            case albumProperties = "AlbumProperties"
        }
        struct HashKeyProps: Decodable {
            let nodeHashKey: String?
            enum CodingKeys: String, CodingKey { case nodeHashKey = "NodeHashKey" }
        }
    }
}

/// Tolerant link body for the attach path: single missing fields become per-item failures rather
/// than failing the whole batch decode (same posture as the trash listing DTO).
struct AlbumPhotoLinkBody: Decodable, Sendable {
    let linkID: String?
    let state: Int?
    let type: Int?
    let mimeType: String?
    let name: String?
    let nodeKey: String?
    let nodePassphrase: String?
    let xAttr: String?
    let fileProperties: FileProps?
    struct FileProps: Decodable, Sendable {
        let activeRevision: Revision?
        struct Revision: Decodable, Sendable {
            let xAttr: String?
            let photo: Photo?
            struct Photo: Decodable, Sendable {
                let mainPhotoLinkID: String?
                enum CodingKeys: String, CodingKey { case mainPhotoLinkID = "MainPhotoLinkID" }
            }
            enum CodingKeys: String, CodingKey {
                case xAttr = "XAttr"
                case photo = "Photo"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                xAttr = try container.decodeIfPresent(String.self, forKey: .xAttr)
                // Only the lineage index reads the photo section. A malformed one leaves the role unknown and must
                // not fail the metadata of the whole batch, which the content index and albums read as well.
                photo = (try? container.decodeIfPresent(Photo.self, forKey: .photo)) ?? nil
            }
        }
        enum CodingKeys: String, CodingKey { case activeRevision = "ActiveRevision" }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"
        case state = "State"
        case type = "Type"
        case mimeType = "MIMEType"
        case
            name = "Name"
        case nodeKey = "NodeKey"
        case
            nodePassphrase = "NodePassphrase"
        case xAttr = "XAttr"
        case fileProperties = "FileProperties"
    }
}

struct AlbumPhotoMetadata: Decodable, Sendable {
    let link: AlbumPhotoLinkBody
    let photo: Photo?

    struct Photo: Decodable, Sendable {
        let relatedPhotoLinkIDs: [String]
        let hasCompleteRelatedPhotoLinkIDs: Bool
        let captureTime: Double?
        let tags: [Int]?
        let activeRevision: Revision?

        struct Revision: Decodable, Sendable {
            let xAttr: String?
            enum CodingKeys: String, CodingKey { case xAttr = "XAttr" }
        }

        enum CodingKeys: String, CodingKey {
            case captureTime = "CaptureTime"
            case tags = "Tags"
            case relatedPhotoLinkIDs = "RelatedPhotosLinkIDs"
            case activeRevision = "ActiveRevision"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let related = try values.decodeIfPresent([String].self, forKey: .relatedPhotoLinkIDs)
            captureTime = try? values.decodeIfPresent(Double.self, forKey: .captureTime)
            tags = try? values.decodeIfPresent([Int].self, forKey: .tags)
            hasCompleteRelatedPhotoLinkIDs = related != nil
            relatedPhotoLinkIDs = related ?? []
            activeRevision = try values.decodeIfPresent(Revision.self, forKey: .activeRevision)
        }
    }

    var relatedPhotoLinkIDs: [String] { photo?.relatedPhotoLinkIDs ?? [] }
    var activeRevisionXAttr: String? { photo?.activeRevision?.xAttr }

    enum CodingKeys: String, CodingKey {
        case link = "Link"
        case photo = "Photo"
    }
}

private struct AlbumXAttrDigests: Decodable {
    let common: Common?
    enum CodingKeys: String, CodingKey { case common = "Common" }
    struct Common: Decodable {
        let digests: Digests?
        enum CodingKeys: String, CodingKey { case digests = "Digests" }
        struct Digests: Decodable {
            let sha1: String?
            enum CodingKeys: String, CodingKey { case sha1 = "SHA1" }
        }
    }
}

// MARK: - Endpoints (DriveSession)

/// One per-item echo of the add-multiple multistatus body.
struct AlbumAddItemResponse: Decodable {
    let linkID: String?
    let response: Status?
    struct Status: Decodable {
        let code: Int?
        let error: String?
        let details: Details?

        struct Details: Decodable {
            let missing: [String]?
            enum CodingKeys: String, CodingKey { case missing = "Missing" }
        }

        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case error = "Error"
            case details = "Details"
        }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"
        case response = "Response"
    }
}

private struct AlbumAddResponse: Decodable {
    let responses: [AlbumAddItemResponse]?
    enum CodingKeys: String, CodingKey { case responses = "Responses" }
}

private struct AlbumCreateResponse: Decodable {
    let album: Album?
    enum CodingKeys: String, CodingKey { case album = "Album" }
    struct Album: Decodable {
        let link: Link?
        enum CodingKeys: String, CodingKey { case link = "Link" }
        struct Link: Decodable {
            let linkID: String?
            enum CodingKeys: String, CodingKey { case linkID = "LinkID" }
        }
    }
}

private struct AlbumLinksMetadataResponse: Decodable {
    let links: [AlbumPhotoLinkBody]?
    enum CodingKeys: String, CodingKey { case links = "Links" }
}

private struct AlbumPhotoMetadataResponse: Decodable {
    let links: [AlbumPhotoMetadata]
    enum CodingKeys: String, CodingKey { case links = "Links" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        links = try values.decodeIfPresent([AlbumPhotoMetadata].self, forKey: .links) ?? []
    }
}

extension DriveSession {
    /// `POST /drive/photos/volumes/{volumeID}/albums` - creates an album node, returns its link id.
    func createAlbum(volumeID: String, link: [String: Any]) async throws -> String {
        let data = try await send(
            "/drive/photos/volumes/\(volumeID)/albums",
            method: "POST",
            body: ["Locked": false, "Link": link]
        )
        guard let linkID = (try? JSONDecoder().decode(AlbumCreateResponse.self, from: data))?.album?.link?.linkID,
            !linkID.isEmpty
        else {
            throw ProtonAlbumWriteError.malformedCreateResponse
        }
        return linkID
    }

    /// `POST /drive/photos/volumes/{volumeID}/albums/{albumLinkID}/add-multiple` returns multistatus
    /// batch (HTTP 200 with per-item codes). Callers target
    /// `ProtonAlbumWriteService.addBatchSize` entries, while a larger related-photo group remains
    /// atomic, and must inspect the per-item responses.
    func addToAlbum(
        volumeID: String, albumLinkID: String, albumData: [[String: Any]]
    ) async throws -> [AlbumAddItemResponse] {
        guard !albumData.isEmpty else { return [] }
        let data = try await send(
            "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)/add-multiple",
            method: "POST",
            body: ["AlbumData": albumData]
        )
        let decoded: AlbumAddResponse
        do {
            decoded = try JSONDecoder().decode(AlbumAddResponse.self, from: data)
        } catch {
            // A body that cannot be decoded, or lacks the `Responses` multistatus array, leaves the
            // per-item outcomes unknown. Never silently downgrade that to a benign empty batch.
            throw ProtonAlbumWriteError.malformedAddResponse
        }
        guard let responses = decoded.responses else {
            throw ProtonAlbumWriteError.malformedAddResponse
        }
        return responses
    }

    /// `POST /drive/photos/volumes/{volumeID}/albums/{albumLinkID}/remove-multiple` removes only
    /// album membership. Proton's official Drive SDK batches this endpoint at ten link IDs and treats
    /// each successful batch as atomic because the response has no reliable per-photo result contract.
    func removeFromAlbum(volumeID: String, albumLinkID: String, linkIDs: [String]) async throws {
        guard !linkIDs.isEmpty else { return }
        for start in stride(from: 0, to: linkIDs.count, by: 10) {
            try Task.checkCancellation()
            let end = min(start + 10, linkIDs.count)
            _ = try await send(
                "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)/remove-multiple",
                method: "POST",
                body: ["LinkIDs": Array(linkIDs[start..<end])]
            )
        }
    }

    /// `POST /drive/shares/{shareID}/links/fetch_metadata` with the attach path's tolerant DTO.
    /// Callers chunk to the web client's metadata batch size (150).
    func fetchPhotoLinksMetadata(shareID: String, linkIDs: [String]) async throws -> [AlbumPhotoLinkBody] {
        guard !linkIDs.isEmpty else { return [] }
        let data = try await send(
            "/drive/shares/\(shareID)/links/fetch_metadata",
            method: "POST",
            body: ["LinkIDs": linkIDs],
            retryOnRateLimit: true
        )
        return (try JSONDecoder().decode(AlbumLinksMetadataResponse.self, from: data)).links ?? []
    }

    /// Current Photos metadata endpoint used by Proton's album client. Unlike the generic legacy metadata
    /// endpoint, it returns `Photo.RelatedPhotosLinkIDs`, which must be honored for Live Photos and bursts.
    func fetchAlbumPhotoMetadata(volumeID: String, linkIDs: [String]) async throws -> [AlbumPhotoMetadata] {
        guard !linkIDs.isEmpty else { return [] }
        let data = try await send(
            "/drive/photos/volumes/\(volumeID)/links",
            method: "POST",
            body: ["LinkIDs": linkIDs],
            retryOnRateLimit: true
        )
        return try JSONDecoder().decode(AlbumPhotoMetadataResponse.self, from: data).links
    }
}
