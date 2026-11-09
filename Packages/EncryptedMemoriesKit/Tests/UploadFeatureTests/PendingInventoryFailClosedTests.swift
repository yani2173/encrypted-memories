import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// The pending grid changes its cached queue rows only from complete reads (#1004 B2). Each case fails statements
/// of the real queue store on its own connection. A later marker row in the same ordered change stream shows that
/// the coordinator handled the failed event.
final class PendingInventoryFailClosedTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var store: PendingBackupManifestStore!
    private var recorder: PendingBackupEventRecorder!
    private var coordinator: PendingBackupCoordinator!
    private var faults: [() -> Void] = []
    private let date = Date(timeIntervalSince1970: 1_750_000_000)
    private let revision = UploadBackupRevision(rawValue: 9)
    private let earlierMain = PhotoUID(volumeID: "volume", nodeID: "earlier-main")

    /// The decision read of every queue row: the full inventory and the keyed reload.
    private static let rowRead = "SELECT source_kind, source_id, resource, revision_us, state, original_filename"
    private static let inventoryRead = "state NOT IN ('alreadyBackedUp'"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        store = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
    }

    override func tearDown() async throws {
        faults.forEach { $0() }
        await coordinator?.close()
        recorder.finish()
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        queue.close()
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        uncheckedAdmissionLimit: Int = 64,
        observing: (any UploadBackupSyncQueueObserving)? = nil,
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> PendingBackupCoordinator {
        let coordinator = PendingBackupCoordinator(
            store: store, queues: [.photoLibraryAsset: observing ?? queue], metadataProvider: EveryKeyMetadata(),
            effects: InertPendingEffects(), recorder: recorder,
            configuration: .init(
                membershipInterval: .zero, progressInterval: .milliseconds(1), doneLinger: .milliseconds(20),
                uncheckedAdmissionLimit: uncheckedAdmissionLimit, libraryChangeDelay: .zero),
            now: { [date] in date }, sleep: sleep)
        self.coordinator = coordinator
        return coordinator
    }

    private func source(_ id: String) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary)
    }

    private func key(_ id: String) -> PendingSourceKey { PendingSourceKey(kind: .photoLibraryAsset, identifier: id) }

    private func enqueue(_ id: String, _ state: UploadBackupSyncQueueState, revision: Int64 = 9) {
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id), revision: UploadBackupRevision(rawValue: revision),
                    originalFilename: "\(id).heic", state: state, updatedAt: date)))
    }

    private func install(_ fault: SQLiteStatementFaults) -> SQLiteStatementFaults {
        faults.append { fault.stop() }
        return fault
    }

    private func tiles() async -> Set<String> {
        Set(await coordinator.currentSnapshot().tiles.map(\.key.identifier))
    }

    /// Waits for a tile that the coordinator shows once it handled every earlier queue change.
    @discardableResult
    private func waitForTile(_ id: String) async -> PendingBackupSnapshot {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let snapshot = await coordinator.currentSnapshot()
            if snapshot.tiles.contains(where: { $0.key.identifier == id }) { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await coordinator.currentSnapshot()
        XCTFail("the tile \(id) never showed; tiles: \(snapshot.tiles.map(\.key.identifier))")
        return snapshot
    }

    /// Fails when the condition stops holding at any point within the window.
    private func assertStays(_ description: String, for window: Duration, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            guard condition() else { return XCTFail(description) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), description)
    }

    /// The retry delay of an owed full read held on `gate`; every other wait runs normally.
    private func gatedRetry(_ gate: RetryGate) -> @Sendable (Duration) async throws -> Void {
        { duration in
            if duration == .seconds(2) { await gate.wait() } else { try await Task.sleep(for: duration) }
        }
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), description)
    }

    // MARK: - Row 1: the full inventory after `.all`

    /// A failed full inventory and failed keyed reloads keep every cached row, its tile and its replacement evidence.
    func testAFailedFullInventoryKeepsEveryCachedRow() async throws {
        enqueue("first", .queuedForUpload)
        enqueue("second", .queuedForUpload)
        enqueue("stuck", .failed)
        recorder.recordUploadEvidence(source: source("first"), revision: revision, replaces: [earlierMain])
        let coordinator = makeCoordinator()
        await coordinator.start()
        let healthy = await tiles()
        XCTAssertTrue(healthy.isSuperset(of: ["first", "second"]), "healthy reads show both rows: \(healthy)")

        let fault = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && !$0.contains("'marker'") })
        XCTAssertEqual(queue.requeueFailed(updatedAt: date), 1, "the requeue announces a change of every row")
        await waitUntil("the inventory read failed") { fault.firedCount > 0 }
        enqueue("marker", .queuedForUpload)
        let snapshot = await waitForTile("marker")

        let shown = Set(snapshot.tiles.map(\.key.identifier))
        XCTAssertTrue(shown.isSuperset(of: ["first", "second"]), "an unknown inventory removes no tile: \(shown)")
        XCTAssertNotNil(
            recorder.replacementLedger.evidence(for: key("first"), revision: revision),
            "an unknown inventory drops no replacement evidence")
    }

    // MARK: - Rows 2 and 4: the inventory at start and admission

    /// An inventory that fails after a prefix certifies nothing: the prefix does not count as the whole queue.
    func testAFailedInitialInventoryAdmitsNoPrefix() async throws {
        for index in 0..<3 { enqueue("unchecked-\(index)", .discovered) }
        // The interrupt armed by the second row also ends the step that returns it, so the prefix is one row.
        let probe = try SQLiteReadInterrupt(in: queue!, matching: Self.inventoryRead, afterRows: 2)
        XCTAssertThrowsError(try queue.decisionUnsettledRows(), "the fixture cuts the read short")
        XCTAssertTrue(probe.fired)
        XCTAssertEqual(probe.tracedRows, 2, "the second row arms the interrupt, so one row came before it")
        probe.stop()
        let fault = try SQLiteReadInterrupt(in: queue!, matching: Self.inventoryRead, afterRows: 2)
        faults.append { fault.stop() }
        let gate = RetryGate()
        defer { gate.release() }
        let coordinator = makeCoordinator(uncheckedAdmissionLimit: 2, sleep: gatedRetry(gate))
        await coordinator.start()
        XCTAssertTrue(fault.fired)
        let afterStart = await tiles()
        XCTAssertTrue(afterStart.isEmpty, "a prefix of three unchecked photos admits none: \(afterStart)")

        enqueue("marker", .queuedForUpload)
        let owed = await waitForTile("marker")
        XCTAssertEqual(Set(owed.tiles.map(\.key.identifier)), ["marker"], "no unchecked photo while the queue is owed")

        fault.stop()
        let reads = install(try SQLiteStatementFaults(in: queue!, fails: false) { $0.contains(Self.inventoryRead) })
        gate.release()
        await waitUntil("the retry read the complete inventory") { reads.matchedCount > 0 }
        enqueue("second-marker", .queuedForUpload)
        let snapshot = await waitForTile("second-marker")
        XCTAssertEqual(
            Set(snapshot.tiles.map(\.key.identifier)), ["marker", "second-marker"],
            "the complete inventory has three unchecked photos, above the limit of two")
    }

    /// While the inventory is unknown, a few unchecked photos from keyed reads are not proof of a small scan.
    func testUncheckedPhotosWaitWhileTheInventoryIsUnknown() async throws {
        let gate = RetryGate()
        defer { gate.release() }
        let fault = install(try SQLiteStatementFaults(in: queue!) { $0.contains(Self.inventoryRead) })
        let coordinator = makeCoordinator(sleep: gatedRetry(gate))
        await coordinator.start()
        XCTAssertGreaterThan(fault.firedCount, 0, "the initial inventory failed")

        enqueue("late", .discovered)
        enqueue("marker", .queuedForUpload)
        let unknown = await waitForTile("marker")
        XCTAssertFalse(
            unknown.tiles.contains { $0.key.identifier == "late" },
            "an unchecked photo waits while the queue's size is unknown")

        fault.stop()
        // The events above scheduled one retry of the owed full read; it now reads the queue.
        gate.release()
        await waitForTile("late")
    }

    /// An unknown inventory does not wait for a queue change: the app becoming active reads it again.
    func testAnUnknownInventoryIsReadAgainWhenTheAppBecomesActive() async throws {
        enqueue("waiting", .queuedForUpload)
        let fault = install(try SQLiteStatementFaults(in: queue!) { $0.contains(Self.inventoryRead) })
        let coordinator = makeCoordinator()
        await coordinator.start()
        XCTAssertGreaterThan(fault.firedCount, 0, "the initial inventory failed")
        let unknown = await tiles()
        XCTAssertTrue(unknown.isEmpty, "only the inventory names this row: \(unknown)")

        fault.stop()
        await coordinator.noteLibraryChanged()
        await waitForTile("waiting")
    }

    /// The coordinator uses the real store's complete inventory, not the protocol's throwing default.
    func testTheRealStoreCertifiesTheInventory() async throws {
        enqueue("queued", .queuedForUpload)
        // A settled row is not part of the inventory; a broader read would return it too.
        enqueue("settled", .completed)
        let observing: any UploadBackupSyncQueueObserving = queue
        XCTAssertEqual(try observing.decisionUnsettledRows().map(\.source.identifier), ["queued"])
        let coordinator = makeCoordinator()
        await coordinator.start()
        let shown = await tiles()
        XCTAssertEqual(shown, ["queued"], "only the inventory names this row")
    }

    // MARK: - Row 3: keyed reloads

    /// A failed keyed reload keeps the cached row, its tile and its evidence, and the next event reads it again.
    func testAFailedKeyedReloadKeepsTheRowAndReadsItAgain() async throws {
        enqueue("keyed-row", .queuedForUpload)
        recorder.recordUploadEvidence(source: source("keyed-row"), revision: revision, replaces: [earlierMain])
        let coordinator = makeCoordinator()
        await coordinator.start()
        let healthy = await tiles()
        XCTAssertEqual(healthy, ["keyed-row"])

        let fault = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'keyed-row'") })
        XCTAssertTrue(
            queue.updateState(
                source: source("keyed-row"), revision: revision, state: .failedPermanent, attempts: nil,
                lastError: nil, updatedAt: date))
        await waitUntil("the keyed reload failed") { fault.firedCount > 0 }
        fault.stop()

        enqueue("marker", .queuedForUpload)
        let snapshot = await waitForTile("marker")
        XCTAssertNotNil(
            recorder.replacementLedger.evidence(for: key("keyed-row"), revision: revision),
            "an unknown keyed read drops no replacement evidence")
        XCTAssertEqual(
            snapshot.tiles.first { $0.key.identifier == "keyed-row" }?.badge, .attention,
            "the next event reads the row again and shows its new state")
    }

    /// An empty keyed request means no rows: never all rows, and no read that could fail.
    func testAnEmptyKeyedDecisionReadIsNoRows() throws {
        enqueue("stored", .queuedForUpload)
        enqueue("broken", .failedPermanent)
        XCTAssertEqual(try queue.decisionRows(kind: .photoLibraryAsset, identifiers: []), [], "other rows are stored")
        let connection = try storeConnection(queue!)
        try SerializedImageMutation.install(on: connection) { image in
            let range = try XCTUnwrap(image.firstRange(of: Array("failedPermanent".utf8)))
            image[range.lowerBound] = UInt8(ascii: "x")
        }
        XCTAssertThrowsError(try queue.decisionRows(kind: .photoLibraryAsset, identifiers: ["broken"]))
        XCTAssertFalse(queue.isOperational(), "an undecodable row is a lasting failure")
        XCTAssertThrowsError(try queue.decisionRows(kind: .photoLibraryAsset, identifiers: ["stored"]))
        XCTAssertEqual(
            try queue.decisionRows(kind: .photoLibraryAsset, identifiers: []), [],
            "an empty request is answered without a read, also on a failed connection")
    }

    // MARK: - Row 5: earlier revisions

    /// An edit whose earlier revisions cannot be read does not show beside its backed-up photo.
    func testAnUnknownEarlierRevisionHidesTheEditUntilRead() async throws {
        enqueue("edit", .completed, revision: 1)
        enqueue("edit", .discovered, revision: 2)
        let fault = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'edit'") })
        let coordinator = makeCoordinator()
        await coordinator.start()
        XCTAssertGreaterThan(fault.firedCount, 0, "the earlier-revision read failed")
        let unknown = await tiles()
        XCTAssertFalse(unknown.contains("edit"), "the edit may belong to a backed-up photo: \(unknown)")

        fault.stop()
        enqueue("marker", .queuedForUpload)
        let snapshot = await waitForTile("marker")
        XCTAssertFalse(
            snapshot.tiles.contains { $0.key.identifier == "edit" },
            "a certified read shows the earlier backup, so the edit waits for its check")
    }

    // MARK: - Review round: settled rows, earlier revisions, retry cost

    private func waitForBadge(_ id: String, _ badge: PendingUploadBadge) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await coordinator.currentSnapshot().tiles.first(where: { $0.key.identifier == id })?.badge == badge {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let shown = await coordinator.currentSnapshot().tiles.first { $0.key.identifier == id }?.badge
        XCTFail("the tile \(id) never showed \(badge); it shows \(String(describing: shown))")
    }

    /// After a complete inventory, a source whose keyed reload fails keeps its cached row: a photo that just settled,
    /// whose handoff event has not arrived yet, keeps its tile.
    func testAFailedReloadAfterACompleteInventoryKeepsTheCachedRow() async throws {
        enqueue("settling", .uploading)
        enqueue("stuck", .failed)
        let coordinator = makeCoordinator()
        await coordinator.start()
        await waitForTile("settling")

        let fault = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'settling'") })
        XCTAssertTrue(
            queue.updateState(
                source: source("settling"), revision: revision, state: .completed, attempts: nil, lastError: nil,
                updatedAt: date))
        await waitUntil("the keyed reload failed") { fault.firedCount > 0 }
        XCTAssertEqual(queue.requeueFailed(updatedAt: date), 1, "the requeue announces a change of every row")
        await waitUntil("the reload after the complete inventory failed") { fault.firedCount > 1 }
        // The requeued photo becomes unchecked and shows once the coordinator handled the `.all` event.
        let snapshot = await waitForTile("stuck")
        XCTAssertTrue(
            snapshot.tiles.contains { $0.key.identifier == "settling" },
            "a failed reload is not an absent row: \(snapshot.tiles.map(\.key.identifier))")
    }

    /// A new photo whose earlier-revision read failed shows once a later read answers, also without an earlier backup.
    func testAnUnknownEarlierRevisionWithoutABackupShowsAfterTheNextRead() async throws {
        enqueue("fresh", .discovered)
        let fault = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'fresh'") })
        let coordinator = makeCoordinator()
        await coordinator.start()
        XCTAssertGreaterThan(fault.firedCount, 0, "the earlier-revision read failed")
        let unknown = await tiles()
        XCTAssertFalse(unknown.contains("fresh"), "an unknown earlier revision holds the photo: \(unknown)")

        fault.stop()
        enqueue("marker", .queuedForUpload)
        await waitForTile("marker")
        await waitForTile("fresh")
    }

    /// Unknown earlier revisions at the admission limit are read again and shown.
    func testUnknownEarlierRevisionsAtTheLimitAreReadAgain() async throws {
        enqueue("limit-a", .discovered)
        enqueue("limit-b", .discovered)
        let fault = install(
            try SQLiteStatementFaults(in: queue!) {
                $0.contains(Self.rowRead) && ($0.contains("'limit-a'") || $0.contains("'limit-b'"))
            })
        let coordinator = makeCoordinator(uncheckedAdmissionLimit: 2)
        await coordinator.start()
        XCTAssertGreaterThan(fault.firedCount, 0, "the earlier-revision read failed")
        let unknown = await tiles()
        XCTAssertTrue(unknown.isDisjoint(with: ["limit-a", "limit-b"]), "both photos wait: \(unknown)")

        fault.stop()
        enqueue("marker", .queuedForUpload)
        await waitForTile("limit-a")
        await waitForTile("limit-b")
    }

    /// A keyed reload returns every revision of its sources, so it answers their unknown earlier revisions: a second
    /// read that fails cannot hide the photo.
    func testAKeyedReloadAnswersAnUnknownEarlierRevision() async throws {
        enqueue("rechecked", .discovered)
        let first = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'rechecked'") })
        let coordinator = makeCoordinator()
        await coordinator.start()
        XCTAssertGreaterThan(first.firedCount, 0, "the earlier-revision read failed")
        let unknown = await tiles()
        XCTAssertFalse(unknown.contains("rechecked"), "an unknown earlier revision holds the photo: \(unknown)")

        first.stop()
        // The event's own reload is the first keyed read; only a second read of the same source would fail.
        let second = try SQLiteReadInterrupt(in: queue!, matching: Self.rowRead, occurrence: 2)
        faults.append { second.stop() }
        XCTAssertTrue(
            queue.updateState(
                source: source("rechecked"), revision: revision, state: .checking, attempts: nil, lastError: nil,
                updatedAt: date))
        await waitForTile("rechecked")
    }

    private func row(_ id: String, _ state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: source(id), revision: revision, originalFilename: "\(id).heic", state: state, updatedAt: date)
    }

    private func faulting(_ ids: [String]) throws -> SQLiteStatementFaults {
        install(
            try SQLiteStatementFaults(in: queue!) { sql in
                sql.contains(Self.rowRead) && ids.contains { sql.contains("'\($0)'") }
            })
    }

    /// Builds four unknown photos with an admission limit of two: `a-checked` and `b-checked` left the admission count
    /// through their upload evidence, `c-wait` and `d-wait` wait for their earlier-revision read. Returns the fault that
    /// still fails all four.
    private func makeFourUnknownPhotos(
        observing: (any UploadBackupSyncQueueObserving)? = nil
    ) async throws -> SQLiteStatementFaults {
        XCTAssertTrue(queue.upsertBatch([row("a-checked", .discovered), row("b-checked", .discovered)]))
        let first = try faulting(["a-checked", "b-checked"])
        let coordinator = makeCoordinator(uncheckedAdmissionLimit: 2, observing: observing)
        await coordinator.start()
        XCTAssertGreaterThan(first.firedCount, 0, "the earlier-revision reads failed")
        // Upload evidence takes both out of the admission count; they stay unchecked and unknown.
        recorder.recordUploadEvidence(source: source("a-checked"), revision: revision)
        recorder.recordUploadEvidence(source: source("b-checked"), revision: revision)
        await waitForTile("a-checked")
        await waitForTile("b-checked")
        // A scan above the limit closes the admission; two more photos arrive while it is closed.
        XCTAssertTrue(
            queue.upsertBatch([row("e-scan", .discovered), row("f-scan", .discovered), row("g-scan", .discovered)]))
        XCTAssertTrue(queue.upsertBatch([row("c-wait", .discovered), row("d-wait", .discovered)]))
        enqueue("marker", .queuedForUpload)
        await waitForTile("marker")
        first.stop()
        let second = try faulting(["a-checked", "b-checked", "c-wait", "d-wait"])
        // The scan settles: the admission opens for the two waiting photos, and their earlier-revision read fails.
        for id in ["e-scan", "f-scan", "g-scan"] {
            XCTAssertTrue(
                queue.updateState(
                    source: source(id), revision: revision, state: .completed, attempts: nil, lastError: nil,
                    updatedAt: date))
        }
        enqueue("second-marker", .queuedForUpload)
        let closed = await waitForTile("second-marker")
        XCTAssertGreaterThan(second.firedCount, 0, "the earlier-revision read of the waiting photos failed")
        XCTAssertTrue(
            Set(closed.tiles.map(\.key.identifier)).isDisjoint(with: ["c-wait", "d-wait"]),
            "four unknown photos, two above the limit, wait")
        return second
    }

    /// More unknown earlier revisions than the admission limit are read in turns within one retry, so none of them
    /// stays hidden and none waits for a further event.
    func testMoreUnknownEarlierRevisionsThanTheLimitAreReadInTurns() async throws {
        let reads = CountingDecisionReads(queue)
        let fault = try await makeFourUnknownPhotos(observing: reads)
        fault.stop()
        reads.reset()
        enqueue("third-marker", .queuedForUpload)
        let shown = Set(await waitForTile("third-marker").tiles.map(\.key.identifier))
        XCTAssertTrue(shown.isSuperset(of: ["c-wait", "d-wait"]), "one retry reads every unknown photo: \(shown)")
        // Each turn is one read of at most the admission limit: two reads of two, not one read per photo.
        let retryReads = reads.identifierSets.filter { !$0.contains("third-marker") }
        XCTAssertEqual(retryReads.map(\.count), [2, 2], "the retry reads in turns of the limit: \(retryReads)")
    }

    /// A read that keeps failing for one photo holds only that photo: its neighbours in the same turn are read alone.
    func testOneFailingPhotoHoldsOnlyItself() async throws {
        let fault = try await makeFourUnknownPhotos()
        fault.stop()
        _ = try faulting(["c-wait"])
        enqueue("third-marker", .queuedForUpload)
        let shown = Set(await waitForTile("third-marker").tiles.map(\.key.identifier))
        XCTAssertTrue(shown.contains("d-wait"), "the neighbour of the failing photo shows: \(shown)")
        XCTAssertFalse(shown.contains("c-wait"), "the photo whose read fails still waits")
    }

    /// Unknown photos that leave the unchecked states through a full read leave the retry too, so they never take the
    /// retry's places from a photo that still waits.
    func testPhotosThatLeaveTheCheckThroughAFullReadLeaveTheRetry() async throws {
        // Two photos whose upload reached Proton: the runner claimed them back to `checking` with their receipt.
        for id in ["a-stale", "b-stale"] {
            XCTAssertTrue(queue.upsert(row(id, .queuedForUpload)))
            let receipt = UploadRemoteCommitReconciliation(
                source: source(id),
                identity: UploadIdentity(
                    correctedName: "\(id).heic", nameHash: "name-\(id)", sha1Hex: String(repeating: "ab", count: 20),
                    sha1Digest: Data(repeating: 0xAB, count: 20), contentHash: "content-\(id)"),
                receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link-\(id)"),
                queueBinding: UploadRemoteCommitQueueBinding(source: source(id), revision: revision))
            XCTAssertTrue(
                queue.markNeedsRemoteReconciliation(
                    source: source(id), revision: revision, reconciliation: receipt, lastError: nil,
                    updatedAt: date.addingTimeInterval(-60)))
        }
        let claimed = try XCTUnwrap(queue.claimRunnable(limit: 10, claimedAt: date, excludingSourcesOf: []))
        XCTAssertEqual(Set(claimed.map(\.source.identifier)), ["a-stale", "b-stale"])
        for id in ["a-stale", "b-stale"] {
            // The claim returns the rows as it selected them; the stored row is `checking` and keeps its receipt.
            let stored = try XCTUnwrap(try queue.entry(for: source(id), revision: revision))
            XCTAssertEqual(stored.state, .checking)
            XCTAssertNotNil(stored.remoteCommitReconciliation)
        }

        // Their earlier-revision read fails at start, so both are unknown.
        let first = try faulting(["a-stale", "b-stale"])
        let coordinator = makeCoordinator(uncheckedAdmissionLimit: 2)
        await coordinator.start()
        XCTAssertGreaterThan(first.firedCount, 0, "the earlier-revision read failed")
        // A scan above the limit closes the admission; one more photo arrives while it is closed.
        XCTAssertTrue(
            queue.upsertBatch([row("e-scan", .discovered), row("f-scan", .discovered), row("g-scan", .discovered)]))
        enqueue("z-wait", .discovered)
        // The stale claims return to reconciliation through `.all`, without a keyed read of the two photos.
        XCTAssertEqual(queue.requeueStaleActive(before: date.addingTimeInterval(60), updatedAt: date), 2)
        enqueue("marker", .queuedForUpload)
        await waitForTile("marker")
        first.stop()
        // The scan settles: the admission opens for the waiting photo, and its earlier-revision read fails.
        let second = try faulting(["z-wait"])
        for id in ["e-scan", "f-scan", "g-scan"] {
            XCTAssertTrue(
                queue.updateState(
                    source: source(id), revision: revision, state: .completed, attempts: nil, lastError: nil,
                    updatedAt: date))
        }
        enqueue("second-marker", .queuedForUpload)
        let waiting = await waitForTile("second-marker")
        XCTAssertGreaterThan(second.firedCount, 0, "the earlier-revision read of the waiting photo failed")
        XCTAssertFalse(waiting.tiles.contains { $0.key.identifier == "z-wait" }, "the waiting photo is unknown")

        second.stop()
        enqueue("third-marker", .queuedForUpload)
        await waitForTile("third-marker")
        await waitForTile("z-wait")
    }

    /// After a complete inventory, an unchecked photo whose earlier revisions are unknown and whose keyed reload fails
    /// keeps its earlier-revision hold together with its last known row.
    func testAFailedReloadAfterACompleteInventoryKeepsTheEarlierRevisionHold() async throws {
        enqueue("held", .checking)
        enqueue("stuck", .failed)
        let fault = try faulting(["held"])
        let coordinator = makeCoordinator()
        await coordinator.start()
        let atStart = fault.firedCount
        XCTAssertGreaterThan(atStart, 0, "the earlier-revision read failed")
        let unknown = await tiles()
        XCTAssertFalse(unknown.contains("held"), "an unknown earlier revision holds the photo: \(unknown)")

        XCTAssertTrue(
            queue.updateState(
                source: source("held"), revision: revision, state: .alreadyBackedUp, attempts: nil, lastError: nil,
                updatedAt: date))
        await waitUntil("the keyed reload failed") { fault.firedCount > atStart }
        let afterKeyed = fault.firedCount
        XCTAssertEqual(queue.requeueFailed(updatedAt: date), 1, "the requeue announces a change of every row")
        await waitUntil("the reload after the complete inventory failed") { fault.firedCount > afterKeyed }
        // The requeued photo becomes unchecked and shows once the coordinator handled the `.all` event.
        let snapshot = await waitForTile("stuck")
        XCTAssertFalse(
            snapshot.tiles.contains { $0.key.identifier == "held" },
            "the restored row keeps its earlier-revision hold: \(snapshot.tiles.map(\.key.identifier))")
    }

    /// A `.all` event reads the owed keyed rows again, also when its own inventory fails.
    func testAnAllEventReadsOwedRowsAgainWhenItsInventoryFails() async throws {
        enqueue("keyed-row", .queuedForUpload)
        enqueue("stuck", .failed)
        recorder.recordUploadEvidence(source: source("keyed-row"), revision: revision, replaces: [earlierMain])
        let coordinator = makeCoordinator()
        await coordinator.start()
        await waitForTile("keyed-row")

        let keyed = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'keyed-row'") })
        XCTAssertTrue(
            queue.updateState(
                source: source("keyed-row"), revision: revision, state: .failedPermanent, attempts: nil,
                lastError: nil, updatedAt: date))
        await waitUntil("the keyed reload failed") { keyed.firedCount > 0 }
        keyed.stop()
        let inventory = install(try SQLiteStatementFaults(in: queue!) { $0.contains(Self.inventoryRead) })
        XCTAssertEqual(queue.requeueFailed(updatedAt: date), 1, "the requeue announces a change of every row")
        await waitUntil("the inventory of the event failed") { inventory.firedCount > 0 }
        await waitForBadge("keyed-row", .attention)
    }

    /// A keyed row that a later read answered is no longer owed: further events do not read it again.
    func testAnAnsweredRowIsReadOnlyOnceAfterItsFailure() async throws {
        enqueue("owed-once", .queuedForUpload)
        let coordinator = makeCoordinator()
        await coordinator.start()
        await waitForTile("owed-once")

        let fault = install(
            try SQLiteStatementFaults(in: queue!) { $0.contains(Self.rowRead) && $0.contains("'owed-once'") })
        XCTAssertTrue(
            queue.updateState(
                source: source("owed-once"), revision: revision, state: .uploading, attempts: nil, lastError: nil,
                updatedAt: date))
        await waitUntil("the keyed reload failed") { fault.firedCount > 0 }
        fault.stop()
        let reads = install(
            try SQLiteStatementFaults(in: queue!, fails: false) {
                $0.contains(Self.rowRead) && $0.contains("'owed-once'")
            })
        enqueue("first-marker", .queuedForUpload)
        await waitForTile("first-marker")
        XCTAssertEqual(reads.matchedCount, 1, "the next event reads the owed row once")
        enqueue("second-marker", .queuedForUpload)
        await waitForTile("second-marker")
        XCTAssertEqual(reads.matchedCount, 1, "an answered row is no longer owed")
    }

    /// While a full read is owed, a burst of queue events runs one full read per retry delay, not one per event.
    func testABurstOfEventsRunsOneOwedFullReadPerRetryDelay() async throws {
        let gate = RetryGate()
        defer { gate.release() }
        let fault = install(try SQLiteStatementFaults(in: queue!) { $0.contains(Self.inventoryRead) })
        let coordinator = makeCoordinator(sleep: { duration in
            // The default retry delay of an owed full read; every other wait runs normally.
            if duration == .seconds(2) { await gate.wait() } else { try await Task.sleep(for: duration) }
        })
        await coordinator.start()
        XCTAssertEqual(fault.firedCount, 1, "the start reads the inventory once")

        for index in 0..<5 { enqueue("burst-\(index)", .queuedForUpload) }
        enqueue("marker", .queuedForUpload)
        await waitForTile("marker")
        XCTAssertEqual(fault.firedCount, 1, "the burst waits for one retry")
        await waitUntil("the retry waits") { gate.waiting >= 1 }
        // More retries would start at once; a correct coordinator keeps one for the whole window.
        await assertStays("one pending retry per kind", for: .milliseconds(200)) { gate.waiting == 1 }
        gate.release()
        await waitUntil("the retry read the inventory") { fault.firedCount == 2 }

        for index in 0..<5 { enqueue("second-burst-\(index)", .queuedForUpload) }
        enqueue("second-marker", .queuedForUpload)
        await waitForTile("second-marker")
        XCTAssertEqual(fault.firedCount, 2, "the next burst waits for the next retry")
    }

    /// Closing the coordinator cancels the pending retry of an owed full read. Every account teardown closes it.
    func testClosingCancelsThePendingRetry() async throws {
        let gate = RetryGate()
        let probe = CancellationProbe()
        let fault = install(try SQLiteStatementFaults(in: queue!) { $0.contains(Self.inventoryRead) })
        let coordinator = makeCoordinator(sleep: { duration in
            guard duration == .seconds(2) else { return try await Task.sleep(for: duration) }
            await gate.wait()
            probe.record(Task.isCancelled)
            try Task.checkCancellation()
        })
        await coordinator.start()
        enqueue("marker", .queuedForUpload)
        await waitForTile("marker")
        await coordinator.close()
        gate.release()
        await waitUntil("the retry woke up") { probe.value != nil }
        XCTAssertEqual(probe.value, true, "close cancels the pending retry")
        XCTAssertEqual(fault.firedCount, 1, "no full read after close")
    }

    /// A retry that wakes up after close reads nothing, also when its wait ignores the cancellation.
    func testARetryThatWakesAfterCloseReadsNothing() async throws {
        let gate = RetryGate()
        let probe = CancellationProbe()
        let fault = install(try SQLiteStatementFaults(in: queue!) { $0.contains(Self.inventoryRead) })
        let coordinator = makeCoordinator(sleep: { duration in
            guard duration == .seconds(2) else { return try await Task.sleep(for: duration) }
            await gate.wait()
            probe.record(Task.isCancelled)
        })
        await coordinator.start()
        enqueue("marker", .queuedForUpload)
        await waitForTile("marker")
        await coordinator.close()
        gate.release()
        await waitUntil("the retry woke up") { probe.value != nil }
        // A read after close would follow at once; a correct coordinator never reads during the window.
        await assertStays("no full read after close", for: .milliseconds(300)) { fault.firedCount == 1 }
    }
}

