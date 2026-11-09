import AppKit
import MediaByteCache
import MediaCache
import PhotosCore
import Testing

@testable import TimelineFeature

/// Diagnostics are test-local. The suite remains serialized because some feed fixtures intentionally exercise
/// shared process resources, but its counters cannot be changed by unrelated Swift Testing suites.
@Suite("Thumbnail cache health", .serialized)
struct ThumbnailHealthTests {
    private static let diagnostics = PhotoDiagnostics()

    @Test func diskButNotRAMWarmupTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "disk-only")
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("disk"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let loader = FakeThumbnailLoader()
        let feed = await Self.makeFeed(cache: cache, loader: loader)

        let before = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(before.diskThumbnail)
        #expect(!before.ramDecoded)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 10)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(result.mainThreadDecodeCount == 0)
        #expect(await loader.requestCount() == 0)

        let after = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(after.diskThumbnail)
        #expect(after.ramDecoded)
    }

    @Test @MainActor func realDataSourceWarmPublishesProgressively() async throws {
        let count = 130
        let uids = (0..<count).map { PhotoUID(volumeID: "vol", nodeID: "warm-batch-\($0)") }
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("warm-batch"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        let png = Self.pngData()
        for uid in uids {
            cache.storeToDisk(png, for: uid)
        }
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())
        let items = uids.map {
            PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        }
        let dataSource = RealMetalGridDataSource(
            sections: [
                TimelineSection(
                    id: "warm-batch", date: Date(timeIntervalSince1970: 0), title: "Warm Batch", items: items)
            ], feed: feed)

        var availabilityCallbacks = 0
        dataSource.onImagesAvailable = {
            availabilityCallbacks += 1
        }
        dataSource.warm(uids.map { ThumbnailRequest(uid: $0, pixelSize: 96) })

        try await Self.waitUntil {
            uids.allSatisfy { dataSource.hasImage(for: $0) }
        }
        #expect(
            availabilityCallbacks >= 2,
            "a large viewport must emit more than one availability wake while its bounded workers drain"
        )
    }

    @Test @MainActor func repeatedWarmDemandStillAdmitsTheWholeStableViewport() async throws {
        let count = 220
        let uids = (0..<count).map { PhotoUID(volumeID: "vol", nodeID: "repeat-warm-\($0)-\(UUID().uuidString)") }
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("repeat-warm"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        let loader = FakeThumbnailLoader()
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 2, batch: 32)
        let items = uids.map {
            PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        }
        let dataSource = RealMetalGridDataSource(
            sections: [
                TimelineSection(
                    id: "repeat-warm", date: Date(timeIntervalSince1970: 0), title: "Repeat Warm", items: items)
            ], feed: feed)

        let requests = uids.map { ThumbnailRequest(uid: $0, pixelSize: 96) }
        for _ in 0..<12 {
            dataSource.warm(requests)
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            if await loader.fetched(uids[180]) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            await loader.fetched(uids[180]),
            "Repeated L5-sized warm calls must progress deep into the visible set while callbacks continue"
        )
        await feed.stopPrefetch()
    }

    @Test @MainActor func movingViewportAdmitsNetworkOnlyForLatestStableDemand() async throws {
        let old = (0..<4).map { PhotoUID(volumeID: "vol", nodeID: "moving-old-\($0)-\(UUID().uuidString)") }
        let latest = (0..<4).map { PhotoUID(volumeID: "vol", nodeID: "moving-latest-\($0)-\(UUID().uuidString)") }
        let png = Self.pngData()
        let loader = FakeThumbnailLoader(
            payloads: Dictionary(
                uniqueKeysWithValues: (old + latest).map { ($0, png) }
            ))
        let feed = await Self.makeFeed(
            cache: ThumbnailCache(
                namespace: Self.uniqueNamespace("moving-viewport"),
                rootDirectory: timelineFeatureTestCacheRoot("thumb-health")
            ),
            loader: loader
        )
        let items = (old + latest).map {
            PhotoItem(uid: $0, captureTime: .distantPast, mediaType: "image/jpeg")
        }
        let dataSource = RealMetalGridDataSource(
            sections: [
                TimelineSection(id: "moving-viewport", date: .distantPast, title: "Moving", items: items)
            ], feed: feed)

        dataSource.warm(old.map { ThumbnailRequest(uid: $0, pixelSize: 96) })
        dataSource.warm(latest.map { ThumbnailRequest(uid: $0, pixelSize: 96) })

        try await Task.sleep(for: .milliseconds(80))
        #expect(await loader.requestCount() == 0, "moving viewport misses must remain disk-only")

        for _ in 0..<100 {
            if await withAllFetched(latest, loader) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await withAllFetched(latest, loader))
        #expect(
            await withAllFetched(old, loader) == false,
            "the superseded viewport must not consume network admission")
        await feed.stopPrefetch()
    }

    @Test @MainActor func firstWarmPassFetchesVisibleNetworkMissesButNotDiskHits() async throws {
        // The opening viewport (a fresh data source's first warm pass) must decode disk-present cells straight
        // from disk and fetch only the true disk-misses over the network - exercising the first-pass
        // `.visibleNow` warm path (map to ThumbnailRequest + priority) end to end.
        let misses = (0..<3).map { PhotoUID(volumeID: "vol", nodeID: "fp-miss-\($0)-\(UUID().uuidString)") }
        let onDisk = PhotoUID(volumeID: "vol", nodeID: "fp-hit-\(UUID().uuidString)")
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("first-pass"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: onDisk)
        let loader = FakeThumbnailLoader(
            payloads: Dictionary(uniqueKeysWithValues: misses.map { ($0, Self.pngData()) }))
        let feed = await Self.makeFeed(cache: cache, loader: loader)
        let items = (misses + [onDisk]).map {
            PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        }
        let dataSource = RealMetalGridDataSource(
            sections: [
                TimelineSection(
                    id: "first-pass", date: Date(timeIntervalSince1970: 0), title: "First Pass", items: items)
            ], feed: feed)

        dataSource.warm((misses + [onDisk]).map { ThumbnailRequest(uid: $0, pixelSize: 96) })

        for _ in 0..<150 {
            let allMissesFetched = await withAllFetched(misses, loader)
            if dataSource.hasImage(for: onDisk) && allMissesFetched { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(dataSource.hasImage(for: onDisk))  // disk hit decoded from disk in the first pass
        #expect(await withAllFetched(misses, loader))  // every true miss was fetched over the network
        #expect(await loader.fetched(onDisk) == false)  // the disk hit was never fetched
    }

    @Test @MainActor func networkArrivalRewarmsAnUnchangedVisibleDemand() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "arrival-rewarm-\(UUID().uuidString)")
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("arrival-rewarm"),
            rootDirectory: timelineFeatureTestCacheRoot("thumb-health")
        )
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let item = PhotoItem(uid: uid, captureTime: .distantPast, mediaType: "image/jpeg")
        let dataSource = RealMetalGridDataSource(
            sections: [
                TimelineSection(id: "arrival-rewarm", date: .distantPast, title: "Arrival", items: [item])
            ], feed: feed)
        let requests = [ThumbnailRequest(uid: uid, pixelSize: 96)]

        // Match the idle host: the arrival callback redraws and therefore warms the exact same visible set.
        dataSource.onImagesAvailable = { [weak dataSource] in
            dataSource?.warm(requests)
        }
        dataSource.warm(requests)

        try await Self.waitUntil(timeout: .seconds(3)) {
            dataSource.hasImage(for: uid)
        }
        #expect(await loader.fetched(uid))
        #expect(
            dataSource.hasImage(for: uid),
            "network bytes that arrive for an unchanged viewport must be decoded without scrolling or relaunching")
        await feed.stopPrefetch()
    }

    private func withAllFetched(_ uids: [PhotoUID], _ loader: FakeThumbnailLoader) async -> Bool {
        for uid in uids where await !loader.fetched(uid) { return false }
        return true
    }

    @Test @MainActor func realDataSourceMarksBackendRefusedThumbnailsNonRetryable() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "refused-\(UUID().uuidString)")
        let feed = await Self.makeFeed(
            cache: ThumbnailCache(
                namespace: Self.uniqueNamespace("refused"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health")),
            loader: FakeThumbnailLoader(itemErrors: [uid: "no thumbnail for node"])
        )
        let item = PhotoItem(uid: uid, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        let dataSource = RealMetalGridDataSource(
            sections: [
                TimelineSection(id: "refused", date: Date(timeIntervalSince1970: 0), title: "Refused", items: [item])
            ], feed: feed)

        #expect(dataSource.canRetryThumbnail(for: uid))
        #expect(await feed.image(for: uid) == nil)
        #expect(!dataSource.canRetryThumbnail(for: uid))
    }

    // MetalGridPlaceholderTests cover placeholder-until-resident behavior during a transition.

    @Test func noMainThreadDecodeTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "no-main")
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("main"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.mainThreadDecodeCount == 0)
    }

    @Test func prefetchProgressTest() async throws {
        // Unique nodeID per run: the prefetch resume-checkpoint is persisted in UserDefaults keyed by
        // the uid list's (count-first-last) signature, so a fixed id would resume "at end" on reruns.
        let uid = PhotoUID(volumeID: "vol", nodeID: "prefetch-\(UUID().uuidString)")
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("prefetch"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        await feed.startPrefetch([uid])
        try await Task.sleep(for: .milliseconds(350))

        let status = await feed.prefetchStatus()
        #expect(status.diskFileCount >= 1)
        #expect(status.diskThumbnailCoverageFraction >= 1)
    }

    @Test func priorityUpgradeTest() async throws {
        Self.diagnostics.resetForTests()
        let uid = PhotoUID(volumeID: "vol", nodeID: "upgrade")
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let feed = await Self.makeFeed(
            cache: ThumbnailCache(
                namespace: Self.uniqueNamespace("upgrade"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health")),
            loader: loader, concurrency: 1, batch: 1)
        await feed.requestPriority(uid, priority: .idleLibraryCrawl)
        await feed.requestPriority(uid, priority: .visibleNow)

        #expect(Self.diagnostics.counter("thumb.priorityUpgrade") == 1)
    }

    @Test func cacheStateSeparationTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "tier")
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("tier"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())

        let diskOnly = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(diskOnly.knownInTimeline)
        #expect(diskOnly.diskThumbnail)
        #expect(!diskOnly.ramDecoded)
        #expect(!diskOnly.gpuTexture)

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        let decoded = await feed.cacheState(for: ThumbnailRequest(uid: uid), gpuTextureResident: false)
        #expect(decoded.diskThumbnail)
        #expect(decoded.ramDecoded)
        #expect(!decoded.gpuTexture)
    }

    @Test func decodeWarmupStatsAreObservable() async throws {
        Self.diagnostics.resetForTests()
        let uid = PhotoUID(volumeID: "vol", nodeID: "decode-stats")
        let cache = ThumbnailCache(
            namespace: Self.uniqueNamespace("decode-stats"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health")
        )
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)

        #expect(Self.diagnostics.counter("thumb.diskCacheHit") >= 1)
        #expect(Self.diagnostics.counter("thumb.ramDecodeStarted") >= 1)
        #expect(Self.diagnostics.counter("thumb.ramDecodeCompleted") >= 1)
        #expect(Self.diagnostics.counter("thumb.ramDecodeFailed") == 0)
        #expect(Self.diagnostics.counter("thumb.diskDecodeFailed") == 0)
    }

    private static func makeFeed(
        cache: ThumbnailCache,
        loader: FakeThumbnailLoader,
        concurrency: Int = 2,
        batch: Int = 2
    ) async -> ThumbnailFeed {
        ThumbnailFeed(
            cache: cache,
            loader: loader,
            concurrency: concurrency,
            batch: batch,
            diagnostics: Self.diagnostics
        )
    }

    private static func uniqueNamespace(_ prefix: String) -> String {
        "tests-\(prefix)-\(UUID().uuidString)"
    }

    private static func pngData() -> Data {
        let image = testCGImage()
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])!
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ condition: @MainActor @escaping () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        while await !condition() {
            if started.duration(to: .now) >= timeout {
                Issue.record("condition did not become true within \(timeout)")
                return
            }
            try await Task.sleep(for: interval)
        }
    }

    private static func testCGImage() -> CGImage {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 180
            pixels[offset + 1] = 80
            pixels[offset + 2] = 40
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private actor FakeThumbnailLoader: PriorityThumbnailBatchLoader {
    private var requests: [PhotoUID] = []
    private var priorities: [ThumbnailPriority] = []
    private let payloads: [PhotoUID: Data]
    private let itemErrors: [PhotoUID: String]

    init(payloads: [PhotoUID: Data] = [:], itemErrors: [PhotoUID: String] = [:]) {
        self.payloads = payloads
        self.itemErrors = itemErrors
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requests.append(contentsOf: uids)
        var errors: [PhotoUID: String] = [:]
        for uid in uids {
            if let data = payloads[uid] {
                onLoaded(uid, data)
            } else if let reason = itemErrors[uid] {
                errors[uid] = reason
            }
        }
        return ThumbnailBatchLoadResult(itemErrors: errors)
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        priorities.append(priority)
        return await loadThumbnails(for: uids, onLoaded: onLoaded)
    }

    func requestCount() -> Int {
        requests.count
    }

    func fetched(_ uid: PhotoUID) -> Bool {
        requests.contains(uid)
    }

    func recordedPriorities() -> [ThumbnailPriority] {
        priorities
    }
}
