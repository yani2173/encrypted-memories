import Foundation
import PhotosCore

@testable import UploadCore

/// One server link table supplies every upload, duplicate, replacement, and album answer.
final class EditScenarioServer: PhotoUploading, UploadDuplicateChecking, EditReplacementRemote,
    SeriesAlbumCarryOver, @unchecked Sendable
{
    enum State: String, Sendable {
        case active
        case trashed
        case deleted
    }

    struct Link: Sendable {
        let linkID: String
        let nameHash: String
        let contentHash: String
        var state: State
        let mainLinkID: String?
        let captureTime: Date
        var favorite = false
        var albums: Set<SeriesAlbumReference> = []
        let assetID: String
        let generation: Int
        let isOriginal: Bool
        var personDeleted = false
        /// The person trashed this main as an earlier version while a newer main stayed. A restore keeps the flag.
        var personRetired = false
        /// The person restored this main from the trash. It is in the library by the person's choice.
        var personRestored = false
        var externalIdentity: UploadBackupExternalIdentity?
        var replacedLinkIDs: Set<String> = []
        var modificationDate: Date?
        var externalIdentifier: String?
        var mimeType = "image/jpeg"
        var tags: Set<Int> = []

        var uid: PhotoUID { PhotoUID(volumeID: "vol", nodeID: linkID) }
        var duplicate: RemotePhotoDuplicate {
            RemotePhotoDuplicate(
                nameHash: nameHash, contentHash: contentHash,
                linkState: state == .active ? .active : state == .trashed ? .trashed : nil,
                linkID: linkID)
        }
    }

    struct Step: Sendable {
        let action: String
        let links: [Link]
        let violations: [String]
        let trashedByBackup: [String]
    }

    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private var table: [String: Link] = [:]
    /// S5 state: the assets that the person deleted, with the earlier active mains that the deleting trash left.
    private var deletedAssets: [String: Set<String>] = [:]
    private var history: [Step] = []
    private var nextID = 1
    private var failTrash = false
    enum LineageRead: Sendable, Equatable { case identity, successors, ancestry, external }
    private var incompleteLineageRead: LineageRead?
    private var failLineageRead = false
    private var failVisibilityRead = false
    private var failCompoundRead = false
    private var cancelCompoundRead = false
    private var failRelatedLookupForTrashedMain = false
    private var healthOverride: UploadRemoteContentIndexHealth?
    private var sharedLinks: Set<String> = []
    private var nodeSizes: [String: Int64] = [:]
    private var missingNodes: Set<String> = []
    private var covers: [String: String] = [:]
    private var failCoverWrite = false
    typealias IndexProgress = @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    typealias IndexBuild = @Sendable (@escaping IndexProgress) async throws -> Void
    private var indexBuildOverride: IndexBuild?
    private var indexBuildCount = 0
    private var rejectedRelatedLookups: [String] = []
    private var proofLookups: [[UploadBackupExternalIdentity]] = []
    let uploadGate = EditScenarioUploadGate()
    private let ownAlbumIDs: Set<String> = ["own-album"]

    var links: [Link] { lock.withLock { orderedLinks() } }
    var personDeletedAssets: [String: Set<String>] { lock.withLock { deletedAssets } }
    var steps: [Step] { lock.withLock { history } }
    var remoteProofLookups: [[UploadBackupExternalIdentity]] { lock.withLock { proofLookups } }
    func noteProofLookup(_ identities: [UploadBackupExternalIdentity]) {
        lock.withLock { proofLookups.append(identities) }
    }
    var rejectedTrashedMainLookupIDs: [String] { lock.withLock { rejectedRelatedLookups } }

    /// The real endpoint's behavior for trashed mains remains unverified.
    var relatedLookupFailsForTrashedMain: Bool {
        get { lock.withLock { failRelatedLookupForTrashedMain } }
        set { lock.withLock { failRelatedLookupForTrashedMain = newValue } }
    }

    private func orderedLinks() -> [Link] {
        table.values.sorted { $0.linkID < $1.linkID }
    }

    static func contentHash(_ digest: Data) -> String {
        "ch(\(UploadContentSHA1.hexString(digest: digest)))"
    }

    private func record(_ action: String, violations: [String] = [], trashedByBackup: [String] = []) {
        history.append(
            Step(action: action, links: orderedLinks(), violations: violations, trashedByBackup: trashedByBackup))
    }

    func failNextTrash() { lock.withLock { failTrash = true } }

    /// The next favorites read fails.
    func failNextFavoritesRead() { lock.withLock { failFavoritesRead = true } }
    private var failFavoritesRead = false

    func configureLineageIndex(incomplete: LineageRead? = nil, failing: Bool = false) {
        lock.withLock {
            incompleteLineageRead = incomplete
            failLineageRead = failing
        }
    }

    func configureOptionalReads(
        visibilityFails: Bool = false, compoundFails: Bool = false, compoundCancels: Bool = false
    ) {
        lock.withLock {
            failVisibilityRead = visibilityFails
            failCompoundRead = compoundFails
            cancelCompoundRead = compoundCancels
        }
    }

    func setModificationDate(_ date: Date?, of uid: PhotoUID) {
        lock.withLock {
            guard var link = table[uid.nodeID] else { return }
            link.modificationDate = date
            link.externalIdentity = link.externalIdentifier.flatMap { identifier in
                date.map { UploadBackupExternalIdentity(identifier: identifier, modificationDate: $0) }
            }
            table[uid.nodeID] = link
        }
    }

    func modificationDate(ofMainLink linkID: String) async throws -> Date? {
        lock.withLock {
            guard let link = table[linkID], link.state == .active, link.mainLinkID == nil else { return nil }
            return link.modificationDate
        }
    }

    /// The person trashes this main right after its compound read, before any later read of the same pass.
    var trashAfterCompoundRead: String? {
        get { lock.withLock { pendingTrashAfterCompoundRead } }
        set { lock.withLock { pendingTrashAfterCompoundRead = newValue } }
    }
    private var pendingTrashAfterCompoundRead: String?

    /// Another device trashes this main right after the next duplicate trash, for example by its own merge.
    var trashAfterDuplicateTrash: String? {
        get { lock.withLock { pendingTrashAfterDuplicateTrash } }
        set { lock.withLock { pendingTrashAfterDuplicateTrash = newValue } }
    }
    private var pendingTrashAfterDuplicateTrash: String?

    /// The visibility reads that fail after the next duplicate trash, before a read succeeds again.
    var failingVisibilityReadsAfterDuplicateTrash: Int {
        get { lock.withLock { visibilityFailuresAfterTrash } }
        set { lock.withLock { visibilityFailuresAfterTrash = newValue } }
    }
    private var visibilityFailuresAfterTrash = 0
    private var armedVisibilityFailures = 0
    /// The error of those failing reads.
    var visibilityErrorAfterDuplicateTrash: any Error {
        get { lock.withLock { visibilityErrorAfterTrash } }
        set { lock.withLock { visibilityErrorAfterTrash = newValue } }
    }
    private var visibilityErrorAfterTrash: any Error = UploadError.backend(
        "The scenario visibility read after the trash failed")

    /// The reads of the duplicate merge so far.
    struct ReadCounts: Equatable {
        var visibility = 0
        var compound = 0
        var favorites = 0
        /// Photos whose album membership was read, one for each photo.
        var albumMembers = 0
        /// Photos whose node was read for its sharing state and size, one for each photo.
        var sharingMembers = 0
        var albumListings = 0
    }
    var readCounts: ReadCounts { lock.withLock { counted } }
    private var counted = ReadCounts()

    /// The album read of this photo answers these albums, as a stale membership cache does.
    func reportStaleAlbums(_ albums: Set<SeriesAlbumReference>, of uid: PhotoUID) {
        lock.withLock { staleAlbums[uid.nodeID] = albums }
    }
    private var staleAlbums: [String: Set<SeriesAlbumReference>] = [:]

    func compound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        lock.withLock { counted.compound += 1 }
        let compound = try readCompound(ofMainLink: linkID)
        lock.withLock {
            guard pendingTrashAfterCompoundRead == linkID else { return }
            pendingTrashAfterCompoundRead = nil
            table[linkID]?.state = .trashed
            table[linkID]?.personDeleted = true
            record("person trash \(linkID) after its compound read")
        }
        return compound
    }

    private func readCompound(ofMainLink linkID: String) throws -> UploadRemoteCompound? {
        try lock.withLock {
            if cancelCompoundRead { throw CancellationError() }
            if failCompoundRead { throw UploadError.backend("The scenario compound read failed") }
            guard let main = table[linkID], main.state == .active, main.mainLinkID == nil else { return nil }
            let resources = orderedLinks().filter { $0.mainLinkID == linkID && $0.state != .deleted }
            guard resources.allSatisfy({ $0.state == .active }) else { return nil }
            func file(_ link: Link) -> UploadRemoteCompound.File {
                .init(
                    linkID: link.linkID, contentHash: link.contentHash,
                    nameHash: link.nameHash, mimeType: link.mimeType)
            }
            return UploadRemoteCompound(
                main: file(main), related: resources.map(file), tags: main.tags,
                externalIdentifier: main.externalIdentifier,
                // The API returns CaptureTime in whole seconds.
                captureDate: Date(timeIntervalSince1970: main.captureTime.timeIntervalSince1970.rounded(.down)),
                modificationDate: main.modificationDate)
        }
    }

    func setTags(_ tags: Set<Int>, of uid: PhotoUID) {
        lock.withLock { table[uid.nodeID]?.tags = tags }
    }

    func activeMainLinkIDs(
        forExternalIdentifier identifier: String
    ) async throws -> (links: Set<String>, complete: Bool) {
        try lock.withLock {
            if failLineageRead { throw UploadError.backend("The scenario lineage read failed") }
            return (
                Set(
                    table.values.filter {
                        $0.state == .active && $0.mainLinkID == nil && $0.externalIdentifier == identifier
                    }.map(\.linkID)), incompleteLineageRead != .identity
            )
        }
    }

    func replacingMainLinkIDs(ofReplacedLink linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        try lock.withLock {
            if failLineageRead { throw UploadError.backend("The scenario lineage read failed") }
            return (
                Set(
                    table.values.filter {
                        $0.state == .active && $0.mainLinkID == nil && $0.replacedLinkIDs.contains(linkID)
                    }.map(\.linkID)), incompleteLineageRead != .successors
            )
        }
    }

    func externalIdentifier(ofMainLink linkID: String) async throws -> (identifier: String?, complete: Bool) {
        try lock.withLock {
            if failLineageRead { throw UploadError.backend("The scenario lineage read failed") }
            let link = table[linkID]
            let identifier =
                link?.state == .active && link?.mainLinkID == nil ? link?.externalIdentifier : nil
            return (identifier, incompleteLineageRead != .external)
        }
    }

    func replacedLinkIDs(ofReplacingMain linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        try lock.withLock {
            if failLineageRead { throw UploadError.backend("The scenario lineage read failed") }
            let link = table[linkID]
            return (
                link?.state == .active && link?.mainLinkID == nil ? link?.replacedLinkIDs ?? [] : [],
                incompleteLineageRead != .ancestry
            )
        }
    }

    /// The fixture starts with links that v1.0.5 uploaded; these are not uploads by today's runner.
    func seedV105Upload(
        _ descriptor: UploadResourceDescriptor, digest: Data, asset: EditScenarioLibrary.Asset, main: PhotoUID?,
        externalIdentifier: String? = nil, replacing: Set<String> = [], mimeType: String = "image/jpeg"
    ) -> PhotoUID {
        lock.withLock {
            let id = String(format: "link-%04d", nextID)
            nextID += 1
            table[id] = Link(
                linkID: id, nameHash: "nh(\(descriptor.filename))",
                contentHash: Self.contentHash(digest), state: .active,
                mainLinkID: main?.nodeID, captureTime: asset.captureTime, assetID: asset.identifier,
                generation: asset.generation,
                isOriginal: descriptor.filename.hasSuffix(".HEIC") || descriptor.filename.hasSuffix(".MOV"),
                externalIdentity: externalIdentifier.map {
                    UploadBackupExternalIdentity(identifier: $0, modificationDate: asset.modificationDate)
                }, replacedLinkIDs: replacing, modificationDate: asset.modificationDate,
                externalIdentifier: externalIdentifier, mimeType: mimeType)
            record("v1.0.5 upload \(id)")
            return PhotoUID(volumeID: "vol", nodeID: id)
        }
    }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let digest = try UploadContentSHA1.digest(ofFileAt: request.fileURL)
        guard request.expectedSHA1 == digest else {
            throw UploadError.backend("The scenario upload bytes do not match the pipeline identity")
        }
        let generation = Int(request.fileURL.lastPathComponent.split(separator: "-")[0]) ?? 0
        await uploadGate.suspendIfArmed(generation: generation, isMain: request.mainPhotoUID == nil)
        let externalIdentity = try Self.externalIdentity(in: request.additionalMetadata)
        onProgress(.init(phase: .uploading, fraction: 1))
        return lock.withLock {
            let assetID = request.fileURL.deletingLastPathComponent().lastPathComponent
            let id = String(format: "link-%04d", nextID)
            nextID += 1
            let main = request.mainPhotoUID?.nodeID
            var violations: [String] = []
            if main == nil && deletedAssets[assetID] != nil {
                violations.append("S5 uploaded \(id) after the person deleted \(assetID)")
            }
            if let main, table[main]?.state != .active {
                violations.append("An upload referenced inactive main \(main)")
            }
            table[id] = Link(
                linkID: id, nameHash: "nh(\(request.name))", contentHash: Self.contentHash(digest),
                state: .active, mainLinkID: main, captureTime: request.captureTime,
                assetID: assetID, generation: generation,
                isOriginal: request.name.hasSuffix(".HEIC") || request.name.hasSuffix(".MOV"),
                externalIdentity: externalIdentity, modificationDate: externalIdentity?.revision.date,
                externalIdentifier: externalIdentity?.identifier, mimeType: request.mediaType, tags: Set(request.tags))
            record("upload \(id)", violations: violations)
            return PhotoUID(volumeID: "vol", nodeID: id)
        }
    }

    private static func externalIdentity(
        in metadata: [PhotoUploadAdditionalMetadata]
    ) throws -> UploadBackupExternalIdentity? {
        guard let value = metadata.first(where: { $0.name == "iOS.photos" }) else { return nil }
        let photos = try JSONDecoder().decode(PhotoUploadMetadataEncoder.IOSPhotos.self, from: value.utf8JsonValue)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let identifier = photos.iCloudID, !identifier.isEmpty,
            let timestamp = photos.modificationTime, let date = formatter.date(from: timestamp)
        else { throw UploadError.backend("The scenario upload has invalid iOS.photos metadata") }
        return UploadBackupExternalIdentity(identifier: identifier, modificationDate: date)
    }

    /// The answer of a full index build at this moment, as `RemotePhotoAssetProofBuilder` gives it. A device keeps
    /// it in `EditScenarioDeviceIndex`; the server itself answers no proof lookup of a pipeline.
    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        lock.withLock { proofLookups.append(identities) }
        return allRemoteAssetProofs().filter { identities.contains($0.key) }
    }

    /// Mirrors the active compound proof: every resource must carry the same external identity.
    /// The count comes from actual uploaded links, rather than the candidate asking for a proof.
    func allRemoteAssetProofs() -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        lock.withLock {
            var proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] = [:]
            var ambiguous: Set<UploadBackupExternalIdentity> = []
            for main in orderedLinks() where main.mainLinkID == nil && main.state == .active {
                guard let identity = main.externalIdentity else { continue }
                let compound = [main] + orderedLinks().filter { $0.mainLinkID == main.linkID }
                guard compound.allSatisfy({ $0.state == .active && $0.externalIdentity == identity }) else { continue }
                if proofs[identity] != nil { ambiguous.insert(identity) }
                proofs[identity] = UploadRemoteAssetIndexRecord(
                    externalIdentity: identity, resourceCount: compound.count,
                    remoteLinkIDs: compound.map(\.linkID), hashKeyEpoch: "scenario-epoch")
            }
            for identity in ambiguous { proofs.removeValue(forKey: identity) }
            return proofs
        }
    }

    func cancel(token: UUID) async {}
    func nameHash(forCorrectedName name: String) async throws -> String { "nh(\(name))" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "ch(\(sha1Hex))" }
    func hashKeyEpoch() async throws -> String { "scenario-epoch" }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock {
            // Trashed mains and active orphaned related files remain visible to duplicate checks.
            // The seam has no deleted link state. A permanently deleted link is absent remotely.
            orderedLinks().filter { $0.state != .deleted && nameHashes.contains($0.nameHash) }.map(\.duplicate)
        }
    }

    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        lock.withLock {
            // The content index proves only active content. Name lookup still includes trash.
            orderedLinks().first { $0.state == .active && $0.contentHash == contentHash }?.duplicate
        }
    }

    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID] {
        lock.withLock {
            orderedLinks().filter {
                $0.state == .active && $0.nameHash == "nh(\(correctedName))"
                    && $0.contentHash == Self.contentHash(sha1Digest)
            }.map(\.uid)
        }
    }

    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        try lock.withLock {
            guard let main = table[mainLinkID], main.state != .deleted else {
                throw UploadError.backend("Related photos of the main photo are unavailable")
            }
            if main.state == .trashed && failRelatedLookupForTrashedMain {
                rejectedRelatedLookups.append(mainLinkID)
                record("failed related lookup of trashed main \(mainLinkID)")
                throw UploadError.backend("The scenario endpoint rejects related lookup of a trashed main")
            }
            return Set(table.values.filter { $0.mainLinkID == mainLinkID && $0.state != .deleted }.map(\.linkID))
        }
    }

    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        guard !linkIDs.isEmpty else { return [:] }
        return try lock.withLock {
            counted.visibility += 1
            if failVisibilityRead { throw UploadError.backend("The scenario visibility read failed") }
            if armedVisibilityFailures > 0 {
                armedVisibilityFailures -= 1
                throw visibilityErrorAfterTrash
            }
            var result: [String: RemoteLinkVisibility] = [:]
            for linkID in linkIDs {
                guard let link = table[linkID], link.state != .deleted else { continue }
                result[linkID] = RemoteLinkVisibility(
                    isActive: link.state == .active, mainPhotoLinkID: link.mainLinkID)
            }
            return result
        }
    }

    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        lock.withLock {
            healthOverride ?? .complete(indexedCount: table.values.filter { $0.state == .active }.count)
        }
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        let build = lock.withLock {
            indexBuildCount += 1
            return indexBuildOverride
        }
        guard let build else { return await progress(.init(phase: .ready)) }
        try await build(progress)
    }

    /// Runs in place of the backend's index build. Nil reports a ready index at once.
    var indexBuild: IndexBuild? {
        get { lock.withLock { indexBuildOverride } }
        set { lock.withLock { indexBuildOverride = newValue } }
    }

    var indexBuilds: Int { lock.withLock { indexBuildCount } }

    /// The index state that the next health checks report. Nil reports a complete index.
    var indexHealth: UploadRemoteContentIndexHealth? {
        get { lock.withLock { healthOverride } }
        set { lock.withLock { healthOverride = newValue } }
    }

    func ownPhotosVolumeID() async throws -> String { "vol" }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { Set(uids.filter { table[$0.nodeID]?.state == .active }) }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        try lock.withLock {
            counted.favorites += 1
            if failFavoritesRead {
                failFavoritesRead = false
                throw UploadError.backend("The scenario favorites read failed once")
            }
            return Set(uids.filter { table[$0.nodeID]?.favorite == true })
        }
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        lock.withLock {
            for uid in uids { table[uid.nodeID]?.favorite = true }
            record("mark favorite")
        }
    }

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        try lock.withLock {
            counted.albumMembers += 1
            if missingNodes.contains(uid.nodeID) { throw UploadError.backend("The scenario node is missing") }
            return (staleAlbums[uid.nodeID] ?? table[uid.nodeID]?.albums ?? []).sorted {
                ($0.volumeID, $0.albumID) < ($1.volumeID, $1.albumID)
            }
        }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try lock.withLock {
            guard ownAlbumIDs.contains(albumID) else {
                throw UploadError.backend("The scenario album is not a known own-volume album")
            }
            for uid in uids {
                table[uid.nodeID]?.albums.insert(.init(volumeID: "vol", albumID: albumID))
            }
            record("carry album \(albumID)")
        }
    }

    func decorate(_ uid: PhotoUID) {
        lock.withLock {
            table[uid.nodeID]?.favorite = true
            table[uid.nodeID]?.albums = [
                .init(volumeID: "vol", albumID: "own-album"),
                .init(volumeID: "shared-vol", albumID: "shared-album"),
            ]
            record("person favorites and files \(uid.nodeID)")
        }
    }

    func trashReplaced(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if failTrash {
                failTrash = false
                record("failed backup trash")
                throw UploadError.backend("The scenario trash write failed once")
            }
            var violations: [String] = []
            let targets = Set(uids.map(\.nodeID))
            for uid in uids {
                guard let target = table[uid.nodeID], target.state == .active else { continue }
                let replacements = table.values.filter {
                    $0.mainLinkID == nil && $0.state == .active && $0.assetID == target.assetID
                        && !targets.contains($0.linkID)
                }
                if target.mainLinkID != nil || replacements.isEmpty {
                    violations.append("S6 backup trash targeted something other than an earlier asset main")
                }
                if target.personRetired {
                    violations.append(
                        "S7 backup trash targeted \(target.linkID), which the person trashed as an earlier version")
                }
                let originals = table.values.filter {
                    ($0.linkID == target.linkID || $0.mainLinkID == target.linkID) && $0.isOriginal
                        && $0.state == .active
                }
                for original in originals {
                    let preserved = table.values.contains { copy in
                        guard copy.state == .active, copy.contentHash == original.contentHash,
                            copy.assetID == target.assetID
                        else { return false }
                        let holderID = copy.mainLinkID ?? copy.linkID
                        return !targets.contains(holderID) && table[holderID]?.state == .active
                            && table[holderID]?.mainLinkID == nil
                    }
                    if !preserved {
                        violations.append("S2 backup trash lost original resource \(original.linkID)")
                    }
                }
                // Service rule: only the main changes state. No related-file event exists.
                table[uid.nodeID]?.state = .trashed
            }
            record("backup trash \(uids.map(\.nodeID))", violations: violations, trashedByBackup: uids.map(\.nodeID))
        }
    }

    /// S5: the asset is deleted by the person when a person trash leaves no newer active main of the asset and no main
    /// that the person restored. A person trash of an earlier main while a newer main stays active retires that
    /// main and leaves the asset in the library.
    func personTrash(_ uid: PhotoUID) {
        lock.withLock {
            guard let target = table[uid.nodeID] else { return }
            table[uid.nodeID]?.state = .trashed
            table[uid.nodeID]?.personDeleted = true
            let remaining = table.values.filter {
                $0.assetID == target.assetID && $0.mainLinkID == nil && $0.state == .active
            }
            if target.mainLinkID == nil, remaining.contains(where: { $0.generation > target.generation }) {
                table[uid.nodeID]?.personRetired = true
            } else if !remaining.contains(where: { $0.personRetired || $0.personRestored }) {
                // Earlier mains that wait for their original stay; the person kept no version in the library.
                deletedAssets[target.assetID] = Set(remaining.map(\.linkID))
            }
            record("person trash \(uid.nodeID)")
        }
    }

    /// A restore ends the S5 deletion of the asset. It keeps `personRetired`.
    func personRestore(_ uid: PhotoUID) {
        lock.withLock {
            guard let restored = table[uid.nodeID], restored.state == .trashed else { return }
            table[uid.nodeID]?.state = .active
            for id in Array(table.keys) where table[id]?.assetID == restored.assetID {
                table[id]?.personDeleted = false
            }
            table[uid.nodeID]?.personRestored = true
            deletedAssets[restored.assetID] = nil
            record("person restore \(uid.nodeID)")
        }
    }

    /// The lineage marker of another app version: `uid` names the earlier mains that its upload replaced.
    func markReplaces(_ replaced: Set<String>, by uid: PhotoUID) {
        lock.withLock {
            table[uid.nodeID]?.replacedLinkIDs.formUnion(replaced)
            record("lineage marker \(uid.nodeID) replaces \(replaced.sorted())")
        }
    }

    /// Assumption: emptying trash deletes related files as well as their trashed mains.
    func personEmptyTrash() {
        lock.withLock {
            let mains = Set(table.values.filter { $0.mainLinkID == nil && $0.state == .trashed }.map(\.linkID))
            for id in Array(table.keys) {
                if mains.contains(id) || table[id]?.mainLinkID.map(mains.contains) == true {
                    table[id]?.state = .deleted
                }
            }
            record("person empty trash")
        }
    }

    /// Seeds one link that another device uploaded, with its own asset.
    func seedLink(
        digest: Data, main: PhotoUID? = nil, captureTime: Date = Date(timeIntervalSince1970: 1_720_000_000)
    ) -> PhotoUID {
        lock.withLock {
            let uid = insertLink(digest: digest, main: main, captureTime: captureTime)
            record("other device upload \(uid.nodeID)")
            return uid
        }
    }

    /// Seeds one main photo for each digest with one recorded step, for a large library.
    @discardableResult
    func seedLinks(digests: [Data]) -> [PhotoUID] {
        lock.withLock {
            let uids = digests.map {
                insertLink(digest: $0, main: nil, captureTime: Date(timeIntervalSince1970: 1_720_000_000))
            }
            record("other device upload of \(uids.count) photos")
            return uids
        }
    }

    private func insertLink(digest: Data, main: PhotoUID?, captureTime: Date) -> PhotoUID {
        let id = String(format: "link-%04d", nextID)
        nextID += 1
        table[id] = Link(
            linkID: id, nameHash: "nh(\(id))", contentHash: Self.contentHash(digest), state: .active,
            mainLinkID: main?.nodeID, captureTime: captureTime, assetID: "asset-\(main?.nodeID ?? id)",
            generation: 0, isOriginal: false)
        return PhotoUID(volumeID: "vol", nodeID: id)
    }

    /// Seeds an earlier device's trashed copy from real uploaded content, without a local journal entry.
    func addHistoricalTrashedCopy(of uid: PhotoUID) throws {
        try lock.withLock {
            guard let original = table[uid.nodeID] else { throw UploadError.backend("Missing historical source") }
            let id = String(format: "link-%04d", nextID)
            nextID += 1
            table[id] = Link(
                linkID: id, nameHash: original.nameHash, contentHash: original.contentHash,
                state: .trashed, mainLinkID: nil, captureTime: original.captureTime,
                assetID: original.assetID, generation: 0, isOriginal: true)
            record("earlier device trashed \(id)")
        }
    }
}

