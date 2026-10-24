import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PhotosCore

@Suite struct JPEGEncodingTests {
    @Test func encodesAnImageAsADecodableJPEG() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())

        let data = try #require(JPEGEncoding.data(from: image))

        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 2)
        #expect(decoded.height == 2)
    }
}
