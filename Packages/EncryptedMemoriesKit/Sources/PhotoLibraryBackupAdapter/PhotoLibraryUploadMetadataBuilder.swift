import CoreLocation
import Foundation
import Photos
import UploadCore

enum PhotoLibraryUploadMetadataBuilder {
    /// `memberCaptureDate` describes a series member that uploads inside `asset`'s compound. The member keeps
    /// the main photo's source identity, because a remote asset proof requires one identity on every
    /// resource of a compound; only its capture time is its own.
    static func metadata(
        for asset: PHAsset,
        cloudIdentifier cachedCloudIdentifier: String? = nil,
        memberCaptureDate: Date? = nil
    ) throws -> [PhotoUploadAdditionalMetadata] {
        let captureDate = memberCaptureDate ?? asset.creationDate ?? asset.modificationDate
        let modificationDate = asset.modificationDate ?? asset.creationDate
        let location = location(from: asset.location)
        let camera = PhotoUploadMetadataEncoder.Camera(captureTime: captureDate.map(format))
        let media = PhotoUploadMetadataEncoder.Media(
            width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            duration: asset.mediaType == .video ? asset.duration : nil
        )
        let iOSPhotos = (cachedCloudIdentifier ?? resolveCloudIdentifier(for: asset)).map {
            PhotoUploadMetadataEncoder.IOSPhotos(
                iCloudID: $0,
                modificationTime: modificationDate.map(format)
            )
        }
        return try PhotoUploadMetadataEncoder.metadata(
            location: location,
            camera: camera,
            media: media,
            iOSPhotos: iOSPhotos
        )
    }

    static func location(from location: CLLocation?) -> PhotoUploadMetadataEncoder.Location? {
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        return PhotoUploadMetadataEncoder.Location(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private static func resolveCloudIdentifier(for asset: PHAsset) -> String? {
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        return try? mapping[asset.localIdentifier]?.get().stringValue
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
