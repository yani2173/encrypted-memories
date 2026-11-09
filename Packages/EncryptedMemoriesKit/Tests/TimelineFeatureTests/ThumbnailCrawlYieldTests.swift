import AppKit
import CryptoKit
import Foundation
import MediaByteCache
import PhotosCore
import Testing

@testable import MediaCache

private let thumbnailCrawlTestKey = SymmetricKey(size: .bits256)

private enum ThumbnailCrawlWaitError: Error {
    case timedOut
}

/// Records fetch order and optionally serves payloads (or fails all requests to model a rate limit).
actor RecordingLoader: ThumbnailBatchLoader {
    private(set) var order: [PhotoUID] = []
    private let payloads: [PhotoUID: Data]
    private let failAll: Bool

    init(payloads: [PhotoUID: Data] = [:], failAll: Bool = false) {
        self.payloads = payloads
        self.failAll = failAll
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        order.append(contentsOf: uids)
        guard !failAll else { return ThumbnailBatchLoadResult(batchError: "simulated 429") }
        for uid in uids { if let data = payloads[uid] { onLoaded(uid, data) } }
        return .delivered
    }

    func fetchOrder() -> [PhotoUID] { order }
    func fetched(_ uid: PhotoUID) -> Bool { order.contains(uid) }
}

