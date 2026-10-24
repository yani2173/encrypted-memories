import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

enum LocatedShareTestImage {
    static let lensModel = "Share test lens"

    static func makeLocatedJPEG() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 12.25, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.5, kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: lensModel],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func imageProperties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func locationProperties(of data: Data) -> [CFString: Any]? {
        imageProperties(of: data)?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    static func lensModel(of data: Data) -> String? {
        (imageProperties(of: data)?[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel]
            as? String
    }
}
