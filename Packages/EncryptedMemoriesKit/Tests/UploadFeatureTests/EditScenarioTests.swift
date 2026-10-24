import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// End-to-end edit scenarios share server truth across every production seam.
final class EditScenarioTests: XCTestCase {
    private var harness: EditScenarioHarness!

    override func tearDownWithError() throws {
        try harness?.cleanup()
        harness = nil
    }

    @discardableResult
    private func firstBackup(live: Bool = false, basename: String = "IMG_1") async throws -> PhotoUID {
        harness = try EditScenarioHarness(live: live, basename: basename)
        try await harness.enqueue()
        await harness.drain()
        let main = try harness.liveMain()
        harness.server.decorate(main)
        harness.assertSafety()
        return main
    }

    @discardableResult
    private func edit(_ bytes: String, omitOriginal: Bool = false) async throws -> UploadBackupSyncQueueEntry {
        harness.library.edit(bytes, omitOriginal: omitOriginal, at: harness.clock.now)
        let entry = try await harness.enqueue()
        harness.assertSafety()
        return entry
    }

    @discardableResult
    private func undo() async throws -> UploadBackupSyncQueueEntry {
        harness.library.undo(at: harness.clock.now)
        let entry = try await harness.enqueue()
        harness.assertSafety()
        return entry
    }

