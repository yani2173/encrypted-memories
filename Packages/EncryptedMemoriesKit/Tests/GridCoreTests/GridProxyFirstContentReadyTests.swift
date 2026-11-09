import XCTest

@testable import GridCore

@MainActor
final class GridProxyFirstContentReadyTests: XCTestCase {
    func testHandlerInstalledBeforeReportReceivesEvent() {
        let proxy = GridProxy<String>()
        var deliveryCount = 0
        proxy.onFirstContentReady = { deliveryCount += 1 }

        proxy.reportFirstContentReady()

        XCTAssertEqual(deliveryCount, 1)
    }

    func testReportBeforeHandlerInstallationIsReplayed() {
        let proxy = GridProxy<String>()
        var deliveryCount = 0

        proxy.reportFirstContentReady()
        XCTAssertEqual(deliveryCount, 0)

        proxy.onFirstContentReady = { deliveryCount += 1 }
        XCTAssertEqual(deliveryCount, 1)
    }

    func testReadinessIsDeliveredExactlyOnce() {
        let proxy = GridProxy<String>()
        var deliveryCount = 0
        proxy.onFirstContentReady = { deliveryCount += 1 }

        proxy.reportFirstContentReady()
        proxy.reportFirstContentReady()
        proxy.onFirstContentReady = { deliveryCount += 1 }

        XCTAssertEqual(deliveryCount, 1)
    }

    func testContentReadinessRepeatsForNewDataGenerations() {
        let proxy = GridProxy<String>()
        var revisions: [UInt64] = []
        proxy.onContentReady = { revisions.append($0) }

        proxy.reportContentReady(revision: 4)
        proxy.reportContentReady(revision: 7)

        XCTAssertEqual(revisions, [4, 7])
    }

    func testLatestContentReadinessIsReplayedAfterHandlerInstallation() {
        let proxy = GridProxy<String>()
        var revisions: [UInt64] = []

        proxy.reportContentReady(revision: 4)
        proxy.reportContentReady(revision: 7)
        proxy.onContentReady = { revisions.append($0) }

        XCTAssertEqual(revisions, [7])
        proxy.reportContentReady(revision: 9)
        XCTAssertEqual(revisions, [7, 9])
    }

    func testInvalidationDiscardsUndeliveredReadinessAndAllowsNextFrame() {
        let proxy = GridProxy<String>()
        proxy.reportContentReady(revision: 4)
        proxy.invalidatePendingContentReady()
        var first = 0
        var revisions: [UInt64] = []
        proxy.onFirstContentReady = { first += 1 }
        proxy.onContentReady = { revisions.append($0) }
        XCTAssertEqual(first, 0)
        XCTAssertEqual(revisions, [])
        proxy.reportContentReady(revision: 7)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(revisions, [7])
    }
}
