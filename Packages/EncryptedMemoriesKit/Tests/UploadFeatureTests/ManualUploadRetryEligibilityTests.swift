import Foundation
import PhotosCore
import SQLite3
import UploadCore
import XCTest

final class ManualUploadRetryEligibilityTests: XCTestCase {
    func testLibraryLastingTerminalWriteFailureHidesRetryUntilRelaunch() async throws {
        try await terminalWriteFailure(destination: .library)
    }

    func testAlbumLastingTerminalWriteFailureHidesRetryUntilRelaunch() async throws {
        try await terminalWriteFailure(
            destination: UploadDestination(target: .existingAlbum(id: "album", title: "Album")))
    }

    func testPendingManifestSettlementKeepsRetry() async throws {
        try await pendingFailure(failsAlbum: false)
    }

    func testPendingAlbumSettlementKeepsRetry() async throws {
        try await pendingFailure(failsAlbum: true)
    }

    private func pendingFailure(failsAlbum: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let store = try XCTUnwrap(
            UploadManualSettlementStore(
                url: directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)))
        defer { store.close() }
        let uploader = MockUploader(deliverProgress: false)
        let resolver = FakeIdentityResolver()
        if !failsAlbum { resolver.recordErrorsByFilename["photo.jpg"] = UploadError.backend("Manifest unavailable") }
        let destination: UploadDestination =
            failsAlbum ? .init(target: .existingAlbum(id: "album", title: "Album")) : .library
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(failAdd: failsAlbum), identityResolver: resolver,
            settlementStore: store, requiresDurableSettlement: true, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(files, destination: destination)
        let items = await waitForAllTerminal(manager)
        let item = try XCTUnwrap(items.first)
        guard case .failed = item.state else {
            await manager.shutdown()
            return XCTFail("The remaining settlement step must fail before checking Retry")
        }
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [.retry])
        XCTAssertTrue(try XCTUnwrap(store.record(for: try XCTUnwrap(ids.first))).isPending)
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(uploader.requests.count, 1)
        await manager.shutdown()
    }

    private func terminalWriteFailure(destination: UploadDestination) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let databaseURL = directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        let store = try XCTUnwrap(UploadManualSettlementStore(url: databaseURL))
        defer { store.close() }
        try execute(
            """
            CREATE TRIGGER refuse_terminal_update
            BEFORE UPDATE ON manual_upload_settlement WHEN NEW.stage = 'terminal'
            BEGIN SELECT RAISE(FAIL, 'terminal write refused'); END;
            """, at: databaseURL)
        let uploader = MockUploader(deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: resolver,
            settlementStore: store, requiresDurableSettlement: true, maxConcurrent: 1)
        let coordinator = await MainActor.run {
            UploadCoordinator(
                manager: manager, uploadCapabilities: uploader.capabilities,
                canCreateAlbum: false, canAddToAlbum: true, canSetAlbumCover: false)
        }
        await coordinator.start()
        let ids = await manager.enqueueFiles(files, destination: destination)
        let id = try XCTUnwrap(ids.first)
        let message: String
        if case .library = destination.target {
            message = "Manual upload settlement could not be persisted."
        } else {
            message = try XCTUnwrap(
                UploadError.albumStep("Manual album settlement could not be persisted.").errorDescription)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var items = await manager.snapshot()
        while items.first?.state != .failed(message: message), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            items = await manager.snapshot()
        }
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.state, .failed(message: message), "Wait for the exact terminal-write failure")
        XCTAssertNotNil(item.uploadedUID)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(resolver.recordedUploads.count, 1)
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(store.hasLastingFailure(), "The refused terminal write is a lasting failure")
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities),
            [],
            "No settlement can run again before a relaunch, so the row offers no Retry (#1104)")
        let deliveryDeadline = ContinuousClock.now + .seconds(5)
        while await coordinator.items.first?.state != item.state, ContinuousClock.now < deliveryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let published = await coordinator.items
        XCTAssertEqual(published, items, "The upload list receives the failed snapshot")

        // Removing the injected fault restores SQLite writes, but not this store's failed connection.
        try execute("DROP TRIGGER refuse_terminal_update;", at: databaseURL)
        for _ in 0..<3 {
            #if DEBUG
                await manager.pumpForTesting()
            #endif
            try await Task.sleep(for: .milliseconds(20))
        }
        await manager.retry(id)

        let afterRetry = await manager.snapshot()
        XCTAssertEqual(afterRetry, items, "The existing Retry returns without changing the failed row")
        XCTAssertEqual(uploader.requests.count, 1, "Committed bytes must never upload again")
        XCTAssertEqual(resolver.recordedUploads.count, 1)
        await manager.shutdown()

        let reopened = try XCTUnwrap(UploadManualSettlementStore(url: databaseURL))
        defer { reopened.close() }
        let saved = try XCTUnwrap(reopened.record(for: id))
        XCTAssertTrue(saved.isPending, "The last successful write on disk still carries the pending receipt")
        XCTAssertNil(saved.terminalState)
        XCTAssertEqual(saved.uploadedUID, item.uploadedUID)
        let replay = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: FakeIdentityResolver(),
            settlementStore: reopened, requiresDurableSettlement: true, maxConcurrent: 1)
        let started = ContinuousClock.now
        var recovered = await replay.snapshot()
        XCTAssertEqual(recovered.first?.state, .finalizing)
        let recoveryDeadline = started + .seconds(5)
        while recovered.first?.state != .completed, ContinuousClock.now < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(5))
            recovered = await replay.snapshot()
        }
        XCTAssertEqual(recovered.first?.state, .completed)
        XCTAssertEqual(recovered.first?.uploadedUID, item.uploadedUID)
        XCTAssertEqual(reopened.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requests.count, 1, "Restart recovery settles only the receipt")
        print("Terminal-write recovery: \(destination.target); elapsed \(started.duration(to: .now)); uploads 1")
        await replay.shutdown()
    }

    // MARK: Retry that cannot pass the byte gate (#1228)

    /// The settlement store has a lasting failure, so enqueue refuses the upload. The item has no
    /// settlement record and no receipt. Retry cannot work before a relaunch, because the byte
    /// gate refuses every byte upload while the store cannot be read: the row offers no Retry, and
    /// a Retry call that still arrives changes nothing.
    func testLastingStoreFailureHidesRetryForAnItemWithoutRecordOrReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let store = try XCTUnwrap(
            UploadManualSettlementStore(
                url: directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)))
        defer { store.close() }
        // A transaction that stays open on the store's own handle is a lasting condition.
        try executeOnStoreConnection("BEGIN IMMEDIATE;", store: store)
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: FakeIdentityResolver(),
            settlementStore: store, requiresDurableSettlement: true, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(files, destination: .library)
        let id = try XCTUnwrap(ids.first)
        let items = await waitForAllTerminal(manager)
        let item = try XCTUnwrap(items.first)
        guard case .failed = item.state else {
            await manager.shutdown()
            return XCTFail("Enqueue must refuse the upload while the store cannot work: \(item.state)")
        }
        XCTAssertNil(item.uploadedUID)
        XCTAssertTrue(store.hasLastingFailure(), "An open transaction is a lasting failure")
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [],
            "The byte gate refuses every upload before a relaunch, so the row offers no Retry")

        await manager.retry(id)
        let afterRetry = await waitForAllTerminal(manager)
        XCTAssertEqual(afterRetry, items, "A Retry call that still arrives changes nothing")
        XCTAssertEqual(uploader.requests.count, 0, "No byte upload runs without a durable receipt")

        await manager.clearFinished()
        let afterClear = await manager.snapshot()
        XCTAssertEqual(afterClear, [], "Clear finished removes the item")
        await manager.shutdown()
    }

    func testLastingStoreFailureAfterAFailedUploadHidesRetry() async throws {
        try await lastingFailureAfterAnEndedUpload(cancels: false)
    }

    func testLastingStoreFailureAfterACancelledUploadHidesRetry() async throws {
        try await lastingFailureAfterAnEndedUpload(cancels: true)
    }

    /// An upload ends before any remote commit (the transfer fails, or the person cancels it), so
    /// the item has no settlement record and no receipt. The store then gets a lasting failure.
    /// Retry would only upload bytes that the byte gate refuses, so the row offers no Retry.
    private func lastingFailureAfterAnEndedUpload(cancels: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let store = try XCTUnwrap(
            UploadManualSettlementStore(
                url: directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)))
        defer { store.close() }
        let uploader = MockUploader(
            workDuration: cancels ? .seconds(30) : .milliseconds(20), deliverProgress: false,
            // The identity resolver names the upload request with the corrected name.
            failNames: cancels ? [] : ["corrected-photo.jpg"])
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: FakeIdentityResolver(),
            settlementStore: store, requiresDurableSettlement: true, maxConcurrent: 1)
        let published = StateHistory()
        await manager.setOnChange { items, _ in published.record(items) }
        let ids = await manager.enqueueFiles(files, destination: .library)
        let id = try XCTUnwrap(ids.first)
        if cancels {
            _ = await waitUntil(manager) { items in
                guard case .uploading = items.first?.state else { return false }
                return true
            }
            await manager.cancel(id)
        }
        let items = await waitForAllTerminal(manager)
        let ended = try XCTUnwrap(items.first)
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: ended, capabilities: uploader.capabilities), [.retry],
            "While the store works, Retry can upload the file again")
        if cancels {
            XCTAssertEqual(ended.state, .cancelled)
        } else {
            guard case .failed = ended.state else { return XCTFail("The transfer must fail: \(ended.state)") }
        }
        XCTAssertNil(ended.uploadedUID)
        XCTAssertEqual(
            published.lastItems.map {
                UploadQueuePresentation.rowActions(for: $0, capabilities: uploader.capabilities)
            },
            [[.retry]], "The published row offers Retry while the store works")

        // The lasting failure starts without a publish: an open transaction on the store's own handle.
        try executeOnStoreConnection("BEGIN IMMEDIATE;", store: store)
        XCTAssertTrue(store.hasLastingFailure(), "An open transaction is a lasting failure")
        let current = await manager.snapshot()
        let item = try XCTUnwrap(current.first)
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [],
            "The byte gate refuses every upload before a relaunch, so the row offers no Retry")
        await manager.retry(id)
        let afterRetry = await manager.snapshot()
        XCTAssertEqual(afterRetry.first?.state, ended.state, "A Retry call that still arrives changes nothing")
        XCTAssertEqual(
            published.lastItems.map {
                UploadQueuePresentation.rowActions(for: $0, capabilities: uploader.capabilities)
            },
            [[]], "A Retry tap publishes the row again, now without Retry")
        try executeOnStoreConnection("ROLLBACK;", store: store)
        await manager.shutdown()
    }

    /// Without a settlement store, enqueue refuses manual uploads. Retry of such an item must not
    /// pass the byte gate either: the commit callback is missing, so an upload would run without a
    /// durable receipt. The row offers no Retry.
    func testRetryWithoutASettlementStoreNeverUploadsAndOffersNoRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: FakeIdentityResolver(),
            settlementStore: nil, requiresDurableSettlement: true, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(files, destination: .library)
        let id = try XCTUnwrap(ids.first)
        let items = await waitForAllTerminal(manager)
        let item = try XCTUnwrap(items.first)
        guard case .failed = item.state else {
            await manager.shutdown()
            return XCTFail("Enqueue must refuse the upload without a settlement store: \(item.state)")
        }
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [],
            "Without a settlement store no upload can run, so the row offers no Retry")

        await manager.retry(id)
        let afterRetry = await waitForAllTerminal(manager)
        XCTAssertEqual(uploader.requests.count, 0, "No byte upload runs without a durable receipt")
        XCTAssertEqual(afterRetry, items, "A Retry call that still arrives changes nothing")
        await manager.shutdown()
    }

    private func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open(url.path, &handle)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(opened, SQLITE_OK)
        guard opened == SQLITE_OK else { throw UploadError.backend("Test database did not open") }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK)
        guard result == SQLITE_OK else { throw UploadError.backend("Test database setup failed") }
    }
}
