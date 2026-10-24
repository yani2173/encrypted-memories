import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import AlbumSyncCore
@testable import PhotoLibraryBackupAdapter

/// After Stop, the message line says that the sync stopped, or that the album finished when the batch that was already
/// sent completed it. Both are information, not errors.
@MainActor
final class AlbumSyncStopMessageTests: XCTestCase {
    private struct NoRemoteAlbums: AlbumSyncRemoteAlbumOps {
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
        func createAlbum(name: String) async throws -> String { "remote-1" }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            AlbumSyncAttachResult()
        }
    }

    private func report(unattachable: Int = 0, incomplete: Int = 0) -> AlbumSyncReport {
        AlbumSyncReport(
            remoteAlbumID: "remote-1", totalAssets: 3, attached: 3 - unattachable, alreadyMember: 0, attachFailed: 0,
            unattachable: unattachable, trashedSkipped: 0, incomplete: incomplete)
    }

    private let stoppedText = L10n.string("albumsync.error_stopped")
    private let syncedText = L10n.string("albumsync.phase_completed")
    private let none = AlbumSyncStopState.Message(text: nil, style: .error)

    private func stopped(queuedAlbums: Int = 0) -> AlbumSyncStopState {
        var state = AlbumSyncStopState()
        state.batchStarted()
        state.stopPressed(isSyncing: true, queuedAlbums: queuedAlbums)
        return state
    }

    func testAStoppedRunSaysThatTheSyncStopped() {
        XCTAssertEqual(stopped().message(after: .stopped, current: none), .init(text: stoppedText, style: .information))
    }

    func testAStopThatTheBackupReportsAsCancellationSaysThatTheSyncStopped() {
        let state = stopped()
        XCTAssertTrue(state.endsAsStop(CancellationError()))
        XCTAssertEqual(state.message(after: .cancelled, current: none), .init(text: stoppedText, style: .information))
    }

    func testACancellationWithoutAStopStaysAnError() {
        var state = AlbumSyncStopState()
        state.batchStarted()
        XCTAssertFalse(state.endsAsStop(CancellationError()))
        XCTAssertNil(state.message(after: .cancelled, current: none))
    }

    func testAStoppedRunThatFinishedTheAlbumSaysAlbumSynced() {
        XCTAssertEqual(
            stopped().message(after: .finished(report()), current: none), .init(text: syncedText, style: .information))
    }

    func testAStopThatDroppedQueuedAlbumsSaysThatTheSyncStoppedAlsoWhenTheCurrentAlbumFinished() {
        XCTAssertEqual(
            stopped(queuedAlbums: 2).message(after: .finished(report()), current: none),
            .init(text: stoppedText, style: .information))
    }

    func testAStopThatDroppedQueuedAlbumsSaysThatTheSyncStoppedAlsoWhenTheRunNeedsAttention() {
        let state = stopped(queuedAlbums: 1)
        XCTAssertEqual(
            state.message(after: .finished(report(unattachable: 1)), current: none),
            .init(text: stoppedText, style: .information))
        XCTAssertEqual(
            state.message(after: .finished(report(incomplete: 1)), current: none),
            .init(text: stoppedText, style: .information))
    }

    func testASecondStopChangesNothing() {
        var once = stopped()
        var twice = stopped()
        twice.stopPressed(isSyncing: true, queuedAlbums: 0)
        XCTAssertEqual(twice, once)

        once = stopped(queuedAlbums: 2)
        twice = stopped(queuedAlbums: 2)
        twice.stopPressed(isSyncing: true, queuedAlbums: 0)
        XCTAssertEqual(twice, once, "a second Stop keeps the dropped albums")
        XCTAssertEqual(
            twice.message(after: .finished(report()), current: none), .init(text: stoppedText, style: .information))
    }

    func testAStoppedRunThatEndedWithPhotosThatNeedAttentionKeepsTheLine() {
        XCTAssertNil(stopped().message(after: .finished(report(unattachable: 1)), current: none))
        XCTAssertNil(stopped().message(after: .finished(report(incomplete: 1)), current: none))
    }

    func testAStopResultNeverReplacesARealError() {
        let error = AlbumSyncStopState.Message(text: "network failed", style: .error)
        XCTAssertNil(stopped().message(after: .stopped, current: error))
        XCTAssertNil(stopped().message(after: .finished(report()), current: error))
    }

    func testWithoutAStopNothingChanges() {
        var state = AlbumSyncStopState()
        state.stopPressed(isSyncing: false, queuedAlbums: 0)
        XCTAssertNil(state.message(after: .finished(report()), current: none))
        XCTAssertNil(state.message(after: .stopped, current: none))
    }

    func testANewBatchForgetsTheStop() {
        var state = stopped(queuedAlbums: 1)
        state.batchStarted()
        XCTAssertNil(state.message(after: .finished(report()), current: none))
    }

    func testAnAlbumAddedAfterStopWaitsAndTheStopStillAppliesToTheRunningAlbum() {
        var state = stopped()
        state.albumsAdded(["added"])
        XCTAssertTrue(state.keepsAfterStop("added"), "the added album runs after the stopped album ends")
        XCTAssertFalse(state.keepsAfterStop("dropped"))
        XCTAssertTrue(state.endsAsStop(CancellationError()), "the running album is still stopped")
        XCTAssertEqual(state.message(after: .stopped, current: none), .init(text: stoppedText, style: .information))
    }

    func testTheNextAlbumEndsTheStop() {
        var state = stopped()
        state.albumsAdded(["added"])
        XCTAssertTrue(state.nextAlbumStarted())
        XCTAssertFalse(state.endsAsStop(CancellationError()))
        XCTAssertNil(state.message(after: .finished(report()), current: none))
        XCTAssertFalse(state.nextAlbumStarted(), "without a Stop the next album changes nothing")
    }

    func testAlbumsAddedWithoutAStopAreNotKeptAsAddedAfterStop() {
        var state = AlbumSyncStopState()
        state.batchStarted()
        state.albumsAdded(["added"])
        XCTAssertFalse(state.keepsAfterStop("added"))
    }

    func testAnErrorAfterAStopMessageShowsAsAnErrorAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-stop-message-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let controller = AlbumSyncController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative),
            identityResolver: nil, uploader: MockUploader(), remoteOps: NoRemoteAlbums())
        addTeardownBlock { await controller.shutdown() }
        XCTAssertEqual(controller.lastMessageStyle, .error)

        controller.setMessage(L10n.string("albumsync.error_stopped"), style: .information)
        XCTAssertEqual(controller.lastMessageStyle, .information)
        controller.setMessage(AlbumSyncError.alreadyRunning.errorDescription)

        XCTAssertEqual(controller.lastMessage, AlbumSyncError.alreadyRunning.errorDescription)
        XCTAssertEqual(controller.lastMessageStyle, .error, "a real error stays red")
    }

    func testTheStopTextsAreTheExistingEnglishAndGermanStrings() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) throws -> String? {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key \(key)")
            let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
            return (localization?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        XCTAssertEqual(
            try value("albumsync.error_stopped", "en"),
            "Sync stopped. Progress is saved and the next run continues where it left off.")
        XCTAssertEqual(
            try value("albumsync.error_stopped", "de"),
            "Synchronisierung gestoppt. Der Fortschritt bleibt erhalten, der nächste Lauf setzt fort.")
        XCTAssertEqual(try value("albumsync.phase_completed", "en"), "Album synced")
        XCTAssertEqual(try value("albumsync.phase_completed", "de"), "Album synchronisiert")
    }
}
