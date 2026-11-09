import AVFoundation
import Foundation
import PhotosCore
import Testing

/// Tests for the native video playback pipeline (detection, byte-range math, cache merge, error
/// mapping, state-machine liveness). All pure - no AVFoundation / network - so they're deterministic.
@Suite("Video playback")
struct VideoPlaybackTests {
    @Test func detectsByExtension() {
        #expect(VideoContentSniffer.kind(filename: "clip.mp4") == .video)
        #expect(VideoContentSniffer.kind(filename: "clip.MOV") == .video)
        #expect(VideoContentSniffer.kind(filename: "clip.m4v") == .video)
        #expect(VideoContentSniffer.kind(filename: "photo.jpg") == .image)
        #expect(VideoContentSniffer.kind(filename: "photo.HEIC") == .image)
        #expect(VideoContentSniffer.kind(filename: "mystery.bin") == .unknown)
    }

    @Test func detectsByMime() {
        #expect(VideoContentSniffer.kind(mimeType: "video/quicktime") == .video)
        #expect(VideoContentSniffer.kind(mimeType: "image/png") == .image)
        // The timeline's generic placeholder must not short-circuit to image - it's untrustworthy.
        #expect(VideoContentSniffer.kind(mimeType: "") == .unknown)
    }

    @Test func unknownExtensionUsesContentSniff() {
        // An extensionless name plus a real MP4 `ftyp` header is classified as video.
        let header = ftypHeader(brand: "isom")
        #expect(VideoContentSniffer.classify(mimeType: "image/jpeg", filename: "IMG_0001", header: header) == .image)
        // When MIME and name are both unknown, the header decides.
        #expect(VideoContentSniffer.classify(mimeType: nil, filename: "IMG_0001", header: header) == .video)
        #expect(VideoContentSniffer.classify(mimeType: nil, filename: nil, header: jpegHeader()) == .image)
    }

