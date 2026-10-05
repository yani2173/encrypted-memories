import AlbumCore
import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore

struct UploadIdentityResolverComposition: Sendable {
    let resolver: any UploadIdentityResolving
    /// The Proton-keyed duplicate service behind `resolver`. Nil when the upload manifest is unavailable.
    let duplicateChecker: (any UploadDuplicateChecking)?
    /// The upload manifest behind `resolver`. Nil when it is unavailable.
    let identityStore: (any UploadIdentityStore)?
    /// The content index in the upload manifest. Nil when the manifest is unavailable.
    let contentIndex: (any UploadRemoteContentIndexStore)?
    /// Earlier uploads of edited photos that the backup replaces. Nil when the upload manifest or the journal is
    /// unavailable.
    let replacementJournal: (any EditReplacementJournaling)?
    let close: @Sendable () -> Void
}

/// High-level, app-facing composition of the Proton clients. Built once the SDK bridge is ready and
/// owned by `AppModel`. The UI binds to the feature objects here (uploads, albums) - never to the SDK.
///
/// This is the single seam where the concrete `DriveSDKBridge` (SDK/HTTP) is wired into the pure
/// feature modules, so features can be added/removed without touching the rest of the app.
@MainActor
public final class ProtonClientFacade {
    /// Existing timeline/thumbnail/download/etc. surface (unchanged).
    public let backend: any PhotosBackend
    /// Neutral multi-source inventory and source-fenced thumbnail route for derived-data consumers.
    public let librarySources: LibrarySourceCoordinator
    /// Album listing and writes through the shared AlbumCore facade.
    public let albums: AlbumsRepository
    /// Upload queue/state-machine.
    public let uploads: UploadManager
    /// Main-actor observable the upload UI binds to.
    public let uploadCoordinator: UploadCoordinator
    /// The raw upload transport (the SDK bridge) for the backup sync runner - shares the exact
    /// upload semantics with the manual queue.
    public let photoUploader: any PhotoUploading
    /// Marks a main photo as a series when backup adds the members that an earlier build left out.
    public let photoTagAdder: any PhotoTagAdding
    /// "Keep Only Favorites" for a series of the account's own library. Nil while uploads are disabled.
    public let seriesDissolution: SeriesDissolutionOrchestrator?
    /// Replaces the earlier upload of a photo that was edited in the photo library. Nil while uploads are disabled.
    public let editedPhotoReplacement: EditedPhotoReplacement?
    /// Finds and merges exact duplicates of the own library. Nil while uploads are disabled.
    public let exactDuplicates: ExactDuplicateFinder?
    /// The single dedupe resolver for this account, shared by manual uploads and backup sync so both
    /// see the same manifest and remote duplicate view. If the manifest database cannot open,
    /// the bridge supplies a fail-closed resolver; uploads must never silently run without dedupe.
    public let uploadIdentityResolver: (any UploadIdentityResolving)?
    /// Per-account data directory (holds `library-v1.sqlite` + upload manifests). Backup sync
    /// stores live here too, so the sign-out purge covers them wholesale.
    public let accountDataDirectory: URL
    /// SQLite tuning for account-scoped stores opened by feature composition.
    public let accountDatabasePolicy: LibraryDatabasePolicy
    /// Remote album operations for the universal album sync engine (create / children / attach) -
    /// backed by the album write service behind the shared transport-independent contract.
    public let albumSyncRemoteOps: any AlbumSyncRemoteAlbumOps
    private let accountInfoRefresher: @Sendable () async throws -> Void
    private let shutdownHandler: @Sendable () async -> Void
    private let shutdownGate = JoinedShutdownGate()
    private var didShutDown = false

    private init(
        backend: any PhotosBackend,
        librarySources: LibrarySourceCoordinator,
        albums: AlbumsRepository,
        uploads: UploadManager,
        uploadCoordinator: UploadCoordinator,
        photoUploader: any PhotoUploading,
        photoTagAdder: any PhotoTagAdding,
        seriesDissolution: SeriesDissolutionOrchestrator?,
        editedPhotoReplacement: EditedPhotoReplacement?,
        exactDuplicates: ExactDuplicateFinder?,
        uploadIdentityResolver: (any UploadIdentityResolving)?,
        accountDataDirectory: URL,
        accountDatabasePolicy: LibraryDatabasePolicy,
        albumSyncRemoteOps: any AlbumSyncRemoteAlbumOps,
        accountInfoRefresher: @Sendable @escaping () async throws -> Void,
        shutdownHandler: @Sendable @escaping () async -> Void
    ) {
        self.backend = backend
        self.librarySources = librarySources
        self.albums = albums
        self.uploads = uploads
        self.uploadCoordinator = uploadCoordinator
        self.photoUploader = photoUploader
        self.photoTagAdder = photoTagAdder
        self.seriesDissolution = seriesDissolution
        self.editedPhotoReplacement = editedPhotoReplacement
        self.exactDuplicates = exactDuplicates
        self.uploadIdentityResolver = uploadIdentityResolver
        self.accountDataDirectory = accountDataDirectory
        self.accountDatabasePolicy = accountDatabasePolicy
        self.albumSyncRemoteOps = albumSyncRemoteOps
        self.accountInfoRefresher = accountInfoRefresher
        self.shutdownHandler = shutdownHandler
    }

