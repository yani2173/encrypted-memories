import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore

/// One account's backup stack, built the same way on macOS, iOS and iPadOS: the device-local pending store, the
/// photo backup that refuses to run without it, and album sync. The account host keeps ownership, adds its own parts
/// (the Mac's watched folders, the iOS thumbnail feed) and keeps its teardown order.
@MainActor
public struct AccountBackupStack {
    /// Nil when the store cannot open; the photo backup then reports itself unavailable, because a deleted pending
    /// photo could otherwise upload.
    public let pendingStore: PendingBackupManifestStore?
    public let photoBackup: PhotoLibraryBackupController
    public let albumSync: AlbumSyncController

    public init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)?,
        editReplacement: EditedPhotoReplacement?,
        albumOperations: any AlbumSyncRemoteAlbumOps
    ) {
        self.init(
            accountDataDirectory: accountDataDirectory, databasePolicy: databasePolicy,
            identityResolver: identityResolver, uploader: uploader, tagAdder: tagAdder,
            editReplacement: editReplacement, albumOperations: albumOperations, dependencies: Dependencies())
    }

    struct Dependencies {
        var makeChangeMonitor: (URL) -> PhotoLibraryChangeMonitor = { PhotoLibraryChangeMonitor(tokenURL: $0) }
        var currentAccessState: () -> PhotoBackupAccessState = PhotoLibraryAuthorization.currentState
        var changeSleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        var localAlbumSource: any AlbumSyncLocalAlbumSource = PhotoKitAlbumSource()
        var defaults: UserDefaults = .standard
        var runtimeSignals: BackupRuntimeSignalSource = .apple
    }

    init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)?,
        editReplacement: EditedPhotoReplacement?,
        albumOperations: any AlbumSyncRemoteAlbumOps,
        dependencies: Dependencies
    ) {
        let changeMonitor = dependencies.makeChangeMonitor(
            accountDataDirectory.appendingPathComponent("photo-backup-change-token.v1"))
        var backupConfiguration = PhotoLibraryBackupController.Configuration(
            accountDataDirectory: accountDataDirectory, databasePolicy: databasePolicy,
            defaults: dependencies.defaults, runtimeSignals: dependencies.runtimeSignals)
        backupConfiguration.makeChangeMonitor = { _ in changeMonitor }
        backupConfiguration.currentAccessState = dependencies.currentAccessState
        backupConfiguration.changeSleep = dependencies.changeSleep
        var albumConfiguration = AlbumSyncController.Configuration(
            accountDataDirectory: accountDataDirectory, databasePolicy: databasePolicy)
        albumConfiguration.makeChangeMonitor = { _ in changeMonitor }
        albumConfiguration.currentAccessState = dependencies.currentAccessState
        albumConfiguration.changeSleep = dependencies.changeSleep
        albumConfiguration.localSource = dependencies.localAlbumSource
        let pendingStore = PendingGridSession.openStore(
            accountDataDirectory: accountDataDirectory, policy: databasePolicy)
        self.pendingStore = pendingStore
        photoBackup = PhotoLibraryBackupController(
            configuration: backupConfiguration,
            identityResolver: identityResolver,
            uploader: uploader,
            tagAdder: tagAdder,
            editReplacement: editReplacement,
            pendingStore: pendingStore,
            requiresPendingStore: true
        )
        albumSync = AlbumSyncController(
            configuration: albumConfiguration,
            identityResolver: identityResolver,
            uploader: uploader,
            remoteOps: albumOperations
        )
    }

    /// Closes a stack that never reached the account, for example after a cancelled or superseded load: the photo
    /// backup first, then the pending store it used, then album sync.
    public func shutdownUnused() async {
        await photoBackup.shutdown()
        pendingStore?.close()
        await albumSync.shutdown()
    }
}
