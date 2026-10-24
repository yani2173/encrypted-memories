import AlbumSyncCore
import Foundation
import PhotoLibraryBackupAdapter
import UploadCore
import XCTest

final class AlbumRemoteProofLookupTests: XCTestCase {
    private func candidate(
        _ id: String, kind: UploadSourceIdentity.Kind = .photoLibraryAsset,
        resource: UploadSourceIdentity.Resource = .primary, revision: Int64 = 100,
        external: Bool = true, count: Int = 1
    ) -> UploadBackupAssetCandidate {
        .init(
            snapshot: .init(
                source: .init(kind: kind, identifier: id, resource: resource),
                revision: .init(rawValue: revision), resourceCount: count,
                externalIdentity: external ? .init(identifier: "cloud-\(id)", revision: .init(rawValue: revision)) : nil
            ),
            originalFilename: "Same.HEIC", byteCount: 42)
    }

    private func withQueue(
        _ body: (UploadBackupSyncQueueManifestStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "album-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        defer {
            queue.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(queue)
    }

    private func seed(
        _ candidate: UploadBackupAssetCandidate, in queue: UploadBackupSyncQueueManifestStore,
        state: UploadBackupSyncQueueState = .alreadyBackedUp
    ) {
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: candidate.snapshot.source, revision: candidate.snapshot.revision,
                    originalFilename: candidate.originalFilename, state: state,
                    updatedAt: Date(timeIntervalSince1970: 100))))
    }

    func testOnlyRequestedPrimaryPhotosWithSameSettledRevisionAndExternalIdentityAreAsked() async throws {
        try await withQueue { queue in
            let valid = self.candidate("valid")
            let pending = self.candidate("pending")
            let file = self.candidate("file", kind: .fileURL)
            let secondary = self.candidate("secondary", resource: .livePairedVideo)
            let unidentified = self.candidate("unidentified", external: false)
            let unrequested = self.candidate("unrequested")
            let stale = self.candidate("stale", revision: 101)
            for asset in [valid, file, secondary, unidentified, unrequested] { self.seed(asset, in: queue) }
            self.seed(pending, in: queue, state: .discovered)
            self.seed(self.candidate("stale", revision: 100), in: queue)
            let resolver = ScriptedAlbumProofResolver()
            let links = try await AlbumSyncRemoteProofLookup.remoteLinks(
                for: ["valid", "pending", "file", "secondary", "unidentified", "stale"],
                catalog: ProofTestCatalog(assets: [valid, pending, file, secondary, unidentified, unrequested, stale]),
                queue: queue, resolver: resolver)
            XCTAssertEqual(Set(links.keys), ["valid"])
            XCTAssertEqual(resolver.requests.flatMap { $0 }.map(\.identifier), ["cloud-valid"])
            XCTAssertNil(links["valid"]?.sha1Hex)
        }
    }

    func testRejectsWrongIdentityRevisionResourceCountAndMalformedCompoundLinks() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset")
            self.seed(asset, in: queue)
            let identity = try XCTUnwrap(asset.snapshot.externalIdentity)
            let base = UploadRemoteAssetIndexRecord(
                externalIdentity: identity, resourceCount: 1, remoteLinkIDs: ["main"], hashKeyEpoch: "epoch")
            var wrongID = base
            wrongID.externalIdentity = .init(identifier: "another-cloud", revision: identity.revision)
            var wrongRevision = base
            wrongRevision.externalIdentity = .init(identifier: identity.identifier, revision: .init(rawValue: 101))
            var wrongCount = base
            wrongCount.resourceCount = 2
            wrongCount.remoteLinkIDs = ["main", "video"]
            var incomplete = base
            incomplete.resourceCount = 2
            incomplete.remoteLinkIDs = ["main"]
            var repeated = base
            repeated.resourceCount = 2
            repeated.remoteLinkIDs = ["main", "main"]
            var surplus = base
            surplus.resourceCount = 2
            surplus.remoteLinkIDs = ["main", "video", "main"]
            var empty = base
            empty.remoteLinkIDs = [""]
            for (proof, count) in [
                (wrongID, 1), (wrongRevision, 1), (wrongCount, 1), (incomplete, 2), (repeated, 2), (surplus, 2),
                (empty, 1),
            ] {
                let current = self.candidate("asset", count: count)
                let resolver = ScriptedAlbumProofResolver(override: [identity: proof])
                let links = try await AlbumSyncRemoteProofLookup.remoteLinks(
                    for: ["asset"], catalog: ProofTestCatalog(assets: [current]), queue: queue, resolver: resolver)
                XCTAssertTrue(links.isEmpty, "Invalid proof must not attach: \(proof)")
            }
        }
    }

    func testUnavailableMissingAndAmbiguousProofsRemainUnattachable() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset")
            self.seed(asset, in: queue)
            for resolver in [
                ScriptedAlbumProofResolver(override: [:]), ScriptedAlbumProofResolver(failure: .unavailable),
            ] {
                let links = try await AlbumSyncRemoteProofLookup.remoteLinks(
                    for: ["asset"], catalog: ProofTestCatalog(assets: [asset]), queue: queue, resolver: resolver)
                XCTAssertTrue(links.isEmpty)
            }
        }
    }

    func testNoExternalIdentityMeansNoProofRequest() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset", external: false)
            self.seed(asset, in: queue)
            let resolver = ScriptedAlbumProofResolver()
            let links = try await AlbumSyncRemoteProofLookup.remoteLinks(
                for: ["asset"], catalog: ProofTestCatalog(assets: [asset]), queue: queue, resolver: resolver)
            XCTAssertTrue(links.isEmpty)
            XCTAssertTrue(resolver.requests.isEmpty)
        }
    }

    func testCancellationBeforeAdmissionDoesNotAskForProof() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset")
            self.seed(asset, in: queue)
            let resolver = ScriptedAlbumProofResolver()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await AlbumSyncRemoteProofLookup.remoteLinks(
                    for: ["asset"], catalog: ProofTestCatalog(assets: [asset]), queue: queue, resolver: resolver)
            }
            do {
                _ = try await task.value
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {}
            XCTAssertTrue(resolver.requests.isEmpty)
        }
    }

    func testCancellationAfterProofAndAfterUnavailableProofPropagates() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset")
            self.seed(asset, in: queue)
            for failure in [ScriptedAlbumProofResolver.Failure.cancelAfterProof, .cancelWithUnavailable] {
                let resolver = ScriptedAlbumProofResolver(failure: failure)
                let task = Task {
                    try await AlbumSyncRemoteProofLookup.remoteLinks(
                        for: ["asset"], catalog: ProofTestCatalog(assets: [asset]), queue: queue, resolver: resolver)
                }
                do {
                    _ = try await task.value
                    XCTFail("Cancellation must propagate")
                } catch is CancellationError {}
            }
        }
    }

    func testExecutorDoesNotHideAnUnavailableQueueStore() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "album-proof-blocker-\(UUID().uuidString)")
        try Data([0]).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: blocker, databasePolicy: .conservative,
            identityResolver: ScriptedAlbumProofResolver(), uploader: MockUploader())
        do {
            _ = try await executor.remoteProofLinks(for: ["asset"])
            XCTFail("The executor must report an unavailable queue store")
        } catch AlbumSyncError.mappingStoreUnavailable {}
    }

    func testProofRequestsStayBoundedAt128Candidates() async throws {
        try await withQueue { queue in
            let assets = (0..<257).map { self.candidate("asset-\($0)") }
            for asset in assets { self.seed(asset, in: queue) }
            let resolver = ScriptedAlbumProofResolver()
            let links = try await AlbumSyncRemoteProofLookup.remoteLinks(
                for: assets.map { $0.snapshot.source.identifier }, catalog: ProofTestCatalog(assets: assets),
                queue: queue, resolver: resolver)
            XCTAssertEqual(resolver.requests.map(\.count), [128, 128, 1])
            XCTAssertEqual(links.count, 257)
        }
    }

    func testCancellationDuringProofLookupDoesNotReturnAnAttachableLink() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset")
            self.seed(asset, in: queue)
            let resolver = ScriptedAlbumProofResolver(failure: .cancelled)
            do {
                _ = try await AlbumSyncRemoteProofLookup.remoteLinks(
                    for: ["asset"], catalog: ProofTestCatalog(assets: [asset]), queue: queue, resolver: resolver)
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {}
        }
    }

    func testTransportCancellationDuringProofLookupPropagates() async throws {
        try await withQueue { queue in
            let asset = self.candidate("asset")
            self.seed(asset, in: queue)
            for failure in [ScriptedAlbumProofResolver.Failure.urlCancelled, .typedCancelled, .transportCancelled] {
                do {
                    _ = try await AlbumSyncRemoteProofLookup.remoteLinks(
                        for: ["asset"], catalog: ProofTestCatalog(assets: [asset]), queue: queue,
                        resolver: ScriptedAlbumProofResolver(failure: failure))
                    XCTFail("transport cancellation cannot become an ordinary proof miss")
                } catch {
                    XCTAssertTrue(UploadError.isCancellation(error))
                    XCTAssertFalse(Task.isCancelled)
                }
            }
        }
    }

    func testUnavailableQueueFailsInsteadOfTreatingRowsAsMissing() async throws {
        try await withQueue { queue in
            queue.close()
            do {
                _ = try await AlbumSyncRemoteProofLookup.remoteLinks(
                    for: ["asset"], catalog: ProofTestCatalog(assets: [self.candidate("asset")]),
                    queue: queue, resolver: ScriptedAlbumProofResolver())
                XCTFail("A failed queue read must surface")
            } catch AlbumSyncError.mappingStoreUnavailable {}
        }
    }
}

