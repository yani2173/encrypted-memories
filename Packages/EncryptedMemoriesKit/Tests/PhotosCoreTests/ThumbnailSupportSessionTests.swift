import Foundation
import PhotosCore
import XCTest

final class ThumbnailSupportSessionTests: XCTestCase {
    func testUnregisterAndReregisterSameSourceDiscardsInFlightResult() async {
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let source = ReregisteringThumbnailSource(sources: sources)
        sources.registerThumbnailCaches(source)
        let result = await sources.thumbnailCacheSnapshot(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertEqual(source.calls, 1, "source must run")
        XCTAssertEqual(result, .unavailable)
    }

    func testSourceReplacementDuringScanDiscardsRetiredResult() async {
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let current = ThumbnailSource(onSnapshot: {})
        let old = ThumbnailSource(onSnapshot: { sources.registerThumbnailCaches(current) })
        sources.registerThumbnailCaches(old)
        let result = await sources.thumbnailCacheSnapshot(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        XCTAssertEqual(old.calls, 1, "the retired source must have begun its snapshot")
        XCTAssertEqual(result, .unavailable, "a snapshot from the retired session must not be exported")
    }
}

private final class ReregisteringThumbnailSource: ThumbnailCacheSupportSource, @unchecked Sendable {
    private let sources: SupportDiagnosticsSources
    private let lock = NSLock()
    private var count = 0
    init(sources: SupportDiagnosticsSources) { self.sources = sources }
    var calls: Int { lock.withLock { count } }
    func thumbnailCacheSupportSnapshot(deadline: ContinuousClock.Instant) async -> ThumbnailCacheSupportSnapshot {
        lock.withLock { count += 1 }
        sources.unregisterThumbnailCaches(self)
        sources.registerThumbnailCaches(self)
        return ThumbnailCacheSupportSnapshot(availability: .complete, caches: [])
    }
}

private final class ThumbnailSource: ThumbnailCacheSupportSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let onSnapshot: @Sendable () -> Void
    init(onSnapshot: @escaping @Sendable () -> Void) { self.onSnapshot = onSnapshot }
    var calls: Int { lock.withLock { count } }
    func thumbnailCacheSupportSnapshot(deadline: ContinuousClock.Instant) async -> ThumbnailCacheSupportSnapshot {
        lock.withLock { count += 1 }
        onSnapshot()
        return ThumbnailCacheSupportSnapshot(
            availability: .complete,
            caches: [
                .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
            ])
    }
}
