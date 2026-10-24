import AlbumSyncCore
import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend

/// Album Sync asks the account's content index for other copies of a photo. Only active copies count; a draft, a
/// trashed copy or a row without a link never stands in for an album member.
@Suite struct AlbumSyncSameContentLookupTests {
    @Test func onlyActiveCopiesWithALinkCount() async throws {
        let checker = SameContentChecker(rows: [
            "content-shared": [
                .init(nameHash: "n", contentHash: "content-shared", linkState: .active, linkID: "copy-a"),
                .init(nameHash: "n", contentHash: "content-shared", linkState: .draft, linkID: "draft"),
                .init(nameHash: "n", contentHash: "content-shared", linkState: .trashed, linkID: "trashed"),
                .init(nameHash: "n", contentHash: "content-shared", linkState: nil, linkID: "deleted"),
                .init(nameHash: "n", contentHash: "content-shared", linkState: .active, linkID: ""),
                .init(nameHash: "n", contentHash: "content-shared", linkState: .active, linkID: nil),
            ],
            "content-draft-only": [
                .init(nameHash: "n", contentHash: "content-draft-only", linkState: .draft, linkID: "draft")
            ],
        ])
        let ops = makeOps(checker: checker)

        let copies = try await ops.activeMainLinkIDs(withSameContentAs: ["shared", "draft-only", "unknown"])

        #expect(copies == ["shared": ["copy-a"]])
        #expect(checker.limits == Array(repeating: ProtonAlbumSyncRemoteOps.sameContentLimit, count: 3))
    }

    @Test func completeMetadataAbsenceDoesNotUseTheActiveIndexToInferDeletion() async throws {
        let checker = SameContentChecker(rows: [:])
        let ops = makeOps(checker: checker)
        let link = AlbumSyncRemoteLink(
            uid: PhotoUID(volumeID: "vol", nodeID: "unknown"), sha1Hex: "shared", isTrashed: false)
        #expect(try await ops.remoteDeletionStates(for: [link]).isEmpty)
        #expect(checker.limits.isEmpty, "an active-only index miss cannot prove permanent deletion")
    }

    @Test func withoutAContentIndexNoCopyIsKnown() async throws {
        let copies = try await makeOps(checker: nil).activeMainLinkIDs(withSameContentAs: ["shared"])
        #expect(copies.isEmpty)
    }

    private func makeOps(checker: (any UploadDuplicateChecking)?) -> ProtonAlbumSyncRemoteOps {
        let session = DriveSession(
            session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
            store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
            accountCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("album-same-content-\(UUID().uuidString)"))
        let service = ProtonAlbumWriteService(session: session, crypto: DriveCrypto(addressKeys: [], signers: [])) {
            PhotosShareContext(volumeID: "vol1", shareID: "share1", rootLinkID: "root1")
        }
        return ProtonAlbumSyncRemoteOps(service: service, listProvider: { [] }, duplicateChecker: checker)
    }
}

/// Content hashes are `content-<sha1>`; each content lookup returns its configured rows.
private final class SameContentChecker: UploadDuplicateChecking, @unchecked Sendable {
    private let rows: [String: [RemotePhotoDuplicate]]
    private let lock = NSLock()
    private var recordedLimits: [Int] = []
    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        .init(states: [:], complete: true)
    }
    var limits: [Int] { lock.withLock { recordedLimits } }

    init(rows: [String: [RemotePhotoDuplicate]]) { self.rows = rows }

    func hashKeyEpoch() async throws -> String { "epoch" }
    func nameHash(forCorrectedName name: String) async throws -> String { "name" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "content-\(sha1Hex)" }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] { [] }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? { rows[contentHash]?.first }
    func findDuplicates(contentHash: String, limit: Int) async throws -> [RemotePhotoDuplicate] {
        lock.withLock { recordedLimits.append(limit) }
        return Array((rows[contentHash] ?? []).prefix(limit))
    }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] { [:] }
}
