import Foundation
import MediaByteCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct LibraryCatchUpTests {
    @Test(.timeLimit(.minutes(1)))
    func olderSharedLoadDoesNotAcknowledgeTheNewerProbe() async throws {
        let provider = CatchUpProvider()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: "a"
        ) {
            let published = await provider.publishNextSnapshot()
            return .refreshed(token: published)
        }
        await provider.waitForProbes(4)
        await monitor.stop()
        #expect(
            await provider.publishedTokens == ["a", "b"],
            "The joined load covers a, so b must remain pending until a second snapshot publishes")
    }

    @Test(.timeLimit(.minutes(1)))
    func inactiveStartRetainsThePublishedStartupRevision() async {
        let provider = CatchUpProvider()
        let monitor = LibraryChangeMonitor()
        let policy = LibraryChangePollingPolicy(interval: .milliseconds(1), failureInterval: .milliseconds(1))
        await monitor.restart(
            provider: provider, policy: policy, isActive: false, resetBaseline: true, initialToken: "a"
        ) {
            .refreshed(token: await provider.publishCurrentSnapshot())
        }
        #expect(await provider.probeCount == 0, "Inactivity must retain the seed without probing")
        await monitor.restart(provider: provider, policy: policy) {
            .refreshed(token: await provider.publishCurrentSnapshot())
        }
        await provider.waitForProbes(3)
        await monitor.stop()
        #expect(await provider.publishedTokens == ["b"], "Foreground must catch up from retained a to b")
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnpairedPublishedProjectionKeepsTheChangedTokenPending() async {
        let provider = CatchUpProvider()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider, policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: "a"
        ) {
            let token = await provider.publishCurrentSnapshot()
            return .refreshed(token: await provider.publishedTokens.count == 1 ? nil : token)
        }
        await provider.waitForProbes(4)
        await monitor.stop()
        #expect(await provider.publishedTokens == ["b", "b"])
    }

    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func cancelledCallbackCannotAdvanceTheRetainedBaseline() async {
            let provider = CatchUpProvider()
            let publication = HeldCatchUpPublication()
            let monitor = LibraryChangeMonitor()
            let policy = LibraryChangePollingPolicy(interval: .milliseconds(1), failureInterval: .milliseconds(1))
            await monitor.start(provider: provider, policy: policy, initialToken: "a") {
                await publication.hold()
                return .refreshed(token: "b")
            }
            await publication.waitUntilEntered()
            let stopping = Task { await monitor.stop() }
            await publication.waitUntilCancelled()
            await publication.release()
            await stopping.value
            #expect(await monitor.testingBaseline() == "a", "A cancelled publication cannot certify b")
            await monitor.restart(provider: provider, policy: policy) {
                .refreshed(token: await provider.publishCurrentSnapshot())
            }
            await provider.waitForProbes(4)
            await monitor.stop()
            #expect(
                await provider.publishedTokens == ["b"], "Foreground must still refresh the unacknowledged revision")
        }
    #endif

    @Test(.timeLimit(.minutes(1)))
    func seedProbeCannotCertifyAnEventNewerThanTheValidatedSnapshot() async {
        let provider = WarmLaunchProvider(remoteRevision: "b")
        let validation = await TimelineCacheValidationPolicy.validate(
            snapshot: CachedTimelineSnapshot(sections: [], validationToken: "photos-inventory-v2:a"),
            repository: provider)
        #expect(validation.monitorBaseline == "a#media=2#order=3", "The seed must still describe published a")
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: validation.monitorBaseline
        ) {
            _ = try? await provider.loadTimeline()
            return .refreshed(token: "b#media=2#order=3")
        }
        await provider.waitForProbes(3)
        await monitor.stop()
        #expect(await provider.listings == 1, "The newer seed probe must leave b pending for an authoritative load")
    }

    @Test(arguments: [
        "a", "a#media=3#order=", "a#media=bad#order=4",
        "a#media=3#order=-1", "a#media=3#order=4#extra=0", "a#media=3#xxxxxx4",
    ])
    func unknownLocalRevisionFormatLeavesTheValidatedSeedUnacknowledged(observed: String) async {
        let provider = WarmLaunchProvider(observedMonitorToken: observed)
        let validation = await TimelineCacheValidationPolicy.validate(
            snapshot: CachedTimelineSnapshot(sections: [], validationToken: "photos-inventory-v2:a"),
            repository: provider)
        #expect(validation.monitorBaseline == "", "An unknown local revision must not certify the cached projection")
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: validation.monitorBaseline
        ) {
            _ = try? await provider.loadTimeline()
            return .refreshed(token: observed)
        }
        await provider.waitForProbes(3)
        await monitor.stop()
        #expect(await provider.listings == 1)
    }

    @MainActor @Test
    func anUnpairedInitialSnapshotCannotUseTheEarlierValidationProbeAsItsSeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = UnpairedStartupRepository()
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        await model.load()
        #expect(model.initialLibraryChangeToken == "", "A probe before the load cannot certify its unpaired rows")
        #expect(await repository.loads == 1)
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [WarmStartCorrection.mediaType, .order])
    func warmStartPublishesLocalCorrectionsBeforeAcknowledgingTheirRevision(
        correction: WarmStartCorrection
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HeldWarmStartRepository(correction: correction)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        let loading = Task { await model.load() }
        #expect(await repository.waitUntilSeedProbeIsHeld())
        await repository.completeCorrectionAndReleaseProbe()
        await loading.value

        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: repository, policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: model.initialLibraryChangeToken
        ) {
            let result = await model.refreshLibrary()
            return result.failureReason == nil ? .refreshed(token: result.publishedLibraryChangeToken) : .retry
        }
        #expect(await repository.waitForProbes(4))
        await monitor.stop()
        #expect(await repository.cachedReads == 2, "Warm validation adds exactly one local cache read")
        #expect(await repository.fullLoads == 0, "A local correction must not require another full server listing")
        let correctedItems = repository.correctedItems
        #expect(
            model.allItems == correctedItems,
            "A local correction after cache capture must appear without needing another remote event")
        #expect(
            await monitor.testingBaseline() != repository.correctedToken || model.allItems == correctedItems,
            "The monitor must not certify corrected metadata while the earlier cached projection is still visible")
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func publicationValidationRejectsAnUnprovenRereadAfterMacStartupCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HeldWarmStartRepository(correction: .mediaType)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        let loading = Task { await model.load() }
        #expect(await repository.waitUntilSeedProbeIsHeld())
        model.cancelInitialLoadForTesting()
        await repository.completeCorrectionAndReleaseProbe()
        await loading.value
        #expect(model.allItems == repository.originalItems)
        #expect(model.initialLibraryChangeToken == "", "Cancelled warm validation must retain a retry seed")
        #expect(await repository.fullLoads == 0, "Cancellation must not enter the authoritative fallback")
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func publicationValidationRejectsAnUnprovenRereadAfterRouteChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HeldWarmStartRepository(correction: .mediaType)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        let loading = Task { await model.load() }
        #expect(await repository.waitUntilSeedProbeIsHeld())
        await model.select(.tag(.favorites))
        await repository.completeCorrectionAndReleaseProbe()
        await loading.value
        #expect(model.filter == .tag(.favorites))
        #expect(model.allItems.isEmpty, "The completed warm validation must not replace the newly selected route")
        #expect(model.initialLibraryChangeToken == "", "A skipped whole-library publication must retain a retry seed")
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func warmCacheRereadDoesNotReplaceANewerLocalRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HeldWarmStartRepository(correction: .mediaType)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        let loading = Task { await model.load() }
        #expect(await repository.waitUntilSeedProbeIsHeld())
        let restored = PhotoItem(
            uid: .init(volumeID: "fixture", nodeID: "restored-during-warm-start"),
            captureTime: .distantPast, mediaType: "image/jpeg")
        await model.commitRestore([restored])
        #expect(model.allItems.contains { $0.uid == restored.uid })
        await repository.completeCorrectionAndReleaseProbe()
        await loading.value
        #expect(
            model.allItems.contains { $0.uid == restored.uid },
            "The older reread must not replace a newer local restore")
        #expect(model.initialLibraryChangeToken == "", "A superseded warm projection must remain pending")
        await feed.stopPrefetch()
    }

    @MainActor
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [RouteSwitchHold.cachedRead, .validation, .serverFetch, .failingServerFetch])
    func aRouteSwitchDuringTheFirstLoadLeavesARetrySeedThatRefreshesOnTheFirstProbe(
        hold: RouteSwitchHold
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RouteSwitchStartupRepository(hold: hold)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        let loading = Task { await model.load() }
        #expect(await repository.waitUntilHeld(), "The first load must reach the held \(hold) step")
        await model.select(.tag(.favorites))
        await repository.release()
        await loading.value
        #expect(model.filter == .tag(.favorites))
        #expect(model.initialLibraryChangeToken == "", "A route switch must not leave the monitor without a seed")
        let (probed, published) = await tokensPublishedByAMonitor(seededBy: model.initialLibraryChangeToken)
        #expect(probed)
        #expect(published == ["b"], "The first probe must refresh exactly once")
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func aScopeLossInTheFirstLoadLeavesARetrySeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: RouteSwitchStartupRepository(hold: .terminalValidation), feed: feed)

        await model.load()

        #expect(model.initialLoadFailureReason == .scopeAccessLost)
        #expect(model.initialLibraryChangeToken == "")
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func aTokenFromAnotherLoadIsNotOverwrittenWhenTheFirstLoadLeavesOnARouteSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RouteSwitchStartupRepository(hold: .firstServerFetchOnly)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        let loading = Task { await model.load() }
        #expect(await repository.waitUntilHeld())
        await model.select(.tag(.favorites))
        await model.select(.all)
        #expect(model.initialLibraryChangeToken == "forced-token", "The load of All Photos published its token")
        await model.select(.tag(.favorites))

        await repository.release()
        await loading.value

        #expect(model.initialLibraryChangeToken == "forced-token", "The first load must not replace a published token")
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func aLoadAfterAFilteredRouteShowedContentStillLeavesARetrySeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RouteSwitchStartupRepository(hold: nil)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let photo = PhotoItem(
            uid: .init(volumeID: "fixture", nodeID: "favorite"), captureTime: Date(timeIntervalSince1970: 1_000),
            mediaType: "image/jpeg")
        let section = TimelineSection(id: "s", date: photo.captureTime, title: "", items: [photo])
        let model = TimelineViewModel(
            repository: repository, feed: feed, library: SingleSectionLibrary(sections: [section]))
        await model.select(.tag(.favorites))
        guard case .loaded = model.state else {
            Issue.record("The filtered route must have published content")
            return
        }

        await model.load()

        #expect(model.initialLibraryChangeToken == "", "The load-once check must not skip the seed")
        let (probed, published) = await tokensPublishedByAMonitor(seededBy: model.initialLibraryChangeToken)
        #expect(probed)
        #expect(published == ["b"])
        await feed.stopPrefetch()
    }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [PhotoFilter.map, .duplicates])
    func aLaunchOnARouteWithoutATimelineLeavesARetrySeed(route: PhotoFilter) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RouteSwitchStartupRepository(hold: nil)
        let feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoCatchUpThumbnails())
        let model = TimelineViewModel(repository: repository, feed: feed)
        await model.select(route)

        await model.load()

        #expect(model.initialLibraryChangeToken == "")
        let (probed, published) = await tokensPublishedByAMonitor(seededBy: model.initialLibraryChangeToken)
        #expect(probed)
        #expect(published == ["b"])
        #expect(await repository.fetches == 0, "A route without a timeline loads nothing")
        await feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func stored110ValidationTokenSeedsAnUnchangedMonitorWithoutListing() async throws {
        let provider = WarmLaunchProvider()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library-v1.sqlite")
        let predecessor = try #require(TimelineMetadataStore(url: url))
        #expect(predecessor.save([], validationToken: "photos-inventory-v2:a").succeeded)
        predecessor.close()
        let reopened = try #require(TimelineMetadataStore(url: url))
        defer { reopened.close() }
        #expect(reopened.validationToken() == "photos-inventory-v2:a")
        let cached = CachedTimelineSnapshot(sections: [], validationToken: reopened.validationToken())
        let validation = await TimelineCacheValidationPolicy.validate(snapshot: cached, repository: provider)
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
            initialToken: validation.monitorBaseline
        ) {
            _ = try? await provider.loadTimeline()
            return .refreshed(token: "a#media=2#order=3")
        }
        await provider.waitForProbes(3)
        await monitor.stop()
        #expect(await provider.listings == 0, "A validated 1.1.0 token must not force a full listing")
        #expect(await provider.validations == 1, "Seed conversion must retain the validated snapshot cursor")
        #expect(
            reopened.validationToken() == "photos-inventory-v2:a", "The first launch must not rewrite the 1.1.0 token")
    }
}

