import AlbumCore
import Foundation
import LibrarySourceRuntime
import MLSearchCore
import PhotosCore
import Testing
import TimelineCore

@testable import EncryptedMemoriesMobile
@testable import ProtonDriveBackend

@MainActor @Suite struct MobileLibraryCatchUpTests {
    @Test(.timeLimit(.minutes(1)))
    func firstLoadSettledWhileInactiveRetainsItsSeed() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let probe = MobileCatchUpProbe(sections: fixture.sections)
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                timelineLoader: { await probe.snapshot() }, changeTokenLoader: { await probe.token() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture)
        model.setApplicationActive(false)
        model.settleIsolatedLibraryForTesting(initialToken: "a")
        await probe.advance()
        model.setApplicationActive(true)
        try await waitUntil { await probe.probes >= 2 }
        model.setApplicationActive(false)
        #expect(await probe.loads == 1, "Foreground must load b after inactive startup published a")
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func supersededSourceProjectionDoesNotReportRefreshed() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let runtime = try await installRuntime(model, fixture: fixture, generation: 100)
        let before = model.timelineRevision
        let outcome = await model.refreshIsolatedLibraryForTesting()
        #expect(outcome == .retry, "The source runtime superseded this projection; no revision was published")
        #expect(model.timelineRevision == before)
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func unpublishedInitialProjectionCannotSeedItsRevision() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let arriving = PhotoItem(
            uid: PhotoUID(volumeID: "fixture-volume", nodeID: "unpublished-arriving"),
            captureTime: .distantPast, mediaType: "image/jpeg")
        let attemptedSections =
            fixture.sections + [TimelineSection(id: "unpublished", date: .distantPast, title: "", items: [arriving])]
        let probe = MobileCatchUpProbe(sections: attemptedSections)
        await probe.advance()
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                timelineLoader: { await probe.snapshot() }, changeTokenLoader: { await probe.token() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture, generation: 100)
        model.setApplicationActive(true)
        try await model.publishIsolatedInitialSnapshotForTesting(
            TimelineLoadSnapshot(sections: attemptedSections, validationToken: "b"))
        #expect(!model.items.contains { $0.uid == arriving.uid })
        try await waitUntil { await probe.probes >= 1 }
        try await waitUntil { await probe.loads >= 1 }
        model.setApplicationActive(false)
        #expect(await probe.loads >= 1, "A discarded initial projection must leave b pending")
        await runtime.shutdown()
    }

    @Test
    func supersededCachedProjectionCannotBecomeAValidatedLaunch() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let runtime = try await installRuntime(model, fixture: fixture, generation: 100)
        model.setApplicationActive(false)
        let accepted = try await model.publishIsolatedValidatedCacheForTesting(
            CachedTimelineSnapshot(sections: fixture.sections, validationToken: "b"))
        #expect(!accepted, "A rejected cached projection must continue through authoritative startup recovery")
        await runtime.shutdown()
    }

    @Test(arguments: ["filter", "search"])
    func derivedMobileRoutesStillPublishTheWholeLibraryToken(route: String) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let arriving = PhotoItem(
            uid: PhotoUID(volumeID: "fixture-volume", nodeID: "arriving"),
            captureTime: .distantPast, mediaType: "image/jpeg")
        let refreshed =
            fixture.sections + [TimelineSection(id: "arriving", date: .distantPast, title: "", items: [arriving])]
        let probe = MobileCatchUpProbe(sections: refreshed)
        await probe.advance()
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                timelineLoader: { await probe.snapshot() }, changeTokenLoader: { await probe.token() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture)
        let key = TimelineSearchProjectionKey(
            sourceRevision: model.timelineRevision,
            query: route == "search" ? "video" : "", context: .init(favoriteUIDs: [fixture.items[0].uid]),
            semanticMatches: nil, refinement: .init(favoritesOnly: route == "filter"))
        let projection = TimelineSearchProjection(key: key, sections: model.sections)
        #expect(projection.snapshot.count < model.items.count)
        let outcome = await model.refreshIsolatedLibraryForTesting()
        #expect(
            outcome == .refreshed(token: "b"), "The visible subset must not replace the shared owner's full snapshot")
        #expect(model.items.contains { $0.uid == arriving.uid })
        #expect(model.items.count == fixture.items.count + 1)
        #expect(await probe.loads == 1)
        await runtime.shutdown()
    }

    @Test(arguments: ["media", "order"])
    func validatedWarmCachePublishesTheRereadBeforeSettling(correction: String) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let first = fixture.items[0]
        let corrected = PhotoItem(
            uid: first.uid, captureTime: first.captureTime,
            mediaType: correction == "media" ? "video/quicktime" : first.mediaType,
            tags: correction == "media" ? [.videos] : first.tags,
            timelineOrder: correction == "order" ? .init(exactCaptureTime: first.captureTime) : first.timelineOrder)
        let currentSections = fixture.sections.map { section in
            TimelineSection(
                id: section.id, date: section.date, title: section.title,
                items: section.items.map { $0.uid == first.uid ? corrected : $0 })
        }
        let cache = MobileRereadProbe(snapshot: CachedTimelineSnapshot(sections: currentSections, validationToken: "a"))
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                changeTokenLoader: { "a" }, cachedTimelineLoader: { await cache.read() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture, authority: .cached)
        model.setApplicationActive(false)
        let accepted = try await model.validateIsolatedCacheForTesting(
            CachedTimelineSnapshot(sections: fixture.sections, validationToken: "a"))
        #expect(accepted)
        #expect(
            model.items.first { $0.uid == first.uid } == corrected,
            "The accepted cache must contain the post-check correction")
        #expect(await cache.reads == 1, "Validation adds one local read before publication")
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func warmCacheRereadRetainsALocalRestoreMadeDuringValidation() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let cache = MobileRereadProbe(
            snapshot: CachedTimelineSnapshot(sections: fixture.sections, validationToken: "a"), holdsRead: true)
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                changeTokenLoader: { "a" }, cachedTimelineLoader: { await cache.read() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture, authority: .cached)
        model.setApplicationActive(false)
        let validation = Task {
            try await model.validateIsolatedCacheForTesting(
                CachedTimelineSnapshot(sections: fixture.sections, validationToken: "a"))
        }
        #expect(await cache.waitUntilHeld())
        let restored = PhotoItem(
            uid: .init(volumeID: "fixture", nodeID: "restored-during-mobile-warm-start"),
            captureTime: .distantPast, mediaType: "image/jpeg")
        try await model.restoreItems([restored])
        #expect(model.items.contains { $0.uid == restored.uid })
        await cache.release()
        let accepted = try await validation.value
        #expect(!accepted, "A newer local mutation supersedes the cached publication")
        #expect(model.items.contains { $0.uid == restored.uid }, "Warm validation must retain the restored photo")
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func fullWarmStartupRetainsRestoreAndLeavesTheOlderFallbackUnacknowledged() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let restored = PhotoItem(
            uid: .init(volumeID: "fixture", nodeID: "restored-during-full-mobile-startup"),
            captureTime: .distantPast, mediaType: "image/jpeg")
        let recovered =
            fixture.sections + [
                TimelineSection(id: "restored", date: .distantPast, title: "", items: [restored])
            ]
        let probe = MobileStartupFallbackProbe(original: fixture.sections, recovered: recovered)
        let backend = MobileFixtureBackend(
            sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
            timelineLoader: { await probe.load() }, changeTokenLoader: { await probe.token() },
            cachedTimelineLoader: { await probe.cache() })
        fixture.install(
            into: model, backend: backend,
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture, authority: .cached)
        model.setApplicationActive(false)
        let startup = Task { try await model.loadIsolatedInitialTimelineForTesting(repository: backend) }
        #expect(await probe.waitUntilRereadIsHeld())
        try await model.restoreItems([restored])
        #expect(model.items.contains { $0.uid == restored.uid })
        await probe.releaseReread()
        try await startup.value
        #expect(
            model.items.contains { $0.uid == restored.uid },
            "The complete startup route must not let an older fallback remove the local restore")
        #expect(await probe.cachedReads == 2)
        await probe.completeInitialPass()
        let loadsBeforeForeground = await probe.fullLoads
        #expect(loadsBeforeForeground == 0, "A superseded warm start must not add an immediate full listing")
        let probesBeforeForeground = await probe.probes
        model.setApplicationActive(true)
        try await waitUntil { await probe.probes >= probesBeforeForeground + 2 }
        model.setApplicationActive(false)
        #expect(
            await probe.fullLoads > loadsBeforeForeground,
            "Superseded startup must keep the constant revision pending for a later whole-library refresh")
        #expect(model.items.contains { $0.uid == restored.uid })
        #expect(await probe.fullLoads == 1, "The monitor catches up once; unchanged later probes do not list again")
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func favoritesFollowTheRemoteSetOnlyWhenARefreshReturnsANewLibraryToken() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        try #require(fixture.items.count >= 4)
        let (a, b, c, d) = (fixture.items[0].uid, fixture.items[1].uid, fixture.items[2].uid, fixture.items[3].uid)
        let probe = MobileRemoteFavoriteProbe(sections: fixture.sections, members: [a])
        defer { Task { await probe.release() } }
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                timelineLoader: { await probe.snapshot() },
                favoriteLoader: { await probe.loadFavorites() },
                favoriteWriter: { uids, favorite in await probe.write(uids, favorite: favorite) }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = try await installRuntime(model, fixture: fixture)
        model.settleIsolatedLibraryForTesting()
        try await waitUntil { model.favoriteFilterAvailability == .available && model.favoriteUIDs == [a] }

        // The first refresh brings the first token: one read. A refresh with the same token reads nothing.
        _ = await model.refreshIsolatedLibraryForTesting()
        try await waitUntil { await probe.reads == 2 }
        _ = await model.refreshIsolatedLibraryForTesting()
        _ = await model.refreshIsolatedLibraryForTesting()

        // Another device removes a and adds b.
        await probe.remoteChange(to: [b])
        _ = await model.refreshIsolatedLibraryForTesting()
        try await waitUntil { model.favoriteUIDs == [b] }
        #expect(await probe.reads == 3, "unchanged refreshes before the change read nothing")

        // Another device adds a again.
        await probe.remoteChange(to: [a, b])
        _ = await model.refreshIsolatedLibraryForTesting()
        try await waitUntil { model.favoriteUIDs == [a, b] }

        // A local favorite made while the read for the next change runs survives the older response. The shown set
        // is [a, b, c] meanwhile; the response removes a and keeps b and the newer local c.
        await probe.holdNextRead()
        await probe.remoteChange(to: [b])
        _ = await model.refreshIsolatedLibraryForTesting()
        try await waitUntil { await probe.isHolding }
        #expect(await model.toggleFavorite([c]))
        await probe.release()
        try await waitUntil { model.favoriteUIDs == [b, c] }
        #expect(model.favoriteFilterAvailability == .available)
        #expect(model.favoriteMutationsInFlight.isEmpty)
        #expect(await probe.reads == 5)

        // Another change that moves the token while a read runs is read right after that read ends.
        await probe.holdNextRead()
        await probe.remoteChange(to: [b, c])
        _ = await model.refreshIsolatedLibraryForTesting()
        try await waitUntil { await probe.isHolding }
        await probe.remoteChange(to: [b, c, d])
        _ = await model.refreshIsolatedLibraryForTesting()
        await probe.release()
        try await waitUntil { model.favoriteUIDs == [b, c, d] }
        #expect(await probe.reads == 7)
        await runtime.shutdown()
    }

    private func installRuntime(
        _ model: MobileLibraryModel, fixture: MobileSignedInFixture, generation: UInt64 = 0,
        authority: SourceInventoryAuthority = .authoritative
    ) async throws -> LibrarySourceAnalysisRuntime {
        let remote = NoAdditionalCatchUpSources()
        let coordinator = LibrarySourceCoordinator(
            remote: remote, thumbnailLoader: fixture.backend, inventoryStore: nil)
        await coordinator.prepare()
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: coordinator, feed: fixture.feed.feedCore, assets: MLAssetUniverse(),
            initiallyActive: false, onAssetsChanged: {})
        #expect(
            await runtime.start(primaryItems: fixture.items, authority: authority, generation: generation)
                == .accepted)
        model.installIsolatedSourceAnalysisForTests(runtime)
        return runtime
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private struct NoAdditionalCatchUpSources: LibrarySourceRemoteBackend {
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { [] }
    func librarySourceItems(for _: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }
}

