import CoreGraphics
import Foundation
import MediaByteCache
import MediaCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import TimelineFeature

@Suite("App infrastructure")
struct AppInfrastructureTests {
    @Test func offlineToggleAndSidebarWidthPersist() {
        let suite = "tests-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Default registers on; the persisted value survives a round-trip.
        defaults.register(defaults: [AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled])
        #expect(defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled) == true)
        defaults.set(false, forKey: AppSettingsKey.offlineLibraryEnabled)
        #expect(defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled) == false)

        // Sidebar width persists and resolves through the clamp.
        defaults.set(300.0, forKey: AppSettingsKey.sidebarWidth)
        #expect(SidebarMetrics.resolved(stored: CGFloat(defaults.double(forKey: AppSettingsKey.sidebarWidth))) == 300)
    }

    @Test func sidebarClampAndResolve() {
        #expect(SidebarMetrics.clamp(10) == SidebarMetrics.minWidth)
        #expect(SidebarMetrics.clamp(9999) == SidebarMetrics.maxWidth)
        #expect(SidebarMetrics.clamp(250) == 250)
        #expect(SidebarMetrics.resolved(stored: 0) == SidebarMetrics.defaultWidth)  // unset key
        #expect(SidebarMetrics.resolved(stored: 5000) == SidebarMetrics.maxWidth)  // clamped
        #expect(SidebarMetrics.resolved(stored: 200) == 200)
    }

    @Test func sidebarWidthClampTest() {
        #expect(SidebarMetrics.clamp(SidebarMetrics.minWidth - 100) == SidebarMetrics.minWidth)
        #expect(SidebarMetrics.clamp(SidebarMetrics.maxWidth + 100) == SidebarMetrics.maxWidth)
        #expect(SidebarMetrics.clamp(320) == 320)
    }

    @Test func sidebarPersistenceTest() {
        let suite = "tests-sidebar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SidebarPersistence.resolvedVisible(defaults: defaults))
        SidebarPersistence.saveVisible(false, defaults: defaults)
        #expect(!SidebarPersistence.resolvedVisible(defaults: defaults))
        SidebarPersistence.saveVisible(true, defaults: defaults)
        #expect(SidebarPersistence.resolvedVisible(defaults: defaults))

        defaults.set(10.0, forKey: AppSettingsKey.sidebarWidth)
        #expect(SidebarPersistence.resolvedWidth(defaults: defaults) == SidebarMetrics.minWidth)
        defaults.set(320.0, forKey: AppSettingsKey.sidebarWidth)
        #expect(SidebarPersistence.resolvedWidth(defaults: defaults) == 320)
    }

    @Test func windowFrameStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fallback = CGSize(width: 1080, height: 720)