private actor CatchUpProvider: LibraryChangeTokenProvider {
    private(set) var publishedTokens: [String] = []
    private(set) var probeCount = 0
    func libraryChangeToken() async throws -> String {
        probeCount += 1
        return "b"
    }
    func publishCurrentSnapshot() -> String {
        publishedTokens.append("b")
        return "b"
    }
    func publishNextSnapshot() -> String {
        let token = publishedTokens.isEmpty ? "a" : "b"
        publishedTokens.append(token)
        return token
    }
    func waitForProbes(_ count: Int) async {
        while probeCount < count { await Task.yield() }
    }
}

private actor WarmLaunchProvider: PhotosRepository, LibraryChangeTokenProvider {
    private let remoteRevision: String
    private let observedMonitorToken: String?
    init(remoteRevision: String = "a", observedMonitorToken: String? = nil) {
        self.remoteRevision = remoteRevision
        self.observedMonitorToken = observedMonitorToken
    }
    private(set) var listings = 0
    private(set) var validations = 0
    private var probes = 0
    func loadTimeline() async throws -> [TimelineSection] {
        listings += 1
        return []
    }
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String {
        validations += 1
        return "photos-inventory-v2:a"
    }
    func libraryChangeToken() async throws -> String {
        probes += 1
        return observedMonitorToken ?? "\(remoteRevision)#media=2#order=3"
    }
    func waitForProbes(_ count: Int) async {
        while probes < count { await Task.yield() }
    }
}

