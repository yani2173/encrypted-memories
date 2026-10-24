import Foundation
import PhotosCore
import ProtonDriveSDK
import UploadCore

/// Reads the volume-qualified SDK node. A shared photo cannot use the account's own Photos share key chain.
enum SDKPhotoMetadataReader {
    struct ReadResult: Sendable {
        let metadata: PhotoMetadata
        let timelineOrder: TimelineOrderMetadata?
    }

    static func metadata(for uid: PhotoUID, client: any SDKPhotoCatalogClient) async throws -> PhotoMetadata {
        try await read(for: uid, client: client).metadata
    }

    /// Reuses the SDK's decrypted sections from the same node read as the Info panel.
    static func read(for uid: PhotoUID, client: any SDKPhotoCatalogClient) async throws -> ReadResult {
        let node = try await SDKCancellableOperation.run { token in
            try await client.getNode(
                nodeUid: SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID), cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetNode(cancellationToken: token)
        }
        try Task.checkCancellation()
        switch node {
        case .photo(let photo):
            return read(name: photo.name, mimeType: photo.mediaType, revision: photo.activeRevision)
        case .file(let file):
            return read(name: file.name, mimeType: file.mediaType, revision: file.activeRevision)
        default:
            throw CocoaError(.fileReadUnknown)
        }
    }

    private static func read(
        name: Result<String, ProtonDriveSDKDriveError>, mimeType: String, revision: FileRevision
    ) -> ReadResult {
        let order = revision.claimedAdditionalMetadata.map { additional in
            TimelineOrderMetadataDecoder().decode(
                camera: additional.first { $0.name == "Camera" }?.utf8JsonValue,
                source: additional.first { $0.name == "iOS.photos" }?.utf8JsonValue)
        }
        return ReadResult(metadata: metadata(name: name, mimeType: mimeType, revision: revision), timelineOrder: order)
    }

    /// What a standalone copy of a series member keeps. The node must be a photo: only a photo node carries
    /// the capture time that places the copy in the timeline.
    static func seriesMemberSource(
        for uid: PhotoUID, client: any SDKPhotoCatalogClient
    ) async throws -> SeriesMemberSource {
        try await relatedFileSource(for: uid, client: client).metadata
    }

    /// Accepts photo nodes only: their capture time supplies the existing series-member projection.
    /// File nodes and other kinds throw CocoaError(.fileReadUnknown), which the transfer maps to copyFailed.
    /// A trustworthy claimed size is this photo's activeRevision.claimedSize, checked against streamed bytes.
    static func relatedFileSource(
        for uid: PhotoUID, client: any SDKPhotoCatalogClient
    ) async throws -> ExactDuplicateRelatedFileSource {
        let node = try await SDKCancellableOperation.run { token in
            try await client.getNode(
                nodeUid: SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID), cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetNode(cancellationToken: token)
        }
        try Task.checkCancellation()
        guard case .photo(let photo) = node else { throw CocoaError(.fileReadUnknown) }
        return ExactDuplicateRelatedFileSource(
            metadata: seriesMemberSource(
                name: try photo.name.get(), mimeType: photo.mediaType,
                captureTime: photo.captureTime, revision: photo.activeRevision),
            claimedSize: photo.activeRevision.claimedSize)
    }

    /// `iOS.photos` identifies the source asset of the series compound. The copy is a new photo without a
    /// source asset, so that section stays behind. The `EncryptedMemories.` sections describe the earlier photo,
    /// for example the uploads that it replaced, so they stay behind as well. Every other section travels unchanged.
    static func seriesMemberSource(
        name: String, mimeType: String, captureTime: TimeInterval, revision: FileRevision
    ) -> SeriesMemberSource {
        let captureDate = Date(timeIntervalSince1970: captureTime)
        return SeriesMemberSource(
            filename: name,
            mediaType: mimeType.isEmpty ? "application/octet-stream" : mimeType,
            captureTime: captureDate,
            modificationDate: revision.claimedModificationTime.flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
            } ?? captureDate,
            additionalMetadata: (revision.claimedAdditionalMetadata ?? [])
                .filter { $0.name != "iOS.photos" && !$0.name.hasPrefix("EncryptedMemories.") }
                .map { PhotoUploadAdditionalMetadata(name: $0.name, utf8JsonValue: $0.utf8JsonValue) }
        )
    }

    /// The metadata that the Info panel shows, with the capture time of the photo node, as the Duplicates screen
    /// compares copies.
    static func fingerprint(
        captureTime: TimeInterval, name: Result<String, ProtonDriveSDKDriveError>, mimeType: String,
        revision: FileRevision
    ) -> ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(
            captureTime: captureTime.isFinite ? Date(timeIntervalSince1970: captureTime) : nil,
            metadata: metadata(name: name, mimeType: mimeType, revision: revision))
    }

    static func metadata(
        name: Result<String, ProtonDriveSDKDriveError>, mimeType: String, revision: FileRevision
    ) -> PhotoMetadata {
        // Optional sections are independent. One absent or unsupported section must not discard other details.
        let additional = revision.claimedAdditionalMetadata ?? []
        func decode<T: Decodable>(_ type: T.Type, name: String) -> T? {
            guard let data = additional.first(where: { $0.name == name })?.utf8JsonValue else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        let media = decode(Media.self, name: "Media")
        let camera = decode(Camera.self, name: "Camera")
        let location = decode(Location.self, name: "Location")
        let modificationTime = revision.claimedModificationTime.flatMap {
            $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
        }
        return PhotoMetadata(
            filename: try? name.get(),
            mimeType: mimeType.isEmpty ? nil : mimeType,
            fileSize: revision.claimedSize.flatMap { $0 >= 0 ? Int(exactly: $0) : nil },
            pixelWidth: media?.width,
            pixelHeight: media?.height,
            device: camera?.device,
            durationSeconds: media?.duration,
            modificationTime: modificationTime,
            latitude: location?.latitude,
            longitude: location?.longitude
        )
    }

    // The SDK exposes decrypted sections of Proton's extended attributes, not full EXIF.
    private struct Media: Decodable {
        let width: Int?
        let height: Int?
        let duration: Double?
        enum CodingKeys: String, CodingKey {
            case width = "Width"
            case height = "Height"
            case duration = "Duration"
        }
    }
    private struct Camera: Decodable {
        let device: String?
        enum CodingKeys: String, CodingKey { case device = "Device" }
    }
    private struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
        enum CodingKeys: String, CodingKey {
            case latitude = "Latitude"
            case longitude = "Longitude"
        }
    }
}
