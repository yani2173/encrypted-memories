import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PhotosCore

final class PrivacyExportPolicyTests: XCTestCase {
    func testRemoveLocationDefaultsOnAndReadsSavedPreference() throws {
        let suiteName = "PrivacyExportPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(PrivacyExportPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AppSettingsKey.removeLocationWhenSharing)
        XCTAssertTrue(PrivacyExportPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AppSettingsKey.removeLocationWhenSharing)
        XCTAssertFalse(PrivacyExportPolicy.isEnabled(defaults: defaults))
    }

    func testSingleExportWithUnsetPreferenceRemovesGPSAndKeepsOriginal() async throws {
        try await assertLocationCopy(drag: false, storedPreference: nil)
    }

    func testDragOutWithUnsetPreferenceRemovesGPSAndKeepsOriginal() async throws {
        try await assertLocationCopy(drag: true, storedPreference: nil)
    }

    func testArchiveWithUnsetPreferenceRemovesGPSAndKeepsLensAndOriginals() async throws {
        let defaults = UserDefaults.standard
        let key = AppSettingsKey.removeLocationWhenSharing
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertNil(defaults.object(forKey: key))
        let directory = try makeDirectory()
        let archive = directory.appendingPathComponent("Export.zip")
        var originals: [URL] = []
        var bytes: [Data] = []
        var photos: [PhotoItem] = []
        for type in [UTType.jpeg, UTType.heic] {
            let ext = try XCTUnwrap(type.preferredFilenameExtension)
            let original = directory.appendingPathComponent("original.\(ext)")
            try makeGPSImage(at: original, type: type)
            originals.append(original)
            bytes.append(try Data(contentsOf: original))
            photos.append(
                PhotoItem(
                    uid: PhotoUID(volumeID: "test", nodeID: ext), captureTime: .now, mediaType: type.preferredMIMEType!)
            )
        }
        let provider = ArchiveGPSFileProvider(
            originals: Dictionary(uniqueKeysWithValues: zip(photos.map(\.uid), originals)))
        try await OriginalExportWriter.writeArchive(items: photos, to: archive, provider: provider) { _ in }
        let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: extracted.path)),
            Set(originals.map(\.lastPathComponent)))
        for (index, original) in originals.enumerated() {
            let output = extracted.appendingPathComponent(original.lastPathComponent)
            XCTAssertNil(gpsProperties(at: output))
            XCTAssertNil(iptcCity(at: output))
            XCTAssertEqual(lensModel(at: output), Self.lensModel)
            XCTAssertNotNil(gpsProperties(at: original))
            XCTAssertEqual(try Data(contentsOf: original), bytes[index])
        }
    }

    private struct ArchiveGPSFileProvider: OriginalFileProvider, PhotoMetadataProvider {
        let originals: [PhotoUID: URL]
        func writeOriginal(
            for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            let original = try XCTUnwrap(originals[uid])
            try Data(contentsOf: original).write(to: destination)
            onProgress(1)
        }
        func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
            PhotoMetadata(filename: try XCTUnwrap(originals[uid]).lastPathComponent)
        }
    }

    func testSingleExportWithExplicitOptOutKeepsGPSAndOriginalBytes() async throws {
        try await assertLocationCopy(drag: false, storedPreference: false)
    }

    func testDragOutWithExplicitOptOutKeepsGPSAndOriginalBytes() async throws {
        try await assertLocationCopy(drag: true, storedPreference: false)
    }

    private func assertLocationCopy(drag: Bool, storedPreference: Bool?) async throws {
        let defaults = UserDefaults.standard
        let key = AppSettingsKey.removeLocationWhenSharing
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if let storedPreference {
            defaults.set(storedPreference, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            XCTAssertNil(defaults.object(forKey: key), "exercise the unset default, not an explicit opt-in")
        }

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.jpg")
        try makeGPSImage(at: original)
        let originalBytes = try Data(contentsOf: original)
        let provider = GPSFileProvider(original: original)
        let photo = PhotoItem(
            uid: PhotoUID(volumeID: "test-volume", nodeID: "test-photo"), captureTime: .now, mediaType: "image/jpeg")
        let output: URL
        if drag {
            let stager = DragOutStager(
                fileProvider: provider, stagingDirectory: directory.appendingPathComponent("drag"), safetyMarginBytes: 0
            )
            let decision = await stager.beginPrefetch(items: [photo])
            XCTAssertTrue(decision.isAllowed)
            output = try await stager.awaitStaged(uid: photo.uid).get()
        } else {
            output = directory.appendingPathComponent("export.jpg")
            try await OriginalExportWriter.writeSingle(item: photo, to: output, provider: provider) { _ in }
        }

        if storedPreference == false {
            XCTAssertNotNil(gpsProperties(at: output))
            XCTAssertEqual(try Data(contentsOf: output), originalBytes)
        } else {
            XCTAssertNil(gpsProperties(at: output))
            XCTAssertNil(iptcCity(at: output))
            XCTAssertEqual(lensModel(at: output), Self.lensModel)
        }
        XCTAssertNotNil(gpsProperties(at: original))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    private struct GPSFileProvider: OriginalFileProvider {
        let original: URL

        func writeOriginal(
            for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            try Data(contentsOf: original).write(to: destination)
            onProgress(1)
        }
    }

    func testImageCopyDropsGPSWhileStoredOriginalKeepsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // iPhone photos are HEIC; both formats must lose their location and keep everything else.
        for type in [UTType.jpeg, UTType.heic] {
            let ext = try XCTUnwrap(type.preferredFilenameExtension)
            let original = directory.appendingPathComponent("original.\(ext)")
            let shared = directory.appendingPathComponent("shared.\(ext)")
            try makeGPSImage(at: original, type: type)
            let originalBytes = try Data(contentsOf: original)

            try await LocationSanitizedCopy.write(from: original, to: shared)

            XCTAssertNotNil(gpsProperties(at: original), ext)
            XCTAssertNil(gpsProperties(at: shared), ext)
            XCTAssertNil(iptcCity(at: shared), ext)
            XCTAssertEqual(lensModel(at: shared), Self.lensModel, ext)
            XCTAssertEqual(try Data(contentsOf: original), originalBytes, ext)
        }
    }

    func testUnsupportedCopyFailsClosedWithoutWritingTheOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("unknown.bin")
        let shared = directory.appendingPathComponent("shared.bin")
        let bytes = Data("possible location metadata".utf8)
        try bytes.write(to: original)

        do {
            try await LocationSanitizedCopy.write(from: original, to: shared)
            XCTFail("Unknown formats must not leave the privacy gate with their bytes intact")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
            XCTAssertEqual(try Data(contentsOf: original), bytes)
        }
    }

    func testVideoCopyDropsLocationWhileStoredOriginalKeepsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mov")
        let shared = directory.appendingPathComponent("shared.mov")
        try await makeGPSVideo(at: original)
        let originalBytes = try Data(contentsOf: original)

        try await LocationSanitizedCopy.write(from: original, to: shared)

        let originalHasLocation = try await hasVideoLocation(at: original)
        let sharedHasLocation = try await hasVideoLocation(at: shared)
        XCTAssertTrue(originalHasLocation)
        XCTAssertFalse(sharedHasLocation)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    /// A staged download has no media extension. The movie must still open, like the motion video of a Live Photo
    /// that the share sheet and the drag stage as `.download` files.
    func testStagedMovieWithoutMediaExtensionLosesItsLocationAndKeepsItsPairing() async throws {
        let directory = try makeDirectory()
        let movie = directory.appendingPathComponent("IMG_0001.mov")
        try await makeGPSVideo(at: movie)
        let staged = directory.appendingPathComponent(".staged.download")
        try FileManager.default.moveItem(at: movie, to: staged)

        let written = try await LocationSanitizedCopy.write(
            from: staged, to: directory.appendingPathComponent("IMG_0001.MOV"))

        XCTAssertEqual(written.lastPathComponent, "IMG_0001.MOV")
        let hasLocation = try await hasVideoLocation(at: written)
        let identifier = try await movieContentIdentifier(at: written)
        XCTAssertFalse(hasLocation)
        XCTAssertEqual(identifier, Self.livePhotoContentIdentifier)
    }

    /// A photo or movie without location leaves as its original bytes, whatever its format.
    func testCopiesWithoutLocationKeepTheOriginalBytes() async throws {
        let directory = try makeDirectory()
        let photo = directory.appendingPathComponent("plain.png")
        try makeImage(at: photo, type: .png, gps: false)
        let movie = directory.appendingPathComponent("plain.download")
        try await makeVideo(at: directory.appendingPathComponent("plain.mov"), location: false)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("plain.mov"), to: movie)

        let sharedPhoto = try await LocationSanitizedCopy.write(
            from: photo, to: directory.appendingPathComponent("shared.png"))
        let sharedMovie = try await LocationSanitizedCopy.write(
            from: movie, to: directory.appendingPathComponent("shared.mov"))

        XCTAssertEqual(try Data(contentsOf: sharedPhoto), try Data(contentsOf: photo))
        XCTAssertEqual(try Data(contentsOf: sharedMovie), try Data(contentsOf: movie))
    }

    /// Every photo format that ImageIO writes keeps its format and loses its location.
    func testEveryWritablePhotoFormatLosesItsLocation() async throws {
        let directory = try makeDirectory()
        for type in [UTType.jpeg, .heic, .png, .tiff, UTType("public.avif")!] {
            let ext = try XCTUnwrap(type.preferredFilenameExtension)
            let original = directory.appendingPathComponent("original.\(ext)")
            try makeImage(at: original, type: type, gps: true)
            XCTAssertNotNil(gpsProperties(at: original), ext)

            let written = try await LocationSanitizedCopy.write(
                from: original, to: directory.appendingPathComponent("shared.\(ext)"))

            XCTAssertEqual(written.pathExtension, ext)
            XCTAssertNil(gpsProperties(at: written), ext)
        }
    }

    /// A photo format that ImageIO reads but cannot write, like RAW, DNG, or WebP, leaves as a JPEG without location.
    func testUnwritablePhotoFormatLeavesAsAJPEGWithoutLocation() async throws {
        let directory = try makeDirectory()
        let original = directory.appendingPathComponent("original.jpg")
        try makeGPSImage(at: original)

        let written = try await LocationSanitizedCopy.write(
            from: original, to: directory.appendingPathComponent("IMG_0001.dng"), writableImageTypes: [])

        XCTAssertEqual(written.lastPathComponent, "IMG_0001.jpg")
        XCTAssertNil(gpsProperties(at: written))
        XCTAssertNil(iptcCity(at: written))
        XCTAssertEqual(lensModel(at: written), Self.lensModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("IMG_0001.dng").path))
    }

    func testOutputNamesFollowTheFormatThatLeaves() {
        XCTAssertEqual(LocationSanitizedCopy.outputFilename(forOriginalName: "IMG_1.DNG"), "IMG_1.jpg")
        XCTAssertEqual(LocationSanitizedCopy.outputFilename(forOriginalName: "DSC_2.NEF"), "DSC_2.jpg")
        XCTAssertEqual(LocationSanitizedCopy.outputFilename(forOriginalName: "a.webp"), "a.jpg")
        XCTAssertEqual(LocationSanitizedCopy.outputFilename(forOriginalName: "IMG_3.HEIC"), "IMG_3.HEIC")
        XCTAssertEqual(LocationSanitizedCopy.outputFilename(forOriginalName: "clip.3gp"), "clip.mov")
        XCTAssertEqual(LocationSanitizedCopy.outputFilename(forOriginalName: "clip.mp4"), "clip.mp4")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A Live Photo pairs its still and its movie by this identifier; a copy without location must keep it.
    func testCopiesKeepTheLivePhotoPairingIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("IMG_0001.heic")
        let movie = directory.appendingPathComponent("IMG_0001.mov")
        try makeGPSImage(at: still, type: .heic)
        try await makeGPSVideo(at: movie)
        let sharedStill = directory.appendingPathComponent("shared.heic")
        let sharedMovie = directory.appendingPathComponent("shared.mov")

        try await LocationSanitizedCopy.write(from: still, to: sharedStill)
        try await LocationSanitizedCopy.write(from: movie, to: sharedMovie)

        XCTAssertNil(gpsProperties(at: sharedStill))
        XCTAssertEqual(stillContentIdentifier(at: sharedStill), Self.livePhotoContentIdentifier)
        let sharedHasLocation = try await hasVideoLocation(at: sharedMovie)
        let sharedIdentifier = try await movieContentIdentifier(at: sharedMovie)
        XCTAssertFalse(sharedHasLocation)
        XCTAssertEqual(sharedIdentifier, Self.livePhotoContentIdentifier)
    }

    private static let livePhotoContentIdentifier = "6F1C1D2E-0000-4000-8000-00000000A11E"
    private static let lensModel = "Test lens"

    private func iptcCity(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        else { return nil }
        return iptc[kCGImagePropertyIPTCCity] as? String
    }

    private func lensModel(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifLensModel] as? String
    }

    private func stillContentIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        return apple["17"] as? String
    }

    private func movieContentIdentifier(at url: URL) async throws -> String? {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        guard let item = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }) else {
            return nil
        }
        return try await item.load(.stringValue)
    }

    private func makeGPSImage(at url: URL, type: UTType = .jpeg) throws {
        try makeImage(at: url, type: type, gps: true)
        XCTAssertNotNil(gpsProperties(at: url))
        XCTAssertEqual(iptcCity(at: url), "Test City")
        XCTAssertEqual(stillContentIdentifier(at: url), Self.livePhotoContentIdentifier)
    }

    private func makeImage(at url: URL, type: UTType, gps withLocation: Bool) throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 12.25,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 45.5,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let apple: [String: Any] = ["17": Self.livePhotoContentIdentifier]
        var properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: apple,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: Self.lensModel],
        ]
        if withLocation {
            properties[kCGImagePropertyGPSDictionary] = gps
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCity: "Test City"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func gpsProperties(at url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    private func makeGPSVideo(at url: URL) async throws {
        try await makeVideo(at: url, location: true)
        let hasLocation = try await hasVideoLocation(at: url)
        XCTAssertTrue(hasLocation)
    }

    private func makeVideo(at url: URL, location withLocation: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+12.2500+045.5000/" as NSString
        let pairing = AVMutableMetadataItem()
        pairing.identifier = .quickTimeMetadataContentIdentifier
        pairing.value = Self.livePhotoContentIdentifier as NSString
        writer.metadata = withLocation ? [location, pairing] : [pairing]

        let width = 16
        let height = 16
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 0, CVPixelBufferGetDataSize(frame))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        XCTAssertTrue(adaptor.append(frame, withPresentationTime: .zero))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func hasVideoLocation(at url: URL) async throws -> Bool {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        return metadata.contains { $0.identifier == .quickTimeMetadataLocationISO6709 }
    }
}
