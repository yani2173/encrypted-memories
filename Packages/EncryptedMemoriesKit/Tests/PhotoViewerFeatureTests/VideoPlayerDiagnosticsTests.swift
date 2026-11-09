import AVFoundation
import Foundation
import PhotosCore
import Testing

@testable import PhotoViewerCore

/// The `[VideoPlayer]` diagnostic never carries the identifier of a video, like the preparation diagnostic.
@Suite("Video player diagnostics", .serialized)
struct VideoPlayerDiagnosticsTests {
    private let uid = PhotoUID(volumeID: "volume-secret-1", nodeID: "node-secret-2")

    @Test @MainActor func attachingAndTimingOutWriteNoIdentifier() async throws {
        let events = EventBox()
        let controller = VideoPlaybackController(
            firstFrameDeadline: 0.03, runtimeState: LibraryRuntimeState(),
            diagnostics: { events.append($0) })
        // A loader that never answers keeps the item in preparation, so the watchdog is what ends the attempt.
        let loader = SilentLoader()
        let asset = AVURLAsset(url: URL(string: "protonvideo://diagnostics/\(UUID().uuidString).mov")!)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "video-diagnostics-test"))
        let stream = StreamingVideoAsset(asset: asset, retaining: loader)
        controller.playStreaming(asset: stream.asset, retaining: stream, uid: uid)
        defer { controller.teardown() }

        // The attachment logs at once; the watchdog logs when the first frame does not come.
        let deadline = ContinuousClock.now + .seconds(5)
        while !events.all.contains(where: { $0.fields["event"] == "watchdogTimeout" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let all = events.all
        #expect(all.contains { $0.fields["event"] == "watchdogTimeout" }, "the watchdog event was observed")
        #expect(all.contains { $0.fields["event"] == nil }, "the attachment event was observed")
        for event in all {
            #expect(event.name == "VideoPlayer")
            #expect(event.fields["uid"] == nil, "\(event.fields)")
            for value in event.fields.values {
                #expect(!value.contains(uid.volumeID) && !value.contains(uid.nodeID), "\(value)")
            }
        }
    }
}

@MainActor
private final class EventBox {
    private(set) var all: [VideoPlaybackDiagnosticEvent] = []
    func append(_ event: VideoPlaybackDiagnosticEvent) { all.append(event) }
}

/// Holds every request without an answer, so no network access and no item failure interferes.
private final class SilentLoader: NSObject, AVAssetResourceLoaderDelegate, VideoStreamLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AVAssetResourceLoadingRequest] = []

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        lock.withLock { requests.append(request) }
        return true
    }

    func close() {
        let pending = lock.withLock { () -> [AVAssetResourceLoadingRequest] in
            defer { requests = [] }
            return requests
        }
        for request in pending where !request.isCancelled && !request.isFinished {
            request.finishLoading(with: CancellationError())
        }
    }
}
