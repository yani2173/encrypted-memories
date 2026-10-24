import CoreLocation
import Foundation
import PhotosCore
import ProtonDriveSDK
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import ProtonDriveBackend
@testable import UploadCore

final class PhotoUploadMetadataEncoderTests: XCTestCase {
    func testEncodesProtonPhotoXAttrSections() throws {
        let metadata = try PhotoUploadMetadataEncoder.metadata(
            location: .init(latitude: 48.2082, longitude: 16.3738),
            camera: .init(captureTime: "2026-07-05T10:00:00.000Z", device: "iPhone", orientation: 1),
            media: .init(width: 4032, height: 3024, duration: nil),
            iOSPhotos: .init(iCloudID: "cloud-id", modificationTime: "2026-07-05T10:01:00.000Z")
        )

        XCTAssertEqual(metadata.map(\.name), ["Location", "Camera", "Media", "iOS.photos"])
        XCTAssertEqual(try json(metadata[0])["Latitude"] as? Double, 48.2082)
        XCTAssertEqual(try json(metadata[0])["Longitude"] as? Double, 16.3738)
        XCTAssertEqual(try json(metadata[1])["CaptureTime"] as? String, "2026-07-05T10:00:00.000Z")
        XCTAssertEqual(try json(metadata[1])["Device"] as? String, "iPhone")
        XCTAssertEqual(try json(metadata[1])["Orientation"] as? Int, 1)
        XCTAssertEqual(try json(metadata[2])["Width"] as? Int, 4032)
        XCTAssertEqual(try json(metadata[2])["Height"] as? Int, 3024)
        XCTAssertNil(try json(metadata[2])["Duration"])
        XCTAssertEqual(try json(metadata[3])["ICloudID"] as? String, "cloud-id")
        XCTAssertEqual(try json(metadata[3])["ModificationTime"] as? String, "2026-07-05T10:01:00.000Z")
    }

    func testLocationRoundTripPreservesCoordinateOrder() throws {
        for (latitude, longitude) in [(12.25, -45.5), (-62.5, 131.25)] {
            let source = CLLocation(latitude: latitude, longitude: longitude)
            let location = try XCTUnwrap(PhotoLibraryUploadMetadataBuilder.location(from: source))
            let sections = try PhotoUploadMetadataEncoder.metadata(
                location: location, camera: .init(captureTime: nil),
                media: .init(width: nil, height: nil, duration: nil), iOSPhotos: nil)
            let revision = FileRevision(
                uid: SDKRevisionUid(volumeID: "test", nodeID: "photo", revisionID: "revision"),
                state: .active, creationTime: 1, storageSize: 1, claimedSize: 1,
                claimedDigests: FileContentDigests(sha1: nil, sha1Verified: false),
                claimedModificationTime: nil, thumbnails: [],
                claimedAdditionalMetadata: sections.map {
                    AdditionalMetadata(name: $0.name, utf8JsonValue: $0.utf8JsonValue)
                }, contentAuthor: nil)
            let decoded = SDKPhotoMetadataReader.metadata(
                name: .success("photo.jpg"), mimeType: "image/jpeg", revision: revision)
            XCTAssertEqual(decoded.latitude, latitude)
            XCTAssertEqual(decoded.longitude, longitude)
        }
    }

    func testEqualCoordinatesEmitOnlyADiagnosticAndKeepBothValues() throws {
        let diagnostics = PhotoDiagnostics()
        for value in [12.25, -45.5, 0] {
            let sections = try PhotoUploadMetadataEncoder.metadata(
                location: .init(latitude: value, longitude: value), camera: .init(captureTime: nil),
                media: .init(width: nil, height: nil, duration: nil), iOSPhotos: nil, diagnostics: diagnostics)
            XCTAssertEqual(try json(sections[0])["Latitude"] as? Double, value)
            XCTAssertEqual(try json(sections[0])["Longitude"] as? Double, value)
        }
        XCTAssertEqual(diagnostics.counter("backup.metadata.equalCoordinates"), 3)
        XCTAssertEqual(diagnostics.supportSnapshot().counters, ["backup.metadata.equalCoordinates": 3])
        for location in [PhotoUploadMetadataEncoder.Location(latitude: 12.25, longitude: 45.5), nil] {
            _ = try PhotoUploadMetadataEncoder.metadata(
                location: location, camera: .init(captureTime: nil),
                media: .init(width: nil, height: nil, duration: nil),
                iOSPhotos: nil, diagnostics: diagnostics)
        }
        XCTAssertEqual(diagnostics.counter("backup.metadata.equalCoordinates"), 3)
    }

    func testApplyingIdentityPreservesAdditionalMetadata() {
        let metadata = PhotoUploadAdditionalMetadata(name: "Media", utf8JsonValue: Data(#"{"Width":1}"#.utf8))
        let request = PhotoUploadRequest(
            queueItemID: UUID(),
            cancellationToken: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/photo.heic"),
            name: "photo.heic",
            mediaType: "image/heic",
            fileSize: 10,
            captureTime: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2),
            tags: [],
            additionalMetadata: [metadata]
        )

        let identity = UploadIdentity(
            correctedName: "photo-corrected.heic",
            nameHash: "name",
            sha1Hex: "0123456789012345678901234567890123456789",
            sha1Digest: Data(repeating: 1, count: 20),
            contentHash: "content"
        )

        let applied = request.applying(identity: identity)
        XCTAssertEqual(applied.name, "photo-corrected.heic")
        XCTAssertEqual(applied.additionalMetadata, [metadata])
        XCTAssertTrue(applied.allowsExpensiveNetwork, "uploads keep every network by default")

        var wiFiOnly = request
        wiFiOnly.allowsExpensiveNetwork = false
        XCTAssertFalse(wiFiOnly.applying(identity: identity).allowsExpensiveNetwork)
        XCTAssertFalse(wiFiOnly.replacingExistingDraft(true).allowsExpensiveNetwork)
    }

    private func json(_ metadata: PhotoUploadAdditionalMetadata) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: metadata.utf8JsonValue) as? [String: Any])
    }
}
