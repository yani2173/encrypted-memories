import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaLocationCore

@Suite @MainActor struct LocationCrawlSessionTests {
    @Test func aStartedCrawlProbesOnlyOnceUntilItIsPausedOrRestarted() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.updateInventory(fixture.items)

        session.start(items: fixture.items, fixture.start())
        let first = session.startingTask
        session.start(items: fixture.items, fixture.start())
        #expect(session.startingTask == first, "a repeated start keeps the running start")
        try await waitUntil { session.index.scanProgress.phase == .completed }

        #expect(session.crawlStartsForTesting == 1)
        #expect(fixture.probes.value() == fixture.items.count, "a repeated start does not crawl twice")
        #expect(session.isStarted)
    }

    @Test func aPauseDuringTheHeadStartKeepsTheCrawlFromProbing() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session(headStart: .milliseconds(200))

        session.start(items: fixture.items, fixture.start())
        let starter = session.startingTask
        session.pause()
        await starter?.value

        #expect(session.crawlStartsForTesting == 0, "the paused start never reached the crawl")
        #expect(fixture.probes.value() == 0)
        #expect(!session.isStarted)
    }

    @Test func anInvalidatedStartDoesNotProbe() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session(headStart: .milliseconds(200))

        session.start(items: fixture.items, fixture.start())
        let earlier = session.invalidate()
        await earlier?.value

        #expect(session.crawlStartsForTesting == 0, "the invalidated start never reached the crawl")
        #expect(fixture.probes.value() == 0)
        #expect(!session.isStarted, "the next configuration may start the crawl again")
    }

    @Test func aStartAfterAPauseWaitsForThePrivacyStopAndThenCrawls() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session(headStart: .milliseconds(200))

        session.start(items: fixture.items, fixture.start())
        session.pause()
        session.start(items: fixture.items, fixture.start())
        try await waitUntil { session.index.scanProgress.phase == .completed }

        #expect(fixture.probes.value() == fixture.items.count, "resume crawls every photo once")
    }

    @Test func theHostsAccountCheckRejectsAStaleStart() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session(headStart: .milliseconds(50))
        let current = Flag(true)

        session.start(items: fixture.items, fixture.start(isCurrent: { current.get() }))
        let starter = session.startingTask
        current.set(false)
        await starter?.value

        #expect(session.crawlStartsForTesting == 0, "the stale start never reached the crawl")
        #expect(fixture.probes.value() == 0)
    }

    @Test func aStoreSessionIsRequiredWhenThePlatformAsksForIt() async throws {
        let fixture = Fixture(configureStore: false)
        defer { fixture.remove() }
        let session = fixture.session(requiresStoreSession: true)

        session.start(items: fixture.items, fixture.start())
        await session.startingTask?.value
        #expect(session.crawlStartsForTesting == 0, "without the account's restored location cache no crawl starts")
        #expect(fixture.probes.value() == 0)

        fixture.store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        session.prepareRestart()
        session.start(items: fixture.items, fixture.start())
        try await waitUntil { session.index.scanProgress.phase == .completed }
        #expect(fixture.probes.value() == fixture.items.count)
    }

    @Test func aFinishedCrawlRestartsOnlyForANewerInventory() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.updateInventory(fixture.items)
        session.start(items: fixture.items, fixture.start())
        try await waitUntil { session.index.scanProgress.phase == .completed }
        #expect(!session.finishedWithOutdatedInventory, "the crawl read the newest inventory")

        session.updateInventory(fixture.items + [PhotoItem.fixture("d")])
        #expect(session.finishedWithOutdatedInventory)
    }

    @Test func retiringForgetsTheStartAndTheInventory() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session(headStart: .milliseconds(200))
        session.updateInventory(fixture.items)
        session.start(items: fixture.items, fixture.start())

        let starter = session.retire()
        await starter?.value

        #expect(session.crawlStartsForTesting == 0)
        #expect(fixture.probes.value() == 0)
        #expect(!session.isStarted)
        #expect(session.startingTask == nil)
    }

    @Test func aTeardownResetKeepsTheStartTaskForTheJoin() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let session = fixture.session(headStart: .milliseconds(50))
        let current = Flag(true)
        session.updateInventory(fixture.items)
        session.start(items: fixture.items, fixture.start(isCurrent: { current.get() }))
        let starter = session.startingTask

        current.set(false)
        session.resetForTeardown()

        #expect(!session.isStarted)
        #expect(session.startingTask != nil, "the teardown joins the start task")
        await starter?.value
        #expect(session.crawlStartsForTesting == 0, "the host's account check rejects the start")
        #expect(fixture.probes.value() == 0)
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let store: PhotoLocationStore
    let probes = Counter()
    let items = ["a", "b", "c"].map(PhotoItem.fixture)

    init(configureStore: Bool = true) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crawl-session-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PhotoLocationStore(directory: directory)
        if configureStore { store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256)) }
    }

    func session(headStart: Duration = .milliseconds(1), requiresStoreSession: Bool = false) -> LocationCrawlSession {
        LocationCrawlSession(
            platform: .init(headStart: headStart, requiresStoreSession: requiresStoreSession),
            index: PhotoLocationIndex(),
            store: store,
            crawl: LocationCrawl(throttle: .zero),
            isEnabled: { true }
        )
    }

    func start(isCurrent: @escaping @MainActor () -> Bool = { true }) -> LocationCrawlSession.Start {
        let probes = probes
        return LocationCrawlSession.Start(
            accountUID: "acct",
            location: { _ in
                _ = probes.increment()
                return .found(latitude: 47.8, longitude: 13.0)
            },
            visibleDemand: { false },
            isCurrent: isCurrent
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
    func value() -> Int { lock.withLock { count } }
}

@MainActor private final class Flag {
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { self.value = value }
    func get() -> Bool { value }
}

extension PhotoItem {
    fileprivate static func fixture(_ id: String) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id), captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            mediaType: "image/jpeg")
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within \(timeout)")
}
