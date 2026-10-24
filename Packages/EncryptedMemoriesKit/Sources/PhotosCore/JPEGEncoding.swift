import CoreGraphics
import Foundation
import ImageIO

/// Encodes a decoded image as JPEG data, for previews of media that only exists on the device.
public enum JPEGEncoding {
    /// The JPEG data of `image` at the lossy compression `quality`, or `nil` when ImageIO cannot encode it.
    public static func data(from image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        // "public.jpeg" is `UTType.jpeg.identifier`; PhotosCore does not import UniformTypeIdentifiers.
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