    static func make(
        bridge: DriveSDKBridge,
        librarySources: LibrarySourceCoordinator,
        identityComposition: UploadIdentityResolverComposition,
        settlementStore: UploadManualSettlementStore?
    ) -> ProtonClientFacade {
        // Albums: SDK 0.29.1 is the sole catalog/sharing/membership reader. Direct Photos HTTP is
        // retained only for writes the SDK does not expose.
        // Recently Deleted lists photos that left every inventory. The coordinator authorizes their
        // thumbnails from that listing; a weak reference keeps the bridge from retaining the coordinator.
        bridge.setIdentitiesOutsideInventoryObserver { [weak librarySources] uids, sequence in
            await librarySources?.setIdentitiesOutsideInventory(uids, sequence: sequence)
        }
        let albumWrite = bridge.makeAlbumWriteService()
        let albumCatalog = bridge.makeAlbumCatalogBackend()
        let albumWrites = HTTPAlbumWriteBackend(
            setCoverProvider: { albumID, photoUID in
                try await bridge.setAlbumCover(albumID: albumID, photoUID: photoUID)
            },
            createProvider: { name in try await albumWrite.createAlbum(name: name) },
            deleteProvider: { albumID in try await bridge.deleteAlbum(albumID: albumID) },
            addProvider: { photoUIDs, albumID in
                let result = try await albumWrite.attach(
                    photoUIDs.map { AlbumAttachRequestItem(uid: $0) }, albumID: albumID
                )
                if result.failedCount > 0 {
                    DebugLog.log(
                        "[AlbumWrite] membership incomplete selected=\(photoUIDs.count) "
                            + "ok=\(result.attachedCount + result.alreadyMemberCount) failed=\(result.failedCount) "
                            + "reason=\(result.firstFailureMessage ?? "unknown")"
                    )
                    throw AlbumError.partialAdd(
                        succeeded: result.attachedCount + result.alreadyMemberCount,
                        total: photoUIDs.count,
                        message: result.firstFailureMessage ?? "add to album failed"
                    )
                }
            },
            removeProvider: { photoUIDs, albumID in
                try await bridge.removePhotos(photoUIDs, fromAlbum: albumID)
            }
        )
        let albumsRepo = AlbumsRepository(
            catalogBackend: albumCatalog,
            writeBackend: albumWrites,
            didLeaveSharedAlbum: { album in
                await librarySources.revokeAdditionalSource(for: album)
            }
        )

        // Uploads: pure manager over the SDK uploader (the bridge) + the album-attaching shim +
        // the universal dedupe pipeline (hash, duplicate check, then skip or upload), so every upload
        // path shares one duplicate semantic.
        let attaching = AlbumAttachingAdapter(albums: albumsRepo)
        // One pipeline instance serves the whole account: manual uploads and backup sync must share
        // the manifest and the cached remote duplicate view, or their skip decisions could drift.
        let identityResolver = identityComposition.resolver
        let manager = UploadManager(
            uploader: bridge,
            albums: attaching,
            identityResolver: identityResolver,
            settlementStore: settlementStore,
            requiresDurableSettlement: true,
            maxConcurrent: 3
        )

        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: bridge.capabilities,
            canCreateAlbum: albumsRepo.capabilities.canCreate,
            canAddToAlbum: albumsRepo.capabilities.canAddPhotos,
            canSetAlbumCover: albumsRepo.capabilities.canSetCover
        )

        return ProtonClientFacade(
            backend: bridge,
            librarySources: librarySources,
            albums: albumsRepo,
            uploads: manager,
            uploadCoordinator: coordinator,
            photoUploader: bridge,
            photoTagAdder: bridge,
            seriesDissolution: bridge.makeSeriesDissolution(
                duplicateChecker: identityComposition.duplicateChecker,
                albums: AlbumRepositorySeriesCarryOver(repository: albumsRepo)
            ),
            editedPhotoReplacement: {
                guard let checker = identityComposition.duplicateChecker,
                    let identities = identityComposition.identityStore,
                    let journal = identityComposition.replacementJournal
                else { return nil }
                return EditedPhotoReplacement(
                    remote: bridge,
                    albums: AlbumRepositorySeriesCarryOver(repository: albumsRepo),
                    relations: checker,
                    identities: identities,
                    journal: journal
                )
            }(),
            exactDuplicates: {
                guard let checker = identityComposition.duplicateChecker,
                    let index = identityComposition.contentIndex,
                    let identities = identityComposition.identityStore,
                    let journal = identityComposition.replacementJournal
                else { return nil }
                return ExactDuplicateFinder(
                    checker: checker,
                    resolver: identityResolver,
                    index: index,
                    identities: identities,
                    journal: journal,
                    remote: bridge,
                    albums: AlbumRepositorySeriesCarryOver(repository: albumsRepo),
                    log: { DebugLog.log($0) }
                )
            }(),
            uploadIdentityResolver: identityResolver,
            accountDataDirectory: bridge.uploadManifestURL.deletingLastPathComponent(),
            accountDatabasePolicy: bridge.uploadManifestPolicy,
            albumSyncRemoteOps: ProtonAlbumSyncRemoteOps(
                service: albumWrite,
                listProvider: { try await albumsRepo.listAlbums() }
            ),
            accountInfoRefresher: { try await bridge.refreshAccountInfo() },
            shutdownHandler: {
                await librarySources.shutdown()
                await manager.shutdown()
                // Bridge shutdown closes shared admission and joins backend, album, sync, upload,
                // and identity work before any account-scoped resolver store is closed.
                await bridge.shutdown()
                identityComposition.close()
            }
        )
    }

    /// Pulls a fresh Drive quota/account snapshot for visible settings and foreground lifecycle refreshes.
    public func refreshAccountInfo() async throws {
        guard !didShutDown else { throw CancellationError() }
        try await accountInfoRefresher()
    }

    /// Closes account-owned stores before platform composition removes the account directory.
    public func shutdown() async {
        didShutDown = true
        let handler = shutdownHandler
        await shutdownGate.run { await handler() }
    }
}
