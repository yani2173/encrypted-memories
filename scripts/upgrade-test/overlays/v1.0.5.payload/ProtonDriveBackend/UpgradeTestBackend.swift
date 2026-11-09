#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import AlbumCore
    import AlbumSyncCore
    import CryptoKit
    import Foundation
    import PhotosCore
    import UploadCore

    /// One loopback server owns uploads and duplicate proof across both app installations.
    struct UpgradeTestBackend: PhotosBackend, PhotoUploading, PhotoTagAdding, UploadDuplicateChecking,
        AlbumCatalogBackend, AlbumWriteBackend, LibrarySourceRemoteBackend
    {
        let capabilities = UploadBackendCapabilities.sdkUploader

        func loadTimeline() async throws -> [TimelineSection] {
            let items = UpgradeTestProbe.assets.map {
                PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 1_720_100_000), mediaType: "image/png")
            }
            return [
                TimelineSection(id: "synthetic", date: items[0].captureTime, title: "Synthetic photos", items: items)
            ]
        }
        func timeline(filter: PhotoFilter) async throws -> [TimelineSection] { try await loadTimeline() }
        func thumbnail(for uid: PhotoUID) async throws -> Data {
            UpgradeTestProbe.checkpoint("thumbnail.beforeLoad")
            let data = try await UpgradeTestProbe.request("thumbnail/\(uid.nodeID)")
            UpgradeTestProbe.checkpoint("thumbnail.afterLoad")
            return data
        }
        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            var errors: [PhotoUID: String] = [:]
            for uid in uids {
                do { onLoaded(uid, try await thumbnail(for: uid)) } catch { errors[uid] = "Synthetic thumbnail failed" }
            }
            return ThumbnailBatchLoadResult(itemErrors: errors)
        }
        func preview(for uid: PhotoUID) async throws -> Data { try await thumbnail(for: uid) }
        func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            try await thumbnail(for: uid)
        }
        func streamOriginalBytes(
            for uid: PhotoUID, onChunk: @escaping @Sendable (Data) async throws -> Void,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws { try await onChunk(thumbnail(for: uid)) }
        func writeOriginal(
            for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
        ) async throws { try await thumbnail(for: uid).write(to: destination, options: .atomic) }
        func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
            throw URLError(.unsupportedURL)
        }
        func prefetchEncrypted(for uid: PhotoUID) async throws {}
        func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
            PhotoMetadata(filename: "\(uid.nodeID).png", mimeType: "image/png", pixelWidth: 32, pixelHeight: 32)
        }
        func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { [] }
        func favoriteUIDs() async throws -> Set<PhotoUID> { [] }
        func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws { throw URLError(.unsupportedURL) }
        func saveToLibrary(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult {
            throw URLError(.unsupportedURL)
        }
        func trash(_ uids: [PhotoUID]) async throws { throw URLError(.unsupportedURL) }
        func restore(_ uids: [PhotoUID]) async throws { throw URLError(.unsupportedURL) }
        func emptyTrash() async throws { throw URLError(.unsupportedURL) }
        func metadataRowCount() async -> Int { 8 }
        func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {}
        func addTags(_ tags: [Int], to uid: PhotoUID) async throws {}

        struct Link: Codable {
            let id: String
            let name: String
            let hash: String
        }
        func links() async throws -> [Link] {
            try JSONDecoder().decode([Link].self, from: await UpgradeTestProbe.request("links"))
        }
        func duplicate(_ link: Link) -> RemotePhotoDuplicate {
            RemotePhotoDuplicate(nameHash: link.name, contentHash: link.hash, linkState: .active, linkID: link.id)
        }
        func nameHash(forCorrectedName name: String) async throws -> String { name }
        func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { sha1Hex }
        func hashKeyEpoch() async throws -> String { "synthetic-epoch" }
        func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
            try await links().filter { nameHashes.contains($0.name) }.map(duplicate)
        }
        func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
            try await links().first { $0.hash == contentHash }.map(duplicate)
        }
        func findDuplicates(contentHash: String, limit: Int) async throws -> [RemotePhotoDuplicate] {
            try await links().filter { $0.hash == contentHash }.prefix(limit).map(duplicate)
        }
        func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }
        func upload(
            _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID {
            let bytes = try Data(contentsOf: request.fileURL)
            let hash = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let payload = try JSONSerialization.data(withJSONObject: ["name": request.name, "hash": hash])
            let link = try JSONDecoder().decode(
                Link.self, from: await UpgradeTestProbe.request("upload", body: payload))
            UpgradeTestProbe.checkpoint("backup.remoteReceipt")
            return PhotoUID(volumeID: "upgrade-fixture", nodeID: link.id)
        }
        func cancel(token: UUID) async {}
        func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { [] }
        func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }
        func listAlbums() async throws -> [AlbumSummary] { [] }
        func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
        func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws { throw URLError(.unsupportedURL) }
        func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] { [:] }
        func createAlbum(name: String) async throws -> AlbumID { throw URLError(.unsupportedURL) }
        func deleteAlbum(albumID: AlbumID) async throws { throw URLError(.unsupportedURL) }
        func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws { throw URLError(.unsupportedURL) }
        func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
            throw URLError(.unsupportedURL)
        }
        func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws { throw URLError(.unsupportedURL) }
    }

    struct UpgradeTestAlbumSync: AlbumSyncRemoteAlbumOps {
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
        func createAlbum(name: String) async throws -> String { throw URLError(.unsupportedURL) }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            throw URLError(.unsupportedURL)
        }
    }
#endif
