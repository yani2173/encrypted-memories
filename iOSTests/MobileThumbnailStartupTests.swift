import AlbumCore
import CryptoKit
import Foundation
import LibrarySourceRuntime
import MLSearchCore
import MediaByteCache
import MediaCacheUIKitAdapter
import Observation
import PhotosCore
import Testing
import UIKit

@testable import EncryptedMemoriesMobile
@testable import ProtonDriveBackend

@MainActor @Suite struct MobileThumbnailStartupTests {
    @Test func authoritativeEmptyMetadataWakesTheLibraryPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = ThumbnailLoaderProbe(data: [:])
        let coordinator = LibrarySourceCoordinator(remote: remote, thumbnailLoader: remote, inventoryStore: nil)
        await coordinator.prepare()
        let cache = ThumbnailCache(rootDirectory: root)
        cache.configure(accountUID: "fixture-account", key: SymmetricKey(size: .bits256))
        let feed = UIKitThumbnailFeed(cache: cache, loader: coordinator, concurrency: 1, batch: 1)
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: coordinator, feed: feed.feedCore, assets: MLAssetUniverse(),
            initiallyActive: false, onAssetsChanged: {})
        #expect(await runtime.start(primaryItems: [], authority: .authoritative, generation: 0) == .accepted)
        let model = MobileLibraryModel()
        model.applyIsolatedLibraryLoadEventsForTesting([
            .authoritativeInventoryResolved(count: 0, requiresNewFrame: false)
        ])
        #expect(!model.isCompletelyEmpty)
        let changes = EmptyLibraryObservationProbe()
        withObservationTracking {
            _ = model.isCompletelyEmpty
        } onChange: {
            changes.markChanged()
        }
        model.installIsolatedSourceAnalysisForTests(runtime)
        #expect(model.isCompletelyEmpty)
        #expect(changes.wasChanged, "The empty screen must update when authoritative metadata arrives")
        await runtime.shutdown()
    }

    @Test func metadataChangeDoesNotRestartCompletedStartupCrawl() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)

        model.startIsolatedThumbnailPrefetchForTests()
        #expect(model.isBackgroundLoading)
        #expect(await waitUntil { !model.isBackgroundLoading })

        let updated = fixture.sections.map { section in
            TimelineSection(
                id: section.id,
                date: section.date,
                title: section.title,
                items: section.items.map {
                    PhotoItem(
                        uid: $0.uid,
                        captureTime: $0.captureTime.addingTimeInterval(1),
                        mediaType: $0.mediaType)
                })
        }
        model.replaceIsolatedThumbnailInventoryForTests(updated)

        #expect(!model.isBackgroundLoading)
        await fixture.feed.stopPrefetch()
    }

    @Test func initiallyEmptyInventoryStartsCrawlWhenContentArrives() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = PhotoUID(volumeID: "thumbnail-owner", nodeID: "arriving")
        let loader = ThumbnailLoaderProbe(data: [uid: try imageData(color: .orange)])
        let cache = ThumbnailCache(rootDirectory: root)
        let feed = UIKitThumbnailFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [],
            thumbnailFeed: feed, thumbnailCache: cache)

        model.startIsolatedThumbnailPrefetchForTests()
        #expect(!model.isBackgroundLoading)

        model.replaceIsolatedThumbnailInventoryForTests([section(items: [item(uid)])])
        #expect(model.isBackgroundLoading)
        #expect(await waitUntil { !model.isBackgroundLoading })
        #expect(await loader.requests(for: uid) > 0)
        #expect(await feed.image(for: uid) != nil)
        await feed.stopPrefetch()
    }

    @Test func newPhotoUsesTheIncrementalCoordinator() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = PhotoUID(volumeID: "thumbnail-owner", nodeID: "old")
        let added = PhotoUID(volumeID: "thumbnail-owner", nodeID: "added")
        let loader = ThumbnailLoaderProbe(data: [
            old: try imageData(color: .blue),
            added: try imageData(color: .green),
        ])
        let cache = ThumbnailCache(rootDirectory: root)
        let feed = UIKitThumbnailFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let initial = [section(items: [item(old)])]
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: initial,
            thumbnailFeed: feed, thumbnailCache: cache)

        model.startIsolatedThumbnailPrefetchForTests()
        #expect(await waitUntil { !model.isBackgroundLoading })
        let initialCalls = await loader.callCount

        model.replaceIsolatedThumbnailInventoryForTests([section(items: [item(old), item(added)])])
        #expect(
            await waitUntil {
                await loader.requests(for: added) > 0 && !model.isBackgroundLoading
            })
        #expect(await loader.callCount > initialCalls)
        #expect(await feed.image(for: added) != nil)
        await feed.stopPrefetch()
    }

    @Test func sourceBoundCacheClearAdmitsTheVisibleInventoryBeforeRestarting() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = PhotoUID(volumeID: "thumbnail-owner", nodeID: "removed")
        let added = PhotoUID(volumeID: "thumbnail-owner", nodeID: "restored")
        let loader = ThumbnailLoaderProbe(data: [
            removed: try imageData(color: .blue), added: try imageData(color: .green),
        ])
        let coordinator = LibrarySourceCoordinator(remote: loader, thumbnailLoader: loader, inventoryStore: nil)
        await coordinator.prepare()
        let cache = ThumbnailCache(rootDirectory: root)
        cache.configure(accountUID: "fixture-account", key: SymmetricKey(size: .bits256))
        let feed = UIKitThumbnailFeed(cache: cache, loader: coordinator, concurrency: 1, batch: 1)
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: coordinator, feed: feed.feedCore, assets: MLAssetUniverse(),
            initiallyActive: false, onAssetsChanged: {})
        #expect(
            await runtime.start(primaryItems: [item(removed)], authority: .authoritative, generation: 0) == .accepted)
        try await feed.waitForPrefetchToFinish()
        let removedCalls = await loader.requests(for: removed)
        #expect(removedCalls > 0)

        let model = MobileLibraryModel()
        // Reproduce the production interval after visible publication but before its async source update.
        fixture.install(
            into: model, backend: fixture.backend, sections: [section(items: [item(added)])],
            thumbnailFeed: feed, thumbnailCache: cache)
        model.installIsolatedSourceAnalysisForTests(runtime)
        await model.clearCache()
        try await feed.waitForPrefetchToFinish()

        #expect(await loader.requests(for: added) > 0)
        #expect(await loader.requests(for: removed) == removedCalls)
        #expect(cache.hasUsableDiskData(added))
        #expect(!cache.hasUsableDiskData(removed))
        await runtime.shutdown()
    }

    @Test func activationRefreshesLibrarySourcesOnce() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = ThumbnailLoaderProbe(data: [:])
        let coordinator = LibrarySourceCoordinator(remote: remote, thumbnailLoader: remote, inventoryStore: nil)
        await coordinator.prepare()
        let cache = ThumbnailCache(rootDirectory: root)
        cache.configure(accountUID: "fixture-account", key: SymmetricKey(size: .bits256))
        let feed = UIKitThumbnailFeed(cache: cache, loader: coordinator, concurrency: 1, batch: 1)
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: coordinator, feed: feed.feedCore, assets: MLAssetUniverse(),
            initiallyActive: false, onAssetsChanged: {})
        _ = await runtime.start(primaryItems: [], authority: .authoritative, generation: 0)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [], thumbnailFeed: feed, thumbnailCache: cache)
        model.installIsolatedSourceAnalysisForTests(runtime)

        // MobileAccountRuntime makes both calls on every activation.
        model.setApplicationActive(true)
        #expect(await waitUntil { await remote.sourceLocatorRequests == 1 })
        await model.refreshAccountInfo()

        #expect(await remote.sourceLocatorRequests == 1)
        await runtime.shutdown()
    }

    @Test func trashedNewPhotoLeavesThePendingThumbnailWork() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The loader never answers for the new photo, so its thumbnail stays pending.
        let loader = UnansweredThumbnailLoader(data: fixture.backend.thumbnails)
        let cache = ThumbnailCache(rootDirectory: root)
        let feed = UIKitThumbnailFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: fixture.sections, thumbnailFeed: feed,
            thumbnailCache: cache)
        model.startIsolatedThumbnailPrefetchForTests()
        #expect(await waitUntil { !model.isBackgroundLoading })

        let added = PhotoUID(volumeID: "fixture", nodeID: "unanswered")
        model.replaceIsolatedThumbnailInventoryForTests(fixture.sections + [section(items: [item(added)])])
        #expect(await waitUntil { await loader.requests(for: added) > 0 })
        #expect(model.isBackgroundLoading)

        try await model.trashItems([added])
        // The next refresh finds the identities that trash already showed.
        model.replaceIsolatedThumbnailInventoryForTests(fixture.sections)

        #expect(await waitUntil { !model.isBackgroundLoading }, "the trashed photo leaves the pending thumbnails")
        await feed.stopPrefetch()
    }

    @Test func explicitCacheClearRestartsTheOwnedCrawl() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = PhotoUID(volumeID: "thumbnail-owner", nodeID: "cached")
        let loader = ThumbnailLoaderProbe(data: [uid: try imageData(color: .purple)])
        let cache = ThumbnailCache(rootDirectory: root)
        let feed = UIKitThumbnailFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: fixture.backend, sections: [section(items: [item(uid)])],
            thumbnailFeed: feed, thumbnailCache: cache)

        model.startIsolatedThumbnailPrefetchForTests()
        #expect(await waitUntil { !model.isBackgroundLoading })
        let callsBeforeClear = await loader.callCount

        await model.clearCache()
        try await feed.waitForPrefetchToFinish()

        #expect(await loader.callCount > callsBeforeClear)
        #expect(await feed.image(for: uid) != nil)
        await feed.stopPrefetch()
    }

    /// Waits until `predicate` holds. Every wait in this suite expects the state to arrive, so the limit only ends a
    /// hung test: a loaded runner can take longer than any short limit to finish the thumbnail work.
    private func waitUntil(
        timeout: Duration = .seconds(300),
        _ predicate: @MainActor @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func section(items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: "thumbnail-owner", date: Date(), title: "Fixture", items: items)
    }

    private func item(_ uid: PhotoUID) -> PhotoItem {
        PhotoItem(uid: uid, captureTime: Date(), mediaType: "image/png")
    }

    private func imageData(color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try #require(image.pngData())
    }
}

