import Foundation
import PhotosCore
import UploadCore
import XCTest

final class PendingBackupRunnerHandoffReachabilityTests: XCTestCase {
    // The state-store seam schedules exclusion after enqueue admission but before its queue write.
    // This exercises file backup without edit replacement. It does not prove PhotoKit or SDK reachability.
    func testExclusionDuringEnqueueProducesBothDedupHandoffsAfterQueueRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-handoff-chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = ChainClock(date)
        let pending = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        defer { pending.close() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        defer { queue.close() }
        let state = try XCTUnwrap(
            UploadBackupStateManifestStore(
                url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)))
        defer { state.close() }
        let identities = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        defer { identities.close() }
        let ownership = try XCTUnwrap(
            BackupExecutionLockManifestStore(
                url: directory.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName),
                now: { clock.now })
        )
        defer { ownership.close() }
        XCTAssertTrue(ownership.acquire(owner: .foreground, runID: "chain-owner").didAcquire)
        defer { XCTAssertTrue(ownership.release(runID: "chain-owner")) }
        guard case .busy = ownership.acquire(owner: .background, runID: "other-owner") else {
            return XCTFail("a healthy execution lease must reject another owner")
        }

        let source = UploadSourceIdentity.file(directory.appendingPathComponent("chain.jpg"))
        let key = PendingSourceKey(source)
        let stateBoundary = ChainStateBoundary(state)
        let preflight = UploadBackupPreflightIndex(store: stateBoundary, now: { clock.now })
        let engine = UploadBackupSyncEngine(preflight: preflight, queue: queue, exclusions: pending, now: { clock.now })
        let recorder = PendingBackupEventRecorder(store: pending, now: { clock.now })
        defer { recorder.finish() }
        let uploader = ChainUploader()
        let runner = BackupSyncRunner(
            queue: queue, preflight: preflight, resolver: ChainResolver(),
            identityResolver: UploadDedupePipeline(store: identities, checker: ChainDuplicates(), now: { clock.now }),
            uploader: uploader,
            configuration: .init(throttle: BackupThrottlePolicy(baseConcurrency: 2)),
            events: recorder, now: { clock.now })

        _ = try await engine.enqueue(ChainResolver.candidate(source: source, revision: 1))
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        let original = try XCTUnwrap(pending.latestHandoffs(for: [key])[key])
        XCTAssertEqual(original.kind, .uploaded)
        XCTAssertEqual(original.remote.nodeID, "runner-A")
        XCTAssertEqual(uploader.uploadCount, 1)

        stateBoundary.beforeNextLookupReturns {
            let excluded = pending.exclude(
                [PendingExclusionRequest(key: key, presentation: nil, remote: original.remote)], at: clock.now)
            guard let states = excluded, let excludedState = states.first else {
                return XCTFail("the exclusion must persist during the admitted enqueue")
            }
            _ = queue.removeSources(kind: source.kind, identifiers: [source.identifier])
            XCTAssertTrue(
                pending.completeEffect(.queueSync, for: key, generation: excludedState.generation, at: clock.now))
            XCTAssertEqual(pending.beginRemoteOperation(.remoteTrash, for: states), [key])
        }
        _ = try await engine.enqueueBatch([
            ChainResolver.candidate(source: source, revision: 2),
            ChainResolver.candidate(source: source, revision: 3),
        ])
        for revision in [Int64(2), 3] {
            XCTAssertNotNil(try queue.entry(for: source, revision: UploadBackupRevision(rawValue: revision)))
        }
        // C represents a persisted retry that becomes eligible after the already queued B.
        XCTAssertTrue(
            queue.updateState(
                source: source, revision: UploadBackupRevision(rawValue: 3), state: .queuedForUpload,
                attempts: nil, lastError: nil, updatedAt: date.addingTimeInterval(2)))
        let excluded = try XCTUnwrap(pending.sourceStateRead(for: key).state)
        let generation = excluded.generation
        XCTAssertEqual(excluded.desired, .excluded)
        XCTAssertFalse(excluded.needsQueueSync, "queue removal completed before the stale enqueue wrote B and C")
        XCTAssertEqual(excluded.remoteOperation, .remoteTrash)
        _ = try await engine.enqueue(ChainResolver.candidate(source: source, revision: 4))
        XCTAssertNil(try queue.entry(for: source, revision: UploadBackupRevision(rawValue: 4)))

        clock.advance(by: 1)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        let middle = try XCTUnwrap(pending.handoffs(forRemoteLinkIDs: ["runner-B"]).first)
        XCTAssertEqual(middle.kind, .deduplicated)
        XCTAssertTrue(pending.handoffs(forRemoteLinkIDs: ["runner-C"]).isEmpty)
        clock.advance(by: 2)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        try await runner.checkCancellation()

        let handoffs = pending.handoffs(forRemoteLinkIDs: ["runner-B", "runner-C"])
        XCTAssertEqual(Set(handoffs.map(\.remote.nodeID)), ["runner-B", "runner-C"])
        XCTAssertTrue(handoffs.allSatisfy { $0.kind == .deduplicated })
        XCTAssertEqual(uploader.uploadCount, 1, "B and C must come from real dedupe decisions without another upload")
        let waiting = try XCTUnwrap(pending.sourceStateRead(for: key).state)
        XCTAssertEqual(waiting.remote, original.remote)
        XCTAssertTrue(waiting.needsRemoteTrash)
        XCTAssertFalse(waiting.needsQueueSync)
        XCTAssertEqual(waiting.remoteOperation, .remoteTrash)
        for revision in [Int64(2), 3] {
            XCTAssertEqual(
                try queue.entry(for: source, revision: UploadBackupRevision(rawValue: revision))?.state,
                .alreadyBackedUp)
        }

        XCTAssertTrue(
            pending.completeEffect(
                .remoteTrash, for: key, generation: generation, remoteLinkID: original.remote.nodeID, at: clock.now))
        let latest = try XCTUnwrap(pending.sourceStateRead(for: key).state)
        XCTAssertEqual(latest.remote?.nodeID, "runner-C")
        XCTAssertTrue(latest.needsRemoteTrash)
        XCTAssertEqual(pending.beginRemoteOperation(.remoteTrash, for: [latest]), [key])
        XCTAssertTrue(
            pending.completeEffect(
                .remoteTrash, for: key, generation: generation, remoteLinkID: "runner-C", at: clock.now))
        let remaining = pending.dueSourceStatesRead(by: clock.now)
        XCTAssertTrue(remaining.complete)
        XCTAssertEqual(
            remaining.states.filter { $0.key == key && $0.needsRemoteTrash }.compactMap { $0.remote?.nodeID },
            ["runner-B"], "the runner-generated B handoff must remain due after A and C complete")
    }
}