extension EditScenarioServer: ExactDuplicateRemote {
    /// The person's trash: only main photos, and a related file never leaves without an active copy elsewhere.
    func trashDuplicates(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if failTrash {
                failTrash = false
                record("failed duplicate trash")
                throw UploadError.backend("The scenario trash write failed once")
            }
            var violations: [String] = []
            let targets = Set(uids.map(\.nodeID))
            for uid in uids {
                guard let target = table[uid.nodeID], target.state == .active else { continue }
                if target.mainLinkID != nil {
                    violations.append("The duplicate trash targeted related file \(target.linkID)")
                }
                for file in table.values where file.mainLinkID == target.linkID && file.state == .active {
                    let preserved = table.values.contains { copy in
                        guard copy.state == .active, copy.contentHash == file.contentHash,
                            let holderID = copy.mainLinkID, !targets.contains(holderID)
                        else { return false }
                        return table[holderID]?.state == .active && table[holderID]?.mainLinkID == nil
                    }
                    if !preserved {
                        violations.append("The duplicate trash lost related file \(file.linkID)")
                    }
                }
                table[uid.nodeID]?.state = .trashed
                table[uid.nodeID]?.personDeleted = true
            }
            record("duplicate trash \(uids.map(\.nodeID))", violations: violations)
            if let other = pendingTrashAfterDuplicateTrash {
                pendingTrashAfterDuplicateTrash = nil
                table[other]?.state = .trashed
                table[other]?.personDeleted = true
                record("other device trash \(other)")
            }
            armedVisibilityFailures = visibilityFailuresAfterTrash
            visibilityFailuresAfterTrash = 0
        }
    }

    func restoreDuplicates(_ uids: [PhotoUID]) async throws {
        for uid in uids { personRestore(uid) }
    }

    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] {
        lock.withLock {
            var dates: [PhotoUID: Date] = [:]
            for uid in uids { dates[uid] = table[uid.nodeID]?.captureTime }
            return dates
        }
    }

    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try lock.withLock {
            counted.sharingMembers += uids.count
            if uids.contains(where: { missingNodes.contains($0.nodeID) }) {
                throw UploadError.backend("The scenario node is missing")
            }
            return Dictionary(
                uniqueKeysWithValues: uids.map {
                    (
                        $0,
                        ExactDuplicateNodeFacts(
                            isShared: sharedLinks.contains($0.nodeID), byteSize: nodeSizes[$0.nodeID],
                            albums: (table[$0.nodeID]?.albums ?? []).sorted {
                                ($0.volumeID, $0.albumID) < ($1.volumeID, $1.albumID)
                            })
                    )
                })
        }
    }

    /// The node of the photo states this file size.
    func setNodeSize(_ size: Int64, of uid: PhotoUID) { lock.withLock { nodeSizes[uid.nodeID] = size } }

    /// The person shares the photo with other people or by a link.
    func share(_ uid: PhotoUID) { lock.withLock { _ = sharedLinks.insert(uid.nodeID) } }

    /// Every node read of the photo fails, as for a node that the SDK cannot return.
    func loseNode(_ uid: PhotoUID) { lock.withLock { _ = missingNodes.insert(uid.nodeID) } }

    /// Sets the cover of an own album, as the person does in Albums.
    func setAlbumCover(_ albumID: String, to uid: PhotoUID) { lock.withLock { covers[albumID] = uid.nodeID } }

    var albumCovers: [String: String] { lock.withLock { covers } }

    func ownAlbumCovers() async throws -> [String: String] {
        lock.withLock {
            counted.albumListings += 1
            return covers.filter { ownAlbumIDs.contains($0.key) }
        }
    }

    /// The next cover write fails.
    func failNextCoverWrite() { lock.withLock { failCoverWrite = true } }

    func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws {
        try lock.withLock {
            if failCoverWrite {
                failCoverWrite = false
                throw UploadError.backend("The scenario cover write failed")
            }
            guard ownAlbumIDs.contains(albumID),
                table[uid.nodeID]?.albums.contains(.init(volumeID: "vol", albumID: albumID)) == true
            else { throw UploadError.backend("The scenario cover is no member of the own album") }
            covers[albumID] = uid.nodeID
            record("cover \(albumID)")
        }
    }
}

