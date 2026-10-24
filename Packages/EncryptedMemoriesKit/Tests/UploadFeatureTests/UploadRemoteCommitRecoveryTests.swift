import AlbumSyncCore
import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

private final class RecoveryTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !signaled else { return [] }
            signaled = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if lock.withLock({ signaled }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var isSignaled: Bool { lock.withLock { signaled } }
}

private final class RecoveryResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<AlbumSyncBackupReport, any Error>?

    var value: Result<AlbumSyncBackupReport, any Error>? { lock.withLock { stored } }

    func set(_ value: Result<AlbumSyncBackupReport, any Error>) { lock.withLock { stored = value } }
}

private final class RecoveryControlledBarrier: @unchecked Sendable {
    let firstEntered = RecoveryTestLatch()
    let secondEntered = RecoveryTestLatch()
    let firstExited = RecoveryTestLatch()
    private let lock = NSLock()
    private var enteredCount = 0
    private var exitedCount = 0
    private var releasePermits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            // Count the entry and queue the waiter together, so the entry order is the release order.
            let (entered, resumeNow) = lock.withLock { () -> (Int, Bool) in
                enteredCount += 1
                if releasePermits > 0 {
                    releasePermits -= 1
                    return (enteredCount, true)
                }
                waiters.append(continuation)
                return (enteredCount, false)
            }
            if entered == 1 { firstEntered.signal() }
            if entered == 2 { secondEntered.signal() }
            if resumeNow { continuation.resume() }
        }

        let exited = lock.withLock {
            exitedCount += 1
            return exitedCount
        }
        if exited == 1 { firstExited.signal() }
    }

    func releaseOne() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else {
                releasePermits += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }
}

private final class RecoveryIdentityRecorder: UploadIdentityResolving, @unchecked Sendable {
    struct Record: Equatable {
        let descriptor: UploadResourceDescriptorSnapshot
        let identity: UploadIdentity
        let volumeID: String
        let linkID: String
    }

    private let lock = NSLock()
    private var values: [Record] = []
    private var remainingFailures: Int
    private let preflight: UploadPreflightResult?

    init(failures: Int = 0, preflight: UploadPreflightResult? = nil) {
        remainingFailures = failures
        self.preflight = preflight
    }

    var records: [Record] { lock.withLock { values } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        if let preflight { return preflight }
        throw UploadError.backend("normal dedupe resolution must not run during receipt settlement")
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        let shouldFail = lock.withLock {
            if remainingFailures > 0 {
                remainingFailures -= 1
                return true
            }
            values.append(
                Record(
                    descriptor: UploadResourceDescriptorSnapshot(descriptor),
                    identity: identity,
                    volumeID: remoteVolumeID,
                    linkID: remoteLinkID
                ))
            return false
        }
        if shouldFail { throw UploadError.backend("injected manifest failure") }
    }
}

private final class BlockingRecoveryIdentityRecorder: UploadIdentityResolving, @unchecked Sendable {
    let entered = RecoveryTestLatch()
    let cancellationObserved = RecoveryTestLatch()
    let release = RecoveryTestLatch()
    let completed = RecoveryTestLatch()
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    private var proofRequests: [Int] = []
    var proofRequestSizes: [Int] { lock.withLock { proofRequests } }
    var onProofCancellation: (@Sendable () -> Void)?

    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        let first = lock.withLock {
            proofRequests.append(identities.count)
            return proofRequests.count == 1
        }
        if first {
            entered.signal()
            await withTaskCancellationHandler {
                await release.wait()
            } onCancel: {
                cancellationObserved.signal()
                onProofCancellation?()
            }
            completed.signal()
        }
        return Dictionary(
            uniqueKeysWithValues: identities.map {
                (
                    $0,
                    .init(
                        externalIdentity: $0, resourceCount: 1, remoteLinkIDs: ["proof-\($0.identifier)"],
                        hashKeyEpoch: "epoch")
                )
            })
    }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw UploadError.backend("normal dedupe resolution must not run during receipt settlement")
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        entered.signal()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            cancellationObserved.signal()
        }
        lock.withLock { writes += 1 }
        completed.signal()
    }
}

private final class RecoveryResourceResolver: BackupResourceResolving, @unchecked Sendable {
    enum Result {
        case value(BackupResolvedResource?)
        case failure(any Error)
    }

    private let lock = NSLock()
    private let result: Result
    private var calls = 0

    init(_ result: Result) {
        self.result = result
    }

    var callCount: Int { lock.withLock { calls } }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        lock.withLock { calls += 1 }
        switch result {
        case .value(let value): return value
        case .failure(let error): throw error
        }
    }
}

