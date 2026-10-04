import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import UploadCore

final class UploadCameraMetadataTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
    }

    private func jpeg(model: String?, orientation: Int?) throws -> URL {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).jpg")
        files.append(url)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let model { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFModel: model] }
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func metadata(camera: PhotoUploadMetadataEncoder.Camera) throws -> [PhotoUploadAdditionalMetadata] {
        try PhotoUploadMetadataEncoder.metadata(
            location: .init(latitude: 48.2, longitude: 16.37),
            camera: camera,
            media: .init(width: 2, height: 2, duration: nil),
            iOSPhotos: .init(iCloudID: "icloud-asset", modificationTime: nil))
    }

    private func camera(in metadata: [PhotoUploadAdditionalMetadata]) throws -> PhotoUploadMetadataEncoder.Camera {
        let section = try XCTUnwrap(metadata.first { $0.name == "Camera" })
        return try JSONDecoder().decode(PhotoUploadMetadataEncoder.Camera.self, from: section.utf8JsonValue)
    }

    func testTheCameraModelAndOrientationOfTheFileCompleteTheCameraSection() throws {
        let url = try jpeg(model: "iPhone 17 Pro", orientation: 6)
        let original = try metadata(camera: .init(captureTime: "2026-10-05T10:00:00.000Z"))

        let completed = UploadCameraMetadata.completing(original, fileURL: url)

        XCTAssertEqual(
            try camera(in: completed),
            .init(captureTime: "2026-10-05T10:00:00.000Z", device: "iPhone 17 Pro", orientation: 6),
            "the info panel shows the camera of a backed-up photo")
        XCTAssertEqual(completed.map(\.name), original.map(\.name))
        XCTAssertEqual(
            completed.filter { $0.name != "Camera" }, original.filter { $0.name != "Camera" },
            "location, size, and the iCloud identity stay as the source wrote them")
    }

    func testValuesTheSourceSetWin() throws {
        let url = try jpeg(model: "iPhone 17 Pro", orientation: 6)
        let original = try metadata(camera: .init(captureTime: nil, device: "Canon EOS R5", orientation: 1))

        XCTAssertEqual(UploadCameraMetadata.completing(original, fileURL: url), original)
    }

    func testAFileWithoutImageDataOrAnUploadWithoutCameraSectionChangesNothing() throws {
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).mov")
        files.append(video)
        try Data("not an image".utf8).write(to: video)
        let original = try metadata(camera: .init(captureTime: "2026-10-05T10:00:00.000Z"))
        XCTAssertEqual(UploadCameraMetadata.completing(original, fileURL: video), original)

        let url = try jpeg(model: "iPhone 17 Pro", orientation: 6)
        XCTAssertEqual(UploadCameraMetadata.completing([], fileURL: url), [], "a folder file gets no new section")
    }
}
