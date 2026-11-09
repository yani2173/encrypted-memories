import AVFoundation
import AVKit
import Observation
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

/// Injects the system's arrangement fact through the production cover. This verifies the transport's owner and
/// hierarchy, not the native geometry of a Device Hub pose. All playback uses a local, playable stream.
final class MobileViewerTransportPlacementTests: XCTestCase {
    @MainActor func testPausedTransportMovesOutsideTheVideoAndForwardsSeekWithoutReloading() async throws {
        try await verifyTransport(playing: false)
    }

    @MainActor func testPlayingTransportMovesOutsideTheVideoWithoutRestartingPlayback() async throws {
        try await verifyTransport(playing: true)
    }

    @MainActor private func verifyTransport(playing: Bool) async throws {
        let clip = try await makeTransportClip()
        defer { try? FileManager.default.removeItem(at: clip) }
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2, includesVideo: true)
        defer { fixture.removeCache() }
        let lifetime = TransportStreamLifetime()
        let loadGate = TransportLoadGate()
        var backend = fixture.backend
        backend.streamingAssetLoader = { uid in
            lifetime.recordLoad(uid)
            try await loadGate.waitForRelease()
            return StreamingVideoAsset(asset: AVURLAsset(url: clip), retaining: lifetime)
        }
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        let router = MobileViewerRouter()
        let facts = TransportArrangementFacts()
        let transport = ViewerVideoTransport()
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let root = UIHostingController(
            rootView: TransportPresentation(router: router, model: model, facts: facts, transport: transport))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let index = try XCTUnwrap(fixture.items.firstIndex(where: \.isVideo))
        let uid = fixture.items[index].uid
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.presentation = MobileViewerPresentation(
                index: index, items: fixture.items, context: ViewerCollectionContext(filter: .all),
                showsInfoInitially: false)
        }
        try await requireTransport("SETUP: the stream request reaches the held loader") {
            lifetime.loadedUIDs == [uid] && root.presentedViewController != nil
        }
        let loadingViewer = try XCTUnwrap(root.presentedViewController)
        for divided in [true, false] {
            facts.isDivided = divided
            try await requireTransport("The loading arrangement reaches the production viewer") {
                facts.rendered == divided
            }
            window.layoutIfNeeded()
            XCTAssertTrue(transportSliders(in: loadingViewer.view).isEmpty, "Loading has no usable transport")
        }
        await loadGate.release()
        try await requireTransport("SETUP: one ready player and one slider must be mounted") {
            guard let viewer = root.presentedViewController else { return false }
            let players = transportControllers(in: viewer)
            return players.count == 1 && players[0].player?.currentItem?.status == .readyToPlay
                && transportSliders(in: viewer.view).count == 1
        }
        let viewer = try XCTUnwrap(root.presentedViewController)
        let controller = try XCTUnwrap(transportControllers(in: viewer).first)
        let player = try XCTUnwrap(controller.player)
        let item = try XCTUnwrap(player.currentItem)
        let pager = try XCTUnwrap(transportPager(in: viewer))
        XCTAssertGreaterThan(item.duration.seconds, 30, "SETUP: the stream outlasts the transitions")
        player.pause()
        let sought = await player.seek(
            to: CMTime(seconds: 8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought, "SETUP: native seek completes")
        try await requireTransport("SETUP: paused position is eight seconds") {
            player.timeControlStatus == .paused && abs(player.currentTime().seconds - 8) < 0.1
        }
        if playing {
            player.play()
            try await requireTransport("SETUP: playback advances before the arrangement changes") {
                player.timeControlStatus == .playing && player.currentTime().seconds > 8.2
            }
        }
        try await settleTransport(window: window, viewer: viewer)
        let initialSlider = try XCTUnwrap(transportSliders(in: viewer.view).first)
        XCTAssertTrue(initialSlider.isDescendant(of: pager.view), "The flat transport stays in the video page")
        let flatFrame = initialSlider.convert(initialSlider.bounds, to: window)
        let mediaFrame = pager.view.convert(pager.view.bounds, to: window)
        XCTAssertGreaterThan(
            flatFrame.minY, mediaFrame.midY, "The flat transport stays in the lower half of the video area")
        var pausedPosition = 8.0
        var report: [String] = []
        for (step, divided) in [true, false, true, false].enumerated() {
            let before = player.currentTime().seconds
            facts.isDivided = divided
            try await requireTransport("The injected arrangement fact reaches the presented viewer") {
                facts.rendered == divided
            }
            try await settleTransport(window: window, viewer: viewer)
            let sliders = transportSliders(in: viewer.view)
            XCTAssertEqual(sliders.count, 1, "Exactly one transport row is visible")
            let slider = try XCTUnwrap(sliders.first)
            XCTAssertEqual(
                slider.isDescendant(of: pager.view), !divided,
                "Divided transport belongs outside the video area; flat transport stays inside it")
            if !divided {
                let frame = slider.convert(slider.bounds, to: window)
                XCTAssertEqual(frame.minX, flatFrame.minX, accuracy: 1, "Flat horizontal placement is unchanged")
                XCTAssertEqual(frame.minY, flatFrame.minY, accuracy: 1, "Flat vertical placement is unchanged")
                XCTAssertEqual(frame.size.width, flatFrame.size.width, accuracy: 1, "Flat width is unchanged")
                XCTAssertEqual(frame.size.height, flatFrame.size.height, accuracy: 1, "Flat height is unchanged")
            }
            let mounted = transportControllers(in: viewer)
            XCTAssertEqual(mounted.count, 1)
            XCTAssertTrue(mounted.first === controller, "Arrangement changes retain the native controller")
            XCTAssertTrue(controller.player === player, "Arrangement changes retain the player")
            XCTAssertTrue(player.currentItem === item, "Arrangement changes retain the stream item")
            XCTAssertEqual(lifetime.loadedUIDs, [uid], "Arrangement changes do not load another stream")
            XCTAssertEqual(lifetime.closeCount, 0, "The mounted stream stays open")
            if playing {
                try await requireTransport("Playback continues through the arrangement change") {
                    player.timeControlStatus == .playing && player.currentTime().seconds > before + 0.2
                }
            } else {
                XCTAssertEqual(player.timeControlStatus, .paused, "Placement does not change playback intent")
                XCTAssertEqual(player.currentTime().seconds, pausedPosition, accuracy: 0.1)
                if step == 0 {
                    transport.seek(to: 12)
                    try await requireTransport("The divided transport forwards seek to the mounted player") {
                        abs(player.currentTime().seconds - 12) < 0.1
                    }
                    pausedPosition = 12
                    XCTAssertEqual(player.timeControlStatus, .paused, "Seeking preserves paused intent")
                }
            }
            facts.showsChrome = false
            try await requireTransport("Hiding chrome removes the transport in either placement") {
                transportSliders(in: viewer.view).isEmpty
            }
            facts.showsChrome = true
            try await requireTransport("Showing chrome restores exactly one transport") {
                transportSliders(in: viewer.view).count == 1
            }
            report.append("step=\(step) divided=\(divided) time=\(player.currentTime().seconds)")
        }
        if playing {
            transport.togglePlayback()
            try await requireTransport("The transport forwards pause to its existing owner") {
                player.timeControlStatus == .paused
            }
            transport.togglePlayback()
            try await requireTransport("The transport forwards play to its existing owner") {
                player.timeControlStatus == .playing
            }
        }
        withTransaction(transaction) { router.presentation = nil }
        try await requireTransport("Closing the viewer closes the single stream once") { lifetime.closeCount == 1 }
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(lifetime.loadedUIDs, [uid])
        XCTAssertEqual(lifetime.closeCount, 1)
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = playing ? "playing-transport-placement" : "paused-transport-placement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor private func transportControllers(in controller: UIViewController) -> [AVPlayerViewController] {
    if let player = controller as? AVPlayerViewController { return [player] }
    return controller.children.flatMap { transportControllers(in: $0) }
}

