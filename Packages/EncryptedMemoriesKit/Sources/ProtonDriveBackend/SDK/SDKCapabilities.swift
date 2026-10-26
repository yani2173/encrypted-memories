import AlbumCore
import Foundation
import UploadCore

/// Central, honest record of what the wired Proton SDK / HTTP layer can actually do. Logged once at
/// sign-in for diagnostics - nothing here currently gates UI.
///
/// The album + upload sections are not hand-rolled here: they reference the same canonical capability
/// presets the UI gates on (`AlbumCapabilities.sdkCatalogWithHTTPWrites`, `UploadBackendCapabilities.sdkUploader`),
/// so the diagnostic can't drift from the real backend.
struct SDKCapabilities {
    // EncryptedMemoriesClient - present and wrapped by `DriveSDKBridge`.
    var photosClientAvailable = true
    var enumerateTimeline = true
    var downloadThumbnails = true
    var download = true
    var downloadOperation = true
    var cancelPhotoDownload = true
    var exactPhotoDuplicatesViaSDK = true
    var photosTrashAPIsAvailable = true
    var emptyTrashViaSDK = true
    var eventEnumerationAvailable = true
    var normalizedFileSystemErrorsAvailable = true
    // Generic Drive SDK trash does not update the Photos trash route used by our library UI.
    var trashViaSDK = false

    /// Upload capabilities, as the UI sees them (the wired SDK uploader). Single source of truth.
    var upload = UploadBackendCapabilities.sdkUploader

    /// The app reads the album catalog, sharing and membership through SDK 0.32.1. Direct Photos HTTP remains only
    /// for the album writes that the Swift API of SDK 0.32.1 does not expose.
    var albumReadAPIsAvailable = true
    var photoTagUpdatesAvailable = true
    var albumsViaSDK = false
    var albums = AlbumCapabilities.sdkCatalogWithHTTPWrites

    static let current = SDKCapabilities()

    /// Emits the `[SDKCapabilities]` diagnostic block.
    func log() {
        let lines = """
            [SDKCapabilities]
            photosClientAvailable=\(photosClientAvailable)
            canUpload=\(upload.canUpload)
            uploadCancel=\(upload.supportsCancel)
            uploadPauseResume=\(upload.supportsPauseResume)
            cancelPhotoDownload=\(cancelPhotoDownload)
            downloadOperation=\(downloadOperation)
            exactPhotoDuplicatesViaSDK=\(exactPhotoDuplicatesViaSDK)
            photosTrashAPIsAvailable=\(photosTrashAPIsAvailable)
            emptyTrashViaSDK=\(emptyTrashViaSDK)
            eventEnumerationAvailable=\(eventEnumerationAvailable)
            normalizedFileSystemErrorsAvailable=\(normalizedFileSystemErrorsAvailable)
            trashViaSDK=\(trashViaSDK)
            albumReadAPIsAvailable=\(albumReadAPIsAvailable)
            photoTagUpdatesAvailable=\(photoTagUpdatesAvailable)
            albumsViaSDK=\(albumsViaSDK)
            albumList=\(albums.canList)
            albumCreate=\(albums.canCreate)
            albumDelete=\(albums.canDelete)
            albumAdd=\(albums.canAddPhotos)
            albumSetCover=\(albums.canSetCover)
            sharedAlbumWrites=\(albums.canWriteSharedAlbums)
            """
        DebugLog.log(lines)
    }
}