private final class ChainStateBoundary: UploadBackupStateStore, @unchecked Sendable {
    private let base: UploadBackupStateManifestStore
    private let lock = NSLock()
    private var boundary: (@Sendable () -> Void)?

    init(_ base: UploadBackupStateManifestStore) { self.base = base }

    func beforeNextLookupReturns(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { boundary = action }
    }

    func lookupBatch(_ snapshots: [UploadBackupAssetSnapshot]) -> [UploadBackupStateLookup] {
        let result = base.lookupBatch(snapshots)
        let action = lock.withLock {
            let action = boundary
            boundary = nil
            return action
        }
        action?()
        return result
    }

    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
        base.record(for: source, revision: revision)
    }
    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool { base.hasAnyRecord(for: source) }
    func upsert(_ record: UploadBackupAssetRecord) -> Bool { base.upsert(record) }
    func upsertBatch(_ records: [UploadBackupAssetRecord]) -> Bool { base.upsertBatch(records) }
    func removeRecords(for source: UploadSourceIdentity, keeping revisions: Set<UploadBackupRevision>) -> Bool {
        base.removeRecords(for: source, keeping: revisions)
    }
    func count() -> Int { base.count() }
}

private final class ChainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private struct ChainResolver: BackupResourceResolving {
    static func candidate(source: UploadSourceIdentity, revision: Int64) -> UploadBackupAssetCandidate {
        UploadBackupAssetCandidate(
            snapshot: UploadBackupAssetSnapshot(
                source: source, revision: UploadBackupRevision(rawValue: revision), resourceCount: 1),
            originalFilename: "chain.jpg", byteCount: 1)
    }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        BackupResolvedResource(
            candidate: Self.candidate(source: entry.source, revision: entry.revision.rawValue),
            descriptor: UploadResourceDescriptor(
                source: entry.source, fileURL: URL(fileURLWithPath: entry.source.identifier),
                filename: entry.originalFilename, fileSize: 1,
                modificationDate: Date(timeIntervalSince1970: Double(entry.revision.rawValue)),
                precomputedSHA1Digest: Data(repeating: UInt8(entry.revision.rawValue), count: 20)),
            mediaType: "image/jpeg", captureDate: Date(timeIntervalSince1970: 1_750_000_000))
    }
}

private struct ChainDuplicates: UploadDuplicateChecking {
    func nameHash(forCorrectedName name: String) async throws -> String { "chain-name" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { sha1Hex }
    func hashKeyEpoch() async throws -> String { "chain-epoch" }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        [UInt8(2), 3].map { value in
            RemotePhotoDuplicate(
                nameHash: "chain-name", contentHash: String(repeating: value == 2 ? "02" : "03", count: 20),
                linkState: .active, linkID: value == 2 ? "runner-B" : "runner-C")
        }
    }

    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }

    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        Dictionary(
            uniqueKeysWithValues: linkIDs.map { ($0, RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil)) })
    }

    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        UploadLinkStateSnapshot(
            states: Dictionary(
                uniqueKeysWithValues: linkIDs.map { ($0, RemotePhotoDuplicate.LinkState.active.rawValue) }),
            complete: true)
    }
}

private final class ChainUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let admission = UploadNetworkAdmission()
    private let lock = NSLock()
    private var count = 0
    var uploadCount: Int { lock.withLock { count } }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await admission.reserve(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        lock.withLock { count += 1 }
        return PhotoUID(volumeID: "vol", nodeID: "runner-A")
    }

    func cancel(token: UUID) async {}
}
