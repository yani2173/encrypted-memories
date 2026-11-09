import Foundation
import UploadFeature
import XCTest

@testable import UploadCore

@MainActor
final class BackupProblemListSessionTests: XCTestCase {
    func testRestartsAndActionsJoinOneReadAndOnePacedFollowUp() async {
        let readGate = Gate()
        let paceGate = Gate()
        var starts: [TimeInterval] = []
        var time: TimeInterval = 0
        var waits: [TimeInterval] = []
        let session = BackupProblemListSession(
            now: { time },
            sleep: {
                waits.append($0)
                await paceGate.hold()
            },
            read: {
                starts.append(time)
                if starts.count == 1 { await readGate.hold() }
                return self.snapshot(1_000)
            })
        session.requestRefresh()
        await readGate.waitForEntry()
        for _ in 0..<20 { session.requestRefresh() }
        await Task.yield()
        XCTAssertEqual(starts.count, 1, "status-key task restarts do not start another scan")
        readGate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(waits, [1])
        XCTAssertEqual(starts.count, 1)
        for _ in 0..<20 { session.requestRefresh() }
        time = 1
        paceGate.release()
        await session.waitUntilIdle()
        XCTAssertEqual(starts, [0, 1])
        XCTAssertEqual(session.total, 1_000)
        await session.shutdown()
    }

