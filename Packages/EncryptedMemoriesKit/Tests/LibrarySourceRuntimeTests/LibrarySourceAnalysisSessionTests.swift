import AlbumCore
import CryptoKit
import Foundation
import MLSearchCore
import MediaByteCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import LibrarySourceRuntime
@testable import ProtonDriveBackend

/// Ordering contract of the shared host owner: generation-fenced admissions, joined lifecycle work, and
/// chained shutdowns. Both the Mac and the iOS library host route every source-analysis runtime through it.
@MainActor
@Suite struct LibrarySourceAnalysisSessionTests {
    private final class Fixture {
        let root: URL
        let coordinator: LibrarySourceCoordinator
        let feed: ThumbnailFeedCore

        init() async {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("library-source-session-\(UUID().uuidString)", isDirectory: true)
            let backend = SessionTestBackend()
            coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
            await coordinator.prepare()
            let cache = ThumbnailCache(namespace: "session-test", rootDirectory: root)
            cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
            feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
            await feed.setPrefetchEnabled(false)
        }

        func makeRuntime() -> LibrarySourceAnalysisRuntime {
            LibrarySourceAnalysisRuntime(
                coordinator: coordinator, feed: feed, assets: MLAssetUniverse(), onAssetsChanged: {})
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let item = PhotoItem(
        uid: PhotoUID(volumeID: "primary", nodeID: "photo"),
        captureTime: Date(timeIntervalSince1970: 1),
        mediaType: "image/jpeg"
    )

    @Test func stopWithoutARuntimeReturnsTheLatestShutdown() async {
        let session = LibrarySourceAnalysisSession()
        #expect(session.stop() == nil)

        let fixture = await Fixture()
        session.install(fixture.makeRuntime())
        let shutdown = session.stop()
        #expect(shutdown != nil)
        #expect(session.runtime == nil)
        #expect(session.stop() == shutdown)
        await shutdown?.value
    }

    @Test func onlyTheLatestRejectedInventoryIsReported() async {
        let fixture = await Fixture()
        let runtime = fixture.makeRuntime()
        await runtime.shutdown()
        let session = LibrarySourceAnalysisSession()
        session.install(runtime)
        let failures = FailureCounter()

        session.replacePrimaryInventory([Self.item], authority: .authoritative) { failures.count += 1 }
        session.replacePrimaryInventory([Self.item], authority: .authoritative) { failures.count += 1 }
        await failures.waitForCount(1)
        for _ in 0..<20 { await Task.yield() }

        #expect(failures.count == 1, "a superseded generation must never report its admission")
    }

    @Test func admissionAfterStopIsNotReported() async {
        let fixture = await Fixture()
        let runtime = fixture.makeRuntime()
        await runtime.shutdown()
        let session = LibrarySourceAnalysisSession()
        session.install(runtime)
        let failures = FailureCounter()

        session.replacePrimaryInventory([Self.item], authority: .authoritative) { failures.count += 1 }
        await session.stop()?.value
        for _ in 0..<20 { await Task.yield() }

        #expect(failures.count == 0, "a stopped runtime must not fail the next account's library")
    }

    @Test func synchronizeWithoutARuntimeIsUnavailable() async {
        let session = LibrarySourceAnalysisSession()
        let admission = await session.synchronizePrimaryInventory([Self.item], authority: .authoritative)
        #expect(admission == .unavailable)
    }

    @Test func synchronizeStartsTheInstalledRuntime() async {
        let fixture = await Fixture()
        let session = LibrarySourceAnalysisSession()
        session.install(fixture.makeRuntime())

        let admission = await session.synchronizePrimaryInventory([Self.item], authority: .authoritative)

        #expect(admission == .accepted)
        await session.stop()?.value
    }

    @Test func stopJoinsLifecycleWorkBeforeTheRuntimeShutsDown() async {
        let fixture = await Fixture()
        let runtime = fixture.makeRuntime()
        let session = LibrarySourceAnalysisSession()
        session.install(runtime)
        let gate = LifecycleGate()
        let order = OrderLog()

        session.enqueueLifecycle { _ in
            await gate.wait()
            await order.append("lifecycle")
        }
        await gate.waitUntilEntered()
        let shutdown = session.stop()
        let shutdownFinished = Task {
            await shutdown?.value
            await order.append("shutdown")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await order.entries.isEmpty, "shutdown must wait for lifecycle work that already started")

        await gate.open()
        await shutdownFinished.value

        #expect(await order.entries == ["lifecycle", "shutdown"])
        let afterShutdown = await runtime.replacePrimaryInventory(
            [Self.item], authority: .authoritative, generation: 99)
        #expect(afterShutdown == .unavailable)
    }

    @Test func aReplacementWaitsForThePreviousShutdown() async {
        let fixture = await Fixture()
        let session = LibrarySourceAnalysisSession()
        session.install(fixture.makeRuntime())
        let gate = LifecycleGate()
        session.enqueueLifecycle { _ in await gate.wait() }
        await gate.waitUntilEntered()
        let shutdown = session.stop()

        let replacementFixture = await Fixture()
        session.install(replacementFixture.makeRuntime())
        let order = OrderLog()
        let admission = Task {
            let result = await session.synchronizePrimaryInventory([Self.item], authority: .authoritative)
            await order.append("replacement started")
            return result
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(session.shutdownTask == shutdown)
        #expect(await order.entries.isEmpty, "a replacement must not start before the previous shutdown ends")

        await gate.open()
        #expect(await admission.value == .accepted)
        #expect(await order.entries == ["replacement started"])
        await session.stop()?.value
    }
}

@MainActor
private final class FailureCounter {
    var count = 0

    func waitForCount(_ expected: Int) async {
        // The limit only ends a hung test. Machine load never reaches it.
        let deadline = ContinuousClock.now + .seconds(300)
        while count < expected, ContinuousClock.now < deadline { await Task.yield() }
    }
}

private actor LifecycleGate {
    private var entered = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor OrderLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

private actor SessionTestBackend: LibrarySourceRemoteBackend, PriorityThumbnailBatchLoader {
    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { [] }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] { [] }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        .delivered
    }
}
