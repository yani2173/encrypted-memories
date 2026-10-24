import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MediaDecodingCore
import MediaFeedCore
import PhotoLibraryBackupAdapter
import PhotosCore
import QuickLookThumbnailing
import UniformTypeIdentifiers
import UploadCore

/// The watched backup folders the app can read right now. Pending files outside them are never read, so an
/// entry of a removed folder cannot reach a file the person no longer shared.
final class PendingFolderAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []

    func setRoots(_ urls: [URL]) {
        let paths = urls.map {
            $0.standardizedFileURL.path.hasSuffix("/") ? $0.standardizedFileURL.path : $0.standardizedFileURL.path + "/"
        }
        lock.withLock { roots = paths }
    }

    /// The file behind a pending file UID, when it lies in a watched folder.
    func fileURL(for uid: PhotoUID) -> URL? {
        guard uid.localPendingNamespace == .file else { return nil }
        return fileURL(forPath: uid.nodeID)
    }

    func fileURL(forPath path: String) -> URL? {
        let roots = lock.withLock { self.roots }
        guard roots.contains(where: { path.hasPrefix($0) }) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Tile metadata of pending files. The capture date comes from the same reader the upload uses, so the tile
/// sorts where the Proton photo will appear.
struct PendingFolderMetadataProvider: PendingSourceMetadataProviding {
    let access: PendingFolderAccess

    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        var result: [PendingSourceKey: PendingPresentationMetadata] = [:]
        for key in keys where key.kind == .fileURL {
            guard let url = access.fileURL(forPath: key.identifier),
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let modified = attributes[.modificationDate] as? Date
            else { continue }
            let fallback = UploadCaptureDateReader.fileSystemFallback(from: attributes, default: modified)
            let type = UTType(filenameExtension: url.pathExtension)
            result[key] = PendingPresentationMetadata(
                captureTime: await UploadCaptureDateReader.captureDate(for: url, fallback: fallback),
                mediaType: type?.preferredMIMEType ?? "application/octet-stream",
                displayName: url.lastPathComponent
            )
        }
        return result
    }
}

/// Thumbnails and viewer media of pending files in watched folders, read from disk. QuickLook renders every
/// type the folder backup supports, videos included.
struct PendingFolderMedia: LocalThumbnailLoading, LocalFileMedia {
    let access: PendingFolderAccess

    private enum FolderMediaError: LocalizedError {
        case unavailable
        var errorDescription: String? { L10n.string("viewer.local_media_unavailable") }
    }

    func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        var result: [PhotoUID: DecodedThumbnail] = [:]
        for uid in uids {
            guard !Task.isCancelled else { break }
            if let url = access.fileURL(for: uid), let image = await Self.render(url, side: maxPixelSize) {
                result[uid] = DecodedThumbnail(image: image)
            }
        }
        return result
    }

    func preview(for uid: PhotoUID) async throws -> Data {
        guard let url = access.fileURL(for: uid), let image = await Self.render(url, side: 2048),
            let data = JPEGEncoding.data(from: image)
        else { throw FolderMediaError.unavailable }
        return data
    }

    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let url = access.fileURL(for: uid) else { throw FolderMediaError.unavailable }
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }
        .value
        onProgress(1)
        return data
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        guard let url = access.fileURL(for: uid) else { throw FolderMediaError.unavailable }
        let asset = AVURLAsset(url: url)
        return StreamingVideoAsset(asset: asset, retaining: asset)
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {}

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = access.fileURL(for: uid) else { throw FolderMediaError.unavailable }
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }.value
        onProgress(1)
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        guard let url = access.fileURL(for: uid) else { throw FolderMediaError.unavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = UTType(filenameExtension: url.pathExtension)
        var metadata = PhotoMetadata(
            filename: url.lastPathComponent,
            mimeType: type?.preferredMIMEType,
            fileSize: (attributes[.size] as? NSNumber)?.intValue,
            modificationTime: attributes[.modificationDate] as? Date
        )
        if type?.conforms(to: .movie) == true {
            let asset = AVURLAsset(url: url)
            metadata.durationSeconds = try? await asset.load(.duration).seconds
        } else if let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
                let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
                let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
            {
                metadata.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude
                metadata.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
            }
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                metadata.device = tiff[kCGImagePropertyTIFFModel] as? String
            }
        }
        return metadata
    }

    private static func render(_ url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
