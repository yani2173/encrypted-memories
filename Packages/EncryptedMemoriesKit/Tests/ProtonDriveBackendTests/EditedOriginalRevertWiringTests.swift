import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import ProtonDriveBackend

/// The bridge builds the revert to original for its account: the journal lives in the account data directory, the
/// bridge's shutdown gate admits every call, and an unproven pair writes nothing. The bridge here fails every request
/// as if the device were offline, so a remote read shows as an error and never as silence.
@Suite("Edited original revert wiring", .serialized)
struct EditedOriginalRevertWiringTests {
    private let editedMain = PhotoUID(volumeID: "own", nodeID: "edited")

    private func withBridge(
        _ body: (DriveSDKBridge, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try await DriveSDKBridgePriorityScopeTests.makeBridge(
            directory: directory, governor: ProtonRequestGovernor())
        do {
            try await body(bridge, directory)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    @Test func withoutADuplicateServiceThereIsNoRevert() async throws {
        try await withBridge { bridge, _ in
            #expect(bridge.makeEditedOriginalRevert(duplicateChecker: nil, albums: NoAlbums()) == nil)
        }
    }

    /// A journal in the trash step with a recorded copy needs a remote read; offline, that read fails and the resume
    /// reports it. The report proves that the revert reads the journal directory of this account.
    @Test func theResumeReadsTheJournalsOfTheAccountDirectory() async throws {
        try await withBridge { bridge, directory in
            let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: directory)
            try store.save(
                EditedOriginalRevertJournal(
                    editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
                    copyUID: PhotoUID(volumeID: "own", nodeID: "copy"), favoriteDone: true, phase: .trashingEdit))
            let revert = try #require(bridge.makeEditedOriginalRevert(duplicateChecker: Checker(), albums: NoAlbums()))

            let outcomes = try await revert.resumePending()

            #expect(outcomes.count == 1, "the journal of the account directory was found and served")
            #expect(throws: (any Error).self) { try outcomes[0].result.get() }
            #expect(try store.journal(forEditedMain: editedMain) != nil, "a failed step keeps its journal")
        }
    }

    /// A journal that needs a new copy makes no request at all: the resume stays silent and the journal stays.
    @Test func theResumeStaysSilentForAJournalThatNeedsANewCopy() async throws {
        try await withBridge { bridge, directory in
            let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: directory)
            let waiting = EditedOriginalRevertJournal(
                editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
                phase: .trashingEdit)
            try store.save(waiting)
            let revert = try #require(bridge.makeEditedOriginalRevert(duplicateChecker: Checker(), albums: NoAlbums()))

            let outcomes = try await revert.resumePending()

            #expect(outcomes.isEmpty)
            #expect(try store.journal(forEditedMain: editedMain) == waiting)
        }
    }

    /// The shared account gate refuses a revert and a resume after the bridge shut down, so a sign-out purge never
    /// meets a running revert.
    @Test func theBridgeShutdownRefusesTheRevertAndTheResume() async throws {
        try await withBridge { bridge, directory in
            let revert = try #require(bridge.makeEditedOriginalRevert(duplicateChecker: Checker(), albums: NoAlbums()))
            await bridge.shutdown()

            await #expect(throws: CancellationError.self) { try await revert.resumePending() }
            await #expect(throws: CancellationError.self) {
                try await revert.revert(
                    editedMain: editedMain, original: PhotoUID(volumeID: "own", nodeID: "original"),
                    restoredName: "IMG_0001 (original).heic")
            }
            // A refused revert writes no journal: the shutdown gate refuses it before its first write.
            let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: directory)
            #expect(try store.pendingJournals().isEmpty)
        }
    }

    /// The viewer's entry proves the pair with the bridge first. Offline, the proof fails, so nothing is written:
    /// no journal appears.
    @Test func aRevertWhoseProofFailsWritesNoJournal() async throws {
        try await withBridge { bridge, directory in
            let revert = try #require(bridge.makeEditedOriginalRevert(duplicateChecker: Checker(), albums: NoAlbums()))
            let reverter = bridge.makeEditedPhotoReverter(revert: revert)
            let main = PhotoItem(uid: editedMain, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
            let original = PhotoItem(
                uid: PhotoUID(volumeID: "own", nodeID: "original"), captureTime: main.captureTime,
                mediaType: "image/heic")

            await #expect(throws: (any Error).self) {
                try await reverter.revertToOriginal(of: main, original: original)
            }

            let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: directory)
            #expect(try store.pendingJournals().isEmpty)
        }
    }
}

private struct NoAlbums: SeriesAlbumCarryOver {
    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] { [] }
    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {}
}

private struct Checker: UploadDuplicateChecking {
    func hashKeyEpoch() async throws -> String { "epoch" }
    func nameHash(forCorrectedName name: String) async throws -> String { "name" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "content" }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] { [] }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? { nil }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] { [:] }
}
