import Darwin
import Foundation
import PhotosCore
import ProtonAuth
import XCTest

final class ThumbnailSupportHostTests: XCTestCase {
    private func makeRoot() throws -> URL {
        var path = Array((NSTemporaryDirectory() + "issue919-host-XXXXXXXX").utf8CString)
        return try path.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress, let result = mkdtemp(base) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return URL(fileURLWithPath: String(cString: result), isDirectory: true)
        }
    }

    @MainActor func testPrepareRejectsInFlightRetiringSource() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "issue919-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let manager = OfflineLibraryManager(testRoot: root, testSources: sources, testDefaults: defaults)
        await manager.previewCache.flushAutomaticDiskCap()
        let source = CallbackSource { await MainActor.run { manager.prepareForAccountTeardown() } }
        manager.installSupportSourceForTesting(source)
        let result = await sources.thumbnailCacheSnapshot(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertEqual(source.calls, 1, "source must run the real manager's preparation")
        XCTAssertEqual(result, .unavailable)
        await manager.stopForAccountTeardown()
        await manager.previewCache.flushAutomaticDiskCap()
    }

    @MainActor func testPrepareOldOwnerDoesNotUnregisterReplacement() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "issue919-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let manager = OfflineLibraryManager(testRoot: root, testSources: sources, testDefaults: defaults)
        await manager.previewCache.flushAutomaticDiskCap()
        let old = CallbackSource {}
        let replacement = CallbackSource {}
        manager.installSupportSourceForTesting(old)
        sources.registerThumbnailCaches(replacement)
        manager.prepareForAccountTeardown()
        let snapshot = await sources.thumbnailCacheSnapshot(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertEqual(snapshot.availability, .complete)
        XCTAssertEqual(replacement.calls, 1)
        await manager.stopForAccountTeardown()
        await manager.previewCache.flushAutomaticDiskCap()
        let afterStop = await sources.thumbnailCacheSnapshot(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertEqual(afterStop.availability, .complete)
    }

    @MainActor func testConfigureRegistersRealGroupAndPrepareRetiresIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "issue919-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppSettingsKey.offlineOriginalsCapUnlimited)
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let manager = OfflineLibraryManager(testRoot: root, testSources: sources, testDefaults: defaults)
        await manager.previewCache.flushAutomaticDiskCap()
        let blob = root.appendingPathComponent("media/thumbnails.enc/probe.blob")
        try Data([0x41]).write(to: blob)
        manager.configure(
            session: ProtonSession(
                uid: "fixture", accessToken: "fixture", refreshToken: "fixture", keyPassword: "fixture"))
        let before = await sources.thumbnailCacheSnapshot(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertEqual(before.availability, .complete, "setup must scan the isolated caches")
        XCTAssertEqual(before.caches.map(\.kind), [.thumbnail, .preview, .original])
        XCTAssertEqual(before.caches.first?.blobCount, 1)
        manager.prepareForAccountTeardown()
        let after = await sources.thumbnailCacheSnapshot(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertEqual(after, .unavailable)
        await manager.stopForAccountTeardown()
        await manager.previewCache.flushAutomaticDiskCap()
    }
}

private final class CallbackSource: ThumbnailCacheSupportSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let action: @Sendable () async -> Void
    init(_ action: @escaping @Sendable () async -> Void) { self.action = action }
    var calls: Int { lock.withLock { count } }
    func thumbnailCacheSupportSnapshot(deadline: ContinuousClock.Instant) async -> ThumbnailCacheSupportSnapshot {
        lock.withLock { count += 1 }
        await action()
        return ThumbnailCacheSupportSnapshot(
            availability: .complete,
            caches: [.init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)])
    }
}
