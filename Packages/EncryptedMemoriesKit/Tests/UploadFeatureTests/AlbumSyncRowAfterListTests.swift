import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import AlbumSyncCore
@testable import PhotoLibraryBackupAdapter

/// A run stores its new count first and reports its end second. The list of the run is stored after that.
/// The row must not combine the new count with the list of the previous run in between.
@MainActor
final class AlbumSyncRowAfterListTests: XCTestCase {
    private struct NoRemoteAlbums: AlbumSyncRemoteAlbumOps {
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
        func createAlbum(name: String) async throws -> String { "remote-1" }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            AlbumSyncAttachResult()
        }
    }

    private func item(_ identifier: String, incomplete: Bool) -> BackupFailedItem {
        let backup = BackupFailedItem(
            id: "queue/\(identifier)", filename: "\(identifier).heic", reason: "Still finishing.", isPermanent: false,
            issue: .remoteDraft, isRetryable: true,
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier),
            category: .automatic)
        return AlbumSyncProblemList.albumItem(
            from: backup, id: incomplete ? AlbumSyncProblemList.incompleteIDPrefix + identifier : nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("The condition did not hold within 10 seconds") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTheRowNeverCombinesTheNewCountWithThePreviousListWhenARunEnds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-row-after-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Teardown blocks run in reverse order: controller shutdown, store close, then the directory removal.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_720_000_000)

        // The previous run left one photo that is not in the album, without a photo that needs attention.
        let mappings = try XCTUnwrap(
            AlbumSyncMappingStore(url: directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        addTeardownBlock { mappings.close() }
        func mapping(failed: Int) -> AlbumSyncMapping {
            AlbumSyncMapping(
                localAlbumID: "album-1", remoteAlbumID: "remote-1", title: "Trip", createdAt: date,
                lastSyncedAt: date, lastFailedCount: failed)
        }
        XCTAssertTrue(mappings.addSelection(AlbumSyncSelection(localAlbumID: "album-1", title: "Trip", addedAt: date)))
        XCTAssertTrue(mappings.upsert(mapping(failed: 1)))
        let previous = AlbumSyncLastRunStore(directory: directory)
        await previous.load()
        previous.record([item("old", incomplete: false)], albumID: "album-1")
        await previous.flush()

        let controller = AlbumSyncController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative),
            identityResolver: nil, uploader: MockUploader(), remoteOps: NoRemoteAlbums())
        addTeardownBlock { await controller.shutdown() }
        try await waitUntil { controller.selectedAlbums.first?.problems.count == 1 }
        let row = { try XCTUnwrap(controller.selectedAlbums.first) }
        let before = try row().localizedRowStatusDescription
        XCTAssertEqual(before, L10n.string("albumsync.detail_not_in_album \(1)"))

        // The runner stores the new count, then reports the end of the run. Two photos need attention.
        XCTAssertTrue(mappings.upsert(mapping(failed: 2)))
        var ended = AlbumSyncProgress()
        ended.phase = .needsAttention
        controller.applyProgress(ended)

        let between = try row().localizedRowStatusDescription
        XCTAssertNotEqual(
            between, L10n.string("albumsync.detail_not_in_album \(2)"),
            "The new count must not appear with the list of the previous run")
        XCTAssertEqual(between, before, "Until the list is stored, the row stays as the previous run left it")

        // The list of the run is stored; now the row shows the run.
        controller.recordFinishedRun(
            [item("a", incomplete: true), item("b", incomplete: true)], albumID: "album-1")
        XCTAssertEqual(
            try row().localizedRowStatusDescription, L10n.string("albumsync.detail_needs_attention \(2)"))
        XCTAssertEqual(
            AlbumSyncController.SelectedAlbum.localizedProblemSheetTitle(for: try row().problems),
            L10n.string("albumsync.problem_sheet_title_attention"))
    }
}
