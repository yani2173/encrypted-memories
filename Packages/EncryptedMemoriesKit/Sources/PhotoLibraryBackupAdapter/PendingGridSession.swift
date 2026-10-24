import CoreGraphics
import Foundation
import MediaDecodingCore
import MediaFeedCore
import Observation
import PhotosCore
import TimelineCore
import UploadCore
import os

/// One account's pending grid, shared by iOS, iPadOS and macOS: the pending store, the coordinator that
/// follows the backup queue, and the presenter that merges pending photos into the timeline.
///
/// Hosts create the store first and hand it to `PhotoLibraryBackupController`, then build this session. They
/// attach their thumbnail feed, feed the session the canonical Proton timeline, show `presenter.current` in
/// the grid and viewer, and forward deletes, restores, favorites and album adds of local photos.
@MainActor
public final class PendingGridSession {
    public let presenter: PendingTimelinePresenter
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "PendingGrid")
    /// The latest coordinator snapshot, including the trash and excluded lists.
    public private(set) var pendingSnapshot = PendingBackupSnapshot.empty
    /// Called after `pendingSnapshot` changed.
    public var onPendingChange: ((PendingBackupSnapshot) -> Void)?
    /// Local photos in "Zuletzt gelöscht" while pending photos show; empty otherwise.
    public private(set) var trash = PendingTrashPresentation.empty
    /// Excluded photos for the Backup settings list, newest deletion first; empty while pending photos do
    /// not show.
    public private(set) var excludedTiles: [PendingTile] = []
    /// Called after `trash` or `excludedTiles` changed.
    public var onListsChange: (() -> Void)?
    private var gridLocalUIDs = Set<PhotoUID>()
    /// The local photos the feed may load: the grid, "Zuletzt gelöscht" and the excluded list.
    private var authorizedLocalUIDs = Set<PhotoUID>()
    private var feed: ThumbnailFeedCore?
    /// Feed updates run in order, so an older authorization never replaces a newer one.
    private var feedUpdate: Task<Void, Never>?
    private weak var photoBackup: PhotoLibraryBackupController?

    private let coordinator: PendingBackupCoordinator
    private let volume: PhotosVolumeBox
    private var snapshotTask: Task<Void, Never>?
    private var isBackupEnabled = false
    private var started = false
    /// Watched Mac folders feed the session too; their files show even while photo backup is off.
    private let hasFileSource: Bool
    /// The snapshot as the grid and lists show it: without Apple Photos tiles while photo backup is off.
    private var presented = PendingBackupSnapshot.empty
    private var presentedFileTiles:
        (revision: UInt64, tiles: [PendingTile], trash: [PendingTile], excluded: [PendingTile])?
    /// Anything shows: photo backup runs, or watched folders exist.
    private var showsPending: Bool { isBackupEnabled || hasFileSource }

    /// Opens the device-local pending store in the account data directory. Nil when it cannot open; backup
    /// then reports itself unavailable, because deleted pending photos could otherwise upload.
    public static func openStore(
        accountDataDirectory: URL, policy: LibraryDatabasePolicy
    ) -> PendingBackupManifestStore? {
        PendingBackupManifestStore(
            url: accountDataDirectory.appendingPathComponent(PendingBackupManifestStore.databaseFileName),
            policy: policy
        )
    }

    /// `files` adds the Mac's watched folders; their backup runner must record into `photoBackup.pendingRecorder`.
    public init?(
        store: PendingBackupManifestStore,
        photoBackup: PhotoLibraryBackupController,
        remote: any PendingRemoteEffects,
        files: PendingFileSource? = nil
    ) {
        guard let recorder = photoBackup.pendingRecorder,
            let queue = photoBackup.pendingQueue,
            let metadata = photoBackup.pendingMetadataProvider
        else { return nil }
        let volume = PhotosVolumeBox()
        self.volume = volume
        hasFileSource = files != nil
        var queues: [UploadSourceIdentity.Kind: any UploadBackupSyncQueueObserving] = [.photoLibraryAsset: queue]
        if let files { queues[.fileURL] = files.queue }
        coordinator = PendingBackupCoordinator(
            store: store,
            queues: queues,
            metadataProvider: SessionMetadata(photos: metadata, files: files?.metadata),
            effects: SessionEffects(photoBackup: photoBackup, files: files, remote: remote, volume: volume),
            recorder: recorder,
            replacementJournal: photoBackup.pendingReplacementJournal,
            identities: photoBackup.pendingIdentities,
            relations: photoBackup.pendingRelations
        )
        presenter = PendingTimelinePresenter(replacementLookup: { [ledger = recorder.replacementLedger] in
            ledger.replacementHandoffs()
        })
        self.photoBackup = photoBackup
        presenter.onRemotePresence = { [coordinator] keys in
            Task { await coordinator.noteRemotePresence(keys) }
        }
        presenter.onFeedUpdate = { [weak self] localUIDs, adoptions, revised in
            guard let self else { return }
            if !adoptions.isEmpty || !revised.isEmpty || localUIDs.count != self.gridLocalUIDs.count {
                Self.logger.notice(
                    "[PendingGrid] local=\(localUIDs.count, privacy: .public) handovers=\(adoptions.count, privacy: .public) revised=\(revised.count, privacy: .public)"
                )
            }
            self.gridLocalUIDs = localUIDs
            self.publishFeedAuthorization(adoptions: adoptions)
            // The tile keeps its image while the new one loads; the grid swaps textures once it is there. The
            // load waits for the authorization above, as the feed loads only authorized photos, such as a tile
            // that shows again. It runs beside the authorization chain, so a slow iCloud load never delays new tiles.
            if !revised.isEmpty, let feed = self.feed {
                let presenter = self.presenter
                let authorization = self.feedUpdate
                Task {
                    await authorization?.value
                    let refreshed = await feed.refreshLocal(revised)
                    presenter.noteContentRefreshed(refreshed)
                }
            }
        }
    }

    /// Lets `feed` load thumbnails of local photos from Apple Photos, and keeps its authorization current.
    /// `imageRequest` is the platform's `PhotoKitPlatformImages.request`.
    /// `fileThumbnails` loads watched-folder files on the Mac.
    public func attachFeed(
        _ feed: ThumbnailFeedCore,
        imageRequest: @escaping PhotoKitImageRequest,
        fileThumbnails: (any LocalThumbnailLoading)? = nil
    ) {
        // A photo deleted in Apple Photos before its upload leaves the grid instead of staying black.
        let coordinator = self.coordinator
        let onMissing: @Sendable ([PhotoUID]) -> Void = { uids in
            Task { await coordinator.noteSourcesMissing(uids) }
        }
        guard feed !== self.feed else { return }
        let previous = self.feed
        self.feed = feed
        let authorized = authorizedLocalUIDs
        enqueueFeedUpdate {
            if let previous { await Self.detach(previous) }
            await feed.setLocalThumbnailLoader(
                LocalThumbnailRouter(
                    photos: PhotoKitLocalThumbnailLoader(request: imageRequest, onMissing: onMissing),
                    files: fileThumbnails)
            )
            await feed.setLocalAuthorization(authorized)
        }
    }

    private func publishFeedAuthorization(adoptions: [(local: PhotoUID, remote: PhotoUID)] = []) {
        var nextAuthorized = gridLocalUIDs
        if showsPending {
            nextAuthorized.formUnion(presented.trashTiles.map(\.item.uid))
            nextAuthorized.formUnion(presented.excludedTiles.map(\.item.uid))
        }
        let authorized = nextAuthorized
        guard authorized != authorizedLocalUIDs || !adoptions.isEmpty else { return }
        authorizedLocalUIDs = authorized
        guard let feed else { return }
        // The Proton photo shows the decoded pending image until its own thumbnail arrives.
        enqueueFeedUpdate { await feed.setLocalAuthorization(authorized, adoptions: adoptions) }
    }

    private func enqueueFeedUpdate(_ work: @escaping @Sendable () async -> Void) {
        let previous = feedUpdate
        feedUpdate = Task {
            await previous?.value
            await work()
        }
    }

    private static func detach(_ feed: ThumbnailFeedCore) async {
        await feed.setLocalAuthorization([])
        await feed.setLocalThumbnailLoader(nil)
    }

    /// Follows the backup switch, availability, and pause of the controller: pending photos show only while
    /// backup is on and able to run, and their badges show the pause when the person paused it or the backup
    /// waits for Wi-Fi.
    private func observeBackupState() {
        guard let photoBackup else { return }
        let (enabled, paused) = withObservationTracking {
            (
                photoBackup.isEnabled && photoBackup.isAvailable && photoBackup.accessState.allowsBackup,
                photoBackup.isUserPaused || photoBackup.isWaitingForWiFi
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeBackupState() }
        }
        presenter.setBackupPaused(paused)
        setBackupEnabled(enabled)
    }

    public func start() {
        guard !started else { return }
        started = true
        observeBackupState()
        let coordinator = self.coordinator
        // Photos deleted in Apple Photos leave the excluded list after the catalog took in the change. Files deleted
        // from a watched folder leave it when the app becomes active or after a sync of the photo catalog.
        photoBackup?.onLibraryChange = { [weak coordinator] in
            Task { await coordinator?.noteLibraryChanged() }
        }
        snapshotTask = Task { [weak self] in
            await coordinator.start()
            for await snapshot in coordinator.snapshots {
                guard let self else { return }
                let membershipChanged = snapshot.membershipRevision != self.pendingSnapshot.membershipRevision
                self.pendingSnapshot = snapshot
                self.presented = self.present(snapshot)
                self.presenter.setPending(self.presented, enabled: self.showsPending)
                // Progress ticks leave the lists unchanged; only membership changes can change authorization.
                if membershipChanged {
                    self.publishFeedAuthorization()
                    self.refreshLists()
                }
                self.onPendingChange?(snapshot)
            }
        }
    }

    /// The canonical whole-library Proton timeline.
    public func setRemote(_ snapshot: TimelineSnapshot) {
        if let volumeID = snapshot.items.first?.uid.volumeID { volume.set(volumeID) }
        presenter.setRemote(snapshot)
    }

    /// Pending photos show only while backup is on and able to run.
    private func setBackupEnabled(_ enabled: Bool) {
        guard enabled != isBackupEnabled else { return }
        isBackupEnabled = enabled
        presented = present(pendingSnapshot)
        presenter.setPending(presented, enabled: showsPending)
        publishFeedAuthorization()
        refreshLists()
    }

    /// Everything while photo backup runs; only watched-folder files while it is off. The membership revision
    /// changes with the filter, so the presenter rebuilds when photo backup turns on or off.
    private func present(_ snapshot: PendingBackupSnapshot) -> PendingBackupSnapshot {
        guard hasFileSource, !isBackupEnabled else { return snapshot }
        let isFile: (PendingTile) -> Bool = { $0.key.kind == .fileURL }
        if presentedFileTiles?.revision != snapshot.membershipRevision {
            presentedFileTiles = (
                snapshot.membershipRevision, snapshot.tiles.filter(isFile), snapshot.trashTiles.filter(isFile),
                snapshot.excludedTiles.filter(isFile)
            )
        }
        let files = presentedFileTiles!
        return PendingBackupSnapshot(
            membershipRevision: snapshot.membershipRevision | (1 << 63),
            progressRevision: snapshot.progressRevision,
            tiles: files.tiles,
            progress: snapshot.progress.filter { $0.key.localPendingNamespace == .file },
            trashTiles: files.trash,
            excludedTiles: files.excluded,
            favoriteIntents: snapshot.favoriteIntents.filter { $0.key.localPendingNamespace == .file }
        )
    }

    private func refreshLists() {
        let trashItems = showsPending ? presented.trashTiles.map(\.item) : []
        let excluded = showsPending ? presented.excludedTiles : []
        guard Set(trashItems.map(\.uid)) != trash.localUIDs || excluded != excludedTiles else { return }
        trash = PendingTrashPresentation(items: trashItems)
        excludedTiles = excluded
        onListsChange?()
    }

    /// Whether pending photos show now (backup on, available, and allowed to read the Photos library).
    public var isShowingPendingPhotos: Bool { showsPending }

    /// Favorites as the app shows them: Proton favorites plus the desired states of pending photos, which the
    /// backup applies after the upload.
    public func displayedFavorites(_ remote: Set<PhotoUID>) -> Set<PhotoUID> {
        let intents = pendingSnapshot.favoriteIntents
        guard !intents.isEmpty else { return remote }
        var result = remote
        for (uid, favorite) in intents {
            if favorite { result.insert(uid) } else { result.remove(uid) }
        }
        return result
    }

    // MARK: - Person actions on local photos

    @discardableResult
    public func delete(_ uids: [PhotoUID]) async -> Bool { await coordinator.exclude(uids) }

    @discardableResult
    public func restore(_ uids: [PhotoUID]) async -> Bool { await coordinator.restore(uids) }

    /// The person restored these Proton photos from the trash. They show at once, also when an edit's
    /// replacement hid them while the listing still returned them.
    public func photosRestored(_ uids: [PhotoUID]) { presenter.showRestored(uids) }

    /// A Proton photo came back from the trash; a pending delete that trashed it is undone as well.
    public func restoreSources(ofRemote uids: [PhotoUID]) async { await coordinator.restoreSources(ofRemote: uids) }

    @discardableResult
    public func removeFromTrashList(_ uids: [PhotoUID]) async -> Bool { await coordinator.removeFromTrashList(uids) }

    @discardableResult
    public func setFavorite(_ uids: [PhotoUID], favorite: Bool) async -> Bool {
        await coordinator.setFavorite(uids, favorite: favorite)
    }

    @discardableResult
    public func addToAlbum(_ uids: [PhotoUID], albumID: String) async -> Bool {
        await coordinator.addToAlbum(uids, albumID: albumID)
    }

    public func recordSavedFromApp(localIdentifier: String, remote: PhotoUID) async {
        await coordinator.recordSavedFromApp(localIdentifier: localIdentifier, remote: remote)
    }

    public func close() async {
        snapshotTask?.cancel()
        snapshotTask = nil
        photoBackup?.onLibraryChange = nil
        await coordinator.close()
        presenter.reset()
        pendingSnapshot = .empty
        presented = .empty
        presentedFileTiles = nil
        gridLocalUIDs = []
        authorizedLocalUIDs = []
        trash = .empty
        excludedTiles = []
        onListsChange?()
        if let feed {
            self.feed = nil
            enqueueFeedUpdate { await Self.detach(feed) }
        }
        await feedUpdate?.value
        feedUpdate = nil
    }
}

