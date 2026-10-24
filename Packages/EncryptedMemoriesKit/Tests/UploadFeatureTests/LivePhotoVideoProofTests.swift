import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// A secondary resource (the video of a Live Photo) settles as already saved only through a file that belongs to
/// the Live Photo's main photo. A same-name or same-bytes main file of another photo proves nothing.
final class LivePhotoVideoProofPipelineTests: XCTestCase {
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

    private let videoPath = "/photos/IMG_1.MOV"

    private func video(
        mainLinkID: String = "live-main", replacesEarlierUpload: Bool = false
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: "/photos/IMG_1.HEIC"), resource: .livePairedVideo),
            fileURL: URL(fileURLWithPath: videoPath), filename: "IMG_1.MOV", fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000), mainRemoteLinkID: mainLinkID,
            requiresRelatedMatch: replacesEarlierUpload)
    }

    private func sha1Hex(seed: String) -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in seed.utf8.enumerated() { digest[i % 20] ^= byte }
        return UploadContentSHA1.hexString(digest: digest)
    }

    private var videoContentHash: String { "ch(\(sha1Hex(seed: videoPath)))" }

    private func activeRow(_ linkID: String, name: String = "IMG_1.MOV") -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(
            nameHash: "nh(\(name))", contentHash: videoContentHash, linkState: .active, linkID: linkID)
    }

    private func trashedRow(_ linkID: String) -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(
            nameHash: "nh(IMG_1.MOV)", contentHash: videoContentHash, linkState: .trashed, linkID: linkID)
    }

    private func foreignDraft() -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(
            nameHash: "nh(IMG_1.MOV)", contentHash: nil, linkState: .draft, linkID: "foreign-draft",
            clientUID: "another-installation")
    }

    // MARK: - Reproduction of issue 562: an unrelated main file settles the video

    func testAnUnrelatedMainFileWithTheSameNameAndBytesDoesNotSettleTheVideo() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "the video uploads under the Live Photo")
    }

    func testAnUnrelatedMainFileNextToAForeignDraftKeepsTheVideoBlocked() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video"), foreignDraft()]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: "foreign-draft"))
    }

    func testAnUnrelatedMainFileUnderAnotherNameDoesNotSettleTheVideo() async throws {
        checker.remoteItemsByContentHash[videoContentHash] = activeRow("other-name", name: "OTHER.MOV")
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "the video uploads under the Live Photo")
    }

    func testTheManifestRowOfAnUnrelatedMainFileDoesNotSettleTheVideo() async throws {
        hasher.contentSeeds[videoPath] = "shared-bytes"
        let sha1 = sha1Hex(seed: "shared-bytes")
        store.upsert(
            UploadIdentityRecord(
                source: .file(URL(fileURLWithPath: "/videos/clip.MOV"), resource: .primary),
                filename: "clip.MOV", correctedName: "clip.MOV", fileSize: 1000,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000), sha1Hex: sha1,
                nameHash: "nh(clip.MOV)", contentHash: "ch(\(sha1))", hashKeyEpoch: checker.epoch,
                remoteVolumeID: "vol", remoteLinkID: "standalone-video",
                outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: Date()))
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "an unrelated manifest row proves nothing")
    }

    func testTheExactLookupFallbackNeverSettlesTheVideoWithAnUnrelatedMainFile() async throws {
        checker.findError = UploadError.backend("duplicates endpoint down")
        checker.exactActiveDuplicates = [PhotoUID(volumeID: "vol", nodeID: "standalone-video")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        do {
            let result = try await pipeline.resolve(video())
            XCTFail("the unrelated main file settled the video: \(result.decision)")
        } catch {
            // The lookup failed and nothing related proves the video, so the item fails like any failed lookup.
            XCTAssertEqual(
                (error as? UploadError)?.localizedDescription,
                UploadError.backend("duplicates endpoint down").localizedDescription,
                "the original lookup error reaches the caller")
        }
    }

    func testAFailedRoleReadFailsClosedForACopyWithTheSameBytes() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video")]
        checker.linkVisibilityError = UploadError.backend("link roles unavailable")

        do {
            let result = try await pipeline.resolve(video())
            XCTFail("a failed read must not decide the video: \(result.decision)")
        } catch {
            XCTAssertEqual(
                (error as? UploadError)?.localizedDescription,
                UploadError.backend("link roles unavailable").localizedDescription, "the read error reaches the caller")
        }
        XCTAssertEqual(checker.linkVisibilityCallCount, 1)
        try await assertTheClaimsOfTheVideoAreReleased()
    }

    func testACopyThatTheRoleAnswerLeavesOutFailsTheCheck() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("own-video")]
        checker.linkVisibilityByID["own-video"] = .some(nil)

        do {
            let result = try await pipeline.resolve(video())
            XCTFail("an unanswered copy must not decide the video: \(result.decision)")
        } catch {}
        try await assertTheClaimsOfTheVideoAreReleased()
    }

    func testARoleAnswerWithoutThePhotoStateFailsTheCheck() async throws {
        // The answer names no main photo because the server left out the photo state, not because the copy is a
        // main photo of its own. The own copy must not count as unrelated.
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("own-video")]
        checker.linkVisibilityByID["own-video"] = RemoteLinkVisibility(
            isActive: true, mainPhotoLinkID: nil, hasExplicitPhotoState: false)

        do {
            let result = try await pipeline.resolve(video())
            XCTFail("an answer without the photo state must not decide the video: \(result.decision)")
        } catch {}
        try await assertTheClaimsOfTheVideoAreReleased()
    }

    func testAnActiveCopyWithoutALinkStaysAnInconsistentAnswer() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.MOV)", contentHash: videoContentHash, linkState: .active, linkID: nil)
        ]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.inconsistentRemoteState, remoteLinkID: nil))
    }

    /// A second check of the same bytes finishes: the failed check released its content and name claims.
    private func assertTheClaimsOfTheVideoAreReleased() async throws {
        checker.linkVisibilityError = nil
        checker.linkVisibilityByID = [:]
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = []
        await pipeline.invalidateCachedRemoteState()
        let finished = expectation(description: "a second check of the same bytes finishes")
        let pipeline = self.pipeline!
        let descriptor = video()
        Task {
            if (try? await pipeline.resolve(descriptor))?.decision == .upload { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 10)
    }

    func testTheVideoOfAnotherLivePhotoWithTheSameBytesDoesNotSettleTheVideo() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("other-live-video")]
        checker.relatedLinkIDsByMainLinkID["other-main"] = ["other-live-video"]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "a copy under another main photo proves nothing")
    }

    func testAVideoWhoseMainPhotoIsInTheTrashIsProvenByTheRoleOfItsCopy() async throws {
        // The server refuses the related list of a main photo in the trash. The copy still names its main photo.
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("old-video")]
        checker.relatedLinkIDsByMainLinkID["trashed-main"] = ["old-video"]
        checker.relatedLookupError = UploadError.backend("Related photos of the main photo are unavailable")

        let result = try await pipeline.resolve(video(mainLinkID: "trashed-main"))

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "old-video"))
        XCTAssertTrue(checker.relatedLookups.isEmpty, "no list of a main photo that may be in the trash")
    }

    // MARK: - The related lookup runs only when it can change the decision

    func testAnActiveFileWithTheSameNameAndOtherBytesAsksNoRelatedLookup() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.MOV)", contentHash: "ch(other-bytes)", linkState: .active, linkID: "other-video")
        ]
        checker.relatedLookupError = UploadError.backend("related photos unavailable")
        checker.linkVisibilityError = UploadError.backend("link roles unavailable")

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "a camera counter that repeats is another photo")
        XCTAssertTrue(checker.relatedLookups.isEmpty, "the answer could not change the decision")
        XCTAssertEqual(checker.linkVisibilityCallCount, 0, "the answer could not change the decision")
    }

    // MARK: - Controls that hold before and after the fix

    func testACopyUnderTheLivePhotosMainPhotoStillSettlesTheVideo() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("video-link")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = ["video-link"]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "video-link"))
    }

    func testATrashedFileOfAnotherPhotoIsNoDeletionOfTheVideo() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [trashedRow("trashed-video")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "the person did not delete this Live Photo")
    }

    func testATrashedCopyOfTheSameLivePhotoStaysTheDeletionByThePerson() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [trashedRow("own-trashed-video")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = ["own-trashed-video"]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "own-trashed-video"))
    }

    func testATrashedFileWithoutAStatedRoleKeepsItsEarlierMeaning() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [trashedRow("trashed-video")]
        checker.linkVisibilityByID["trashed-video"] = RemoteLinkVisibility(
            isActive: false, mainPhotoLinkID: nil, hasExplicitPhotoState: false)

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "trashed-video"))
    }

    func testATrashedFileWithoutAStatedRoleDoesNotHideTheOwnActiveCopy() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("own-video"), trashedRow("trashed-video")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = ["own-video"]
        checker.linkVisibilityByID["trashed-video"] = .some(nil)

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "own-video"))
    }

    func testTheTrashedVideoOfAnotherLivePhotoIsNoDeletionOfTheVideo() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [trashedRow("other-trashed-video")]
        checker.relatedLinkIDsByMainLinkID["other-main"] = ["other-trashed-video"]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload, "a trashed copy under another main photo says nothing about this one")
    }

    func testAnUnrelatedTrashedFileNextToAForeignDraftLetsTheDraftDecide() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [trashedRow("trashed-video"), foreignDraft()]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: "foreign-draft"))
    }

    func testALinkListedActiveAndTrashedNeedsAStatedRoleLikeAnActiveCopy() async throws {
        let rows = [activeRow("twin-video"), trashedRow("twin-video")]
        // Stated role under this Live Photo: the copy settles.
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = rows
        checker.relatedLinkIDsByMainLinkID["live-main"] = ["twin-video"]
        var result = try await pipeline.resolve(video())
        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "twin-video"))

        // Stated role under another photo: neither row decides.
        let other = UploadDedupePipeline(store: FakeIdentityStore(), hasher: hasher, checker: checker)
        checker.relatedLinkIDsByMainLinkID = ["other-main": ["twin-video"]]
        result = try await other.resolve(video())
        XCTAssertEqual(result.decision, .upload)
        await other.uploadDidFail(video())

        // Unstated role: the active row needs a role, so the check fails instead of keeping the trashed meaning.
        let unstated = UploadDedupePipeline(store: FakeIdentityStore(), hasher: hasher, checker: checker)
        checker.linkVisibilityByID["twin-video"] = RemoteLinkVisibility(
            isActive: true, mainPhotoLinkID: nil, hasExplicitPhotoState: false)
        do {
            let decision = try await unstated.resolve(video()).decision
            XCTFail("a link that a row lists as active needs a stated role: \(decision)")
        } catch {}
    }

    func testAFailedRoleReadForAnOnlyTrashedCopyFailsTheCheckAndReleasesIt() async throws {
        // A trashed copy now needs its role read. A failed read leaves the video for a later try, not a wrong skip.
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [trashedRow("trashed-video")]
        checker.linkVisibilityError = UploadError.backend("link roles unavailable")

        do {
            let result = try await pipeline.resolve(video())
            XCTFail("a failed read must not decide the video: \(result.decision)")
        } catch {
            XCTAssertEqual(
                (error as? UploadError)?.localizedDescription,
                UploadError.backend("link roles unavailable").localizedDescription)
        }
        try await assertTheClaimsOfTheVideoAreReleased()
    }

    func testATrashedCopyWithoutALinkKeepsItsMeaning() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.MOV)", contentHash: videoContentHash, linkState: .trashed, linkID: nil)
        ]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: nil))
    }

    func testUnrelatedActiveAndTrashedFilesLeaveTheVideoToUpload() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video"), trashedRow("trashed-video")]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload)
    }

    func testAMissingStateStaysUnknownWhenItsRoleCannotBeRead() async throws {
        // Missing State does not prove deletion, even when its role cannot be read.
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.MOV)", contentHash: videoContentHash, linkState: nil, linkID: "deleted-video")
        ]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.inconsistentRemoteState, remoteLinkID: "deleted-video"))
        XCTAssertEqual(checker.linkVisibilityCallCount, 0)
    }

    func testTheNameAndTheContentLookupReadTheRoleOfACopyOnce() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video")]
        checker.remoteItemsByContentHash[videoContentHash] = activeRow("standalone-video")
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(checker.linkVisibilityCallCount, 1, "the role of the copy is read once")
        XCTAssertTrue(checker.relatedLookups.isEmpty)
    }

    func testAVideoOfAReplacingEditReadsTheListOfItsMainPhotoOnce() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video")]
        checker.remoteItemsByContentHash[videoContentHash] = activeRow("elsewhere", name: "OTHER.MOV")
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video(replacesEarlierUpload: true))

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(checker.relatedLookups, ["live-main"], "the list of the new main photo is read once")
    }

    func testAnOwnInterruptedDraftNextToAnUnrelatedCopyIsReplaced() async throws {
        let pipeline = UploadDedupePipeline(
            store: store, hasher: hasher, checker: checker, currentClientUID: "this-installation")
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            activeRow("standalone-video"),
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.MOV)", contentHash: nil, linkState: .draft, linkID: "own-draft",
                clientUID: "this-installation"),
        ]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .uploadReplacingDraft)
    }

    func testEverySecondaryOfAMainPhotoNeedsACopyUnderThatMainPhoto() async throws {
        let resources: [UploadSourceIdentity.Resource] = [
            .livePairedVideo, .photoKit(role: "pairedVideo", ordinal: 0), .photoKit(role: "originalPhoto", ordinal: 0),
        ]
        for resource in resources {
            let store = FakeIdentityStore()
            let pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
            checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [activeRow("standalone-video")]
            checker.relatedLinkIDsByMainLinkID["live-main"] = []
            let secondary = UploadResourceDescriptor(
                source: .file(URL(fileURLWithPath: "/photos/IMG_1.HEIC"), resource: resource),
                fileURL: URL(fileURLWithPath: videoPath), filename: "IMG_1.MOV", fileSize: 1000,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000), mainRemoteLinkID: "live-main")

            let result = try await pipeline.resolve(secondary)

            XCTAssertEqual(result.decision, .upload, "\(resource)")
            await pipeline.uploadDidFail(secondary)
        }
    }

    func testAVideoOfAReplacingEditIgnoresItsTrashedCopyUnderTheEarlierPhoto() async throws {
        // The earlier copy moved to the trash with the earlier photo that the edit replaces. That is no deletion
        // by the person, so the video uploads under the edited photo.
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.MOV)", contentHash: videoContentHash, linkState: .trashed, linkID: "earlier-video")
        ]
        checker.relatedLinkIDsByMainLinkID["live-main"] = []

        let result = try await pipeline.resolve(video(replacesEarlierUpload: true))

        XCTAssertEqual(result.decision, .upload)
    }

    func testAForeignDraftAloneKeepsTheVideoBlocked() async throws {
        checker.remoteItemsByNameHash["nh(IMG_1.MOV)"] = [foreignDraft()]

        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: "foreign-draft"))
    }

    func testTheVideoUploadsWhenNothingWithItsNameOrBytesExists() async throws {
        let result = try await pipeline.resolve(video())

        XCTAssertEqual(result.decision, .upload)
    }

    func testAMainPhotoStillAdoptsAnActiveMainPhotoWithTheSameBytes() async throws {
        let photo = UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: "/photos/IMG_2.HEIC")),
            fileURL: URL(fileURLWithPath: "/photos/IMG_2.HEIC"), filename: "IMG_2.HEIC", fileSize: 1000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let contentHash = "ch(\(sha1Hex(seed: "/photos/IMG_2.HEIC")))"
        checker.remoteItemsByNameHash["nh(IMG_2.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_2.HEIC)", contentHash: contentHash, linkState: .active, linkID: "main-photo")
        ]

        let result = try await pipeline.resolve(photo)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "main-photo"))
    }
}