    @Test func sniffsContainerExtension() {
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "isom")) == "mp4")
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "mp42")) == "mp4")
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "qt  ")) == "mov")
        // A non-container returns nil so the caller can apply its default.
        #expect(VideoContentSniffer.videoExtension(forHeader: jpegHeader()) == nil)
        #expect(VideoContentSniffer.videoExtension(forHeader: Data([0, 1, 2])) == nil)
        // HEIC is an ftyp box but an image, not a playable video container.
        #expect(VideoContentSniffer.headerIsImage(ftypHeader(brand: "heic")))
        #expect(!VideoContentSniffer.headerIsVideo(ftypHeader(brand: "heic")))
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "heic")) == nil)
        #expect(VideoContentSniffer.classify(mimeType: nil, filename: nil, header: ftypHeader(brand: "heic")) == .image)
    }

    /// 3 blocks of 100 bytes each (indices 1..3), total 300.
    private var map: VideoBlockMap {
        VideoBlockMap(blockSizes: [(1, 100), (2, 100), (3, 100)], totalOverride: 300)
    }

    @Test func sliceWithinSingleBlock() {
        let slices = map.slices(offset: 10, length: 20)  // [10,30) - all inside block 1
        #expect(slices.count == 1)
        #expect(slices[0].blockIndex == 1)
        #expect(slices[0].inBlock == ByteRange(lower: 10, upper: 30))
        #expect(slices[0].fileOffset == 10)
    }

    @Test func sliceSpanningBlocks() {
        let slices = map.slices(offset: 90, length: 120)  // [90,210) - blocks 1,2,3
        #expect(slices.map(\.blockIndex) == [1, 2, 3])
        // Contiguity: concatenated slice lengths == requested length.
        #expect(slices.reduce(0) { $0 + $1.inBlock.length } == 120)
        #expect(slices[0].inBlock == ByteRange(lower: 90, upper: 100))
        #expect(slices[1].inBlock == ByteRange(lower: 0, upper: 100))
        #expect(slices[2].inBlock == ByteRange(lower: 0, upper: 10))
    }

    @Test func sliceClampsToFileSize() {
        let slices = map.slices(offset: 250, length: 1000)  // clamps to [250,300)
        #expect(slices.reduce(0) { $0 + $1.inBlock.length } == 50)
        #expect(slices.last?.blockIndex == 3)
        #expect(map.slices(offset: 300, length: 10).isEmpty)  // fully past EOF
    }

    @Test func repeatedAndOverlappingRequestsAreDeterministic() {
        // Asking twice (overlapping) yields identical slices - the loader can dedup against its cache.
        #expect(map.slices(offset: 50, length: 100) == map.slices(offset: 50, length: 100))
        let a = map.slices(offset: 0, length: 150)
        let b = map.slices(offset: 100, length: 50)
        // The overlap region (block 2) maps to the same block index in both.
        #expect(a.contains { $0.blockIndex == 2 })
        #expect(b.contains { $0.blockIndex == 2 })
    }

    @Test func seekRequestsOnlyTheNeededBlocks() {
        // A seek to the last block must not re-pull earlier blocks.
        let indices = map.slices(offset: 220, length: 40).map(\.blockIndex)  // inside block 3
        #expect(indices == [3])
        // And an initial-play request for the head only touches block 1.
        #expect(map.slices(offset: 0, length: 50).map(\.blockIndex) == [1])
    }

    @Test func mapsNetworkErrors() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(VideoPlaybackError.classify(offline) == .networkUnavailable)
    }

    @Test func mapsCodecErrors() {
        let codec = NSError(domain: "AVFoundationErrorDomain", code: -11828)
        #expect(VideoPlaybackError.classify(codec) == .unsupportedCodec)
        #expect(VideoPlaybackError.unsupportedCodec.isRetryable == false)
    }

    @Test func aDecoderThatIsTemporarilyUnavailableKeepsRetry() {
        // The numeric codes come from AVFoundation, so a change of the SDK shows here.
        let temporary = NSError(
            domain: AVFoundationErrorDomain, code: AVError.Code.decoderTemporarilyUnavailable.rawValue)
        let classified = VideoPlaybackError.classify(temporary)
        #expect(classified != .unsupportedCodec)
        #expect(classified.isRetryable)
        for code in [AVError.Code.fileFormatNotRecognized, .fileFailedToParse, .decoderNotFound] {
            let permanent = NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
            #expect(VideoPlaybackError.classify(permanent) == .unsupportedCodec)
        }
    }

    @Test func mapsHTTPStatusErrors() {
        #expect(VideoPlaybackError.classify(apiError(401)) == .authExpired)
        #expect(VideoPlaybackError.classify(apiError(429)) == .quotaOrRateLimited)
        #expect(VideoPlaybackError.classify(apiError(416)) == .rangeNotSupported)
    }

    @Test func decryptionFailureComesFromTheTypeOfTheErrorNotFromItsText() {
        struct Typed: VideoPlaybackClassifiable {
            var videoPlaybackError: VideoPlaybackError? { .decryptionFailed }
        }
        let text = NSError(
            domain: "Custom", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "block decrypt failed"])
        #expect(VideoPlaybackError.classify(Typed()) == .decryptionFailed)
        #expect(VideoPlaybackError.classify(text) != .decryptionFailed)
    }

    @Test func everyTerminalStatusLeavesLoading() {
        // Readiness is observable but does not claim playback. Only actual `.playing` ends the watchdog.
        #expect(VideoPlayerItemStatus.readyToPlay.nextState(error: nil) == .ready)
        #expect(VideoPlayerItemStatus.failed.nextState(error: nil) != nil)

        // Busy states are mutually exclusive with playing/failed; nothing is both "busy" and terminal.
        let states: [VideoViewerState] = [
            .idle, .resolving, .preparingStream, .downloading(0.5), .buffering(nil),
            .ready, .playing, .seeking, .failed(.timedOut),
        ]
        for s in states {
            if s.isBusy { #expect(s.error == nil && s != .playing) }
            if case .failed = s { #expect(!s.isBusy) }
            if s == .playing { #expect(!s.isBusy) }
        }
    }

    private func ftypHeader(brand: String) -> Data {
        var d = Data([0, 0, 0, 0x18])  // box size
        d.append(contentsOf: Array("ftyp".utf8))  // box type
        d.append(contentsOf: Array(brand.utf8).prefix(4))
        while d.count < 12 { d.append(0) }
        return d
    }

    private func jpegHeader() -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]) }

    private func apiError(_ status: Int) -> NSError {
        NSError(
            domain: "ProtonAuth", code: status,
            userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) for /drive/x"])
    }
}
