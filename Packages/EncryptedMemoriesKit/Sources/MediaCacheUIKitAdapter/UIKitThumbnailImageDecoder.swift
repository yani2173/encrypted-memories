#if canImport(UIKit)
    import MediaDecodingCore
    import UIKit

    enum UIKitThumbnailImageDecoder {
        static func image(from decoded: DecodedThumbnail) -> UIImage {
            UIImage(cgImage: decoded.image, scale: 1, orientation: .up)
        }
    }
#endif
