import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class UploadDraftContentLookupTests: XCTestCase {
    func testForeignNameDraftDoesNotHideAnActiveCopyUnderAnotherName() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let active = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
        let draft = harness.server.seedDraft(
            name: "IMG_1.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("different-photo".utf8))),
            clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(before.map(\.linkID), [draft.nodeID])
        XCTAssertEqual(before.first?.linkState, .draft)
        XCTAssertNotEqual(before.first?.contentHash, harness.server.links.first { $0.uid == active }?.contentHash)
        let entry = try await harness.enqueue()

        await harness.pass()

        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(after, before, "The foreign draft must survive unchanged")
        XCTAssertEqual(harness.server.links.count, 2)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        XCTAssertFalse(harness.server.steps.contains { $0.action.hasPrefix("upload ") })

        try harness.relaunch()
        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
    }

    func testForeignAndUnknownDraftsRemainBlockedWithoutAnActiveCopy() async throws {
        for owner in ["other-uploader", nil] {
            let server = EditScenarioServer()
            let (pipeline, descriptor, draft) = fixture(server: server, owner: owner)
            let result = try await pipeline.resolve(descriptor)
            XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
            XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
            XCTAssertEqual(server.uploadRequestCount, 0)
        }
    }

    func testRelatedActiveContentDoesNotSettleARootBlockedByDraft() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let main = server.seedLink(digest: Data(repeating: 2, count: 20))
        _ = server.seedLink(digest: descriptor.precomputedSHA1Digest!, main: main)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testFailedVisibilityDoesNotAdoptARelatedFileBehindAForeignDraft() async throws {
        try await assertUnprovenRoleKeepsDraftBlock(visibilityFails: true)
    }

    func testMissingVisibilityDoesNotAdoptARelatedFileBehindAForeignDraft() async throws {
        try await assertUnprovenRoleKeepsDraftBlock(visibilityFails: false)
    }

    private func assertUnprovenRoleKeepsDraftBlock(visibilityFails: Bool) async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let main = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        let related = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)), main: main)
        let draft = harness.server.seedDraft(
            name: "IMG_1.HEIC", digest: Data(repeating: 3, count: 20), clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        harness.server.configureOptionalReads(visibilityFails: visibilityFails)
        if !visibilityFails { harness.server.omitVisibility(of: [related.nodeID]) }
        let entry = try await harness.enqueue()

        await harness.pass()

        XCTAssertEqual(harness.state(of: entry), .blockedByDraft)
        XCTAssertNil(harness.identities.record(for: entry.source)?.remoteLinkID)
        XCTAssertNil(harness.identities.record(for: entry.source)?.outcome)
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(after, before)
        XCTAssertEqual(harness.server.links.first { $0.uid == draft }?.state, .draft)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        try harness.relaunch()
        XCTAssertEqual(harness.state(of: entry), .blockedByDraft)
        XCTAssertNil(harness.identities.record(for: entry.source)?.remoteLinkID)
        XCTAssertNil(harness.identities.record(for: entry.source)?.outcome)
    }

    func testInactiveContentFromAStaleIndexDoesNotReplaceTheDraftBlock() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let old = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        server.personTrash(old)
        server.returnInactiveContentFromStaleIndex()

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == old }?.state, .trashed)
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testCancelledContentLookupReleasesClaimsAndStartsNoUpload() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        server.setContentLookupError(CancellationError())
        do {
            _ = try await pipeline.resolve(descriptor)
            XCTFail("A cancelled content lookup must not settle the photo")
        } catch is CancellationError {
        }
        server.setContentLookupError(nil)
        let active = server.seedLink(digest: descriptor.precomputedSHA1Digest!)

        let retried = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)

        XCTAssertEqual(retried.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
        XCTAssertEqual(server.uploadRequestCount, 0)
    }

    func testAdoptedLivePrimaryUploadsOnlyItsMissingVideoAndKeepsTheForeignDraft() async throws {
        let harness = try EditScenarioHarness(live: true)
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let active = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
        let draft = harness.server.seedDraft(
            name: "IMG_1.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("different-photo".utf8))),
            clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(before.map(\.linkID), [draft.nodeID])
        XCTAssertTrue(harness.server.links.filter { $0.mainLinkID == active.nodeID }.isEmpty)
        let entry = try await harness.enqueue()

        await harness.pass()

        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(after, before, "The foreign draft must survive unchanged")
        XCTAssertEqual(harness.server.uploadRequestCount, 1)
        let uploaded = harness.server.links.filter { $0.uid != active && $0.uid != draft }
        XCTAssertEqual(uploaded.count, 1)
        let video = try XCTUnwrap(uploaded.first)
        XCTAssertEqual(video.mainLinkID, active.nodeID)
        XCTAssertEqual(video.nameHash, "nh(IMG_1.MOV)")
        XCTAssertEqual(video.state, .active)
        XCTAssertEqual(
            video.contentHash,
            EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: try XCTUnwrap(asset.pairedVideo)))))
        let secondarySource = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: asset.identifier, resource: .livePairedVideo)
        XCTAssertEqual(harness.identities.record(for: secondarySource)?.remoteLinkID, video.linkID)
        XCTAssertEqual(harness.identities.record(for: secondarySource)?.outcome, "uploaded")

        try harness.relaunch()
        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
        XCTAssertEqual(harness.identities.record(for: secondarySource)?.remoteLinkID, video.linkID)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.server.uploadRequestCount, 1)
    }

    func testBlockedResolveKeepsExistingRestoredVersionJournalUpdates() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let source = try XCTUnwrap(harness.library.snapshot.first).source
        let descriptor = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"), filename: "current.heic",
            fileSize: 20, modificationDate: harness.clock.now, precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let restored = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        try harness.journal.addSuperseded(restored, for: source)
        try harness.journal.settle([restored.nodeID], related: [], trashed: true, for: source)
        try harness.journal.keepDeleted(for: source)
        XCTAssertEqual(harness.journal.entry(for: source).retired, [restored.nodeID])
        XCTAssertEqual(harness.journal.entry(for: source).keptDeleted, true)
        let draft = harness.server.seedDraft(
            name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(current.heic)"])
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), checker: harness.server, currentClientUID: "this-uploader",
            replacementJournal: harness.journal)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        let journal = harness.journal.entry(for: source)
        XCTAssertNil(journal.keptDeleted)
        XCTAssertTrue(journal.retired.isEmpty)
        XCTAssertEqual(journal.superseded, [PhotoUID(volumeID: "", nodeID: restored.nodeID)])
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(current.heic)"])
        XCTAssertEqual(after, before)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        try harness.relaunch()
        XCTAssertEqual(harness.journal.entry(for: source), journal)
    }

    func testBlockedContentAdoptionKeepsRestoredVersionJournalUpdates() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let source = try XCTUnwrap(harness.library.snapshot.first).source
        let descriptor = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"), filename: "current.heic",
            fileSize: 20, modificationDate: harness.clock.now, precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let restored = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        try harness.journal.addSuperseded(restored, for: source)
        try harness.journal.settle([restored.nodeID], related: [], trashed: true, for: source)
        try harness.journal.keepDeleted(for: source)
        let active = harness.server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let draft = harness.server.seedDraft(
            name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(current.heic)"])
        let pipeline = UploadDedupePipeline(
            store: harness.identities, checker: harness.server, currentClientUID: "this-uploader",
            replacementJournal: harness.journal)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, active.nodeID)
        let journal = harness.journal.entry(for: source)
        XCTAssertNil(journal.keptDeleted)
        XCTAssertTrue(journal.retired.isEmpty)
        XCTAssertEqual(journal.superseded, [PhotoUID(volumeID: "", nodeID: restored.nodeID)])
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(current.heic)"])
        XCTAssertEqual(after, before)
        XCTAssertEqual(harness.server.links.first { $0.uid == draft }?.state, .draft)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        try harness.relaunch()
        XCTAssertEqual(harness.journal.entry(for: source), journal)
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, active.nodeID)
    }

    func testActiveIndexRowWithTrashedVisibilityKeepsTheDraftBlock() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let old = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let row = try XCTUnwrap(server.links.first { $0.uid == old }).duplicate
        server.personTrash(old)
        server.setContentLookupRows([row])

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(row.linkState, .active)
        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == old }?.state, .trashed)
    }

    func testContentBatchSkipsRelatedFileAndAdoptsTheFollowingMain() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let other = server.seedLink(digest: Data(repeating: 2, count: 20))
        let related = server.seedLink(digest: descriptor.precomputedSHA1Digest!, main: other)
        let active = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let rows = [related, active].map { uid in server.links.first { $0.uid == uid }!.duplicate }
        server.setContentLookupRows(rows)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
        XCTAssertEqual(server.contentLookupCount, 1)
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testForeignDraftForLiveVideoDoesNotAdoptAnUnrelatedMain() async throws {
        let server = EditScenarioServer()
        let url = URL(fileURLWithPath: "/fixture/current.mov")
        let main = server.seedLink(digest: Data(repeating: 2, count: 20))
        let descriptor = UploadResourceDescriptor(
            source: .file(url, resource: .livePairedVideo), fileURL: url, filename: "current.mov", fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
            precomputedSHA1Digest: Data(repeating: 1, count: 20), mainRemoteLinkID: main.nodeID)
        let draft = server.seedDraft(
            name: descriptor.filename, digest: Data(repeating: 3, count: 20),
            clientUID: "other-uploader")
        _ = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), checker: server, currentClientUID: "this-uploader")

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertEqual(server.contentLookupCount, 0)
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testBurstAndRelatedMatchDraftsDoNotQueryContent() async throws {
        for (resource, requiresRelated) in [
            (UploadSourceIdentity.Resource.burstMember(ordinal: 0), false),
            (.livePairedVideo, true),
        ] {
            let server = EditScenarioServer()
            let url = URL(fileURLWithPath: "/fixture/secondary.heic")
            let main = server.seedLink(digest: Data(repeating: 2, count: 20))
            let descriptor = UploadResourceDescriptor(
                source: .file(url, resource: resource), fileURL: url, filename: "secondary.heic", fileSize: 20,
                modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
                precomputedSHA1Digest: Data(repeating: 1, count: 20), mainRemoteLinkID: main.nodeID,
                requiresRelatedMatch: requiresRelated)
            let draft = server.seedDraft(
                name: descriptor.filename, digest: Data(repeating: 3, count: 20),
                clientUID: "other-uploader")
            _ = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
            let pipeline = UploadDedupePipeline(
                store: FakeIdentityStore(), checker: server, currentClientUID: "this-uploader")

            let result = try await pipeline.resolve(descriptor)

            XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
            XCTAssertEqual(server.contentLookupCount, 0)
        }
    }

    func testContentIndexFailureKeepsTheDraftDecision() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        server.setContentLookupError(UploadError.backend("The content index is unavailable"))
        do {
            let result = try await pipeline.resolve(descriptor)
            XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        } catch {
            XCTFail("An optional content lookup must keep the draft decision: \(error)")
        }
        server.setContentLookupError(nil)
        let result = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)
        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
    }

    func testContentIndexFailureStillThrowsWithoutADraftBlock() async throws {
        try await assertNormalContentFailure(cancelledTask: false)
    }

    func testCancelledNormalLookupKeepsTheExistingBackendFailure() async throws {
        try await assertNormalContentFailure(cancelledTask: true)
    }

    private func assertNormalContentFailure(cancelledTask: Bool) async throws {
        let server = EditScenarioServer()
        let (_, descriptor, _) = fixture(server: server)
        let normal = EditScenarioServer()
        normal.setContentLookupError(UploadError.backend("The content index is unavailable"))
        normal.cancelCallerAtContentLookup(cancelledTask)
        let pipeline = UploadDedupePipeline(store: FakeIdentityStore(), checker: normal)
        let task = Task { try await pipeline.resolve(descriptor) }
        do {
            _ = try await task.value
            XCTFail("The normal content lookup must still throw")
        } catch is CancellationError {
            XCTFail("Expected the backend failure, not cancellation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("content index"))
        }
    }

    func testScopedContentVisibilityFailureKeepsTheDraftAndNamePassJournal() async throws {
        try await assertScopedContentFailure(cancelled: false)
    }

    func testScopedContentVisibilityCancellationPropagatesAndReleasesClaims() async throws {
        try await assertScopedContentFailure(cancelled: true)
    }

    private func assertScopedContentFailure(cancelled: Bool) async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let source = try XCTUnwrap(harness.library.snapshot.first).source
        let descriptor = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"), filename: "current.heic",
            fileSize: 20, modificationDate: harness.clock.now, precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let restored = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        try harness.journal.addSuperseded(restored, for: source)
        try harness.journal.settle([restored.nodeID], related: [], trashed: true, for: source)
        try harness.journal.keepDeleted(for: source)
        let active = harness.server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let draft = harness.server.seedDraft(
            name: descriptor.filename, digest: Data(repeating: 3, count: 20),
            clientUID: "other-uploader")
        let failure: any Error = cancelled ? CancellationError() : UploadError.backend("Content visibility failed")
        harness.server.setVisibilityError(failure, whenAskingFor: active.nodeID)
        let pipeline = UploadDedupePipeline(
            store: harness.identities, checker: harness.server, currentClientUID: "this-uploader",
            replacementJournal: harness.journal)
        do {
            let result = try await pipeline.resolve(descriptor)
            XCTAssertFalse(cancelled, "Cancellation must propagate")
            XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        } catch is CancellationError {
            XCTAssertTrue(cancelled)
        } catch {
            XCTFail("A failed content visibility read must retain the draft decision: \(error)")
        }
        let journal = harness.journal.entry(for: source)
        XCTAssertNil(journal.keptDeleted)
        XCTAssertTrue(journal.retired.isEmpty)
        XCTAssertEqual(journal.superseded, [PhotoUID(volumeID: "", nodeID: restored.nodeID)])
        XCTAssertNil(harness.identities.record(for: source)?.remoteLinkID)
        XCTAssertNil(harness.identities.record(for: source)?.outcome)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        XCTAssertEqual(harness.server.links.first { $0.uid == draft }?.state, .draft)
        harness.server.setVisibilityError(nil, whenAskingFor: active.nodeID)
        let retried = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)
        XCTAssertEqual(retried.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
    }

    func testDifferentContentHashCannotSettleAScopedDraft() async throws {
        try await assertMalformedContentKeepsScopedDraft(emptyLink: false)
    }

    func testEmptyContentLinkCannotSettleAScopedDraft() async throws {
        try await assertMalformedContentKeepsScopedDraft(emptyLink: true)
    }

    private func assertMalformedContentKeepsScopedDraft(emptyLink: Bool) async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let source = try XCTUnwrap(harness.library.snapshot.first).source
        let descriptor = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"), filename: "current.heic",
            fileSize: 20, modificationDate: harness.clock.now, precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let current = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        try harness.journal.addSuperseded(current, for: source)
        let unrelated = harness.server.seedLink(digest: Data(repeating: 3, count: 20))
        let draft = harness.server.seedDraft(
            name: descriptor.filename, digest: Data(repeating: 4, count: 20), clientUID: "other-uploader")
        let hash = EditScenarioServer.contentHash(descriptor.precomputedSHA1Digest!)
        let row = RemotePhotoDuplicate(
            nameHash: "another-name", contentHash: emptyLink ? hash : "different-content", linkState: .active,
            linkID: emptyLink ? "" : unrelated.nodeID)
        harness.server.setContentLookupRows([row])
        if emptyLink { harness.server.setVisibility(.init(isActive: true, mainPhotoLinkID: nil), for: "") }
        let pipeline = UploadDedupePipeline(
            store: harness.identities, checker: harness.server, currentClientUID: "this-uploader",
            replacementJournal: harness.journal)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertNil(harness.identities.record(for: source)?.remoteLinkID)
        XCTAssertNil(harness.identities.record(for: source)?.outcome)
        XCTAssertEqual(harness.server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testCancelledTaskWithContentBackendFailureStillPropagatesCancellation() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        server.cancelCallerAtContentLookup(true)
        server.setContentLookupError(UploadError.backend("Content lookup failed after cancellation"))
        let task = Task { try await pipeline.resolve(descriptor) }
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not settle the draft")
        } catch is CancellationError {
        } catch {
            XCTFail("The cancellation must propagate instead of a backend failure: \(error)")
        }
        server.cancelCallerAtContentLookup(false)
        server.setContentLookupError(nil)
        let result = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)
        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
    }

    func testTypedContentCancellationStillThrowsWithoutCancellingTheCallerTask() async throws {
        let errors: [any Error] = [UploadError.cancelled, URLError(.cancelled)]
        for error in errors {
            let server = EditScenarioServer()
            let (pipeline, descriptor, draft) = fixture(server: server)
            server.setContentLookupError(error)
            do {
                _ = try await pipeline.resolve(descriptor)
                XCTFail("A typed cancellation must not settle the draft")
            } catch {
                XCTAssertTrue((error as? UploadError) == .cancelled || (error as? URLError)?.code == .cancelled)
            }
            server.setContentLookupError(nil)
            let result = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)
            XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        }
    }

    func testTypedVisibilityCancellationPropagatesBehindADraft() async throws {
        let errors: [any Error] = [UploadError.cancelled, URLError(.cancelled)]
        for error in errors {
            let server = EditScenarioServer()
            let (pipeline, descriptor, draft) = fixture(server: server)
            let active = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
            server.setVisibilityError(error, whenAskingFor: active.nodeID)
            do {
                _ = try await pipeline.resolve(descriptor)
                XCTFail("A typed visibility cancellation must escape the optional content pass")
            } catch {
                XCTAssertTrue((error as? UploadError) == .cancelled || (error as? URLError)?.code == .cancelled)
            }
            let record = await pipeline.identityRecord(for: descriptor.source)
            XCTAssertNil(record?.remoteLinkID)
            XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
            server.setVisibilityError(nil, whenAskingFor: active.nodeID)
            await pipeline.invalidateCachedRemoteState()
            let retried = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)
            XCTAssertEqual(retried.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
        }
    }

    func testCancelledCallerWithVisibilityFailurePropagatesBehindADraft() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let active = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        server.cancelCallerAtContentLookup(true)
        server.setVisibilityError(UploadError.backend("Visibility failed after Stop"), whenAskingFor: active.nodeID)
        let task = Task { try await pipeline.resolve(descriptor) }
        do {
            _ = try await task.value
            XCTFail("Stop must propagate out of the optional visibility pass")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected task cancellation instead of a visibility error: \(error)")
        }
        let record = await pipeline.identityRecord(for: descriptor.source)
        XCTAssertNil(record?.remoteLinkID)
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
        server.cancelCallerAtContentLookup(false)
        server.setVisibilityError(nil, whenAskingFor: active.nodeID)
        await pipeline.invalidateCachedRemoteState()
        let retried = try await resolveBeforeTimeout(pipeline, descriptor: descriptor)
        XCTAssertEqual(retried.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
    }

    func testFirstBatchVisibilityFailureKeepsTheDraftInsteadOfAdoptingTheSecondBatch() async throws {
        try await assertBatchedVisibilityFailure(blocked: true)
    }

    func testNormalContentPassKeepsItsFailOpenVisibilityBehaviorAcrossBatches() async throws {
        try await assertBatchedVisibilityFailure(blocked: false)
    }

    private func assertBatchedVisibilityFailure(blocked: Bool) async throws {
        let server = EditScenarioServer()
        let (_, descriptor, _) = fixture(server: EditScenarioServer())
        let store = FakeIdentityStore()
        let pipeline = UploadDedupePipeline(store: store, checker: server, currentClientUID: "this-uploader")
        let draft =
            blocked
            ? server.seedDraft(
                name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: "other-uploader")
            : nil
        let other = server.seedLink(digest: Data(repeating: 2, count: 20))
        let related = (0..<8).map { _ in server.seedLink(digest: descriptor.precomputedSHA1Digest!, main: other) }
        let active = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let rows = (related + [active]).map { uid in server.links.first { $0.uid == uid }!.duplicate }
        server.setContentLookupRows(rows)
        server.setVisibilityError(
            UploadError.backend("First batch visibility failed"), whenAskingFor: related[0].nodeID)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(
            result.decision,
            blocked
                ? .skip(.draftExists, remoteLinkID: draft?.nodeID)
                : .skip(.activeDuplicate, remoteLinkID: related[0].nodeID))
        XCTAssertEqual(store.record(for: descriptor.source)?.remoteLinkID, blocked ? nil : related[0].nodeID)
        XCTAssertEqual(store.record(for: descriptor.source)?.outcome, blocked ? nil : "duplicateActive")
        XCTAssertEqual(server.contentLookupCount, 1)
        XCTAssertEqual(server.uploadRequestCount, 0)
        if let draft { XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft) }
    }

    func testBlockedContentDoesNotRestoreJournalLinksWithoutExplicitPhotoState() async throws {
        try await assertScopedContentJournalProof(blocked: true)
    }

    func testNormalContentWithoutExplicitPhotoStateKeepsJournalUnchanged() async throws {
        try await assertScopedContentJournalProof(blocked: false)
    }

    func testNormalContentWithExplicitPhotoStateRestoresJournalLinks() async throws {
        try await assertScopedContentJournalProof(blocked: false, explicitPhotoState: true)
    }

    private func assertScopedContentJournalProof(blocked: Bool, explicitPhotoState: Bool = false) async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let source = try XCTUnwrap(harness.library.snapshot.first).source
        let descriptor = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"), filename: "current.heic",
            fileSize: 20, modificationDate: harness.clock.now, precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let retired = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        try harness.journal.addSuperseded(retired, for: source)
        try harness.journal.settle([retired.nodeID], related: [], trashed: true, for: source)
        try harness.journal.keepDeleted(for: source)
        let before = harness.journal.entry(for: source)
        harness.server.setVisibility(.init(isActive: false, mainPhotoLinkID: nil), for: retired.nodeID)
        let active = harness.server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        let visibility = RemoteLinkVisibility(
            isActive: true, mainPhotoLinkID: nil, hasExplicitPhotoState: explicitPhotoState)
        harness.server.setVisibilityAfterContentLookup(visibility, for: retired.nodeID)
        harness.server.setVisibilityAfterContentLookup(visibility, for: active.nodeID)
        let draft =
            blocked
            ? harness.server.seedDraft(
                name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: "other-uploader")
            : nil
        let pipeline = UploadDedupePipeline(
            store: harness.identities, checker: harness.server, currentClientUID: "this-uploader",
            replacementJournal: harness.journal)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(
            result.decision,
            blocked
                ? .skip(.draftExists, remoteLinkID: draft?.nodeID)
                : .skip(
                    explicitPhotoState ? .activeDuplicate : .inconsistentRemoteState, remoteLinkID: active.nodeID))
        XCTAssertEqual(harness.server.contentLookupCount, 1)
        let journal = harness.journal.entry(for: source)
        if blocked || !explicitPhotoState {
            XCTAssertEqual(journal, before)
            XCTAssertNil(harness.identities.record(for: source)?.remoteLinkID)
            XCTAssertNil(harness.identities.record(for: source)?.outcome)
        } else {
            XCTAssertNil(journal.keptDeleted)
            XCTAssertTrue(journal.retired.isEmpty)
            XCTAssertEqual(journal.superseded, [PhotoUID(volumeID: "", nodeID: retired.nodeID)])
            XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, active.nodeID)
        }
        if let draft { XCTAssertEqual(harness.server.links.first { $0.uid == draft }?.state, .draft) }
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        try harness.relaunch()
        XCTAssertEqual(harness.journal.entry(for: source), journal)
    }

    private func resolveBeforeTimeout(
        _ pipeline: UploadDedupePipeline, descriptor: UploadResourceDescriptor
    ) async throws -> UploadPreflightResult {
        let finished = expectation(description: "resolve releases both claims and finishes")
        let task = Task {
            defer { finished.fulfill() }
            return try await pipeline.resolve(descriptor)
        }
        await fulfillment(of: [finished], timeout: 2)
        await pipeline.uploadDidFail(descriptor)
        return try await task.value
    }

    private func fixture(
        server: EditScenarioServer, owner: String? = "other-uploader"
    ) -> (UploadDedupePipeline, UploadResourceDescriptor, PhotoUID) {
        let url = URL(fileURLWithPath: "/fixture/current.heic")
        let descriptor = UploadResourceDescriptor(
            source: .file(url), fileURL: url, filename: "current.heic", fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
            precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let draft = server.seedDraft(name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: owner)
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), checker: server, currentClientUID: "this-uploader")
        return (pipeline, descriptor, draft)
    }
}
