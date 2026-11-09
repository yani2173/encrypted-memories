import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Durability of the revert journal: save, reopen across store instances, tolerant decoding of older
/// journals, pending listing and account isolation.
final class EditedOriginalRevertJournalTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edited-original-revert-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let main = PhotoUID(volumeID: "volume", nodeID: "main")

    func testJournalPersistsProgressAndSurvivesStoreReopen() throws {
        var journal = EditedOriginalRevertJournal(editedMainUID: main, originalLinkID: "original")
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        try store.save(journal)
        XCTAssertEqual(try store.journal(forEditedMain: main), journal)

        journal.copyUID = PhotoUID(volumeID: "volume", nodeID: "copy")
        journal.favoriteDone = true
        journal.addedAlbumIDs = ["album"]
        journal.phase = .trashingEdit
        try store.save(journal)

        let reopened = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        XCTAssertEqual(try reopened.journal(forEditedMain: main), journal)
        XCTAssertEqual(try reopened.pendingJournals(), [journal])

        try reopened.remove(forEditedMain: main)
        XCTAssertNil(try store.journal(forEditedMain: main))
        XCTAssertEqual(try store.pendingJournals(), [])
    }

    func testAnOlderJournalWithoutCarryOverFieldsDecodesAsNothingCarried() throws {
        // Journals written by an older build without the carry-over fields mean "nothing carried over yet".
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        let json = """
            {"editedMainUID":{"volumeID":"volume","nodeID":"main"},"originalLinkID":"o","phase":"copying"}
            """
        let directory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("legacy.json"))

        let journal = try XCTUnwrap(try store.pendingJournals().first)
        XCTAssertEqual(journal.editedMainUID, main)
        XCTAssertEqual(journal.originalLinkID, "o")
        XCTAssertFalse(journal.favoriteDone)
        XCTAssertTrue(journal.addedAlbumIDs.isEmpty)
        XCTAssertNil(journal.copyUID)
    }

    func testAccountsDoNotShareJournals() throws {
        let first = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir.appendingPathComponent("first"))
        let second = EditedOriginalRevertJournalFileStore(
            accountDataDirectory: tempDir.appendingPathComponent("second"))
        let journal = EditedOriginalRevertJournal(editedMainUID: main, originalLinkID: "original")
        try first.save(journal)
        XCTAssertEqual(try first.journal(forEditedMain: main), journal)
        XCTAssertNil(try second.journal(forEditedMain: main))
        XCTAssertTrue(try second.pendingJournals().isEmpty)
    }

    func testUndecodableJournalIsSkippedButUnreadableStillThrows() throws {
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        try store.save(.init(editedMainUID: main, originalLinkID: "original"))
        let directory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try store.journal(forEditedMain: main))
        // One undecodable journal must not stop the resume of every other revert: pendingJournals skips
        // it instead of throwing.
        XCTAssertEqual(try store.pendingJournals().count, 0)
    }

    /// F18: `decodableJournal` treats a file that was read but cannot be decoded as missing, so `revert`
    /// starts a fresh run and `abandon` removes the file. A file that still decodes reads as present.
    func testDecodableJournalTreatsAnUndecodableFileAsMissing() throws {
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        try store.save(.init(editedMainUID: main, originalLinkID: "original"))
        let directory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try store.journal(forEditedMain: main))

        XCTAssertNil(try store.decodableJournal(forEditedMain: main))

        let other = PhotoUID(volumeID: "volume", nodeID: "other")
        let healthy = EditedOriginalRevertJournal(editedMainUID: other, originalLinkID: "original")
        try store.save(healthy)
        XCTAssertEqual(try store.decodableJournal(forEditedMain: other), healthy)

        // An account with no journal directory at all has no journal.
        let empty = EditedOriginalRevertJournalFileStore(
            accountDataDirectory: tempDir.appendingPathComponent("does-not-exist"))
        XCTAssertNil(try empty.decodableJournal(forEditedMain: main))
    }

    /// F19: a journal path that exists but cannot be read as file data (an I/O error, a permission
    /// change) throws from every reader, instead of reading as a missing journal. Treating it as missing
    /// would let `revert` replace the file with a fresh journal and lose the recorded phase and copy.
    func testAJournalFileThatCannotBeReadThrowsInsteadOfReadingAsMissing() throws {
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        let directory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data("\(main.volumeID)/\(main.nodeID)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        // A directory at the journal path exists but cannot be read as file data.
        let unreadable = directory.appendingPathComponent("\(name).json")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.journal(forEditedMain: main))
        XCTAssertThrowsError(try store.decodableJournal(forEditedMain: main))
        // A resume does not silently skip the unreadable file.
        XCTAssertThrowsError(try store.pendingJournals())
        // The path still exists: nothing removed or replaced it.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unreadable.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }
}
