import Foundation
import XCTest

@testable import PhotosCore

final class TimelineMetadataReconciliationTests: XCTestCase {
    private func fixture() throws -> ReconciliationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try ReconciliationFixture(url: directory.appendingPathComponent("order.sqlite"))
    }

    private func inventory(_ count: Int, library: String = "first") -> TimelineMetadataReconciliation.Inventory {
        .init(
            items: (0..<count).map {
                PhotoItem(
                    uid: PhotoUID(volumeID: library, nodeID: String(format: "%04d", $0)),
                    captureTime: Date(timeIntervalSince1970: 500), mediaType: "image/jpeg")
            }, classifiedNodeIDs: [], libraryID: library)
    }

    func testFrequentChangesPublishTheActiveSnapshotAndOnlyOneLatestFollowUp() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { pass in
            await fixture.run(pass)
        }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        for count in 3...12 { reconciliation.schedule(inventory(count), operation: operation) }
        let beforeRelease = await fixture.counts()
        XCTAssertEqual(beforeRelease.started, 1, "inventory changes must not displace the network phase")
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 2, "one change series must produce exactly one follow-up")
        XCTAssertEqual(result.cancelled, 0)
        XCTAssertEqual(result.published.map(\.count), [2, 12], "the original snapshot must publish before the latest")
        await fixture.close()
    }

    func testQueuedPassDoesNotRepeatCompletedMIMERequests() async throws {
        try await assertQueuedMIMERequests(useOrderCache: true)
    }

    func testQueuedMIMEFallbackDoesNotRepeatCompletedRequests() async throws {
        try await assertQueuedMIMERequests(useOrderCache: false)
    }

    private func assertQueuedMIMERequests(useOrderCache: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try MIMEReconciliationFixture(directory: directory, useOrderCache: useOrderCache)
        let reconciliation = TimelineMetadataReconciliation()
        let initial = inventory(302)
        let latest = inventory(303)
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = {
            await fixture.run($0, reconciliation: reconciliation)
        }
        reconciliation.schedule(initial, operation: operation)
        await awaitEvent(fixture.requested, "the first MIME request")
        // B is queued before A commits its first MIME response.
        reconciliation.schedule(latest, operation: operation)
        let before = try await fixture.result()
        XCTAssertEqual(before.requests.map(\.count), [1])
        XCTAssertEqual(before.classified, 0)
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = try await fixture.result()
        XCTAssertEqual(result.requests.map(\.count), [3, 1], "B must request only the newly added photo")
        XCTAssertEqual(result.requests.last?.flatMap { $0 }, [latest.items.last!.uid])
        XCTAssertEqual(
            result.requests.flatMap { $0 }.flatMap { $0 }.count, 303, "completed MIME checks must not repeat")
        XCTAssertEqual(result.classified, 303)
        XCTAssertEqual(result.images, 152)
        XCTAssertEqual(result.videos, 151)
        XCTAssertTrue(result.pending.isEmpty, "completed checkpoints must remain complete")
        await fixture.close()
    }

    func testReturningToTheActiveInventoryDropsAnObsoleteFollowUp() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        reconciliation.schedule(inventory(3), operation: operation)
        reconciliation.schedule(inventory(2), operation: operation)
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.cancelled, 0)
        XCTAssertEqual(result.published.map(\.count), [2])
        await fixture.close()
    }

    func testRepeatedIdenticalInventoriesKeepTheHeldRequest() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        let initial = inventory(2)
        reconciliation.schedule(initial, operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        let reversed = TimelineMetadataReconciliation.Inventory(
            items: Array(initial.items.reversed()), classifiedNodeIDs: [], libraryID: initial.libraryID)
        for _ in 0..<20 { reconciliation.schedule(reversed, operation: operation) }
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.cancelled, 0)
        XCTAssertEqual(result.published.map(\.count), [2])
        await fixture.close()
    }

    func testNewPhotosStayVisibleInFallbackOrderBeforePublication() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let initial = inventory(2)
        let latest = inventory(5)
        reconciliation.schedule(initial) { await fixture.run($0) }
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        reconciliation.schedule(latest) { await fixture.run($0) }
        let visible = await fixture.enrich(latest.items)
        XCTAssertEqual(visible.map(\.uid), latest.items.map(\.uid))
        XCTAssertTrue(visible.allSatisfy { $0.timelineOrder == nil })
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.published.map(\.count), [2, 5])
        XCTAssertEqual(result.published.last?.first?.uid, latest.items.last?.uid)
        await fixture.close()
    }

    func testLogoutCancelsThePassAndDiscardsThePendingInventory() async throws {
        try await assertRetirement()
    }

    func testAccountReplacementCancelsTheOldPassAndDiscardsItsPendingInventory() async throws {
        try await assertRetirement()
        let replacement = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        await replacement.release()
        reconciliation.schedule(inventory(2, library: "replacement")) { await replacement.run($0) }
        await reconciliation.waitForCurrentPass()
        let result = await replacement.result()
        XCTAssertEqual(result.published.map(\.count), [2])
        XCTAssertEqual(result.published.first?.first?.uid.volumeID, "replacement")
        await replacement.close()
    }

    private func assertRetirement() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        for count in 3...12 { reconciliation.schedule(inventory(count), operation: operation) }
        // The same account admission barrier is used by the production owner before teardown.
        fixture.admission.closeAdmission()
        reconciliation.retire()
        await fixture.admission.closeAdmissionAndJoin()
        await reconciliation.waitForCurrentPass()
        reconciliation.schedule(inventory(13), operation: operation)
        let result = await fixture.result()
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.cancelled, 1, "cancellation must finish without releasing the held network request")
        XCTAssertTrue(result.published.isEmpty)
        await fixture.close()
    }

    func testRetirementCancellationHandlerCanReadTheCoordinator() async {
        await assertCancellationOutsideLock(replacingLibrary: false)
    }

    func testLibraryReplacementCancellationHandlerCanReadTheCoordinator() async {
        await assertCancellationOutsideLock(replacingLibrary: true)
    }

    private func assertCancellationOutsideLock(replacingLibrary: Bool) async {
        let reconciliation = TimelineMetadataReconciliation()
        let started = AsyncTestSignal()
        let finished = AsyncTestSignal()
        reconciliation.schedule(inventory(2)) { pass in
            await withTaskCancellationHandler {
                started.fire()
                try? await Task.sleep(for: .seconds(30))
            } onCancel: {
                let queried = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    XCTAssertFalse(reconciliation.isCurrent(pass))
                    queried.signal()
                }
                // The query is a plain read; the bound only ends a deadlock, so machine load never reaches it.
                XCTAssertEqual(
                    queried.wait(timeout: .now() + 60), .success,
                    "cancellation handlers must be able to read the coordinator without waiting for its lock")
            }
            finished.fire()
        }
        await awaitEvent(started, "the registration of the cancellation handler")
        if replacingLibrary {
            reconciliation.schedule(inventory(2, library: "second")) { _ in }
        } else {
            reconciliation.retire()
        }
        await awaitEvent(finished, "the end of the cancelled pass")
        await reconciliation.waitForCurrentPass()
    }

    func testLibraryReplacementCancelsThePassAndDropsTheOldFollowUp() async throws {
        let fixture = try fixture()
        let reconciliation = TimelineMetadataReconciliation()
        let operation: @Sendable (TimelineMetadataReconciliation.Pass) async -> Void = { await fixture.run($0) }
        reconciliation.schedule(inventory(2), operation: operation)
        await awaitEvent(fixture.started, "the first pass reaching the network phase")
        for count in 3...12 { reconciliation.schedule(inventory(count), operation: operation) }
        reconciliation.schedule(inventory(3, library: "second"), operation: operation)
        await awaitEvent(fixture.cancelled, "the cancellation of the old pass")
        await fixture.release()
        await reconciliation.waitForCurrentPass()
        let result = await fixture.result()
        XCTAssertEqual(result.started, 2)
        XCTAssertEqual(result.cancelled, 1)
        XCTAssertEqual(result.published.map(\.count), [3])
        XCTAssertTrue(result.published.flatMap { $0 }.allSatisfy { $0.uid.volumeID == "second" })
        await fixture.close()
    }
}