/// The photos volume seen in the Proton timeline, for link-only handoffs.
private final class PhotosVolumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ volumeID: String) { lock.withLock { value = volumeID } }
    func get() -> String? { lock.withLock { value } }
}

/// Watched Mac folders as a second backup source of the pending grid. The app owns folder access; the folder
/// backup runner records into the photo backup's pending recorder, so one event stream serves both.
public struct PendingFileSource: Sendable {
    public let queue: any UploadBackupSyncQueueObserving
    public let metadata: any PendingSourceMetadataProviding
    /// Removes excluded files (standardized paths) from queued and in-flight backup work.
    public let removeFromBackup: @Sendable ([String]) async -> Bool
    /// Enqueues restored files again.
    public let returnToBackup: @Sendable ([String]) async -> Bool

    public init(
        queue: any UploadBackupSyncQueueObserving,
        metadata: any PendingSourceMetadataProviding,
        removeFromBackup: @escaping @Sendable ([String]) async -> Bool,
        returnToBackup: @escaping @Sendable ([String]) async -> Bool
    ) {
        self.queue = queue
        self.metadata = metadata
        self.removeFromBackup = removeFromBackup
        self.returnToBackup = returnToBackup
    }
}

/// Tile metadata from the source that owns each key.
private struct SessionMetadata: PendingSourceMetadataProviding {
    let photos: any PendingSourceMetadataProviding
    let files: (any PendingSourceMetadataProviding)?

    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        let photoKeys = keys.filter { $0.kind == .photoLibraryAsset }
        let fileKeys = keys.filter { $0.kind == .fileURL }
        var result = photoKeys.isEmpty ? [:] : await photos.metadata(for: photoKeys)
        if let files, !fileKeys.isEmpty {
            result.merge(await files.metadata(for: fileKeys)) { current, _ in current }
        }
        return result
    }
}