    func testFirstEditOfABackedUpPhoto() async throws {
        let earlier = try await firstBackup()
        let related = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: earlier.nodeID)
        XCTAssertTrue(related.isEmpty, "An existing main without related files answers with an empty set")
        let entry = try await edit("render-one")
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
    }

    func testFirstEditAfterRelaunch() async throws {
        try await firstBackup()
        try harness.relaunch()
        try await edit("render-one")
        await harness.drain()
    }

    func testSecondEdit() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        try await edit("render-two")
        await harness.drain()
    }

    func testSecondEditAfterRelaunch() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        try harness.relaunch()
        try await edit("render-two")
        await harness.drain()
    }

    func testUndoAfterOneEdit() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        let entry = try await undo()
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry), .completed)
    }

    func testUndoAfterOneEditAndRelaunch() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        try harness.relaunch()
        try await undo()
        await harness.drain()
    }

    /// Mirrors the IMG_7380 device case from September 30, 2026.
    func testUndoWithATrashedOriginalOutsideRetired() async throws {
        let original = try await firstBackup(basename: "IMG_7380")
        try await edit("render-one")
        await harness.drain()
        let edited = try harness.liveMain()
        let originalLink = try XCTUnwrap(harness.server.links.first { $0.uid == original })
        XCTAssertTrue(
            harness.server.links.contains {
                $0.mainLinkID == edited.nodeID && $0.state == .active && $0.contentHash == originalLink.contentHash
                    && $0.nameHash == originalLink.nameHash
            }, "The edited main must hold the original as an active related file before undo")
        try harness.server.addHistoricalTrashedCopy(of: original)
        harness.assertSafety()
        let historical = try XCTUnwrap(harness.server.links.first { $0.generation == 0 })
        XCTAssertEqual(historical.state, .trashed)
        XCTAssertNil(historical.mainLinkID)
        XCTAssertEqual(historical.nameHash, originalLink.nameHash)
        XCTAssertEqual(historical.contentHash, originalLink.contentHash)
        let source = try harness.library.candidate().snapshot.source
        XCTAssertFalse(harness.journal.entry(for: source).retired.contains(historical.linkID))
        let entry = try await undo()
        await harness.drain()
        harness.check(harness.state(of: entry) != .skippedRemoteDeletion, "an undo is not the person's deletion")
        harness.check(
            harness.activeMains.contains { $0.contentHash == originalLink.contentHash },
            "an undo must make the original the main again")
    }

    func testThreeRapidEdits() async throws {
        try await firstBackup()
        try await edit("render-one")
        try await edit("render-two")
        try await edit("render-three")
        // No sleeps or scheduling race: all three discoveries exist before the runner resolves current bytes.
        await harness.drain()
        XCTAssertEqual(harness.activeMains.count, 1, "U3 rapid edits must converge to one main")
        XCTAssertEqual(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, 4,
            "Only the original main, final render main, original secondary, and current adjustment data should upload")
    }

    func testLivePhotoEditThenUndo() async throws {
        try await firstBackup(live: true)
        try await edit("render-one")
        await harness.drain()
        try await undo()
        await harness.drain()
    }

    func testTurningTheLiveEffectOffAndOnReplacesTheLivePhotoWithAStillAndBack() async throws {
        let live = try await firstBackup(live: true)
        let video = try XCTUnwrap(harness.library.snapshot.first?.pairedVideo)
        let videoHash = EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: video)))
        let liveTag: Set<Int> = [PhotoTag.livePhotos.rawValue]
        func compound(of main: PhotoUID) throws -> (main: EditScenarioServer.Link, video: EditScenarioServer.Link) {
            let links = harness.server.links
            return (
                try XCTUnwrap(links.first { $0.uid == main }),
                try XCTUnwrap(links.first { $0.mainLinkID == main.nodeID && $0.contentHash == videoHash })
            )
        }
        XCTAssertEqual(try compound(of: live).main.tags, liveTag)

        harness.library.setLivePlaybackOff(true)
        let off = try await edit("live-off-render")
        await harness.drain()

        XCTAssertEqual(harness.state(of: off), .completed)
        XCTAssertEqual(harness.server.links.first { $0.uid == live }?.state, .trashed)
        let still = try compound(of: try harness.liveMain())
        XCTAssertEqual(still.main.tags, [], "a still photo carries no Live Photo tag")
        XCTAssertEqual(still.video.tags, [], "the paired video stays a plain related file")
        XCTAssertEqual(still.video.state, .active)
        harness.assertCurrentManifest()

        harness.library.setLivePlaybackOff(false)
        let on = try await undo()
        await harness.drain()

        XCTAssertEqual(harness.state(of: on), .completed)
        XCTAssertEqual(harness.server.links.first { $0.uid == still.main.uid }?.state, .trashed)
        let liveAgain = try compound(of: try harness.liveMain())
        XCTAssertEqual(liveAgain.main.tags, liveTag)
        XCTAssertEqual(liveAgain.video.tags, liveTag)
        harness.assertCurrentManifest()
    }

    func testPersonTrashesLiveMainThenEditsNothingUploads() async throws {
        let main = try await firstBackup()
        harness.server.personTrash(main)
        harness.assertSafety()
        let uploads = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let entry = try await edit("render-after-person-deletion")
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .discovered)
        let deferred = try XCTUnwrap(harness.queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(
            BackupIssueRecord.decode(deferred.lastError)?.detail,
            L10n.string("backup.issue_deletion_check"))
        XCTAssertEqual(deferred.attempts, 0)
        // A second check after two minutes still finds nothing, but the bound has not passed: no question yet.
        harness.clock.advance(by: 120)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .discovered)
        harness.clock.advance(by: 480)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .failedPermanent)
        let parked = try XCTUnwrap(harness.queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .deletedElsewhere)
        XCTAssertEqual(harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
    }

    func testPersonRestoresReplacedMainThenUndoesWithoutAnIdenticalMain() async throws {
        let original = try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        harness.server.personRestore(original)
        harness.assertSafety()
        try await undo()
        await harness.drain()
        harness.check(harness.activeMains.count == 1, "Restore plus undo must not create another identical main")
        harness.check(try harness.liveMain() == original, "The restored original already holds the current version")
    }

    func testPersonTrashesTheEditRestoresTheEarlierVersionThenEditsAgain() async throws {
        let original = try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        let edited = try harness.liveMain()
        harness.server.personTrash(edited)
        harness.server.personRestore(original)
        harness.assertSafety()
        try await edit("render-two")
        await harness.drain()
        XCTAssertEqual(harness.activeMains.count, 1, "the new edit replaces the restored earlier version")
        XCTAssertEqual(harness.server.links.first { $0.uid == edited }?.state, .trashed, "the person's trash stays")
    }

    func testAnEditThatKeepsWaitingChecksAgainLessOften() async throws {
        let original = try await firstBackup()
        let entry = try await edit("render-that-keeps-waiting", omitOriginal: true)
        harness.clock.advance(by: 5)
        var waits: [TimeInterval] = []
        for _ in 0..<4 {
            await harness.pass()
            let row = try XCTUnwrap(harness.queue.entry(for: entry.source, revision: entry.revision))
            XCTAssertEqual(row.state, .discovered)
            XCTAssertEqual(row.attempts, 0, "waiting spends no attempt")
            waits.append(row.updatedAt.timeIntervalSince(harness.clock.now))
            harness.clock.advance(by: row.updatedAt.timeIntervalSince(harness.clock.now) + 1)
        }

        XCTAssertEqual(waits.count, 4)
        for (earlier, later) in zip(waits, waits.dropFirst()) {
            XCTAssertGreaterThan(later, earlier, "each check waits longer than the one before")
        }
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .active)
    }

    func testTheWaitOfAnEditDoublesUpToSixHours() {
        let delays = (0..<10).map { BackupSyncRunner.waitingReplacementDelay(afterWaits: $0, first: 180) }

        XCTAssertEqual(Array(delays.prefix(4)), [180, 360, 720, 1440])
        XCTAssertEqual(delays.last, 6 * 60 * 60)
        XCTAssertEqual(BackupSyncRunner.waitingReplacementDelay(afterWaits: 3, first: 0.5), 4)
    }

    func testEditWhoseCompoundLacksTheOriginal() async throws {
        let original = try await firstBackup()
        let entry = try await edit("render-without-original", omitOriginal: true)
        harness.clock.advance(by: 5)
        await harness.pass()
        let waiting = try XCTUnwrap(harness.queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(waiting.state, .discovered)
        XCTAssertEqual(waiting.attempts, 0, "waiting for an original spends no attempt")
        XCTAssertGreaterThan(waiting.updatedAt, harness.clock.now)
        XCTAssertEqual(BackupIssueRecord.decode(waiting.lastError)?.nextAttemptAt, waiting.updatedAt)
        XCTAssertEqual(harness.activeMains.count, 2, "the earlier main protects the original while the edit waits")
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .active)
        harness.check(
            !(harness.state(of: entry)?.isTerminalSuccess == true
                && harness.journal.entry(for: entry.source).superseded.contains(original)),
            "the queue must not complete while the earlier main waits for its original")
        harness.assertRetired()

        harness.library.makeOriginalAvailable()
        try harness.relaunch()
        harness.clock.advance(by: waiting.updatedAt.timeIntervalSince(harness.clock.now) + 1)
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(harness.activeMains.count, 1)
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)
        let main = try harness.liveMain()
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        XCTAssertTrue(
            harness.server.links.contains {
                $0.mainLinkID == main.nodeID && $0.state == .active
                    && $0.contentHash == EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: asset.original)))
            }, "the edited main holds the original as an active related file")
    }

    /// The person trashes the earlier main while the edit waits for its original. The edit then completes without a
    /// trash of its own, so the earlier main is gone, not retired. No `decorate`: a gone main keeps no favorite (S4).
    private func personTrashesTheWaitingEarlierMain() async throws -> (PhotoUID, UploadBackupSyncQueueEntry) {
        harness = try EditScenarioHarness()
        try await harness.enqueue()
        await harness.drain()
        let earlier = try harness.liveMain()
        let entry = try await edit("render-while-earlier-waits", omitOriginal: true)
        harness.clock.advance(by: 5)
        await harness.pass()
        let waiting = try XCTUnwrap(harness.queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertTrue(harness.journal.entry(for: entry.source).superseded.contains(earlier))
        harness.server.personTrash(earlier)
        harness.assertSafety()
        harness.library.makeOriginalAvailable()
        try harness.relaunch()
        harness.clock.advance(by: waiting.updatedAt.timeIntervalSince(harness.clock.now) + 1)
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(harness.journal.entry(for: entry.source).gone, [earlier.nodeID])
        XCTAssertFalse(harness.journal.entry(for: entry.source).retired.contains(earlier.nodeID))
        return (earlier, entry)
    }

    func testPersonTrashesTheWaitingEarlierMainRestoresItThenEditsAgain() async throws {
        let (earlier, _) = try await personTrashesTheWaitingEarlierMain()
        let edited = try harness.liveMain()
        harness.server.personRestore(earlier)
        harness.assertSafety()
        try await edit("render-after-restore")
        await harness.drain()
        XCTAssertEqual(
            harness.server.links.first { $0.uid == earlier }?.state, .active, "the person's restored photo stays")
        XCTAssertEqual(harness.server.links.first { $0.uid == edited }?.state, .trashed)
    }

    /// The person restored the earlier photo, so the photo is in the library: trashing the edit and editing again backs
    /// up the new edit without a deletion question.
    func testRestoredEarlierMainKeepsThePhotoLiveAfterThePersonTrashesTheEdit() async throws {
        let (earlier, _) = try await personTrashesTheWaitingEarlierMain()
        let edited = try harness.liveMain()
        harness.server.personRestore(earlier)
        harness.server.personTrash(edited)
        harness.assertSafety()
        let entry = try await edit("render-after-restore-and-trash")
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry)?.isTerminalSuccess, true, "the photo is live, so the edit backs up")
        XCTAssertNil(harness.journal.entry(for: entry.source).deletionCheckStartedAt)
        XCTAssertEqual(
            harness.server.links.first { $0.uid == earlier }?.state, .active, "the person's restored photo stays")
    }

    /// A choice to keep the photo deleted ends when the person restores the earlier photo: the photo is live again.
    func testRestoredEarlierMainEndsAnEarlierChoiceToKeepThePhotoDeleted() async throws {
        let (earlier, entry) = try await personTrashesTheWaitingEarlierMain()
        let edited = try harness.liveMain()
        harness.server.personTrash(edited)
        try harness.journal.keepDeleted(for: entry.source)
        harness.server.personRestore(earlier)
        harness.assertSafety()
        let next = try await edit("render-after-kept-deleted")
        harness.clock.advance(by: 5)
        // The duplicate check itself ends the choice, before any upload succeeds. This check uploads nothing, so no
        // pass follows: the pipeline keeps its claim on these bytes until an upload settles.
        let decision = try await harness.primaryDecision(for: next)
        XCTAssertTrue(decision.uploadsBytes)
        XCTAssertNil(harness.journal.entry(for: entry.source).keptDeleted, "the live photo ends the earlier choice")
    }

    /// An undo adopts the restored photo as the backup of the photo. A later edit still never trashes it.
    func testRestoredEarlierMainAdoptedByAnUndoStaysThroughTheNextEdit() async throws {
        let (earlier, _) = try await personTrashesTheWaitingEarlierMain()
        harness.server.personRestore(earlier)
        harness.assertSafety()
        try await undo()
        await harness.drain()
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .active)
        let next = try await edit("render-after-adopting-undo")
        await harness.drain()
        XCTAssertEqual(
            harness.server.links.first { $0.uid == earlier }?.state, .active, "the person's restored photo stays")
        XCTAssertFalse(
            harness.journal.entry(for: next.source).superseded.contains { $0.nodeID == earlier.nodeID },
            "a kept photo leaves the replacement")
        harness.assertRetired()
    }

    func testPersonTrashesTheWaitingEarlierMainThenTheEditThenUndoes() async throws {
        let (_, entry) = try await personTrashesTheWaitingEarlierMain()
        try harness.server.personTrash(harness.liveMain())
        harness.assertSafety()
        let uploads = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let undone = try await undo()
        harness.clock.advance(by: 5)
        await harness.pass()
        // The trashed earlier main has the bytes of the undo, but its author is unknown: the backup asks.
        XCTAssertEqual(harness.state(of: undone), .discovered)
        let deferred = try XCTUnwrap(harness.queue.entry(for: undone.source, revision: undone.revision))
        XCTAssertEqual(
            BackupIssueRecord.decode(deferred.lastError)?.detail,
            L10n.string("backup.issue_deletion_check"))
        XCTAssertNotNil(harness.journal.entry(for: entry.source).deletionCheckStartedAt)
        XCTAssertEqual(harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
    }

    private enum LineageMarker {
        case none
        /// The other device's upload names the earlier main that its backup trashed. A marker names what an upload
        /// replaces, not who trashed it, so it proves no backup trash either.
        case otherDevice
        /// Only the waiting upload of this device names the earlier main. That is no proof of a backup trash.
        case ownUpload
    }

    func testSecondDeviceRetiresTheWaitingEarlierMainWithAMarkerOfTheOtherDevice() async throws {
        try await secondDeviceRetiresTheWaitingEarlierMain(marker: .otherDevice)
    }

    func testSecondDeviceRetiresTheWaitingEarlierMainWithoutLineageProof() async throws {
        try await secondDeviceRetiresTheWaitingEarlierMain(marker: .none)
    }

    func testSecondDeviceRetiresTheWaitingEarlierMainWithOnlyTheOwnMarker() async throws {
        try await secondDeviceRetiresTheWaitingEarlierMain(marker: .ownUpload)
    }

    /// Two devices with their own libraries share one server. Device B edits the photo with other render bytes and
    /// its backup trashes the earlier main while the edit of device A waits for its original.
    private func secondDeviceRetiresTheWaitingEarlierMain(marker: LineageMarker) async throws {
        harness = try EditScenarioHarness()
        let deviceB = try EditScenarioHarness(server: harness.server)
        defer { try? deviceB.cleanup() }
        // Both discover before either uploads, so both manifests name the earlier main.
        try await harness.enqueue()
        try await deviceB.enqueue()
        await harness.drain()
        await deviceB.drain()
        let earlier = try harness.liveMain()
        let source = try harness.library.candidate().snapshot.source
        XCTAssertEqual(deviceB.identities.record(for: source)?.remoteLinkID, earlier.nodeID)

        let entry = try await edit("device-a-render", omitOriginal: true)
        harness.clock.advance(by: 5)
        await harness.pass()
        let waiting = try XCTUnwrap(harness.queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertTrue(harness.journal.entry(for: source).superseded.contains(earlier))

        deviceB.library.edit("device-b-render", at: deviceB.clock.now)
        let editB = try await deviceB.enqueue()
        deviceB.clock.advance(by: 5)
        await deviceB.pass()
        XCTAssertEqual(deviceB.state(of: editB), .completed)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
        XCTAssertTrue(deviceB.journal.entry(for: source).retired.contains(earlier.nodeID))
        XCTAssertFalse(harness.server.links.contains { $0.personDeleted })
        func main(rendering bytes: String) throws -> PhotoUID {
            let hash = EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: Data(bytes.utf8))))
            return try XCTUnwrap(harness.activeMains.first { $0.contentHash == hash }).uid
        }
        switch marker {
        case .none: break
        case .otherDevice: try harness.server.markReplaces([earlier.nodeID], by: main(rendering: "device-b-render"))
        case .ownUpload: try harness.server.markReplaces([earlier.nodeID], by: main(rendering: "device-a-render"))
        }

        harness.library.makeOriginalAvailable()
        try harness.relaunch()
        harness.clock.advance(by: waiting.updatedAt.timeIntervalSince(harness.clock.now) + 1)
        await harness.pass()
        harness.clock.advance(by: 5)
        await harness.pass()
        // Both edits stay active mains, so the passes skip the quiescence check of one main.
        XCTAssertEqual(harness.state(of: entry)?.isTerminalSuccess, true)
        let settled = harness.journal.entry(for: source)
        XCTAssertFalse(settled.superseded.contains(earlier))
        // Only this device's intent proves its own trash; any other trash has an unknown author.
        XCTAssertEqual(settled.gone, [earlier.nodeID], "without proof the author of the trash is unknown")
        XCTAssertFalse(settled.retired.contains(earlier.nodeID))
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
        harness.assertRetired()
    }

    func testFailedTrashThenRelaunch() async throws {
        let earlier = try await firstBackup(live: true)
        let entry = try await edit("render-one")
        harness.server.failNextTrash()
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .active)
        XCTAssertFalse(harness.state(of: entry)?.isTerminalSuccess == true)
        XCTAssertEqual(harness.server.steps.filter { $0.action == "failed backup trash" }.count, 1)
        // A failed write cannot retire links that remain in the library.
        harness.assertRetired()
        let uploadedBeforeRetry = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        try harness.relaunch()
        harness.clock.advance(by: 8)
        await harness.drain()
        harness.check(harness.activeMains.count == 1, "U3 one main after the retry")
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploadedBeforeRetry,
            "A trash retry must not upload the compound again")
    }

    func testLocalDeletionKeepsTheRemoteBackup() async throws {
        let original = try await firstBackup()
        harness.library.delete()
        let entry = try harness.enqueueStaleRemovedAsset()
        harness.assertSafety()
        await harness.drain()
        XCTAssertNotEqual(harness.state(of: entry), .completed, "a deleted asset uploads nothing")
        XCTAssertEqual(try harness.liveMain(), original, "a local deletion keeps the backup")
    }

    func testADeviceIndexHoldsNoCompoundThatAppearedAfterItsFullBuild() async throws {
        harness = try EditScenarioHarness()
        // The second device opens the account before the first device backs the photo up.
        let deviceB = try EditScenarioHarness(server: harness.server, library: harness.library)
        defer { try? deviceB.cleanup() }
        try await harness.enqueue()
        await harness.drain()
        let original = try harness.liveMain()
        let uploads = deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count

        let discovered = try await deviceB.enqueue()
        XCTAssertEqual(deviceB.lastScan.alreadyBackedUp, 0, "the index of a device gains no record from events")
        deviceB.clock.advance(by: 5)
        await deviceB.drain()

        XCTAssertEqual(deviceB.state(of: discovered), .alreadyBackedUp, "the duplicate check adopts the photo")
        XCTAssertEqual(deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
        XCTAssertEqual(deviceB.identities.record(for: discovered.source)?.remoteLinkID, original.nodeID)
        deviceB.assertQuiescent()
    }

    func testRemoteProofOnSecondDeviceThenFirstEdit() async throws {
        try await remoteProofOnSecondDeviceThenFirstEdit(staleIndex: false)
    }

    func testRemoteProofOnSecondDeviceThenFirstEditWithStaleIndex() async throws {
        try await remoteProofOnSecondDeviceThenFirstEdit(staleIndex: true)
    }

    private func remoteProofOnSecondDeviceThenFirstEdit(staleIndex: Bool) async throws {
        harness = try EditScenarioHarness(staleLineageIndex: staleIndex)
        try await harness.enqueue()
        await harness.drain()
        let original = try harness.liveMain()
        let deviceB = try EditScenarioHarness(
            server: harness.server, library: harness.library, staleLineageIndex: staleIndex)
        defer { try? deviceB.cleanup() }
        let candidate = try deviceB.library.candidate()
        let identity = try XCTUnwrap(candidate.snapshot.externalIdentity)
        let proof = try await deviceB.server.findRemoteAssetProofs(for: [identity])
        XCTAssertEqual(proof[identity]?.resourceCount, candidate.snapshot.resourceCount)
        XCTAssertEqual(proof[identity]?.remoteLinkIDs, [original.nodeID])
        let uploadsBeforeDiscovery = deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let lookupsBeforeDiscovery = deviceB.server.remoteProofLookups.count
        let discovered = try await deviceB.enqueue()
        XCTAssertEqual(deviceB.server.remoteProofLookups.count, lookupsBeforeDiscovery + 1)
        XCTAssertEqual(deviceB.lastScan.alreadyBackedUp, 1)
        XCTAssertEqual(deviceB.state(of: discovered), .alreadyBackedUp)
        XCTAssertNil(deviceB.identities.record(for: candidate.snapshot.source))
        XCTAssertTrue(deviceB.journal.entry(for: candidate.snapshot.source).isEmpty)
        await deviceB.pass()
        XCTAssertEqual(
            deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploadsBeforeDiscovery,
            "The remote compound proof must avoid resolving or uploading bytes")

        if staleIndex {
            let before = try await deviceB.index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
            XCTAssertEqual(before.links, [original.nodeID])
        }
        deviceB.library.edit("device-b-edit", at: deviceB.clock.now)
        try await deviceB.enqueue()
        deviceB.clock.advance(by: 5)
        await deviceB.pass()
        deviceB.check(deviceB.activeMains.count == 1, "S1/U3 mains: the second device's edit must replace the original")
        deviceB.check(
            deviceB.server.links.first { $0.uid == original }?.state == .trashed,
            "N1 the remotely proven original must move to trash")
        await deviceB.drain()
        deviceB.assertQuiescent()
    }

    func testTwoDevicesReplaceAnEditOutsideTheSecondDevicesJournal() async throws {
        try await twoDevicesReplaceAnEditOutsideTheSecondDevicesJournal(staleIndex: false)
    }

    func testTwoDevicesReplaceAnEditOutsideTheSecondDevicesJournalWithStaleIndex() async throws {
        try await twoDevicesReplaceAnEditOutsideTheSecondDevicesJournal(staleIndex: true)
    }

    func testTwoDevicesReplaceLiveEditWithRenderedPairedVideo() async throws {
        try await twoDevicesReplaceAnEditOutsideTheSecondDevicesJournal(staleIndex: true, live: true)
    }

    private func twoDevicesReplaceAnEditOutsideTheSecondDevicesJournal(
        staleIndex: Bool, live: Bool = false
    ) async throws {
        harness = try EditScenarioHarness(live: live, staleLineageIndex: staleIndex)
        let deviceB = try EditScenarioHarness(
            server: harness.server, library: harness.library, staleLineageIndex: staleIndex)
        defer { try? deviceB.cleanup() }
        // Both discover before either uploads, so both run the real pipeline and acquire a manifest for O.
        try await harness.enqueue()
        try await deviceB.enqueue()
        await harness.drain()
        await deviceB.drain()
        let source = try harness.library.candidate().snapshot.source
        let original = try harness.liveMain()
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, original.nodeID)
        XCTAssertEqual(deviceB.identities.record(for: source)?.remoteLinkID, original.nodeID)
        XCTAssertNotEqual(deviceB.directory, harness.directory)

        if live { harness.library.renderPairedVideo("device-a-rendered-video") }
        try await edit("device-a-edit-e")
        await harness.drain()
        let editE = try harness.liveMain()
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)
        XCTAssertEqual(deviceB.identities.record(for: source)?.remoteLinkID, original.nodeID)
        XCTAssertFalse(deviceB.journal.entry(for: source).retired.contains(original.nodeID))
        if staleIndex {
            let stale = try await deviceB.index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
            XCTAssertFalse(stale.links.contains(editE.nodeID), "The device must still see its earlier snapshot")
        }
        deviceB.clock.advance(by: 15)
        if live { deviceB.library.renderPairedVideo("device-b-rendered-video") }
        deviceB.library.edit("device-b-edit-f", at: deviceB.clock.now)
        let editF = try await deviceB.enqueue()
        deviceB.clock.advance(by: 5)
        await deviceB.pass()
        XCTAssertEqual(deviceB.state(of: editF), .completed, "Edit F must finish before checking replacement of E")
        let editFHash = EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: Data("device-b-edit-f".utf8))))
        XCTAssertTrue(
            deviceB.activeMains.contains { $0.contentHash == editFHash },
            "Edit F's bytes must exist in an active main before checking replacement of E")
        deviceB.check(
            deviceB.state(of: editF) != .skippedRemoteDeletion, "U2 another device's trash is not person deletion")
        deviceB.check(
            deviceB.server.links.first { $0.uid == editE }?.state == .trashed,
            "N2 the second device must trash the first device's edit E")
        if staleIndex {
            deviceB.clock.advance(by: 15)
            let refreshed = try await deviceB.index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
            XCTAssertEqual(
                refreshed.links, Set(deviceB.activeMains.map(\.linkID)),
                "The index must converge to the server after the replacement pass")
            XCTAssertFalse(
                deviceB.server.steps.contains {
                    $0.trashedByBackup.contains(where: { $0 != original.nodeID && $0 != editE.nodeID })
                })
        }
        XCTAssertFalse(deviceB.server.links.contains { $0.personDeleted })
        await deviceB.drain()
        deviceB.assertQuiescent()
    }

    func testOlderOfflineEditUploadsNextToANewerEditOfAnotherDevice() async throws {
        try await divergentOfflineEdits(otherDeviceEditIsNewer: true)
    }

    func testNewerOfflineEditStillReplacesAnOlderEditOfAnotherDevice() async throws {
        try await divergentOfflineEdits(otherDeviceEditIsNewer: false)
    }

    /// Device A edits the photo while offline. Device B edits it as well and backs its edit up first.
    private func divergentOfflineEdits(otherDeviceEditIsNewer: Bool) async throws {
        harness = try EditScenarioHarness()
        // Each device has its own Photos library here. With one shared library, device B's edit would also be the
        // current version on device A, so device A could not hold an older edit of its own.
        let deviceB = try EditScenarioHarness(server: harness.server)
        defer { try? deviceB.cleanup() }
        try await harness.enqueue()
        try await deviceB.enqueue()
        await harness.drain()
        await deviceB.drain()
        let original = try harness.liveMain()
        let source = try harness.library.candidate().snapshot.source
        XCTAssertEqual(deviceB.identities.record(for: source)?.remoteLinkID, original.nodeID)

        // Two offline edits give the photo on device A a later generation than the single edit on device B, so S6
        // can compare the versions of both libraries.
        harness.library.edit("device-a-draft", at: harness.clock.now)
        let editTimeA = harness.clock.now
        harness.library.edit("device-a-offline-edit", at: editTimeA)
        let editTimeB = editTimeA.addingTimeInterval(60)
        deviceB.library.edit("device-b-edit", at: editTimeB)
        try await deviceB.enqueue()
        deviceB.clock.advance(by: 5)
        await deviceB.pass()
        let headB = try XCTUnwrap(deviceB.activeMains.first)
        XCTAssertEqual(deviceB.activeMains.count, 1, "device B's edit must replace the original first")
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)
        // The server keeps the ModificationTime that Photos set when the person saved the edit.
        let olderTime = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.modificationDate)
        harness.server.setModificationDate(otherDeviceEditIsNewer ? editTimeB : olderTime, of: headB.uid)
        if otherDeviceEditIsNewer {
            // An answer to an earlier deletion question must not outlive the proof that the photo is live.
            try harness.journal.keepDeleted(for: source)
        }

        let steps = harness.server.steps.count
        let entryA = try await harness.enqueue()
        harness.clock.advance(by: 5)
        if otherDeviceEditIsNewer {
            // The duplicate check itself ends the earlier choice, before any upload succeeds.
            let decision = try await harness.primaryDecision(for: entryA)
            XCTAssertTrue(decision.uploadsBytes)
            XCTAssertNil(harness.journal.entry(for: source).keptDeleted, "a newer version proves the photo live")
        }
        await harness.pass()
        XCTAssertEqual(harness.state(of: entryA), .completed, "device A's edit must upload without a deletion question")
        let journal = harness.journal.entry(for: source)
        XCTAssertNil(journal.deletionCheckStartedAt)
        let headA = try XCTUnwrap(harness.identities.record(for: source)?.remoteLinkID)
        let trashed = harness.server.steps.dropFirst(steps).flatMap(\.trashedByBackup)
        if otherDeviceEditIsNewer {
            XCTAssertNil(journal.keptDeleted, "a newer version on the server proves the photo live")
            XCTAssertEqual(
                Set(harness.activeMains.map(\.linkID)), [headA, headB.linkID], "both versions of the photo stay")
            XCTAssertEqual(trashed, [], "device A must not trash the newer version of device B")
        } else {
            XCTAssertEqual(harness.activeMains.map(\.linkID), [headA], "the newer edit replaces the older one")
            XCTAssertTrue(trashed.contains(headB.linkID), "device A must trash the older version of device B")
        }
        XCTAssertFalse(harness.server.links.contains { $0.personDeleted })
        harness.assertCurrentManifest()
    }

    func testUndoRestoresTheExactEarlierRevision() async throws {
        let original = try await firstBackup()
        let earlierCandidate = try harness.library.candidate()
        let originalHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        try await edit("render-before-exact-undo")
        await harness.drain()
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)

        harness.library.undo(at: harness.clock.now, restoreEarlierDate: true)
        let undoCandidate = try harness.library.candidate()
        XCTAssertEqual(undoCandidate.snapshot.revision, earlierCandidate.snapshot.revision)
        XCTAssertEqual(undoCandidate.snapshot.externalIdentity, earlierCandidate.snapshot.externalIdentity)
        XCTAssertEqual(undoCandidate.snapshot.editRevision, earlierCandidate.snapshot.editRevision)
        try await harness.enqueue()
        await harness.pass()
        XCTAssertTrue(
            harness.activeMains.contains { $0.contentHash == originalHash },
            "S1 the main must hold the current version after exact-revision undo")
        await harness.drain()
        harness.assertQuiescent()
    }

    func testMissingRenderBeyondTheReadinessDeadline() async throws {
        try await missingRender(timestampPresent: true)
    }

    func testMissingRenderWithoutAnAdjustmentTimestamp() async throws {
        try await missingRender(timestampPresent: false)
    }

    private func missingRender(timestampPresent: Bool) async throws {
        harness = try EditScenarioHarness()
        harness.library.edit(
            "late-render", at: harness.clock.now, renderPresent: false, timestampPresent: timestampPresent)
        try await harness.enqueue()
        let uploadsBeforeEdit = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        if timestampPresent {
            await harness.pass()
            XCTAssertEqual(harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploadsBeforeEdit)
        }
        if timestampPresent { harness.clock.advance(by: 121) }
        await harness.pass()
        // Photos may never list a rendered file, so the backup stores what exists instead of waiting forever.
        XCTAssertEqual(harness.activeMains.count, 1, "the photo is backed up with its original")
        let unrendered = try harness.library.candidate()
        harness.library.publishRender("late-render")
        XCTAssertNotEqual(
            try harness.library.candidate().snapshot.revision, unrendered.snapshot.revision,
            "the rendered file re-opens the photo although its dates did not move")
        try await harness.enqueue()
        harness.clock.advance(by: 15)
        await harness.pass()
        harness.assertQuiescent()
    }

    func testWaitingOriginalThenPersonDeletesTheEditAndMetadataDrifts() async throws {
        let original = try await firstBackup()
        try await edit("deleted-edit-with-waiting-original", omitOriginal: true)
        harness.clock.advance(by: 5)
        await harness.pass()
        let source = try harness.library.candidate().snapshot.source
        let deletedEdit = try XCTUnwrap(harness.activeMains.first { $0.generation == 2 }).uid
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .active)
        XCTAssertTrue(harness.journal.entry(for: source).superseded.contains(original))
        harness.server.personTrash(deletedEdit)
        harness.assertSafety()
        let uploadsBeforeDrift = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let bytesBeforeDrift = try XCTUnwrap(harness.library.snapshot.first).current
        let revisionBeforeDrift = try harness.library.candidate().snapshot.revision
        harness.library.changeModificationDate()
        XCTAssertEqual(try XCTUnwrap(harness.library.snapshot.first).current, bytesBeforeDrift)
        XCTAssertNotEqual(try harness.library.candidate().snapshot.revision, revisionBeforeDrift)
        let drifted = try await harness.enqueue()
        XCTAssertEqual(drifted.state, .checking, "Metadata drift must require a backend check during discovery")
        let decision = try await harness.primaryDecision(for: drifted)
        XCTAssertEqual(decision, .skip(.knownFromManifest, remoteLinkID: deletedEdit.nodeID))
        await harness.pass()
        // The unchanged digest and capture date reuse the manifest; this path does not revalidate the deleted main.
        XCTAssertEqual(
            harness.state(of: drifted), .skippedRemoteDeletion,
            "the person trashed the edit, so the photo is not backed up")
        let settled = try XCTUnwrap(harness.queue.entry(for: drifted.source, revision: drifted.revision))
        XCTAssertEqual(settled.attempts, 0)
        XCTAssertNil(settled.remoteCommitReconciliation)
        // The intentionally waiting original can remain. Only a new upload after deletion violates this scenario.
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploadsBeforeDrift,
            "S5 metadata drift after the person's deletion must upload nothing")
        harness.check(
            harness.server.links.first { $0.uid == deletedEdit }?.state == .trashed,
            "S5 metadata drift must preserve the person's deletion")
    }

    func testThreeEditsWithTheFirstUploadInFlight() async throws {
        let original = try await firstBackup()
        let firstEdit = try await edit("in-flight-edit-one")
        harness.clock.advance(by: 5)
        await harness.server.uploadGate.arm(generation: 2)
        let runningPass = harness.startPass()
        await harness.server.uploadGate.waitUntilSuspended()
        // The first render's descriptor and bytes are already resolved. Two newer revisions arrive before commit.
        do {
            try await edit("in-flight-edit-two")
            try await edit("in-flight-edit-three")
            harness.clock.advance(by: 5)
        } catch {
            await harness.server.uploadGate.release()
            _ = await runningPass.value
            throw error
        }
        await harness.server.uploadGate.release()
        _ = await runningPass.value
        await harness.pass()
        await harness.drain()
        XCTAssertTrue(
            harness.library.materializations.contains {
                $0.resolvedGeneration == 2 && $0.currentGeneration == 4 && $0.digestChanged
            }, "The first compound must materialize changed secondary bytes after its primary upload")
        XCTAssertTrue(
            harness.library.resolutions.contains {
                $0.revision == firstEdit.revision && $0.state == .queuedForUpload && $0.attempts == 0
            }, "The changed secondary must requeue the first revision without completing it or spending a retry")
        let firstMain = try XCTUnwrap(harness.server.links.first { $0.mainLinkID == nil && $0.generation == 2 })
        XCTAssertFalse(
            harness.server.links.contains { $0.mainLinkID == firstMain.linkID && $0.generation == 2 },
            "The first main must not receive eagerly exported stale secondaries")
        harness.assertCurrentManifest()
        XCTAssertEqual(harness.activeMains.count, 1)
        XCTAssertEqual(harness.activeMains.first?.generation, 4, "The third edit must hold the sole active main")
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)
        XCTAssertTrue(
            harness.server.links.filter { $0.mainLinkID == nil && $0.generation < 4 }.allSatisfy {
                $0.state == .trashed
            },
            "Every earlier uploaded main must leave the library")
    }

    func testSecondEditWhenRelatedLookupRejectsTrashedMains() async throws {
        let original = try await firstBackup(live: true)
        try await edit("first-edit-with-strict-related-endpoint")
        await harness.drain()
        let edited = try harness.liveMain()
        let originalHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        XCTAssertTrue(
            harness.server.links.contains {
                $0.mainLinkID == edited.nodeID && $0.state == .active && $0.contentHash == originalHash
            }, "An active original-content row must remain under the edit before undo")
        harness.server.personTrash(edited)
        harness.server.relatedLookupFailsForTrashedMain = true
        let uploads = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let undone = try await undo()
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.state(of: undone), .discovered)
        harness.clock.advance(by: 600)
        await harness.pass()
        let row = try XCTUnwrap(harness.queue.entry(for: undone.source, revision: undone.revision))
        XCTAssertTrue(
            harness.server.rejectedTrashedMainLookupIDs.isEmpty,
            "the check must not ask for the related photos of a trashed main")
        XCTAssertEqual(row.state, .failedPermanent)
        XCTAssertEqual(BackupIssueRecord.decode(row.lastError)?.kind, .deletedElsewhere)
        XCTAssertEqual(harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
    }

    func testOtherDeviceReplacesDuringDeletionWaitAndSecondCheckAdopts() async throws {
        harness = try EditScenarioHarness()
        let deviceB = try EditScenarioHarness(
            server: harness.server, library: harness.library, staleLineageIndex: true)
        defer { try? deviceB.cleanup() }
        try await harness.enqueue()
        try await deviceB.enqueue()
        await harness.drain()
        await deviceB.drain()
        harness.clock.advance(by: 200)
        deviceB.clock.advance(by: 200)
        _ = try await deviceB.index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
        harness.library.edit("device-a-replacement", at: harness.clock.now.addingTimeInterval(-121))
        try await harness.enqueue()
        await harness.pass()
        harness.library.edit("current-edit", at: deviceB.clock.now.addingTimeInterval(-121))
        let waiting = try await deviceB.enqueue()
        await deviceB.pass()
        XCTAssertEqual(deviceB.state(of: waiting), .discovered)
        XCTAssertNotNil(deviceB.journal.entry(for: waiting.source).deletionCheckStartedAt)
        try await harness.enqueue()
        await harness.pass()
        let uploads = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        deviceB.clock.advance(by: 120)
        await deviceB.pass()
        XCTAssertEqual(deviceB.state(of: waiting), .alreadyBackedUp)
        XCTAssertEqual(harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
        XCTAssertNil(deviceB.journal.entry(for: waiting.source).deletionCheckStartedAt)
    }

    func testManualRetriesCannotShortenDeletionWaitAndRelaunchKeepsTheBound() async throws {
        let main = try await firstBackup()
        harness.server.personTrash(main)
        let entry = try await edit("deleted-edit")
        harness.clock.advance(by: 5)
        await harness.pass()
        let started = try XCTUnwrap(harness.journal.entry(for: entry.source).deletionCheckStartedAt)
        for _ in 0..<5 {
            harness.clock.advance(by: 10)
            _ = await harness.makeRetryableWorkEligibleNow()
            await harness.pass()
            XCTAssertEqual(harness.state(of: entry), .discovered)
            XCTAssertEqual(harness.journal.entry(for: entry.source).deletionCheckStartedAt, started)
        }
        try harness.relaunch()
        harness.clock.advance(by: 600)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .failedPermanent)
        _ = await harness.makeRetryableWorkEligibleNow()
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .failedPermanent)
    }

    func testKeepDeletedAppliesToLaterEditsAndRestoreClearsChoice() async throws {
        let main = try await firstBackup()
        harness.server.personTrash(main)
        let entry = try await edit("deleted-edit")
        harness.clock.advance(by: 5)
        await harness.pass()
        try harness.journal.keepDeleted(for: entry.source)
        let next = try await edit("later-deleted-edit")
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.state(of: next), .skippedRemoteDeletion)
        XCTAssertTrue(harness.journal.entry(for: entry.source).keptDeleted == true)
        harness.server.personRestore(main)
        // Until the next pass the earlier rows still read skipped; the pass below backs the photo up and clears them.
        harness.library.edit("restored-edit", at: harness.clock.now)
        let restored = try await harness.enqueue()
        harness.clock.advance(by: 600)
        await harness.pass()
        harness.assertSafety()
        XCTAssertEqual(harness.state(of: restored), .completed)
        XCTAssertNil(harness.queue.entry(for: next.source, revision: next.revision))
        XCTAssertNil(harness.journal.entry(for: entry.source).keptDeleted)
        XCTAssertNil(harness.journal.entry(for: entry.source).deletionCheckStartedAt)
    }

    func testAParkedRevisionLeavesOnceALaterRevisionIsBackedUp() async throws {
        let main = try await firstBackup()
        harness.server.personTrash(main)
        let parked = try await edit("deleted-edit")
        harness.clock.advance(by: 5)
        await harness.pass()
        harness.clock.advance(by: 600)
        await harness.pass()
        XCTAssertEqual(harness.state(of: parked), .failedPermanent)
        harness.server.personRestore(main)
        harness.library.edit("edit-after-restore", at: harness.clock.now)
        let later = try await harness.enqueue()
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.state(of: later), .completed)
        XCTAssertNil(harness.queue.entry(for: parked.source, revision: parked.revision), "nothing asks about it")
    }

    func testRestoreDuringDeletionWaitSettlesWithoutParking() async throws {
        let main = try await firstBackup()
        harness.server.personTrash(main)
        let entry = try await edit("deleted-edit")
        harness.clock.advance(by: 5)
        await harness.pass()
        harness.server.personRestore(main)
        harness.clock.advance(by: 120)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertNil(harness.journal.entry(for: entry.source).deletionCheckStartedAt)
    }

    func testServerTrashRestoreAndEmptyTrashRules() async throws {
        let original = try await firstBackup(live: true)
        let contentHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        let related = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: original.nodeID)
        XCTAssertEqual(related.count, 1)
        let identity = try XCTUnwrap(harness.library.candidate().snapshot.externalIdentity)
        let compoundProof = try await harness.server.findRemoteAssetProofs(for: [identity])
        XCTAssertEqual(compoundProof[identity]?.resourceCount, 2)
        XCTAssertEqual(Set(compoundProof[identity]?.remoteLinkIDs ?? []), related.union([original.nodeID]))
        let albums = try await harness.server.albums(containing: original)
        for albumID in ["shared-album", "unknown-album"] {
            do {
                try await harness.server.addPhotos([original], toOwnAlbum: albumID)
                XCTFail("An album outside the known own-volume albums must fail")
            } catch {}
        }
        let unchangedAlbums = try await harness.server.albums(containing: original)
        XCTAssertEqual(unchangedAlbums, albums, "A rejected album write must not invent a membership")
        harness.server.personTrash(original)
        harness.assertSafety()
        let trashedContent = try await harness.server.findDuplicate(contentHash: contentHash)
        XCTAssertNil(trashedContent, "Content lookup returns only active records")
        let trashedProof = try await harness.server.findRemoteAssetProofs(for: [identity])
        XCTAssertNil(trashedProof[identity], "An orphan under a trashed main cannot prove an active compound")
        let trashedRelated = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: original.nodeID)
        XCTAssertEqual(trashedRelated, related, "A trashed main still answers with its related files")
        let trashed = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(trashed.first?.linkState, .trashed)
        let orphan = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.MOV)"])
        XCTAssertEqual(orphan.first?.linkState, .active)
        harness.server.personRestore(original)
        harness.assertSafety()
        let active = try await harness.server.activeUIDs(among: [original])
        XCTAssertEqual(active, [original])
        let activeContent = try await harness.server.findDuplicate(contentHash: contentHash)
        XCTAssertEqual(activeContent?.linkID, original.nodeID)
        XCTAssertEqual(activeContent?.linkState, .active)
        harness.server.personTrash(original)
        harness.assertSafety()
        harness.server.personEmptyTrash()
        harness.assertSafety()
        XCTAssertTrue(harness.server.links.allSatisfy { $0.state == .deleted })
        let removed = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)", "nh(IMG_1.MOV)"])
        XCTAssertTrue(removed.isEmpty)
        for mainLinkID in [original.nodeID, "unknown-main"] {
            do {
                _ = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
                XCTFail("An unknown or permanently deleted main must not answer with an empty set")
            } catch {}
        }
    }
}
