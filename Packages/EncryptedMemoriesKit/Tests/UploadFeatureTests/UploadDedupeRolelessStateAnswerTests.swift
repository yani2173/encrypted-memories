import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Issue 876: a state answer that carries a link and an active State but no photo role data must
/// not prove that a root photo is already backed up. These tests drive the public `resolve` surface
/// with role-less visibility answers and require an upload. The fakes come from
/// `UploadDedupePipelineTests.swift`; this file adds only the strict-rule cases so it stays separate
/// from the pipeline test suite.
final class UploadDedupeRolelessStateAnswerTests: XCTestCase {
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
        path: String = "/photos/IMG_1.HEIC"
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: path)),
            fileURL: URL(fileURLWithPath: path),
            filename: (path as NSString).lastPathComponent,
            fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            precomputedSHA1Digest: nil
        )
    }

    /// The sha1 hex FakeHasher yields for a given content seed.
    private func fakeSHA1Hex(seed: String) -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in seed.utf8.enumerated() { digest[i % 20] ^= byte }
        return UploadContentSHA1.hexString(digest: digest)
    }

    /// A state answer with a link and an active State but no photo role data, like the answers
    /// described in issue 876.
    private var rolelessActiveAnswer: RemoteLinkVisibility {
        RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil, hasExplicitPhotoState: false)
    }

    func testARootUploadsWhenTheNameMatchAnswersWithoutRoleData() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash, linkState: .active, linkID: "match-link")
        ]
        checker.linkVisibilityByID["match-link"] = rolelessActiveAnswer

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(
            result.decision, .upload,
            "an active state answer without photo role data does not prove a main photo")
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        await pipeline.uploadDidFail(d)
    }

    func testARootUploadsWhenTheContentIndexAnswersWithoutRoleData() async throws {
        let d = descriptor()
        let contentHash = "ch(\(fakeSHA1Hex(seed: d.fileURL.path)))"
        checker.remoteItemsByContentHash[contentHash] = RemotePhotoDuplicate(
            nameHash: "", contentHash: contentHash, linkState: .active, linkID: "index-link")
        checker.linkVisibilityByID["index-link"] = rolelessActiveAnswer

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(
            result.decision, .upload,
            "an active state answer without photo role data does not prove a main photo")
        XCTAssertEqual(checker.contentFindCallCount, 1)
        await pipeline.uploadDidFail(d)
    }

    func testAFailingDetailedLookupDoesNotAdoptARoleLessExactSDKMatchForARoot() async throws {
        let d = descriptor()
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "sdk-link")]
        checker.linkVisibilityByID["sdk-link"] = rolelessActiveAnswer

        do {
            let result = try await pipeline.resolve(d)
            XCTFail("expected the detailed lookup error, got \(result.decision)")
        } catch let error as UploadError {
            XCTAssertEqual(error, .backend("duplicates endpoint down"))
        }
        XCTAssertEqual(checker.exactFindCallCount, 1)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        XCTAssertNil(store.record(for: d.source)?.outcome, "a role-less answer must not persist a duplicate row")
    }

    func testAFailingDetailedLookupDoesNotAdoptAnAbsentExactSDKMatchStateAnswerForARoot() async throws {
        let d = descriptor()
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "sdk-link")]

        do {
            let result = try await pipeline.resolve(d)
            XCTFail("expected the detailed lookup error, got \(result.decision)")
        } catch let error as UploadError {
            XCTAssertEqual(error, .backend("duplicates endpoint down"))
        }
        XCTAssertEqual(checker.exactFindCallCount, 1)
        XCTAssertNil(store.record(for: d.source)?.outcome, "an absent state answer must not persist a duplicate row")
    }

    func testARootUploadsWhenAManifestRowAnswersWithoutRoleData() async throws {
        hasher.contentSeeds["/photos/IMG_1.HEIC"] = "shared-bytes"
        hasher.contentSeeds["/photos/IMG_2.HEIC"] = "shared-bytes"
        let contentHash = "ch(\(fakeSHA1Hex(seed: "shared-bytes")))"

        let first = descriptor(path: "/photos/IMG_1.HEIC")
        let uploaded = try await pipeline.resolve(first)
        XCTAssertEqual(uploaded.decision, .upload)
        try await pipeline.recordUploaded(
            first, identity: uploaded.identity, remoteVolumeID: "vol", remoteLinkID: "manifest-link")

        // The state answer of the next check carries no photo role data, so the stored row proves
        // nothing about a main photo.
        checker.linkVisibilityByID["manifest-link"] = rolelessActiveAnswer
        let renamed = descriptor(path: "/photos/IMG_2.HEIC")
        let result = try await pipeline.resolve(renamed)

        XCTAssertEqual(
            result.decision, .upload,
            "an active state answer without photo role data does not prove a main photo")
        await pipeline.uploadDidFail(renamed)
    }

    // MARK: Issue 1062 - the two remaining role-less paths

    private func nonRootDescriptor() -> UploadResourceDescriptor {
        // A secondary of a main photo that does not pin a main link and does not require a related
        // match: not a root (`isRoot` needs `.primary`), but it still reaches the exact-match
        // fallback after a failed detailed name lookup.
        UploadResourceDescriptor(
            source: .file(
                URL(fileURLWithPath: "/photos/IMG_1.HEIC"), resource: .livePairedVideo),
            fileURL: URL(fileURLWithPath: "/photos/IMG_1.HEIC#IMG_1.MOV"),
            filename: "IMG_1.MOV",
            fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            precomputedSHA1Digest: nil
        )
    }

    func testAFailingDetailedLookupDoesNotAdoptAnInactiveExactSDKMatchForANonRoot() async throws {
        let d = nonRootDescriptor()
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "sdk-link")]
        // A non-root's legitimate copy is a related file, so a state answer needs no role data for it
        // (see `countsAsBackup`). An inactive copy is what must not authorize a skip.
        checker.linkVisibilityByID["sdk-link"] = RemoteLinkVisibility(
            isActive: false, mainPhotoLinkID: nil, hasExplicitPhotoState: false)

        do {
            let result = try await pipeline.resolve(d)
            XCTFail("expected the detailed lookup error, got \(result.decision)")
        } catch let error as UploadError {
            XCTAssertEqual(error, .backend("duplicates endpoint down"))
        }
        XCTAssertEqual(checker.exactFindCallCount, 1)
        XCTAssertEqual(
            checker.linkVisibilityCallCount, 1,
            "the fallback must read state before skipping on an SDK match")
        XCTAssertNil(
            store.record(for: d.source)?.outcome,
            "an inactive match must not persist a duplicate row")
    }

    func testAFailingDetailedLookupSkipsANonRootOnAProvenActiveExactSDKMatch() async throws {
        let d = nonRootDescriptor()
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "sdk-link")]
        checker.linkVisibilityByID["sdk-link"] = rolelessActiveAnswer

        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "sdk-link"))
        XCTAssertEqual(
            checker.linkVisibilityCallCount, 1,
            "the fallback proves the copy with a state read before it skips")
    }

    func testRevalidationDoesNotAdoptARoleLessExactSDKMatch() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        XCTAssertEqual(first.decision, .upload)
        try await pipeline.recordUploaded(
            d, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "uploaded-link")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "uploaded-link")]
        checker.linkVisibilityByID["uploaded-link"] = rolelessActiveAnswer
        // The recorded upload would give the fall-through content index an active row of the same
        // content. Remove it, so the SDK exact match is the only duplicate evidence in this check.
        checker.remoteItemsByContentHash[first.identity.contentHash] = nil
        let nameBatchesBeforeFallThrough = checker.findCallCount

        let decision = try await pipeline.revalidateKnownRemote(d)

        XCTAssertEqual(
            decision, nil,
            "an exact SDK match whose state answer carries no photo role data does not prove an active duplicate")
        XCTAssertEqual(checker.linkVisibilityCallCount, 1, "revalidation must read state before adopting an SDK match")
        XCTAssertEqual(
            checker.findCallCount, nameBatchesBeforeFallThrough + 1,
            "when unproven, revalidation falls through to the name/content evidence chain")
    }

    func testRevalidationFallsThroughToATrashedKnownLinkWhenTheSDKMatchIsUnproven() async throws {
        let d = descriptor()
        let first = try await pipeline.resolve(d)
        XCTAssertEqual(first.decision, .upload)
        try await pipeline.recordUploaded(
            d, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: "uploaded-link")
        // Unproven exact SDK match X ≠ knownLinkID; known-link state is trashed
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "sdk-link")]
        checker.linkVisibilityByID["sdk-link"] = rolelessActiveAnswer
        // The recorded upload would give the fall-through content index an active row of the same
        // content. Remove it, so the deletion evidence is the only remaining evidence in this check.
        checker.remoteItemsByContentHash[first.identity.contentHash] = nil
        checker.deletionMetadata = .init(states: ["uploaded-link": 2], complete: true)

        let decision = try await pipeline.revalidateKnownRemote(d)

        XCTAssertEqual(
            decision, .skip(.trashedDuplicate, remoteLinkID: "uploaded-link"),
            "when the SDK match is unproven, revalidation continues to the deletion-evidence chain")
        XCTAssertEqual(
            checker.linkVisibilityCallCount, 1, "revalidation must read state before falling through")
    }
}
