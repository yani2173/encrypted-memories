import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import UploadCore

/// Image files for the camera model tests: a real encoder writes them, so ImageIO reads them like a library file.
enum CameraDeviceFixtures {
    static func write(
        to url: URL,
        type: String = "public.jpeg",
        make: String? = nil,
        model: String? = nil,
        latitude: Double? = nil
    ) throws {
        let size = 32
        var pixels = Data(count: size * size * 4)
        for index in 0..<pixels.count { pixels[index] = UInt8(truncatingIfNeeded: index &* 31) }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var properties: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake as String] = make }
        if let model { tiff[kCGImagePropertyTIFFModel as String] = model }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        if let latitude {
            properties[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: latitude,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 16.3738,
                kCGImagePropertyGPSLongitudeRef as String: "E",
            ]
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

final class UploadCameraDeviceReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-camera-device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func url(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    func testReadsTheModelFromJPEGHEICAndTIFF() throws {
        for (name, type) in [("a.jpg", "public.jpeg"), ("a.heic", "public.heic"), ("a.tiff", "public.tiff")] {
            try CameraDeviceFixtures.write(to: url(name), type: type, make: "Apple", model: "iPhone 15 Pro")
            XCTAssertEqual(UploadCameraDeviceReader.device(forImageAt: url(name)), "iPhone 15 Pro", name)
        }
    }

    func testAnImageWithoutMetadataHasNoDevice() throws {
        try CameraDeviceFixtures.write(to: url("plain.jpg"))
        XCTAssertNil(UploadCameraDeviceReader.device(forImageAt: url("plain.jpg")))
    }

    func testAMakeWithoutAModelIsNoDevice() throws {
        try CameraDeviceFixtures.write(to: url("make.jpg"), make: "Apple")
        XCTAssertNil(UploadCameraDeviceReader.device(forImageAt: url("make.jpg")))
    }

    func testABlankModelIsNoDevice() throws {
        try CameraDeviceFixtures.write(to: url("blank.jpg"), model: "  ")
        XCTAssertNil(UploadCameraDeviceReader.device(forImageAt: url("blank.jpg")))
    }

    func testUnreadableFilesHaveNoDeviceAndDoNotThrow() throws {
        try CameraDeviceFixtures.write(to: url("whole.jpg"), model: "TESTCAM")
        let whole = try Data(contentsOf: url("whole.jpg"))
        try Data().write(to: url("empty.jpg"))
        try whole.prefix(12).write(to: url("cut-in-header.jpg"))
        try Data("not an image".utf8).write(to: url("text.jpg"))
        for name in ["missing.jpg", "empty.jpg", "cut-in-header.jpg", "text.jpg"] {
            XCTAssertNil(UploadCameraDeviceReader.device(forImageAt: url(name)), name)
        }
    }

    func testControlCharactersAreStrippedFromTheModel() {
        XCTAssertEqual(UploadCameraDeviceReader.normalized("iPhone\u{0}\u{7}\n 15\u{202E} Pro\r\n"), "iPhone 15 Pro")
        XCTAssertNil(UploadCameraDeviceReader.normalized("\u{0}\u{1}\n\t"))
    }

    func testAHugeModelIsCutToTheLimit() throws {
        let huge = String(repeating: "A\u{0}B", count: 400_000)
        let normalized = try XCTUnwrap(UploadCameraDeviceReader.normalized(huge))
        XCTAssertEqual(normalized.unicodeScalars.count, UploadCameraDeviceReader.maxLength)
        XCTAssertFalse(normalized.unicodeScalars.contains { $0.value == 0 })

        try CameraDeviceFixtures.write(to: url("huge.jpg"), model: String(repeating: "X\u{7}", count: 3_000))
        let device = try XCTUnwrap(UploadCameraDeviceReader.device(forImageAt: url("huge.jpg")))
        XCTAssertEqual(device, String(repeating: "X", count: UploadCameraDeviceReader.maxLength))
    }

    func testTheLocationOfTheFileIsNeverRead() throws {
        try CameraDeviceFixtures.write(to: url("gps.jpg"), model: "TESTCAM", latitude: 48.2082)
        let filled = PhotoUploadMetadataEncoder.fillingCameraDevice(
            in: [], mediaType: "image/jpeg", fileURL: url("gps.jpg"))
        XCTAssertEqual(filled.map(\.name), ["Camera"], "only the Camera section is added")
        let text = try XCTUnwrap(String(data: filled[0].utf8JsonValue, encoding: .utf8))
        XCTAssertEqual(text, #"{"Device":"TESTCAM"}"#)

        try CameraDeviceFixtures.write(to: url("gps-only.jpg"), latitude: 48.2082)
        XCTAssertEqual(
            PhotoUploadMetadataEncoder.fillingCameraDevice(
                in: [], mediaType: "image/jpeg", fileURL: url("gps-only.jpg")), [],
            "a file with a location and no model adds nothing")
    }
}

final class PhotoUploadCameraDeviceFillTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/nonexistent/photo.heic")

    private func camera(_ json: String) -> PhotoUploadAdditionalMetadata {
        PhotoUploadAdditionalMetadata(name: "Camera", utf8JsonValue: Data(json.utf8))
    }

    private func media() -> PhotoUploadAdditionalMetadata {
        PhotoUploadAdditionalMetadata(name: "Media", utf8JsonValue: Data(#"{"Width":4032}"#.utf8))
    }

    private func fill(
        _ metadata: [PhotoUploadAdditionalMetadata], mediaType: String = "image/heic", device: String? = "Model X",
        reads: ReadCounter = ReadCounter()
    ) -> [PhotoUploadAdditionalMetadata] {
        PhotoUploadMetadataEncoder.fillingCameraDevice(in: metadata, mediaType: mediaType, fileURL: file) { _ in
            reads.count += 1
            return device
        }
    }

    final class ReadCounter { var count = 0 }

    private func decoded(_ section: PhotoUploadAdditionalMetadata) throws -> PhotoUploadMetadataEncoder.Camera {
        try JSONDecoder().decode(PhotoUploadMetadataEncoder.Camera.self, from: section.utf8JsonValue)
    }

    func testFillsTheDeviceAndKeepsTheOtherCameraFieldsAndSections() throws {
        let original = [
            media(), camera(#"{"CaptureTime":"2026-07-05T10:00:00.000Z","Orientation":6}"#),
        ]
        let result = fill(original)
        XCTAssertEqual(result.map(\.name), ["Media", "Camera"])
        XCTAssertEqual(result[0], original[0])
        let camera = try decoded(result[1])
        XCTAssertEqual(camera.device, "Model X")
        XCTAssertEqual(camera.captureTime, "2026-07-05T10:00:00.000Z")
        XCTAssertEqual(camera.orientation, 6)
    }

    func testCreatesACameraSectionWhenThereIsNone() throws {
        let result = fill([media()])
        XCTAssertEqual(result.map(\.name), ["Media", "Camera"])
        XCTAssertEqual(try decoded(result[1]).device, "Model X")
    }

    func testADeviceThatIsAlreadySetWinsAndTheFileIsNotRead() {
        let original = [camera(#"{"CaptureTime":"2026-07-05T10:00:00.000Z","Device":"iPhone"}"#)]
        let reads = ReadCounter()
        XCTAssertEqual(fill(original, reads: reads), original)
        XCTAssertEqual(reads.count, 0)
    }

    func testABlankDeviceCountsAsNotSet() throws {
        let result = fill([camera(#"{"Device":"  "}"#)])
        XCTAssertEqual(try decoded(result[0]).device, "Model X")
    }

    func testVideosAndOtherMediaAreNotRead() {
        let original = [media()]
        for mediaType in ["video/quicktime", "application/octet-stream", ""] {
            let reads = ReadCounter()
            XCTAssertEqual(fill(original, mediaType: mediaType, reads: reads), original, mediaType)
            XCTAssertEqual(reads.count, 0, mediaType)
        }
    }

    func testAFileWithoutAModelLeavesTheSectionsUnchanged() {
        let original = [media(), camera(#"{"CaptureTime":"2026-07-05T10:00:00.000Z"}"#)]
        XCTAssertEqual(fill(original, device: nil), original)
        XCTAssertEqual(fill(original, device: " \n"), original)
    }

    func testADamagedCameraSectionIsLeftAlone() {
        let original = [camera("not json"), media()]
        XCTAssertEqual(fill(original), original)
    }

    func testTheDefaultReaderLeavesAMissingFileAlone() {
        let original = [media()]
        XCTAssertEqual(
            PhotoUploadMetadataEncoder.fillingCameraDevice(in: original, mediaType: "image/heic", fileURL: file),
            original)
    }
}
