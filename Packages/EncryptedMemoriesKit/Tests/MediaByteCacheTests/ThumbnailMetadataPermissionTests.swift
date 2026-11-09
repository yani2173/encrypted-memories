import Foundation
import PhotosCore
import XCTest

@testable import MediaByteCache

final class ThumbnailMetadataPermissionTests: XCTestCase {
    func testUnreadableBlobIsCountedWithNoReadError() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a file without read permission")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = ThumbnailCache(
            namespace: "test", derivative: "thumbnail",
            configuration: ThumbnailCacheConfiguration(diskByteBudgetBytes: 1_000_000_000), rootDirectory: root)
        let file = root.appendingPathComponent("test.enc/private-0.blob")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 42, count: 123)))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertThrowsError(try Data(contentsOf: file), "the test must deny payload reads")
        let result = await cache.thumbnailCacheSupportSnapshot(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        XCTAssertEqual(
            result,
            ThumbnailCacheSupportSnapshot(
                availability: .complete,
                caches: [
                    .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
                ]))
    }
}
