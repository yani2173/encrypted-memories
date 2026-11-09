import PhotosCore
import UploadCore
import XCTest

@testable import AlbumSyncCore
@testable import UploadFeature

/// A row restored from the last-run file must carry the same source to previews as a current row.
@MainActor
final class AlbumSyncLastRunSourcePreviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-last-run-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func listItem(_ identifier: String) -> BackupFailedItem {
        BackupFailedItem(
            id: "album/\(identifier)", filename: "\(identifier).heic", reason: "Not backed up.", isPermanent: false,
            isRetryable: true,
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier),
            category: .userResolvable)
    }

    func testARestoredRowGivesItsStoredSourceToPreviews() async throws {
        let store = AlbumSyncLastRunStore(directory: directory)
        await store.load()
        store.record([listItem("asset-1")], albumID: "album-1")
        await store.flush()

        // A relaunch builds its rows from the file, not from this run's report.
        let relaunched = AlbumSyncLastRunStore(directory: directory)
        await relaunched.load()
        let restored = relaunched.items(albumID: "album-1")
        XCTAssertEqual(restored.count, 1)

        XCTAssertEqual(
            BackupProblemPreviewModel.uid(for: restored[0].source),
            PhotoUID(localPending: .photoLibrary, identifier: "asset-1"))
    }

    func testARestoredRowWithoutASourceHasNoPreview() async throws {
        let unsourced = BackupFailedItem(
            id: "album/old", filename: "old.heic", reason: "Not backed up.", isPermanent: false,
            isRetryable: true, category: .userResolvable)
        let store = AlbumSyncLastRunStore(directory: directory)
        await store.load()
        store.record([unsourced], albumID: "album-1")
        await store.flush()

        let relaunched = AlbumSyncLastRunStore(directory: directory)
        await relaunched.load()
        let restored = relaunched.items(albumID: "album-1")

        XCTAssertNil(BackupProblemPreviewModel.uid(for: restored.first?.source))
    }
}
