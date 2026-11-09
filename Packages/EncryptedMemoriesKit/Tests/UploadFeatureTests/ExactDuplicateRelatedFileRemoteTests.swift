import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class ExactDuplicateRelatedFileRemoteTests: XCTestCase {
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

func makeDuplicateRelatedFileRequest(fileURL: URL) -> PhotoUploadRequest {
    PhotoUploadRequest(
        queueItemID: UploadQueueItemID(), cancellationToken: UUID(), fileURL: fileURL,
        name: "related.jpg", mediaType: "image/jpeg", fileSize: 13,
        captureTime: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 2),
        tags: [], expectedSHA1: Data(repeating: 1, count: 20),
        mainPhotoUID: PhotoUID(volumeID: "vol", nodeID: "kept"))
}
