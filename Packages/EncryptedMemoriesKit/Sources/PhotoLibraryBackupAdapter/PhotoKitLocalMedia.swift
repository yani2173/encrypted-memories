import AVFoundation
import CoreGraphics
import Foundation
import Photos
import PhotosCore
import UniformTypeIdentifiers

/// Viewer media of pending Apple Photos assets, read from the device. No Proton request is involved.
public struct PhotoKitLocalMedia: Sendable {
    public enum LocalMediaError: LocalizedError {
        case unavailable

        public var errorDescription: String? { L10n.string("viewer.local_media_unavailable") }
    }

    private let request: PhotoKitImageRequest

    public init(request: @escaping PhotoKitImageRequest) {
        self.request = request
    }

    /// A screen-sized JPEG rendition, for the viewer's first frame.
    public func preview(for uid: PhotoUID, maxPixelSize: CGFloat) async throws -> Data {
        let asset = try await Self.asset(for: uid)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        let data: Data? = await PhotoKitRequest.perform { [request] finish in
            // `.highQualityFormat` answers once, never degraded.
            request(asset, CGSize(width: maxPixelSize, height: maxPixelSize), .aspectFit, options) { image, _ in
                finish(image.flatMap { JPEGEncoding.data(from: $0) })
            }
        }
        try Task.checkCancellation()
        guard let data else { throw LocalMediaError.unavailable }
        return data
    }

    /// The original image bytes as Apple Photos stores them (HEIC, JPEG, RAW, …).
    public func originalData(for uid: PhotoUID) async throws -> Data {
        let asset = try await Self.asset(for: uid)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true
        let data: Data? = await PhotoKitRequest.perform { finish in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                finish(data)
            }
        }
        try Task.checkCancellation()
        guard let data else { throw LocalMediaError.unavailable }
        return data
    }

    /// A playable asset for a pending video. The player needs a file-backed asset; when PhotoKit renders an
    /// edit as a composition (for example slow motion), the viewer plays the unedited original instead.
    public func streamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        let asset = try await Self.asset(for: uid)
        for version in [PHVideoRequestOptionsVersion.current, .original] {
            let options = PHVideoRequestOptions()
            options.version = version
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let urlAsset: AVURLAsset? = await PhotoKitRequest.perform { finish in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    finish(avAsset as? AVURLAsset)
                }
            }
            try Task.checkCancellation()
            if let urlAsset { return StreamingVideoAsset(asset: urlAsset, retaining: urlAsset) }
        }
        throw LocalMediaError.unavailable
    }

    /// What Apple Photos knows about a pending photo, for the viewer's info panel and export file names.
    public func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        let asset = try await Self.asset(for: uid)
        let resource = Self.primaryResource(of: asset)
        let location = asset.location?.coordinate
        return PhotoMetadata(
            filename: resource?.originalFilename,
            mimeType: resource.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType },
            pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            durationSeconds: asset.mediaType == .video ? asset.duration : nil,
            modificationTime: asset.modificationDate,
            latitude: location?.latitude,
            longitude: location?.longitude
        )
    }

    /// Writes the current version of a pending photo's original (with edits, as Apple Photos shows it) to
    /// `destination`, for sharing, export and drag-out. Large videos stream to disk.
    public func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = try await Self.asset(for: uid)
        guard let resource = Self.currentResource(of: asset) else { throw LocalMediaError.unavailable }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { onProgress($0) }
        try? FileManager.default.removeItem(at: destination)
        let failure: (any Error)?? = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) {
                continuation.resume(returning: .some($0))
            }
        }
        try Task.checkCancellation()
        if case .some(.some(let error)) = failure { throw error }
        onProgress(1)
    }

    private static func primaryResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary: Set<PHAssetResourceType> = asset.mediaType == .video ? [.video] : [.photo]
        return resources.first { primary.contains($0.type) } ?? resources.first
    }

    /// The edited rendition when there is one, else the original.
    private static func currentResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let edited: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        return resources.first { $0.type == edited } ?? primaryResource(of: asset)
    }

    private static func asset(for uid: PhotoUID) async throws -> PHAsset {
        guard uid.localPendingNamespace == .photoLibrary else { throw LocalMediaError.unavailable }
        let identifier = uid.nodeID
        let asset = await Task.detached(priority: .userInitiated) {
            PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }.value
        guard let asset else { throw LocalMediaError.unavailable }
        return asset
    }
}

