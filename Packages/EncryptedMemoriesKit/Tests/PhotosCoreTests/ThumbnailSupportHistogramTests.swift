import Foundation
import XCTest

@testable import PhotosCore

final class ThumbnailSupportHistogramTests: XCTestCase {
    func testExportReportsUnavailableWithoutThumbnailSource() async throws {
        let runtime = LibraryRuntimeState()
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let data = try await SupportDiagnosticsExporter.makeJSONData(
            runtimeState: runtime, resourceCoordinator: LibraryResourceCoordinator(runtimeState: runtime),
            diagnostics: PhotoDiagnostics(debugConsoleLogsEnabled: false), sources: sources, trail: SupportEventTrail())
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let histogram = try XCTUnwrap(report["thumbnailCaches"] as? [String: Any])
        XCTAssertEqual(histogram["availability"] as? Int, 2)
    }

    func testExportEncodesAllThumbnailEnumCodesAsIntegers() async throws {
        let runtime = LibraryRuntimeState()
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let caches = [ThumbnailCacheSupportSnapshot.Kind.thumbnail, .preview, .original].map {
            ThumbnailCacheSupportSnapshot.Cache(
                kind: $0, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
        }
        // Availability: complete=0, partial=1, unavailable=2; kind: thumbnail=0, preview=1, original=2.
        for (availability, expected) in [
            (ThumbnailCacheSupportSnapshot.Availability.complete, 0), (.partial, 1), (.unavailable, 2),
        ] {
            let source = FixedThumbnailSource(
                ThumbnailCacheSupportSnapshot(
                    availability: availability, caches: availability == .unavailable ? [] : caches))
            sources.registerThumbnailCaches(source)
            let data = try await SupportDiagnosticsExporter.makeJSONData(
                runtimeState: runtime, resourceCoordinator: LibraryResourceCoordinator(runtimeState: runtime),
                diagnostics: PhotoDiagnostics(debugConsoleLogsEnabled: false), sources: sources,
                trail: SupportEventTrail())
            let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let section = try XCTUnwrap(report["thumbnailCaches"] as? [String: Any])
            XCTAssertEqual(section["availability"] as? Int, expected)
            let entries = try XCTUnwrap(section["caches"] as? [[String: Any]])
            if availability != .unavailable {
                XCTAssertEqual(entries.compactMap { $0["kind"] as? Int }, [0, 1, 2])
            } else {
                XCTAssertTrue(entries.isEmpty)
            }
        }
    }
}

private final class FixedThumbnailSource: ThumbnailCacheSupportSource {
    private let snapshot: ThumbnailCacheSupportSnapshot
    init(_ snapshot: ThumbnailCacheSupportSnapshot) { self.snapshot = snapshot }
    func thumbnailCacheSupportSnapshot(deadline: ContinuousClock.Instant) async -> ThumbnailCacheSupportSnapshot {
        snapshot
    }
}