final class UploadRemoteCommitRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private let modified = Date(timeIntervalSince1970: 1_725_000_000)
    private let digest = Data(repeating: 0xA4, count: 20)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-remote-commit-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testPersistedDescriptorRecoversCheckingPrimaryAfterReopenWithoutLocalRead() async throws {
        let source = source("primary")
        let descriptor = descriptor(source: source, filename: "primary.heic", fileExists: false)
        let reconciliation = reconciliation(descriptor: descriptor)
        let entry = seedEntry(reconciliation: reconciliation, state: .checking, byteCount: nil)
        let url = queueURL()
        try persist(entry, at: url)

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        let identityRecorder = RecoveryIdentityRecorder()
        let settled = try await UploadRemoteCommitRecovery(
            queue: reopened,
            resolver: resolver,
            identityResolver: identityRecorder
        ).settleAll()

        XCTAssertEqual(settled, 1)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertNil(reopened.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(identityRecorder.records.first?.descriptor, UploadResourceDescriptorSnapshot(descriptor))
        XCTAssertEqual(identityRecorder.records.first?.linkID, "remote-primary")
    }

    func testDescriptorReceiptRejectsMissingOrWrongQueueBindingAndPrimaryEvidence() async throws {
        let queueSource = source("bound-primary")
        let queueRevision = revision()
        let validDescriptor = descriptor(source: queueSource, filename: "bound-primary.heic", fileExists: false)
        let receipt = UploadRemoteCommitReceipt(remoteVolumeID: "remote-volume", remoteLinkID: "remote-primary")
        let validIdentity = identity(filename: validDescriptor.filename)
        let wrongNameDescriptor = descriptor(source: queueSource, filename: "other.heic", fileExists: false)
        let wrongSizeDescriptor = descriptor(
            source: queueSource,
            filename: validDescriptor.filename,
            fileExists: false,
            fileSize: 8_192
        )
        let cases: [(String, UploadRemoteCommitReconciliation)] = [
            (
                "missing-binding",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor)
                )
            ),
            (
                "wrong-source",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(
                        source: source("other-source"),
                        revision: queueRevision
                    )
                )
            ),
            (
                "wrong-revision",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(
                        source: queueSource,
                        revision: UploadBackupRevision(rawValue: queueRevision.rawValue + 1)
                    )
                )
            ),
            (
                "wrong-resource",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(
                        source: source("bound-primary", resource: .livePairedVideo),
                        revision: queueRevision
                    )
                )
            ),
            (
                "wrong-primary-name",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: identity(filename: wrongNameDescriptor.filename),
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(wrongNameDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(source: queueSource, revision: queueRevision)
                )
            ),
            (
                "wrong-known-size",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(wrongSizeDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(source: queueSource, revision: queueRevision)
                )
            ),
        ]

        for (name, reconciliation) in cases {
            let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite"))
            )
            let entry = seedEntry(source: queueSource, reconciliation: reconciliation)
            XCTAssertTrue(store.upsert(entry))
            let recorder = RecoveryIdentityRecorder()

            do {
                _ = try await UploadRemoteCommitRecovery(
                    queue: store,
                    resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                    identityResolver: recorder
                ).settleAll()
                XCTFail("\(name) must fail closed")
            } catch let error as UploadRemoteCommitRecoveryError {
                XCTAssertTrue(
                    error == .invalidReceipt(entry.source, entry.revision)
                        || error == .descriptorMismatch(entry.source, entry.revision)
                )
            }
            XCTAssertTrue(recorder.records.isEmpty)
            XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        }
    }

    func testDescriptorReceiptRejectsWhitespaceIdentityHashesButAcceptsOpaqueValues() async throws {
        for (name, nameHash, contentHash) in [
            ("empty-name", "", "opaque-content"),
            ("whitespace-name", " \n\t", "opaque-content"),
            ("empty-content", "opaque-name", ""),
            ("whitespace-content", "opaque-name", " \n\t"),
        ] {
            let queueSource = source(name)
            let descriptor = descriptor(source: queueSource, filename: "\(name).heic", fileExists: false)
            let reconciliation = reconciliation(
                descriptor: descriptor,
                identity: identity(
                    filename: descriptor.filename,
                    nameHash: nameHash,
                    contentHash: contentHash
                )
            )
            let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite"))
            )
            let entry = seedEntry(reconciliation: reconciliation)
            XCTAssertTrue(store.upsert(entry))

            do {
                _ = try await UploadRemoteCommitRecovery(
                    queue: store,
                    resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                    identityResolver: RecoveryIdentityRecorder()
                ).settleAll()
                XCTFail("\(name) must fail closed")
            } catch let error as UploadRemoteCommitRecoveryError {
                XCTAssertEqual(error, .invalidReceipt(entry.source, entry.revision))
            }
            XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        }

        let opaqueSource = source("opaque-positive")
        let opaqueDescriptor = descriptor(
            source: opaqueSource,
            filename: "opaque-positive.heic",
            fileExists: false
        )
        let opaqueEntry = seedEntry(
            reconciliation: reconciliation(
                descriptor: opaqueDescriptor,
                identity: identity(
                    filename: opaqueDescriptor.filename,
                    nameHash: "shared-protocol-name-value",
                    contentHash: "shared-protocol-content-value"
                )
            )
        )
        let opaqueDirectory = tempDirectory.appendingPathComponent("opaque-positive", isDirectory: true)
        try FileManager.default.createDirectory(at: opaqueDirectory, withIntermediateDirectories: true)
        let opaqueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: opaqueDirectory.appendingPathComponent("queue.sqlite"))
        )
        XCTAssertTrue(opaqueStore.upsert(opaqueEntry))
        let opaqueRecorder = RecoveryIdentityRecorder()
        let opaqueSettled = try await UploadRemoteCommitRecovery(
            queue: opaqueStore,
            resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            identityResolver: opaqueRecorder
        ).settleAll()
        XCTAssertEqual(opaqueSettled, 1)
        XCTAssertEqual(opaqueRecorder.records.count, 1)
    }

    func testInjectedManifestFailurePersistsReceiptAndReopenSettlesWithoutSecondUpload() async throws {
        let source = source("crash-window")
        let descriptor = descriptor(source: source, filename: "crash-window.heic", fileExists: false)
        let identity = identity(filename: descriptor.filename)
        let entry = UploadBackupSyncQueueEntry(
            source: source,
            revision: revision(),
            originalFilename: descriptor.filename,
            byteCount: descriptor.fileSize,
            updatedAt: modified
        )
        let queueURL = self.queueURL()
        let stateURL = tempDirectory.appendingPathComponent("state.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let state = try XCTUnwrap(UploadBackupStateManifestStore(url: stateURL))
        XCTAssertTrue(queue.upsert(entry))
        // Both the initial settlement and the runner's immediate reconciliation must fail
        // before eligible-only mode leaves a durable receipt for the simulated restart.
        let identityResolver = RecoveryIdentityRecorder(
            failures: 2,
            preflight: UploadPreflightResult(identity: identity, decision: .upload)
        )
        let uploader = MockUploader()
        let resolved = resolvedResource(
            queueSource: source,
            revision: entry.revision,
            descriptor: descriptor
        )
        let resolver = RecoveryResourceResolver(.value(resolved))
        let runner = BackupSyncRunner(
            queue: queue,
            preflight: UploadBackupPreflightIndex(store: state),
            resolver: resolver,
            identityResolver: identityResolver,
            uploader: uploader
        )

        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        let pending = try XCTUnwrap(queue.entry(for: source, revision: entry.revision))
        XCTAssertEqual(pending.state, .needsRemoteReconciliation)
        XCTAssertEqual(pending.remoteCommitReconciliation?.descriptor, UploadResourceDescriptorSnapshot(descriptor))
        XCTAssertEqual(uploader.requests.count, 1)
        queue.close()
        state.close()

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let settledCount = try await UploadRemoteCommitRecovery(
            queue: reopened,
            resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            identityResolver: identityResolver
        ).settleAll()
        XCTAssertEqual(settledCount, 1)
        XCTAssertEqual(identityResolver.records.count, 1)
        XCTAssertEqual(uploader.requests.count, 1, "settlement replay must not call the uploader again")
        XCTAssertNil(reopened.entry(for: source, revision: entry.revision))
    }

    func testPersistedSecondaryRepairsExactRemoteLinkWithoutResolvingOrSchedulingSibling() async throws {
        let primary = source("live")
        let secondary = source("live", resource: .photoKit(role: "alternate", ordinal: 2))
        let descriptor = descriptor(source: secondary, filename: "live.mov", fileExists: false)
        XCTAssertNil(descriptor.mainResource)
        let reconciliation = reconciliation(
            descriptor: descriptor,
            queueSource: primary,
            linkID: "remote-secondary"
        )
        let entry = seedEntry(source: primary, reconciliation: reconciliation)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        let recorder = RecoveryIdentityRecorder()

        let settledCount = try await UploadRemoteCommitRecovery(
            queue: store,
            resolver: resolver,
            identityResolver: recorder
        ).settleAll()
        XCTAssertEqual(settledCount, 1)

        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [secondary])
        XCTAssertEqual(recorder.records.map(\.linkID), ["remote-secondary"])
    }

    func testLegacyReceiptUsesMatchedSecondaryAndDigestWithoutUploader() async throws {
        let primary = source("legacy-live")
        let secondary = source("legacy-live", resource: .livePairedVideo)
        let primaryDescriptor = descriptor(source: primary, filename: "legacy-live.heic", fileExists: false)
        let secondaryDescriptor = descriptor(source: secondary, filename: "legacy-live.mov", fileExists: false)
        let resolved = resolvedResource(
            queueSource: primary,
            revision: revision(),
            descriptor: primaryDescriptor,
            secondaries: [BackupSecondaryResource(descriptor: secondaryDescriptor, mediaType: "video/quicktime")]
        )
        let legacy = reconciliation(
            descriptor: nil,
            source: secondary,
            identity: identity(filename: secondaryDescriptor.filename)
        )
        let entry = seedEntry(source: primary, reconciliation: legacy)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))
        let recorder = RecoveryIdentityRecorder()

        let settled = try await UploadRemoteCommitRecovery(
            queue: store,
            resolver: RecoveryResourceResolver(.value(resolved)),
            identityResolver: recorder
        ).settleAll()

        XCTAssertEqual(settled, 1)
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [secondary])
        XCTAssertNil(store.entry(for: entry.source, revision: entry.revision))
    }

    func testLegacyMatchedSecondaryWithChangedDigestFailsClosed() async throws {
        let primary = source("legacy-digest")
        let secondary = source("legacy-digest", resource: .livePairedVideo)
        let primaryDescriptor = descriptor(source: primary, filename: "legacy-digest.heic", fileExists: false)
        let changedSecondary = UploadResourceDescriptor(
            source: secondary,
            fileURL: tempDirectory.appendingPathComponent("missing-legacy-digest.mov"),
            filename: "legacy-digest.mov",
            fileSize: 4_096,
            modificationDate: modified,
            precomputedSHA1Digest: Data(repeating: 0xB5, count: 20)
        )
        let resolved = resolvedResource(
            queueSource: primary,
            revision: revision(),
            descriptor: primaryDescriptor,
            secondaries: [BackupSecondaryResource(descriptor: changedSecondary, mediaType: "video/quicktime")]
        )
        let legacy = reconciliation(
            descriptor: nil,
            source: secondary,
            identity: identity(filename: changedSecondary.filename)
        )
        let entry = seedEntry(source: primary, reconciliation: legacy)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))

        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.value(resolved)),
                identityResolver: RecoveryIdentityRecorder()
            ).settleAll()
            XCTFail("legacy recovery must require the exact digest")
        } catch let error as UploadRemoteCommitRecoveryError {
            XCTAssertEqual(error, .descriptorMismatch(entry.source, entry.revision))
        }
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testUnavailableManifestResolverPreservesReceiptAndSurfacesExistingBackendError() async throws {
        let queueSource = source("manifest-unavailable")
        let descriptor = descriptor(
            source: queueSource,
            filename: "manifest-unavailable.heic",
            fileExists: false
        )
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))

        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                identityResolver: DedupeUnavailableIdentityResolver(message: "manifest unavailable")
            ).settleAll()
            XCTFail("unavailable manifest settlement must fail closed")
        } catch let error as UploadError {
            guard case .backend(let message) = error else {
                return XCTFail("unexpected upload error: \(error)")
            }
            XCTAssertEqual(message, "manifest unavailable")
        }
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testLegacyReceiptUsesOnlyMatchingCurrentDescriptorAndJoinsCleanup() async throws {
        let source = source("legacy")
        let descriptor = descriptor(source: source, filename: "legacy.heic", fileExists: false)
        let cleanup = RecoveryTestLatch()
        let resolved = resolvedResource(
            queueSource: source,
            revision: revision(),
            descriptor: descriptor,
            cleanup: { cleanup.signal() }
        )
        let legacy = reconciliation(descriptor: nil, source: source)
        let entry = seedEntry(source: source, reconciliation: legacy)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))
        let recorder = RecoveryIdentityRecorder()

        let settledCount = try await UploadRemoteCommitRecovery(
            queue: store,
            resolver: RecoveryResourceResolver(.value(resolved)),
            identityResolver: recorder
        ).settleAll()
        XCTAssertEqual(settledCount, 1)

        XCTAssertTrue(cleanup.isSignaled)
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [source])
        XCTAssertNil(store.entry(for: entry.source, revision: entry.revision))
    }

    func testLegacyMissingOrChangedDescriptorFailsClosedAndPreservesReceipt() async throws {
        for changed in [false, true] {
            let directory = tempDirectory.appendingPathComponent(changed ? "changed" : "missing", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = source(changed ? "changed" : "missing")
            let legacy = reconciliation(descriptor: nil, source: source)
            let entry = seedEntry(source: source, reconciliation: legacy)
            let url = directory.appendingPathComponent("queue.sqlite")
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.upsert(entry))
            let value =
                changed
                ? resolvedResource(
                    queueSource: source,
                    revision: UploadBackupRevision(rawValue: revision().rawValue + 1),
                    descriptor: descriptor(source: source, filename: "changed.heic", fileExists: false)
                )
                : nil

            do {
                _ = try await UploadRemoteCommitRecovery(
                    queue: store,
                    resolver: RecoveryResourceResolver(.value(value)),
                    identityResolver: RecoveryIdentityRecorder()
                ).settleAll()
                XCTFail("legacy receipt without matching evidence must fail")
            } catch {
                XCTAssertTrue(error is UploadRemoteCommitRecoveryError)
            }
            XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        }
    }

    func testManifestFailureAndCancellationPreserveDurableReceipt() async throws {
        let source = source("preserved")
        let descriptor = descriptor(source: source, filename: "preserved.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        let url = queueURL()
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(store.upsert(entry))

        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                identityResolver: RecoveryIdentityRecorder(failures: 1)
            ).settleAll()
            XCTFail("injected manifest failure must surface")
        } catch {}
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)

        let blocker = BlockingRecoveryIdentityRecorder()
        let recovery = Task {
            try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                identityResolver: blocker
            ).settleAll()
        }
        await blocker.entered.wait()
        recovery.cancel()
        await blocker.cancellationObserved.wait()
        blocker.release.signal()
        do {
            _ = try await recovery.value
            XCTFail("cancelled settlement must fail")
        } catch is CancellationError {}

        XCTAssertEqual(blocker.writeCount, 1)
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        store.close()
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertNotNil(reopened.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testUnreadablePendingStatePreservesReceiptBeforeIdentitySettlement() async throws {
        let source = source("pending-failure")
        let descriptor = descriptor(source: source, filename: "pending-failure.heic", fileExists: false)
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        defer { queue.close() }
        XCTAssertTrue(queue.upsert(entry))
        let pendingURL = tempDirectory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let pending = try XCTUnwrap(PendingBackupManifestStore(url: pendingURL))
        let key = PendingSourceKey(source)
        let states = try XCTUnwrap(
            pending.exclude(
                [PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: modified))
        try executeSQL("UPDATE source_state SET desired='invalid';", at: pendingURL)
        let recorder = PendingBackupEventRecorder(store: pending)
        recorder.replacementLedger.record(
            key, revision: entry.revision, replaces: [PhotoUID(volumeID: "remote-volume", nodeID: "earlier")])
        let identities = RecoveryIdentityRecorder()
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: queue, resolver: resolver, identityResolver: identities, events: recorder
            ).settleAll()
            XCTFail("an unreadable exclusion must retain the remote commit receipt")
        } catch {
            XCTAssertEqual(error as? UploadRemoteCommitRecoveryError, .storeUnavailable)
        }
        XCTAssertTrue(identities.records.isEmpty)
        XCTAssertTrue(recorder.replacementLedger.replacementHandoffs().isEmpty)
        XCTAssertFalse(pending.isOperational())
        XCTAssertTrue(pending.unacknowledgedHandoffs().isEmpty, "the handoff insert must roll back")
        XCTAssertEqual(
            queue.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation,
            entry.remoteCommitReconciliation)
        recorder.finish()
        var events: [PendingRuntimeEvent] = []
        for await event in recorder.events { events.append(event) }
        XCTAssertTrue(events.isEmpty, "a failed handoff must not publish success")
        pending.close()
        queue.close()

        try executeSQL("UPDATE source_state SET desired='excluded';", at: pendingURL)
        let reopenedPending = try XCTUnwrap(PendingBackupManifestStore(url: pendingURL))
        defer { reopenedPending.close() }
        XCTAssertEqual(reopenedPending.sourceStates(), states)
        let reopenedQueue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        defer { reopenedQueue.close() }
        XCTAssertNotNil(reopenedQueue.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        let retryRecorder = PendingBackupEventRecorder(store: reopenedPending)
        defer { retryRecorder.finish() }
        let settled = try await UploadRemoteCommitRecovery(
            queue: reopenedQueue, resolver: resolver, identityResolver: identities, events: retryRecorder
        ).settleAll()
        XCTAssertEqual(settled, 1)
        XCTAssertNil(reopenedQueue.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(identities.records.count, 1)
        XCTAssertTrue(reopenedPending.sourceState(for: key)?.needsRemoteTrash ?? false)
        XCTAssertEqual(reopenedPending.sourceState(for: key)?.remote?.nodeID, "remote-primary")
        XCTAssertEqual(resolver.callCount, 0)
    }

    func testMalformedJSONAndSQLReadFailureAreNotDecodedAsNoReceipt() throws {
        let source = source("malformed")
        let descriptor = descriptor(source: source, filename: "malformed.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        let malformedURL = tempDirectory.appendingPathComponent("malformed.sqlite")
        try persist(entry, at: malformedURL)
        try executeSQL(
            "UPDATE backup_sync_queue SET remote_commit_reconciliation=x'00ff' WHERE source_id='malformed';",
            at: malformedURL
        )
        let malformedStore = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: malformedURL))
        XCTAssertThrowsError(try malformedStore.entriesWithRemoteCommitReconciliation(limit: 32)) { error in
            XCTAssertEqual(
                error as? UploadRemoteCommitRecoveryError,
                .malformedReceipt(source, entry.revision)
            )
        }
        XCTAssertFalse(malformedStore.isOperational(), "a malformed receipt marks the reading store failed")
        malformedStore.close()
        let ordinaryReader = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: malformedURL))
        XCTAssertTrue(ordinaryReader.nextRunnable(limit: 1).isEmpty)
        XCTAssertFalse(ordinaryReader.isOperational(), "malformed receipt must not become ordinary runnable work")
        ordinaryReader.close()
        XCTAssertEqual(try receiptCount(in: "backup_sync_queue", at: malformedURL), 1)

        let readFailureURL = tempDirectory.appendingPathComponent("read-failure.sqlite")
        try persist(entry, at: readFailureURL)
        let readFailureStore = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: readFailureURL))
        try executeSQL("ALTER TABLE backup_sync_queue RENAME TO preserved_queue;", at: readFailureURL)
        XCTAssertThrowsError(try readFailureStore.entriesWithRemoteCommitReconciliation(limit: 32)) { error in
            XCTAssertEqual(error as? UploadRemoteCommitRecoveryError, .storeUnavailable)
        }
        readFailureStore.close()
        XCTAssertEqual(try receiptCount(in: "preserved_queue", at: readFailureURL), 1)
    }

    func testAlbumExecutorRecoversBeforeResetKeepsCurrentRunCountsAndNeverCallsUploader() async throws {
        let source = source("executor")
        let descriptor = descriptor(source: source, filename: "executor.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = RecoveryIdentityRecorder()
        let uploader = MockUploader()
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve old receipt")))
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: uploader,
            resourceResolver: resolver,
            runtimeSignals: .wiFiWithMobileDataOff
        )

        let report = try await executor.ensureBackedUp(
            localIdentifiers: ["D4-nonexistent-\(UUID().uuidString)"],
            onProgress: { _ in }
        )

        XCTAssertEqual(report, AlbumSyncBackupReport())
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertTrue(uploader.requests.isEmpty, "settlement-only replay must have no uploader path")
        let currentRunQueue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertEqual(currentRunQueue.count(), 0)
    }

    func testEmptyAlbumInvocationSettlesPreviouslySelectedReceiptBeforeReturning() async throws {
        let queueSource = source("previously-selected")
        let descriptor = descriptor(
            source: queueSource,
            filename: "previously-selected.heic",
            fileExists: false
        )
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = RecoveryIdentityRecorder()
        let uploader = MockUploader()
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not scan or resolve")))
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: uploader,
            resourceResolver: resolver,
            runtimeSignals: .wiFiWithMobileDataOff
        )

        let report = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })

        XCTAssertEqual(report, AlbumSyncBackupReport())
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [queueSource])
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        let resetQueue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertEqual(resetQueue.count(), 0)
    }

    // MARK: - Network signals

    /// A regression must fail within the timeout instead of hanging the package job. The run has a runnable row, so the
    /// runner reads its network limit.
    func testAlbumExecutorFinishesOnWiFiWithMobileDataOff() async throws {
        let uploader = MockUploader()
        let recorder = RecoveryIdentityRecorder()
        let executor = try networkExecutor(signals: .wiFiWithMobileDataOff, recorder: recorder, uploader: uploader)
        let finished = expectation(description: "the album backup returns on Wi-Fi")
        let result = RecoveryResultBox()
        let run = Task {
            result.set(await Self.ensureBackedUp(executor, onProgress: { _ in }))
            finished.fulfill()
        }
        defer { run.cancel() }

        await fulfillment(of: [finished], timeout: 30)

        XCTAssertEqual(try result.value?.get(), AlbumSyncBackupReport())
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testAlbumExecutorWaitsForWiFiBeforeTheFirstNetworkPathAndFinishesOnWiFi() async throws {
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: .undetermined))
        let uploader = MockUploader()
        let recorder = RecoveryIdentityRecorder()
        // The poll of the paused runner never fires, so only the runtime change can end the wait.
        let poll = HeldBackupSleepClock(clock: BackupTestClock())
        defer { poll.releaseAll() }
        let executor = try networkExecutor(
            signals: .mobileDataOff(runtime), recorder: recorder, uploader: uploader, clock: poll)
        let waiting = expectation(description: "the album backup reports the Wi-Fi wait")
        waiting.assertForOverFulfill = false
        let finished = expectation(description: "the album backup returns after the Wi-Fi path")
        let result = RecoveryResultBox()
        let run = Task {
            let outcome = await Self.ensureBackedUp(executor) { progress in
                if progress.isPausedByPolicy, progress.isWaitingForWiFi { waiting.fulfill() }
            }
            result.set(outcome)
            finished.fulfill()
        }
        defer { run.cancel() }

        await fulfillment(of: [waiting], timeout: 30)
        XCTAssertNil(result.value, "an unknown network with mobile data off holds the album backup")
        XCTAssertTrue(uploader.requests.isEmpty)

        runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

        // The runtime change wakes the paused runner; its 30-second poll is held above.
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(try result.value?.get(), AlbumSyncBackupReport())
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    /// The album run of `testAlbumExecutorRecoversBeforeResetKeepsCurrentRunCountsAndNeverCallsUploader`: a saved
    /// receipt and a photo that is not in the library.
    private func networkExecutor(
        signals: BackupRuntimeSignalSource, recorder: RecoveryIdentityRecorder, uploader: MockUploader,
        clock: any BackupSchedulerClock = BackupContinuousClock()
    ) throws -> PhotoAlbumBackupExecutor {
        let source = source("network")
        let descriptor = descriptor(source: source, filename: "network.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        return PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            runtimeSignals: signals,
            clock: clock
        )
    }

    private static func ensureBackedUp(
        _ executor: PhotoAlbumBackupExecutor,
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async -> Result<AlbumSyncBackupReport, any Error> {
        do {
            return .success(
                try await executor.ensureBackedUp(
                    localIdentifiers: ["D4-nonexistent-\(UUID().uuidString)"], onProgress: onProgress))
        } catch {
            return .failure(error)
        }
    }

    func testAlbumExecutorMalformedReceiptFailsBeforeScratchReset() async throws {
        let source = source("executor-malformed")
        let descriptor = descriptor(source: source, filename: "executor-malformed.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        let url = albumQueueURL()
        try persist(entry, at: url)
        try executeSQL(
            "UPDATE backup_sync_queue SET remote_commit_reconciliation=x'00ff' "
                + "WHERE source_id='executor-malformed';",
            at: url
        )
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: RecoveryIdentityRecorder(),
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            runtimeSignals: .wiFiWithMobileDataOff
        )

        do {
            _ = try await executor.ensureBackedUp(
                localIdentifiers: ["D4-never-scanned"],
                onProgress: { _ in }
            )
            XCTFail("malformed durable receipt must abort the album run")
        } catch let error as UploadRemoteCommitRecoveryError {
            XCTAssertEqual(error, .malformedReceipt(source, entry.revision))
        }

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try receiptCount(in: "backup_sync_queue", at: url), 1)
    }

    func testAlbumExecutorScratchProofPathAttachesSharedServerPhotoWithoutChangingRows() async throws {
        let deviceA = try EditScenarioHarness()
        defer { try? deviceA.cleanup() }
        try await deviceA.enqueue()
        await deviceA.drain()
        let original = try deviceA.liveMain()
        let deviceB = try EditScenarioHarness(server: deviceA.server, library: deviceA.library)
        defer { try? deviceB.cleanup() }
        let settled = try await deviceB.enqueue()
        XCTAssertEqual(deviceB.state(of: settled), .alreadyBackedUp)
        let candidate = try deviceB.library.candidate()
        let queueURL = deviceB.directory.appendingPathComponent(PhotoAlbumBackupExecutor.queueDatabaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        XCTAssertTrue(queue.upsert(settled))
        queue.close()
        let resolutions = deviceB.library.resolutions.count
        let uploads = deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: deviceB.directory, databasePolicy: .conservative,
            identityResolver: deviceB.identityResolver, uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            proofCatalog: RecoveryProofCatalog(assets: [candidate]), runtimeSignals: .wiFiWithMobileDataOff)
        let mapping = try XCTUnwrap(
            AlbumSyncMappingStore(url: deviceB.directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName))
        )
        defer { mapping.close() }
        let runner = AlbumSyncRunner(
            localSource: RecoveryProofAlbumSource(identifiers: [candidate.snapshot.source.identifier]),
            backup: RecoveryProofOnlyAlbumBackup(executor: executor), remoteOps: deviceB.server,
            linkLookup: RecoveryMissingAlbumLinks(), mappingStore: mapping)
        let report = try await runner.sync(
            album: .init(id: "local-album", title: "Scenario album", assetCount: 1),
            resolution: .attachToExisting(remoteAlbumID: "own-album"))
        XCTAssertEqual(report.attached, 1)
        XCTAssertEqual(report.unattachable, 0)
        let members = try await deviceB.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members, [original.nodeID])
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { reopened.close() }
        XCTAssertEqual(reopened.entry(for: settled.source, revision: settled.revision), settled)
        XCTAssertNil(deviceB.identities.record(for: candidate.snapshot.source))
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions)
        XCTAssertEqual(deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testAlbumExecutorStopDuringEmptyCatalogKeepsRunnerStoppedError() async throws {
        try await assertRunnerStoppedDuringProofEnumeration(count: 0)
    }

    func testAlbumExecutorStoppedEmptyProofLookupReturnsNoLinks() async throws {
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        queue.close()
        let catalog = RecoveryPartialProofCatalog(assets: [])
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory, databasePolicy: .conservative,
            identityResolver: RecoveryIdentityRecorder(), uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            proofCatalog: catalog, runtimeSignals: .wiFiWithMobileDataOff)
        let lookup = Task { try await executor.remoteProofLinks(for: ["missing-proof"]) }
        await catalog.nextEntered.wait()
        await executor.stop()
        let links = try await lookup.value
        XCTAssertTrue(links.isEmpty, "Empty enumeration must retain its normal return for the runner's Stop fence")
    }

    func testAlbumExecutorStopDuringNonemptyCatalogKeepsRunnerStoppedError() async throws {
        for count in [1, 127] { try await assertRunnerStoppedDuringProofEnumeration(count: count) }
    }

    private func assertRunnerStoppedDuringProofEnumeration(count: Int) async throws {
        let assets = (0..<count).map { index in
            UploadBackupAssetCandidate(
                snapshot: .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "missing-proof-\(index)"),
                    revision: .init(rawValue: 100), resourceCount: 1,
                    externalIdentity: .init(identifier: "cloud-\(index)", revision: .init(rawValue: 100))),
                originalFilename: "Photo.HEIC")
        }
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertTrue(
            queue.upsertBatch(
                assets.map {
                    .init(
                        source: $0.snapshot.source, revision: $0.snapshot.revision,
                        originalFilename: $0.originalFilename, state: .alreadyBackedUp,
                        updatedAt: Date(timeIntervalSince1970: 100))
                }))
        queue.close()
        let catalog = RecoveryPartialProofCatalog(assets: assets)
        let recorder = BlockingRecoveryIdentityRecorder()
        recorder.release.signal()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory, databasePolicy: .conservative,
            identityResolver: recorder, uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            proofCatalog: catalog, runtimeSignals: .wiFiWithMobileDataOff)
        let mapping = try XCTUnwrap(
            AlbumSyncMappingStore(url: tempDirectory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        defer { mapping.close() }
        let runner = AlbumSyncRunner(
            localSource: RecoveryProofAlbumSource(
                identifiers: count == 0 ? ["missing-proof"] : assets.map { $0.snapshot.source.identifier }),
            backup: RecoveryProofOnlyAlbumBackup(executor: executor),
            remoteOps: EditScenarioServer(), linkLookup: RecoveryMissingAlbumLinks(), mappingStore: mapping)
        let pass = Task {
            try await runner.sync(
                album: .init(id: "local-album", title: "Scenario album", assetCount: 1),
                resolution: .attachToExisting(remoteAlbumID: "own-album"))
        }
        await catalog.nextEntered.wait()
        await runner.stop()
        XCTAssertTrue(catalog.cancellationObserved.isSignaled)
        // Empty enumeration cannot issue a proof request; exercise the request assertion only for real candidates.
        if count > 0 { XCTAssertEqual(recorder.proofRequestSizes, []) }
        XCTAssertEqual(mapping.mapping(localAlbumID: "local-album")?.remoteAlbumID, "own-album")
        do {
            _ = try await pass.value
            XCTFail("Stop must keep the runner's stopped result for \(count) candidates")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .stopped)
        } catch {
            XCTFail("Stop with \(count) candidates must preserve .stopped, not \(error)")
        }
    }

    func testAlbumExecutorStopDuringCatalogNextPreventsPartialProofBatch() async throws {
        for count in [1, 127] {
            let assets = (0..<count).map { index in
                UploadBackupAssetCandidate(
                    snapshot: .init(
                        source: .init(kind: .photoLibraryAsset, identifier: "partial-\(count)-\(index)"),
                        revision: .init(rawValue: 100), resourceCount: 1,
                        externalIdentity: .init(identifier: "cloud-\(count)-\(index)", revision: .init(rawValue: 100))),
                    originalFilename: "Photo.HEIC")
            }
            let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
            XCTAssertTrue(
                queue.upsertBatch(
                    assets.map {
                        .init(
                            source: $0.snapshot.source, revision: $0.snapshot.revision,
                            originalFilename: $0.originalFilename, state: .alreadyBackedUp,
                            updatedAt: Date(timeIntervalSince1970: 100))
                    }))
            queue.close()
            let catalog = RecoveryPartialProofCatalog(assets: assets)
            let recorder = BlockingRecoveryIdentityRecorder()
            recorder.release.signal()
            let executor = PhotoAlbumBackupExecutor(
                accountDataDirectory: tempDirectory, databasePolicy: .conservative,
                identityResolver: recorder, uploader: MockUploader(),
                resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                proofCatalog: catalog, runtimeSignals: .wiFiWithMobileDataOff)
            let lookup = Task { try await executor.remoteProofLinks(for: assets.map { $0.snapshot.source.identifier }) }
            await catalog.nextEntered.wait()
            await executor.stop()
            XCTAssertTrue(catalog.cancellationObserved.isSignaled)
            XCTAssertEqual(
                recorder.proofRequestSizes, [],
                "Stop during catalog.next must reject the \(count)-candidate partial batch")
            do {
                _ = try await lookup.value
                XCTFail("Stop must surface cancellation without an attachable proof")
            } catch is CancellationError {}
        }
    }

    func testAlbumExecutorStopCancelsAndJoinsProofLookupBeforeAnotherBatch() async throws {
        let assets = (0..<257).map { index in
            UploadBackupAssetCandidate(
                snapshot: .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "proof-\(index)"),
                    revision: .init(rawValue: 100), resourceCount: 1,
                    externalIdentity: .init(identifier: "cloud-\(index)", revision: .init(rawValue: 100))),
                originalFilename: "Photo.HEIC")
        }
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertTrue(
            queue.upsertBatch(
                assets.map {
                    .init(
                        source: $0.snapshot.source, revision: $0.snapshot.revision,
                        originalFilename: $0.originalFilename, state: .alreadyBackedUp,
                        updatedAt: Date(timeIntervalSince1970: 100))
                }))
        queue.close()
        let blocker = BlockingRecoveryIdentityRecorder()
        let cancellation = expectation(description: "Stop cancels the proof request")
        blocker.onProofCancellation = { cancellation.fulfill() }
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory, databasePolicy: .conservative,
            identityResolver: blocker, uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            proofCatalog: RecoveryProofCatalog(assets: assets), runtimeSignals: .wiFiWithMobileDataOff)
        let lookup = Task { try await executor.remoteProofLinks(for: assets.map { $0.snapshot.source.identifier }) }
        await blocker.entered.wait()
        do {
            _ = try await executor.remoteProofLinks(for: [assets[0].snapshot.source.identifier])
            XCTFail("The in-flight proof request must reject another operation")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }
        let cancelledAdmission = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await executor.remoteProofLinks(for: [])
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        let cancelledBeforeAdmission = await cancelledAdmission.value
        XCTAssertTrue(cancelledBeforeAdmission, "Caller cancellation must take precedence over operation admission")
        let stopReturned = RecoveryTestLatch()
        let stop = Task {
            await executor.stop()
            stopReturned.signal()
        }
        await fulfillment(of: [cancellation], timeout: 5)
        XCTAssertFalse(
            stopReturned.isSignaled, "Stop must join a proof request that ignores cancellation until release")
        blocker.release.signal()
        await stop.value
        XCTAssertTrue(blocker.cancellationObserved.isSignaled)
        XCTAssertTrue(blocker.completed.isSignaled)
        XCTAssertEqual(blocker.proofRequestSizes, [128], "Stop must prevent every later proof batch")
        do {
            _ = try await lookup.value
            XCTFail("Stop must surface cancellation without an attachable proof")
        } catch is CancellationError {}
    }

    func testAlbumExecutorStopCancelsAndJoinsRecoveryBeforeClosingStores() async throws {
        let source = source("stop")
        let descriptor = descriptor(source: source, filename: "stop.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let blocker = BlockingRecoveryIdentityRecorder()
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: blocker,
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            runtimeSignals: .wiFiWithMobileDataOff
        )
        let ensure = Task {
            try await executor.ensureBackedUp(
                localIdentifiers: ["D4-never-scanned"],
                onProgress: { _ in }
            )
        }
        await blocker.entered.wait()
        let stopReturned = RecoveryTestLatch()
        let stop = Task {
            await executor.stop()
            stopReturned.signal()
        }
        await blocker.cancellationObserved.wait()
        XCTAssertFalse(stopReturned.isSignaled, "stop must join cancellation-ignoring recovery")
        blocker.release.signal()
        await stop.value

        XCTAssertTrue(blocker.completed.isSignaled)
        XCTAssertTrue(stopReturned.isSignaled)
        XCTAssertEqual(blocker.writeCount, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
        do {
            _ = try await ensure.value
            XCTFail("stopped executor must surface cancellation")
        } catch is CancellationError {}

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertNotNil(reopened.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testStopFenceRejectsAdmissionAfterOperationJoinsUntilStopReturns() async throws {
        let queueSource = source("stop-fence")
        let descriptor = descriptor(source: queueSource, filename: "stop-fence.heic", fileExists: false)
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = BlockingRecoveryIdentityRecorder()
        let fenceRelease = RecoveryControlledBarrier()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            stopFenceBarrier: { await fenceRelease.wait() },
            runtimeSignals: .wiFiWithMobileDataOff
        )
        let ensure = Task {
            try await executor.ensureBackedUp(localIdentifiers: ["not-scanned"], onProgress: { _ in })
        }
        await recorder.entered.wait()
        let stop = Task { await executor.stop() }
        await recorder.cancellationObserved.wait()
        recorder.release.signal()
        await fenceRelease.firstEntered.wait()

        do {
            _ = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
            XCTFail("stop fence must reject admission after the captured operation has joined")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        do {
            _ = try await executor.remoteProofLinks(for: [])
            XCTFail("The proof lookup must retain the Stop admission fence")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        fenceRelease.releaseOne()
        await stop.value
        do {
            _ = try await ensure.value
            XCTFail("stopped operation must surface cancellation")
        } catch is CancellationError {}

        let report = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
        XCTAssertEqual(report, AlbumSyncBackupReport())
    }

    func testOverlappingStopsRetainIndependentAdmissionFences() async throws {
        let queueSource = source("overlapping-stops")
        let descriptor = descriptor(
            source: queueSource,
            filename: "overlapping-stops.heic",
            fileExists: false
        )
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = BlockingRecoveryIdentityRecorder()
        let acquired = RecoveryControlledBarrier()
        let releasing = RecoveryControlledBarrier()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            stopFenceAcquired: { await acquired.wait() },
            stopFenceBarrier: { await releasing.wait() },
            runtimeSignals: .wiFiWithMobileDataOff
        )
        let ensure = Task {
            try await executor.ensureBackedUp(localIdentifiers: ["not-scanned"], onProgress: { _ in })
        }
        await recorder.entered.wait()

        let firstStop = Task { await executor.stop() }
        await acquired.firstEntered.wait()
        let secondStop = Task { await executor.stop() }
        await acquired.secondEntered.wait()

        acquired.releaseOne()
        await recorder.cancellationObserved.wait()
        recorder.release.signal()
        await releasing.firstEntered.wait()
        acquired.releaseOne()
        await releasing.secondEntered.wait()

        do {
            _ = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
            XCTFail("two stop owners must fence admission")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        releasing.releaseOne()
        await firstStop.value
        do {
            _ = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
            XCTFail("the remaining stop owner must retain its fence")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        releasing.releaseOne()
        await secondStop.value
        do {
            _ = try await ensure.value
            XCTFail("stopped operation must surface cancellation")
        } catch is CancellationError {}

        let report = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
        XCTAssertEqual(report, AlbumSyncBackupReport())
    }

    func testPreCancelledAlbumExecutorDoesNotOpenStoresOrStartUploadWork() async throws {
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: RecoveryIdentityRecorder(),
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            runtimeSignals: .wiFiWithMobileDataOff
        )

        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.ensureBackedUp(
                localIdentifiers: ["D4-pre-cancelled"],
                onProgress: { _ in }
            )
        }
        do {
            _ = try await attempt.value
            XCTFail("pre-cancelled album run must fail before admission")
        } catch is CancellationError {}

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: albumQueueURL().path))
    }

    private func source(
        _ identifier: String,
        resource: UploadSourceIdentity.Resource = .primary
    ) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier, resource: resource)
    }

    private func revision() -> UploadBackupRevision {
        UploadBackupRevision(date: modified)
    }

    private func descriptor(
        source: UploadSourceIdentity,
        filename: String,
        fileExists: Bool,
        fileSize: Int64 = 4_096
    ) -> UploadResourceDescriptor {
        let url = tempDirectory.appendingPathComponent(fileExists ? filename : "missing-\(filename)")
        return UploadResourceDescriptor(
            source: source,
            fileURL: url,
            filename: filename,
            fileSize: fileSize,
            modificationDate: modified,
            precomputedSHA1Digest: digest
        )
    }

    private func identity(
        filename: String,
        nameHash: String? = nil,
        contentHash: String? = nil
    ) -> UploadIdentity {
        UploadIdentity(
            correctedName: ProtonPhotoNameCorrection.correctedName(for: filename),
            nameHash: nameHash ?? "name-hash-\(filename)",
            sha1Hex: UploadContentSHA1.hexString(digest: digest),
            sha1Digest: digest,
            contentHash: contentHash ?? "content-hash-\(filename)"
        )
    }

    private func reconciliation(
        descriptor: UploadResourceDescriptor?,
        source explicitSource: UploadSourceIdentity? = nil,
        queueSource explicitQueueSource: UploadSourceIdentity? = nil,
        queueRevision: UploadBackupRevision? = nil,
        identity explicitIdentity: UploadIdentity? = nil,
        linkID: String = "remote-primary"
    ) -> UploadRemoteCommitReconciliation {
        let source = explicitSource ?? descriptor!.source
        let filename = descriptor?.filename ?? "\(source.identifier).heic"
        let queueSource =
            explicitQueueSource
            ?? UploadSourceIdentity(kind: source.kind, identifier: source.identifier, resource: .primary)
        return UploadRemoteCommitReconciliation(
            source: source,
            identity: explicitIdentity ?? identity(filename: filename),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "remote-volume", remoteLinkID: linkID),
            descriptor: descriptor.map(UploadResourceDescriptorSnapshot.init),
            queueBinding: descriptor.map { _ in
                UploadRemoteCommitQueueBinding(
                    source: queueSource,
                    revision: queueRevision ?? revision()
                )
            }
        )
    }

    private func seedEntry(
        source explicitSource: UploadSourceIdentity? = nil,
        reconciliation: UploadRemoteCommitReconciliation,
        state: UploadBackupSyncQueueState = .needsRemoteReconciliation,
        byteCount: Int64? = 4_096
    ) -> UploadBackupSyncQueueEntry {
        let source = explicitSource ?? reconciliation.source
        return UploadBackupSyncQueueEntry(
            source: source,
            revision: revision(),
            originalFilename: "\(source.identifier).heic",
            byteCount: byteCount,
            state: state,
            remoteCommitReconciliation: reconciliation,
            updatedAt: modified
        )
    }

    private func resolvedResource(
        queueSource: UploadSourceIdentity,
        revision: UploadBackupRevision,
        descriptor: UploadResourceDescriptor,
        secondaries: [BackupSecondaryResource] = [],
        cleanup: (@Sendable () -> Void)? = nil
    ) -> BackupResolvedResource {
        BackupResolvedResource(
            candidate: UploadBackupAssetCandidate(
                snapshot: UploadBackupAssetSnapshot(
                    source: queueSource,
                    revision: revision,
                    editRevision: .unavailable,
                    resourceCount: 1 + secondaries.count
                ),
                originalFilename: descriptor.filename,
                byteCount: descriptor.fileSize
            ),
            descriptor: descriptor,
            mediaType: "image/heic",
            captureDate: modified,
            secondaries: secondaries,
            cleanup: cleanup
        )
    }

    private func queueURL() -> URL {
        tempDirectory.appendingPathComponent("queue.sqlite")
    }

    private func albumQueueURL() -> URL {
        tempDirectory.appendingPathComponent(PhotoAlbumBackupExecutor.queueDatabaseFileName)
    }

    private func persist(_ entry: UploadBackupSyncQueueEntry, at url: URL) throws {
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(store.upsert(entry))
        store.close()
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private func receiptCount(in table: String, at url: URL) throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT COUNT(*) FROM \(table) WHERE remote_commit_reconciliation IS NOT NULL;",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
}

