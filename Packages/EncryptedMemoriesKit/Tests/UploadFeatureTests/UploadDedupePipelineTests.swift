import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// In-memory `UploadIdentityStore`.
final class FakeIdentityStore: UploadIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UploadSourceIdentity: UploadIdentityRecord] = [:]
    private var failNextWrite = false
    var onUpsert: (@Sendable (UploadIdentityRecord) -> Void)?

    func rejectNextUpsert() {
        lock.withLock { failNextWrite = true }
    }

    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? {
        lock.withLock { rows[source] }
    }

    /// Oldest row first, so a test controls which row the pipeline sees first.
    func trustedRecords(contentHash: String, hashKeyEpoch: String, limit: Int) -> [UploadIdentityRecord] {
        lock.withLock {
            let trusted = rows.values.filter { row in
                row.contentHash == contentHash
                    && row.hashKeyEpoch == hashKeyEpoch
                    && row.remoteLinkID != nil
                    && (row.outcome == UploadIdentityManifestStore.Outcome.uploaded.rawValue
                        || row.outcome == UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
            }
            return Array(trusted.sorted { $0.updatedAt < $1.updatedAt }.prefix(limit))
        }
    }

    func sources(withRemoteLinkID linkID: String) -> [UploadSourceIdentity]? {
        lock.withLock {
            rows.values.filter { row in
                row.remoteLinkID == linkID
                    && (row.outcome == UploadIdentityManifestStore.Outcome.uploaded.rawValue
                        || row.outcome == UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
            }.map(\.source)
        }
    }

    private var failNextForget = false

    func rejectNextForget() {
        lock.withLock { failNextForget = true }
    }

    @discardableResult
    func forgetRemoteLinks(_ linkIDs: Set<String>, of owner: UploadSourceIdentity) -> Bool {
        lock.withLock {
            if failNextForget {
                failNextForget = false
                return false
            }
            for (source, row) in rows
            where source.kind == owner.kind && source.identifier == owner.identifier
                && row.remoteLinkID.map(linkIDs.contains) == true
            {
                var forgotten = row
                forgotten.remoteVolumeID = nil
                forgotten.remoteLinkID = nil
                forgotten.outcome = nil
                rows[source] = forgotten
            }
            return true
        }
    }

    @discardableResult
    func upsert(_ record: UploadIdentityRecord) -> Bool {
        onUpsert?(record)
        return lock.withLock {
            if failNextWrite {
                failNextWrite = false
                return false
            }
            rows[record.source] = record
            return true
        }
    }
}

/// Deterministic hasher: digest derived from the file path (or an explicit per-path content
/// seed, so tests can make different paths carry identical content); counts invocations to
/// prove cache hits never rehash.
final class FakeHasher: UploadHashing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var hashCount = 0
    var delay: Duration?
    /// path to content seed. Paths sharing a seed hash identically (simulated identical bytes).
    var contentSeeds: [String: String] = [:]

    func sha1(of descriptor: UploadResourceDescriptor) async throws -> Data {
        lock.withLock { hashCount += 1 }
        if let delay {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        let path = descriptor.fileURL.path
        let seed = lock.withLock { contentSeeds[path] } ?? path
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in seed.utf8.enumerated() {
            digest[i % 20] ^= byte
        }
        return digest
    }
}

/// Scripted duplicate checker: nameHash = "nh(<name>)", contentHash = "ch(<sha1>)"; canned remote
/// items keyed by name hash; records every findDuplicates batch.
final class FakeChecker: UploadDuplicateChecking, @unchecked Sendable {
    private let lock = NSLock()
    var epoch = "epoch-1"
    var epochError: (any Error)?
    var nameHashesError: (any Error)?
    var onEpochLookup: (@Sendable () -> Void)?
    var onContentLookup: (@Sendable () -> Void)?
    var remoteItemsByNameHash: [String: [RemotePhotoDuplicate]] = [:]
    var remoteItemsByContentHash: [String: RemotePhotoDuplicate] = [:]
    var exactActiveDuplicates: [PhotoUID] = []
    var onExactLookup: (@Sendable () -> Void)?
    var findError: Error?
    var contentFindError: Error?
    /// What the account-wide content index reports to the backup screen.
    var contentIndexHealth: UploadRemoteContentIndexHealth = .complete(indexedCount: 0)
    /// Makes the next index preparations fail, for example with a cancellation.
    var prepareRemoteIndexError: Error?
    private(set) var findBatches: [[String]] = []
    private(set) var nameHashCalls = 0
    private var invalidationCount = 0
    private var nameLookupAttempts = 0
    var nameLookupAttemptCount: Int { lock.withLock { nameLookupAttempts } }
    private var contentFindCount = 0
    private var exactFindCount = 0
    var onNameLookup: (@Sendable ([String]) -> Void)?
    var deletionMetadata = UploadLinkStateSnapshot(states: [:], complete: false)

    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot { deletionMetadata }

    func nameHash(forCorrectedName name: String) async throws -> String {
        lock.withLock { nameHashCalls += 1 }
        return "nh(\(name))"
    }

    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        "ch(\(sha1Hex))"
    }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock { nameLookupAttempts += 1 }
        if let findError { throw findError }
        onNameLookup?(nameHashes)
        return lock.withLock {
            findBatches.append(nameHashes)
            return nameHashes.flatMap { hash in remoteItemsByNameHash[hash] ?? [] }
        }
    }

    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        onContentLookup?()
        return lock.withLock {
            contentFindCount += 1
            return remoteItemsByContentHash[contentHash]
        }
    }

    /// Several indexed links per content hash, in this order. Without an entry, the single row above answers.
    var contentMatchesByContentHash: [String: [RemotePhotoDuplicate]] = [:]

    func findDuplicates(contentHash: String, limit: Int) async throws -> [RemotePhotoDuplicate] {
        if let contentFindError { throw contentFindError }
        return lock.withLock {
            contentFindCount += 1
            let single = remoteItemsByContentHash[contentHash].map { [$0] } ?? []
            return Array((contentMatchesByContentHash[contentHash] ?? single).prefix(limit))
        }
    }

    var relatedLinkIDsByMainLinkID: [String: Set<String>] = [:]
    /// Answers like the server from state outside the checker, for example the uploads a test made.
    var relatedLinkIDsProvider: (@Sendable (String) -> Set<String>)?
    /// Fails every related-files lookup, like a server that does not answer.
    var relatedLookupError: Error?
    /// Runs inside every related-files lookup, so a test can hold the caller there.
    var relatedLookupGate: (@Sendable () async -> Void)?

    /// The main photos whose related files a caller asked for, in order.
    private(set) var relatedLookups: [String] = []
    /// Compounds by main link. Other links have none.
    var compoundsByMainLinkID: [String: UploadRemoteCompound] = [:]
    var externalMainLinks: [String: (links: Set<String>, complete: Bool)] = [:]
    var replacedLinks: [String: (links: Set<String>, complete: Bool)] = [:]
    var replacingLinks: [String: (links: Set<String>, complete: Bool)] = [:]
    func activeMainLinkIDs(
        forExternalIdentifier identifier: String
    ) async throws -> (links: Set<String>, complete: Bool) {
        externalMainLinks[identifier] ?? ([], false)
    }
    func replacedLinkIDs(ofReplacingMain linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        replacedLinks[linkID] ?? ([], false)
    }
    func replacingMainLinkIDs(ofReplacedLink linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        replacingLinks[linkID] ?? ([], false)
    }
    /// Errors that the next compound reads of a main link throw, one per read.
    var compoundErrorsByMainLinkID: [String: [Error]] = [:]

    func compound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        try lock.withLock {
            if let error = compoundErrorsByMainLinkID[linkID]?.first {
                compoundErrorsByMainLinkID[linkID]?.removeFirst()
                throw error
            }
            return compoundsByMainLinkID[linkID]
        }
    }

    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        lock.withLock { relatedLookups.append(mainLinkID) }
        if let gate = lock.withLock({ relatedLookupGate }) { await gate() }
        if let error = lock.withLock({ relatedLookupError }) { throw error }
        let provided = lock.withLock { relatedLinkIDsProvider }?(mainLinkID) ?? []
        return lock.withLock { relatedLinkIDsByMainLinkID[mainLinkID] ?? [] }.union(provided)
    }

    /// Explicit answers. Other links derive from the rows above.
    var linkVisibilityByID: [String: RemoteLinkVisibility?] = [:]
    /// Answers activity from the same state that another fake of the test holds, so both agree like one server.
    var linkActivityProvider: (@Sendable (String) -> Bool)?
    var linkVisibilityError: Error?
    var onVisibilityLookup: (@Sendable () -> Void)?
    private var visibilityReadCount = 0

    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        lock.withLock { contentIndexHealth }
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        if let failure = lock.withLock({ prepareRemoteIndexError }) { throw failure }
        await progress(.init(phase: .ready))
    }

    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        onVisibilityLookup?()
        let failure = lock.withLock {
            visibilityReadCount += 1
            return linkVisibilityError
        }
        if let failure { throw failure }
        let provider = lock.withLock { relatedLinkIDsProvider }
        let activity = lock.withLock { linkActivityProvider }
        // The provider answers per main photo, so it can name the main only among the links asked about.
        let provided = Dictionary(uniqueKeysWithValues: Set(linkIDs).map { ($0, provider?($0) ?? []) })
        return lock.withLock {
            let rows =
                remoteItemsByNameHash.values.flatMap { $0 } + remoteItemsByContentHash.values
                + contentMatchesByContentHash.values.flatMap { $0 }
            var result: [String: RemoteLinkVisibility] = [:]
            for linkID in linkIDs {
                if let explicit = linkVisibilityByID[linkID] {
                    result[linkID] = explicit
                    continue
                }
                let main =
                    relatedLinkIDsByMainLinkID.first { $0.value.contains(linkID) }?.key
                    ?? provided.first { $0.value.contains(linkID) }?.key
                if let activity {
                    result[linkID] = RemoteLinkVisibility(isActive: activity(linkID), mainPhotoLinkID: main)
                    continue
                }
                // A link without a row is one that the server no longer knows.
                guard let row = rows.first(where: { $0.linkID == linkID }), let state = row.linkState else {
                    continue
                }
                result[linkID] = RemoteLinkVisibility(isActive: state == .active, mainPhotoLinkID: main)
            }
            return result
        }
    }

    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID] {
        onExactLookup?()
        return lock.withLock {
            exactFindCount += 1
            return exactActiveDuplicates
        }
    }

    func invalidateCachedRemoteState() async {
        lock.withLock { invalidationCount += 1 }
    }

    func recordUploaded(contentHash: String, remoteLinkID: String) async {
        lock.withLock {
            remoteItemsByContentHash[contentHash] = RemotePhotoDuplicate(
                nameHash: "",
                contentHash: contentHash,
                linkState: .active,
                linkID: remoteLinkID
            )
        }
    }

    func hashKeyEpoch() async throws -> String {
        onEpochLookup?()
        if let epochError { throw epochError }
        return epoch
    }

    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        if let nameHashesError { throw nameHashesError }
        var hashes: [String] = []
        for name in names { hashes.append(try await nameHash(forCorrectedName: name)) }
        return hashes
    }

    var findCallCount: Int { lock.withLock { findBatches.count } }
    var invalidateCallCount: Int { lock.withLock { invalidationCount } }
    var contentFindCallCount: Int { lock.withLock { contentFindCount } }
    var exactFindCallCount: Int { lock.withLock { exactFindCount } }
    var linkVisibilityCallCount: Int { lock.withLock { visibilityReadCount } }
}