/// The same defect through the backup runner: the Live Photo counts as saved, but its video has no copy under
/// the Live Photo's main photo.
final class LivePhotoVideoProofRunnerTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var stateStore: UploadBackupStateManifestStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-photo-video-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        stateStore = try XCTUnwrap(
            UploadBackupStateManifestStore(url: tempDir.appendingPathComponent("backup-state.sqlite")))
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        stateStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func seedLivePhoto() -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/live.heic")),
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: "live.heic", byteCount: 4, state: .discovered, attempts: 0,
            updatedAt: clock.now.addingTimeInterval(-60))
        queueStore.upsert(entry)
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        return entry
    }

    private func makeRunner() -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore, preflight: preflight, resolver: resolver,
            identityResolver: UploadDedupePipeline(
                store: identityStore, hasher: hasher, checker: checker, now: { [clock] in clock!.now }),
            uploader: uploader,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: 180, uploadStallPollInterval: 5,
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
                throttle: BackupThrottlePolicy(baseConcurrency: 2)),
            throttleInputs: { .unconstrained }, clock: clock, now: { [clock] in clock!.now })
    }

    private func videoContentHash() -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in "/backup/live.heic#live.mov".utf8.enumerated() { digest[i % 20] ^= byte }
        return "ch(\(UploadContentSHA1.hexString(digest: digest)))"
    }

    private func unrelatedMainVideo() -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(
            nameHash: "nh(live.mov)", contentHash: videoContentHash(), linkState: .active,
            linkID: "standalone-video")
    }

    private func foreignDraft() -> RemotePhotoDuplicate {
        RemotePhotoDuplicate(
            nameHash: "nh(live.mov)", contentHash: nil, linkState: .draft, linkID: "foreign-draft",
            clientUID: "another-installation")
    }

    private func state(of entry: UploadBackupSyncQueueEntry) -> UploadBackupSyncQueueState? {
        queueStore.entry(for: entry.source, revision: entry.revision)?.state
    }

    func testAnUnrelatedMainFileDoesNotMakeTheLivePhotoCountAsSaved() async throws {
        let entry = seedLivePhoto()
        checker.remoteItemsByNameHash["nh(live.mov)"] = [unrelatedMainVideo()]
        checker.relatedLinkIDsByMainLinkID["node-live.heic"] = []

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["live.heic", "live.mov"],
            "state \(String(describing: state(of: entry))), backedUp \(progress.backedUp)")
        XCTAssertEqual(
            uploader.requests.last?.mainPhotoUID, testUID("live.heic"),
            "the video is attached to the Live Photo's own main photo")
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testAnUnrelatedMainFileNextToAForeignDraftKeepsTheLivePhotoBlocked() async throws {
        let entry = seedLivePhoto()
        checker.remoteItemsByNameHash["nh(live.mov)"] = [unrelatedMainVideo(), foreignDraft()]
        checker.relatedLinkIDsByMainLinkID["node-live.heic"] = []

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic"])
    }

    func testTheVideoUploadsAndTheLivePhotoCompletesWhenNothingWithItsNameExists() async throws {
        let entry = seedLivePhoto()

        _ = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic", "live.mov"])
    }
}
