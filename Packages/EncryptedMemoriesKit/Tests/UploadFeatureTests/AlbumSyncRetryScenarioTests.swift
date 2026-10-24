import AlbumSyncCore
import CryptoKit
import Foundation
import XCTest

@testable import UploadCore

/// A retry of Album Sync keeps every photo that an earlier run added, adds every photo that can be added, and lists
/// only the photos whose backup could not finish.
final class AlbumSyncRetryScenarioTests: XCTestCase {
    func testRetriesKeepEveryAddedPhotoAndListOnlyTheBlockedPhoto() async throws {
        let device = try EditScenarioHarness()
        defer { try? device.cleanup() }
        for number in 2...4 {
            device.library.add("asset-\(number)", basename: "IMG_\(number)")
        }
        let assets = Dictionary(uniqueKeysWithValues: device.library.snapshot.map { ($0.identifier, $0) })
        // asset-3: a foreign draft with the same name and other bytes. It stays protected.
        let blockingDraft = device.server.seedDraft(
            name: "IMG_3.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("other-photo-3".utf8))),
            clientUID: "other-uploader")
        // asset-4: a foreign draft with the same name hides an active copy of the same bytes under another name.
        let hiddenCopy = device.server.seedLink(
            digest: Data(Insecure.SHA1.hash(data: try XCTUnwrap(assets["asset-4"]).current)))
        _ = device.server.seedDraft(
            name: "IMG_4.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("other-photo-4".utf8))),
            clientUID: "other-uploader")

        var reports: [AlbumSyncReport] = []
        var memberCounts: [Int] = []
        for _ in 0..<3 {
            let backup = EditScenarioAlbumBackup(device: device)
            reports.append(try await device.syncAlbum(assets.keys.sorted(), backup: backup))
            memberCounts.append(try await device.server.childMainLinkIDs(albumID: "own-album").count)
        }

        XCTAssertEqual(reports.map(\.attached), [3, 0, 0])
        XCTAssertEqual(reports.map(\.alreadyMember), [0, 3, 3])
        XCTAssertEqual(memberCounts, [3, 3, 3], "A retry never loses a photo that an earlier run added")
        XCTAssertEqual(reports.map(\.unattachable), [1, 1, 1])
        XCTAssertEqual(reports.map(\.incomplete), [0, 0, 0])
        for report in reports {
            XCTAssertEqual(report.problems.map(\.source?.identifier), ["asset-3"])
            XCTAssertEqual(report.problems.first?.issue, .remoteDraft)
        }
        let members = try await device.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertTrue(members.contains(hiddenCopy.nodeID))
        XCTAssertEqual(device.server.links.first { $0.uid == blockingDraft }?.state, .draft)
        XCTAssertEqual(device.server.uploadRequestCount, 2, "Only asset-1 and asset-2 upload, each once")
    }
}
