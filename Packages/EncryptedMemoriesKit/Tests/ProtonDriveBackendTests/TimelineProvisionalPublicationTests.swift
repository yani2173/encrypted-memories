import Foundation
import PhotosCore
import ProtonAuth
import Testing

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

extension DriveSessionStubSuite {
    @Suite struct TimelineProvisionalPublicationTests {
        @Test func theFirstPagePublishesWithoutCompletingOrReplacingTheCache() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let observations = ProvisionalObservations()
                let repository: any PhotosRepository = bridge
                let load = Task {
                    do {
                        let result = try await repository.loadTimelineSnapshot { provisional in
                            observations.received(provisional)
                        }
                        observations.finished()
                        return result
                    } catch {
                        observations.failed(String(describing: error))
                        throw error
                    }
                }
                do {
                    let clock = ContinuousClock()
                    let deadline = clock.now + .seconds(10)
                    while !SecondMetadataPageGate.isWaiting, clock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if !SecondMetadataPageGate.isWaiting {
                        print("SETUP: load failure=\(String(describing: observations.snapshot().failure))")
                        let paths = StubURLProtocol.requests().map { $0.method + " " + $0.path }
                        print("SETUP: requests=\(paths)")
                    }
                    try #require(
                        SecondMetadataPageGate.isWaiting,
                        "SETUP: the real bridge must reach the held second metadata request")
                    let expected = Set((0..<500).map { PhotoUID(volumeID: "vol1", nodeID: "photo-\($0)") })
                    let beforeCompletion = observations.snapshot()
                    #expect(
                        beforeCompletion.pages.last == expected,
                        "The first qualified page must reach its observer before the second page completes")
                    #expect(beforeCompletion.pageCounts.last == expected.count, "No duplicates or estimated photos")
                    #expect(!beforeCompletion.completed, "An unfinished listing is not a complete load")
                    #expect(try store.load() == [old], "The old inventory remains authoritative while listing")
                    #expect(store.validationToken() == oldToken, "A page must not persist or advance the cache token")
                    let requests = StubURLProtocol.requests()
                    #expect(requests.allSatisfy { $0.method == "GET" }, "A provisional page performs no remote write")
                    #expect(!requests.contains { $0.path.contains("/trash") }, "No page-driven trash reconciliation")