private struct RecoveryProofCatalog: UploadBackupAssetCatalog {
    let assets: [UploadBackupAssetCandidate]
    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        AsyncThrowingStream { continuation in
            for asset in assets { continuation.yield(asset) }
            continuation.finish()
        }
    }
}

private final class RecoveryPartialProofCatalog: UploadBackupAssetCatalog, @unchecked Sendable {
    let nextEntered = RecoveryTestLatch()
    let cancellationObserved = RecoveryTestLatch()
    private let lock = NSLock()
    private let assets: [UploadBackupAssetCandidate]
    private var nextIndex = 0

    init(assets: [UploadBackupAssetCandidate]) { self.assets = assets }

    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        AsyncThrowingStream(unfolding: { [self] in
            let candidate = lock.withLock { () -> UploadBackupAssetCandidate? in
                guard nextIndex < assets.count else { return nil }
                defer { nextIndex += 1 }
                return assets[nextIndex]
            }
            if let candidate { return candidate }
            let pending = AsyncThrowingStream<UploadBackupAssetCandidate, any Error> { continuation in
                continuation.onTermination = { [self] _ in cancellationObserved.signal() }
            }
            var iterator = pending.makeAsyncIterator()
            nextEntered.signal()
            return try await iterator.next()
        })
    }
}

private struct RecoveryProofAlbumSource: AlbumSyncLocalAlbumSource {
    var identifiers: [String] = ["missing-proof"]
    func listAlbums() async throws -> [LocalAlbumSummary] { [] }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents { .present(identifiers) }
}

private struct RecoveryMissingAlbumLinks: AlbumSyncRemoteLinkLookup {
    func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink] { [:] }
}

private struct RecoveryProofOnlyAlbumBackup: AlbumSyncBackupExecuting {
    let executor: PhotoAlbumBackupExecutor
    func ensureBackedUp(
        localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        .init(total: 1, backedUp: 1, failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0)
    }
    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        try await executor.remoteProofLinks(for: localIdentifiers)
    }
    func stop() async { await executor.stop() }
}
