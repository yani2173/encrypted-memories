import AlbumSyncCore
import CryptoKit
import Foundation
import PhotosCore
import UploadCore
import XCTest

/// Public Album Sync entry point with the real backup runner, pipeline, SQLite stores and shared scenario server.
final class AlbumSyncDeletedPhotoScenarioTests: XCTestCase {
    func testTrashAfterReinstallAndLaterPermanentDeletionNeverCreateAnotherUpload() async throws {
        let first = try EditScenarioHarness()
        defer { try? first.cleanup() }
        try await first.enqueue()
        await first.drain()
        let original = try first.liveMain()
        first.server.personTrash(original)
        let reinstalled = try EditScenarioHarness(server: first.server, library: first.library)
        defer { try? reinstalled.cleanup() }
        XCTAssertNil(reinstalled.identities.record(for: .init(kind: .photoLibraryAsset, identifier: "asset-1")))

        let trashReport = try await reinstalled.syncAlbum(
            ["asset-1"], backup: EditScenarioAlbumBackup(device: reinstalled))
        XCTAssertEqual(trashReport.trashedSkipped, 1)
        XCTAssertEqual(trashReport.problems.first?.issue, .remoteDeletion)
        XCTAssertFalse(trashReport.isFullySynced)
        XCTAssertEqual(first.server.uploadRequestCount, 1)
        XCTAssertEqual(
            reinstalled.identities.record(for: .init(kind: .photoLibraryAsset, identifier: "asset-1"))?.remoteLinkID,
            original.nodeID)

        first.server.personEmptyTrash()
        for _ in 0..<3 {
            let report = try await reinstalled.syncAlbum(
                ["asset-1"], backup: EditScenarioAlbumBackup(device: reinstalled))
            XCTAssertFalse(report.isFullySynced)
            XCTAssertEqual(report.problems.first?.issue, .remoteDeletion)
            XCTAssertEqual(report.problems.first?.reason, L10n.string("backup.state_skipped_remote_deletion"))
            XCTAssertEqual(first.server.uploadRequestCount, 1, "ordinary retries and later runs create no consent")
        }
    }