                    SecondMetadataPageGate.release()
                    let completed = try await load.value
                    let finalUIDs = Set(completed.sections.flatMap(\.items).map(\.uid))
                    #expect(finalUIDs == expected.union([PhotoUID(volumeID: "vol1", nodeID: "last")]))
                    #expect(completed.sections.flatMap(\.items).count == 501)
                    #expect(observations.snapshot().completed)
                    #expect(Set(try store.load().map(\.uid)) == finalUIDs)
                    #expect(
                        store.validationToken()
                            == TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-1"))
                } catch {
                    load.cancel()
                    SecondMetadataPageGate.release()
                    await bridge.shutdown()
                    _ = await load.result
                    throw error
                }
            }
        }

        @Test func cancellingOneObserverEndsItsWaitWhileTheOtherKeepsTheListing() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let firstState = ProvisionalObservations()
                let secondState = ProvisionalObservations()
                let first = observedLoad(bridge, state: firstState)
                defer { first.cancel() }
                try #require(await eventually { SecondMetadataPageGate.isWaiting })
                let second = observedLoad(bridge, state: secondState)
                defer { second.cancel() }
                try #require(await eventually { secondState.snapshot().pageCounts.last == 500 })
                #expect(firstState.snapshot().pages.last == secondState.snapshot().pages.last)
                #expect(StubURLProtocol.requests().filter { $0.path.contains("/photos?") }.count == 1)
                first.cancel()
                #expect(
                    await eventually(timeout: .seconds(1)) { firstState.snapshot().failure != nil },
                    "Cancellation must end this observer's wait before the other caller releases page two")
                #expect(!secondState.snapshot().completed)
                #expect(SecondMetadataPageGate.isWaiting, "The other caller still owns the listing")
                #expect(try store.load() == [old])
                #expect(store.validationToken() == oldToken)
                SecondMetadataPageGate.release()
                await #expect(throws: CancellationError.self) { try await first.value }
                let completed = try await second.value
                #expect(completed.sections.flatMap(\.items).count == 501)
                #expect(secondState.snapshot().completed)
                #expect(firstState.snapshot().pageCounts == [500], "A cancelled observer gets no later page")
            }
        }

        @Test func aFailedPageKeepsTheCacheAndDoesNotReplayItsProjectionIntoTheNextLoad() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let failedState = ProvisionalObservations()
                let failed = observedLoad(bridge, state: failedState)
                defer { failed.cancel() }
                try #require(await eventually { SecondMetadataPageGate.isWaiting })
                try #require(await eventually { failedState.snapshot().pageCounts.last == 500 })
                SecondMetadataPageGate.release(status: 403)
                await #expect(throws: (any Error).self) { try await failed.value }
                #expect(!failedState.snapshot().completed)
                #expect(try store.load() == [old])
                #expect(store.validationToken() == oldToken)
                #expect(!StubURLProtocol.requests().contains { $0.method != "GET" || $0.path.contains("/trash") })

                StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: metadataResponse(prefix: "new"))
                let nextState = ProvisionalObservations()
                let next = observedLoad(bridge, state: nextState)
                defer { next.cancel() }
                try #require(await eventually { SecondMetadataPageGate.isWaiting })
                let expected = Set((0..<500).map { PhotoUID(volumeID: "vol1", nodeID: "new-\($0)") })
                try #require(await eventually { nextState.snapshot().pages.last == expected })
                #expect(nextState.snapshot().pages.allSatisfy { $0 == expected }, "No projection from the failed load")
                #expect(store.validationToken() == oldToken)
                SecondMetadataPageGate.release()
                let completed = try await next.value
                #expect(
                    Set(completed.sections.flatMap(\.items).map(\.uid))
                        == expected.union([
                            PhotoUID(volumeID: "vol1", nodeID: "last")
                        ]))
                #expect(StubURLProtocol.requests().filter { $0.path.contains("/photos?") }.count == 2)
            }
        }

        @Test func shutdownJoinsAnObserverBeforeClosingItsStore() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let callback = ProvisionalCallbackHold()
                let state = ProvisionalObservations()
                let closed = ProvisionalObservations()
                let load = Task {
                    try await bridge.loadTimelineSnapshot { page in
                        state.received(page)
                        await withTaskCancellationHandler {
                            await callback.block()
                        } onCancel: {
                            state.cancelled()
                        }
                        state.recordStoreRead((try? store.load()) == [old] && store.validationToken() == oldToken)
                    }
                }
                defer { load.cancel() }
                var shutdown: Task<Void, Never>?
                do {
                    try #require(await eventually { await callback.hasEntered() })
                    shutdown = Task {
                        await bridge.shutdown()
                        closed.finished()
                    }
                    try #require(await eventually { state.snapshot().wasCancelled })
                    #expect(!closed.snapshot().completed, "Shutdown must join the held observer before store closure")
                    await callback.release()
                    await shutdown?.value
                    await #expect(throws: CancellationError.self) { try await load.value }
                    #expect(closed.snapshot().completed)
                    #expect(state.snapshot().storeReadWasSafe == true)
                    #expect(state.snapshot().pageCounts == [500], "Shutdown admits no later provisional page")
                } catch {
                    await callback.release()
                    await shutdown?.value
                    throw error
                }
            }
        }

        @Test func aSmallLibraryPublishesOnlyItsTenKnownPhotos() async throws {
            try await withFixture { bridge, store, _, _ in
                StubURLProtocol.route(
                    "GET /drive/volumes/vol1/photos", json: metadataResponse(prefix: "small", count: 10))
                let state = ProvisionalObservations()
                let completed = try await observedLoad(bridge, state: state).value
                let expected = Set((0..<10).map { PhotoUID(volumeID: "vol1", nodeID: "small-\($0)") })
                #expect(state.snapshot().pages == [expected])
                #expect(state.snapshot().pageCounts == [10])
                #expect(Set(completed.sections.flatMap(\.items).map(\.uid)) == expected)
                #expect(try store.load().count == 10)
                #expect(!SecondMetadataPageGate.isWaiting)
            }
        }

        private func metadataResponse(prefix: String = "photo", count: Int = 500) -> String {
            let page = (0..<count).map {
                #"{"LinkID":"\#(prefix)-\#($0)","CaptureTime":\#($0 + 10),"Tags":[],"RelatedPhotos":[]}"#
            }.joined(separator: ",")
            return #"{"Code":1000,"Photos":[\#(page)]}"#
        }

        private func observedLoad(
            _ bridge: DriveSDKBridge, state: ProvisionalObservations
        ) -> Task<TimelineLoadSnapshot, any Error> {
            Task {
                do {
                    let result = try await bridge.loadTimelineSnapshot { state.received($0) }
                    state.finished()
                    return result
                } catch {
                    state.failed(String(describing: error))
                    throw error
                }
            }
        }

        private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while !(await condition()), clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            return await condition()
        }

        private func withFixture(
            _ body: (DriveSDKBridge, TimelineMetadataStore, PhotoItem, String) async throws -> Void
        ) async throws {
            StubURLProtocol.reset()
            SecondMetadataPageGate.reset()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
            let old = PhotoItem(
                uid: PhotoUID(volumeID: "vol1", nodeID: "old"),
                captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
            let oldToken = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-0")
            #expect(store.save([old], validationToken: oldToken).succeeded)
            StubURLProtocol.route(
                "GET /drive/shares",
                json: #"{"Code":1000,"Shares":[{"ShareID":"share1","VolumeID":"vol1","LinkID":"root","State":1}]}"#)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"event-1"}"#)
            for cursor in ["event-0", "event-1"] {
                StubURLProtocol.route(
                    "GET /drive/volumes/vol1/events/\(cursor)",
                    json: #"{"Code":1000,"EventID":"event-1","More":0,"Refresh":0,"Events":[]}"#)
                StubURLProtocol.route(
                    "GET /drive/v2/volumes/vol1/events/\(cursor)",
                    json: #"{"Code":1000,"EventID":"event-1","More":false,"Refresh":false,"Events":[]}"#)
            }
            StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: metadataResponse())
            let bridge = try await makeBridge(directory: directory, store: store)
            do {
                try await body(bridge, store, old, oldToken)
            } catch {
                SecondMetadataPageGate.release()
                await bridge.shutdown()
                throw error
            }
            SecondMetadataPageGate.release()
            await bridge.shutdown()
        }

        private func makeBridge(directory: URL, store: TimelineMetadataStore) async throws -> DriveSDKBridge {
            let governor = ProtonRequestGovernor()
            let protocols: [AnyClass] = [SecondMetadataPageGate.self, StubURLProtocol.self]
            let session = DriveSession(
                session: ProtonSession(uid: "page-fixture", accessToken: "", refreshToken: "", keyPassword: ""),
                store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                accountCacheDirectory: directory, requestGovernor: governor, urlProtocolClasses: protocols)
            let client = try await EncryptedMemoriesClient(
                configuration: ProtonDriveClientConfiguration(
                    baseURL: "https://fixture.invalid/", clientUID: "fixture"),
                httpClient: SDKHttpClient(
                    driveSession: session, requestGovernor: governor, urlProtocolClasses: protocols),
                accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
                logCallback: { _ in }, featureFlagProviderCallback: { _, completion in completion(false) },
                recordMetricEventCallback: { _ in })
            let crypto = DriveCrypto(addressKeys: [], signers: [])
            let gate = TimelineMetadataStartGate()
            gate.buildStarted()
            return DriveSDKBridge(
                prepared: .init(
                    photosClient: client, uploadClientUID: "fixture", driveSession: session,
                    requestGovernor: governor, expensiveUploadAccess: ExpensiveUploadAccess(),
                    timelineStore: store, timelineOrderStore: nil, firstIndexBuildGate: gate,
                    metadataReconciliation: TimelineMetadataReconciliation(startGate: gate), crypto: crypto,
                    photosVolumeBootstrap: PhotosVolumeBootstrapService(session: session, crypto: crypto),
                    recentlyDeletedStore: RecentlyDeletedListingStore(
                        directory: directory, accountUID: "fixture", keyPassword: ""),
                    photoNames: nil, recentlyDeleted: RecentlyDeletedIdentities(listing: nil),
                    uploadManifestURL: directory.appendingPathComponent("manifest.sqlite"),
                    uploadManifestPolicy: .conservative))
        }
    }
}

private final class ProvisionalObservations: @unchecked Sendable {
    struct Snapshot {
        var pages: [Set<PhotoUID>] = []
        var pageCounts: [Int] = []
        var completed = false
        var failure: String?
        var storeReadWasSafe: Bool?
        var wasCancelled = false
    }
    private let lock = NSLock()
    private var value = Snapshot()

    func received(_ page: ProvisionalTimelineSnapshot) {
        lock.withLock {
            let items = page.sections.flatMap(\.items)
            value.pages.append(Set(items.map(\.uid)))
            value.pageCounts.append(items.count)
        }
    }

    func finished() { lock.withLock { value.completed = true } }
    func failed(_ error: String) { lock.withLock { value.failure = error } }
    func recordStoreRead(_ safe: Bool) { lock.withLock { value.storeReadWasSafe = safe } }
    func cancelled() { lock.withLock { value.wasCancelled = true } }
    func snapshot() -> Snapshot { lock.withLock { value } }
}

/// Holds only the second Photos request; every other request uses the existing recording HTTP fixture.
private final class SecondMetadataPageGate: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: SecondMetadataPageGate?

    static var isWaiting: Bool { lock.withLock { waiting != nil } }
    static func reset() { lock.withLock { waiting = nil } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/drive/volumes/vol1/photos"
            && request.url?.query?.contains("PreviousPageLastLinkID=") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.waiting = self } }
    override func stopLoading() {
        Self.lock.withLock { if Self.waiting === self { Self.waiting = nil } }
    }

    static func release(status: Int = 200) {
        let pending = lock.withLock { () -> SecondMetadataPageGate? in
            defer { waiting = nil }
            return waiting
        }
        guard let pending, let url = pending.request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        pending.client?.urlProtocol(pending, didReceive: response, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(
            pending,
            didLoad: Data(
                (status == 200
                    ? #"{"Code":1000,"Photos":[{"LinkID":"last","CaptureTime":1000,"Tags":[],"RelatedPhotos":[]}]}"#
                    : #"{"Code":\#(status)}"#).utf8))
        pending.client?.urlProtocolDidFinishLoading(pending)
    }
}

private actor ProvisionalCallbackHold {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