/// Suspends one real pipeline upload before the fake transport commits it. No sleeps or scheduling races.
actor EditScenarioUploadGate {
    private var generation: Int?
    private var suspended = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func arm(generation: Int) { self.generation = generation }

    func suspendIfArmed(generation: Int, isMain: Bool) async {
        guard isMain, self.generation == generation else { return }
        self.generation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            suspended = true
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
        suspended = false
    }
}

/// The remote asset index of one device, as `ProtonUploadDedupeService` keeps it. A full build reads every active
/// compound. The refresh from events only removes the record of a compound whose link changed; it adds none
/// (`makeIndexRows` returns no asset records). Optional stale mode keeps lineage answers for 15 seconds.
/// Live visibility, compound contents, and modification metadata still come from the server.
final class EditScenarioDeviceIndex: UploadDuplicateChecking, @unchecked Sendable {
    private let server: EditScenarioServer
    private let lock = NSLock()
    private var proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]

    private let staleLineage: Bool
    private let now: @Sendable () -> Date
    private var lineageSnapshot: [EditScenarioServer.Link]
    private var lineageSnapshotAt: Date
    private var lineageInvalidated = false
    private var ownUploads: [String: Date] = [:]

    /// A device builds its index when it first opens the account.
    init(server: EditScenarioServer, staleLineage: Bool = false, now: @escaping @Sendable () -> Date = { Date() }) {
        self.server = server
        proofs = server.allRemoteAssetProofs()
        self.staleLineage = staleLineage
        self.now = now
        lineageSnapshot = server.links
        lineageSnapshotAt = now()
    }

    private func indexedLinks() -> [EditScenarioServer.Link] {
        lock.withLock {
            if lineageInvalidated || now().timeIntervalSince(lineageSnapshotAt) >= 15 {
                let pending = Set(ownUploads.filter { now().timeIntervalSince($0.value) < 15 }.keys)
                lineageSnapshot = server.links.filter { !pending.contains($0.linkID) }
                lineageSnapshotAt = now()
                lineageInvalidated = false
            }
            return lineageSnapshot
        }
    }

    func recordUploaded(contentHash: String, remoteLinkID: String) async {
        lock.withLock { ownUploads[remoteLinkID] = now() }
        await server.recordUploaded(contentHash: contentHash, remoteLinkID: remoteLinkID)
    }

    func invalidateCachedRemoteState() async {
        await server.invalidateCachedRemoteState()
        lock.withLock { lineageInvalidated = true }
    }

    func modificationDate(ofMainLink linkID: String) async throws -> Date? {
        try await server.modificationDate(ofMainLink: linkID)
    }

    func compound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        try await server.compound(ofMainLink: linkID)
    }

    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        server.noteProofLookup(identities)
        let indexed = lock.withLock { proofs }
        let links = indexed.values.flatMap(\.remoteLinkIDs)
        let visibility = try await server.linkVisibility(of: links)
        let stale = indexed.filter { !$0.value.remoteLinkIDs.allSatisfy { visibility[$0]?.isActive == true } }.keys
        lock.withLock { for identity in stale { proofs[identity] = nil } }
        return lock.withLock { proofs.filter { identities.contains($0.key) } }
    }

    func nameHash(forCorrectedName name: String) async throws -> String {
        try await server.nameHash(forCorrectedName: name)
    }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        try await server.contentHash(forSHA1Hex: sha1Hex)
    }
    func hashKeyEpoch() async throws -> String { try await server.hashKeyEpoch() }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        try await server.findDuplicates(nameHashes: nameHashes)
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        try await server.findDuplicate(contentHash: contentHash)
    }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        try await server.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
    }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        try await server.linkVisibility(of: linkIDs)
    }
    func activeMainLinkIDs(
        forExternalIdentifier identifier: String
    ) async throws -> (links: Set<String>, complete: Bool) {
        guard staleLineage else { return try await server.activeMainLinkIDs(forExternalIdentifier: identifier) }
        return (
            Set(
                indexedLinks().filter {
                    $0.state == .active && $0.mainLinkID == nil && $0.externalIdentifier == identifier
                }.map(\.linkID)), true
        )
    }
    func replacingMainLinkIDs(ofReplacedLink linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        guard staleLineage else { return try await server.replacingMainLinkIDs(ofReplacedLink: linkID) }
        return (
            Set(
                indexedLinks().filter {
                    $0.state == .active && $0.mainLinkID == nil && $0.replacedLinkIDs.contains(linkID)
                }.map(\.linkID)), true
        )
    }
    func externalIdentifier(ofMainLink linkID: String) async throws -> (identifier: String?, complete: Bool) {
        guard staleLineage else { return try await server.externalIdentifier(ofMainLink: linkID) }
        let main = indexedLinks().first { $0.linkID == linkID && $0.state == .active && $0.mainLinkID == nil }
        return (main?.externalIdentifier, true)
    }
    func replacedLinkIDs(ofReplacingMain linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        guard staleLineage else { return try await server.replacedLinkIDs(ofReplacingMain: linkID) }
        let main = indexedLinks().first { $0.linkID == linkID && $0.state == .active && $0.mainLinkID == nil }
        return (main?.replacedLinkIDs ?? [], true)
    }
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        try await server.remoteContentIndexHealth()
    }
}

