import Foundation
import PhotosCore
import UploadCore
import XCTest

final class UnsupportedUploadRetryPresentationTests: XCTestCase {
    func testEnqueuedUnsupportedFilesKeepTheirReasonWithoutRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try makeTempFiles(["notes.txt", "archive.zip", "without-extension"], in: directory)
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader)

        let ids = await manager.enqueueFiles(urls, destination: .library)
        let items = await manager.snapshot()

        XCTAssertEqual(items.count, urls.count)
        for item in items {
            let reason = try XCTUnwrap(UploadError.unsupportedFile(item.displayName).errorDescription)
            XCTAssertEqual(item.state, .failed(message: reason))
            XCTAssertEqual(
                UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [],
                "An unsupported file must keep its reason without offering a retry that does nothing")
        }
        for id in ids { await manager.retry(id) }
        let afterRetry = await manager.snapshot()
        XCTAssertEqual(afterRetry, items)
        XCTAssertTrue(uploader.requests.isEmpty)
        await manager.shutdown()
    }

    func testSupportedFailureStillOffersRetryThatCanSucceed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try makeTempFiles(["retry.JPG"], in: directory)
        let uploader = MockUploader(deliverProgress: false, transientFailures: ["retry.JPG": 1])
        let manager = UploadManager(uploader: uploader)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        let firstAttempt = await waitForAllTerminal(manager)
        let failed = try XCTUnwrap(firstAttempt.first)

        guard case .failed = failed.state else {
            await manager.shutdown()
            return XCTFail("The first supported upload must fail before the explicit retry")
        }
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: failed, capabilities: uploader.capabilities), [.retry])

        await manager.retry(try XCTUnwrap(ids.first))
        let retried = await waitForAllTerminal(manager)
        XCTAssertEqual(retried.map(\.state), [.completed])
        XCTAssertEqual(uploader.requests.count, 2)
        await manager.shutdown()
    }

    func testUploadedItemKeepsSettlementRetryForUnsupportedFilename() {
        let item = item(
            state: .failed(message: "The remaining upload steps failed"), uploadedUID: testUID("uploaded"))

        XCTAssertEqual(UploadQueuePresentation.rowActions(for: item, capabilities: .unavailable), [.retry])
    }

    func testCancelledItemKeepsItsExistingRetry() {
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item(state: .cancelled), capabilities: .unavailable), [.retry])
    }

    private func item(state: UploadItemState, uploadedUID: PhotoUID? = nil) -> UploadItem {
        UploadItem(
            id: UUID(), ordinal: 0, fileURL: URL(fileURLWithPath: "/fixture/item.txt"),
            displayName: "item.txt", mediaType: "application/octet-stream", byteCount: 1,
            state: state, uploadedUID: uploadedUID)
    }
}