private actor HeldCatchUpPublication {
    private var entered = false
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancelledByOwner() }
        }
    }
    private func cancelledByOwner() { cancelled = true }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func waitUntilCancelled() async { while !cancelled { await Task.yield() } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor UnpairedStartupRepository: PhotosRepository, LibraryChangeTokenProvider {
    private(set) var loads = 0
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        CachedTimelineSnapshot(sections: [], validationToken: "a")
    }
    func loadTimeline() async throws -> [TimelineSection] {
        loads += 1
        return []
    }
    func libraryChangeToken() async throws -> String { "b" }
}

/// The step of the first load that stays suspended while a test acts. `nil` holds nothing.
enum RouteSwitchHold: Sendable {
    case cachedRead
    case validation
    case serverFetch
    case failingServerFetch
    /// Only the first fetch stays suspended; a later one returns at once with "forced-token".
    case firstServerFetchOnly
    /// The cache validation reports that the cached scope is gone.
    case terminalValidation
}

private actor RouteSwitchStartupRepository: PhotosRepository, LibraryChangeTokenProvider {
    private struct Failure: Error {}
    private static let cachedToken = "a-cache"
    private let hold: RouteSwitchHold?
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var fetches = 0

    init(hold: RouteSwitchHold?) { self.hold = hold }

    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        switch hold {
        case .cachedRead:
            await holdUntilReleased()
            return CachedTimelineSnapshot(sections: [], validationToken: Self.cachedToken)
        case .validation, .terminalValidation:
            return CachedTimelineSnapshot(sections: [], validationToken: Self.cachedToken)
        default:
            return nil
        }
    }
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String {
        if hold == .terminalValidation { throw TimelineCacheValidationTerminalError() }
        if hold == .validation { await holdUntilReleased() }
        return Self.cachedToken
    }
    func libraryChangeToken() async throws -> String { Self.cachedToken }
    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        fetches += 1
        switch hold {
        case .serverFetch, .failingServerFetch:
            await holdUntilReleased()
            if hold == .failingServerFetch { throw Failure() }
            return TimelineLoadSnapshot(sections: [], validationToken: "a#media=0#order=0")
        case .firstServerFetchOnly:
            if fetches == 1 {
                await holdUntilReleased()
                return TimelineLoadSnapshot(sections: [], validationToken: "first-token")
            }
            return TimelineLoadSnapshot(sections: [], validationToken: "forced-token")
        default:
            return TimelineLoadSnapshot(sections: [], validationToken: "a#media=0#order=0")
        }
    }
    private func holdUntilReleased() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async -> Bool { await waitUntil { await self.entered } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct SingleSectionLibrary: PhotoLibraryProvider {
    let sections: [TimelineSection]
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] { sections }
}