final class UploadDedupePipelineTests: XCTestCase {
    private var store: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!

    override func setUp() {
        super.setUp()
        store = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
    }

    private func descriptor(
        path: String = "/photos/IMG_1.HEIC",
        filename: String? = nil,
        size: Int64 = 1000,
        mtime: TimeInterval = 1_700_000_000,
        digest: Data? = nil
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: path)),
            fileURL: URL(fileURLWithPath: path),
            filename: filename ?? (path as NSString).lastPathComponent,
            fileSize: size,
            modificationDate: Date(timeIntervalSince1970: mtime),
            precomputedSHA1Digest: digest
        )
    }

    /// The sha1 hex FakeHasher yields for a given content seed (or path when unseeded).
    private func fakeSHA1Hex(seed: String) -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in seed.utf8.enumerated() { digest[i % 20] ^= byte }
        return UploadContentSHA1.hexString(digest: digest)
    }

    func testSameContentUnderNewSourceAdoptsManifestAfterCheckingNameState() async throws {
        hasher.contentSeeds["/sync1/IMG_1.HEIC"] = "shared-bytes"
        hasher.contentSeeds["/sync2/renamed.HEIC"] = "shared-bytes"

        let original = descriptor(path: "/sync1/IMG_1.HEIC")
        let resolvedOriginal = try await pipeline.resolve(original)
        XCTAssertEqual(resolvedOriginal.decision, .upload)
        try await pipeline.recordUploaded(
            original, identity: resolvedOriginal.identity,
            remoteVolumeID: "vol", remoteLinkID: "link-a")
        let findsAfterOriginal = checker.findCallCount

        // Copied file: different path and different filename, identical bytes.
        let copy = descriptor(path: "/sync2/renamed.HEIC")
        let resolvedCopy = try await pipeline.resolve(copy)

        XCTAssertEqual(resolvedCopy.decision, .skip(.knownFromManifest, remoteLinkID: "link-a"))
        XCTAssertEqual(
            checker.findCallCount, findsAfterOriginal + 1,
            "explicit matching trash must be checked before cross-source cached adoption")
        let copyRow = store.record(for: copy.source)
        XCTAssertEqual(copyRow?.outcome, UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
        XCTAssertEqual(
            copyRow?.remoteLinkID, "link-a",
            "the copy source must adopt the original's remote link for future fast-path hits")
    }

    func testCachedActiveCopyCannotHideExplicitTrashForANewSourceWithOrWithoutPrime() async throws {
        for primed in [false, true] {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let digest = Data(repeating: 7, count: 20)
            let active = descriptor(path: "/other/active.HEIC", digest: digest)
            let first = try await localPipeline.resolve(active)
            try await localPipeline.recordUploaded(
                active, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "active")
            let copy = descriptor(digest: digest)
            localChecker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
                .init(
                    nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash, linkState: .trashed,
                    linkID: "trash")
            ]
            if primed { await localPipeline.prime([copy]) }
            let result = try await localPipeline.resolve(copy)
            XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "trash"))
            XCTAssertEqual(localStore.record(for: copy.source)?.remoteLinkID, "trash")
            XCTAssertFalse(try XCTUnwrap(localStore.record(for: copy.source)).provesUpload)
        }
    }

    func testFailedNameProbePreservesTrustedActiveAdoptionButCancellationPropagates() async throws {
        let errors: [any Error] = [
            UploadError.backend("unavailable"), URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: URLError.cancelled.rawValue, message: "cancelled"),
        ]
        for (index, error) in errors.enumerated() {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let digest = Data(repeating: 7, count: 20)
            let active = descriptor(path: "/other/active.HEIC", digest: digest)
            let first = try await localPipeline.resolve(active)
            try await localPipeline.recordUploaded(
                active, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "active")
            localChecker.findError = error
            let attempts = localChecker.nameLookupAttemptCount
            do {
                let result = try await localPipeline.resolve(descriptor(digest: digest))
                if index == 0 {
                    XCTAssertEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: "active"))
                } else {
                    XCTFail("cancellation cannot fall through to cached adoption")
                }
            } catch {
                XCTAssertNotEqual(index, 0, "ordinary evidence failure preserves the existing trusted proof")
                XCTAssertFalse(Task.isCancelled)
            }
            XCTAssertEqual(localChecker.nameLookupAttemptCount, attempts + 1)
        }
    }

    func testKnownTrashCannotAdoptCachedActiveProofWhenNameEvidenceFails() async throws {
        let digest = Data(repeating: 7, count: 20)
        let active = descriptor(path: "/other/active.HEIC", digest: digest)
        let first = try await pipeline.resolve(active)
        try await pipeline.recordUploaded(
            active, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "active")
        let copy = descriptor(digest: digest)
        var knownTrash = try XCTUnwrap(store.record(for: active.source))
        knownTrash.source = copy.source
        knownTrash.filename = copy.filename
        knownTrash.correctedName = copy.filename
        knownTrash.nameHash = "nh(IMG_1.HEIC)"
        knownTrash.remoteLinkID = "trash"
        knownTrash.outcome = "duplicateTrashed"
        XCTAssertTrue(store.upsert(knownTrash))
        checker.findError = UploadError.backend("unavailable")
        do {
            _ = try await pipeline.resolve(copy)
            XCTFail("failed evidence cannot clear an exact known deletion through another cached source")
        } catch {
            XCTAssertEqual(error as? UploadError, .backend("unavailable"))
        }
        XCTAssertEqual(store.record(for: copy.source)?.remoteLinkID, "trash")
        XCTAssertFalse(try XCTUnwrap(store.record(for: copy.source)).provesUpload)
    }

    private var transportCancellations: [any Error] {
        [
            CancellationError(), URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: URLError.cancelled.rawValue, message: "cancelled"),
        ]
    }

    func testKnownTrashNameCancellationDoesNotRunPositiveSDKFallbackAndReleasesClaims() async throws {
        for failure in transportCancellations {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let d = descriptor(digest: Data(repeating: 7, count: 20))
            let initial = try await localPipeline.resolve(d)
            await localPipeline.uploadDidFail(d)
            var trash = try XCTUnwrap(localStore.record(for: d.source))
            trash.remoteLinkID = "trash"
            trash.outcome = "duplicateTrashed"
            XCTAssertTrue(localStore.upsert(trash))
            localChecker.findError = failure
            localChecker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "active")]
            do {
                let result = try await localPipeline.resolve(d)
                XCTFail("cancelled known-trash lookup cannot settle through SDK fallback: \(result.decision)")
            } catch {
                XCTAssertTrue(UploadError.isCancellation(error))
                XCTAssertFalse(Task.isCancelled)
            }
            XCTAssertEqual(localChecker.exactFindCallCount, 0, "cancellation must precede the positive SDK fallback")
            XCTAssertEqual(localStore.record(for: d.source)?.remoteLinkID, "trash")
            XCTAssertFalse(try XCTUnwrap(localStore.record(for: d.source)).provesUpload)

            // No external uploadDidFail call may be needed to release either owned claim after the throw.
            localChecker.findError = nil
            let finished = expectation(description: "retry obtains released content and name claims")
            let retry = Task {
                let result = try await localPipeline.resolve(d)
                finished.fulfill()
                return result
            }
            await fulfillment(of: [finished], timeout: 2)
            await localPipeline.uploadDidFail(d)  // Unblock a broken implementation after the assertion.
            let retried = try await retry.value
            XCTAssertEqual(retried.identity, initial.identity)
            XCTAssertEqual(retried.decision, .skip(.deletedRemotely, remoteLinkID: "trash"))
        }
    }

    func testCachedRoleCancellationCannotBecomeTrustedAdoption() async throws {
        for failure in transportCancellations {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let digest = Data(repeating: 7, count: 20)
            let active = descriptor(path: "/other/active.HEIC", digest: digest)
            let first = try await localPipeline.resolve(active)
            try await localPipeline.recordUploaded(
                active, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "active")
            localChecker.linkVisibilityError = failure
            let copy = descriptor(digest: digest)
            let nameReads = localChecker.nameLookupAttemptCount
            do {
                let result = try await localPipeline.resolve(copy)
                XCTFail("cancelled role read cannot become trusted adoption: \(result.decision)")
            } catch {
                XCTAssertTrue(UploadError.isCancellation(error))
                XCTAssertFalse(Task.isCancelled)
            }
            XCTAssertEqual(localChecker.linkVisibilityCallCount, 1)
            XCTAssertEqual(localChecker.nameLookupAttemptCount, nameReads, "cancellation must stop before name probe")
            XCTAssertFalse(try XCTUnwrap(localStore.record(for: copy.source)).provesUpload)
        }
    }

    func testSuccessfulAwaitedReadsCannotSettleACancelledCaller() async throws {
        for route in ["epoch", "candidate-role", "fallback-role", "revalidation-name", "revalidation-content"] {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let d = descriptor(digest: Data(repeating: 7, count: 20))
            let first = try await localPipeline.resolve(d)
            await localPipeline.uploadDidFail(d)
            if route != "candidate-role" && route != "fallback-role" {
                try await localPipeline.recordUploaded(
                    d, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "prior")
            }
            await localPipeline.invalidateCachedRemoteState()
            switch route {
            case "epoch": localChecker.onEpochLookup = { withUnsafeCurrentTask { $0?.cancel() } }
            case "candidate-role":
                localChecker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
                    .init(
                        nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash, linkState: .active,
                        linkID: "active")
                ]
                localChecker.onVisibilityLookup = { withUnsafeCurrentTask { $0?.cancel() } }
            case "fallback-role":
                localChecker.findError = UploadError.backend("name unavailable")
                localChecker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "active")]
                localChecker.onVisibilityLookup = { withUnsafeCurrentTask { $0?.cancel() } }
            case "revalidation-name":
                localChecker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
                    .init(
                        nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash, linkState: .active,
                        linkID: "active")
                ]
                localChecker.onNameLookup = { _ in withUnsafeCurrentTask { $0?.cancel() } }
            default: localChecker.onContentLookup = { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let before = localStore.record(for: d.source)
            let task = Task {
                if route.hasPrefix("revalidation") { return try await localPipeline.revalidateKnownRemote(d) }
                return try await localPipeline.resolve(d).decision
            }
            do {
                _ = try await task.value
                XCTFail("\(route) success must not bypass caller cancellation")
            } catch is CancellationError {}
            XCTAssertEqual(localStore.record(for: d.source)?.remoteLinkID, before?.remoteLinkID)
            XCTAssertEqual(localStore.record(for: d.source)?.outcome, before?.outcome)
        }
    }

    func testCancellationDuringBurstCandidatesPreventsAnotherContentLookup() async throws {
        let url = URL(fileURLWithPath: "/burst/IMG_1.HEIC")
        let frame = UploadResourceDescriptor(
            source: .file(url, resource: .burstMember(ordinal: 1)), fileURL: url, filename: "IMG_1.HEIC",
            fileSize: 1000, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            precomputedSHA1Digest: Data(repeating: 7, count: 20), mainRemoteLinkID: "burst-main")
        let first = try await pipeline.resolve(frame)
        await pipeline.uploadDidFail(frame)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            .init(
                nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash, linkState: .active,
                linkID: "another-frame")
        ]
        checker.relatedLinkIDsProvider = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return []
        }
        await pipeline.invalidateCachedRemoteState()
        let contentReads = checker.contentFindCallCount
        let pipeline = try XCTUnwrap(self.pipeline)
        let task = Task { try await pipeline.resolve(frame) }
        do {
            _ = try await task.value
            XCTFail("a cancelled burst-candidate read must propagate cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(checker.relatedLookups, ["burst-main"])
        XCTAssertEqual(checker.contentFindCallCount, contentReads, "cancellation prevents another content request")
        XCTAssertFalse(store.record(for: frame.source)?.provesUpload == true)
    }

    func testCancelledContentAndNameWaitersFinishBeforeTheirOwnerSettles() async throws {
        for sameContent in [true, false] {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let owner = descriptor(path: "/owner/IMG_1.HEIC", digest: Data(repeating: 7, count: 20))
            let first = try await localPipeline.resolve(owner)
            XCTAssertEqual(first.decision, .upload)
            let copy = descriptor(
                path: sameContent ? "/copy/other.HEIC" : "/copy/IMG_1.HEIC",
                digest: Data(repeating: sameContent ? 7 : 8, count: 20))
            let entered = expectation(description: "waiter identity persisted")
            localStore.onUpsert = { row in if row.source == copy.source { entered.fulfill() } }
            let finished = expectation(description: "cancelled waiter finishes while owner is held")
            let waiter = Task {
                do {
                    _ = try await localPipeline.resolve(copy)
                    XCTFail("cancelled claim waiter must throw")
                } catch { XCTAssertTrue(error is CancellationError) }
                finished.fulfill()
            }
            await fulfillment(of: [entered], timeout: 2)
            // This actor turn runs after the resolver reaches its claim suspension.
            _ = await localPipeline.identityRecord(for: copy.source)
            waiter.cancel()
            await fulfillment(of: [finished], timeout: 2)
            localStore.onUpsert = nil
            await localPipeline.uploadDidFail(owner)  // Cleanup only after the cancellation assertion.
            await waiter.value
        }
    }

    func testCancellationDuringPositiveSDKFallbackCannotSettleResolveOrRevalidation() async throws {
        for (revalidating, hasActiveMatch) in [(false, false), (false, true), (true, false), (true, true)] {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let d = descriptor(digest: Data(repeating: 7, count: 20))
            let first = try await localPipeline.resolve(d)
            try await localPipeline.recordUploaded(
                d, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "prior")
            if !revalidating {
                var trash = try XCTUnwrap(localStore.record(for: d.source))
                trash.outcome = "duplicateTrashed"
                XCTAssertTrue(localStore.upsert(trash))
                localChecker.findError = UploadError.backend("name unavailable")
            }
            let before = localStore.record(for: d.source)
            localChecker.exactActiveDuplicates =
                hasActiveMatch ? [PhotoUID(volumeID: "vol", nodeID: "active")] : []
            localChecker.onExactLookup = { withUnsafeCurrentTask { $0?.cancel() } }
            await localPipeline.invalidateCachedRemoteState()
            let task = Task {
                if revalidating { return try await localPipeline.revalidateKnownRemote(d) }
                return try await localPipeline.resolve(d).decision
            }
            do {
                _ = try await task.value
                XCTFail("cancellation during SDK fallback must propagate")
            } catch is CancellationError {}
            XCTAssertEqual(localChecker.exactFindCallCount, 1, "the test must reach the SDK fallback")
            XCTAssertEqual(localStore.record(for: d.source)?.remoteLinkID, before?.remoteLinkID)
            XCTAssertEqual(localStore.record(for: d.source)?.outcome, before?.outcome)
            if !revalidating {
                localChecker.onExactLookup = nil
                localChecker.findError = nil
                let finished = expectation(description: "post-SDK cancellation releases both claims")
                let retry = Task {
                    let result = try await localPipeline.resolve(d)
                    finished.fulfill()
                    return result
                }
                await fulfillment(of: [finished], timeout: 2)
                await localPipeline.uploadDidFail(d)
                let retried = try await retry.value
                XCTAssertEqual(retried.decision, .skip(.activeDuplicate, remoteLinkID: "prior"))
            }
        }
    }

    func testCancelledManifestFastPathDoesNotReturnAnActiveSettlement() async throws {
        let d = descriptor(digest: Data(repeating: 7, count: 20))
        let first = try await pipeline.resolve(d)
        try await pipeline.recordUploaded(d, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "active")
        let pipeline = try XCTUnwrap(self.pipeline)
        checker.onEpochLookup = { XCTFail("a cancelled caller cannot admit another identity lookup") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.resolve(d)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled caller cannot settle through manifest fast path")
        } catch is CancellationError {}
    }

    func testPrimeCancellationAtEpochHashAndNameReadsCannotBeLost() async throws {
        for route in ["epoch", "hash", "name"] {
            for failure in transportCancellations {
                let localStore = FakeIdentityStore()
                let localChecker = FakeChecker()
                let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
                let d = descriptor(digest: Data(repeating: 7, count: 20))
                if route == "epoch" { localChecker.epochError = failure }
                if route == "hash" { localChecker.nameHashesError = failure }
                if route == "name" { localChecker.findError = failure }
                await localPipeline.prime([d])
                localChecker.epochError = nil
                localChecker.nameHashesError = nil
                localChecker.findError = nil
                do {
                    let result = try await localPipeline.resolve(d)
                    XCTFail("\(route) priming cancellation cannot authorize resolution: \(result.decision)")
                    await localPipeline.uploadDidFail(d)
                } catch {
                    XCTAssertTrue(UploadError.isCancellation(error))
                    XCTAssertFalse(Task.isCancelled)
                }
            }
        }
    }

    func testCancelledPrimeDoesNotCancelUnrelatedManualSources() async throws {
        for route in ["epoch", "hash", "name", "role", "stop"] {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let digest = Data(repeating: 7, count: 20)
            let batchSources = (0..<2).map {
                UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "photo-\($0)")
            }
            // Backup lookahead has no prepared bytes and uses queue metadata plus a placeholder URL.
            let lookahead = batchSources.map {
                UploadResourceDescriptor(
                    source: $0, fileURL: URL(fileURLWithPath: "/dev/null"), filename: "IMG_1.HEIC",
                    fileSize: 0, modificationDate: Date(timeIntervalSince1970: 1))
            }
            let failure = URLError(.cancelled)
            if route == "epoch" { localChecker.epochError = failure }
            if route == "hash" { localChecker.nameHashesError = failure }
            if route == "name" { localChecker.findError = failure }
            if route == "role" {
                localChecker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
                    .init(
                        nameHash: "nh(IMG_1.HEIC)", contentHash: "ch(twin)",
                        linkState: .active, linkID: "twin")
                ]
                localChecker.linkVisibilityError = failure
            }
            if route == "stop" {
                localChecker.onEpochLookup = { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let priming = Task { await localPipeline.prime(lookahead) }
            await priming.value
            localChecker.epochError = nil
            localChecker.nameHashesError = nil
            localChecker.findError = nil
            localChecker.linkVisibilityError = nil
            localChecker.onEpochLookup = nil
            localChecker.remoteItemsByNameHash = [:]

            // Even the same name, bytes and identifier in the file namespace belong to another batch.
            let manual = UploadResourceDescriptor(
                source: .init(kind: .fileURL, identifier: batchSources[0].identifier),
                fileURL: URL(fileURLWithPath: "/manual/IMG_1.HEIC"), filename: "IMG_1.HEIC",
                fileSize: 1000, modificationDate: Date(timeIntervalSince1970: 2),
                precomputedSHA1Digest: digest)
            do {
                let result = try await localPipeline.resolve(manual)
                XCTAssertEqual(result.decision, .upload, route)
                try await localPipeline.recordUploaded(
                    manual, identity: result.identity, remoteVolumeID: "vol", remoteLinkID: "manual")
            } catch {
                XCTFail("\(route): an unrelated manual upload must not inherit prime cancellation: \(error)")
            }
            // Resolving another source must not consume the error owed to any primed source.
            for source in batchSources {
                let prepared = UploadResourceDescriptor(
                    source: source, fileURL: URL(fileURLWithPath: "/prepared/IMG_1.HEIC"),
                    filename: "IMG_1.HEIC", fileSize: 1000,
                    modificationDate: Date(timeIntervalSince1970: 2), precomputedSHA1Digest: digest)
                do {
                    let result = try await localPipeline.resolve(prepared)
                    XCTFail("\(route): the primed batch must retain its cancellation: \(result.decision)")
                    try await localPipeline.recordUploaded(
                        prepared, identity: result.identity, remoteVolumeID: "vol", remoteLinkID: "unexpected")
                } catch {
                    XCTAssertTrue(UploadError.isCancellation(error), route)
                }
            }
            XCTAssertFalse(Task.isCancelled)
        }
    }

    func testPrimedRoleCancellationIsDeferredToResolveUntilTheViewIsInvalidated() async throws {
        for failure in transportCancellations {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let digest = Data(repeating: 7, count: 20)
            let active = descriptor(path: "/other/active.HEIC", digest: digest)
            let first = try await localPipeline.resolve(active)
            try await localPipeline.recordUploaded(
                active, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "active")
            let copy = descriptor(digest: digest)
            localChecker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
                .init(
                    nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash,
                    linkState: .active, linkID: "active")
            ]
            localChecker.linkVisibilityError = failure
            await localPipeline.prime([copy])
            localChecker.linkVisibilityError = nil
            do {
                let result = try await localPipeline.resolve(copy)
                XCTFail("priming must preserve cancellation for resolve: \(result.decision)")
            } catch {
                XCTAssertTrue(UploadError.isCancellation(error))
                XCTAssertFalse(Task.isCancelled)
            }
            XCTAssertFalse(localStore.record(for: copy.source)?.provesUpload == true)
            await localPipeline.invalidateCachedRemoteState()
            let retried = try await localPipeline.resolve(copy)
            XCTAssertEqual(retried.decision, .skip(.knownFromManifest, remoteLinkID: "active"))
        }
    }

    func testDraftContentCancellationPropagatesButOrdinaryFailureKeepsDraftBlocked() async throws {
        for failure in transportCancellations + [UploadError.backend("unavailable")] {
            let localStore = FakeIdentityStore()
            let localChecker = FakeChecker()
            let localPipeline = UploadDedupePipeline(store: localStore, checker: localChecker)
            let digest = Data(repeating: 7, count: 20)
            let d = descriptor(digest: digest)
            localChecker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
                .init(
                    nameHash: "nh(IMG_1.HEIC)", contentHash: "other-content", linkState: .draft,
                    linkID: "foreign-draft", clientUID: "other-client")
            ]
            localChecker.contentFindError = failure
            do {
                let result = try await localPipeline.resolve(d)
                XCTAssertFalse(UploadError.isCancellation(failure), "draft fallback must propagate cancellation")
                XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: "foreign-draft"))
            } catch {
                XCTAssertTrue(UploadError.isCancellation(failure), "ordinary failure must keep the draft blocked")
                XCTAssertTrue(UploadError.isCancellation(error))
                XCTAssertFalse(Task.isCancelled)
            }
            XCTAssertFalse(try XCTUnwrap(localStore.record(for: d.source)).provesUpload)
            XCTAssertEqual(localChecker.exactFindCallCount, 0)
        }
    }

    func testExplicitTrashDefersCachedAdoptionToTheNormalSameNameDecision() async throws {
        let digest = Data(repeating: 7, count: 20)
        let active = descriptor(path: "/other/active.HEIC", digest: digest)
        let first = try await pipeline.resolve(active)
        try await pipeline.recordUploaded(
            active, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "cached-other-name")
        let copy = descriptor(digest: digest)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            .init(
                nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash, linkState: .trashed,
                linkID: "trash"),
            .init(
                nameHash: "nh(IMG_1.HEIC)", contentHash: first.identity.contentHash, linkState: .active,
                linkID: "same-name-active"),
        ]
        let result = try await pipeline.resolve(copy)
        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "same-name-active"))
        XCTAssertEqual(store.record(for: copy.source)?.remoteLinkID, "same-name-active")
    }

    func testRemoteContentDuplicateWithDifferentNameSkipsWithoutUpload() async throws {
        hasher.contentSeeds["/local/renamed-copy.HEIC"] = "already-remote-bytes"
        let sha1 = fakeSHA1Hex(seed: "already-remote-bytes")
        let contentHash = "ch(\(sha1))"
        checker.remoteItemsByContentHash[contentHash] = RemotePhotoDuplicate(
            nameHash: "nh(IMG_0001.HEIC)",
            contentHash: contentHash,
            linkState: .active,
            linkID: "remote-existing"
        )

        let local = descriptor(path: "/local/renamed-copy.HEIC")
        let result = try await pipeline.resolve(local)

        XCTAssertEqual(checker.contentFindCallCount, 1, "renamed content still needs the account-wide fallback")

        XCTAssertEqual(
            result.decision, .skip(.activeDuplicate, remoteLinkID: "remote-existing"),
            "remote content identity must win even when the name hash is different")
        XCTAssertEqual(
            checker.findBatches.count, 1,
            "the cheap Proton name-hash check must precede the renamed-content fallback")
        let row = store.record(for: local.source)
        XCTAssertEqual(row?.outcome, UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
        XCTAssertEqual(row?.remoteLinkID, "remote-existing")
    }

    func testExactNameAndContentDuplicateAvoidsAccountWideContentIndex() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)",
                contentHash: contentHash,
                linkState: .active,
                linkID: "remote-existing"
            )
        ]
        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "remote-existing"))
        XCTAssertEqual(
            checker.exactFindCallCount, 0,
            "the batched normal path must not add one SDK request per duplicate")
        XCTAssertEqual(
            checker.contentFindCallCount, 0,
            "the batched Proton name/content proof must not build the full remote content index")
    }

    func testSameNameDifferentContentStillUsesAccountWideFallback() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)",
                contentHash: "different-content",
                linkState: .active,
                linkID: "name-collision"
            )
        ]
        checker.remoteItemsByContentHash[contentHash] = RemotePhotoDuplicate(
            nameHash: "nh(old-name.HEIC)",
            contentHash: contentHash,
            linkState: .active,
            linkID: "actual-twin"
        )

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "actual-twin"))
        XCTAssertEqual(checker.contentFindCallCount, 1)
        XCTAssertEqual(checker.exactFindCallCount, 0)
    }

    func testDraftOnlyCandidateDoesNotInvokeSDKExactActiveLookup() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)",
                contentHash: contentHash,
                linkState: .draft,
                linkID: "draft",
                clientUID: "other-client"
            )
        ]

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: "draft"))
        XCTAssertEqual(checker.exactFindCallCount, 0)
    }

    func testOwnDraftSurvivesContentFallbackAsReplacementDecision() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        let draft = RemotePhotoDuplicate(
            nameHash: "nh(IMG_1.HEIC)",
            contentHash: contentHash,
            linkState: .draft,
            linkID: "stale-draft",
            clientUID: "this-installation"
        )
        checker.remoteItemsByNameHash[draft.nameHash] = [draft]
        checker.remoteItemsByContentHash[contentHash] = draft
        pipeline = UploadDedupePipeline(
            store: store,
            hasher: hasher,
            checker: checker,
            currentClientUID: "this-installation"
        )

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .uploadReplacingDraft)
        await pipeline.uploadDidFail(d)
    }

    func testPrecomputedDigestAvoidsReadingTheExportAgain() async throws {
        let digest = Data(repeating: 0xA5, count: 20)
        let missingURL = URL(fileURLWithPath: "/does-not-exist/photo.heic")
        let descriptor = UploadResourceDescriptor(
            source: .file(missingURL),
            fileURL: missingURL,
            filename: "photo.heic",
            fileSize: 123,
            modificationDate: Date(timeIntervalSince1970: 1),
            precomputedSHA1Digest: digest
        )

        let actual = try await UploadFileHasher().sha1(of: descriptor)
        XCTAssertEqual(actual, digest)
    }

    func testRemoteStateInvalidationPropagatesToContentIndexOwner() async {
        XCTAssertEqual(checker.invalidateCallCount, 0)

        await pipeline.invalidateCachedRemoteState()

        XCTAssertEqual(
            checker.invalidateCallCount, 1,
            "stale-name invalidation must also drop backend content-index state")
    }

    func testDedupeUnavailableResolverFailsBeforeUploadDecision() async {
        let resolver = DedupeUnavailableIdentityResolver(message: "dedupe unavailable")
        do {
            _ = try await resolver.resolve(descriptor())
            XCTFail("expected fail-closed resolver to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("dedupe unavailable"))
        }
    }

    func testTrashedContentRowIsNeverTrustedAsBackedUp() async throws {
        hasher.contentSeeds["/sync1/IMG_1.HEIC"] = "trashed-bytes"
        hasher.contentSeeds["/sync2/IMG_1.HEIC"] = "trashed-bytes"
        let contentHash = "ch(\(fakeSHA1Hex(seed: "trashed-bytes")))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash, linkState: .trashed, linkID: "t-1"
            )
        ]

        let original = try await pipeline.resolve(descriptor(path: "/sync1/IMG_1.HEIC"))
        XCTAssertEqual(original.decision, .skip(.trashedDuplicate, remoteLinkID: "t-1"))

        // The copy shares the bytes, but the persisted trashed outcome must not satisfy the
        // content lookup - the deletion stays respected and re-checked, never "backed up".
        let copy = try await pipeline.resolve(descriptor(path: "/sync2/IMG_1.HEIC"))
        XCTAssertEqual(copy.decision, .skip(.trashedDuplicate, remoteLinkID: "t-1"))
    }

    func testConcurrentIdenticalContentWaitsForUploadThenSkips() async throws {
        hasher.contentSeeds["/sync1/IMG_1.HEIC"] = "dup-bytes"
        hasher.contentSeeds["/sync2/copy.HEIC"] = "dup-bytes"

        let first = descriptor(path: "/sync1/IMG_1.HEIC")
        let resolvedFirst = try await pipeline.resolve(first)
        XCTAssertEqual(resolvedFirst.decision, .upload, "first claims the content upload")

        let second = descriptor(path: "/sync2/copy.HEIC")
        let pipeline = self.pipeline!
        let secondTask = Task { try await pipeline.resolve(second) }
        try await Task.sleep(for: .milliseconds(50))  // let it reach the coalescing wait

        try await pipeline.recordUploaded(
            first, identity: resolvedFirst.identity,
            remoteVolumeID: "vol", remoteLinkID: "link-a")
        let resolvedSecond = try await secondTask.value

        XCTAssertEqual(
            resolvedSecond.decision, .skip(.knownFromManifest, remoteLinkID: "link-a"),
            "identical bytes resolved concurrently must wait and then skip, not double-upload")
    }

    func testUploadedManifestWriteFailureReleasesWaiterAndForcesRemoteRecheck() async throws {
        hasher.contentSeeds["/sync1/IMG_1.HEIC"] = "dup-bytes"
        hasher.contentSeeds["/sync2/copy.HEIC"] = "dup-bytes"

        let first = descriptor(path: "/sync1/IMG_1.HEIC")
        let resolvedFirst = try await pipeline.resolve(first)
        let second = descriptor(path: "/sync2/copy.HEIC")
        let pipeline = self.pipeline!
        let secondTask = Task { try await pipeline.resolve(second) }
        try await Task.sleep(for: .milliseconds(50))

        checker.remoteItemsByContentHash[resolvedFirst.identity.contentHash] = RemotePhotoDuplicate(
            nameHash: resolvedFirst.identity.nameHash,
            contentHash: resolvedFirst.identity.contentHash,
            linkState: .active,
            linkID: "server-link"
        )
        store.rejectNextUpsert()

        do {
            try await pipeline.recordUploaded(
                first,
                identity: resolvedFirst.identity,
                remoteVolumeID: "vol",
                remoteLinkID: "server-link"
            )
            XCTFail("an unpersisted upload outcome must not be reported as settled")
        } catch {
            // The waiter must be released to consult fresh server state.
        }

        let resolvedSecond = try await secondTask.value
        XCTAssertEqual(resolvedSecond.decision, .skip(.activeDuplicate, remoteLinkID: "server-link"))
        XCTAssertEqual(checker.invalidateCallCount, 1)
    }

    func testUploadFailureReleasesWaiterToUploadItself() async throws {
        hasher.contentSeeds["/sync1/IMG_1.HEIC"] = "dup-bytes"
        hasher.contentSeeds["/sync2/copy.HEIC"] = "dup-bytes"

        let first = descriptor(path: "/sync1/IMG_1.HEIC")
        let resolvedFirst = try await pipeline.resolve(first)
        XCTAssertEqual(resolvedFirst.decision, .upload)

        let second = descriptor(path: "/sync2/copy.HEIC")
        let pipeline = self.pipeline!
        let secondTask = Task { try await pipeline.resolve(second) }
        try await Task.sleep(for: .milliseconds(50))

        await pipeline.uploadDidFail(first)
        let resolvedSecond = try await secondTask.value

        XCTAssertEqual(
            resolvedSecond.decision, .upload,
            "after the owner's upload fails, a waiting identical item takes over")
        await pipeline.uploadDidFail(second)  // settle the taken-over claim
    }

    func testFreshFileWithNoRemoteMatchUploads() async throws {
        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(result.identity.correctedName, "IMG_1.HEIC")
        XCTAssertEqual(result.identity.nameHash, "nh(IMG_1.HEIC)")
        XCTAssertEqual(result.identity.contentHash, "ch(\(result.identity.sha1Hex))")
        XCTAssertEqual(result.identity.sha1Digest.count, 20)
        XCTAssertEqual(hasher.hashCount, 1)
        // Identity persisted (crash-safe) without an outcome.
        let row = store.record(for: .file(URL(fileURLWithPath: "/photos/IMG_1.HEIC")))
        XCTAssertEqual(row?.sha1Hex, result.identity.sha1Hex)
        XCTAssertNil(row?.outcome)
    }

    func testSecondResolveReusesCachedHashes() async throws {
        let d = descriptor()
        _ = try await pipeline.resolve(d)
        await pipeline.uploadDidFail(d)
        let nameHashCallsAfterFirst = checker.nameHashCalls
        _ = try await pipeline.resolve(d)

        XCTAssertEqual(hasher.hashCount, 1, "unchanged file must not rehash")
        XCTAssertEqual(checker.nameHashCalls, nameHashCallsAfterFirst, "valid manifest row must reuse HMACs")
    }

    func testChangedSizeInvalidatesCachedHashes() async throws {
        let first = descriptor(size: 1000)
        _ = try await pipeline.resolve(first)
        await pipeline.uploadDidFail(first)
        _ = try await pipeline.resolve(descriptor(size: 1001))
        XCTAssertEqual(hasher.hashCount, 2)
    }

    func testChangedModificationDateInvalidatesCachedHashes() async throws {
        let first = descriptor(mtime: 1_700_000_000)
        _ = try await pipeline.resolve(first)
        await pipeline.uploadDidFail(first)
        _ = try await pipeline.resolve(descriptor(mtime: 1_700_000_001))
        XCTAssertEqual(hasher.hashCount, 2)
    }

    func testHashKeyEpochChangeRecomputesHMACsButNotSHA1() async throws {
        let d = descriptor()
        _ = try await pipeline.resolve(d)
        await pipeline.uploadDidFail(d)
        let callsAfterFirst = checker.nameHashCalls
        checker.epoch = "epoch-2"
        _ = try await pipeline.resolve(d)

        XCTAssertEqual(hasher.hashCount, 1, "SHA-1 does not depend on the hash key")
        XCTAssertGreaterThan(checker.nameHashCalls, callsAfterFirst, "HMACs must be recomputed for a new key epoch")
    }

    func testActiveDuplicateSkipsAndPersistsOutcome() async throws {
        let d = descriptor()
        // Resolve once to learn the content hash the fake produces, then plant the remote twin.
        let probe = try await pipeline.resolve(d)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: probe.identity.contentHash, linkState: .active,
                linkID: "link-9")
        ]
        // New pipeline so the (empty) per-run duplicate cache from the probe doesn't linger.
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)

        let result = try await pipeline.resolve(d)
        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "link-9"))

        let row = store.record(for: d.source)
        XCTAssertEqual(row?.outcome, UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
        XCTAssertEqual(row?.remoteLinkID, "link-9")
    }

    func testManifestKnownDuplicateSkipsWithoutAnyRemoteCall() async throws {
        let d = descriptor()
        let probe = try await pipeline.resolve(d)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: probe.identity.contentHash, linkState: .active,
                linkID: "link-9")
        ]
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        _ = try await pipeline.resolve(d)  // records duplicateActive
        let callsAfterConfirmation = checker.findCallCount
        let hashesAfterConfirmation = hasher.hashCount

        // Third resolve, fresh pipeline (fresh run): manifest fast path, no query, no hashing.
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: "link-9"))
        XCTAssertEqual(checker.findCallCount, callsAfterConfirmation, "manifest hit must not re-query")
        XCTAssertEqual(hasher.hashCount, hashesAfterConfirmation, "manifest hit must not rehash")
    }

    /// A photo library source keeps its name, size, and capture-date mtime when the user edits it again. Only the
    /// digest read from the new bytes proves the change, so the manifest must not answer for the old bytes.
    func testChangedPrecomputedDigestIsNotAnsweredFromTheManifest() async throws {
        let before = Data(repeating: 0x11, count: 20)
        let after = Data(repeating: 0x22, count: 20)
        let original = descriptor(digest: before)
        let first = try await pipeline.resolve(original)
        XCTAssertEqual(first.decision, .upload)
        try await pipeline.recordUploaded(
            original, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "old-link")

        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let unchanged = try await pipeline.resolve(original)
        XCTAssertEqual(unchanged.decision, .skip(.knownFromManifest, remoteLinkID: "old-link"))

        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let edited = try await pipeline.resolve(descriptor(digest: after))
        XCTAssertEqual(edited.decision, .upload, "new bytes with the same name and size must upload")
        XCTAssertEqual(edited.identity.sha1Hex, UploadContentSHA1.hexString(digest: after))
        XCTAssertEqual(hasher.hashCount, 0, "a supplied digest needs no hashing")
    }

    func testRecordUploadedEnablesManifestFastPathNextRun() async throws {
        let d = descriptor()
        let result = try await pipeline.resolve(d)
        XCTAssertEqual(result.decision, .upload)
        try await pipeline.recordUploaded(d, identity: result.identity, remoteVolumeID: "vol", remoteLinkID: "new-link")

        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let second = try await pipeline.resolve(d)
        XCTAssertEqual(second.decision, .skip(.knownFromManifest, remoteLinkID: "new-link"))
    }

    func testKnownUploadedResourceRevalidationUsesSDKExactActiveProof() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        try await pipeline.recordUploaded(
            d,
            identity: first.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "uploaded-link"
        )
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "uploaded-link")]
        let detailedCallsBefore = checker.findCallCount
        let contentCallsBefore = checker.contentFindCallCount

        let decision = try await pipeline.revalidateKnownRemote(d)

        XCTAssertEqual(decision, .skip(.activeDuplicate, remoteLinkID: "uploaded-link"))
        XCTAssertEqual(checker.exactFindCallCount, 1)
        XCTAssertEqual(
            checker.findCallCount, detailedCallsBefore,
            "an exact SDK proof must handle the one-item revalidation")
        XCTAssertEqual(checker.contentFindCallCount, contentCallsBefore)
    }

    func testKnownUploadedResourceRevalidationKeepsIncompleteAbsenceUnknown() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        try await pipeline.recordUploaded(d, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "known")
        checker.remoteItemsByContentHash[first.identity.contentHash] = nil
        let result = try await pipeline.revalidateKnownRemote(d)
        XCTAssertNil(result, "an active-index miss and incomplete metadata are not a deletion")
    }

    func testKnownUploadedResourceRevalidationKeepsCompleteMetadataAbsenceUnknown() async throws {
        checker.deletionMetadata = .init(states: [:], complete: true)
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        try await pipeline.recordUploaded(
            d,
            identity: first.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "uploaded-link"
        )
        checker.remoteItemsByContentHash[first.identity.contentHash] = nil

        let decision = try await pipeline.revalidateKnownRemote(d)

        XCTAssertNil(decision, "no verified all-state ContentHash query exists")
        XCTAssertEqual(checker.invalidateCallCount, 1)
        XCTAssertEqual(checker.findCallCount, 2, "revalidation must bypass the manifest and query current name state")
        XCTAssertEqual(checker.contentFindCallCount, 2, "a name miss must consult the refreshed active-content index")
    }

    func testKnownUploadedResourceRevalidationReturnsCurrentTrashState() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        try await pipeline.recordUploaded(
            d,
            identity: first.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "uploaded-link"
        )
        checker.remoteItemsByNameHash[first.identity.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: first.identity.nameHash,
                contentHash: first.identity.contentHash,
                linkState: .trashed,
                linkID: "uploaded-link"
            )
        ]

        let decision = try await pipeline.revalidateKnownRemote(d)

        XCTAssertEqual(decision, .skip(.trashedDuplicate, remoteLinkID: "uploaded-link"))
        XCTAssertEqual(checker.contentFindCallCount, 1, "an exact trash result needs no account-wide fallback")
    }

    func testTrashedDuplicateKeepsItsLinkForRestoreWithoutProvingAnUpload() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash, linkState: .trashed, linkID: "trash-link")
        ]

        let first = try await pipeline.resolve(d)
        XCTAssertEqual(first.decision, .skip(.trashedDuplicate, remoteLinkID: "trash-link"))
        let saved = try XCTUnwrap(store.record(for: d.source))
        XCTAssertEqual(saved.remoteLinkID, "trash-link", "Restore needs the exact trashed link")
        XCTAssertFalse(saved.provesUpload)
        XCTAssertTrue(
            store.trustedRecords(contentHash: contentHash, hashKeyEpoch: saved.hashKeyEpoch, limit: 10).isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.sources(withRemoteLinkID: "trash-link")).isEmpty)

        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let calls = checker.findCallCount
        let next = try await pipeline.resolve(d)
        XCTAssertEqual(next.decision, .skip(.trashedDuplicate, remoteLinkID: "trash-link"))
        XCTAssertGreaterThan(checker.findCallCount, calls, "a new run must recheck the server")
        let revalidated = try await pipeline.revalidateKnownRemote(d)
        XCTAssertNil(revalidated, "the uploaded-copy revalidation path must reject a trashed manifest row")
    }

    func testKnownTrashNeedsConsentAfterItsServerEntryVanishesAndStillFindsActiveCopies() async throws {
        let d = descriptor()
        let probe = try await pipeline.resolve(d)
        await pipeline.uploadDidFail(d)
        var saved = try XCTUnwrap(store.record(for: d.source))
        saved.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        saved.remoteLinkID = "trash-link"
        XCTAssertTrue(store.upsert(saved))

        for legacyWithoutLink in [false, true] {
            saved.remoteLinkID = legacyWithoutLink ? nil : "trash-link"
            XCTAssertTrue(store.upsert(saved))
            pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
            let vanished = try await pipeline.resolve(d)
            XCTAssertEqual(vanished.decision, .skip(.deletedRemotely, remoteLinkID: saved.remoteLinkID))
            await pipeline.uploadDidFail(d)
        }

        checker.remoteItemsByContentHash[probe.identity.contentHash] = RemotePhotoDuplicate(
            nameHash: "other-name", contentHash: probe.identity.contentHash, linkState: .active, linkID: "active-copy")
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let active = try await pipeline.resolve(d)
        XCTAssertEqual(active.decision, .skip(.activeDuplicate, remoteLinkID: "active-copy"))
        XCTAssertTrue(try XCTUnwrap(store.record(for: d.source)).provesUpload)
        XCTAssertEqual(store.record(for: d.source)?.remoteLinkID, "active-copy")
    }

    func testPrimeQueriesLegacyTrashRowsAndHydratesTheirRestoreLink() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        await pipeline.uploadDidFail(d)
        var legacy = try XCTUnwrap(store.record(for: d.source))
        legacy.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        checker.remoteItemsByNameHash[first.identity.nameHash] = [
            .init(
                nameHash: first.identity.nameHash, contentHash: first.identity.contentHash,
                linkState: .trashed, linkID: "recoverable-trash")
        ]
        for knownLink in [nil, "old-trash"] as [String?] {
            legacy.remoteLinkID = knownLink
            XCTAssertTrue(store.upsert(legacy))
            pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
            let before = checker.findCallCount
            await pipeline.prime([d])
            XCTAssertGreaterThan(checker.findCallCount, before, "a trash row never skips the fresh name lookup")
            let result = try await pipeline.resolve(d)
            XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "recoverable-trash"))
            XCTAssertEqual(store.record(for: d.source)?.remoteLinkID, "recoverable-trash")
            XCTAssertFalse(try XCTUnwrap(store.record(for: d.source)).provesUpload)
        }
    }

    func testKnownTrashFactDoesNotApplyToAChangedFileIdentity() async throws {
        let d = descriptor()
        _ = try await pipeline.resolve(d)
        await pipeline.uploadDidFail(d)
        var saved = try XCTUnwrap(store.record(for: d.source))
        saved.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        saved.remoteLinkID = "old-trash"
        XCTAssertTrue(store.upsert(saved))
        let changed = descriptor(size: d.fileSize + 1)
        let result = try await pipeline.resolve(changed)
        XCTAssertEqual(result.decision, .upload, "the known deletion belongs only to the exact cached file identity")
        await pipeline.uploadDidFail(changed)
    }

    func testMissingStateInAContentResultCannotBecomeADeletedPhoto() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        await pipeline.uploadDidFail(d)
        checker.remoteItemsByContentHash[first.identity.contentHash] = .init(
            nameHash: "other-name", contentHash: first.identity.contentHash, linkState: nil, linkID: "unknown")
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let result = try await pipeline.resolve(d)
        XCTAssertEqual(result.decision, .skip(.inconsistentRemoteState, remoteLinkID: "unknown"))
    }

    func testTrashedOutcomeIsRecordedButRecheckedEveryRun() async throws {
        let d = descriptor()
        let probe = try await pipeline.resolve(d)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: probe.identity.contentHash, linkState: .trashed,
                linkID: "link-t")
        ]
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let second = try await pipeline.resolve(d)
        XCTAssertEqual(second.decision, .skip(.trashedDuplicate, remoteLinkID: "link-t"))
        XCTAssertEqual(
            store.record(for: d.source)?.outcome, UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue)

        // Emptying the trash never authorizes another upload; only an explicit version decision can do that.
        checker.remoteItemsByNameHash = [:]
        let queriesBefore = checker.findCallCount
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let third = try await pipeline.resolve(d)
        XCTAssertEqual(third.decision, .skip(.deletedRemotely, remoteLinkID: "link-t"))
        XCTAssertGreaterThan(checker.findCallCount, queriesBefore)
    }

    func testConcurrentDifferentPhotosWithSameFilenameSerializeWithoutDedupingBytes() async throws {
        // Camera filenames repeat after a reset. Both photos must upload, but never concurrently
        // under one name because a live first upload would look like a stale draft to the second.
        let a = descriptor(path: "/a/IMG.jpg")
        let b = descriptor(path: "/b/IMG.jpg")
        let pipeline = self.pipeline!
        let ra = try await pipeline.resolve(a)
        XCTAssertEqual(ra.decision, .upload)

        let second = Task { try await pipeline.resolve(b) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(checker.findCallCount, 1, "second same-name item must wait behind the live upload")

        try await pipeline.recordUploaded(
            a,
            identity: ra.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "first-link"
        )
        let rb = try await second.value
        XCTAssertEqual(rb.decision, .upload, "same filename with different bytes remains a new photo")
        XCTAssertEqual(checker.findCallCount, 1, "the first upload refreshes the shared cached name view")
        await pipeline.uploadDidFail(b)
    }

    func testConcurrentResolveOfSameSourceWaitsForFirstAttempt() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        XCTAssertEqual(first.decision, .upload)

        let pipeline = self.pipeline!
        let duplicateCall = Task { try await pipeline.resolve(d) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(checker.findCallCount, 1)

        try await pipeline.recordUploaded(
            d,
            identity: first.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "first-link"
        )
        let second = try await duplicateCall.value
        XCTAssertEqual(second.decision, .skip(.knownFromManifest, remoteLinkID: "first-link"))
    }

    func testSettlingEarlierResourceRevisionPreservesTheLaterContentClaim() async throws {
        try await assertEarlierRevisionPreservesLaterClaim(.uploaded)
    }

    func testFailingEarlierResourceRevisionPreservesTheLaterContentClaim() async throws {
        try await assertEarlierRevisionPreservesLaterClaim(.failed)
    }

    func testReconcilingEarlierResourceRevisionPreservesTheLaterContentClaim() async throws {
        try await assertEarlierRevisionPreservesLaterClaim(.reconciliation)
    }

    private enum EarlierRevisionSettlement { case uploaded, failed, reconciliation }

    private func assertEarlierRevisionPreservesLaterClaim(_ settlement: EarlierRevisionSettlement) async throws {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "edited-photo")
        let earlier = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/earlier/original.HEIC"),
            filename: "original.HEIC", fileSize: 1_000, modificationDate: Date(timeIntervalSince1970: 100)
        )
        let later = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/later/edited.jpg"),
            filename: "edited.jpg", fileSize: 2_000, modificationDate: Date(timeIntervalSince1970: 200)
        )
        let copy = descriptor(path: "/copy/renamed.jpg", size: 2_000)
        hasher.contentSeeds[later.fileURL.path] = "edited-bytes"
        hasher.contentSeeds[copy.fileURL.path] = "edited-bytes"
        let first = try await pipeline.resolve(earlier)
        let second = try await pipeline.resolve(later)
        XCTAssertEqual(first.decision, .upload)
        XCTAssertEqual(second.decision, .upload)
        switch settlement {
        case .uploaded:
            try await pipeline.recordUploaded(
                earlier, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "earlier-link"
            )
        case .failed:
            await pipeline.uploadDidFail(earlier)
        case .reconciliation:
            await pipeline.remoteCommitNeedsReconciliation(earlier)
        }

        let queriedBeforeSettlement = expectation(description: "copy must wait for the later resource revision")
        queriedBeforeSettlement.isInverted = true
        checker.onNameLookup = { hashes in
            if hashes.contains("nh(renamed.jpg)") { queriedBeforeSettlement.fulfill() }
        }
        let pipeline = self.pipeline!
        let copyTask = Task { try await pipeline.resolve(copy) }
        await fulfillment(of: [queriedBeforeSettlement], timeout: 0.2)

        try await pipeline.recordUploaded(
            later, identity: second.identity, remoteVolumeID: "vol", remoteLinkID: "later-link"
        )
        let result = try await copyTask.value
        XCTAssertEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: "later-link"))
        if result.decision.uploadsBytes { await pipeline.uploadDidFail(copy) }
    }

    func testPrimeBatchesAtProtonSize() async throws {
        let descriptors = (0..<200).map { descriptor(path: "/photos/IMG_\($0).HEIC") }
        await pipeline.prime(descriptors)

        XCTAssertEqual(
            checker.findBatches.map(\.count).sorted(), [50, 150],
            "prime must chunk at Proton's 150-hash batch size")
        XCTAssertEqual(hasher.hashCount, 0, "prime must never hash file contents")
        XCTAssertEqual(
            checker.invalidateCallCount, 0,
            "lookahead refreshes must not discard and rebuild the account-wide content index")

        // Primed hashes are cache hits - resolving one must not add a query.
        let queriesAfterPrime = checker.findCallCount
        _ = try await pipeline.resolve(descriptors[0])
        XCTAssertEqual(checker.findCallCount, queriesAfterPrime)
    }

    func testDuplicateCheckFailureSurfacesAsError() async {
        checker.findError = UploadError.backend("duplicates endpoint down")
        do {
            _ = try await pipeline.resolve(descriptor())
            XCTFail("expected error")
        } catch {
            // resolve must throw - the manager surfaces this as a failed item, never a blind upload
        }
    }

    func testSDKExactMatchSafelyRecoversDetailedLookupFailure() async throws {
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "sdk-existing")]

        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "sdk-existing"))
        XCTAssertEqual(checker.exactFindCallCount, 1)
        XCTAssertEqual(checker.contentFindCallCount, 0)
    }

    // MARK: - Root eligibility: a main photo never adopts a related file of another photo

    private func activeRow(
        _ linkID: String, contentHash: String, name: String = "IMG_1.HEIC"
    ) -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(nameHash: "nh(\(name))", contentHash: contentHash, linkState: .active, linkID: linkID)
    }

    func testAPrimaryNeverAdoptsTheManifestRowOfABurstFrame() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "frame-bytes"
        let sha1 = fakeSHA1Hex(seed: "frame-bytes")
        let contentHash = "ch(\(sha1))"
        // This device uploaded the bytes as a frame of a burst. The content index also names related files.
        store.upsert(
            UploadIdentityRecord(
                source: .file(URL(fileURLWithPath: "/burst/IMG_0001.HEIC"), resource: .burstMember(ordinal: 1)),
                filename: "IMG_0002.HEIC", correctedName: "IMG_0002.HEIC", fileSize: 1000,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000), sha1Hex: sha1,
                nameHash: "nh(IMG_0002.HEIC)", contentHash: contentHash, hashKeyEpoch: checker.epoch,
                remoteVolumeID: "vol", remoteLinkID: "frame-link",
                outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: Date()))
        checker.relatedLinkIDsByMainLinkID["burst-main"] = ["frame-link"]
        checker.remoteItemsByContentHash[contentHash] = activeRow("frame-link", contentHash: contentHash)

        let d = descriptor()
        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload, "a burst frame is no photo of its own")
        XCTAssertNil(store.record(for: d.source)?.remoteLinkID)
    }

    func testAFrameOfAReplacingSeriesEditNeverSkipsByItsRowUnderTheEarlierMain() async throws {
        let path = "/burst/IMG_0001.HEIC"
        let frame = UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: path), resource: .burstMember(ordinal: 1)),
            fileURL: URL(fileURLWithPath: path + "#IMG_0002.HEIC"), filename: "IMG_0002.HEIC", fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let first = try await pipeline.resolve(frame.relatedTo(mainRemoteLinkID: "earlier-main"))
        XCTAssertEqual(first.decision, .upload)
        try await pipeline.recordUploaded(
            frame, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "frame-under-earlier-main")

        let settled = try await pipeline.resolve(frame.relatedTo(mainRemoteLinkID: "earlier-main"))
        XCTAssertEqual(settled.decision, .skip(.knownFromManifest, remoteLinkID: "frame-under-earlier-main"))

        // The edit of the main frame replaces the series: the frame belongs under the edited main photo now.
        let replacing = frame.relatedTo(mainRemoteLinkID: "edited-main", requiresRelatedMatch: true)
        let result = try await pipeline.resolve(replacing)

        XCTAssertEqual(result.decision, .upload, "the row names the copy under the replaced main photo")
        await pipeline.uploadDidFail(replacing)
    }

    func testAResolveKeepsTheLinkThatAMergeMovedItsRowToWhileItRan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebind-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let store = RebindBeforeNextWriteStore(base: manifest)
        let pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let path = "/photos/IMG_1.HEIC"
        let video = UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: path), resource: .livePairedVideo),
            fileURL: URL(fileURLWithPath: path + "#IMG_1.MOV"), filename: "IMG_1.MOV", fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let first = try await pipeline.resolve(video.relatedTo(mainRemoteLinkID: "duplicate-main"))
        XCTAssertEqual(first.decision, .upload)
        try await pipeline.recordUploaded(
            video, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "duplicate-video")

        // A merge of exact duplicates moves the row to the copy under the kept photo after this resolve read it.
        store.rebindBeforeNextWrite(
            [UploadRemoteLinkMove(from: "duplicate-video", to: "kept-video", contentHash: first.identity.contentHash)],
            hashKeyEpoch: checker.epoch)
        let replacing = video.relatedTo(mainRemoteLinkID: "kept-main", requiresRelatedMatch: true)
        let raced = try await pipeline.resolve(replacing)
        if raced.decision.uploadsBytes { await pipeline.uploadDidFail(replacing) }

        XCTAssertEqual(manifest.record(for: video.source)?.remoteLinkID, "kept-video")
        let next = try await pipeline.resolve(video.relatedTo(mainRemoteLinkID: "kept-main"))
        XCTAssertEqual(next.decision, .skip(.knownFromManifest, remoteLinkID: "kept-video"))
    }

    func testAResolveThatConfirmsTheLinkItReadKeepsTheLinkThatAMergeMovedItsRowTo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebind-confirm-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let store = RebindBeforeNextWriteStore(base: manifest)
        let pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let path = "/photos/IMG_1.HEIC"
        let video = UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: path), resource: .livePairedVideo),
            fileURL: URL(fileURLWithPath: path + "#IMG_1.MOV"), filename: "IMG_1.MOV", fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let first = try await pipeline.resolve(video.relatedTo(mainRemoteLinkID: "duplicate-main"))
        XCTAssertEqual(first.decision, .upload)
        try await pipeline.recordUploaded(
            video, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "duplicate-video")
        // The server still lists the copy under the duplicate as active, so the resolve confirms the link it read.
        checker.remoteItemsByNameHash[first.identity.nameHash] = [
            activeRow("duplicate-video", contentHash: first.identity.contentHash, name: "IMG_1.MOV")
        ]
        checker.relatedLinkIDsByMainLinkID["duplicate-main"] = ["duplicate-video"]

        // A merge of exact duplicates moves the row to the copy under the kept photo after this resolve read it.
        store.rebindBeforeNextWrite(
            [UploadRemoteLinkMove(from: "duplicate-video", to: "kept-video", contentHash: first.identity.contentHash)],
            hashKeyEpoch: checker.epoch)
        let confirming = video.relatedTo(mainRemoteLinkID: "duplicate-main", requiresRelatedMatch: true)
        let raced = try await pipeline.resolve(confirming)

        XCTAssertEqual(raced.decision, .skip(.activeDuplicate, remoteLinkID: "duplicate-video"))
        XCTAssertEqual(manifest.record(for: video.source)?.remoteLinkID, "kept-video")
    }

    func testAPrimaryUploadsWhenItsOnlyNameMatchIsTheOriginalUnderAnEditedPhoto() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [activeRow("original-link", contentHash: contentHash)]
        checker.relatedLinkIDsByMainLinkID["edited-main"] = ["original-link"]

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload, "the hidden original under an edit is no backup of this photo")
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        await pipeline.uploadDidFail(d)
    }

    func testAPrimaryAdoptsTheMainPhotoWhenARelatedFileHasTheSameBytes() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            activeRow("frame-link", contentHash: contentHash), activeRow("main-link", contentHash: contentHash),
        ]
        checker.relatedLinkIDsByMainLinkID["burst-main"] = ["frame-link"]

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "main-link"))
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        XCTAssertEqual(checker.contentFindCallCount, 0)
    }

    func testAPrimaryNeverAdoptsARelatedFileWhoseMetadataOmitsTheState() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        // The listing states the row active. The decoded metadata omits State but names the main photo, so the
        // role alone shows a related file of another photo.
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [activeRow("frame-link", contentHash: contentHash)]
        checker.linkVisibilityByID["frame-link"] = RemoteLinkVisibility(
            isActive: true, mainPhotoLinkID: "burst-main", hasExplicitPhotoState: false)

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload, "a related file of another photo is no backup of this photo")
        XCTAssertNil(store.record(for: d.source)?.remoteLinkID)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        await pipeline.uploadDidFail(d)
    }

    func testAPrimaryUploadsWhenTheContentIndexNamesOnlyARelatedFile() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "video-bytes"
        let contentHash = "ch(\(fakeSHA1Hex(seed: "video-bytes")))"
        checker.remoteItemsByContentHash[contentHash] = activeRow(
            "video-link", contentHash: contentHash, name: "IMG_9.MOV")
        checker.relatedLinkIDsByMainLinkID["live-main"] = ["video-link"]

        let d = descriptor()
        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload, "a paired video is no photo of its own")
        XCTAssertEqual(checker.contentFindCallCount, 1)
        await pipeline.uploadDidFail(d)
    }

    func testOneResolveReadsTheVisibilityOfALinkOnlyOnce() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [activeRow("frame-link", contentHash: contentHash)]
        checker.remoteItemsByContentHash[contentHash] = activeRow("frame-link", contentHash: contentHash)
        checker.relatedLinkIDsByMainLinkID["burst-main"] = ["frame-link"]

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(checker.contentFindCallCount, 1)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1, "the name rows and the content index name the same link")
        await pipeline.uploadDidFail(d)
    }

    func testAPrimaryWithoutAnActiveContentMatchReadsNoVisibility() async throws {
        let d = descriptor()
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [activeRow("other-photo", contentHash: "other-bytes")]

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(checker.linkVisibilityCallCount, 0)
        await pipeline.uploadDidFail(d)
    }

    func testAFailedVisibilityReadKeepsTheDuplicateDecision() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [activeRow("original-link", contentHash: contentHash)]
        checker.relatedLinkIDsByMainLinkID["edited-main"] = ["original-link"]
        checker.linkVisibilityError = UploadError.backend("metadata endpoint down")

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(
            result.decision, .skip(.activeDuplicate, remoteLinkID: "original-link"),
            "an unproven role keeps the decision of the listing")
    }

    func testASecondaryAdoptsItsCopyUnderItsMainPhotoWithOneRoleRead() async throws {
        let video = UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: "/photos/IMG_1.HEIC"), resource: .livePairedVideo),
            fileURL: URL(fileURLWithPath: "/photos/IMG_1.MOV"), filename: "IMG_1.MOV", fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000), mainRemoteLinkID: "live-main")
        let contentHash = "ch(\(fakeSHA1Hex(seed: "/photos/IMG_1.MOV")))"
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            activeRow("video-link", contentHash: contentHash, name: "IMG_1.MOV")
        ]
        checker.relatedLinkIDsByMainLinkID["live-main"] = ["video-link"]

        let result = try await pipeline.resolve(video)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "video-link"))
        // The copy proves the video only through its role. One read answers it, also for a main photo in the trash.
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        XCTAssertTrue(checker.relatedLookups.isEmpty)
    }

    func testTheSDKFallbackNeverAdoptsARelatedFileForAPrimary() async throws {
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "frame-link")]
        checker.linkVisibilityByID["frame-link"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: "burst-main")

        do {
            let result = try await pipeline.resolve(descriptor())
            XCTFail("expected the lookup error, got \(result.decision)")
        } catch {
            // Only a main photo proves the bytes. Without one, the item fails like any failed lookup.
        }
        XCTAssertEqual(checker.exactFindCallCount, 1)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
    }

    /// Stores a trusted primary row of another file with these bytes, as an earlier version wrote it.
    private func storePrimaryRow(_ path: String, linkID: String, seed: String, updatedAt: Date) {
        let sha1 = fakeSHA1Hex(seed: seed)
        store.upsert(
            UploadIdentityRecord(
                source: .file(URL(fileURLWithPath: path), resource: .primary),
                filename: "IMG_5.HEIC", correctedName: "IMG_5.HEIC", fileSize: 1000,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000), sha1Hex: sha1,
                nameHash: "nh(IMG_5.HEIC)", contentHash: "ch(\(sha1))", hashKeyEpoch: checker.epoch,
                remoteVolumeID: "vol", remoteLinkID: linkID,
                outcome: UploadIdentityManifestStore.Outcome.duplicateActive.rawValue, updatedAt: updatedAt))
    }

    func testAPrimaryNeverAdoptsALegacyPrimaryRowThatNamesARelatedFile() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "frame-bytes"
        storePrimaryRow("/old/IMG_5.HEIC", linkID: "frame-link", seed: "frame-bytes", updatedAt: Date())
        checker.linkVisibilityByID["frame-link"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: "burst-main")

        let d = descriptor()
        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .upload, "a primary row of an earlier version proves no main photo")
        XCTAssertNil(store.record(for: d.source)?.remoteLinkID)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        await pipeline.uploadDidFail(d)
    }

    func testAPrimaryAdoptsTheMainPhotoOfALaterManifestRowWhenTheFirstNamesARelatedFile() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "shared-bytes"
        storePrimaryRow(
            "/old/IMG_5.HEIC", linkID: "frame-link", seed: "shared-bytes", updatedAt: Date(timeIntervalSince1970: 1))
        storePrimaryRow(
            "/copy/IMG_5.HEIC", linkID: "main-link", seed: "shared-bytes", updatedAt: Date(timeIntervalSince1970: 2))
        checker.linkVisibilityByID["frame-link"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: "burst-main")
        checker.linkVisibilityByID["main-link"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil)

        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: "main-link"))
        XCTAssertEqual(checker.linkVisibilityCallCount, 1, "one read covers every row")
    }

    func testAPrimaryAdoptsTheMainPhotoWhenTheContentIndexNamesARelatedFileFirst() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "shared-bytes"
        let contentHash = "ch(\(fakeSHA1Hex(seed: "shared-bytes")))"
        checker.contentMatchesByContentHash[contentHash] = [
            activeRow("frame-link", contentHash: contentHash, name: "IMG_9.HEIC"),
            activeRow("main-link", contentHash: contentHash, name: "IMG_8.HEIC"),
        ]
        checker.relatedLinkIDsByMainLinkID["burst-main"] = ["frame-link"]

        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "main-link"))
        XCTAssertEqual(checker.contentFindCallCount, 1)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
    }

    func testAPrimaryAdoptsTheMainPhotoOfTheNinthManifestRowAfterEightRowsNameOneRelatedFile() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "shared-bytes"
        for index in 0..<8 {
            storePrimaryRow(
                "/old/\(index)/IMG_5.HEIC", linkID: "frame-link", seed: "shared-bytes",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        storePrimaryRow(
            "/copy/IMG_5.HEIC", linkID: "main-link", seed: "shared-bytes", updatedAt: Date(timeIntervalSince1970: 9))
        checker.linkVisibilityByID["frame-link"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: "burst-main")
        checker.linkVisibilityByID["main-link"] = RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil)

        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: "main-link"))
        XCTAssertEqual(checker.linkVisibilityCallCount, 1, "a batch holds eight distinct links, not eight rows")
    }

    func testAPrimaryAdoptsTheMainPhotoThatTheContentIndexNamesAfterEightRelatedFiles() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "shared-bytes"
        let contentHash = "ch(\(fakeSHA1Hex(seed: "shared-bytes")))"
        let frames = (0..<8).map { "frame-\($0)" }
        checker.contentMatchesByContentHash[contentHash] =
            frames.map { activeRow($0, contentHash: contentHash, name: "IMG_9.HEIC") }
            + [activeRow("main-link", contentHash: contentHash, name: "IMG_8.HEIC")]
        checker.relatedLinkIDsByMainLinkID["burst-main"] = Set(frames)

        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "main-link"))
        XCTAssertEqual(checker.contentFindCallCount, 1, "one consistent read of every candidate")
        XCTAssertEqual(checker.linkVisibilityCallCount, 2, "one read for each batch of candidates")
    }

    /// Plants one active same-content row for each of `count` roots, under their own names.
    private func rootsWithActiveTwins(_ count: Int) -> [UploadResourceDescriptor] {
        (0..<count).map { index in
            let root = descriptor(path: "/photos/IMG_\(index).HEIC")
            let contentHash = "ch(\(fakeSHA1Hex(seed: root.fileURL.path)))"
            checker.remoteItemsByNameHash["nh(IMG_\(index).HEIC)"] = [
                activeRow("link-\(index)", contentHash: contentHash, name: "IMG_\(index).HEIC")
            ]
            return root
        }
    }

    func testCancellationDuringPrimedVisibilityStopsBeforeTheNextBatch() async throws {
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker, batchSize: 1)
        let roots = rootsWithActiveTwins(2)
        checker.onVisibilityLookup = { withUnsafeCurrentTask { $0?.cancel() } }
        let pipeline = try XCTUnwrap(self.pipeline)
        let priming = Task { await pipeline.prime(roots) }
        await priming.value
        XCTAssertEqual(checker.linkVisibilityCallCount, 1, "cancellation must prevent the next metadata batch")
        checker.onVisibilityLookup = nil
        do {
            _ = try await pipeline.resolve(roots[0])
            XCTFail("priming cancellation must reach the next resolve")
        } catch is CancellationError {}
        XCTAssertFalse(Task.isCancelled)
    }

    func testPrimeReadsTheVisibilityOfTheUpcomingRootsInBatches() async throws {
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker, batchSize: 2)
        let roots = rootsWithActiveTwins(5)
        checker.relatedLinkIDsByMainLinkID["burst-main"] = ["link-4"]

        await pipeline.prime(roots)
        var decisions: [UploadDuplicateDecision] = []
        for root in roots {
            decisions.append(try await pipeline.resolve(root).decision)
        }

        XCTAssertEqual(
            decisions,
            (0..<4).map { UploadDuplicateDecision.skip(.activeDuplicate, remoteLinkID: "link-\($0)") } + [.upload],
            "a related file is still no backup of a root")
        XCTAssertEqual(checker.linkVisibilityCallCount, 3, "5 roots in batches of 2 cost 3 reads, not 5")
    }

    func testAFailedPrimeReadKeepsTheDuplicateDecisionsWithoutAReadPerRoot() async throws {
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker, batchSize: 2)
        let roots = rootsWithActiveTwins(3)
        checker.linkVisibilityError = UploadError.backend("metadata endpoint down")

        await pipeline.prime(roots)
        XCTAssertEqual(checker.linkVisibilityCallCount, 2)
        checker.linkVisibilityError = nil
        for (index, root) in roots.enumerated() {
            let result = try await pipeline.resolve(root)
            XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "link-\(index)"))
        }

        XCTAssertEqual(checker.linkVisibilityCallCount, 2, "an unproven role keeps the listing, without a retry")
    }

    func testResolveCancellationDuringHashingPropagates() async throws {
        hasher.delay = .seconds(5)
        let d = descriptor()
        let pipeline = self.pipeline!
        let task = Task { _ = try await pipeline.resolve(d) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }
}

