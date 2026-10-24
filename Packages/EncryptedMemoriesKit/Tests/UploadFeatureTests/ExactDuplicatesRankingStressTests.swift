import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Stress of the Duplicates ranking in an optimized build, as the macOS list drives it: the list evaluates every
/// section at once, so `groupAppeared` arrives for all groups in one burst while loads restart and the screen closes.
/// The real model ranks through the real finder; the remote reads each node like the SDK backend, a few at a time,
/// with a native cancellation call that is joined before the read returns. Runs only with `EM_CONCURRENCY_STRESS=1`:
/// `EM_CONCURRENCY_STRESS=1 swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG
/// --filter ExactDuplicatesRankingStressTests`
@MainActor
final class ExactDuplicatesRankingStressTests: XCTestCase {
    static let rounds = 300
    static let groupCount = 1_500

    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["EM_CONCURRENCY_STRESS"] == "1", "set EM_CONCURRENCY_STRESS=1")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ranking-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testBurstsOfAppearancesWithReloadsAndClosedScreensRankWithoutFault() async throws {
        let store = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        let server = EditScenarioServer()
        let native = StressNativeNodeReads()
        let finder = ExactDuplicateFinder(
            checker: server, resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal,
            mergeJournal: ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory),
            remote: StressRankingRemote(native: native), albums: server)
        let groups = (0..<Self.groupCount).map { index in
            ExactDuplicateGroup(
                contentHash: String(format: "h%05d", index), hashKeyEpoch: "e",
                members: [
                    PhotoUID(volumeID: "vol", nodeID: "g\(index)-1"), PhotoUID(volumeID: "vol", nodeID: "g\(index)-2"),
                ])
        }
        let screen = StressRankingFinder(groups: groups, ranking: finder)
        var rankedGroups = 0

        for _ in 0..<Self.rounds {
            let model = ExactDuplicatesModel(finder: screen)
            var loads = [Task { await model.load() }]
            for _ in 0..<500 where model.groups.isEmpty { await Task.yield() }
            for _ in 0..<Int.random(in: 1...4) {
                // One list update: every section appears in the same main-actor turn.
                for group in groups { model.groupAppeared(group.id) }
                // Mostly the next update follows at once; sometimes the pause passes and the shown pages rank.
                let pause = Int.random(in: 0..<4) == 0 ? Int.random(in: 160_000...250_000) : Int.random(in: 0...20_000)
                try? await Task.sleep(for: .microseconds(pause))
                switch Int.random(in: 0..<4) {
                case 0: loads.append(Task { await model.load() })
                case 1: loads.randomElement()?.cancel()
                default: break
                }
            }
            loads.forEach { $0.cancel() }
            for load in loads { await load.value }
            rankedGroups += model.groups.filter(\.isRanked).count
        }
        XCTAssertGreaterThan(rankedGroups, 0, "the ranking ranked groups")
        for _ in 0..<2_000 where native.pending > 0 { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(native.pending, 0, "every native read finished or was cancelled")
    }
}

/// The scan of the screen from memory; the ranking runs through the real finder.
private final class StressRankingFinder: ExactDuplicateMerging, @unchecked Sendable {
    let groups: [ExactDuplicateGroup]
    let ranking: ExactDuplicateFinder

    init(groups: [ExactDuplicateGroup], ranking: ExactDuplicateFinder) {
        self.groups = groups
        self.ranking = ranking
    }

    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan {
        try await Task.sleep(for: .microseconds(Int.random(in: 0...2_000)))
        return ExactDuplicateScan(groups: groups, coverage: .complete)
    }

    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool {
        try await Task.sleep(for: .microseconds(Int.random(in: 0...5_000)))
        return false
    }

    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
    }

    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async {
        await ranking.rankMembers(of: groups, ranked: ranked)
    }

    func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        requests.map { _ in .failure(CancellationError()) }
    }
}

/// The node reads of `SDKAlbumCatalogBackend.nodeFacts`: admitted through a shutdown gate, a few nodes at once, each
/// read with its own native cancellation call that the read joins before it returns.
private struct StressRankingRemote: ExactDuplicateRemote {
    static let concurrentNodeReads = 4
    let native: StressNativeNodeReads
    let admission = JoinedShutdownGate()

    func downloadRelatedFile(
        _ uid: PhotoUID, to destination: URL, allowsExpensiveNetwork: Bool
    ) async throws -> SeriesMemberSource {
        XCTFail("Ranking must not download a related file")
        throw ExactDuplicateRelatedFileTransferError.unavailable
    }
    func uploadRelatedFile(_ request: PhotoUploadRequest) async throws -> PhotoUID {
        XCTFail("Ranking must not upload a related file")
        throw ExactDuplicateRelatedFileTransferError.unavailable
    }
    func trashDuplicates(_ uids: [PhotoUID]) async throws {}
    func restoreDuplicates(_ uids: [PhotoUID]) async throws {}
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { [:] }
    func ownPhotosVolumeID() async throws -> String { "vol" }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { Set(uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws {}
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        try await Task.sleep(for: .microseconds(Int.random(in: 0...1_000)))
        return []
    }

    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        let native = native
        return try await admission.withAdmission {
            let facts = try await BoundedConcurrency.throwingMap(uids, limit: Self.concurrentNodeReads) { _ in
                try await StressNativeNodeReads.read(native)
            }
            return Dictionary(uniqueKeysWithValues: zip(uids, facts))
        }
    }
}

/// Native node reads that ignore Swift cancellation and finish on another thread after a random delay. Only the
/// cancellation call with the read's token ends a read early, as with the SDK.
final class StressNativeNodeReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [UUID: CheckedContinuation<ExactDuplicateNodeFacts, any Error>] = [:]

    var pending: Int { lock.withLock { reads.count } }

    /// One read like `SDKCancellableOperation.run`: the Swift cancellation starts the native cancellation in a task,
    /// and the read waits for that task before it returns.
    static func read(_ native: StressNativeNodeReads) async throws -> ExactDuplicateNodeFacts {
        let token = UUID()
        let cancellation = StressCancellationJoin { await native.cancel(token) }
        let result: Result<ExactDuplicateNodeFacts, any Error>
        do {
            result = .success(
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await native.start(token)
                } onCancel: {
                    cancellation.request()
                })
        } catch {
            result = .failure(error)
        }
        if Task.isCancelled { cancellation.request() }
        await cancellation.join()
        let facts = try result.get()
        try Task.checkCancellation()
        return facts
    }

    private func start(_ token: UUID) async throws -> ExactDuplicateNodeFacts {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { reads[token] = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(Int.random(in: 0...1_500))) {
                self.finish(token, with: .success(ExactDuplicateNodeFacts(isShared: false, byteSize: 10)))
            }
        }
    }

    private func cancel(_ token: UUID) async {
        try? await Task.sleep(for: .microseconds(Int.random(in: 0...200)))
        finish(token, with: .failure(CancellationError()))
    }

    private func finish(_ token: UUID, with result: Result<ExactDuplicateNodeFacts, any Error>) {
        lock.withLock { reads.removeValue(forKey: token) }?.resume(with: result)
    }
}

private final class StressCancellationJoin: @unchecked Sendable {
    private let lock = NSLock()
    private let cancel: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(cancel: @escaping @Sendable () async -> Void) { self.cancel = cancel }

    func request() {
        lock.withLock {
            guard task == nil else { return }
            task = Task { [cancel] in await cancel() }
        }
    }

    func join() async {
        await lock.withLock { task }?.value
    }
}
