import AlbumSyncCore
import CryptoKit
import Foundation
import PhotosCore
import UploadCore
import XCTest

/// A different photo's unfinished upload can occupy the same filename without proving a backup of this photo.
final class AlbumSyncForeignDraftReasonScenarioTests: XCTestCase {
    func testOneHundredDifferentPhotosWithTheSameFilenameAllUploadAndJoinTheAlbum() async throws {
        let device = try EditScenarioHarness(basename: "IMG_0001")
        defer { try? device.cleanup() }
        for number in 2...100 { device.library.add("asset-\(number)", basename: "IMG_0001") }
        let assets = device.library.snapshot
        XCTAssertEqual(assets.count, 100)
        XCTAssertEqual(Set(assets.map(\.current)).count, 100, "Every photo has different bytes")
        XCTAssertTrue(device.server.links.isEmpty, "No existing photo or foreign draft is seeded")

        let report = try await device.syncAlbum(
            assets.map(\.identifier), backup: EditScenarioAlbumBackup(device: device))

        XCTAssertEqual(report.attached, 100)
        XCTAssertEqual(report.alreadyMember, 0)
        XCTAssertEqual(report.unattachable, 0)
        XCTAssertEqual(report.trashedSkipped, 0)
        XCTAssertEqual(report.attachFailed, 0)
        XCTAssertEqual(report.incomplete, 0)
        XCTAssertTrue(report.isFullySynced)
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertEqual(device.server.uploadRequestCount, 100)
        XCTAssertEqual(device.server.links.count, 100)
        XCTAssertTrue(device.server.links.allSatisfy { $0.state == .active && $0.mainLinkID == nil })
        XCTAssertEqual(Set(device.server.links.map(\.nameHash)), ["nh(IMG_0001.HEIC)"])
        XCTAssertEqual(Set(device.server.links.map(\.contentHash)).count, 100)
        let members = try await device.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members.count, 100)
        XCTAssertEqual(device.queue.entries(in: .completed, updatedBefore: .distantFuture, limit: 101).count, 100)
        var savedLinkIDs: Set<String> = []
        for asset in assets {
            let record = try XCTUnwrap(device.identities.record(for: asset.source))
            XCTAssertEqual(record.outcome, "uploaded")
            savedLinkIDs.insert(try XCTUnwrap(record.remoteLinkID))
        }
        XCTAssertEqual(savedLinkIDs, members, "Every distinct source keeps its own uploaded photo")
    }

    func testForeignDraftReasonNamesTheSharedFilenameThroughAlbumSync() async throws {
        try await assertReason(
            stale: false, key: "backup.issue_remote_draft",
            english: "An unfinished upload with the same file name is blocking this photo.",
            german: "Ein unvollständiger Upload mit demselben Dateinamen blockiert dieses Foto.")
    }

    func testStaleForeignDraftReasonNamesTheSharedFilenameThroughAlbumSync() async throws {
        try await assertReason(
            stale: true, key: "backup.issue_remote_draft_stale",
            english: "An unfinished upload with the same file name is still blocking this photo.",
            german: "Ein unvollständiger Upload mit demselben Dateinamen blockiert dieses Foto weiterhin.")
    }

    private func assertReason(
        stale: Bool, key: String.LocalizationValue, english: String, german: String
    ) async throws {
        let device = try EditScenarioHarness()
        defer { try? device.cleanup() }
        let asset = try XCTUnwrap(device.library.snapshot.first)
        let draft = device.server.seedDraft(
            name: "IMG_1.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("another-photo".utf8))),
            clientUID: "other-uploader")
        let before = try XCTUnwrap(device.server.links.first { $0.uid == draft })
        XCTAssertNotEqual(
            before.contentHash, EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: asset.current))))

        let base = EditScenarioAlbumBackup(device: device)
        let backup: any AlbumSyncBackupExecuting = stale ? RecheckedAlbumBackup(base: base) : base
        let report = try await device.syncAlbum([asset.identifier], backup: backup)

        XCTAssertEqual(report.attached, 0)
        XCTAssertEqual(report.unattachable, 1)
        XCTAssertFalse(report.isFullySynced)
        XCTAssertEqual(report.problems.count, 1)
        let problem = try XCTUnwrap(report.problems.first)
        XCTAssertEqual(problem.source, asset.source)
        XCTAssertEqual(problem.issue, stale ? .remoteDraftStale : .remoteDraft)
        let rows = device.queue.entries(
            in: stale ? .failedPermanent : .blockedByDraft, updatedBefore: .distantFuture, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attempts, stale ? 4 : 1)
        XCTAssertEqual(
            device.server.links.first { $0.uid == draft }?.duplicate, before.duplicate,
            "The foreign draft stays unchanged")
        XCTAssertEqual(device.server.uploadRequestCount, 0)
        XCTAssertNil(device.identities.record(for: asset.source)?.remoteLinkID)

        // Assert the reason emitted by the real runner/report route, independently of its catalog key.
        let expected = L10n.string("action.cancel") == "Abbrechen" ? german : english
        XCTAssertEqual(problem.reason, expected, "A same-name foreign draft need not belong to this photo")
        // Both compiled translations must match the same requirement; no source-text search supplies this oracle.
        for (language, text) in [("en", english), ("de", german)] {
            let path = try XCTUnwrap(L10n.resourceBundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(String(localized: key, bundle: bundle, locale: Locale(identifier: language)), text)
        }
    }
}

/// Reaches the real runner's fourth-attempt state before the real Album Sync report is projected.
/// Normal Sync now resets its scratch queue; this fixture proves the stale reason, not aging across sync runs.
private struct RecheckedAlbumBackup: AlbumSyncBackupExecuting {
    let base: EditScenarioAlbumBackup

    func ensureBackedUp(
        localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        _ = try await base.ensureBackedUp(localIdentifiers: localIdentifiers, onProgress: onProgress)
        for _ in 0..<3 {
            base.device.clock.advance(by: 61)
            await base.device.pass()
        }
        return try AlbumSyncBackupReport.read(from: base.device.queue, localIdentifiers: localIdentifiers)
    }

    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        try await base.remoteProofLinks(for: localIdentifiers)
    }

    func stop() async { await base.stop() }
}
