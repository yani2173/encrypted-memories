import Foundation
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import PhotosCore
import ProtonAuth
import SwiftUI
import Testing
import UIKit
import UploadCore

@testable import EncryptedMemoriesMobile

private actor MobileRetryLifecycleLatch {
    private var entered: [String] = []
    private var released = Set<String>()
    private var entryWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ ownerID: String) {
        entered.append(ownerID)
        let waiters = entryWaiters.removeValue(forKey: ownerID) ?? []
        waiters.forEach { $0.resume() }
    }

    func block(_ ownerID: String) async {
        record(ownerID)
        guard !released.contains(ownerID) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[ownerID, default: []].append(continuation)
        }
    }

    func waitUntilEntered(_ ownerID: String) async {
        if entered.contains(ownerID) { return }
        await withCheckedContinuation { continuation in
            entryWaiters[ownerID, default: []].append(continuation)
        }
    }

    func release(_ ownerID: String) {
        released.insert(ownerID)
        let waiters = releaseWaiters.removeValue(forKey: ownerID) ?? []
        waiters.forEach { $0.resume() }
    }

    func events() -> [String] { entered }
    func hasEntered(_ ownerID: String) -> Bool { entered.contains(ownerID) }
}

private actor MobileRetryCompletionLatch {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor MobileFavoriteRecoveryProbe {
    private(set) var calls = 0
    let retry = MobileRetryLifecycleLatch()
    let members: Set<PhotoUID>

    init(members: Set<PhotoUID>) { self.members = members }

    func load() async throws -> Set<PhotoUID> {
        calls += 1
        if calls == 1 { throw MobileFixtureError.unavailable }
        await retry.block("favorites")
        return members
    }
}

@MainActor
private final class MobileScopeRecoveryTestState {
    var events: [String] = []
    var oldIdentityIsCurrent = true

    func record(_ event: String) {
        events.append(event)
    }
}

private enum MobileRetryTestTimeout: Error {
    case elapsed
}

private actor ViewerOriginalLoadProbe: FullMediaProvider, OriginalByteStreamProvider, VideoStreamProvider {
    let previewData: Data
    private var work: Task<Void, Error>?
    private var motionWork: Task<Void, Error>?
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var motionStarted = false
    private(set) var motionCancelled = false

    init(previewData: Data) { self.previewData = previewData }

    func preview(for uid: PhotoUID) async throws -> Data { previewData }

    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw CancellationError()
    }

    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let pending = Task { try await Task.sleep(for: .seconds(60)) }
        work = pending
        started = true
        do {
            try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
        } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        let pending = Task { try await Task.sleep(for: .seconds(60)) }
        motionWork = pending
        motionStarted = true
        do {
            try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
        } catch {
            motionCancelled = Task.isCancelled
            throw error
        }
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        throw VideoStreamError.notAVideo
    }

    func finish() {
        work?.cancel()
        motionWork?.cancel()
    }
}

@MainActor @Observable private final class ViewerPageVisibility {
    var isCurrent = true
    var isPresented = true
}

/// Holds each preview until the test releases it, so a test can act while a load runs.
private actor HeldPreviewProbe: FullMediaProvider {
    private var previews: [Data]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests = 0

    init(previews: [Data]) { self.previews = previews }

    func preview(for uid: PhotoUID) async throws -> Data {
        requests += 1
        await withCheckedContinuation { waiters.append($0) }
        return previews.removeFirst()
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw CancellationError()
    }
}

private struct ViewerImagePageProbe: View {
    let visibility: ViewerPageVisibility
    let store: UIKitViewerImageStore
    let item: PhotoItem
    var streamer: (any VideoStreamProvider)? = nil

