import AlbumCore
import Foundation
import LibrarySourceRuntime
import MLSearchCore
import PhotosCore
import SQLite3
import Testing
import TimelineCore

@testable import EncryptedMemoriesMobile
@testable import ProtonDriveBackend

@MainActor @Suite struct TimelineCacheReadStartupTests {
    @Test(arguments: ["photos", "photo_tags", "burst_members"], [false, true])
    func failedCacheReadNeverAuthorizesEitherLibraryModel(table: String, partial: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let repository = try CacheReadStartupRepository(table: table, partial: partial)
        defer { repository.close() }
        #expect(repository.readableToken == "matching-token")

        let mac = TimelineViewModel(repository: repository, feed: fixture.feed.feedCore)
        await mac.load()
        #expect(mac.wholeLibraryInventoryAuthority != .authoritative)
        if case .failed = mac.gridState {
        } else {
            Issue.record("Failed cache and server reads must show failure on the Mac model")
        }
        #expect(repository.serverCalls == 1)
        #expect(repository.tokenProbes == 0)

        let mobile = MobileLibraryModel()
        fixture.install(
            into: mobile, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        let runtime = await installSourceRuntime(into: mobile, fixture: fixture)
        await #expect(throws: CacheReadStartupRepository.ServerFailure.self) {
            try await mobile.loadIsolatedInitialTimelineForTesting(repository: repository)
        }
        #expect(mobile.isolatedInventoryAuthorityForTesting != .authoritative)
        #expect(!mobile.isCompletelyEmpty)
        #expect(repository.serverCalls == 2)
        #expect(repository.tokenProbes == 0)
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    @Test func completeEmptyCacheRemainsAuthoritativeInBothLibraryModels() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let repository = try CacheReadStartupRepository(table: nil, partial: false)
        defer { repository.close() }
        let mac = TimelineViewModel(repository: repository, feed: fixture.feed.feedCore)
        await mac.load()
        #expect(mac.wholeLibraryInventoryAuthority == .authoritative)
        if case .empty = mac.gridState {
        } else {
            Issue.record("A complete validated zero remains empty on the Mac model")
        }
        let mobile = MobileLibraryModel()
        fixture.install(
            into: mobile, backend: fixture.backend, sections: [], thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        let runtime = await installSourceRuntime(into: mobile, fixture: fixture)
        try await mobile.loadIsolatedInitialTimelineForTesting(repository: repository)
        #expect(mobile.isolatedInventoryAuthorityForTesting == .authoritative)
        #expect(mobile.isCompletelyEmpty)
        #expect(repository.serverCalls == 0)
        #expect(repository.tokenProbes == 2)
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }
    private func installSourceRuntime(
        into model: MobileLibraryModel, fixture: MobileSignedInFixture
    ) async -> LibrarySourceAnalysisRuntime {
        model.setApplicationActive(false)
        let source = CacheReadSourceBackend()
        let coordinator = LibrarySourceCoordinator(remote: source, thumbnailLoader: source, inventoryStore: nil)
        await coordinator.prepare()
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: coordinator, feed: fixture.feed.feedCore,
            assets: MLAssetUniverse(), initiallyActive: false, onAssetsChanged: {})
        model.installIsolatedSourceAnalysisForTests(runtime)
        return runtime
    }
}

@MainActor private final class CacheReadStartupRepository: PhotosRepository, LibraryChangeTokenProvider {
    enum ServerFailure: Error { case unavailable }
    private let store: TimelineMetadataStore
    private let directory: URL
    private(set) var serverCalls = 0
    private(set) var tokenProbes = 0
    var readableToken: String? { store.validationToken() }

    init(table: String?, partial: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let url = directory.appendingPathComponent("timeline.sqlite")
        let store = try #require(TimelineMetadataStore(url: url))
        self.store = store
        let items: [PhotoItem] =
            table == nil
            ? []
            : ["first", "second"].enumerated().map { index, node in
                PhotoItem(
                    uid: PhotoUID(volumeID: "volume", nodeID: node),
                    captureTime: Date(timeIntervalSince1970: Double(index)), mediaType: "image/jpeg",
                    tags: [.favorites], burstMemberIDs: ["member"])
            }
        #expect(store.save(items, validationToken: "matching-token").succeeded)
        if let table {
            let projection: String
            switch table {
            case "photos":
                projection =
                    "vol, node, t, CASE WHEN node='second' THEN abs(-9223372036854775808) ELSE mime END AS mime, live, relvid, dur"
            case "photo_tags":
                projection = "vol, node, CASE WHEN node='second' THEN abs(-9223372036854775808) ELSE tag END AS tag"
            default:
                projection =
                    "anchor_vol, anchor_node, seq, CASE WHEN anchor_node='second' THEN abs(-9223372036854775808) ELSE member_node END AS member_node"
            }
            var handle: OpaquePointer?
            #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            let sql =
                "ALTER TABLE \(table) RENAME TO fixture_rows;"
                + (partial ? "CREATE VIEW \(table) AS SELECT \(projection) FROM fixture_rows;" : "")
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    // Same repository contract as the bridge: a read failure is no cache, never a validated zero.
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        do { return try store.cachedTimelineSnapshot() } catch { return nil }
    }
    func loadTimeline() async throws -> [TimelineSection] {
        serverCalls += 1
        throw ServerFailure.unavailable
    }
    func libraryChangeToken() async throws -> String {
        tokenProbes += 1
        return "matching-token"
    }
    func close() {
        // Cleanup runs only after the sequential model loads finish.
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct CacheReadSourceBackend: LibrarySourceRemoteBackend, ThumbnailBatchLoader {
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { [] }
    func librarySourceItems(for _: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
