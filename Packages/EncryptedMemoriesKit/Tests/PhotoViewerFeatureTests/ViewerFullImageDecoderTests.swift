import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import UniformTypeIdentifiers
import XCTest

@testable import PhotoViewerCore

final class ViewerFullImageDecoderTests: XCTestCase {
    func testDecodesGeneratedPNGAsCGImageWithoutPlatformImageWrapper() throws {
        let data = try pngData(width: 3, height: 2)

        let image = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data))

        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
    }

    func testInvalidDataReturnsNil() {
        XCTAssertNil(ViewerFullImageDecoder.decodeCGImage(Data("not image data".utf8)))
    }

    func testBoundedDecodeCapsLongestSideAndNeverUpscales() throws {
        let data = try pngData(width: 200, height: 100)  // 200×100 original

        // A cap below the original downsamples proportionally (longest side == cap).
        let bounded = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data, maxPixelSize: 50))
        XCTAssertEqual(max(bounded.width, bounded.height), 50)
        XCTAssertLessThanOrEqual(bounded.width, 50)
        XCTAssertLessThanOrEqual(bounded.height, 50)

        // A cap above the original never upscales - full resolution is preserved, not enlarged.
        let notUpscaled = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data, maxPixelSize: 4096))
        XCTAssertEqual(notUpscaled.width, 200)
        XCTAssertEqual(notUpscaled.height, 100)

        // nil cap == full resolution (the zoom/export path is unchanged).
        let full = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data))
        XCTAssertEqual(full.width, 200)
        XCTAssertEqual(full.height, 100)
    }

    func testStreamedDecodeAcceptsBoundedChunksWithoutCallerAggregation() async throws {
        let data = try pngData(width: 200, height: 100)
        let decoded = try await ViewerFullImageDecoder.decodeStreamedCGImage(
            from: ChunkedOriginalProvider(data: data, chunkSize: 7),
            uid: PhotoUID(volumeID: "v", nodeID: "n"),
            maxPixelSize: 50,
            onProgress: { _ in }
        )
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(max(image.width, image.height), 50)
    }

    func testStreamedDecodeSuspendsAcrossBufferBoundaryAndRepeatedTeardown() async throws {
        let data = try pngData(width: 1_500, height: 1_200, usesNoise: true)
        XCTAssertGreaterThan(data.count, 4 * 1_024 * 1_024)

        for _ in 0..<3 {
            let decoded = try await ViewerFullImageDecoder.decodeStreamedCGImage(
                from: ChunkedOriginalProvider(data: data, chunkSize: data.count),
                uid: PhotoUID(volumeID: "v", nodeID: "large"),
                maxPixelSize: 240,
                onProgress: { _ in }
            )
            let image = try XCTUnwrap(decoded)
            XCTAssertEqual(max(image.width, image.height), 240)
        }
    }

    func testStreamedDecodeCancellationUnblocksImageIOConsumer() async throws {
        let data = try pngData(width: 200, height: 100)
        for iteration in 0..<5 {
            let probe = StreamExitProbe()
            let decode = Task {
                try await ViewerFullImageDecoder.decodeStreamedCGImage(
                    from: DelayedOriginalProvider(data: data, exitProbe: probe),
                    uid: PhotoUID(volumeID: "v", nodeID: "cancel-\(iteration)"),
                    maxPixelSize: 50,
                    onProgress: { _ in }
                )
            }

            try await Task.sleep(for: .milliseconds(20))
            decode.cancel()

            do {
                _ = try await decode.value
                XCTFail("cancelled streamed decode must throw")
            } catch is CancellationError {
                // Expected: cancellation must settle both the producer and the blocking ImageIO consumer.
            }
            XCTAssertTrue(probe.didExit, "Core must join the provider before returning from cancellation")
        }
    }

    func testStreamedDecodeSettlesEveryRapidStartAndCancel() async throws {
        let data = try pngData(width: 200, height: 100)
        for iteration in 0..<200 {
            let decode = Task {
                try await ViewerFullImageDecoder.decodeStreamedCGImage(
                    from: ChunkedOriginalProvider(data: data, chunkSize: 64),
                    uid: PhotoUID(volumeID: "v", nodeID: "rapid-\(iteration)"),
                    maxPixelSize: 50,
                    onProgress: { _ in }
                )
            }
            try await Task.sleep(for: .microseconds(Int.random(in: 0...2_000)))
            decode.cancel()
            do {
                let image = try await decode.value
                XCTAssertNotNil(image, "a decode that finished before the cancellation returns its image")
            } catch is CancellationError {
                // Expected when the cancellation arrived first.
            }
        }
    }

    func testStreamedDecodePropagatesProviderFailureAfterJoiningDecoder() async {
        do {
            _ = try await ViewerFullImageDecoder.decodeStreamedCGImage(
                from: FailingOriginalProvider(),
                uid: PhotoUID(volumeID: "v", nodeID: "failure"),
                maxPixelSize: 50,
                onProgress: { _ in }
            )
            XCTFail("provider failure must propagate")
        } catch StreamTestError.expected {
            // Expected.
        } catch {
            XCTFail("unexpected provider error: \(error)")
        }
    }

    private func pngData(width: Int, height: Int, usesNoise: Bool = false) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if usesNoise {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
                pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 32)
                pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 40)
            } else {
                pixels[index] = 255
            }
            pixels[index + 3] = 255
        }
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct ChunkedOriginalProvider: OriginalByteStreamProvider {
    let data: Data
    let chunkSize: Int

    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        for start in stride(from: 0, to: data.count, by: chunkSize) {
            try Task.checkCancellation()
            let end = min(start + chunkSize, data.count)
            try await onChunk(data.subdata(in: start..<end))
            onProgress(Double(end) / Double(data.count))
        }
    }
}

private struct DelayedOriginalProvider: OriginalByteStreamProvider {
    let data: Data
    let exitProbe: StreamExitProbe

    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        defer { exitProbe.markExited() }
        try await Task.sleep(for: .seconds(5))
        try await onChunk(data)
        onProgress(1)
    }
}

private struct FailingOriginalProvider: OriginalByteStreamProvider {
    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        throw StreamTestError.expected
    }
}

private enum StreamTestError: Error {
    case expected
}

private final class StreamExitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false

    var didExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func markExited() {
        lock.lock()
        exited = true
        lock.unlock()
    }
}