private actor MobileCatchUpProbe {
    let sections: [TimelineSection]
    private var current = "a"
    private(set) var probes = 0
    private(set) var loads = 0
    init(sections: [TimelineSection]) { self.sections = sections }
    func advance() { current = "b" }
    func token() -> String {
        probes += 1
        return current
    }
    func snapshot() -> TimelineLoadSnapshot {
        loads += 1
        return TimelineLoadSnapshot(sections: sections, validationToken: current)
    }
}

/// The favorites of an account that another device changes. Every change moves the library token.
private actor MobileRemoteFavoriteProbe {
    let sections: [TimelineSection]
    private var members: Set<PhotoUID>
    private var tokenNumber = 0
    private(set) var reads = 0
    private var holdsNextRead = false
    private(set) var isHolding = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(sections: [TimelineSection], members: Set<PhotoUID>) {
        self.sections = sections
        self.members = members
    }
    func remoteChange(to members: Set<PhotoUID>) {
        self.members = members
        tokenNumber += 1
    }
    /// A write of this device reaches the server set. Its library token is not tracked here.
    func write(_ uids: [PhotoUID], favorite: Bool) {
        if favorite { members.formUnion(uids) } else { members.subtract(uids) }
    }
    func snapshot() -> TimelineLoadSnapshot {
        TimelineLoadSnapshot(sections: sections, validationToken: "token-\(tokenNumber)")
    }
    func holdNextRead() { holdsNextRead = true }
    func loadFavorites() async -> Set<PhotoUID> {
        reads += 1
        let response = members
        if holdsNextRead {
            holdsNextRead = false
            isHolding = true
            await withCheckedContinuation { continuation = $0 }
            isHolding = false
        }
        return response
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MobileRereadProbe {
    let snapshot: CachedTimelineSnapshot
    private(set) var reads = 0
    private let holdsRead: Bool
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(snapshot: CachedTimelineSnapshot, holdsRead: Bool = false) {
        self.snapshot = snapshot
        self.holdsRead = holdsRead
    }
    func read() async -> CachedTimelineSnapshot {
        reads += 1
        if holdsRead {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        return snapshot
    }
    func waitUntilHeld() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !held, ContinuousClock.now < deadline { await Task.yield() }
        return held
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MobileStartupFallbackProbe {
    let original: [TimelineSection]
    let recovered: [TimelineSection]
    private(set) var cachedReads = 0
    private(set) var fullLoads = 0
    private(set) var probes = 0
    private var initialPassComplete = false
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(original: [TimelineSection], recovered: [TimelineSection]) {
        self.original = original
        self.recovered = recovered
    }
    func cache() async -> CachedTimelineSnapshot {
        cachedReads += 1
        if cachedReads == 2 {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        return CachedTimelineSnapshot(sections: original, validationToken: "a")
    }
    func load() -> TimelineLoadSnapshot {
        fullLoads += 1
        return TimelineLoadSnapshot(sections: initialPassComplete ? recovered : original, validationToken: "a")
    }
    func completeInitialPass() { initialPassComplete = true }
    func token() -> String {
        probes += 1
        return "a"
    }
    func waitUntilRereadIsHeld() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !held, ContinuousClock.now < deadline { await Task.yield() }
        return held
    }
    func releaseReread() {
        continuation?.resume()
        continuation = nil
    }
}