/// The real manifest, with a merge of exact duplicates that moves rows right before the next write.
private final class RebindBeforeNextWriteStore: UploadIdentityStore, @unchecked Sendable {
    private let base: UploadIdentityManifestStore
    private let lock = NSLock()
    private var pending: (moves: [UploadRemoteLinkMove], epoch: String)?

    init(base: UploadIdentityManifestStore) { self.base = base }

    func rebindBeforeNextWrite(_ moves: [UploadRemoteLinkMove], hashKeyEpoch: String) {
        lock.withLock { pending = (moves, hashKeyEpoch) }
    }

    private func rebindIfPending() {
        let rebind: (moves: [UploadRemoteLinkMove], epoch: String)? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        if let rebind { XCTAssertTrue(base.rebindRemoteLinks(rebind.moves, hashKeyEpoch: rebind.epoch)) }
    }

    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? { base.record(for: source) }
    func trustedRecords(contentHash: String, hashKeyEpoch: String, limit: Int) -> [UploadIdentityRecord] {
        base.trustedRecords(contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, limit: limit)
    }
    func upsert(_ record: UploadIdentityRecord) -> Bool {
        rebindIfPending()
        return base.upsert(record)
    }
    func upsert(_ record: UploadIdentityRecord, keepingRemoteLinkChangedFrom readLinkID: String?) -> Bool {
        rebindIfPending()
        return base.upsert(record, keepingRemoteLinkChangedFrom: readLinkID)
    }
    func forgetRemoteLinks(_ linkIDs: Set<String>, of source: UploadSourceIdentity) -> Bool {
        base.forgetRemoteLinks(linkIDs, of: source)
    }
    func rebindRemoteLinks(_ moves: [UploadRemoteLinkMove], hashKeyEpoch: String) -> Bool {
        base.rebindRemoteLinks(moves, hashKeyEpoch: hashKeyEpoch)
    }
}
