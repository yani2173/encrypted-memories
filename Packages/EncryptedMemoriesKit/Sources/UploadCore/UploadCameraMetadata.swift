import Foundation
import ImageIO

/// Completes the Camera section of a photo upload with what the file itself states. Photos does not expose the
/// camera model or the EXIF orientation; the header of the original does. The info panel shows the model from
/// this section. Only a section that the source already wrote is completed, and a value the source set wins.
enum UploadCameraMetadata {
    static func completing(
        _ metadata: [PhotoUploadAdditionalMetadata], fileURL: URL
    ) -> [PhotoUploadAdditionalMetadata] {
        guard let index = metadata.firstIndex(where: { $0.name == "Camera" }),
            let camera = try? JSONDecoder().decode(
                PhotoUploadMetadataEncoder.Camera.self, from: metadata[index].utf8JsonValue),
            camera.device == nil || camera.orientation == nil,
            let embedded = embeddedCamera(at: fileURL)
        else { return metadata }
        let completed = PhotoUploadMetadataEncoder.Camera(
            captureTime: camera.captureTime,
            device: camera.device ?? embedded.device,
            orientation: camera.orientation ?? embedded.orientation,
            subjectCoordinates: camera.subjectCoordinates
        )
        guard completed != camera, let data = try? JSONEncoder().encode(completed) else { return metadata }
        var result = metadata
        result[index] = PhotoUploadAdditionalMetadata(name: "Camera", utf8JsonValue: data)
        return result
    }

    /// The camera model and EXIF orientation of an image file. Nil for a video or a file that states neither.
    static func embeddedCamera(at url: URL) -> (device: String?, orientation: Int?)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return nil }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = model?.isEmpty == false ? model : nil
        let exifOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        let orientation = exifOrientation.flatMap { (1...8).contains($0) ? $0 : nil }
        guard device != nil || orientation != nil else { return nil }
        return (device, orientation)
    }
}
