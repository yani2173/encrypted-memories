import Foundation
import PhotosCore
import Synchronization
import Testing

@testable import ProtonDriveBackend

@Suite struct PhotoNameFillTests {
    @Test func theBackfillReadsEachMissingPhotoOnceIn150PhotoRequests() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeIDs = (0..<36_000).map { "n\($0)" }
        let server = FakeServer()

        let outcome = try await backfill(nodeIDs, store: store, server: server)

        #expect(outcome.requests == 240)
        #expect(outcome.recorded == 36_000)
        #expect(!outcome.deferred)
        #expect(server.requested.count == 36_000)
        #expect(Set(server.requested).count == 36_000)
        #expect(server.batchSizes.allSatisfy { $0 <= 150 })
        #expect(server.priorities == Set([.maintenance]))
        #expect(server.keyReads == 1)
        #expect(store.index().normalizedName(of: PhotoUID(volumeID: "vol", nodeID: "n123")) == "img_n123.heic")

        // A complete index makes no request and reads no key.
        let again = try await backfill(nodeIDs, store: store, server: server)
        #expect(again.requests == 0)
        #expect(server.requested.count == 36_000)
        #expect(server.keyReads == 1)
    }

    /// An app end keeps every committed batch: the next pass requests only the photos still without a name.
    @Test func theBackfillResumesWhereItStopped() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeIDs = (0..<1_000).map { "n\($0)" }
        let server = FakeServer()
        var allowed = 3

        let first = try await PhotoNameFill.backfill(
            nodeIDs: nodeIDs, volumeID: "vol", store: store,
            permits: {
                allowed -= 1
                return allowed >= 0
            },
            nameKey: { Self.decrypt }, fetch: { try await server.fetch($0) })
        #expect(first.requests == 3)
        #expect(first.deferred)

        let second = try await backfill(nodeIDs, store: store, server: server)
        #expect(second.requests == 4)
        #expect(server.requested.count == 1_000)
        #expect(Set(server.requested).count == 1_000)
    }

    @Test func aWithdrawnPermissionStopsBeforeAnyRequest() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeServer()

        let outcome = try await PhotoNameFill.backfill(
            nodeIDs: ["n1"], volumeID: "vol", store: store, permits: { false },
            nameKey: {
                Issue.record("no key read without permission")
                return Self.decrypt
            },
            fetch: { try await server.fetch($0) })

        #expect(outcome == PhotoNameFill.Outcome(requests: 0, recorded: 0, superseded: 0, deferred: true))
        #expect(server.requested.isEmpty)
    }

    /// A name that does not decrypt, and a photo that the response lacks, are recorded empty: no endless requests.
    @Test func unreadableAndMissingNamesAreRecordedEmpty() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeServer(omitting: ["gone"])

        let outcome = try await PhotoNameFill.backfill(
            nodeIDs: ["ok", "bad", "gone"], volumeID: "vol", store: store, permits: { true },
            nameKey: { { $0.contains("bad") ? nil : Self.decrypt($0) } },
            fetch: { try await server.fetch($0) })

        #expect(outcome.requests == 1)
        #expect(store.recordedNodeIDs(volumeID: "vol") == ["ok", "bad", "gone"])
        let index = store.index()
        #expect(index.count == 1)
        #expect(index.normalizedName(of: PhotoUID(volumeID: "vol", nodeID: "ok")) == "img_ok.heic")
        let again = try await backfill(["ok", "bad", "gone"], store: store, server: server)
        #expect(again.requests == 0)
    }

    /// A forget during the read (a rename event) keeps the batch's possibly old names out; the next run reads them.
    @Test func aForgetDuringTheReadDiscardsTheBatch() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeServer()
        let renamed = PhotoUID(volumeID: "vol", nodeID: "n1")

        let first = try await PhotoNameFill.backfill(
            nodeIDs: ["n1", "n2"], volumeID: "vol", store: store, permits: { true },
            nameKey: { Self.decrypt },
            fetch: { ids in
                #expect(store.forget([renamed]))
                return try await server.fetch(ids)
            })
        #expect(first.requests == 1)
        #expect(first.recorded == 0)
        #expect(first.superseded == 2)
        #expect(store.recordedNodeIDs(volumeID: "vol") == [])

        let second = try await backfill(["n1", "n2"], store: store, server: server)
        #expect(second.requests == 1)
        #expect(second.recorded == 2)
    }

    @Test func namesOfAResponseCoverOnlyTheRequestedLinks() throws {
        let links = try Self.links(["a", "b", "c"])
        let names = PhotoNameFill.names(in: links, requested: ["a", "c"], volumeID: "vol", decrypt: Self.decrypt)
        #expect(
            names == [
                PhotoUID(volumeID: "vol", nodeID: "a"): "IMG_a.HEIC",
                PhotoUID(volumeID: "vol", nodeID: "c"): "IMG_c.HEIC",
            ])
    }

    @Test(arguments: [
        (LibraryExecutionOpportunity.foregroundActive, LibraryNetworkState(), true),
        (.foregroundInactive, LibraryNetworkState(), false),
        (.backgroundPermitted, LibraryNetworkState(), false),
        (.foregroundActive, LibraryNetworkState(isConstrained: true), false),
        (.foregroundActive, LibraryNetworkState(isExpensive: true), false),
        (.foregroundActive, LibraryNetworkState(isReachable: false), false),
        (.foregroundActive, LibraryNetworkState.undetermined, false),
    ])
    func theBackfillRunsOnlyInTheForegroundOnAnOrdinaryNetwork(
        opportunity: LibraryExecutionOpportunity, network: LibraryNetworkState, expected: Bool
    ) {
        let runtime = LibraryRuntimeSnapshot(network: network, executionOpportunity: opportunity)
        #expect(PhotoNameFill.permits(runtime) == expected)
    }

    private func backfill(
        _ nodeIDs: [String], store: PhotoNameStore, server: FakeServer
    ) async throws -> PhotoNameFill.Outcome {
        try await PhotoNameFill.backfill(
            nodeIDs: nodeIDs, volumeID: "vol", store: store, permits: { true },
            nameKey: {
                server.keyReads += 1
                return Self.decrypt
            },
            fetch: { try await server.fetch($0) })
    }

    private func makeStore() throws -> (PhotoNameStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoNameFillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try #require(PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "secret"))
        return (store, directory)
    }

    /// The fake armors a name as `sealed:<name>`.
    private static func decrypt(_ armored: String) -> String? {
        armored.hasPrefix("sealed:") ? String(armored.dropFirst("sealed:".count)) : nil
    }

    fileprivate static func links(_ nodeIDs: [String]) throws -> [AlbumPhotoLinkBody] {
        let body = nodeIDs.map { ["LinkID": $0, "State": 1, "Name": "sealed:IMG_\($0).HEIC"] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode([AlbumPhotoLinkBody].self, from: data)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PhotoNameBackfillQueueTests {
    /// The caller (the metadata pass) returns while its backfill still runs.
    @Test func scheduleReturnsBeforeTheBackfillEnds() async {
        let queue = PhotoNameBackfillQueue()
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseSignal) = AsyncStream.makeStream(of: Void.self)
        let finished = Atomic<Bool>(false)
        queue.schedule {
            startedSignal.yield()
            for await _ in release { break }
            finished.store(true, ordering: .relaxed)
        }
        for await _ in started { break }
        let finishedBeforeRelease = finished.load(ordering: .relaxed)
        #expect(!finishedBeforeRelease)
        releaseSignal.yield()
        await queue.wait()
        let finishedAfterWait = finished.load(ordering: .relaxed)
        #expect(finishedAfterWait)
    }

    /// A newer backfill cancels the running one and starts only after it ended.
    @Test func aNewerBackfillCancelsAndFollowsTheRunningOne() async {
        let queue = PhotoNameBackfillQueue()
        let order = Mutex<[String]>([])
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        queue.schedule {
            startedSignal.yield()
            while !Task.isCancelled { await Task.yield() }
            order.withLock { $0.append("first ended cancelled") }
        }
        for await _ in started { break }
        queue.schedule { order.withLock { $0.append("second") } }
        await queue.wait()
        let observed = order.withLock { $0 }
        #expect(observed == ["first ended cancelled", "second"])
    }

    @Test func closeCancelsTheRunningBackfillAndAdmitsNoNewOne() async {
        let queue = PhotoNameBackfillQueue()
        let ran = Mutex<[String]>([])
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        queue.schedule {
            startedSignal.yield()
            while !Task.isCancelled { await Task.yield() }
            ran.withLock { $0.append("cancelled") }
        }
        for await _ in started { break }
        queue.close()
        queue.schedule { ran.withLock { $0.append("after close") } }
        await queue.wait()
        let observed = ran.withLock { $0 }
        #expect(observed == ["cancelled"])
    }
}

private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private let omitted: Set<String>
    private var requestedIDs: [String] = []
    private var sizes: [Int] = []
    private var seenPriorities = Set<ProtonRequestPriority>()
    private var keyReadCount = 0

    init(omitting omitted: Set<String> = []) {
        self.omitted = omitted
    }

    var requested: [String] { lock.withLock { requestedIDs } }
    var batchSizes: [Int] { lock.withLock { sizes } }
    var priorities: Set<ProtonRequestPriority> { lock.withLock { seenPriorities } }
    var keyReads: Int {
        get { lock.withLock { keyReadCount } }
        set { lock.withLock { keyReadCount = newValue } }
    }

    func fetch(_ ids: [String]) async throws -> [AlbumPhotoLinkBody] {
        let priority = ProtonRequestContext.priority
        lock.withLock {
            requestedIDs += ids
            sizes.append(ids.count)
            seenPriorities.insert(priority)
        }
        return try PhotoNameFillTests.links(ids.filter { !omitted.contains($0) })
    }
}