private struct EveryKeyMetadata: PendingSourceMetadataProviding {
    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        Dictionary(
            uniqueKeysWithValues: keys.map {
                (
                    $0,
                    PendingPresentationMetadata(
                        captureTime: Date(timeIntervalSince1970: 1_750_000_000), mediaType: "image/heic",
                        displayName: "\($0.identifier).heic")
                )
            })
    }
}

/// Holds each wait until a release; a release without a waiter lets the next wait pass.
private final class RetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                guard permits > 0 else {
                    waiters.append(continuation)
                    return false
                }
                permits -= 1
                return true
            }
            if passes { continuation.resume() }
        }
    }

    var waiting: Int { lock.withLock { waiters.count } }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !waiters.isEmpty else {
                permits += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }
}

/// Records whether the retry's task was cancelled when its wait ended.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Bool?

    var value: Bool? { lock.withLock { recorded } }

    func record(_ cancelled: Bool) { lock.withLock { recorded = cancelled } }
}

/// The real queue store, with a record of the identifier set of every complete keyed read.
private final class CountingDecisionReads: UploadBackupSyncQueueObserving, @unchecked Sendable {
    private let inner: UploadBackupSyncQueueManifestStore
    private let lock = NSLock()
    private var recorded: [Set<String>] = []

    init(_ inner: UploadBackupSyncQueueManifestStore) { self.inner = inner }

    var identifierSets: [Set<String>] { lock.withLock { recorded } }

    func reset() { lock.withLock { recorded.removeAll() } }

    func setChangeObserver(_ observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?) {
        inner.setChangeObserver(observer)
    }
    func changes() -> AsyncStream<UploadBackupSyncQueueChange> { inner.changes() }
    func decisionUnsettledRows() throws -> [UploadBackupQueueRowState] { try inner.decisionUnsettledRows() }
    func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision] {
        inner.backedUpRevisions(kind: kind)
    }
    func decisionRows(
        kind: UploadSourceIdentity.Kind, identifiers: Set<String>
    ) throws -> [UploadBackupQueueRowState] {
        lock.withLock { recorded.append(identifiers) }
        return try inner.decisionRows(kind: kind, identifiers: identifiers)
    }
}