private actor ReconciliationFixture {
    nonisolated let started = AsyncTestSignal()
    nonisolated let cancelled = AsyncTestSignal()
    nonisolated let admission = JoinedShutdownGate()
    private let store: TimelineOrderMetadataStore
    private var startedCount = 0
    private var cancelledCount = 0
    private var publications: [[PhotoItem]] = []
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(url: URL) throws { store = try XCTUnwrap(TimelineOrderMetadataStore(url: url)) }

    nonisolated func run(_ pass: TimelineMetadataReconciliation.Pass) async {
        _ = try? await admission.withAdmission { await self.perform(pass) }
    }

    private func perform(_ pass: TimelineMetadataReconciliation.Pass) async {
        startedCount += 1
        let items = pass.inventory.items
        guard await store.synchronizeInChunks(items, isClassified: { _ in true }) else { return }
        if startedCount == 1 { started.fire() }
        do {
            try await networkRequest()
            try Task.checkCancellation()
            let metadata = Dictionary(
                uniqueKeysWithValues: items.enumerated().map { index, item in
                    (
                        item.uid,
                        TimelineOrderMetadata(
                            exactCaptureTime: item.captureTime.addingTimeInterval(0.1),
                            stableIdentity: String(format: "%04d", 1000 - index))
                    )
                })
            XCTAssertTrue(store.record(metadata))
            XCTAssertTrue(try store.publishCompletedSeconds())
            publications.append(store.enrich(items))
        } catch is CancellationError {
            cancelledCount += 1
            if cancelledCount == 1 { cancelled.fire() }
        } catch {
            XCTFail("unexpected pass failure: \(error)")
        }
    }

    private func networkRequest() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if released { return }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func release() {
        released = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func counts() -> (started: Int, cancelled: Int) { (startedCount, cancelledCount) }
    func result() -> (started: Int, cancelled: Int, published: [[PhotoItem]]) {
        (startedCount, cancelledCount, publications)
    }
    func enrich(_ items: [PhotoItem]) -> [PhotoItem] { store.enrich(items) }
    func close() async {
        await admission.closeAdmissionAndJoin()
        store.close()
    }
}

private actor MIMEReconciliationFixture {
    nonisolated let requested = AsyncTestSignal()
    private let timeline: TimelineMetadataStore
    private let order: TimelineOrderMetadataStore?
    private var requests: [[[PhotoUID]]] = []
    private var response: CheckedContinuation<Void, Never>?
    private var released = false

    init(directory: URL, useOrderCache: Bool) throws {
        timeline = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        order =
            useOrderCache
            ? try XCTUnwrap(TimelineOrderMetadataStore(url: directory.appendingPathComponent("order.sqlite"))) : nil
    }

    func run(_ pass: TimelineMetadataReconciliation.Pass, reconciliation: TimelineMetadataReconciliation) async {
        let reader = TimelineMetadataPageReader(inventory: pass.inventory, orderStore: order, timelineStore: timeline)
        requests.append([])
        let index = requests.count - 1
        do {
            try await reader.prepare(isCurrent: { reconciliation.isCurrent(pass) })
            while true {
                let page = try await reader.nextPage(isCurrent: { reconciliation.isCurrent(pass) })
                if page.isEmpty { break }
                requests[index].append(page.map(\.uid))
                if index == 0, requests[index].count == 1, !released {
                    await withCheckedContinuation {
                        response = $0
                        requested.fire()
                    }
                }
                let evidence = Dictionary(
                    uniqueKeysWithValues: page.map {
                        ($0.uid, Int($0.uid.nodeID)!.isMultiple(of: 2) ? "image/jpeg" : "video/mp4")
                    })
                XCTAssertTrue(timeline.recordMediaTypeEvidence(evidence, publishRevision: false).succeeded)
                if let order {
                    let metadata = Dictionary(
                        uniqueKeysWithValues: page.filter(\.needsOrder).map { ($0.uid, TimelineOrderMetadata()) })
                    XCTAssertTrue(order.record(metadata, classifiedUIDs: Set(evidence.keys)))
                }
            }
            if let order { _ = try order.publishCompletedSeconds() }
        } catch { XCTFail("unexpected MIME reconciliation failure: \(error)") }
    }

    func release() {
        released = true
        response?.resume()
        response = nil
    }

    func result() throws -> (requests: [[[PhotoUID]]], classified: Int, images: Int, videos: Int, pending: [PhotoUID]) {
        let evidence = try XCTUnwrap(timeline.mediaTypeEvidence(volumeID: "first"))
        return (
            requests, evidence.count,
            evidence.values.filter { $0 == "image/jpeg" }.count,
            evidence.values.filter { $0 == "video/mp4" }.count,
            try order?.nextPage().map(\.uid) ?? []
        )
    }

    func close() {
        order?.close()
        timeline.close()
    }
}
