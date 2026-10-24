import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import AlbumSyncCore
@testable import PhotoLibraryBackupAdapter

/// A photo that is in the Proton album while a part of it is not backed up, such as the video of a Live Photo,
/// shows as "needs attention". The existing "not in the album" texts keep their wording.
final class AlbumSyncIncompletePhotoTests: XCTestCase {
    private var packageCatalog: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings")
    }

    /// All non-empty values of one language: a direct string, or every plural form.
    private func values(of key: String, language: String) throws -> [String: String] {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: packageCatalog)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key \(key)")
        let localization = try XCTUnwrap(
            (entry["localizations"] as? [String: Any])?[language] as? [String: Any], "\(key) has no \(language)")
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return ["": value]
        }
        let plural = try XCTUnwrap(
            (localization["variations"] as? [String: Any])?["plural"] as? [String: Any],
            "\(key) has no \(language) text")
        return plural.compactMapValues { ($0 as? [String: Any])?["stringUnit"] as? [String: Any] }
            .compactMapValues { $0["value"] as? String }
    }

    func testTheAttentionTextsExistInEnglishAndGerman() throws {
        XCTAssertEqual(
            try values(of: "albumsync.detail_needs_attention %lld", language: "en"),
            ["one": "%lld photo needs attention", "other": "%lld photos need attention"])
        XCTAssertEqual(
            try values(of: "albumsync.detail_needs_attention %lld", language: "de"),
            ["one": "%lld Foto benötigt Aufmerksamkeit", "other": "%lld Fotos benötigen Aufmerksamkeit"])
        XCTAssertEqual(
            try values(of: "albumsync.problem_sheet_title_attention", language: "en"),
            ["": "Photos that need attention"])
        XCTAssertEqual(
            try values(of: "albumsync.problem_sheet_title_attention", language: "de"),
            ["": "Fotos, die Aufmerksamkeit benötigen"])
    }

    func testTheNotInAlbumTextsKeepTheirWording() throws {
        XCTAssertEqual(
            try values(of: "albumsync.detail_not_in_album %lld", language: "en"),
            ["one": "%lld photo not in the album", "other": "%lld photos not in the album"])
        XCTAssertEqual(
            try values(of: "albumsync.detail_not_in_album %lld", language: "de"),
            ["one": "%lld Foto nicht im Album", "other": "%lld Fotos nicht im Album"])
        XCTAssertEqual(
            try values(of: "albumsync.problem_sheet_title", language: "en"), ["": "Photos not in the album"])
        XCTAssertEqual(
            try values(of: "albumsync.problem_sheet_title", language: "de"), ["": "Fotos nicht im Album"])
    }

    private func backupItem(
        _ identifier: String, reason: String = "An earlier upload of this photo is still finishing."
    ) -> BackupFailedItem {
        BackupFailedItem(
            id: "queue/\(identifier)", filename: "\(identifier).heic", reason: reason, isPermanent: false,
            issue: .remoteDraft, nextAttemptAt: Date(timeIntervalSince1970: 1_720_000_000), isRetryable: true,
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier),
            category: .automatic)
    }

    func testAnIncompletePhotoKeepsTheBackupsOwnReasonUnderAnAlbumId() {
        let backup = AlbumSyncBackupReport(
            total: 1, backedUp: 0, failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0,
            problems: ["live": backupItem("live")], filenames: ["live": "live.heic"])

        let items = AlbumSyncProblemList.items(
            missingIdentifiers: [], attachFailedIdentifiers: [], incompleteIdentifiers: ["live", "no-reason"],
            backup: backup)

        XCTAssertEqual(items.count, 1, "a photo without a backup reason is not listed")
        XCTAssertEqual(items.first?.id, AlbumSyncProblemList.incompleteIDPrefix + "live")
        XCTAssertEqual(items.first?.reason, "An earlier upload of this photo is still finishing.")
        XCTAssertEqual(items.first?.filename, "live.heic")
        XCTAssertEqual(items.first?.category, .userResolvable, "the album queue has no automatic retry")
        XCTAssertNil(items.first?.nextAttemptAt)
    }

    func testAnIncompletePhotoIsNoCompleteSync() {
        let report = AlbumSyncReport(
            remoteAlbumID: "remote", totalAssets: 1, attached: 1, alreadyMember: 0, attachFailed: 0,
            unattachable: 0, trashedSkipped: 0, incomplete: 1)
        XCTAssertFalse(report.isFullySynced)
        XCTAssertTrue(
            AlbumSyncReport(
                remoteAlbumID: "remote", totalAssets: 1, attached: 1, alreadyMember: 0, attachFailed: 0,
                unattachable: 0, trashedSkipped: 0
            ).isFullySynced)

        var progress = AlbumSyncProgress()
        progress.incomplete = 2
        progress.attachFailed = 1
        XCTAssertEqual(progress.needsAttentionCount, 3)
    }

    func testOnlyLinkedUntrashedPhotosWithAnOpenBackupRowAreIncomplete() {
        func link(_ id: String, trashed: Bool = false) -> AlbumSyncRemoteLink {
            AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol", nodeID: id), sha1Hex: nil, isTrashed: trashed)
        }
        let backup = AlbumSyncBackupReport(
            total: 5, backedUp: 0, failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0,
            problems: [
                "open": backupItem("open"), "no-link": backupItem("no-link"), "trashed": backupItem("trashed"),
                "attach-failed": backupItem("attach-failed"), "second-open": backupItem("second-open"),
                "shares-failed-link": backupItem("shares-failed-link"),
            ])

        let incomplete = AlbumSyncRunner.incompleteIdentifiers(
            orderedLocalIdentifiers: [
                "open", "no-link", "trashed", "attach-failed", "shares-failed-link", "clean", "second-open",
            ],
            links: [
                "open": link("l1"), "trashed": link("l2", trashed: true), "attach-failed": link("l3"),
                "shares-failed-link": link("l3"), "clean": link("l4"), "second-open": link("l5"),
            ],
            attachFailedLinkIDs: ["l3"],
            backup: backup)

        XCTAssertEqual(
            incomplete, ["open", "second-open"],
            "a photo whose link failed to attach is not in the album, also when another photo shares the link")
    }

    @MainActor
    func testTheListLimitNeverCutsTheIncompletePhotos() {
        let missing = (0..<AlbumSyncLastRunStore.itemLimit).map { "missing-\($0)" }
        let backup = AlbumSyncBackupReport(
            total: 201, backedUp: 0, failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0,
            problems: ["live": backupItem("live")], filenames: [:])

        let items = AlbumSyncProblemList.items(
            missingIdentifiers: missing, attachFailedIdentifiers: [], incompleteIdentifiers: ["live"],
            backup: backup)

        XCTAssertEqual(items.count, AlbumSyncLastRunStore.itemLimit + 1)
        let kept = Array(items.prefix(AlbumSyncLastRunStore.itemLimit))
        XCTAssertEqual(kept.first?.id, AlbumSyncProblemList.incompleteIDPrefix + "live")
        XCTAssertEqual(
            album(problems: kept, count: items.count).localizedRowStatusDescription,
            L10n.string("albumsync.detail_needs_attention \(items.count)"))
    }

    @MainActor
    func testTheIncompleteMarkSurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-incomplete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let incomplete = AlbumSyncProblemList.albumItem(
            from: backupItem("live"), id: AlbumSyncProblemList.incompleteIDPrefix + "live")
        let store = AlbumSyncLastRunStore(directory: directory)
        await store.load()
        store.record([incomplete], albumID: "album-1")
        await store.flush()

        let reopened = AlbumSyncLastRunStore(directory: directory)
        await reopened.load()
        let row = album(problems: reopened.items(albumID: "album-1"), count: 1)

        XCTAssertEqual(row.localizedRowStatusDescription, L10n.string("albumsync.detail_needs_attention \(1)"))
        XCTAssertEqual(
            AlbumSyncController.SelectedAlbum.localizedProblemSheetTitle(for: row.problems),
            L10n.string("albumsync.problem_sheet_title_attention"))
    }

    private func album(problems: [BackupFailedItem], count: Int) -> AlbumSyncController.SelectedAlbum {
        var album = AlbumSyncController.SelectedAlbum(
            id: "album-1", title: "Trip", assetCount: 3,
            state: .synced(Date(timeIntervalSince1970: 1_720_000_000)), needsAttentionCount: count)
        album.problems = problems
        return album
    }

    func testTheRowSaysNeedsAttentionWhenAPhotoInTheAlbumIsIncomplete() {
        let incomplete = AlbumSyncProblemList.albumItem(
            from: backupItem("live"), id: AlbumSyncProblemList.incompleteIDPrefix + "live")
        let row = album(problems: [incomplete], count: 1)

        XCTAssertEqual(row.localizedRowStatusDescription, L10n.string("albumsync.detail_needs_attention \(1)"))
        XCTAssertEqual(
            AlbumSyncController.SelectedAlbum.localizedProblemSheetTitle(for: row.problems),
            L10n.string("albumsync.problem_sheet_title_attention"))
    }

    func testTheRowKeepsNotInAlbumWhenOnlyPhotosAreMissingFromTheAlbum() {
        let missing = AlbumSyncProblemList.albumItem(from: backupItem("missing"))
        let row = album(problems: [missing], count: 1)

        XCTAssertEqual(row.localizedRowStatusDescription, L10n.string("albumsync.detail_not_in_album \(1)"))
        XCTAssertEqual(
            AlbumSyncController.SelectedAlbum.localizedProblemSheetTitle(for: row.problems),
            L10n.string("albumsync.problem_sheet_title"))
        // A run of an earlier build left no list: the old text stays.
        XCTAssertEqual(
            album(problems: [], count: 2).localizedRowStatusDescription,
            L10n.string("albumsync.detail_not_in_album \(2)"))
    }

    func testAMixedListUsesTheNeedsAttentionTextForTheWholeCount() {
        let missing = AlbumSyncProblemList.albumItem(from: backupItem("missing"))
        let incomplete = AlbumSyncProblemList.albumItem(
            from: backupItem("live"), id: AlbumSyncProblemList.incompleteIDPrefix + "live")
        let row = album(problems: [missing, incomplete], count: 2)

        XCTAssertEqual(row.localizedRowStatusDescription, L10n.string("albumsync.detail_needs_attention \(2)"))
    }
}