/// Starts a monitor with `seed` and returns whether it probed three times and which tokens its refreshes published.
private func tokensPublishedByAMonitor(seededBy seed: String?) async -> (probed: Bool, published: [String]) {
    let provider = CatchUpProvider()
    let monitor = LibraryChangeMonitor()
    await monitor.start(
        provider: provider, policy: .init(interval: .milliseconds(1), failureInterval: .milliseconds(1)),
        initialToken: seed
    ) {
        .refreshed(token: await provider.publishCurrentSnapshot())
    }
    let probed = await waitUntil { await provider.probeCount >= 3 }
    await monitor.stop()
    return (probed, await provider.publishedTokens)
}

/// Polls until `condition` holds or ten seconds pass. A `.timeLimit` cannot stop a `Task.yield` loop.
private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

private struct NoCatchUpThumbnails: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult()
    }
}

enum WarmStartCorrection: Sendable {
    case mediaType
    case order
}

private actor HeldWarmStartRepository: PhotosRepository, LibraryChangeTokenProvider {
    nonisolated let originalItems: [PhotoItem]
    nonisolated let correctedItems: [PhotoItem]
    nonisolated let correctedToken: String
    private var corrected = false
    private var seedProbeHeld = false
    private var heldProbe: CheckedContinuation<Void, Never>?
    private var probes = 0
    private(set) var cachedReads = 0
    private(set) var fullLoads = 0

    init(correction: WarmStartCorrection) {
        let date = Date(timeIntervalSince1970: 1_000)
        let first = PhotoItem(
            uid: .init(volumeID: "fixture", nodeID: "first"), captureTime: date, mediaType: "image/jpeg")
        let second = PhotoItem(
            uid: .init(volumeID: "fixture", nodeID: "second"), captureTime: date, mediaType: "image/jpeg")
        originalItems = [first, second]
        switch correction {
        case .mediaType:
            correctedItems = [
                PhotoItem(uid: first.uid, captureTime: date, mediaType: "video/quicktime", tags: [.videos]), second,
            ]
            correctedToken = "a#media=2#order=1"
        case .order:
            correctedItems = [
                PhotoItem(
                    uid: second.uid, captureTime: date, mediaType: second.mediaType,
                    timelineOrder: .init(exactCaptureTime: date.addingTimeInterval(0.1))),
                PhotoItem(
                    uid: first.uid, captureTime: date, mediaType: first.mediaType,
                    timelineOrder: .init(exactCaptureTime: date.addingTimeInterval(0.9))),
            ]
            correctedToken = "a#media=1#order=2"
        }
    }

    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        cachedReads += 1
        return CachedTimelineSnapshot(sections: sections(), validationToken: "photos-inventory-v2:a")
    }
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String { "photos-inventory-v2:a" }
    func libraryChangeToken() async throws -> String {
        probes += 1
        if cachedReads > 0, !seedProbeHeld {
            seedProbeHeld = true
            await withCheckedContinuation { heldProbe = $0 }
        }
        return corrected ? correctedToken : "a#media=1#order=1"
    }
    func completeCorrectionAndReleaseProbe() {
        corrected = true
        heldProbe?.resume()
        heldProbe = nil
    }
    func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        fullLoads += 1
        return TimelineLoadSnapshot(
            sections: sections(), validationToken: corrected ? correctedToken : "a#media=1#order=1")
    }
    private func sections() -> [TimelineSection] {
        [
            TimelineSection(
                id: "all", date: originalItems[0].captureTime, title: "",
                items: corrected ? correctedItems : originalItems)
        ]
    }
    func waitUntilSeedProbeIsHeld() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !seedProbeHeld, ContinuousClock.now < deadline { await Task.yield() }
        return seedProbeHeld
    }
    func waitForProbes(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while probes < count, ContinuousClock.now < deadline { await Task.yield() }
        return probes >= count
    }
}
