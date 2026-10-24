import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaByteCache

@Suite("ThumbnailCacheTrackedSize")
struct ThumbnailCacheTrackedSizeTests {
    private let key = SymmetricKey(size: .bits256)

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-tracked-size-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCache(_ root: URL, namespace: String = "tracked") -> ThumbnailCache {
        let cache = ThumbnailCache(namespace: namespace, derivative: "original", rootDirectory: root)
        cache.configure(accountUID: "acct-A", key: key)
        return cache
    }

    private func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "vol-1", nodeID: id)
    }

    private func setModified(_ cache: ThumbnailCache, _ id: String, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)],
            ofItemAtPath: cache.diskURL(for: uid(id)).path)
    }

    @Test func laterMeasurementsReadTheRunningTotalWithoutListingTheDirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        cache.storeToDisk(Data(repeating: 0x11, count: 300), for: uid("a"))
        cache.storeToDisk(Data(repeating: 0x22, count: 500), for: uid("b"))
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())

        // A file that the cache did not write shows only when a measurement lists the directory.
        let stray = cache.diskURL(for: uid("a")).deletingLastPathComponent().appendingPathComponent("stray.blob")
        try Data(repeating: 0x33, count: 1_000).write(to: stray)

        cache.storeToDisk(Data(repeating: 0x44, count: 700), for: uid("c"))
        cache.storeToDisk(Data(repeating: 0x55, count: 100), for: uid("a"))
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes() - 1_000)
    }

    @Test func runningTotalFollowsReplacementsEvictionsAndClear() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        cache.storeToDisk(Data(repeating: 0x11, count: 900), for: uid("old"))
        cache.storeToDisk(Data(repeating: 0x22, count: 400), for: uid("mid"))
        cache.storeToDisk(Data(repeating: 0x33, count: 200), for: uid("new"))
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())

        // A smaller and a larger replacement change the total by their difference only.
        cache.storeToDisk(Data(repeating: 0x44, count: 50), for: uid("mid"))
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())
        cache.storeToDisk(Data(repeating: 0x55, count: 2_000), for: uid("new"))
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())

        try setModified(cache, "old", 1)
        try setModified(cache, "mid", 2)
        try setModified(cache, "new", 3)
        #expect(cache.enforceByteCap(cache.diskSizeBytes() - 1, ifCurrent: cache.captureWriterGeneration()))
        #expect(cache.diskData(for: uid("old")) == nil)
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())

        await cache.clear()
        #expect(cache.trackedDiskSizeBytes() == 0)
        cache.storeToDisk(Data(repeating: 0x66, count: 300), for: uid("after"))
        #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())
    }

    #if DEBUG
        @Test func blobsWrittenBetweenTheListingAndItsCloseCountOnce() throws {
            let root = makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = makeCache(root)
            cache.storeToDisk(Data(repeating: 0x11, count: 900), for: uid("listed"))
            cache.storeToDisk(Data(repeating: 0x22, count: 400), for: uid("kept"))

            // The listing saw the first blob at its old size; it shrinks and a new blob arrives before the close.
            cache.setSeedListingHookForTesting {
                cache.storeToDisk(Data(repeating: 0x33, count: 50), for: uid("listed"))
                cache.storeToDisk(Data(repeating: 0x44, count: 300), for: uid("added"))
            }
            #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())
            cache.setSeedListingHookForTesting(nil)
            #expect(cache.diskUsageExactForTesting() == cache.diskSizeBytes())

            cache.storeToDisk(Data(repeating: 0x55, count: 700), for: uid("later"))
            #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes())
        }
    #endif

    @Test func firstMeasurementStaysExactWhileWritesLandDuringTheListing() async throws {
        for round in 0..<6 {
            let root = makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let filler = makeCache(root)
            for index in 0..<400 {
                filler.storeToDisk(Data(repeating: 0x11, count: 200 + index % 7 * 50), for: uid("photo-\(index)"))
            }

            // A new instance does not know the total; its first measurement lists the directory.
            let cache = makeCache(root)
            let writes = Task.detached {
                for index in 0..<600 {
                    // Replacements shrink and grow existing blobs; higher indices add new blobs.
                    let size = (index * 37 + round * 11) % 900 + 10
                    cache.storeToDisk(Data(repeating: 0x22, count: size), for: uid("photo-\((index * 7) % 700)"))
                }
            }
            var measurements = 0
            while measurements < 3 || cache.diskUsageExactForTesting() == nil {
                _ = cache.trackedDiskSizeBytes()
                measurements += 1
                if measurements > 1_000 { break }
            }
            await writes.value
            #expect(cache.trackedDiskSizeBytes() == cache.diskSizeBytes(), "round \(round)")
        }
    }

    @Test func groupsAreEqualOnlyForTheSameCacheInstances() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnails = makeCache(root, namespace: "thumbnails")
        let reloaded = makeCache(root, namespace: "thumbnails")

        #expect(ThumbnailCacheGroup([thumbnails]) == ThumbnailCacheGroup([thumbnails]))
        #expect(ThumbnailCacheGroup([thumbnails]) != ThumbnailCacheGroup([reloaded]))
        #expect(ThumbnailCacheGroup([thumbnails]) != ThumbnailCacheGroup([]))
        #expect(Set([ThumbnailCacheGroup([thumbnails]), ThumbnailCacheGroup([thumbnails])]).count == 1)
    }

    @Test func groupMeasuresAtOnceAndAfterEachChange() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnails = makeCache(root, namespace: "thumbnails")
        let originals = makeCache(root, namespace: "originals")
        thumbnails.storeToDisk(Data(repeating: 0x11, count: 300), for: uid("a"))
        let group = ThumbnailCacheGroup([thumbnails, originals])
        let sizes = SizeLog()

        let follower = Task {
            await group.followDiskChanges(interval: .milliseconds(20)) {
                await sizes.append(await group.diskSizeBytes())
            }
        }
        defer { follower.cancel() }
        #expect(await sizes.waitFor(1) == [thumbnails.diskSizeBytes()])

        originals.storeToDisk(Data(repeating: 0x22, count: 500), for: uid("b"))
        let expected = thumbnails.diskSizeBytes() + originals.diskSizeBytes()
        #expect(await sizes.waitFor(2).last == expected)
    }
}

/// Collects measured sizes, so a test can wait for a measurement with a deadline.
private actor SizeLog {
    private(set) var values: [Int64] = []

    func append(_ value: Int64) { values.append(value) }

    func waitFor(_ count: Int, within timeout: Duration = .seconds(5)) async -> [Int64] {
        let deadline = ContinuousClock.now + timeout
        while values.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return values
    }
}
