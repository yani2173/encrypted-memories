import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaByteCache

/// Counts the elements of a change stream, so a test can wait for a signal with a deadline.
private actor SignalCounter {
    private(set) var count = 0
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<Void>) {
        task = Task { [weak self] in
            for await _ in stream { await self?.increment() }
        }
    }

    func stop() { task?.cancel() }

    private func increment() { count += 1 }

    /// Waits until the counter reaches `target` or the deadline passes, and returns the count.
    func waitFor(_ target: Int, within timeout: Duration = .seconds(5)) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while count < target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return count
    }
}

@Suite("ThumbnailCacheDiskChanges")
struct ThumbnailCacheDiskChangeTests {
    private let key = SymmetricKey(size: .bits256)

    private func makeCache(_ root: URL) -> ThumbnailCache {
        let cache = ThumbnailCache(
            namespace: "disk-change-\(UUID().uuidString)",
            derivative: "original",
            rootDirectory: root
        )
        cache.configure(accountUID: "acct-A", key: key)
        return cache
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-disk-change-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "vol-1", nodeID: id)
    }

    @Test func storeEvictionAndClearEachSignalAChange() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        let counter = SignalCounter()
        await counter.start(cache.diskChanges())
        defer { Task { await counter.stop() } }

        let first = uid("a")
        cache.storeToDisk(Data(repeating: 0x11, count: 300), for: first)
        #expect(await counter.waitFor(1) == 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: cache.diskURL(for: first).path)
        cache.storeToDisk(Data(repeating: 0x22, count: 300), for: uid("b"))
        #expect(await counter.waitFor(2) == 2)

        // The cap pass evicts the older blob; Settings must see the smaller size without a timer.
        let sizeBefore = cache.diskSizeBytes()
        #expect(cache.enforceByteCap(sizeBefore - 1, ifCurrent: cache.captureWriterGeneration()))
        #expect(cache.diskData(for: first) == nil)
        #expect(await counter.waitFor(3) == 3)

        await cache.clear()
        #expect(cache.diskSizeBytes() == 0)
        #expect(await counter.waitFor(4) == 4)
    }

    @Test func capPassWithinBudgetDoesNotSignal() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        cache.storeToDisk(Data(repeating: 0x11, count: 300), for: uid("a"))

        let counter = SignalCounter()
        await counter.start(cache.diskChanges())
        defer { Task { await counter.stop() } }
        #expect(cache.enforceByteCap(1_000_000, ifCurrent: cache.captureWriterGeneration()))
        #expect(await counter.waitFor(1, within: .milliseconds(200)) == 0)
    }

    @Test func combinedSignalMergesCachesAndCoalescesBursts() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnails = makeCache(root)
        let originals = makeCache(root)
        let counter = SignalCounter()
        await counter.start(ThumbnailCache.diskChanges(of: [thumbnails, originals], interval: .seconds(1)))
        defer { Task { await counter.stop() } }

        // The first change arrives at once.
        originals.storeToDisk(Data(repeating: 0x11, count: 300), for: uid("first"))
        #expect(await counter.waitFor(1) == 1)

        // A burst inside the interval collapses into one trailing signal.
        for index in 0..<20 {
            thumbnails.storeToDisk(Data(repeating: 0x22, count: 300), for: uid("burst-\(index)"))
        }
        #expect(await counter.waitFor(2) == 2)
        #expect(await counter.waitFor(3, within: .milliseconds(1_500)) == 2)
    }

    @Test func clearOfOneCacheSignalsTheCombinedStream() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnails = makeCache(root)
        let previews = makeCache(root)
        thumbnails.storeToDisk(Data(repeating: 0x11, count: 300), for: uid("a"))

        let counter = SignalCounter()
        await counter.start(ThumbnailCache.diskChanges(of: [thumbnails, previews], interval: .milliseconds(50)))
        defer { Task { await counter.stop() } }
        await thumbnails.clear()
        #expect(await counter.waitFor(1) == 1)
        #expect(thumbnails.diskSizeBytes() == 0)
    }
}