    func testSameContentInTrashUnderAnotherNameDoesNotProvePermanentDeletion() async throws {
        let device = try EditScenarioHarness()
        defer { try? device.cleanup() }
        try await device.enqueue()
        await device.drain()
        let original = try device.liveMain()
        let asset = try XCTUnwrap(device.library.snapshot.first)
        device.server.personTrash(original)
        device.server.personEmptyTrash()
        let other = device.server.seedDraft(
            name: "other-name.HEIC", digest: Data(Insecure.SHA1.hash(data: asset.current)), clientUID: "foreign")
        device.server.personTrash(other)
        let report = try await device.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: device))
        XCTAssertEqual(report.unattachable, 0, "absence from a NameHashes query cannot prove content absence")
        XCTAssertEqual(report.attachFailed, 1, "unknown keeps the existing attachment path")
        XCTAssertFalse(report.problems.contains { $0.issue == .remoteDeletion })
        XCTAssertEqual(device.server.uploadRequestCount, 1)
    }

    func testMatchingExplicitTrashWinsWhileACrossNameActiveCopyExistsWithoutAnotherUpload() async throws {
        let first = try EditScenarioHarness()
        defer { try? first.cleanup() }
        try await first.enqueue()
        await first.drain()
        let original = try first.liveMain()
        first.server.personTrash(original)
        let asset = try XCTUnwrap(first.library.snapshot.first)
        _ = first.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
        let second = try EditScenarioHarness(server: first.server, library: first.library)
        defer { try? second.cleanup() }
        let before = first.server.uploadRequestCount
        let report = try await second.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: second))
        XCTAssertEqual(report.trashedSkipped, 1)
        XCTAssertEqual(report.problems.first?.issue, .remoteDeletion)
        XCTAssertEqual(first.server.uploadRequestCount - before, 0)
        let saved = try XCTUnwrap(second.identities.record(for: asset.source))
        XCTAssertEqual(saved.remoteLinkID, original.nodeID)
        XCTAssertFalse(saved.provesUpload)
    }

    func testKnownTrashPrecedesCachedActiveAdoptionUntilTheTrashEntryDisappears() async throws {
        let first = try EditScenarioHarness()
        defer { try? first.cleanup() }
        try await first.enqueue()
        await first.drain()
        let original = try first.liveMain()
        first.server.personTrash(original)
        let device = try EditScenarioHarness(server: first.server, library: first.library)
        defer { try? device.cleanup() }
        let backup = EditScenarioAlbumBackup(device: device)
        _ = try await device.syncAlbum(["asset-1"], backup: backup)
        XCTAssertEqual(
            device.identities.record(for: .init(kind: .photoLibraryAsset, identifier: "asset-1"))?.outcome,
            "duplicateTrashed")

        let asset = try XCTUnwrap(first.library.snapshot.first)
        device.library.add("asset-2", basename: "Other", original: asset.current)
        try await device.enqueue("asset-2")
        await device.drain()
        let otherSource = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-2")
        let active = try XCTUnwrap(device.identities.record(for: otherSource))
        XCTAssertTrue(active.provesUpload)
        let before = first.server.uploadRequestCount
        let coexistence = try await device.syncAlbum(["asset-1"], backup: backup)
        XCTAssertEqual(coexistence.trashedSkipped, 1)
        XCTAssertEqual(coexistence.problems.first?.issue, .remoteDeletion)
        let saved = try XCTUnwrap(device.identities.record(for: asset.source))
        XCTAssertEqual(saved.remoteLinkID, original.nodeID)
        XCTAssertFalse(saved.provesUpload)
        XCTAssertEqual(first.server.uploadRequestCount, before)

        first.server.personEmptyTrash()
        let convergence = try await device.syncAlbum(["asset-1"], backup: backup)
        XCTAssertTrue(convergence.isFullySynced)
        XCTAssertTrue(convergence.problems.isEmpty)
        let settled = try XCTUnwrap(device.identities.record(for: asset.source))
        XCTAssertEqual(settled.remoteLinkID, active.remoteLinkID)
        XCTAssertTrue(settled.provesUpload)
        XCTAssertEqual(first.server.uploadRequestCount, before)
    }

    func testUncachedSourceChecksExplicitTrashBeforeAdoptingAnotherCachedActiveCopy() async throws {
        let first = try EditScenarioHarness()
        defer { try? first.cleanup() }
        try await first.enqueue()
        await first.drain()
        let original = try first.liveMain()
        first.server.personTrash(original)
        let device = try EditScenarioHarness(server: first.server, library: first.library)
        defer { try? device.cleanup() }
        let asset = try XCTUnwrap(first.library.snapshot.first)
        // This device initially sees only the other source. The original becomes available afterwards.
        device.library.delete("asset-1")
        device.library.add("asset-2", basename: "Other", original: asset.current)
        try await device.enqueue("asset-2")
        await device.drain()
        let active = try XCTUnwrap(
            device.identities.record(for: .init(kind: .photoLibraryAsset, identifier: "asset-2")))
        XCTAssertTrue(active.provesUpload)
        XCTAssertNil(device.identities.record(for: asset.source))
        device.library.add("asset-1", original: asset.current)
        let before = first.server.uploadRequestCount
        let backup = EditScenarioAlbumBackup(device: device)
        let coexistence = try await device.syncAlbum(["asset-1"], backup: backup)
        XCTAssertEqual(coexistence.trashedSkipped, 1)
        XCTAssertFalse(coexistence.isFullySynced)
        XCTAssertEqual(coexistence.problems.first?.issue, .remoteDeletion)
        let saved = try XCTUnwrap(device.identities.record(for: asset.source))
        XCTAssertEqual(saved.remoteLinkID, original.nodeID)
        XCTAssertFalse(saved.provesUpload)
        XCTAssertEqual(first.server.uploadRequestCount, before)

        first.server.personEmptyTrash()
        let convergence = try await device.syncAlbum(["asset-1"], backup: backup)
        XCTAssertTrue(convergence.isFullySynced)
        XCTAssertTrue(convergence.problems.isEmpty)
        XCTAssertEqual(device.identities.record(for: asset.source)?.remoteLinkID, active.remoteLinkID)
        XCTAssertTrue(try XCTUnwrap(device.identities.record(for: asset.source)).provesUpload)
        XCTAssertEqual(first.server.uploadRequestCount, before)
    }

    func testRestoreConvergesToTheSameCopyWithoutUploading() async throws {
        let first = try EditScenarioHarness()
        defer { try? first.cleanup() }
        try await first.enqueue()
        await first.drain()
        let original = try first.liveMain()
        first.server.personTrash(original)
        let second = try EditScenarioHarness(server: first.server, library: first.library)
        defer { try? second.cleanup() }
        _ = try await second.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: second))
        first.server.personRestore(original)
        let restored = try await second.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: second))
        XCTAssertTrue(restored.isFullySynced)
        XCTAssertEqual(restored.attached, 1)
        XCTAssertTrue(restored.problems.isEmpty)
        XCTAssertEqual(first.server.uploadRequestCount, 1)
        let members = try await first.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members, [original.nodeID])
    }

    func testPartialOrFailedMetadataKeepsTheActiveCopyAttachable() async throws {
        for fails in [false, true] {
            let device = try EditScenarioHarness()
            defer { try? device.cleanup() }
            try await device.enqueue()
            await device.drain()
            let original = try device.liveMain()
            if fails {
                device.server.configureOptionalReads(visibilityFails: true)
            } else {
                device.server.omitVisibility(of: [original.nodeID])
            }
            let report = try await device.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: device))
            XCTAssertEqual(report.attached, 1)
            XCTAssertTrue(report.isFullySynced)
            XCTAssertTrue(report.problems.isEmpty)
            XCTAssertEqual(device.server.uploadRequestCount, 1)
        }
    }
}