/// The uploads and backup trash of one device. U6: the backup never trashes a head that this device did not upload.
/// One exception holds: this device uploaded a later version of the same asset. A device adopts the upload of
/// another device and replaces it with its own edit, and the proven remote path replaces another device's older
/// edit; both trash only a head with an earlier ModificationTime than the active upload of this device.
final class EditScenarioDeviceRemote: PhotoUploading, EditReplacementRemote, @unchecked Sendable {
    private let server: EditScenarioServer
    private let lock = NSLock()
    private var ownUploads: Set<String> = []
    private var recordedViolations: [String] = []

    init(server: EditScenarioServer) { self.server = server }

    var capabilities: UploadBackendCapabilities { server.capabilities }
    var violations: [String] { lock.withLock { recordedViolations } }

    /// A link that this device seeded as an earlier app version counts as its own upload.
    func recordOwnUpload(_ uid: PhotoUID) {
        lock.withLock { _ = ownUploads.insert(uid.nodeID) }
    }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let uid = try await server.upload(request, onProgress: onProgress)
        recordOwnUpload(uid)
        return uid
    }

    func cancel(token: UUID) async { await server.cancel(token: token) }
    func pause(token: UUID) async throws { try await server.pause(token: token) }
    func resume(token: UUID) async throws { try await server.resume(token: token) }
    func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {
        try await server.ensureRemoteCapacity(forBytes: bytes, filename: filename)
    }

    func ownPhotosVolumeID() async throws -> String { try await server.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        try await server.activeUIDs(among: uids)
    }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        try await server.favoriteUIDs(among: uids)
    }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await server.markFavorite(uids) }

    func trashReplaced(_ uids: [PhotoUID]) async throws {
        let links = server.links
        lock.withLock {
            for uid in uids {
                guard let target = links.first(where: { $0.linkID == uid.nodeID }), target.state == .active,
                    !ownUploads.contains(target.linkID)
                else { continue }
                let laterOwnUpload = links.contains { own in
                    ownUploads.contains(own.linkID) && own.state == .active && own.mainLinkID == nil
                        && own.assetID == target.assetID
                        && (own.modificationDate ?? .distantPast) > (target.modificationDate ?? .distantFuture)
                }
                if !laterOwnUpload {
                    recordedViolations.append(
                        "U6 backup trashed \(target.linkID), which this device did not upload and which is not older "
                            + "than its own upload")
                }
            }
        }
        try await server.trashReplaced(uids)
    }
}
