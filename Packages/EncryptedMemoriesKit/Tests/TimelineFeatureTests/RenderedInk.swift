import CoreGraphics
import SwiftUI
import Testing

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
        let bytes = try rawPixels(of: framed, width: width, height: height)
        var ink = 0
        for pixel in bytes {
            if pixel > 240 { continue }
            ink &+= 1
        }
        return ink
    }

    /// Renders `view` and returns its raw RGBA pixels without any composited background. Views that
    /// fill their own surface color stay comparable through pixel differences between two renders.
    @MainActor static func rawPixels<V: View>(
        _ view: V, width: CGFloat = 480, height: CGFloat = 360
    ) throws -> [UInt8] {
        try rawPixels(
            of: view.frame(width: width, height: height).environment(\.colorScheme, .light),
            width: width, height: height)
    }

    @MainActor private static func rawPixels<V: View>(of view: V, width: CGFloat, height: CGFloat) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw RenderError.noImage }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw RenderError.noContext }
        return bytes
    }

    /// Renders until two consecutive renders agree and returns that render. A render can differ from the
    /// one before it for a moment, so one difference is tolerated. A view that does not settle within
    /// `attempts` renders is not deterministic, and this throws. Every difference is printed with its
    /// screen area under `logTag`, so an occurrence can be found in a log. Tests of this helper pass their own tag.
    @MainActor static func stablePixels(
        attempts: Int = 5, width: Int = 480, label: String, logTag: String = "RENDER_DIFFERENCE",
        render: () throws -> [UInt8]
    ) throws -> [UInt8] {
        var previous = try render()
        for attempt in 1..<max(2, attempts) {
            let next = try render()
            let offsets = differingPixelOffsets(previous, next)
            if offsets.isEmpty { return next }
            let columns = offsets.map { ($0 / 4) % width }
            let rows = offsets.map { ($0 / 4) / width }
            print(
                "\(logTag) label=\(label) render=\(attempt + 1) pixels=\(offsets.count) "
                    + "x=\(columns.min()!)...\(columns.max()!) y=\(rows.min()!)...\(rows.max()!)")
            previous = next
        }
        throw RenderError.unstable(label)
    }

    /// Offsets of pixels whose color differs between two same-sized RGBA renders.
    static func differingPixelOffsets(_ lhs: [UInt8], _ rhs: [UInt8]) -> [Int] {
        precondition(lhs.count == rhs.count)
        var offsets: [Int] = []
        for offset in stride(from: 0, to: lhs.count, by: 4) {
            if lhs[offset] != rhs[offset]
                || lhs[offset + 1] != rhs[offset + 1]
                || lhs[offset + 2] != rhs[offset + 2]
            {
                offsets.append(offset)
            }
        }
        return offsets
    }

    enum RenderError: Error {
        case noImage
        case noContext
        case unstable(String)
    }
}