@MainActor private func transportPager(in controller: UIViewController) -> UIPageViewController? {
    if let pager = controller as? UIPageViewController { return pager }
    return controller.children.lazy.compactMap { transportPager(in: $0) }.first
}

@MainActor private func transportSliders(in view: UIView) -> [UISlider] {
    guard !view.isHidden, view.alpha >= 0.01 else { return [] }
    return (view as? UISlider).map { [$0] } ?? view.subviews.flatMap { transportSliders(in: $0) }
}

@MainActor private func requireTransport(_ message: String, condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(condition(), message)
    if !condition() { throw TransportProbeFailure.timeout }
}

@MainActor private func settleTransport(window: UIWindow, viewer: UIViewController) async throws {
    var previous: [CGRect] = []
    var stable = 0
    try await requireTransport("The production transport layout settles") {
        window.layoutIfNeeded()
        let frames = transportSliders(in: viewer.view).map { $0.convert($0.bounds, to: window) }
        if !frames.isEmpty, frames.allSatisfy({ !$0.isEmpty }), frames == previous {
            stable += 1
        } else {
            stable = 0
        }
        previous = frames
        return stable >= 3
    }
}

@MainActor @Observable private final class TransportArrangementFacts {
    var isDivided = false
    var showsChrome = true
    var rendered: Bool?
}

