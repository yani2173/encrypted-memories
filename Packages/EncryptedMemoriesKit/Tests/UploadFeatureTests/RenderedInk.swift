import CoreGraphics
import SwiftUI

/// Renders a SwiftUI view on a white surface in the light scheme and counts the pixels that are not white. Text
/// and symbols draw ink; the system progress indicator does not render, so this measures drawn content, not controls.
enum RenderedInk {
    @MainActor static func pixels<V: View>(
        _ view: V, width: CGFloat = 480, height: CGFloat = 360
    ) throws -> Int {
        let framed =
            view
            .frame(width: width, height: height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw RenderError.noImage }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw RenderError.noContext }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, offset in
            count + (bytes[offset] < 200 || bytes[offset + 1] < 200 || bytes[offset + 2] < 200 ? 1 : 0)
        }
    }

    enum RenderError: Error {
        case noImage
        case noContext
    }
}