    func testRepeatedNearEndRequestsAppendOnlyOnePageAndEveryRowRemainsReachable() async {
        let session = BackupProblemListSession(read: { self.snapshot(1_000) })
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.rows.count, 200)
        XCTAssertTrue(session.requestNextPage())
        XCTAssertFalse(session.requestNextPage(), "a repeated near-end callback joins the pending append")
        await session.waitUntilIdle()
        XCTAssertEqual(session.rows.count, 400)
        while session.rows.count < session.total {
            XCTAssertTrue(session.requestNextPage())
            await session.waitUntilIdle()
        }
        XCTAssertEqual(Set(session.rows.map(\.id)).count, 1_000)
        await session.shutdown()
    }

    func testSmallerPagesReachEveryPhotoOnceWithoutAdditionalReads() async {
        for size in [50, 100] {
            var reads = 0
            let captured = snapshot(5_000)
            let session = BackupProblemListSession(
                pageSize: size,
                read: {
                    reads += 1
                    return captured
                })
            session.requestRefresh()
            await session.waitUntilIdle()
            XCTAssertEqual(session.rows.count, size)
            var expected = size
            while session.rows.count < session.total {
                XCTAssertTrue(session.requestNextPage())
                await session.waitUntilIdle()
                expected = min(expected + size, 5_000)
                XCTAssertEqual(session.rows.count, expected)
                if session.rows.count != expected { break }
            }
            XCTAssertEqual(session.rows.map(\.id), captured.rows.map(\.id))
            XCTAssertEqual(reads, 1)
            await session.shutdown()
        }
    }

    func testFailedRefreshKeepsVisibleRowsAndLoadedPageProgress() async {
        var fail = false
        let session = BackupProblemListSession(
            now: { 10 }, sleep: { _ in },
            read: {
                fail ? nil : self.snapshot(1_000)
            })
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertTrue(session.requestNextPage())
        await session.waitUntilIdle()
        let visible = session.rows
        fail = true
        session.requestRefresh()
        XCTAssertEqual(session.rows, visible)
        await session.waitUntilIdle()
        XCTAssertEqual(session.rows, visible)
        XCTAssertEqual(session.total, 1_000)
        XCTAssertTrue(session.isUnavailable)
        await session.shutdown()
    }

    func testARefreshKeepsTheLoadedPrefixInsteadOfResettingToPageOne() async {
        let session = BackupProblemListSession(now: { 10 }, sleep: { _ in }, read: { self.snapshot(1_000) })
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertTrue(session.requestNextPage())
        await session.waitUntilIdle()
        let ids = session.rows.map(\.id)
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.rows.map(\.id), ids)
        await session.shutdown()
    }

    #if DEBUG
        func testShutdownRejectsALateReadAndEveryLaterAdmission() async {
            let gate = Gate()
            var reads = 0
            let session = BackupProblemListSession(read: {
                reads += 1
                await gate.hold()
                return self.snapshot(1_000)
            })
            var publishedAfterRetirement = false
            session.onPublicationEvent = { event in
                if event == .didApply, session.isRetired, !session.rows.isEmpty {
                    publishedAfterRetirement = true
                }
            }
            session.requestRefresh()
            await gate.waitForEntry()
            let shutdown = Task { await session.shutdown() }
            await Task.yield()
            gate.release()
            await shutdown.value
            XCTAssertFalse(publishedAfterRetirement, "A late read must never publish rows into a retired session")
            XCTAssertTrue(session.rows.isEmpty)
            session.requestRefresh()
            await Task.yield()
            XCTAssertEqual(reads, 1)
            gate.release()
            await session.waitUntilIdle()
            session.onPublicationEvent = nil
        }
    #endif

    func testNearEndAdmissionLoadsPagesWithoutScanningAgain() async throws {
        var reads = 0
        let captured = snapshot(5_000)
        let session = BackupProblemListSession(
            now: { 10 }, sleep: { _ in },
            read: {
                reads += 1
                return captured
            })
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertFalse(session.requestNextPage(near: session.rows[159].item))
        XCTAssertTrue(session.requestNextPage(near: session.rows[160].item))
        XCTAssertFalse(session.requestNextPage(near: session.rows[199].item))
        await session.waitUntilIdle()
        var expected = 400
        XCTAssertEqual(session.rows.count, expected)
        while session.rows.count < session.total {
            let last = try XCTUnwrap(session.rows.last)
            XCTAssertTrue(session.requestNextPage(near: last.item))
            await session.waitUntilIdle()
            expected = min(expected + 200, 5_000)
            XCTAssertEqual(session.rows.count, expected)
            XCTAssertEqual(session.rows.map(\.id), captured.rows.prefix(expected).map(\.id))
        }
        XCTAssertEqual(session.rows.map(\.id), captured.rows.map(\.id))
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(session.requestNextPage(near: try XCTUnwrap(session.rows.last).item))
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(reads, 2, "Only a refresh reads the complete snapshot again")
        XCTAssertEqual(session.rows.count, 5_000)
        XCTAssertEqual(session.rows.map(\.id), captured.rows.map(\.id))
        await session.shutdown()
    }

    func testDismissalRemovesOnlyItsLoadedRowAndRefreshKeepsTheLoadedPrefix() async throws {
        var captured = snapshot(1_000)
        let session = BackupProblemListSession(now: { 10 }, sleep: { _ in }, read: { captured })
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertTrue(session.requestNextPage())
        await session.waitUntilIdle()
        let removed = session.rows[249].item
        let before = session.rows.map(\.id)
        session.dismissItem(id: removed.id)
        XCTAssertEqual(session.rows.map(\.id), before.filter { $0 != before[249] })
        XCTAssertEqual(session.total, 999)
        captured = BackupProblemSnapshot(items: captured.rows.map(\.item).filter { $0.id != removed.id })
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.rows.count, 399)
        XCTAssertEqual(session.rows.map(\.id), before.filter { $0 != before[249] })
        XCTAssertEqual(session.total, 999)
        await session.shutdown()
        XCTAssertTrue(session.isRetired)
    }

    #if DEBUG
        func testRefreshRetainsNearEndDemandWhenItCancelsAnOlderPage() async throws {
            let captured = snapshot(1_000)
            let session = BackupProblemListSession(now: { 10 }, sleep: { _ in }, read: { captured })
            session.requestRefresh()
            await session.waitUntilIdle()
            let last = try XCTUnwrap(session.rows.last)
            session.onPublicationEvent = { event in
                if event == .willApply {
                    XCTAssertTrue(session.requestNextPage(near: last.item))
                }
            }
            session.requestRefresh()
            await session.waitUntilIdle()
            XCTAssertEqual(session.rows.count, 400, "A surviving visible near-end row must not strand the next page")
            XCTAssertEqual(session.rows.map(\.id), Array(captured.rows.prefix(400)).map(\.id))
            session.onPublicationEvent = nil
            await session.shutdown()
        }
    #endif

    func testCompletedEmptyReadWithPositiveSummaryUsesExistingUnavailableState() async {
        let session = BackupProblemListSession(read: { self.snapshot(0) })
        XCTAssertEqual(session.presentation(expectsItems: true), .loading)
        XCTAssertEqual(
            session.presentation(expectsItems: false), .loading,
            "no answer that nobody read yet: never empty before a read")
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.presentation(expectsItems: true), .unavailable)
        XCTAssertEqual(session.presentation(expectsItems: false), .empty)
        await session.shutdown()
    }

    func testUncommittedDecisionKeepsItsRowAndReason() async throws {
        let session = BackupProblemListSession(now: { 10 }, sleep: { _ in }, read: { self.snapshot(1_000) })
        session.requestRefresh()
        await session.waitUntilIdle()
        let before = session.rows
        XCTAssertFalse(session.resolveDecision(try XCTUnwrap(before.first).item, using: { false }))
        XCTAssertEqual(session.rows, before)
        XCTAssertEqual(session.total, 1_000)
        await session.waitUntilIdle()
        await session.shutdown()
    }

    func testRetiredSessionNeverStartsAnotherDecision() async {
        let session = BackupProblemListSession(read: { self.snapshot(1) })
        session.requestRefresh()
        await session.waitUntilIdle()
        let item = session.rows[0].item
        await session.shutdown()
        var calls = 0
        XCTAssertFalse(
            session.resolveDecision(item) {
                calls += 1
                return true
            })
        XCTAssertEqual(calls, 0)
    }

    private func snapshot(_ count: Int) -> BackupProblemSnapshot {
        BackupProblemSnapshot(
            items: (0..<count).map {
                BackupFailedItem(id: "\($0)", filename: "Photo \($0)", reason: "Reason", isPermanent: false)
            })
    }

    @MainActor
    private final class Gate {
        private var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            observer?.resume()
            observer = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitForEntry() async {
            if !entered { await withCheckedContinuation { observer = $0 } }
        }
        func release() {
            waiter?.resume()
            waiter = nil
        }
    }
}