private struct TransportPresentation: View {
    let router: MobileViewerRouter
    let model: MobileLibraryModel
    let facts: TransportArrangementFacts
    let transport: ViewerVideoTransport

    var body: some View {
        Color.black.ignoresSafeArea()
            .fullScreenCover(item: Binding(get: { router.presentation }, set: { router.presentation = $0 })) {
                presentation in
                MobilePhotoViewer(
                    items: presentation.items, startIndex: presentation.index, context: presentation.context,
                    libraryModel: model, viewerRouter: router, showsInfoInitially: presentation.showsInfoInitially,
                    videoTransport: transport
                )
                .environment(\.mobileViewerIsDividedForTesting, facts.isDivided)
                .environment(\.mobileViewerTransportChromeForTesting, facts.showsChrome)
                .onChange(of: facts.isDivided, initial: true) { _, value in facts.rendered = value }
            }
    }
}

private final class TransportStreamLifetime: VideoStreamLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private var loads: [PhotoUID] = []
    private var closes = 0
    var loadedUIDs: [PhotoUID] { lock.withLock { loads } }
    var closeCount: Int { lock.withLock { closes } }
    func recordLoad(_ uid: PhotoUID) { lock.withLock { loads.append(uid) } }
    func close() { lock.withLock { closes += 1 } }
}

private enum TransportProbeFailure: Error { case timeout, writerUnavailable, writerFailed }

@MainActor private func makeTransportClip() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    defer { if writer.status == .writing { writer.cancelWriting() } }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 160])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 160,
        ])
    writer.add(input)
    guard writer.startWriting() else { throw TransportProbeFailure.writerFailed }
    writer.startSession(atSourceTime: .zero)
    let pool = try XCTUnwrap(adaptor.pixelBufferPool)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    if let address = CVPixelBufferGetBaseAddress(frame) { memset(address, 128, CVPixelBufferGetDataSize(frame)) }
    CVPixelBufferUnlockBaseAddress(frame, [])
    for index in 0..<60 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard input.isReadyForMoreMediaData else { throw TransportProbeFailure.writerUnavailable }
        guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 1)) else {
            throw TransportProbeFailure.writerFailed
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw TransportProbeFailure.writerFailed }
    return url
}

private actor TransportLoadGate {
    private var released = false
    func release() { released = true }
    func waitForRelease() async throws {
        while !released { try await Task.sleep(for: .milliseconds(10)) }
    }
}
