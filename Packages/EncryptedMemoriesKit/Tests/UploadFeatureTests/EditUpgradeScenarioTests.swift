import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Upgrade scenarios start with persisted v1.0.5 values, without running today's upload path to seed them.
final class EditUpgradeScenarioTests: XCTestCase {
    private var harness: EditScenarioHarness!

    override func tearDownWithError() throws {
        try harness?.cleanup()
        harness = nil
    }

    private var uploads: Int { harness.server.steps.filter { $0.action.hasPrefix("upload") }.count }
    private var trashed: [String] { harness.server.steps.flatMap(\.trashedByBackup) }
    private var activeMains: Set<PhotoUID> {
        Set(harness.server.links.filter { $0.mainLinkID == nil && $0.state == .active }.map(\.uid))
    }

    func testV105DroppedPhotoReturnsWithoutAnEditAndUploadsOnlyOnce() async throws {
        try await assertV105DroppedPhotoReturns(pending: false)
    }

    func testV105DroppedPhotoWithPendingStateReturnsWithoutAnEdit() async throws {
        try await assertV105DroppedPhotoReturns(pending: true)
    }

    private func assertV105DroppedPhotoReturns(pending: Bool) async throws {
        harness = try EditScenarioHarness(v105: .unchanged)
        try harness.seedV105DroppedPhoto(pending: pending)
        let candidate = try harness.library.candidate("dropped-photo")
        XCTAssertNil(harness.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        XCTAssertEqual(scan.discovered, 0)
        let row = try XCTUnwrap(
            harness.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertTrue([.discovered, .queuedForUpload, .checking].contains(row.state))
        await harness.drain()
        XCTAssertEqual(harness.state(of: row), .completed)
        XCTAssertEqual(uploads, 1)
        XCTAssertTrue(trashed.isEmpty)
        try harness.relaunch()
        _ = try await harness.fullRescan()
        await harness.drain()
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(harness.library.resolutions.filter { $0.source.identifier == "asset-1" }.count, 0)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testRecoveredV105PhotoWithAnUploadManifestDoesNotUploadAgain() async throws {
        harness = try EditScenarioHarness(v105: .unchanged)
        let before = activeMains
        let candidate = try harness.library.candidate()
        XCTAssertNotNil(harness.identities.record(for: candidate.snapshot.source))
        try harness.removeLocalBackupSettlement()
        _ = try await harness.fullRescan()
        XCTAssertNotNil(harness.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        await harness.drain()
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, before)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testFirstFullRescanAfterV105ReopensNothingAndWritesNoJournal() async throws {
        harness = try EditScenarioHarness(v105: .unchanged, assetCount: 256)
        let before = activeMains
        XCTAssertEqual(before.count, 256)
        XCTAssertFalse(harness.journalFileExists)
        for asset in harness.library.snapshot {
            XCTAssertEqual(harness.identities.record(for: asset.source)?.outcome, "uploaded")
            XCTAssertTrue(harness.journal.entry(for: asset.source).isEmpty)
        }

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.scanned, 256)
        XCTAssertEqual(scan.discovered, 0)
        XCTAssertEqual(scan.changed, 0, "An unchanged library must not re-open on upgrade")
        XCTAssertEqual(scan.removed, 0)
        XCTAssertTrue(harness.queue.unsettledRows().isEmpty)
        await harness.drain()

        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, before)
        XCTAssertTrue(harness.library.resolutions.isEmpty, "No photo bytes should be requested")
        XCTAssertFalse(harness.journalFileExists)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testV105LivePhotoWithItsLiveEffectOffStaysUntilItsNextEdit() async throws {
        try await assertV105LiveEffectOffUpgrade(.unchanged)
    }

    func testV105EditedLivePhotoWithItsLiveEffectOffStaysUntilItsNextEdit() async throws {
        try await assertV105LiveEffectOffUpgrade(.edited)
    }

    /// The photo has the shape that Photos reports with the Live effect off: no `.photoLive`, a still playback style, and
    /// a listed paired video. v1.0.5 backed it up as a Live Photo. The upgrade uploads, trashes, and asks nothing; the
    /// next edit replaces the Live Photo with a still photo.
    private func assertV105LiveEffectOffUpgrade(_ fixture: EditScenarioHarness.V105Fixture) async throws {
        harness = try EditScenarioHarness(v105: fixture, live: true, liveOff: true)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let videoHash = EditScenarioServer.contentHash(
            Data(Insecure.SHA1.hash(data: try XCTUnwrap(asset.pairedVideo))))
        let legacyMain = try XCTUnwrap(harness.identities.record(for: asset.source)?.remoteLinkID)
        let legacyVideo = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: asset.identifier, resource: .livePairedVideo)
        XCTAssertNotNil(harness.identities.record(for: legacyVideo), "v1.0.5 recorded a Live Photo video")
        XCTAssertEqual(harness.server.links.first { $0.linkID == legacyMain }?.tags, [PhotoTag.livePhotos.rawValue])
        XCTAssertFalse(asset.info.isLivePhoto)
        XCTAssertTrue(asset.info.livePlaybackOff)
        XCTAssertEqual(harness.catalog.entry(for: asset.identifier)?.livePlaybackOff, false)
        func serverState() -> [String] { harness.server.links.map { "\($0.linkID) \($0.state) \($0.tags.sorted())" } }
        let before = serverState()

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0, "the Live effect alone must not re-open a photo on upgrade")
        XCTAssertEqual(scan.discovered, 0)
        XCTAssertTrue(harness.queue.unsettledRows().isEmpty)
        // A v1.0.5 edit deduped the original and the video against the first main, so it fails the S3 drain check.
        await harness.pass()

        XCTAssertTrue(harness.queue.unsettledRows().isEmpty)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(serverState(), before, "the Live Photo stays in Proton until the next edit")
        XCTAssertTrue(harness.library.resolutions.isEmpty, "No photo bytes should be requested")
        XCTAssertFalse(harness.journalFileExists)
        XCTAssertEqual(harness.catalog.entry(for: asset.identifier)?.livePlaybackOff, true)

        // A metadata change, such as a favorite, moves the modification date. Only an edit replaces the photo.
        harness.library.changeModificationDate()
        _ = try await harness.fullRescan()
        await harness.pass()
        XCTAssertTrue(harness.queue.unsettledRows().isEmpty)
        XCTAssertTrue(trashed.isEmpty)
        if fixture == .edited {
            // v1.0.5 counted the video of the edited version as saved, because the same file already sat under the
            // first version of the photo. It was never related to the edited version. With the Live effect off, the
            // video is a secondary of its own kind now, so no v1.0.5 row covers it, and a copy under another main
            // photo proves nothing. A later queue pass uploads the video once under the edited version. This costs
            // the size of the video in storage once. Nothing is deleted or changed in Proton.
            XCTAssertEqual(uploads, 1, "the video uploads once under the edited version")
            let after = serverState()
            XCTAssertEqual(Array(after.prefix(before.count)), before, "no existing link changes")
            XCTAssertEqual(after.count, before.count + 1)
            let added = try XCTUnwrap(harness.server.links.last)
            XCTAssertEqual(added.mainLinkID, legacyMain, "the video is related to the edited version")
            XCTAssertEqual(added.contentHash, videoHash)
            XCTAssertEqual(added.state, .active)
            XCTAssertEqual(added.tags, [], "the edit backs the video up like the still photo")
        } else {
            XCTAssertEqual(uploads, 0)
            XCTAssertEqual(serverState(), before, "a metadata change keeps the Live Photo in Proton")
        }

        harness.library.edit("edit-after-upgrade", at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(trashed, [legacyMain])
        let main = try harness.liveMain()
        let links = harness.server.links
        XCTAssertEqual(links.first { $0.uid == main }?.tags, [], "the edit backs the photo up as a still")
        let video = try XCTUnwrap(links.first { $0.mainLinkID == main.nodeID && $0.contentHash == videoHash })
        XCTAssertEqual(video.tags, [])
        harness.assertCurrentManifest()
    }

    func testNewEditAfterV105TrashesOnlyTheManifestMainAndKeepsTheOriginalMain() async throws {
        harness = try EditScenarioHarness(v105: .edited)
        let original = try XCTUnwrap(harness.activeMains.first { $0.generation == 1 }).uid
        let earlierEdit = try XCTUnwrap(harness.activeMains.first { $0.generation == 2 }).uid
        let source = try harness.library.candidate().snapshot.source
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, earlierEdit.nodeID)
        XCTAssertTrue(
            harness.server.links.filter { $0.mainLinkID == earlierEdit.nodeID }.allSatisfy { !$0.isOriginal },
            "v1.0.5 deduped the original against L0 instead of attaching a new copy to E")
        XCTAssertFalse(harness.journalFileExists)
        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        await harness.pass()
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertFalse(harness.journalFileExists)

        harness.library.edit("new-render-after-upgrade", at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(trashed, [earlierEdit.nodeID])
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .active)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlierEdit }?.state, .trashed)
        XCTAssertEqual(activeMains.count, 2, "The unrelated legacy original stays beside the new edit")
        XCTAssertFalse(harness.journal.entry(for: source).retired.contains(original.nodeID))
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testUndoOfAV105EditKeepsBothLegacyMainsAndTrashesNothing() async throws {
        harness = try EditScenarioHarness(v105: .edited)
        let before = activeMains
        XCTAssertEqual(before.count, 2)
        XCTAssertFalse(harness.journalFileExists)

        harness.library.undo(at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(activeMains, before)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(harness.journal.entry(for: entry.source).superseded.isEmpty)
        XCTAssertFalse(harness.journalFileExists)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testEditingOneOfTwoV105AssetsWithIdenticalBytesKeepsTheirSharedMain() async throws {
        harness = try EditScenarioHarness(v105: .identicalBytes)
        let first = try harness.library.candidate().snapshot.source
        let second = try harness.library.candidate("asset-2").snapshot.source
        let shared = try XCTUnwrap(harness.identities.record(for: first)?.remoteLinkID)
        XCTAssertEqual(harness.identities.record(for: second)?.remoteLinkID, shared)
        XCTAssertEqual(activeMains.count, 1)
        XCTAssertFalse(harness.journalFileExists)

        harness.library.edit("only-the-first-asset-is-edited", at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(harness.server.links.first { $0.linkID == shared }?.state, .active)
        XCTAssertEqual(harness.identities.record(for: second)?.remoteLinkID, shared)
        XCTAssertNotEqual(harness.identities.record(for: first)?.remoteLinkID, shared)
        XCTAssertEqual(activeMains.count, 2)
        XCTAssertTrue(harness.journal.entry(for: first).superseded.isEmpty)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testV105MissingRenderReopensOnceWithoutUploadingOrSupersedingAnything() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let candidate = try harness.library.candidate()
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let oldRevision = UploadBackupRevision(date: asset.modificationDate)
        XCTAssertNotEqual(candidate.snapshot.revision, oldRevision)
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: oldRevision)?.state, .completed)
        XCTAssertNil(harness.queue.entry(for: asset.source, revision: candidate.snapshot.revision))
        XCTAssertFalse(harness.journalFileExists)
        let before = activeMains

        let firstScan = try await harness.fullRescan()
        XCTAssertEqual(firstScan.scanned, 1)
        XCTAssertEqual(firstScan.changed, 1, "Only the missing-render marker re-opens the legacy row")
        XCTAssertEqual(firstScan.discovered, 0)
        let reopened = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(reopened.state, .checking)
        await harness.drain()
        XCTAssertEqual(harness.state(of: reopened), .alreadyBackedUp)
        XCTAssertEqual(harness.library.resolutions.count, 1)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(harness.journal.entry(for: asset.source).superseded.isEmpty)

        // Reopen the files again so an in-memory scan result cannot hide a repeated migration.
        try harness.relaunch()
        let secondScan = try await harness.fullRescan()
        XCTAssertEqual(secondScan.scanned, 1)
        XCTAssertEqual(secondScan.changed, 0)
        XCTAssertEqual(secondScan.discovered, 0)
        await harness.drain()
        XCTAssertEqual(harness.library.resolutions.count, 1)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, before)
        XCTAssertTrue(harness.journal.entry(for: asset.source).superseded.isEmpty)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testV105MissingRenderUploadsTheRenderedFileThatAppearsWithoutANewDate() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        try await assertLateRenderUploads()
    }