/// Thumbnails of local photos from the source that owns each identity.
private struct LocalThumbnailRouter: LocalThumbnailLoading {
    let photos: PhotoKitLocalThumbnailLoader
    let files: (any LocalThumbnailLoading)?

    func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        let photoUIDs = uids.filter { $0.localPendingNamespace == .photoLibrary }
        let fileUIDs = uids.filter { $0.localPendingNamespace == .file }
        var result = photoUIDs.isEmpty ? [:] : await photos.thumbnails(for: photoUIDs, maxPixelSize: maxPixelSize)
        if let files, !fileUIDs.isEmpty {
            result.merge(await files.thumbnails(for: fileUIDs, maxPixelSize: maxPixelSize)) { current, _ in current }
        }
        return result
    }
}

private struct SessionEffects: PendingBackupEffects {
    let photoBackup: PhotoLibraryBackupController
    let files: PendingFileSource?
    let remote: any PendingRemoteEffects
    let volume: PhotosVolumeBox

    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
        switch kind {
        case .photoLibraryAsset: await photoBackup.removeFromBackup(identifiers: identifiers)
        case .fileURL: await files?.removeFromBackup(identifiers) ?? true
        }
    }

    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool {
        let photos = keys.filter { $0.kind == .photoLibraryAsset }.map(\.identifier)
        let fileKeys = keys.filter { $0.kind == .fileURL }.map(\.identifier)
        var succeeded = true
        if !photos.isEmpty { succeeded = await photoBackup.returnToBackup(identifiers: photos) }
        if !fileKeys.isEmpty, let files { succeeded = await files.returnToBackup(fileKeys) && succeeded }
        return succeeded
    }

    func photosVolumeID() async -> String? { volume.get() }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { await remote.trash(uids) }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { await remote.restore(uids) }

    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        await remote.setFavorite(uid, favorite: favorite)
    }

    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        await remote.addToAlbum(uid, albumID: albumID)
    }
}