/// Routes viewer media requests: local pending photos go to Apple Photos, every other identity to Proton.
/// Media of pending files in watched Mac folders, supplied by the app, which owns folder access.
public typealias LocalFileMedia = FullMediaProvider & VideoStreamProvider & OriginalFileProvider & PhotoMetadataProvider

public struct LocalPendingMediaRouter: FullMediaProvider, VideoStreamProvider, OriginalByteStreamProvider,
    OriginalFileProvider, PhotoMetadataProvider
{
    private let remote: (any FullMediaProvider)?
    private let remoteVideo: (any VideoStreamProvider)?
    private let local: PhotoKitLocalMedia
    private let files: (any LocalFileMedia)?
    /// The viewer's first-frame size for local previews.
    private let previewPixelSize: CGFloat

    public init(
        remote: (any FullMediaProvider)?, remoteVideo: (any VideoStreamProvider)?,
        imageRequest: @escaping PhotoKitImageRequest, files: (any LocalFileMedia)? = nil,
        previewPixelSize: CGFloat = 2048
    ) {
        self.remote = remote
        self.remoteVideo = remoteVideo
        self.local = PhotoKitLocalMedia(request: imageRequest)
        self.files = files
        self.previewPixelSize = previewPixelSize
    }

    private func fileMedia(for uid: PhotoUID) throws -> (any LocalFileMedia)? {
        guard uid.localPendingNamespace == .file else { return nil }
        guard let files else { throw PhotoKitLocalMedia.LocalMediaError.unavailable }
        return files
    }

    public func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        if let files = try fileMedia(for: uid) { return try await files.metadata(for: uid) }
        if uid.isLocalPending { return try await local.metadata(for: uid) }
        guard let provider = remote as? any PhotoMetadataProvider else {
            throw PhotoKitLocalMedia.LocalMediaError.unavailable
        }
        return try await provider.metadata(for: uid)
    }

    public func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let files = try fileMedia(for: uid) {
            return try await files.writeOriginal(for: uid, to: destination, onProgress: onProgress)
        }
        if uid.isLocalPending {
            return try await local.writeOriginal(for: uid, to: destination, onProgress: onProgress)
        }
        guard let provider = remote as? any OriginalFileProvider else {
            throw PhotoKitLocalMedia.LocalMediaError.unavailable
        }
        try await provider.writeOriginal(for: uid, to: destination, onProgress: onProgress)
    }

    public func preview(for uid: PhotoUID) async throws -> Data {
        if let files = try fileMedia(for: uid) { return try await files.preview(for: uid) }
        if uid.isLocalPending { return try await local.preview(for: uid, maxPixelSize: previewPixelSize) }
        guard let remote else { throw PhotoKitLocalMedia.LocalMediaError.unavailable }
        return try await remote.preview(for: uid)
    }

    public func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        if let files = try fileMedia(for: uid) { return try await files.originalData(for: uid, onProgress: onProgress) }
        if uid.isLocalPending {
            let data = try await local.originalData(for: uid)
            onProgress(1)
            return data
        }
        guard let remote else { throw PhotoKitLocalMedia.LocalMediaError.unavailable }
        return try await remote.originalData(for: uid, onProgress: onProgress)
    }

    /// Proton originals stream in bounded chunks. Apple Photos returns a local original as one value, so it
    /// arrives as one chunk.
    public func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if !uid.isLocalPending, let streamer = remote as? any OriginalByteStreamProvider {
            return try await streamer.streamOriginalBytes(for: uid, onChunk: onChunk, onProgress: onProgress)
        }
        try await onChunk(originalData(for: uid, onProgress: onProgress))
    }

    public func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        if let files = try fileMedia(for: uid) { return try await files.makeStreamingAsset(for: uid) }
        if uid.isLocalPending { return try await local.streamingAsset(for: uid) }
        guard let remoteVideo else { throw PhotoKitLocalMedia.LocalMediaError.unavailable }
        return try await remoteVideo.makeStreamingAsset(for: uid)
    }

    public func prefetchEncrypted(for uid: PhotoUID) async throws {
        guard !uid.isLocalPending, let remoteVideo else { return }
        try await remoteVideo.prefetchEncrypted(for: uid)
    }
}
