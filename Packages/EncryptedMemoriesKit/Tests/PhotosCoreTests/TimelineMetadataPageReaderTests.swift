import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineMetadataPageReaderTests: XCTestCase {
    @MainActor
    func testReaderRebuildDuringANetworkPageReplansWithoutAMonitorChange() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        let passes = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        try await reader.prepare(isCurrent: { true })
        let first = try await reader.nextPage(isCurrent: { true })
        XCTAssertEqual(first.count, 150)
        XCTAssertEqual(first.first?.uid, fixture.inventory.items.first?.uid)
        let mediaRevision = fixture.timeline.mediaTypeEvidenceRevision()
        XCTAssertEqual(fixture.order.revision, 0)

        // A metadata request yields the owner after complete SQL preparation.
        await Task.yield()
        try rebuildThroughReader(fixture)
        XCTAssertTrue(fixture.order.record(absentOrder(first)))
        XCTAssertEqual(fixture.timeline.mediaTypeEvidenceRevision(), mediaRevision)
        XCTAssertEqual(fixture.order.revision, 0, "neither monitor revision schedules another pass")
        XCTAssertEqual(fixture.timeline.count(), 302, "base timeline photos stay visible")

        let resumed = try await reader.nextPage(isCurrent: { true })
        XCTAssertEqual(resumed.first?.uid, fixture.inventory.items.first?.uid, "the lost first page needs replay")
        var inspected = resumed.map(\.uid)
        XCTAssertTrue(fixture.order.record(absentOrder(resumed)))
        while true {
            let page = try await reader.nextPage(isCurrent: { true })
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 150)
            inspected += page.map(\.uid)
            XCTAssertTrue(fixture.order.record(absentOrder(page)))
        }
        XCTAssertEqual(inspected, fixture.inventory.items.map(\.uid))
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), passes + 2)
        XCTAssertTrue(try fixture.order.publishCompletedSeconds())
        XCTAssertTrue(try fixture.order.nextPage().isEmpty)
        XCTAssertEqual(fixture.order.revision, 1)
    }

    @MainActor
    func testReplanningPreservesFreshReaderCheckpointsAndDoesNotRepeatPreparation() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        let passes = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        try await reader.prepare(isCurrent: { true })
        _ = try await reader.nextPage(isCurrent: { true })
        try rebuildThroughReader(fixture)
        let saved = [fixture.inventory.items[0], fixture.inventory.items[301]]
        XCTAssertTrue(fixture.order.synchronize(saved, classifiedUIDs: Set(saved.map(\.uid))))
        XCTAssertTrue(
            fixture.order.record(Dictionary(uniqueKeysWithValues: saved.map { ($0.uid, TimelineOrderMetadata()) })))
        var inspected: [PhotoUID] = []
        while true {
            let page = try await reader.nextPage(isCurrent: { true })
            if page.isEmpty { break }
            inspected += page.map(\.uid)
            XCTAssertTrue(fixture.order.record(absentOrder(page)))
        }
        XCTAssertEqual(inspected, Array(fixture.inventory.items.dropFirst().dropLast()).map(\.uid))
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), passes + 3)
        XCTAssertEqual(fixture.order.rebuildRevision, 1, "replanning must not rebuild the reader's replacement again")
        XCTAssertTrue(try fixture.order.publishCompletedSeconds())
        XCTAssertTrue(try fixture.order.nextPage().isEmpty)
    }

    @MainActor
    func testOmittedResponseAfterRecoveryDoesNotRetryInsideTheSamePass() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        try await reader.prepare(isCurrent: { true })
        _ = try await reader.nextPage(isCurrent: { true })
        try rebuildThroughReader(fixture)
        let omitted = fixture.inventory.items[0].uid
        var requested: [PhotoUID] = []
        var completed = false
        // Bound the calls so a broken revision fence cannot make this regression hang.
        for _ in 0..<4 {
            let page = try await reader.nextPage(isCurrent: { true })
            if page.isEmpty {
                completed = true
                break
            }
            requested += page.map(\.uid)
            XCTAssertTrue(fixture.order.record(absentOrder(page.filter { $0.uid != omitted })))
        }
        XCTAssertTrue(completed, "one recovered pass must terminate even when a link is omitted")
        XCTAssertEqual(requested.count, fixture.inventory.items.count)
        XCTAssertEqual(Set(requested), Set(fixture.inventory.items.map(\.uid)))
        XCTAssertEqual(requested.filter { $0 == omitted }.count, 1, "a later pass can retry the missing response")
        XCTAssertEqual(try fixture.order.nextPage().map(\.uid), [omitted])
    }

    @MainActor
    func testRetiredPassCannotReprepareAReplacementInventory() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        try await reader.prepare(isCurrent: { true })
        _ = try await reader.nextPage(isCurrent: { true })
        try rebuildThroughReader(fixture)
        let replacement = PhotoItem(
            uid: PhotoUID(volumeID: "second", nodeID: "replacement"),
            captureTime: Date(timeIntervalSince1970: 900), mediaType: "image/jpeg")
        XCTAssertTrue(fixture.order.synchronize([replacement], classifiedUIDs: []))
        let passes = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        do {
            _ = try await reader.nextPage(isCurrent: { false })
            XCTFail("a retired pass must not read or restore its old inventory")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), passes)
        XCTAssertEqual(try fixture.order.nextPage().map(\.uid), [replacement.uid])
        XCTAssertEqual(fixture.order.rebuildRevision, 1)
    }

    @MainActor
    func testCancelledPassCannotEraseTheReaderReplacement() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        try await reader.prepare(isCurrent: { true })
        _ = try await reader.nextPage(isCurrent: { true })
        try rebuildThroughReader(fixture)
        let replacement = fixture.inventory.items[0]
        XCTAssertTrue(fixture.order.synchronize([replacement], classifiedUIDs: []))
        let passes = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        let task = Task { @MainActor in
            do {
                _ = try await reader.nextPage(isCurrent: { true })
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled, "cancellation must reject recovery before SQL or fallback rebuilding")
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), passes)
        XCTAssertEqual(try fixture.order.nextPage().map(\.uid), [replacement.uid])
        XCTAssertEqual(fixture.order.rebuildRevision, 1)
    }

    @MainActor
    func testRetirementAtRecoveryCompletionCannotReturnAStalePage() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        try await reader.prepare(isCurrent: { true })
        _ = try await reader.nextPage(isCurrent: { true })
        try rebuildThroughReader(fixture)
        var checks = 0
        do {
            _ = try await reader.nextPage(isCurrent: {
                checks += 1
                return checks < 3  // Admission succeeds; retirement precedes the post-await check.
            })
            XCTFail("recovery must reject retirement after its awaited preparation")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(fixture.order.rebuildRevision, 1)
    }

    @MainActor
    func testUnavailableOrderCacheKeepsBoundedUnclassifiedMIMEPages() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let items = fixture.inventory.items
        let inventory = TimelineMetadataReconciliation.Inventory(
            items: items,
            classifiedNodeIDs: Set(items.prefix(151).map { $0.uid.nodeID }), libraryID: "volume")
        let reader = TimelineMetadataPageReader(inventory: inventory, orderStore: nil)
        try await reader.prepare(isCurrent: { true })
        XCTAssertFalse(reader.useOrderCache)
        var inspected: [PhotoUID] = []
        while true {
            let page = try await reader.nextPage(isCurrent: { true })
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 150)
            XCTAssertTrue(page.allSatisfy { !$0.needsOrder })
            inspected += page.map(\.uid)
        }
        XCTAssertEqual(inspected, items.dropFirst(151).map(\.uid))
    }

    @MainActor
    func testFailedPreparationDoesNotEraseAReaderReplacement() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        fixture.order.close()
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        let replacement = fixture.inventory.items[0]
        var checks = 0
        // Replace the failed connection at the completion boundary, before the fallback decision.
        try await reader.prepare(isCurrent: {
            checks += 1
            if checks == 2 {
                fixture.order.rebuild()
                XCTAssertTrue(fixture.order.synchronize([replacement], classifiedUIDs: []))
            }
            return true
        })
        XCTAssertFalse(reader.useOrderCache)
        XCTAssertEqual(fixture.order.rebuildRevision, 1, "failed preparation must preserve a reader replacement")
        XCTAssertEqual(try fixture.order.nextPage().map(\.uid), [replacement.uid])
    }

    @MainActor
    func testRecoveryReadsItsPageBeforeAnEnqueuedReaderCanRebuildAgain() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: fixture.order)
        try await reader.prepare(isCurrent: { true })
        _ = try await reader.nextPage(isCurrent: { true })
        try rebuildThroughReader(fixture)
        var queuedReader: Task<Void, Never>?
        var checks = 0
        let page = try await reader.nextPage(isCurrent: {
            checks += 1
            if checks == 3 {
                // Queue a competing actor job at the final recovery check, immediately before return.
                queuedReader = Task(priority: .high) { @MainActor in fixture.order.rebuild() }
            }
            return true
        })
        XCTAssertEqual(page.count, 150, "same-actor recovery must read before the queued actor job")
        XCTAssertEqual(page.first?.uid, fixture.inventory.items.first?.uid)
        let queued = try XCTUnwrap(queuedReader)
        await queued.value
        XCTAssertEqual(fixture.order.rebuildRevision, 2, "the competing reader really ran")
    }

    @MainActor
    func testRetiredFallbackStopsBetweenEmptyMIMEChunks() async throws {
        let fixture = try fixture()
        defer {
            fixture.order.close()
            fixture.timeline.close()
        }
        let reader = TimelineMetadataPageReader(inventory: fixture.inventory, orderStore: nil)
        try await reader.prepare(isCurrent: { true })
        var checks = 0
        do {
            _ = try await reader.nextPage(isCurrent: {
                checks += 1
                return checks < 3
            })
            XCTFail("retirement between empty MIME chunks must stop the scan")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(checks, 3)
    }

    @MainActor
    private func fixture() throws -> (
        inventory: TimelineMetadataReconciliation.Inventory,
        order: TimelineOrderMetadataStore, timeline: TimelineMetadataStore, url: URL
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let items = (0..<302).map { index in
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: String(format: "%06d", index)),
                captureTime: Date(timeIntervalSince1970: Double(500 + index / 2)), mediaType: "image/jpeg")
        }
        let timeline = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        XCTAssertTrue(timeline.save(items, validationToken: "remote-token").succeeded)
        let url = directory.appendingPathComponent("order.sqlite")
        let order = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        let inventory = TimelineMetadataReconciliation.Inventory(
            items: items,
            classifiedNodeIDs: Set(items.map { $0.uid.nodeID }), libraryID: "volume")
        return (inventory, order, timeline, url)
    }

    @MainActor
    private func rebuildThroughReader(
        _ fixture: (
            inventory: TimelineMetadataReconciliation.Inventory,
            order: TimelineOrderMetadataStore, timeline: TimelineMetadataStore, url: URL
        )
    ) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE photo_order;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(fixture.order.enrich(fixture.inventory.items), fixture.inventory.items)
        XCTAssertEqual(fixture.order.rebuildRevision, 1)
    }

    private func absentOrder(_ page: [TimelineOrderMetadataStore.Candidate]) -> [PhotoUID: TimelineOrderMetadata] {
        Dictionary(uniqueKeysWithValues: page.map { ($0.uid, TimelineOrderMetadata()) })
    }
}