/// Controllable monotonic clock for the feed's crawl-yield logic.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("Thumbnail crawl yield / offline decoupling", .serialized)
struct ThumbnailCrawlYieldTests {
    @Test func crawlRunsIndependentlyOfAnyOfflineFlag() async throws {
        let uids = (0..<4).map { PhotoUID(volumeID: "v", nodeID: "crawl-\(UUID())-\($0)") }
        let loader = RecordingLoader(payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.bytes()) }))
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 2, batch: 2)

        await feed.startPrefetch(uids)  // no offline flag anywhere in this path
        try await Self.waitUntil { await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0 }

        #expect(await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0)
    }

    @Test func visibleDemandPausesSequentialCrawl() async throws {
        let visible = PhotoUID(volumeID: "v", nodeID: "visible-\(UUID())")
        let seq = (0..<3).map { PhotoUID(volumeID: "v", nodeID: "seq-\(UUID())-\($0)") }
        let payloads = Dictionary(uniqueKeysWithValues: (seq + [visible]).map { ($0, Self.bytes()) })
        let loader = RecordingLoader(payloads: payloads)
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 1, batch: 1)

        // Live visible demand at T=1000 (the clock stays put, so demand is always "recent").
        await feed.requestPriority(visible, priority: .visibleNow)
        await feed.startPrefetch(seq)

        try await Self.waitUntil { await loader.fetched(visible) }  // visible is served…
        // …while the sequential crawl stays paused because demand is recent.
        let duringDemand = await loader.fetchOrder()
        #expect(duringDemand.contains(visible))
        #expect(duringDemand.allSatisfy { !seq.contains($0) })

        // Demand goes quiet after advancing past the 0.25 s window, so the crawl resumes.
        clock.advance(1.0)
        await feed.resumePrefetch()
        try await Self.waitUntil {
            let o = await loader.fetchOrder()
            return seq.allSatisfy { o.contains($0) }
        }
        let finalOrder = await loader.fetchOrder()
        #expect(seq.allSatisfy { finalOrder.contains($0) })  // crawl resumes once demand quiets
    }

    @Test func noteVisibleDemandPausesSequentialCrawl() async throws {
        // The grid records visible demand via `noteVisibleDemand()` before decoding, so the crawl's
        // `recentDemand` gate yields the serial feed actor to the visible decode.
        let seq = (0..<3).map { PhotoUID(volumeID: "v", nodeID: "note-seq-\(UUID())-\($0)") }
        let payloads = Dictionary(uniqueKeysWithValues: seq.map { ($0, Self.bytes()) })
        let loader = RecordingLoader(payloads: payloads)
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 1, batch: 1)

        feed.noteVisibleDemand()  // viewport is live at T=1000; synchronous (nonisolated), no enqueue/decode
        await feed.startPrefetch(seq)

        try await Task.sleep(for: .milliseconds(200))
        #expect(await loader.fetchOrder().isEmpty)  // sequential crawl suppressed while demand is recent

        // Demand goes quiet (past the 0.25 s window) to the crawl resumes and drains the sequential set.
        clock.advance(1.0)
        await feed.resumePrefetch()
        try await Self.waitUntil {
            let o = await loader.fetchOrder()
            return seq.allSatisfy { o.contains($0) }
        }
        let finalOrder = await loader.fetchOrder()
        #expect(seq.allSatisfy { finalOrder.contains($0) })
    }

    @Test func noteVisibleDemandIsRecordedSynchronouslyWithoutActorHop() async throws {
        // Visible demand is marked synchronously on the caller's thread, so it cannot queue behind coverage scans.
        // The call has no `await` because `noteVisibleDemand` is `nonisolated`.
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: RecordingLoader(), clock: clock)
        feed.noteVisibleDemand()
        #expect(await feed.hasRecentVisibleDemand())
    }

    @Test func rateLimitedBatchBacksOffSequentialCrawl() async throws {
        // A loader that fails everything models a 429: the crawl should back off rather than hammer on.
        let seq = (0..<3).map { PhotoUID(volumeID: "v", nodeID: "rl-\(UUID())-\($0)") }
        let loader = RecordingLoader(failAll: true)
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 1, batch: 1)

        await feed.startPrefetch(seq)
        // First failing batch trips the backoff; with the clock frozen the crawl stays parked.
        try await Self.waitUntil { await loader.fetchOrder().count >= 1 }
        let firstCount = await loader.fetchOrder().count
        try await Task.sleep(for: .milliseconds(250))
        #expect(await loader.fetchOrder().count == firstCount)  // no further attempts during backoff
    }

    @Test func diskHitWarmsRamWithoutNetwork() async throws {
        let cache = ThumbnailCache(
            namespace: "diskhit-\(UUID())", rootDirectory: timelineFeatureTestCacheRoot("yield-diskhit"))
        cache.configure(accountUID: "acct-A", key: thumbnailCrawlTestKey)
        let uid = PhotoUID(volumeID: "v", nodeID: "disk-only")
        cache.storeToDisk(Self.bytes(), for: uid)  // encrypted on disk, no RAM, no network

        let loader = RecordingLoader()  // would record any network call
        let feed = await Self.makeFeed(cache: cache, loader: loader)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(await loader.fetchOrder().isEmpty)  // decrypted disk to RAM with zero network
    }

    @Test func corruptDiskBlobDoesNotStarveVisibleFetch() async throws {
        let cache = ThumbnailCache(
            namespace: "corrupt-\(UUID())", rootDirectory: timelineFeatureTestCacheRoot("yield-corrupt"))
        cache.configure(accountUID: "acct-A", key: thumbnailCrawlTestKey)
        let uid = PhotoUID(volumeID: "v", nodeID: "corrupt")
        // A blob may exist on disk but fail to decrypt because another key wrote it. Written
        // directly to the on-disk path - not via storeToDisk - so it is not pre-marked decryptable.
        try Data(repeating: 0x09, count: 64).write(to: cache.diskURL(for: uid))
        #expect(cache.has(uid) == true)  // the file exists even though its contents are unusable

        let loader = RecordingLoader(payloads: [uid: Self.bytes()])
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)

        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.fetched(uid) }
        #expect(await loader.fetched(uid))  // fetched from the loader despite the corrupt blob
        #expect(cache.hasUsableDiskData(uid) == true)  // and replaced it with a decryptable blob
    }

    private static func makeFeed(
        cache: ThumbnailCache? = nil,
        loader: RecordingLoader,
        clock: ClockBox = ClockBox(Date(timeIntervalSince1970: 1000)),
        concurrency: Int = 1,
        batch: Int = 1
    ) async -> ThumbnailFeed {
        let root = timelineFeatureTestCacheRoot("yield")
        let cache = cache ?? ThumbnailCache(namespace: "yield-\(UUID())", rootDirectory: root)
        return ThumbnailFeed(cache: cache, loader: loader, concurrency: concurrency, batch: batch, clock: clock.now)
    }

    /// Polls a condition while the async crawl runs. A timeout fails at the wait boundary.
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<60 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ThumbnailCrawlWaitError.timedOut
    }

    /// A real, decodable PNG so `warmDecoded` can downsample it.
    private static func bytes() -> Data {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 160
            pixels[offset + 1] = 90
            pixels[offset + 2] = 50
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    }
}
