import CoreGraphics
import GridCore
import Metal
import Testing

@testable import MetalGridTextureCore

@Suite struct MetalGridUploadBadgeImageTests {
    private static let side = 64

    /// RGBA bytes of `image`, row 0 at the top.
    private func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: Self.side, height: Self.side, bitsPerComponent: 8,
                bytesPerRow: Self.side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        }
        return bytes
    }

    /// Red channel and alpha at `x`, `y` from the top-left corner.
    private func sample(_ bytes: [UInt8], x: Int, y: Int) -> (red: UInt8, alpha: UInt8) {
        let offset = (y * Self.side + x) * 4
        return (bytes[offset], bytes[offset + 3])
    }

    @Test func pausedGlyphDrawsTwoWhiteBarsInTheEmptyCircle() throws {
        let paused = pixels(of: try #require(MetalGridUploadBadgeImage.make(.paused, pixelSize: Self.side)))
        let empty = pixels(of: try #require(MetalGridUploadBadgeImage.make(.pie(0), pixelSize: Self.side)))
        let center = Self.side / 2
        for x in [center - 6, center + 6] {
            #expect(sample(paused, x: x, y: center) == (255, 255), "a white bar at x \(x)")
            #expect(sample(empty, x: x, y: center).red == 0, "the empty circle is dark there")
        }
        #expect(sample(paused, x: center, y: center).red == 0, "a dark gap between the bars")
        let above = center - 14
        #expect(sample(paused, x: center, y: above) == sample(empty, x: center, y: above), "bars stay short")
        // The circle outline is the same as on every other badge.
        #expect(sample(paused, x: center, y: 4) == sample(empty, x: center, y: 4))
    }

    @Test @MainActor func pausedGlyphIsItsOwnCachedTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // no GPU (CI) to skip
        let rasterizer = CountingRasterizer()
        let cache = try #require(
            MetalGridTextureCache<Int>(
                device: device,
                budget: GridTextureBudget(
                    maxUploadsPerFrame: 8, maxUploadBytesPerFrame: 1_000_000,
                    maxCachedTextures: 16, maxResidentBytes: 1_000_000, overscanFraction: 1.0
                ),
                maxTexturePixels: 64,
                glyphRasterizer: rasterizer
            ))
        let paused = try #require(cache.uploadBadgeTexture(.paused))
        let empty = try #require(cache.uploadBadgeTexture(.pie(0)))
        #expect(paused !== empty, "the paused badge never reuses the waiting circle")
        #expect(cache.uploadBadgeTexture(.paused) === paused, "every paused tile shares one texture")
        #expect(rasterizer.requests == [MetalGridGlyphRequest(uploadBadge: .paused), .init(uploadBadge: .pie(0))])
    }
}

private final class CountingRasterizer: MetalGridGlyphRasterizing {
    private(set) var requests: [MetalGridGlyphRequest] = []

    func image(for request: MetalGridGlyphRequest) -> CGImage? {
        requests.append(request)
        guard case .uploadBadge(let glyph) = request.content else { return nil }
        return MetalGridUploadBadgeImage.make(glyph, pixelSize: request.pixelSize)
    }
}