        // Reachable frame is returned unchanged.
        let onScreen = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowFramePolicy.validate(onScreen, screens: [screen], fallbackSize: fallback) == onScreen)

        // A frame on a vanished display is re-centred (keeping its size) onto the primary screen.
        let offScreen = CGRect(x: 6000, y: 6000, width: 800, height: 600)
        let recovered = WindowFramePolicy.validate(offScreen, screens: [screen], fallbackSize: fallback)
        #expect(recovered.size == offScreen.size)
        #expect(WindowFramePolicy.isSufficientlyVisible(recovered, on: [screen]))

        // No screens to fallback size at origin (headless/test).
        let headless = WindowFramePolicy.validate(.zero, screens: [], fallbackSize: fallback)
        #expect(headless.size == fallback)

        // Empty saved frame with screens to centred fallback size, on screen.
        let firstRun = WindowFramePolicy.validate(.zero, screens: [screen], fallbackSize: fallback)
        #expect(firstRun.size == fallback)
        #expect(WindowFramePolicy.isSufficientlyVisible(firstRun, on: [screen]))
    }

    @Test func windowFramePersistenceNotBrokenTest() {
        let suite = "tests-window-frame-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let finalFrame = CGRect(x: 80, y: 90, width: 1_100, height: 740)
        defaults.set(NSStringFromRect(finalFrame), forKey: AppSettingsKey.mainWindowFrame)
        let restored = WindowFramePolicy.validate(
            NSRectFromString(defaults.string(forKey: AppSettingsKey.mainWindowFrame) ?? ""),
            screens: [CGRect(x: 0, y: 0, width: 1_920, height: 1_080)],
            fallbackSize: CGSize(width: 1_080, height: 720)
        )
        #expect(restored == finalFrame)
    }

    @Test func cacheCoverageMath() {
        var status = OfflineCacheStatus()
        #expect(status.thumbnailCoverage == 0)  // no authoritative inventory yet
        status.totalAssets = 200
        status.thumbnailsOnDisk = 50
        #expect(abs(status.thumbnailCoverage - 0.25) < 1e-9)
        status.cacheSizeBytes = 10
        status.previewCacheSizeBytes = 7
        #expect(status.totalCacheSizeBytes == 17)
    }

    @Test func videoStateMachineTransitions() {
        #expect(VideoPlayerItemStatus.readyToPlay.nextState(error: nil) == .ready)
        #expect(VideoPlayerItemStatus.failed.nextState(error: .decryptionFailed) == .failed(.decryptionFailed))
        #expect(VideoPlayerItemStatus.unknown.nextState(error: nil) == nil)  // keep current state

        #expect(VideoViewerState.downloading(0.42).progress == 0.42)
        #expect(VideoViewerState.playing.progress == 1)
        #expect(VideoViewerState.resolving.isBusy)
        #expect(VideoViewerState.downloading(0.1).isBusy)
        #expect(VideoViewerState.buffering(nil).isBusy)
        #expect(!VideoViewerState.playing.isBusy)  // no infinite spinner once playing
        #expect(!VideoViewerState.failed(.timedOut).isBusy)  // …or once failed
        #expect(
            VideoViewerState.failed(.networkUnavailable).errorMessage
                == VideoPlaybackError.networkUnavailable.userMessage)
        #expect(VideoViewerState.ready.errorMessage == nil)
    }

    @Test func videoLogFieldsContract() {
        let fields = videoViewerLogFields(
            state: .downloading(0.5),
            localURLExists: true,
            assetPlayable: false,
            playerItemStatus: 0,
            error: nil
        )
        #expect(fields["uid"] == nil, "the diagnostic never carries the identifier of a photo")
        #expect(fields["state"] == "downloading")
        #expect(fields["progress"] == "0.50")
        #expect(fields["localURLExists"] == "true")
        #expect(fields["assetPlayable"] == "false")
        #expect(fields["playerItemStatus"] == "0")
        #expect(fields["error"] == "none")
    }

    @Test func thumbnailPriorityIsOrdered() {
        // Visible work outranks every background tier; idle crawl is last.
        let order: [ThumbnailPriority] = [
            .visibleNow, .zoomAnchorAndFocusRow, .likelyZoomOutTargetCoverage,
            .nearViewportScrollAhead, .idleLibraryCrawl,
        ]
        for (a, b) in zip(order, order.dropFirst()) { #expect(a < b) }
        #expect(order.min() == .visibleNow)
        #expect(order.max() == .idleLibraryCrawl)
    }

    @Test func prefetchPauseReasons() async {
        let namespace = "tests-pause-\(UUID().uuidString)"
        let root = timelineFeatureTestCacheRoot("pause")
        let feed = ThumbnailFeed(
            cache: ThumbnailCache(namespace: namespace, rootDirectory: root),
            loader: StubThumbnailLoader(),
            concurrency: 1, batch: 1)
        await feed.startPrefetch([PhotoUID(volumeID: "v", nodeID: "a")])

        let grid = ThumbnailInteractionOwner()
        feed.setUserInteractionActive(true, owner: grid)
        var status = await feed.prefetchStatus()
        #expect(!status.paused)
        #expect(status.pausedReason == "none")  // interaction must not starve visible thumbnails

        feed.setUserInteractionActive(false, owner: grid)
        await feed.pausePrefetch()
        status = await feed.prefetchStatus()
        #expect(status.pausedReason == "manual")

        await feed.resumePrefetch()
        await feed.setPrefetchEnabled(false)
        status = await feed.prefetchStatus()
        #expect(!status.enabled)
        #expect(status.pausedReason == "disabled")  // offline toggle off
    }

    //
    // The timeline query-plan guard lives with `TimelineMetadataStore` in PhotosCoreTests.
    // It checks the store schema and load statement directly.

    @Test func metalGridStatsFrameSurfacesRenderAndUploadCounters() {
        let stats = MetalGridStats.frame(
            visibleCount: 7,
            overscanCount: 3,
            realCount: 5,
            cellCount: 8,
            textureUploads: 2,
            textureUploadBytes: 4_096,
            deferredTextureUploads: 3,
            textureUploadMs: 1.25,
            evictions: 1,
            evictMs: 0.5,
            residentBytes: 8_192,
            residentTextureCount: 9,
            pinnedTextureCount: 4,
            textureCapacity: 10,
            pinnedTextureOverflow: false,
            residentByteBudget: 65_536,
            uploadByteBudget: 16_384,
            byteBudgetOverflow: false,
            residencySaturated: true,
            drawCalls: 6,
            textureBinds: 7,
            instanceCount: 5,
            drawMs: 0.75,
            gpuMs: 0.25
        )
        #expect(stats.visibleItems == 7)
        #expect(stats.overscanItems == 3)
        #expect(stats.realTextureItems == 5)
        #expect(stats.placeholderItems == 3)
        #expect(stats.textureUploads == 2)
        #expect(stats.textureUploadBytes == 4_096)
        #expect(stats.deferredTextureUploads == 3)
        #expect(stats.textureUploadMs == 1.25)
        #expect(stats.evictions == 1)
        #expect(stats.evictMs == 0.5)
        #expect(stats.memoryEstimateBytes == 8_192)
        #expect(stats.residentTextureCount == 9)
        #expect(stats.pinnedTextureCount == 4)
        #expect(stats.textureCapacity == 10)
        #expect(!stats.pinnedTextureOverflow)
        #expect(stats.residentByteBudget == 65_536)
        #expect(stats.uploadByteBudget == 16_384)
        #expect(!stats.byteBudgetOverflow)
        #expect(stats.residencySaturated)
        #expect(stats.encodedSlotItems == 8)
        #expect(stats.cacheHits == 5)
        #expect(stats.cacheMisses == 3)
        #expect(stats.drawCalls == 6)
        #expect(stats.textureBinds == 7)
        #expect(stats.instanceCount == 5)
        #expect(stats.drawMs == 0.75)
        #expect(stats.gpuMs == 0.25)
        #expect(stats.drawMs >= 0)
        #expect(stats.gpuMs >= 0)
        #expect(stats.summary.contains("drawMs=0.75"))
        #expect(stats.summary.contains("gpuMs=0.25"))
    }

    @Test func metalGridStatsStartsWithNoCompletedGpuTiming() {
        let stats = MetalGridStats()
        #expect(stats.drawMs == 0)
        #expect(stats.gpuMs == 0)
        #expect(stats.summary.contains("drawMs=0.00"))
        #expect(stats.summary.contains("gpuMs=0.00"))
    }
}

private actor StubThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