    func testV105MissingRenderUploadsALateRenderedFileAlsoAfterTheFirstReopen() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        _ = try await harness.fullRescan()
        await harness.drain()
        XCTAssertEqual(uploads, 0)
        try await assertLateRenderUploads()
    }

    func testV105MissingRenderReopensWhenTheOriginalRecordHoldsTheMainBytes() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        var late = try XCTUnwrap(harness.library.snapshot.first)
        let main = try XCTUnwrap(harness.identities.record(for: late.source))
        late.render = Data("late-render".utf8)
        // A record of the original with the bytes of the main file proves that the backup holds no rendered file.
        var original = main
        original.source = try XCTUnwrap(PhotoBackupAssetPlanner.originalSecondarySource(for: late.info))
        XCTAssertTrue(harness.identities.upsert(original))
        try await assertLateRenderUploads()
    }

    func testV105MissingRenderUploadsTheRenderedFileThatAppearsWhenThePairedVideoDisappears() async throws {
        harness = try EditScenarioHarness(v105: .missingRender, live: true)
        let legacyCount = try harness.library.candidate().snapshot.resourceCount
        harness.library.removePairedVideo()
        var late = try XCTUnwrap(harness.library.snapshot.first)
        late.render = Data("late-render".utf8)
        // The rendered file takes the place of the paired video, so the v1.0.5 backup counts as many files.
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: late.info)?.snapshot.resourceCount, legacyCount)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        let earlierMains = activeMains
        harness.library.publishRender("late-render")
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .completed)

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1)
        let reopened = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(reopened.state, .queuedForUpload, "equal file counts must not hide the missing rendered file")
        await harness.pass()
        XCTAssertGreaterThan(uploads, 0, "the rendered file uploads")
        // The paired video exists only under the earlier main photo, so the edit waits instead of trashing it.
        XCTAssertTrue(earlierMains.isSubset(of: activeMains))
        XCTAssertEqual(harness.state(of: reopened), .discovered)
        harness.assertSafety()
    }

    func testV105MissingRenderThatThePersonDeletedElsewhereStaysDeletedWhenTheRenderedFileAppears() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        // Another client moves the only backup to the trash, so this device keeps no exclusion for the photo.
        harness.server.personTrash(try XCTUnwrap(harness.activeMains.first).uid)
        harness.library.publishRender("late-render-after-deletion")

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1)
        harness.clock.advance(by: 5)
        await harness.pass()
        let deferred = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(deferred.state, .discovered)
        XCTAssertEqual(
            BackupIssueRecord.decode(deferred.lastError)?.detail,
            L10n.string("backup.issue_deletion_check"))
        harness.clock.advance(by: 120)
        await harness.pass()
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .discovered)
        harness.clock.advance(by: 480)
        await harness.pass()

        let parked = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(parked.state, .failedPermanent)
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .deletedElsewhere)
        XCTAssertEqual(uploads, 0, "The rendered file must not bring the deleted photo back")
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(activeMains.isEmpty)
        harness.assertSafety()
    }

    func testV105MissingRenderThatTheRunnerBacksUpBeforeTheNextScanDoesNotReopen() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        // The scan stores the catalog entry without the rendered file, which appears before the runner reads the photo.
        _ = try await harness.fullRescan()
        harness.library.publishRender("late-render-before-scan")
        await harness.drain()
        let uploadsAfterRender = uploads
        XCTAssertGreaterThan(uploadsAfterRender, 0)
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .completed)
        let resolutions = harness.library.resolutions.count

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1)
        let row = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertTrue(
            [.completed, .alreadyBackedUp].contains(row.state), "The backup already holds the rendered file")
        await harness.drain()
        XCTAssertEqual(harness.library.resolutions.count, resolutions, "No photo bytes should be requested again")
        XCTAssertEqual(uploads, uploadsAfterRender)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testV105CatalogThatAlreadyListsTheLateRenderedFileUploadsItOnceAfterTheUpgrade() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let late = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: late.modificationDate)
        harness.library.add("asset-2", basename: "IMG_2")
        harness.library.edit("proven-render", identifier: "asset-2", at: harness.clock.now.addingTimeInterval(-121))
        harness.library.publishRender("late-render")
        // Today's build backs up the second edit with its rendered file as main photo.
        let proven = try await harness.enqueue("asset-2")
        await harness.pass()
        XCTAssertEqual(harness.state(of: proven), .completed)
        // v1.0.5 scanned both photos after Photos listed the rendered files, so the upgrade scan sees no change.
        let observedAt = harness.clock.now
        let entries = harness.library.snapshot.map {
            PhotoLibraryCatalogMapper.entry(for: $0.info, observedAt: observedAt)
        }
        XCTAssertTrue(harness.catalog.upsertBatch(entries))
        XCTAssertFalse(harness.catalog.hasReconciledLateRenders())
        let uploadsBefore = uploads
        let provenResolutions = harness.library.resolutions.filter { $0.source == proven.source }.count

        try harness.relaunch()
        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        XCTAssertEqual(scan.discovered, 0)
        XCTAssertTrue(harness.catalog.hasReconciledLateRenders())
        let reopened = try XCTUnwrap(harness.queue.entry(for: late.source, revision: revision))
        XCTAssertEqual(reopened.state, .queuedForUpload, "The v1.0.5 backup holds no rendered file")
        XCTAssertEqual(harness.state(of: proven), .completed, "The manifest proves the rendered file")
        await harness.drain()
        XCTAssertEqual(harness.state(of: reopened), .completed)
        let uploadsAfterRender = uploads
        XCTAssertGreaterThan(uploadsAfterRender, uploadsBefore)
        XCTAssertEqual(harness.library.resolutions.filter { $0.source == proven.source }.count, provenResolutions)

        try harness.relaunch()
        let secondScan = try await harness.fullRescan()
        XCTAssertEqual(secondScan.changed, 0)
        await harness.drain()
        XCTAssertEqual(uploads, uploadsAfterRender)
        XCTAssertEqual(harness.library.resolutions.filter { $0.source == proven.source }.count, provenResolutions)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    /// Another device backed up the edit with its rendered file. v1.0.5 on this device settled the photo through the
    /// remote proof, so this device holds backup states and no manifest record. The one-time pass over edits that list
    /// their rendered file keeps the photo settled without reading its bytes; a later edit still replaces it.
    func testV105EditSettledByTheRemoteProofOfAnotherDeviceStaysSettledWithoutReadingBytes() async throws {
        let (deviceB, main) = try await secondDeviceSettledByTheRemoteProof()
        defer { try? deviceB.cleanup() }
        let candidate = try deviceB.library.candidate()
        let uploadsBefore = uploads
        let resolutions = deviceB.library.resolutions.count

        let scan = try await deviceB.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        XCTAssertEqual(scan.discovered, 0)
        XCTAssertTrue(deviceB.catalog.hasReconciledLateRenders())
        let row = try XCTUnwrap(
            deviceB.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(row.state, .alreadyBackedUp, "The remote proof still holds the rendered file")
        await deviceB.drain()
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions, "No photo bytes should be requested")
        XCTAssertEqual(uploads, uploadsBefore)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, [main])

        deviceB.library.edit("edit-after-upgrade", at: deviceB.clock.now)
        let edit = try await deviceB.enqueue()
        await deviceB.drain()
        XCTAssertEqual(deviceB.state(of: edit), .completed)
        XCTAssertGreaterThan(uploads, uploadsBefore, "A new edit still backs up")
        XCTAssertEqual(trashed, [main.nodeID])
        deviceB.assertQuiescent()
    }

    /// The remote proof cannot be read on the first launch, for example offline. The pass leaves the photo settled and
    /// stops without marking itself done; a later pass with a readable proof finishes it. No pass reads photo bytes.
    func testV105EditSettledByTheRemoteProofWaitsForAReadableProofWhenTheLookupFails() async throws {
        let (deviceB, main) = try await secondDeviceSettledByTheRemoteProof()
        defer { try? deviceB.cleanup() }
        let candidate = try deviceB.library.candidate()
        let uploadsBefore = uploads
        let resolutions = deviceB.library.resolutions.count
        func rowState() -> UploadBackupSyncQueueState? {
            deviceB.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision)?.state
        }

        deviceB.index.setProofLookupsFail(true)
        _ = try await deviceB.fullRescan()
        XCTAssertFalse(deviceB.catalog.hasReconciledLateRenders(), "A later pass checks the photo again")
        XCTAssertEqual(rowState(), .alreadyBackedUp, "An unreadable proof re-opens nothing")
        await deviceB.drain()
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions, "No photo bytes should be requested")

        deviceB.index.setProofLookupsFail(false)
        try deviceB.relaunch()
        _ = try await deviceB.fullRescan()
        XCTAssertTrue(deviceB.catalog.hasReconciledLateRenders())
        XCTAssertEqual(rowState(), .alreadyBackedUp, "The remote proof still holds the rendered file")
        await deviceB.drain()
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions, "No photo bytes should be requested")
        XCTAssertEqual(uploads, uploadsBefore)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, [main])
    }

    /// This device hashed and uploaded the unedited original. Another device then edited the photo and replaced the
    /// upload, and v1.0.5 on this device settled the edit through the remote proof. The manifest still holds the record
    /// of the unedited original, which says nothing about the edit's backup, so the remote proof keeps it settled.
    func testV105EditSettledByTheRemoteProofStaysSettledOnTheDeviceThatHashedTheOriginal() async throws {
        harness = try EditScenarioHarness()
        try await harness.enqueue()
        await harness.drain()
        let original = try harness.liveMain()
        let source = try harness.library.candidate().snapshot.source
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, original.nodeID)
        let phone = try EditScenarioHarness(server: harness.server, library: harness.library)
        defer { try? phone.cleanup() }
        try await phone.enqueue()
        await phone.pass()
        phone.library.edit("phone-render", at: phone.clock.now)
        try await phone.enqueue()
        phone.clock.advance(by: 5)
        await phone.drain()
        let edit = try harness.liveMain()
        XCTAssertNotEqual(edit, original)
        XCTAssertEqual(trashed, [original.nodeID])

        harness.index.refreshProofs()
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let candidate = try harness.library.candidate()
        let identity = try XCTUnwrap(candidate.snapshot.externalIdentity)
        let proof = try await harness.server.findRemoteAssetProofs(for: [identity])
        XCTAssertEqual(proof[identity]?.resourceCount, candidate.snapshot.resourceCount)
        try harness.seedV105RemoteProofSettlement()
        XCTAssertNotNil(harness.identities.record(for: source), "The record of the unedited original stays")
        let formerMain = try XCTUnwrap(PhotoBackupAssetPlanner.originalSecondarySource(for: asset.info))
        XCTAssertNil(harness.identities.record(for: formerMain))
        let uploadsBefore = uploads
        let resolutions = harness.library.resolutions.count

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        XCTAssertTrue(harness.catalog.hasReconciledLateRenders())
        let row = try XCTUnwrap(harness.queue.entry(for: source, revision: candidate.snapshot.revision))
        XCTAssertEqual(row.state, .alreadyBackedUp, "The remote proof holds the rendered file")
        await harness.drain()
        XCTAssertEqual(harness.library.resolutions.count, resolutions, "No photo bytes should be requested")
        XCTAssertEqual(uploads, uploadsBefore)
        XCTAssertEqual(trashed, [original.nodeID])
        XCTAssertEqual(activeMains, [edit])
    }

    /// Two photos list the same iCloud identity, and the backup of one of them matches it. The proof cannot tell which
    /// photo it belongs to, so the pass re-opens both.
    func testV105EditsThatShareOneRemoteIdentityReopenBecauseTheProofProvesNeither() async throws {
        let (deviceB, _) = try await secondDeviceSettledByTheRemoteProof { library in
            library.add("asset-2", basename: "IMG_2")
            library.shareCloudIdentifier("cloud-asset-1", between: ["asset-1", "asset-2"])
            library.edit("second-render", identifier: "asset-2", at: Date(timeIntervalSince1970: 1_720_000_100))
        }
        defer { try? deviceB.cleanup() }
        let first = try deviceB.library.candidate()
        let second = try deviceB.library.candidate("asset-2")
        XCTAssertEqual(first.snapshot.externalIdentity, second.snapshot.externalIdentity)
        XCTAssertEqual(first.snapshot.resourceCount, second.snapshot.resourceCount)

        _ = try await deviceB.fullRescan()
        XCTAssertTrue(deviceB.catalog.hasReconciledLateRenders())
        for candidate in [first, second] {
            XCTAssertEqual(
                deviceB.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision)?.state,
                .queuedForUpload, "\(candidate.snapshot.source.identifier) re-opens")
        }
    }

    /// Device A backs up an edit with its rendered file. Then `prepare` changes the shared library, and device B gets
    /// the stores that v1.0.5 wrote after it settled every photo through the remote proof.
    private func secondDeviceSettledByTheRemoteProof(
        prepare: (EditScenarioLibrary) -> Void = { _ in }
    ) async throws -> (EditScenarioHarness, PhotoUID) {
        harness = try EditScenarioHarness()
        harness.library.edit("first-device-render", at: harness.clock.now.addingTimeInterval(-121))
        try await harness.enqueue()
        await harness.drain()
        let main = try harness.liveMain()
        prepare(harness.library)
        let deviceB = try EditScenarioHarness(server: harness.server, library: harness.library)
        do {
            let candidate = try deviceB.library.candidate()
            let identity = try XCTUnwrap(candidate.snapshot.externalIdentity)
            let proof = try await deviceB.server.findRemoteAssetProofs(for: [identity])
            XCTAssertEqual(proof[identity]?.resourceCount, candidate.snapshot.resourceCount)
            try deviceB.seedV105RemoteProofSettlement()
            XCTAssertNil(deviceB.identities.record(for: candidate.snapshot.source))
            XCTAssertFalse(deviceB.catalog.hasReconciledLateRenders())
        } catch {
            try? deviceB.cleanup()
            throw error
        }
        return (deviceB, main)
    }

    /// The other device backed up the edit before Photos listed its rendered file. The remote proof counts one file
    /// less than the photo lists now, so it settles nothing, and the rendered file backs up.
    func testV105LateRenderSettledByTheRemoteProofOfAnotherDeviceStillBacksUpTheRenderedFile() async throws {
        harness = try EditScenarioHarness(v105: .missingRender, remoteIdentity: true)
        let deviceB = try EditScenarioHarness(server: harness.server, library: harness.library)
        defer { try? deviceB.cleanup() }
        let asset = try XCTUnwrap(deviceB.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        deviceB.library.publishRender("late-render")
        let candidate = try deviceB.library.candidate()
        XCTAssertEqual(candidate.snapshot.revision, revision)
        let identity = try XCTUnwrap(candidate.snapshot.externalIdentity)
        let proof = try await deviceB.server.findRemoteAssetProofs(for: [identity])
        XCTAssertEqual(proof[identity]?.resourceCount, candidate.snapshot.resourceCount - 1)
        // v1.0.5 settled the photo before Photos listed the rendered file, and scanned it again afterwards.
        try deviceB.seedV105RemoteProofSettlement()
        XCTAssertNil(deviceB.identities.record(for: candidate.snapshot.source))
        let uploadsBefore = uploads

        let scan = try await deviceB.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        let reopened = try XCTUnwrap(deviceB.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(reopened.state, .queuedForUpload, "The remote backup holds no rendered file")
        await deviceB.pass()
        XCTAssertEqual(deviceB.state(of: reopened), .completed)
        XCTAssertGreaterThan(uploads, uploadsBefore)
        let renderHash = EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: Data("late-render".utf8))))
        XCTAssertTrue(
            harness.server.links.contains {
                $0.state == .active && $0.mainLinkID == nil && $0.contentHash == renderHash
            }, "The rendered file is a main photo in Proton")
    }

    /// Photos lists the rendered file later and leaves the dates alone, so the revision equals the v1.0.5 one.
    private func assertLateRenderUploads(file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        harness.library.publishRender("late-render")
        XCTAssertEqual(try harness.library.candidate().snapshot.revision, revision, file: file, line: line)
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .completed)

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1, file: file, line: line)
        let reopened = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(
            reopened.state, .queuedForUpload, "The v1.0.5 backup holds no rendered file", file: file, line: line)
        await harness.drain(file: file, line: line)
        XCTAssertEqual(harness.state(of: reopened), .completed, file: file, line: line)
        let uploadsAfterRender = uploads
        XCTAssertGreaterThan(uploadsAfterRender, 0, file: file, line: line)

        // The re-open happens once: the catalog now lists the rendered file.
        try harness.relaunch()
        let secondScan = try await harness.fullRescan()
        XCTAssertEqual(secondScan.changed, 0, file: file, line: line)
        await harness.drain(file: file, line: line)
        XCTAssertEqual(uploads, uploadsAfterRender, file: file, line: line)
        harness.assertSafety(file: file, line: line)
        harness.assertQuiescent(file: file, line: line)
    }
}
