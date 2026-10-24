import Foundation
import XCTest

@testable import UploadCore

final class ExactDuplicateMergeJournalTests: XCTestCase {
    func testClearingAnOlderRecordRetainsSameTimeReplacementsWithDifferentPayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-journal-equality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)
        let checker = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)
        let move = UploadRemoteLinkMove(from: "duplicate", to: "kept", contentHash: "main-hash")
        let older = ExactDuplicateMergeIntent(
            volumeID: "volume", kept: "kept", contentHash: "main-hash", hashKeyEpoch: "epoch",
            members: [.init(link: "duplicate", moves: [move])], trashedAt: 1_720_000_000,
            successors: ["earlier-edit"])
        let replacements = [
            ExactDuplicateMergeIntent(
                volumeID: older.volumeID, kept: older.kept, contentHash: older.contentHash,
                hashKeyEpoch: older.hashKeyEpoch,
                members: older.members + [.init(link: "another-duplicate", moves: [])],
                trashedAt: older.trashedAt, successors: older.successors),
            ExactDuplicateMergeIntent(
                volumeID: older.volumeID, kept: older.kept, contentHash: older.contentHash,
                hashKeyEpoch: older.hashKeyEpoch,
                members: [
                    .init(
                        link: "duplicate",
                        moves: [move, .init(from: "related", to: "kept-related", contentHash: "related-hash")])
                ],
                trashedAt: older.trashedAt, successors: older.successors),
            ExactDuplicateMergeIntent(
                volumeID: older.volumeID, kept: older.kept, contentHash: older.contentHash,
                hashKeyEpoch: older.hashKeyEpoch, members: older.members,
                trashedAt: older.trashedAt, successors: ["later-edit"]),
        ]

        for replacement in replacements {
            XCTAssertEqual(replacement.key, older.key)
            XCTAssertEqual(replacement.trashedAt, older.trashedAt)
            XCTAssertNotEqual(replacement, older)
            XCTAssertTrue(writer.record([older]))
            XCTAssertEqual(checker.pendingMerges(), [older])
            XCTAssertTrue(writer.record([replacement]))
            XCTAssertEqual(checker.pendingMerges(), [replacement])

            XCTAssertTrue(checker.clear([older]))

            XCTAssertEqual(
                writer.pendingMerges(), [replacement],
                "Clearing the checked record must retain a same-time replacement with a different payload")
            XCTAssertTrue(checker.clear([replacement]), "The exact current record must still clear")
            XCTAssertEqual(writer.pendingMerges(), [])
        }
    }
}
