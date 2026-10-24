import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ProtonDriveBackend

/// Uploaded thumbnails and previews are opaque 8-bit JPEGs in sRGB or Display P3 (#269). HDR content is anchored at
/// its reference white (ITU-R BT.2408), and every other source that is not sRGB or Display P3 is converted to sRGB, so
/// a viewer that ignores an embedded profile still shows sRGB thumbnails correctly. Expected colours are fixed values,
/// never a render of the source by the same conversion.
@Suite("Upload thumbnail colour", .serialized)
struct UploadMediaProcessorTests {
    private static let tolerance = 6
    /// The sRGB colour of every SDR source.
    private static let fill = [199, 46, 46]
    private static let opaque8 = CGImageAlphaInfo.noneSkipLast.rawValue
    private static let halfFloat =
        CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue

    // MARK: HDR

    /// BT.2408: reference white (HLG 0.75, PQ 0.58) shows as SDR white, 18 % grey (signal 0.38) as linear 0.128.
    @Test(arguments: [
        ("HLG reference white", 0.75, 255), ("HLG 18% grey", 0.38, 101),
        ("PQ reference white", 0.58, 255), ("PQ 18% grey", 0.38, 100),
    ])
    func hdrStillsShowReferenceWhiteAsSDRWhite(name: String, signal: Double, expected: Int) async throws {
        let spaceName = name.hasPrefix("HLG") ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_2100_PQ
        let space = try #require(CGColorSpace(name: spaceName))
        let image = try Self.signalImage(space, signal: signal)
        let thumbnails = try await Self.thumbnails(ofStill: image)
        #expect(thumbnails.count == 2)
        for (type, data) in thumbnails {
            let shown = try Self.shownSRGB(data, expectingName: CGColorSpace.sRGB)
            #expect(Self.isClose(shown, [expected, expected, expected]), "\(name) \(type): \(shown)")
        }
    }