private actor ThumbnailLoaderProbe: ThumbnailBatchLoader, LibrarySourceRemoteBackend {
    private let data: [PhotoUID: Data]
    private var calls = 0
    private var requested: [PhotoUID: Int] = [:]

    init(data: [PhotoUID: Data]) {
        self.data = data
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        calls += 1
        var errors: [PhotoUID: String] = [:]
        for uid in uids {
            requested[uid, default: 0] += 1
            if let bytes = data[uid] {
                onLoaded(uid, bytes)
            } else {
                errors[uid] = "missing fixture thumbnail"
            }
        }
        return ThumbnailBatchLoadResult(itemErrors: errors)
    }

    var callCount: Int { calls }
    private(set) var sourceLocatorRequests = 0
    func requests(for uid: PhotoUID) -> Int { requested[uid, default: 0] }
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        sourceLocatorRequests += 1
        return []
    }
    func librarySourceItems(for _: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }
}

/// Delivers known thumbnails and never answers for the others, neither with the image nor with an error.
private actor UnansweredThumbnailLoader: ThumbnailBatchLoader {
    private let data: [PhotoUID: Data]
    private var requested: [PhotoUID: Int] = [:]

    init(data: [PhotoUID: Data]) {
        self.data = data
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids {
            requested[uid, default: 0] += 1
            if let bytes = data[uid] { onLoaded(uid, bytes) }
        }
        return ThumbnailBatchLoadResult(itemErrors: [:])
    }

    func requests(for uid: PhotoUID) -> Int { requested[uid, default: 0] }
}

private final class EmptyLibraryObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var wasChanged: Bool { lock.withLock { changed } }
    func markChanged() { lock.withLock { changed = true } }
}
