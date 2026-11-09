import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaByteCache

@Suite struct DiskCachePolicyWiringTests {
    @Test func previewAndThumbnailDefaultsFollowSharedPolicy() {
        let policy = DiskCacheBudgetPolicy(platform: .mobile)
        guard case .bytes(let previewBytes) = policy.previewBudget else {
            Issue.record("The current preview policy must have a byte limit")
            return
        }
        #expect(ThumbnailCache.defaultDiskByteBudget(for: "preview") == previewBytes)
        #expect(policy.thumbnailBudget == .unlimited)
        #expect(ThumbnailCache.defaultDiskByteBudget(for: "thumbnail") == nil)
    }

    @Test func negativeCapKeepsStoredOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ThumbnailCache(namespace: "original", derivative: "original", rootDirectory: root)
        cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
        let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
        let generation = cache.captureWriterGeneration()
        #expect(cache.storeToDisk(Data(repeating: 7, count: 128), for: photo, ifCurrent: generation) == .stored)

        #expect(cache.enforceByteCap(-1, ifCurrent: generation))
        #expect(FileManager.default.fileExists(atPath: cache.diskURL(for: photo).path))
    }

    @Test func staleCapRequestKeepsCurrentOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ThumbnailCache(namespace: "original", derivative: "original", rootDirectory: root)
        let key = SymmetricKey(size: .bits256)
        cache.configure(accountUID: "account", key: key)
        let stale = cache.captureWriterGeneration()
        cache.configure(accountUID: "account", key: key)
        let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
        #expect(
            cache.storeToDisk(
                Data(repeating: 7, count: 128), for: photo, ifCurrent: cache.captureWriterGeneration()) == .stored)

        #expect(cache.diskUsageEstimateForTesting() == nil)
        #expect(!cache.enforceByteCap(Int64.max, ifCurrent: stale))
        #expect(cache.diskUsageEstimateForTesting() == nil)
        #expect(!cache.enforceByteCap(0, ifCurrent: stale))
        #expect(FileManager.default.fileExists(atPath: cache.diskURL(for: photo).path))
    }
}
