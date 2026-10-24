import Foundation
import ImageIO

/// Reads the camera model of an image file for the photo `Camera.Device` section.
///
/// Only the TIFF `Model` is read, the same field that Proton's own iOS app writes. ImageIO answers from the
/// image properties (the file header), so no pixels are decoded. The reader never looks at GPS tags or any
/// other field, and it returns nil for anything it cannot read.
public enum UploadCameraDeviceReader {
    /// Longest `Device` value in Unicode scalars. A longer value is cut.
    static let maxLength = 128

    public static func device(forImageAt url: URL) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any],
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
            let raw = tiff[kCGImagePropertyTIFFModel as String] as? String
        else {
            return nil
        }
        return normalized(raw)
    }

    /// Strips control characters, cuts the value to `maxLength` scalars, and trims white space.
    /// An empty result is nil, so a blank model never counts as a device.
    static func normalized(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.lazy
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(maxLength)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let trimmed = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension PhotoUploadMetadataEncoder {
    /// Fills `Camera.Device` from the image file when the sections carry none. A `Device` that is already set
    /// is never replaced, and the file is not read then. Videos, other media, and files without a readable
    /// model return `metadata` unchanged, so a missing or damaged file never fails the backup.
    public static func fillingCameraDevice(
        in metadata: [PhotoUploadAdditionalMetadata],
        mediaType: String,
        fileURL: URL,
        readDevice: (URL) -> String? = UploadCameraDeviceReader.device(forImageAt:)
    ) -> [PhotoUploadAdditionalMetadata] {
        guard mediaType.hasPrefix("image/") else { return metadata }
        let index = metadata.firstIndex { $0.name == "Camera" }
        var camera = Camera(captureTime: nil)
        if let index {
            guard let existing = try? JSONDecoder().decode(Camera.self, from: metadata[index].utf8JsonValue) else {
                return metadata
            }
            if let device = existing.device, !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return metadata
            }
            camera = existing
        }
        guard let device = readDevice(fileURL).flatMap(UploadCameraDeviceReader.normalized) else { return metadata }
        let filled = Camera(
            captureTime: camera.captureTime,
            device: device,
            orientation: camera.orientation,
            subjectCoordinates: camera.subjectCoordinates
        )
        guard let data = try? JSONEncoder().encode(filled) else { return metadata }
        let section = PhotoUploadAdditionalMetadata(name: "Camera", utf8JsonValue: data)
        var result = metadata
        if let index { result[index] = section } else { result.append(section) }
        return result
    }
}