private struct ProofTestCatalog: UploadBackupAssetCatalog {
    let assets: [UploadBackupAssetCandidate]
    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        AsyncThrowingStream { continuation in
            for asset in assets { continuation.yield(asset) }
            continuation.finish()
        }
    }
}

private final class ScriptedAlbumProofResolver: UploadIdentityResolving, @unchecked Sendable {
    enum Failure {
        case unavailable, cancelled, cancelAfterProof, cancelWithUnavailable, urlCancelled, typedCancelled,
            transportCancelled
    }
    private let lock = NSLock()
    private var recorded: [[UploadBackupExternalIdentity]] = []
    var requests: [[UploadBackupExternalIdentity]] { lock.withLock { recorded } }
    let override: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]?
    let failure: Failure?
    init(override: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]? = nil, failure: Failure? = nil) {
        self.override = override
        self.failure = failure
    }
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        lock.withLock { recorded.append(identities) }
        if failure == .cancelAfterProof || failure == .cancelWithUnavailable {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if failure == .cancelWithUnavailable { throw UploadError.backend("Proof unavailable during cancellation") }
        if failure == .cancelled { throw CancellationError() }
        if failure == .urlCancelled { throw URLError(.cancelled) }
        if failure == .typedCancelled { throw UploadError.cancelled }
        if failure == .transportCancelled { throw UploadError.transport(code: -999, message: "cancelled") }
        if failure == .unavailable { throw UploadError.backend("Proof unavailable") }
        if let override { return override }
        return Dictionary(
            uniqueKeysWithValues: identities.map {
                (
                    $0,
                    .init(
                        externalIdentity: $0, resourceCount: 1, remoteLinkIDs: ["main-\($0.identifier)"],
                        hashKeyEpoch: "epoch")
                )
            })
    }
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        XCTFail("Proof lookup must not resolve bytes")
        throw UploadError.backend("Unexpected byte resolution")
    }
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String
    ) async throws {
        XCTFail("Proof lookup must not write an identity")
        throw UploadError.backend("Unexpected identity write")
    }
}
