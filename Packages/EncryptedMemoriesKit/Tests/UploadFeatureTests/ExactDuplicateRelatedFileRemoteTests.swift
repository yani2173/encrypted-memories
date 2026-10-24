import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class ExactDuplicateRelatedFileRemoteTests: XCTestCase {
    func testDefaultDownloadThroughExistentialFailsWithoutCreatingAFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("related.partial")
        let remote: any ExactDuplicateRemote = UnavailableRelatedFileRemote(base: EditScenarioServer())

        do {
            _ = try await remote.downloadRelatedFile(
                PhotoUID(volumeID: "vol", nodeID: "related"), to: destination, allowsExpensiveNetwork: false)
            XCTFail("An unavailable download must fail")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testDefaultUploadThroughExistentialFailsWithoutChangingTheSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("related.jpg")
        let bytes = Data("related bytes".utf8)
        try bytes.write(to: source)
        let remote: any ExactDuplicateRemote = UnavailableRelatedFileRemote(base: EditScenarioServer())

        do {
            _ = try await remote.uploadRelatedFile(makeDuplicateRelatedFileRequest(fileURL: source))
            XCTFail("An unavailable upload must fail")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
        }

        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["related.jpg"])
    }

    func testExistentialDispatchUsesBothTransferOverrides() async throws {
        let server = EditScenarioServer()
        let remote: any ExactDuplicateRemote = server
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await remote.downloadRelatedFile(
                PhotoUID(volumeID: "vol", nodeID: "related"), to: file, allowsExpensiveNetwork: false)
            XCTFail("The scenario transfer must fail closed")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
        }
        do {
            _ = try await remote.uploadRelatedFile(makeDuplicateRelatedFileRequest(fileURL: file))
            XCTFail("The scenario transfer must fail closed")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
        }
        XCTAssertEqual(server.relatedFileTransferCallCount, 2, "Both protocol requirements dispatch to the conformer")
        XCTAssertEqual(server.uploadRequestCount, 0)
        XCTAssertEqual(server.steps.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

/// Uses the same default transfer witnesses as the production bridge, without a signed-in SDK session.
private struct UnavailableRelatedFileRemote: ExactDuplicateRemote {
    let base: EditScenarioServer

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
}

func makeDuplicateRelatedFileRequest(fileURL: URL) -> PhotoUploadRequest {
    PhotoUploadRequest(
        queueItemID: UploadQueueItemID(), cancellationToken: UUID(), fileURL: fileURL,
        name: "related.jpg", mediaType: "image/jpeg", fileSize: 13,
        captureTime: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 2),
        tags: [], expectedSHA1: Data(repeating: 1, count: 20),
        mainPhotoUID: PhotoUID(volumeID: "vol", nodeID: "kept"))
}