    var body: some View {
        if visibility.isPresented {
            MobileImagePage(
                item: item, isCurrent: visibility.isCurrent, imageStore: store, streamer: streamer,
                onToggleChrome: {}, onCloseRequested: {}
            )
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MobileRetryTestTimeout.elapsed
}

@Suite @MainActor struct MobileAppStateTests {
    @Test func unconfiguredLibraryDoesNotStartSignOutTeardown() {
        let library = MobileLibraryModel()
        let revision = library.timelineRevision
        library.configure(session: nil, store: SessionKeychainStore())
        library.configure(session: nil, store: SessionKeychainStore())
        #expect(library.timelineRevision == revision)
        #expect(!library.isSigningOut)
    }

    @Test func installedSettingsBundleHasOneLocalizedResetSwitch() throws {
        let rootURL = try #require(
            Bundle.main.url(forResource: "Root", withExtension: "plist", subdirectory: "Settings.bundle"))
        let root = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: rootURL), format: nil) as? [String: Any])
        #expect(root["StringsTable"] as? String == "Root")
        let specifiers = try #require(root["PreferenceSpecifiers"] as? [[String: Any]])
        let switches = specifiers.filter { $0["Type"] as? String == "PSToggleSwitchSpecifier" }
        #expect(switches.count == 1)
        let toggle = try #require(switches.first)
        #expect(toggle["Key"] as? String == BackupLocalDataPurge.resetOnNextLaunchKey)
        #expect(toggle["DefaultValue"] as? Bool == false)
        let visibleKeys = specifiers.flatMap { specifier in
            ["Title", "FooterText"].compactMap { specifier[$0] as? String }
        }
        for locale in ["en", "de"] {
            let stringsURL = rootURL.deletingLastPathComponent()
                .appendingPathComponent("\(locale).lproj/Root.strings")
            let strings = try #require(
                PropertyListSerialization.propertyList(from: Data(contentsOf: stringsURL), format: nil)
                    as? [String: String])
            #expect(Set(strings.keys) == Set(visibleKeys))
            #expect(Set(strings.values).count == strings.count)
            for key in visibleKeys {
                #expect(strings[key]?.isEmpty == false)
                #expect(strings[key] != key)
            }
        }
    }

    @Test func unresolvedSessionShowsLoadingInsteadOfLogin() {
        #expect(
            MobileRootPresentation.resolve(
                metalSupported: false,
                isCheckingSession: true,
                hasSession: false
            ) == .unsupportedDevice)
        #expect(
            MobileRootPresentation.resolve(
                metalSupported: true,
                isCheckingSession: true,
                hasSession: false
            ) == .restoringSession)
        #expect(
            MobileRootPresentation.resolve(
                metalSupported: true,
                isCheckingSession: true,
                hasSession: true
            ) == .restoringSession)
        #expect(
            MobileRootPresentation.resolve(
                metalSupported: true,
                isCheckingSession: false,
                hasSession: false
            ) == .signedOut)
        #expect(
            MobileRootPresentation.resolve(
                metalSupported: true,
                isCheckingSession: false,
                hasSession: true
            ) == .signedIn)
    }

    /// VoiceOver read the raw key while the session restored: the package catalog has no entry for it.
    @Test func restoringSessionAnnouncesTranslatedText() {
        let label = MobileRootPresentation.restoringSessionAccessibilityLabel
        #expect(!label.isEmpty)
        #expect(label != "auth.checking_session")
    }

    @Test func failedSignOutCleanupReplacesTheWorkingCoverUntilRetry() {
        #expect(
            MobileSignOutCleanupPresentation.resolve(
                isSigningOut: false,
                cleanupFailed: false
            ) == .hidden)
        #expect(
            MobileSignOutCleanupPresentation.resolve(
                isSigningOut: true,
                cleanupFailed: false
            ) == .working)
        #expect(
            MobileSignOutCleanupPresentation.resolve(
                isSigningOut: true,
                cleanupFailed: true
            ) == .failed)
        #expect(
            MobileSignOutCleanupPresentation.resolve(
                isSigningOut: false,
                cleanupFailed: true
            ) == .failed)
    }

    private func makeViewerImage(size: CGSize, color: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func findViewerScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.delegate != nil {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findViewerScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func makeHostedViewer(
        image: UIImage,
        size: CGSize
    ) throws -> (UIWindow, UIHostingController<MobileZoomableImage>, UIScrollView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView: MobileZoomableImage(
                image: image,
                reduceMotion: true,
                onSingleTap: {},
                onCloseRequested: {}
            ))
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.view.layoutIfNeeded()
        let scrollView = try #require(findViewerScrollView(in: host.view))
        scrollView.layoutIfNeeded()
        return (window, host, scrollView)
    }

    private func makeHostedImagePage(
        _ page: ViewerImagePageProbe
    ) throws -> (
        UIWindow, UIHostingController<ViewerImagePageProbe>
    ) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: page)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return (window, host)
    }

    @Test(.serialized, arguments: [false, true])
    func leavingImagePageCancelsTheOriginalZoomLoad(dismiss: Bool) async throws {
        let thumbnail = makeViewerImage(size: CGSize(width: 120, height: 80))
        let provider = ViewerOriginalLoadProbe(previewData: try #require(thumbnail.pngData()))
        let store = UIKitViewerImageStore(thumbnailProvider: { _ in thumbnail }, media: provider)
        let visibility = ViewerPageVisibility()
        let item = PhotoItem(uid: uid("zoom-cancel"), captureTime: Date(), mediaType: "image/jpeg")
        let (window, host) = try makeHostedImagePage(.init(visibility: visibility, store: store, item: item))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        do {
            try await waitUntil {
                await MainActor.run { self.findViewerScrollView(in: host.view) != nil }
            }
            let scrollView = try #require(findViewerScrollView(in: host.view))
            scrollView.setZoomScale(3, animated: false)
            scrollView.delegate?.scrollViewDidEndZooming?(scrollView, with: nil, atScale: 3)
            try await waitUntil { await provider.started }

            if dismiss {
                visibility.isPresented = false
            } else {
                visibility.isCurrent = false
            }
            try await waitUntil { await provider.cancelled }
        } catch {
            await provider.finish()
            throw error
        }
        await provider.finish()
    }

    /// A second edit can reuse the UID of the first one's tile. A load that started before `forget` must neither
    /// return nor keep the first edit's picture.
    @Test func aLoadThatStartedBeforeForgetKeepsNoImage() async throws {
        let first = try #require(makeViewerImage(size: CGSize(width: 120, height: 80), color: .red).pngData())
        let second = try #require(makeViewerImage(size: CGSize(width: 120, height: 80), color: .blue).pngData())
        let provider = HeldPreviewProbe(previews: [first, second])
        let store = UIKitViewerImageStore(thumbnailProvider: { _ in nil }, media: provider)
        let tile = uid("reused-tile")

        let early = Task { await store.displayImage(for: tile, maxPixelSize: 512) }
        try await waitUntil { await provider.requests == 1 }
        store.forget([tile])
        await provider.release()
        let earlyImage = await early.value
        #expect(earlyImage == nil, "a load from before forget must not show the earlier picture")

        let fresh = Task { await store.displayImage(for: tile, maxPixelSize: 512) }
        try await waitUntil { await provider.requests == 2 }
        await provider.release()
        let freshImage = await fresh.value
        #expect(freshImage != nil)
        #expect(await provider.requests == 2, "nothing was kept from the earlier load")
    }

    @Test func livePhotoPreloadsMotionOnlyWhenItsPageBecomesCurrent() async throws {
        let thumbnail = makeViewerImage(size: CGSize(width: 120, height: 80))
        let provider = ViewerOriginalLoadProbe(previewData: try #require(thumbnail.pngData()))
        let store = UIKitViewerImageStore(thumbnailProvider: { _ in thumbnail }, media: provider)
        let visibility = ViewerPageVisibility()
        visibility.isCurrent = false
        let item = PhotoItem(
            uid: uid("live-preload"), captureTime: Date(), mediaType: "image/heic",
            isLivePhoto: true, relatedVideoID: "motion"
        )
        let (window, host) = try makeHostedImagePage(
            .init(visibility: visibility, store: store, item: item, streamer: provider)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        do {
            try await waitUntil {
                await MainActor.run { self.findViewerScrollView(in: host.view) != nil }
            }
            #expect(await !provider.motionStarted)
            visibility.isCurrent = true
            try await waitUntil { await provider.motionStarted }
            try await waitUntil { await provider.started }
            visibility.isCurrent = false
            try await waitUntil { await provider.motionCancelled }
            try await waitUntil { await provider.cancelled }
        } catch {
            await provider.finish()
            throw error
        }
        await provider.finish()
    }

    private func resizeHostedViewer(
        window: UIWindow,
        host: UIHostingController<MobileZoomableImage>,
        scrollView: UIScrollView,
        to size: CGSize
    ) {
        window.frame = CGRect(origin: .zero, size: size)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.view.layoutIfNeeded()
        scrollView.layoutIfNeeded()
    }

    private func normalizedAnchor(
        offset: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        let settledOrigin = ViewerZoomGeometry.settledOrigin(
            proposedOrigin: offset,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
        return ViewerZoomGeometry.normalizedVisibleAnchor(
            contentOrigin: settledOrigin,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }

    private func expectClose(
        _ actual: CGFloat,
        _ expected: CGFloat,
        tolerance: CGFloat = 1
    ) {
        #expect(abs(actual - expected) <= tolerance)
    }

    private func uid(_ value: String) -> PhotoUID {
        PhotoUID(volumeID: "volume", nodeID: value)
    }

    @Test func leavingSelectionModeClearsEverySelectedItem() {
        let selection = MobileGridSelectionController()

        selection.toggleMode()
        selection.toggle(PhotoItem(uid: uid("one"), captureTime: Date(), mediaType: "image/jpeg"))
        selection.toggle(PhotoItem(uid: uid("two"), captureTime: Date(), mediaType: "image/jpeg"))
        #expect(selection.isSelecting)
        #expect(selection.selected.count == 2)

        selection.toggleMode()
        #expect(!selection.isSelecting)
        #expect(selection.selected.isEmpty)
    }

    @Test func finishClearsSelectionAndSelectionMode() {
        let selection = MobileGridSelectionController()
        selection.toggleMode()
        selection.toggle(PhotoItem(uid: uid("one"), captureTime: Date(), mediaType: "image/jpeg"))

        selection.finish()

        #expect(!selection.isSelecting)
        #expect(selection.selected.isEmpty)
    }

    @Test func viewerMutationRetainsTheExactChangedPhoto() {
        let router = MobileViewerRouter()
        let changed = uid("changed")

        router.noteCompletedMutation(uid: changed)

        #expect(router.completedMutation?.uid == changed)
    }

    @Test func viewerUsesResolvedMIMEKindInsteadOfLossyTimelineHint() {
        let mislabeledVideo = PhotoItem(
            uid: uid("legacy-video"),
            captureTime: .distantPast,
            mediaType: "image/jpeg"
        )
        let falsePositiveVideo = PhotoItem(
            uid: uid("false-positive"),
            captureTime: .distantPast,
            mediaType: "video/quicktime",
            tags: [.videos]
        )

        #expect(MobileViewerMediaRoute.isVideo(item: mislabeledVideo, resolvedKind: nil) == false)
        #expect(MobileViewerMediaRoute.isVideo(item: mislabeledVideo, resolvedKind: .video))
        #expect(MobileViewerMediaRoute.isVideo(item: falsePositiveVideo, resolvedKind: .image) == false)
    }

    @Test func videoPlaybackIntentDistinguishesBufferingPauseAndCompletion() {
        #expect(MobileVideoPlaybackIntent.isActivelyPlaying(.playing))
        #expect(!MobileVideoPlaybackIntent.isActivelyPlaying(.waitingToPlayAtSpecifiedRate))
        #expect(MobileVideoPlaybackIntent.isBuffering(.waitingToPlayAtSpecifiedRate))
        #expect(!MobileVideoPlaybackIntent.isBuffering(.paused))
        #expect(MobileVideoPlaybackIntent.showsLoadingIndicator(intendsToPlay: true, isActivelyPlaying: false))
        #expect(!MobileVideoPlaybackIntent.showsLoadingIndicator(intendsToPlay: true, isActivelyPlaying: true))
        #expect(!MobileVideoPlaybackIntent.showsLoadingIndicator(intendsToPlay: false, isActivelyPlaying: false))
        #expect(MobileVideoPlaybackIntent.reachedEnd(current: 37, duration: 37))
        #expect(!MobileVideoPlaybackIntent.reachedEnd(current: 36.5, duration: 37))
    }

    /// The bars are native; the app owns only the filmstrip rows below the media. Both orientations keep a
    /// touch-sized strip, and compact landscape trades height for the shorter window.
    @Test func viewerFilmstripAccessoryKeepsTouchTargetsInBothOrientations() {
        let regular = MobileViewerBottomLayout.profile(compactLandscape: false)
        let landscape = MobileViewerBottomLayout.profile(compactLandscape: true)
        #expect(regular == .regular)
        #expect(landscape == .compactLandscape)
        #expect(regular.filmstripHeight >= 44)
        #expect(landscape.filmstripHeight >= 44)
        #expect(landscape.filmstripHeight < regular.filmstripHeight)
        #expect(landscape.rowSpacing > 0 && landscape.bottomPadding >= 0)
        #expect(MobileViewerBottomLayout.horizontalPadding == 12)
    }

    @Test
    func viewerZoomAdapterReflowsAspectFitAcrossRotationAndPreservesVisibleAnchor() throws {
        let mediaSize = CGSize(width: 1600, height: 1200)
        let image = makeViewerImage(size: mediaSize)
        let (window, host, scrollView) = try makeHostedViewer(
            image: image,
            size: CGSize(width: 390, height: 844)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let portraitViewport = scrollView.bounds.size
        let portraitFit = ViewerZoomGeometry.aspectFitSize(mediaSize: mediaSize, viewportSize: portraitViewport)
        expectClose(scrollView.contentSize.width, portraitFit.width)
        expectClose(scrollView.contentSize.height, portraitFit.height)

        scrollView.setZoomScale(2, animated: false)
        scrollView.layoutIfNeeded()
        let oldViewport = scrollView.bounds.size
        let oldContentSize = scrollView.contentSize
        let oldMaximumOffset = CGPoint(
            x: max(0, oldContentSize.width - oldViewport.width),
            y: max(0, oldContentSize.height - oldViewport.height)
        )
        scrollView.setContentOffset(
            CGPoint(x: oldMaximumOffset.x * 0.37, y: oldMaximumOffset.y * 0.61),
            animated: false
        )
        scrollView.layoutIfNeeded()
        let oldAnchor = normalizedAnchor(
            offset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            viewportSize: oldViewport
        )
        expectClose(oldAnchor.y, 0.5, tolerance: 0.001)

        resizeHostedViewer(
            window: window,
            host: host,
            scrollView: scrollView,
            to: CGSize(width: 844, height: 390)
        )

        let landscapeViewport = scrollView.bounds.size
        let landscapeFit = ViewerZoomGeometry.aspectFitSize(mediaSize: mediaSize, viewportSize: landscapeViewport)
        #expect(landscapeViewport != portraitViewport, "rotation must change the native viewport size")
        #expect(landscapeFit != portraitFit, "rotation must change the aspect-fit media dimensions")
        expectClose(scrollView.zoomScale, 2, tolerance: 0.01)
        expectClose(scrollView.contentSize.width, landscapeFit.width * 2)
        expectClose(scrollView.contentSize.height, landscapeFit.height * 2)

        let newAnchor = normalizedAnchor(
            offset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            viewportSize: landscapeViewport
        )
        let expectedOrigin = ViewerZoomGeometry.rebasedOrigin(
            anchor: oldAnchor,
            contentSize: scrollView.contentSize,
            viewportSize: landscapeViewport
        )
        let expectedAnchor = normalizedAnchor(
            offset: expectedOrigin,
            contentSize: scrollView.contentSize,
            viewportSize: landscapeViewport
        )
        expectClose(newAnchor.x, expectedAnchor.x, tolerance: 0.02)
        expectClose(newAnchor.y, expectedAnchor.y, tolerance: 0.02)
    }

    @Test
    func viewerZoomAdapterUsesMediaEdgesAtIntermediateZoom() throws {
        let mediaSize = CGSize(width: 1080, height: 1920)
        let requestedViewport = CGSize(width: 390, height: 844)
        let (window, _, scrollView) = try makeHostedViewer(
            image: makeViewerImage(size: mediaSize),
            size: requestedViewport
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        scrollView.setZoomScale(2, animated: false)
        scrollView.layoutIfNeeded()

        let viewport = scrollView.bounds.size
        let fit = ViewerZoomGeometry.aspectFitSize(mediaSize: mediaSize, viewportSize: viewport)
        let expectedContent = CGSize(width: fit.width * 2, height: fit.height * 2)
        expectClose(scrollView.contentSize.width, expectedContent.width)
        expectClose(scrollView.contentSize.height, expectedContent.height)
        expectClose(scrollView.contentInset.left, 0)
        expectClose(scrollView.contentInset.right, 0)
        expectClose(scrollView.contentInset.top, 0)
        expectClose(scrollView.contentInset.bottom, 0)

        let mediaEdgeOffset = CGPoint(
            x: expectedContent.width - viewport.width,
            y: expectedContent.height - viewport.height
        )
        scrollView.setContentOffset(mediaEdgeOffset, animated: false)
        scrollView.layoutIfNeeded()
        expectClose(scrollView.contentOffset.x, mediaEdgeOffset.x)
        expectClose(scrollView.contentOffset.y, mediaEdgeOffset.y)
    }

    @Test
    func viewerZoomAdapterPreservesZoomAndPanForSameMountedImageUpgrade() throws {
        let viewport = CGSize(width: 390, height: 844)
        let firstImage = makeViewerImage(size: CGSize(width: 1200, height: 1800), color: .white)
        let replacementImage = makeViewerImage(size: CGSize(width: 2400, height: 3600), color: .yellow)
        let (window, host, scrollView) = try makeHostedViewer(image: firstImage, size: viewport)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        scrollView.setZoomScale(2.5, animated: false)
        scrollView.layoutIfNeeded()
        let oldViewport = scrollView.bounds.size
        let oldContentSize = scrollView.contentSize
        let oldMaximumOffset = CGPoint(
            x: max(0, oldContentSize.width - oldViewport.width),
            y: max(0, oldContentSize.height - oldViewport.height)
        )
        scrollView.setContentOffset(
            CGPoint(x: oldMaximumOffset.x * 0.42, y: oldMaximumOffset.y * 0.68),
            animated: false
        )
        scrollView.layoutIfNeeded()
        let oldAnchor = normalizedAnchor(
            offset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            viewportSize: oldViewport
        )
        let oldZoom = scrollView.zoomScale

        host.rootView = MobileZoomableImage(
            image: replacementImage,
            reduceMotion: true,
            onSingleTap: {},
            onCloseRequested: {}
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        scrollView.layoutIfNeeded()

        expectClose(scrollView.zoomScale, oldZoom, tolerance: 0.01)
        expectClose(scrollView.contentSize.width, oldContentSize.width)
        expectClose(scrollView.contentSize.height, oldContentSize.height)
        let newAnchor = normalizedAnchor(
            offset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            viewportSize: scrollView.bounds.size
        )
        expectClose(newAnchor.x, oldAnchor.x, tolerance: 0.02)
        expectClose(newAnchor.y, oldAnchor.y, tolerance: 0.02)
    }

    @Test func libraryMutationLeaseRejectsAccountAndLoadGenerationReplacement() {
        let lease = MobileLibraryMutationLease(loadToken: 7, sessionUID: "account-a")

        #expect(lease.isCurrent(loadToken: 7, sessionUID: "account-a"))
        #expect(!lease.isCurrent(loadToken: 8, sessionUID: "account-a"))
        #expect(!lease.isCurrent(loadToken: 7, sessionUID: "account-b"))
        #expect(!lease.isCurrent(loadToken: 7, sessionUID: nil))
    }

    @Test func scopeRecoveryIdentityRejectsDifferentSessionLoadOrRequest() {
        let failedSession = ProtonSession(
            uid: "account-a",
            accessToken: "access-a",
            refreshToken: "refresh-a",
            keyPassword: "key-a"
        )
        let identity = MobileScopeRecoveryIdentity(
            failedSession: failedSession,
            failedLoadGeneration: 7,
            requestID: 1
        )

        #expect(identity.matches(session: failedSession, loadGeneration: 8, activeIdentity: identity))
        #expect(!identity.matches(session: failedSession, loadGeneration: 7, activeIdentity: identity))
        #expect(!identity.matches(session: failedSession, loadGeneration: 9, activeIdentity: identity))
        #expect(
            !identity.matches(
                session: ProtonSession(
                    uid: "account-a",
                    accessToken: "replacement-access",
                    refreshToken: "replacement-refresh",
                    keyPassword: "key-a"
                ),
                loadGeneration: 8,
                activeIdentity: identity
            )
        )
        #expect(
            !identity.matches(
                session: failedSession,
                loadGeneration: 8,
                activeIdentity: MobileScopeRecoveryIdentity(
                    failedSession: failedSession,
                    failedLoadGeneration: 7,
                    requestID: 2
                )
            )
        )
    }

    @Test func terminalRecoveryTracksTaskAndOrdersClearRetirePurgeRebuild() async {
        let coordinator = MobileScopeRecoveryCoordinator()
        let state = MobileScopeRecoveryTestState()
        let session = ProtonSession(
            uid: "account-a",
            accessToken: "access-a",
            refreshToken: "refresh-a",
            keyPassword: "key-a"
        )
        let identity = MobileScopeRecoveryIdentity(
            failedSession: session,
            failedLoadGeneration: 10,
            requestID: 1
        )
        let driver = MobileScopeRecoveryDriver(
            isCurrent: { coordinator.isCurrent(identity) },
            joinRetry: { state.record("join-retry") },
            retireOwners: { state.record("retire") },
            purgeLostScope: { state.record("purge") },
            rebuild: { state.record("rebuild") }
        )

        let scheduled = coordinator.schedule(
            identity: identity,
            prepare: { state.record("clear-projection") },
            operation: { await driver.run() }
        )

        #expect(scheduled)
        #expect(coordinator.isActive)
        #expect(coordinator.isCurrent(identity))
        #expect(state.events == ["clear-projection"])
        #expect(await coordinator.joinIfActive())
        #expect(state.events == ["clear-projection", "join-retry", "retire", "purge", "rebuild"])
        #expect(!coordinator.isActive)
    }

    @Test func retryJoinsPendingScopeRecoveryInsteadOfStartingAnotherRetirement() async throws {
        let coordinator = MobileScopeRecoveryCoordinator()
        let latch = MobileRetryLifecycleLatch()
        let state = MobileScopeRecoveryTestState()
        let identity = MobileScopeRecoveryIdentity(
            failedSession: ProtonSession(
                uid: "account-a",
                accessToken: "access-a",
                refreshToken: "refresh-a",
                keyPassword: "key-a"
            ),
            failedLoadGeneration: 4,
            requestID: 1
        )
        #expect(
            coordinator.schedule(
                identity: identity,
                prepare: { state.record("clear-projection") },
                operation: { await latch.block("scope-recovery") }
            )
        )
        try await waitUntil { await latch.hasEntered("scope-recovery") }

        let retry = Task { @MainActor in
            if await coordinator.joinIfActive() { return }
            state.record("transient-retry")
        }
        await Task.yield()
        #expect(!state.events.contains("transient-retry"))

        await latch.release("scope-recovery")
        await retry.value
        #expect(!state.events.contains("transient-retry"))
    }

    @Test func canceledOldRecoveryCannotPurgeOrClearReplacementRecovery() async throws {
        let coordinator = MobileScopeRecoveryCoordinator()
        let latch = MobileRetryLifecycleLatch()
        let state = MobileScopeRecoveryTestState()
        let session = ProtonSession(
            uid: "account-a",
            accessToken: "access-a",
            refreshToken: "refresh-a",
            keyPassword: "key-a"
        )
        let oldIdentity = MobileScopeRecoveryIdentity(
            failedSession: session,
            failedLoadGeneration: 2,
            requestID: 1
        )
        let oldDriver = MobileScopeRecoveryDriver(
            isCurrent: { state.oldIdentityIsCurrent && coordinator.isCurrent(oldIdentity) },
            joinRetry: {
                state.record("old-join")
                await latch.block("old-join")
            },
            retireOwners: { state.record("old-retire") },
            purgeLostScope: { state.record("old-purge") },
            rebuild: { state.record("old-rebuild") }
        )
        #expect(
            coordinator.schedule(
                identity: oldIdentity,
                prepare: { state.record("old-clear") },
                operation: { await oldDriver.run() }
            )
        )
        try await waitUntil { await latch.hasEntered("old-join") }

        let oldTask = coordinator.cancel()
        state.oldIdentityIsCurrent = false
        let newIdentity = MobileScopeRecoveryIdentity(
            failedSession: session,
            failedLoadGeneration: 3,
            requestID: 2
        )
        #expect(
            coordinator.schedule(
                identity: newIdentity,
                prepare: { state.record("new-clear") },
                operation: {
                    state.record("new-running")
                    await latch.block("new-running")
                }
            )
        )
        try await waitUntil { await latch.hasEntered("new-running") }
        await latch.release("old-join")
        await oldTask?.value

        #expect(!state.events.contains("old-retire"))
        #expect(!state.events.contains("old-purge"))
        #expect(!state.events.contains("old-rebuild"))
        #expect(coordinator.isCurrent(newIdentity))
        #expect(coordinator.isActive)

        await latch.release("new-running")
        #expect(await coordinator.joinIfActive())
        #expect(!coordinator.isActive)
    }

    @Test func directAccountSwitchClosesThePreviousAccountFirst() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let feed = fixture.feed
        await feed.pausePrefetch()
        await feed.startPrefetch(fixture.items.map(\.uid))
        #expect(await feed.hasPendingThumbnailWork())

        let store = SessionKeychainStore()
        model.configure(
            session: ProtonSession(
                uid: "second-account",
                accessToken: "access-b",
                refreshToken: "refresh-b",
                keyPassword: "key-b"
            ),
            store: store
        )
        // Sign out before the second account opens a backend. The test covers the first account only.
        model.configure(session: nil, store: store)

        try await waitUntil { await !feed.hasPendingThumbnailWork() }
    }

    @Test func favoriteFilterWaitsForAuthoritativeMembership() {
        let model = MobileLibraryModel()

        #expect(model.favoriteFilterAvailability == .loading)
        #expect(model.favoriteUIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func unavailableFavoritesRecoverThroughCoalescedLibraryRefresh(knownEmpty: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let authoritative: Set<PhotoUID> = knownEmpty ? [] : [fixture.items[0].uid]
        let newerFavorite = fixture.items[1].uid
        let probe = MobileFavoriteRecoveryProbe(members: authoritative)
        defer { Task { await probe.retry.release("favorites") } }
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                favoriteLoader: { try await probe.load() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)

        // This is the production entry used after connectivity and successful timeline refreshes.
        // It must work without a secondary-source runtime and without restarting the account.
        model.refreshLibrarySources()
        try await waitUntil { await MainActor.run { model.favoriteFilterAvailability == .unavailable } }
        #expect(await probe.calls == 1)
        #expect(!model.allowsSuggestionCacheRestore)

        model.refreshLibrarySources()
        model.refreshLibrarySources()
        try await waitUntil { await probe.retry.hasEntered("favorites") }
        #expect(await probe.calls == 2)
        #expect(model.favoriteFilterAvailability == .loading)
        #expect(!model.allowsSuggestionCacheRestore)
        let mutationSucceeded = await model.toggleFavorite([newerFavorite])
        #expect(mutationSucceeded)
        model.refreshLibrarySources()
        await probe.retry.release("favorites")

        try await waitUntil { await MainActor.run { model.allowsSuggestionCacheRestore } }
        #expect(model.favoriteUIDs == authoritative.union([newerFavorite]))
        #expect(model.favoriteFilterAvailability == .available)
        #expect(await probe.calls == 2)
        model.refreshLibrarySources()
        #expect(model.favoriteFilterAvailability == .available)
        #expect(await probe.calls == 2, "known favorites must not cause another server read on every refresh")
    }

    @Test(arguments: ["success", "failureBeforeRead", "failureAfterRead"])
    func favoriteMutationStartedBeforeRetrySurvivesStaleRead(outcome: String) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let favorite = fixture.items[0].uid
        let probe = MobileFavoriteRecoveryProbe(members: [])
        defer {
            Task {
                await probe.retry.release("favorites")
                await probe.retry.release("write")
            }
        }
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                favoriteLoader: { try await probe.load() },
                favoriteWriter: { _, _ in
                    await probe.retry.block("write")
                    if outcome != "success" { throw MobileFixtureError.unavailable }
                }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        model.refreshLibrarySources()
        try await waitUntil { await MainActor.run { model.favoriteFilterAvailability == .unavailable } }

        let mutation = Task { await model.toggleFavorite([favorite]) }
        try await waitUntil { await probe.retry.hasEntered("write") }
        #expect(model.favoriteUIDs.contains(favorite))
        model.refreshLibrarySources()
        try await waitUntil { await probe.retry.hasEntered("favorites") }

        if outcome == "failureBeforeRead" {
            await probe.retry.release("write")
            #expect(await mutation.value == false)
        }
        await probe.retry.release("favorites")
        try await waitUntil { await MainActor.run { model.allowsSuggestionCacheRestore } }
        #expect(model.favoriteUIDs.contains(favorite) == (outcome != "failureBeforeRead"))
        if outcome != "failureBeforeRead" {
            await probe.retry.release("write")
            #expect(await mutation.value == (outcome == "success"))
        }
        #expect(model.favoriteUIDs.contains(favorite) == (outcome == "success"))
        #expect(model.favoriteMutationsInFlight.isEmpty)
        model.refreshLibrarySources()
        #expect(model.favoriteFilterAvailability == .available)
        #expect(await probe.calls == 2)
    }

    @Test func bulkFavoriteKeepsSelectionAndSurfacesFailure() async throws {
        let first = uid("favorite-first")
        let second = uid("favorite-second")
        let selection = MobileGridSelectionController()
        selection.isSelecting = true
        selection.selected = [first, second]

        selection.performFavorite { selected in
            #expect(selected == [first, second])
            return false
        }

        #expect(selection.isFavoriting)
        try await waitUntil { await MainActor.run { !selection.isFavoriting } }
        #expect(selection.isSelecting)
        #expect(selection.selected == [first, second])
        #expect(selection.actionError?.message == String(localized: "selection.favorite_failed"))
    }

    @Test func livePhotoMotionTaskIdentityIgnoresImageViewportChanges() {
        let live = PhotoItem(
            uid: uid("live"),
            captureTime: .distantPast,
            mediaType: "image/heic",
            isLivePhoto: true,
            relatedVideoID: "motion"
        )

        let visible = MobileLivePhotoMotionTaskID(item: live, isCurrent: true)
        #expect(visible == MobileLivePhotoMotionTaskID(item: live, isCurrent: true))
        #expect(visible != MobileLivePhotoMotionTaskID(item: live, isCurrent: false))
    }

    @Test func shareCleanupDeletesOnlyOwnedPlaintextExports() throws {
        let fileManager = FileManager.default
        let shareDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ShareExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let owned = shareDirectory.appendingPathComponent("IMG_0001.HEIC")
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("outside-share-\(UUID().uuidString).HEIC")
        try Data([1]).write(to: owned)
        try Data([2]).write(to: outside)
        defer { try? fileManager.removeItem(at: outside) }

        MobileMediaExporter.cleanup([owned, outside])

        #expect(!fileManager.fileExists(atPath: owned.path))
        #expect(!fileManager.fileExists(atPath: shareDirectory.path))
        #expect(fileManager.fileExists(atPath: outside.path))
    }

    @Test func cancellingMultiItemShareClearsPayloadAndPlaintextAfterUIKitDismissal() throws {
        let fileManager = FileManager.default
        let shareDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ShareExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let urls = ["IMG_0001.HEIC", "IMG_0002.HEIC"].map {
            shareDirectory.appendingPathComponent($0)
        }
        for url in urls { try Data([1]).write(to: url) }
        defer { try? fileManager.removeItem(at: shareDirectory) }

        var payload: MobileSharePayload? = MobileSharePayload(urls: urls)
        let binding = Binding<MobileSharePayload?>(
            get: { payload },
            set: { payload = $0 }
        )
        let coordinator = MobileActivityPresenter.Coordinator()
        let originalPayload = try #require(payload)
        coordinator.begin(payload: originalPayload, binding: binding)
        let completion = coordinator.completionHandler(for: originalPayload.id)

        completion(nil, false, nil, nil)

        #expect(payload == nil)
        #expect(urls.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        #expect(!fileManager.fileExists(atPath: shareDirectory.path))
    }

    @Test func retryOwnerGraphJoinsEachOwnerBeforeReturning() async throws {
        let latch = MobileRetryLifecycleLatch()
        let completed = MobileRetryCompletionLatch()
        let coordinator = try MobileRetryOwnerGraph.makeCoordinator(
            platformTasks: { await latch.record("mobile.retry.platform-tasks") },
            smartSearch: { await latch.record("mobile.retry.smart-search") },
            locationCrawl: { await latch.block("mobile.retry.location-crawl") },
            photoBackup: { await latch.block("mobile.retry.photo-backup") },
            albumSync: { await latch.block("mobile.retry.album-sync") },
            facade: { await latch.block("mobile.retry.facade") }
        )

        let first = Task {
            let report = await coordinator.teardown()
            await completed.markCompleted()
            return report
        }
        try await waitUntil { await latch.hasEntered("mobile.retry.location-crawl") }
        let completedBeforeLocationRelease = await completed.isCompleted()
        #expect(!completedBeforeLocationRelease, "retry must await the location owner")
        #expect(
            await latch.events() == [
                "mobile.retry.platform-tasks",
                "mobile.retry.smart-search",
                "mobile.retry.location-crawl",
            ])

        let second = Task { await coordinator.teardown() }
        await latch.release("mobile.retry.location-crawl")
        try await waitUntil { await latch.hasEntered("mobile.retry.photo-backup") }
        #expect(
            await latch.events().suffix(2) == [
                "mobile.retry.location-crawl",
                "mobile.retry.photo-backup",
            ])
        await latch.release("mobile.retry.photo-backup")
        try await waitUntil { await latch.hasEntered("mobile.retry.album-sync") }
        await latch.release("mobile.retry.album-sync")
        try await waitUntil { await latch.hasEntered("mobile.retry.facade") }
        await latch.release("mobile.retry.facade")

        let firstReport = await first.value
        let secondReport = await second.value
        #expect(firstReport == secondReport)
        #expect(firstReport.succeeded)
        #expect(
            await latch.events() == [
                "mobile.retry.platform-tasks",
                "mobile.retry.smart-search",
                "mobile.retry.location-crawl",
                "mobile.retry.photo-backup",
                "mobile.retry.album-sync",
                "mobile.retry.facade",
            ])
    }
}
