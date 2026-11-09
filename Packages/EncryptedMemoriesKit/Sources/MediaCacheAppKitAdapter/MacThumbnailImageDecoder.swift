import AppKit
import MediaDecodingCore

enum MacThumbnailImageDecoder {
    static func image(from decoded: DecodedThumbnail) -> NSImage {
        NSImage(
            cgImage: decoded.image,
            size: NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)
        )
    }
}