    /// An HLG video (iPhone records HDR video as HLG) takes the same conversion through its video frame.
    @Test(arguments: [(0.75, 255), (0.38, 101)])
    func hlgVideoFrameShowsReferenceWhiteAsSDRWhite(signal: Double, expected: Int) async throws {
        let hlg = try #require(CGColorSpace(name: CGColorSpace.itur_2100_HLG))
        let url = try Self.clip(
            transfer: AVVideoTransferFunction_ITU_R_2100_HLG, primaries: AVVideoColorPrimaries_ITU_R_2020,
            matrix: AVVideoYCbCrMatrix_ITU_R_2020, space: hlg, value: signal)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumbnails = await UploadMediaProcessor.thumbnails(for: url, isVideo: true)
        #expect(thumbnails.count == 1)
        let shown = try Self.shownSRGB(try #require(thumbnails.first).data, expectingName: CGColorSpace.sRGB)
        #expect(Self.isClose(shown, [expected, expected, expected]), "\(shown)")
    }

    /// An ordinary SDR video frame is BT.709. Its code value 0.5 shows as sRGB 139 (Apple's video gamma 1.961).
    @Test func sdrVideoFrameIsConvertedToSRGB() async throws {
        let bt709 = try #require(CGColorSpace(name: CGColorSpace.itur_709))
        let url = try Self.clip(
            transfer: AVVideoTransferFunction_ITU_R_709_2, primaries: AVVideoColorPrimaries_ITU_R_709_2,
            matrix: AVVideoYCbCrMatrix_ITU_R_709_2, space: bt709, value: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumbnails = await UploadMediaProcessor.thumbnails(for: url, isVideo: true)
        let shown = try Self.shownSRGB(try #require(thumbnails.first).data, expectingName: CGColorSpace.sRGB)
        #expect(Self.isClose(shown, [139, 139, 139]), "\(shown)")
    }

    // MARK: SDR

    /// Sources whose colour space is not sRGB or Display P3 are converted to sRGB and keep their colour.
    @Test(arguments: ["BT.2020 16-bit", "BT.2020 8-bit", "linear sRGB", "unnamed Display P3 profile", "Adobe RGB"])
    func otherSDRSourcesAreConvertedToSRGB(name: String) async throws {
        let (space, bits): (CGColorSpace, Int) =
            switch name {
            case "BT.2020 16-bit": (try #require(CGColorSpace(name: CGColorSpace.itur_2020)), 16)
            case "BT.2020 8-bit": (try #require(CGColorSpace(name: CGColorSpace.itur_2020)), 8)
            case "linear sRGB": (try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB)), 16)
            case "Adobe RGB": (try #require(CGColorSpace(name: CGColorSpace.adobeRGB1998)), 8)
            default: (try Self.unnamedDisplayP3(), 8)
            }
        let image = try Self.filledImage(space, bits: bits, color: Self.fill)
        for (type, data) in try await Self.thumbnails(ofStill: image) {
            let shown = try Self.shownSRGB(data, expectingName: CGColorSpace.sRGB)
            #expect(Self.isClose(shown, Self.fill), "\(name) \(type): \(shown)")
        }
    }

    /// A grey photo becomes an sRGB JPEG; its grey stays.
    @Test func greySourceIsConvertedToSRGB() async throws {
        let grey = [128, 128, 128]
        let alpha = CGImageAlphaInfo.none.rawValue
        let image = try Self.filledImage(CGColorSpaceCreateDeviceGray(), bits: 8, color: grey, bitmapInfo: alpha)
        for (type, data) in try await Self.thumbnails(ofStill: image) {
            let shown = try Self.shownSRGB(data, expectingName: CGColorSpace.sRGB)
            #expect(Self.isClose(shown, grey), "\(type): \(shown)")
        }
    }

    /// sRGB and Display P3 sources keep their colour space, also at 16 bits per component; the JPEG has 8.
    @Test(arguments: [("sRGB", 8), ("Display P3", 8), ("sRGB", 16), ("Display P3", 16)])
    func sRGBAndDisplayP3SourcesKeepTheirColourSpace(spaceLabel: String, bits: Int) async throws {
        let spaceName = spaceLabel == "sRGB" ? CGColorSpace.sRGB : CGColorSpace.displayP3
        // 16-bit integer components: ImageIO decodes float components into the extended variant of a space.
        let info = bits == 16 ? Self.opaque8 | CGBitmapInfo.byteOrder16Little.rawValue : Self.opaque8
        let image = try Self.filledImage(
            try #require(CGColorSpace(name: spaceName)), bits: bits, color: Self.fill, bitmapInfo: info)
        for (type, data) in try await Self.thumbnails(ofStill: image) {
            let shown = try Self.shownSRGB(data, expectingName: spaceName)
            #expect(Self.isClose(shown, Self.fill), "\(spaceLabel) \(bits) \(type): \(shown)")
        }
    }

    /// A source with an alpha channel is flattened onto black, as before: (199, 46, 46) at alpha 0.5 shows as
    /// about (100, 23, 23).
    @Test func alphaSourceIsFlattenedOntoBlack() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
        let image = try Self.filledImage(space, bits: 8, color: Self.fill, alpha: 0.5, bitmapInfo: alpha)
        for (type, data) in try await Self.thumbnails(ofStill: image) {
            let decoded = try Self.decode(data)
            #expect([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo), "\(type)")
            let shown = try Self.shownSRGB(data, expectingName: CGColorSpace.sRGB)
            #expect(Self.isClose(shown, [100, 23, 23], tolerance: 4), "\(type): \(shown)")
        }
    }

    // MARK: Limits

    /// When a source that needs a conversion cannot be converted, the thumbnail is omitted instead of uploaded with
    /// the wrong colours. A source that needs no conversion still falls back to the unconverted image.
    @Test func failedConversionOmitsTheThumbnail() throws {
        let failing: (CGImage, Int, Int, CGColorSpace, Bool) -> CGImage? = { _, _, _, _, _ in nil }
        let hlg = try Self.signalImage(try #require(CGColorSpace(name: CGColorSpace.itur_2100_HLG)), signal: 0.75)
        let bt2020Space = try #require(CGColorSpace(name: CGColorSpace.itur_2020))
        let bt2020 = try Self.filledImage(bt2020Space, bits: 8, color: Self.fill)
        let sRGB = try Self.filledImage(try #require(CGColorSpace(name: CGColorSpace.sRGB)), bits: 8, color: Self.fill)
        #expect(UploadMediaProcessor.sdrImage(of: hlg, maxPixel: 512, draw: failing) == nil)
        #expect(UploadMediaProcessor.sdrImage(of: bt2020, maxPixel: 512, draw: failing) == nil)
        #expect(UploadMediaProcessor.sdrImage(of: sRGB, maxPixel: 512, draw: failing) === sRGB)
    }

    /// One HDR conversion at a time: a second one waits. An SDR source never waits for the HDR gate.
    @Test func hdrConversionsRunOneAtATime() async throws {
        let gate = UploadMediaProcessor.hdrConversions
        let hlg = try Self.signalImage(try #require(CGColorSpace(name: CGColorSpace.itur_2100_HLG)), signal: 0.75)
        let hdrURL = try Self.tiff(hlg)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let sdrURL = try Self.tiff(try Self.filledImage(sRGB, bits: 8, color: Self.fill))
        defer {
            try? FileManager.default.removeItem(at: hdrURL)
            try? FileManager.default.removeItem(at: sdrURL)
        }
        await gate.acquire()
        var holdsGate = true
        defer { if holdsGate { gate.release() } }
        let held = Task { await UploadMediaProcessor.thumbnails(for: hdrURL, isVideo: false) }
        #expect(try await Self.waitUntil { gate.waitingCount == 1 }, "a second HDR conversion must wait for the first")
        let sdr = await UploadMediaProcessor.thumbnails(for: sdrURL, isVideo: false)
        #expect(sdr.count == 2, "an SDR source does not take the HDR gate")
        holdsGate = false
        gate.release()
        #expect(await held.value.count == 2)
        #expect(gate.waitingCount == 0)
    }

    /// A cancelled HDR upload (pause, sign-out) converts nothing once it gets the gate, and frees it at once.
    @Test func aCancelledHDRUploadSkipsItsConversionAndFreesTheGate() async throws {
        let gate = UploadMediaProcessor.hdrConversions
        let hlg = try Self.signalImage(try #require(CGColorSpace(name: CGColorSpace.itur_2100_HLG)), signal: 0.75)
        let hdrURL = try Self.tiff(hlg)
        defer { try? FileManager.default.removeItem(at: hdrURL) }
        await gate.acquire()
        var holdsGate = true
        defer { if holdsGate { gate.release() } }
        let cancelled = Task { await UploadMediaProcessor.thumbnails(for: hdrURL, isVideo: false) }
        #expect(try await Self.waitUntil { gate.waitingCount == 1 })
        cancelled.cancel()
        holdsGate = false
        gate.release()
        #expect(await cancelled.value.isEmpty, "a cancelled upload must not convert")
        let admitted = AdmissionFlag()
        let next = Task {
            await gate.acquire()
            admitted.set()
            gate.release()
        }
        let free = try await Self.waitUntil { admitted.isSet }
        #expect(free, "the gate is free after the cancelled upload")
        if !free { gate.release() }
        await next.value
    }

    /// The gate admits waiters in arrival order: three waiters queued one after another get in in that order.
    @Test func gateAdmitsWaitersInArrivalOrder() async throws {
        let gate = UploadHDRConversionGate()
        await gate.acquire()
        var holdsGate = true
        defer { if holdsGate { gate.release() } }
        let order = AdmissionOrder()
        var waiters: [Task<Void, Never>] = []
        for index in 0..<3 {
            waiters.append(
                Task {
                    await gate.acquire()
                    order.append(index)
                    gate.release()
                })
            #expect(try await Self.waitUntil { gate.waitingCount == index + 1 })
        }
        holdsGate = false
        gate.release()
        for waiter in waiters { await waiter.value }
        #expect(order.values == [0, 1, 2])
        #expect(gate.waitingCount == 0)
    }

    /// A holder that is cancelled still releases the gate in its `defer`, so the next waiter gets in.
    @Test func gateIsReleasedAfterACancelledHolder() async throws {
        let gate = UploadHDRConversionGate()
        let holding = AdmissionFlag()
        let holder = Task {
            await gate.acquire()
            defer { gate.release() }
            holding.set()
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(try await Self.waitUntil { holding.isSet })
        let admitted = AdmissionFlag()
        let next = Task {
            await gate.acquire()
            admitted.set()
            gate.release()
        }
        #expect(try await Self.waitUntil { gate.waitingCount == 1 })
        holder.cancel()
        await holder.value
        let free = try await Self.waitUntil { admitted.isSet }
        #expect(free, "the next waiter gets in after the cancelled holder")
        if !free { gate.release() }
        await next.value
    }

    // MARK: Helpers

    /// Polls `condition` for up to ten seconds, a bound that only stops a hung test.
    private static func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A 2,400 x 1,600 HDR image of one grey signal value, written exactly as half floats.
    private static func signalImage(_ space: CGColorSpace, signal: Double) throws -> CGImage {
        let width = 2_400
        let height = 1_600
        let value = Float16(signal)
        var pixels = [Float16](repeating: value, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 1 }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: halfFloat), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
    }

    /// A 2,400 x 1,600 image in `space` filled with the sRGB colour `color`.
    private static func filledImage(
        _ space: CGColorSpace, bits: Int, color: [Int], alpha: CGFloat = 1, bitmapInfo: UInt32? = nil
    ) throws -> CGImage {
        let info = bitmapInfo ?? (bits == 16 ? halfFloat : opaque8)
        let context = try #require(
            CGContext(
                data: nil, width: 2_400, height: 1_600, bitsPerComponent: bits, bytesPerRow: 0, space: space,
                bitmapInfo: info))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let components = color.map { CGFloat($0) / 255 } + [alpha]
        context.setFillColor(try #require(CGColor(colorSpace: sRGB, components: components)))
        context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_600))
        return try #require(context.makeImage())
    }

    /// Display P3 whose profile header differs, so CoreGraphics does not recognize it as the named space.
    private static func unnamedDisplayP3() throws -> CGColorSpace {
        var icc = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()) as Data
        icc.replaceSubrange(80..<84, with: Array("XTST".utf8))
        for index in 84..<100 { icc[index] = 0 }
        let space = try #require(CGColorSpace(iccData: icc as CFData))
        #expect(space.name == nil)
        return space
    }

    private static func tiff(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-thumbnail-colour-\(UUID().uuidString).tiff")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Writes `image` as a TIFF with its colour profile and runs the production upload thumbnail path on it.
    private static func thumbnails(ofStill image: CGImage) async throws -> [(type: String, data: Data)] {
        let url = try tiff(image)
        defer { try? FileManager.default.removeItem(at: url) }
        return await UploadMediaProcessor.thumbnails(for: url, isVideo: false).map { ("\($0.type)", $0.data) }
    }

    /// A three-frame ProRes clip of one grey `value` in the given transfer, written in the test.
    private static func clip(
        transfer: String, primaries: String, matrix: String, space: CGColorSpace, value: Double
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-thumbnail-clip-\(UUID().uuidString).mov")
        let width = 320
        let height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer,
                    AVVideoYCbCrMatrixKey: matrix,
                ],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            let pool = try #require(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float16.self)
            let rowLength = CVPixelBufferGetBytesPerRow(buffer) / 2
            for row in 0..<height {
                for column in 0..<width {
                    let offset = row * rowLength + column * 4
                    base[offset] = Float16(value)
                    base[offset + 1] = Float16(value)
                    base[offset + 2] = Float16(value)
                    base[offset + 3] = 1
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries as CFString, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    private static func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Checks the 8-bit JPEG and its colour space name, then draws its centre into a known 8-bit RGBA sRGB context.
    private static func shownSRGB(_ data: Data, expectingName name: CFString) throws -> [Int] {
        let image = try decode(data)
        #expect(image.bitsPerComponent == 8)
        #expect(image.colorSpace?.name == name)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .none
        let centre = try #require(
            image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        context.draw(centre, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Int(pixel[$0]) }
    }

    private static func isClose(_ lhs: [Int], _ rhs: [Int], tolerance: Int = tolerance) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

/// Records that a task got past the gate.
private final class AdmissionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

/// Records the order in which tasks got past the gate.
private final class AdmissionOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var values: [Int] { lock.withLock { recorded } }

    func append(_ value: Int) { lock.withLock { recorded.append(value) } }
}
