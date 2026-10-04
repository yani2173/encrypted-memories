import AlbumCore
import AlbumSyncCore
import Foundation
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import UIKit
import UploadCore

#if DEBUG
    /// A deterministic, offline account for hosted tests and UI tests. Debug builds only.
    ///
    /// It replaces only the account backend and its content inside the process-wide `MobileAccountRuntime`. Every
    /// production layer above it (scene roots, tab shell, timeline screens, grids, selection, search, viewer) renders
    /// unchanged. No real account, keychain entry, network request, or physical device is involved.
    @MainActor final class MobileSignedInFixture {
        static let sectionNames = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
        nonisolated static let videoNodeID = "zeta-video"

        let session = ProtonSession(
            uid: "fixture-account", accessToken: "fixture-access", refreshToken: "fixture-refresh",
            keyPassword: "fixture-key")
        let sections: [TimelineSection]
        let backend: MobileFixtureBackend
        let cache: ThumbnailCache
        let feed: UIKitThumbnailFeed
        var items: [PhotoItem] { sections.flatMap(\.items) }

        private let runtime: MobileAccountRuntime
        private let cacheDirectory: URL
        private var backupFixture: PhotoLibraryBackupController?
        private var albumSyncFixture: AlbumSyncController?

        /// `includesVideo` adds one video as the newest item; the UI tests use it, the hosted tests count photos only.
        init(
            runtime: MobileAccountRuntime = .shared, itemsPerSection: Int = 36, includesVideo: Bool = false
        ) async throws {
            guard !BackupLocalDataPurge.isPurgePending() else { throw MobileFixtureError.pendingAccountPurge }
            self.runtime = runtime
            cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "signed-in-fixture-" + UUID().uuidString)
            var sections: [TimelineSection] = []
            var thumbnails: [PhotoUID: Data] = [:]
            let calendar = Calendar(identifier: .gregorian)
            for (sectionIndex, name) in Self.sectionNames.enumerated() {
                let sectionDate = calendar.date(from: DateComponents(year: 2026, month: sectionIndex + 1, day: 12))!
                var items: [PhotoItem] = []
                for index in 0..<itemsPerSection {
                    let uid = PhotoUID(volumeID: "fixture", nodeID: "\(name)-\(index)")
                    let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                        UIColor(
                            hue: CGFloat(sectionIndex) / CGFloat(Self.sectionNames.count), saturation: 0.55,
                            brightness: 0.45 + 0.5 * CGFloat(index % 6) / 6, alpha: 1
                        ).setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
                    }
                    guard let data = bitmap.jpegData(compressionQuality: 0.8) else { throw MobileFixtureError.bitmap }
                    thumbnails[uid] = data
                    items.append(
                        PhotoItem(
                            uid: uid, captureTime: sectionDate.addingTimeInterval(TimeInterval(index) * 60),
                            mediaType: "image/jpeg"))
                }
                if includesVideo, sectionIndex == Self.sectionNames.count - 1 {
                    // The newest item is one video whose stream is unavailable, like a video that an offline
                    // account cannot play.
                    let uid = PhotoUID(volumeID: "fixture", nodeID: Self.videoNodeID)
                    thumbnails[uid] = thumbnails[items[0].uid]
                    items.append(
                        PhotoItem(
                            uid: uid, captureTime: sectionDate.addingTimeInterval(TimeInterval(itemsPerSection) * 60),
                            mediaType: "video/quicktime", durationSeconds: 3))
                }
                sections.append(
                    TimelineSection(id: "fixture-\(name)", date: sectionDate, title: "Fixture \(name)", items: items))
            }
            self.sections = sections
            backend = MobileFixtureBackend(sections: sections, thumbnails: thumbnails)
            cache = ThumbnailCache(rootDirectory: cacheDirectory)
            feed = UIKitThumbnailFeed(cache: cache, loader: backend)
            for (uid, data) in thumbnails {
                await cache.store(data, for: uid)
            }
            _ = await feed.warmDecoded(thumbnails.keys.map { $0 })
        }

        /// Signs the shared account runtime in with this fixture. Library content first, then the session, so the
        /// runtime's session observer finds an already configured account and does not start a network backend.
        func install() {
            let albums = MobileFixtureAlbums()
            runtime.libraryModel.installIsolatedLibrary(
                session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
                thumbnailFeed: feed,
                albums: AlbumsRepository(
                    catalogBackend: albums, writeBackend: albums, capabilities: MobileFixtureAlbums.capabilities))
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDeletedBackupFixture") {
                installDeletedBackupFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesFailedBackupFixture") {
                installDeletedBackupFixture(failedItems: true)
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesBackupQueueFixture") {
                installDeletedBackupFixture(queue: true)
            }
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesAlbumSyncReasonsFixture") {
                installAlbumSyncReasonsFixture()
            }
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDuplicatesFixture") {
                runtime.libraryModel.installIsolatedDuplicatesForTesting(
                    MobileFixtureDuplicates(groups: sections.prefix(2).map { $0.items.prefix(2).map(\.uid) }))
            }
            runtime.sessionModel.installIsolatedSession(session)
        }

        static let albumSyncFixtureAlbumID = "fixture-album-sync"

        /// One synced album whose last run left two photos outside the Proton album.
        private func installAlbumSyncReasonsFixture() {
            let directory = cacheDirectory.appendingPathComponent("albumsync", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let controller = AlbumSyncController(
                    configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative),
                    identityResolver: MobileFixtureBackupBackend(), uploader: MobileFixtureBackupBackend(),
                    remoteOps: MobileFixtureAlbumSyncRemoteOps())
                guard
                    controller.installNotInAlbumFixtureForTesting(
                        albumID: Self.albumSyncFixtureAlbumID, title: "Fixture Album Sync")
                else { return }
                albumSyncFixture = controller
                runtime.libraryModel.installIsolatedAlbumSyncForTesting(controller)
            } catch {
                assertionFailure("The album sync fixture could not be installed")
            }
        }

        private func installDeletedBackupFixture(failedItems: Bool = false, queue: Bool = false) {
            let directory = cacheDirectory.appendingPathComponent("backup", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let journal = EditReplacementJournalFileStore.shared(accountDataDirectory: directory),
                    let defaults = UserDefaults(suiteName: "deleted-backup-fixture")
                else { return }
                defaults.removePersistentDomain(forName: "deleted-backup-fixture")
                let controller = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                    identityResolver: MobileFixtureBackupBackend(), uploader: MobileFixtureBackupBackend(),
                    replacementJournal: journal)
                let installed: Bool
                if queue {
                    installed = controller.installQueueFixtureForTesting()
                } else if failedItems {
                    let arguments = ProcessInfo.processInfo.arguments
                    let kinds: [BackupIssueKind]
                    if arguments.contains("-EncryptedMemoriesNetworkOnlyBackupFixture") {
                        kinds = [.network]
                    } else if arguments.contains("-EncryptedMemoriesAccountStorageOnlyBackupFixture") {
                        kinds = [.accountStorage]
                    } else if arguments.contains("-EncryptedMemoriesNoUserResolvableBackupFixture") {
                        kinds = [.network, .deletedElsewhere, .unsupported]
                    } else {
                        kinds = [.network, .accountStorage, .deletedElsewhere, .unsupported]
                    }
                    installed = controller.installFailedItemsFixtureForTesting(kinds: kinds)
                } else {
                    installed = controller.installDeletedElsewhereFixtureForTesting()
                }
                guard installed else { return }
                backupFixture = controller
                runtime.libraryModel.installIsolatedBackupForTesting(controller)
            } catch {
                assertionFailure("The deleted backup fixture could not be installed")
            }
        }

        /// Installs only the library content into an isolated model (no session, no shared runtime): for probes that
        /// host one production screen in a test window.
        func install(into model: MobileLibraryModel) {
            model.installIsolatedLibrary(
                session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
                thumbnailFeed: feed, thumbnailCache: cache)
        }

        func install(
            into model: MobileLibraryModel,
            backend: any PhotosBackend,
            sections: [TimelineSection],
            thumbnailFeed: UIKitThumbnailFeed,
            thumbnailCache: ThumbnailCache
        ) {
            model.installIsolatedLibrary(
                session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
                thumbnailFeed: thumbnailFeed, thumbnailCache: thumbnailCache)
        }

        /// Clears fixture state through the session observer without requesting another persistent-data purge.
        func clearSession() {
            runtime.sessionModel.installIsolatedSession(nil)
        }

        func removeCache() {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private struct MobileFixtureBackupBackend: PhotoUploading, UploadIdentityResolving {
        let capabilities = UploadBackendCapabilities(
            canUpload: true, supportsCancel: true,
            supportsPauseResume: false, supportsResumeAcrossRelaunch: false)

        func upload(
            _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID { throw MobileFixtureError.unavailable }
        func cancel(token: UUID) async {}
        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw MobileFixtureError.unavailable
        }
        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity,
            remoteVolumeID: String, remoteLinkID: String
        ) async throws { throw MobileFixtureError.unavailable }
    }

    /// Remote album operations of an offline account: every call fails.
    private struct MobileFixtureAlbumSyncRemoteOps: AlbumSyncRemoteAlbumOps {
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { throw MobileFixtureError.unavailable }
        func createAlbum(name: String) async throws -> String { throw MobileFixtureError.unavailable }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { throw MobileFixtureError.unavailable }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            throw MobileFixtureError.unavailable
        }
    }

    /// Groups of exact copies in memory. A merge keeps the chosen photo and moves the other copies to Trash.
    final class MobileFixtureDuplicates: ExactDuplicateMerging, @unchecked Sendable {
        private let lock = NSLock()
        private var groups: [ExactDuplicateGroup]

        init(groups members: [[PhotoUID]]) {
            groups = members.enumerated().map { index, members in
                ExactDuplicateGroup(contentHash: "fixture-copies-\(index)", hashKeyEpoch: "fixture", members: members)
            }
        }

        func duplicateGroups() async throws -> ExactDuplicateScan {
            ExactDuplicateScan(groups: lock.withLock { groups }, coverage: .complete)
        }

        func rankedMembers(of groups: [ExactDuplicateGroup]) async throws -> [String: [PhotoUID]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        }

        func merge(
            _ requests: [(group: ExactDuplicateGroup, kept: PhotoUID)]
        ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            lock.withLock { groups.removeAll { group in requests.contains { $0.group.id == group.id } } }
            return requests.map { group, kept in
                .success(.merged(kept: kept, trashed: group.members.filter { $0 != kept }, keptDuplicates: [:]))
            }
        }
    }

    enum MobileFixtureError: Error {
        case bitmap
        case unavailable
        case pendingAccountPurge
    }

    /// One owned album in memory, so the UI tests can add photos to an album without an account.
    final class MobileFixtureAlbums: AlbumCatalogBackend, AlbumWriteBackend, @unchecked Sendable {
        static let albumTitle = "Fixture Album"
        static let capabilities = AlbumCapabilities(
            canList: true, canCreate: false, canAddPhotos: true, canSetCover: false, canReadMemberships: true)

        private let lock = NSLock()
        private var members: [PhotoUID] = []

        func listAlbums() async throws -> [AlbumSummary] {
            let count = lock.withLock { members.count }
            return [AlbumSummary(id: "fixture-album", title: Self.albumTitle, photoCount: count, coverPhotoID: nil)]
        }
        func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
        func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
        func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
            let members = lock.withLock { Set(self.members) }
            return Dictionary(
                uniqueKeysWithValues: photoUIDs.map { uid in
                    let album = AlbumNodeIdentifier(volumeID: uid.volumeID, nodeID: "fixture-album")
                    return (uid, members.contains(uid) ? [album] : [])
                })
        }
        func createAlbum(name: String) async throws -> AlbumID { throw MobileFixtureError.unavailable }
        func deleteAlbum(albumID: AlbumID) async throws { throw MobileFixtureError.unavailable }
        func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
            lock.withLock { members += photoUIDs.filter { !members.contains($0) } }
        }
        func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
            throw MobileFixtureError.unavailable
        }
        func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws { throw MobileFixtureError.unavailable }
    }

    /// Every provider of the account backend, answered from memory. Media beyond thumbnails is unavailable, which
    /// the production viewer handles like an offline account.
    struct MobileFixtureBackend: PhotosBackend {
        let sections: [TimelineSection]
        let thumbnails: [PhotoUID: Data]
        var favoriteLoader: (@Sendable () async throws -> Set<PhotoUID>)? = nil
        var favoriteWriter: (@Sendable ([PhotoUID], Bool) async throws -> Void)? = nil

        func loadTimeline() async throws -> [TimelineSection] { sections }
        func timeline(filter: PhotoFilter) async throws -> [TimelineSection] { sections }

        func thumbnail(for uid: PhotoUID) async throws -> Data {
            guard let data = thumbnails[uid] else { throw MobileFixtureError.unavailable }
            return data
        }

        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            var missing: [PhotoUID: String] = [:]
            for uid in uids {
                if let data = thumbnails[uid] {
                    onLoaded(uid, data)
                } else {
                    missing[uid] = "fixture has no thumbnail"
                }
            }
            return ThumbnailBatchLoadResult(itemErrors: missing)
        }

        func preview(for uid: PhotoUID) async throws -> Data { try await thumbnail(for: uid) }
        func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            throw MobileFixtureError.unavailable
        }
        func streamOriginalBytes(
            for uid: PhotoUID, onChunk: @escaping @Sendable (Data) async throws -> Void,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            throw MobileFixtureError.unavailable
        }
        func writeOriginal(
            for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
        )
            async throws
        {
            throw MobileFixtureError.unavailable
        }
        func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
            throw MobileFixtureError.unavailable
        }
        func prefetchEncrypted(for uid: PhotoUID) async throws {}
        func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
            guard uid.nodeID == MobileSignedInFixture.videoNodeID else {
                return PhotoMetadata(
                    filename: "\(uid.nodeID).jpg", mimeType: "image/jpeg", pixelWidth: 160, pixelHeight: 160)
            }
            return PhotoMetadata(
                filename: "\(uid.nodeID).mov", mimeType: "video/quicktime", pixelWidth: 160, pixelHeight: 160)
        }
        func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { [] }
        func favoriteUIDs() async throws -> Set<PhotoUID> {
            try await favoriteLoader?() ?? []
        }
        func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws {
            try await favoriteWriter?(uids, favorite)
        }
        func saveToLibrary(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult {
            PhotoLibrarySaveResult(saved: Set(uids), failed: [])
        }
        func trash(_ uids: [PhotoUID]) async throws {}
        func restore(_ uids: [PhotoUID]) async throws {}
        func emptyTrash() async throws {}
        func metadataRowCount() async -> Int { sections.reduce(0) { $0 + $1.items.count } }
        func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {}
    }
#endif
