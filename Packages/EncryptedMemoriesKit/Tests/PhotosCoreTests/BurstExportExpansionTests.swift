import XCTest

@testable import PhotosCore

final class BurstExportExpansionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 400_000)

    private func item(
        _ nodeID: String,
        volumeID: String = "vol",
        burst: Bool = false
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: nodeID),
            captureTime: base,
            mediaType: "image/jpeg",
            tags: burst ? [.bursts] : []
        )
    }

    private func group(count: Int, around origin: PhotoItem) -> [PhotoItem] {
        (0..<count).map { offset in
            PhotoItem(
                uid: PhotoUID(volumeID: origin.uid.volumeID, nodeID: "\(origin.uid.nodeID)-\(offset)"),
                captureTime: origin.captureTime.addingTimeInterval(Double(offset)),
                mediaType: "image/jpeg"
            )
        }
    }

    func testBurstCandidateWhoseGroupReadThrowsFailsTheWholeRequest() async {
        let burst = item("burst", burst: true)
        let result = await BurstExportExpansion.expand(
            sourceItems: [burst],
            preferredSeriesNameSource: burst,
            burstGroupReader: { _ in throw TestError.readFailed }
        )

        XCTAssertEqual(result, .burstReadFailed(failedSources: [burst]))
    }

    func testCancelledGroupReadIsNotAFailure() async {
        let burst = item("burst", burst: true)
        let result = await BurstExportExpansion.expand(
            sourceItems: [burst],
            preferredSeriesNameSource: burst,
            burstGroupReader: { _ in throw CancellationError() }
        )

        // A cancellation must not surface as a read failure: no failed source and no
        // alert-causing result, so the host shows nothing for an action it cancelled itself.
        XCTAssertEqual(result, .cancelled)
    }

    func testURLErrorCancelledGroupReadIsNotAFailure() async {
        let burst = item("burst", burst: true)
        let result = await BurstExportExpansion.expand(
            sourceItems: [burst],
            preferredSeriesNameSource: burst,
            burstGroupReader: { _ in throw URLError(.cancelled) }
        )

        // The transport rethrows URLSession's raw cancellation error, so it must
        // reach the host as a cancellation, not as a burst read failure.
        XCTAssertEqual(result, .cancelled)
    }

    func testNonBurstItemExportsAsSingleItem() async {
        let plain = item("plain")
        let result = await BurstExportExpansion.expand(
            sourceItems: [plain],
            preferredSeriesNameSource: plain,
            burstGroupReader: { _ in
                XCTFail("A non-burst item must not read its burst group")
                return []
            }
        )

        XCTAssertEqual(result, .success(items: [plain], expandedSingleSeries: false))
    }

    func testBurstCandidateWithSingletonGroupExportsAsSingleItem() async {
        let burst = item("burst", burst: true)
        let result = await BurstExportExpansion.expand(
            sourceItems: [burst],
            preferredSeriesNameSource: burst,
            burstGroupReader: { _ in [burst] }
        )

        XCTAssertEqual(result, .success(items: [burst], expandedSingleSeries: false))
    }

    func testBurstCandidateWithEmptyGroupExportsAsSingleItem() async {
        let burst = item("burst", burst: true)
        let result = await BurstExportExpansion.expand(
            sourceItems: [burst],
            preferredSeriesNameSource: burst,
            burstGroupReader: { _ in [] }
        )

        XCTAssertEqual(result, .success(items: [burst], expandedSingleSeries: false))
    }

    func testDeclaredBurstWhoseGroupAnswerMissesItsMembersFailsTheRequest() async {
        let declared = PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: "a"),
            captureTime: base,
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: ["a", "b", "c"]
        )
        for (name, answer) in [("empty answer", [PhotoItem]()), ("single-photo answer", [declared])] {
            let result = await BurstExportExpansion.expand(
                sourceItems: [declared],
                preferredSeriesNameSource: declared,
                burstGroupReader: { _ in answer }
            )

            // The photo declares three members; one photo or none is not the burst.
            XCTAssertEqual(result, .burstReadFailed(failedSources: [declared]), name)
        }
    }

    func testPhotoWhoseOnlyOtherMemberIsNoFrameExportsAsOnePhoto() async {
        // The photo declares itself and the adjustment data of its edit; the read finds one frame.
        let declared = PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: "main"),
            captureTime: base,
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: ["main", "edit-data"]
        )
        let loneFrame = PhotoItem(
            uid: declared.uid, captureTime: base, mediaType: "image/jpeg", tags: [.bursts], burstMemberIDs: ["main"])

        let single = await BurstExportExpansion.expand(
            sourceItems: [declared],
            preferredSeriesNameSource: declared,
            burstGroupReader: { _ in [loneFrame] }
        )
        XCTAssertEqual(single, .success(items: [declared], expandedSingleSeries: false))

        // An empty answer still contradicts the two declared members.
        let empty = await BurstExportExpansion.expand(
            sourceItems: [declared],
            preferredSeriesNameSource: declared,
            burstGroupReader: { _ in [] }
        )
        XCTAssertEqual(empty, .burstReadFailed(failedSources: [declared]))
    }

    func testOneFrameAnswerOfAnotherPhotoFailsTheRequest() async {
        // The photo declares three members, and the read answers with another photo as a lone frame.
        let declared = PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: "p"),
            captureTime: base,
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: ["p", "q", "r"]
        )
        let other = PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: "x"), captureTime: base, mediaType: "image/jpeg",
            tags: [.bursts], burstMemberIDs: ["x"])

        let result = await BurstExportExpansion.expand(
            sourceItems: [declared],
            preferredSeriesNameSource: declared,
            burstGroupReader: { _ in [other] }
        )
        XCTAssertEqual(result, .burstReadFailed(failedSources: [declared]))
    }

    func testMixedSelectionWithOneFailingBurstFailsTheWholeRequest() async {
        let burst = item("burst", burst: true)
        let plainA = item("plain-a")
        let plainB = item("plain-b")
        let result = await BurstExportExpansion.expand(
            sourceItems: [plainA, burst, plainB],
            preferredSeriesNameSource: nil,
            burstGroupReader: { uid in
                if uid == burst.uid { throw TestError.readFailed }
                return []
            }
        )

        XCTAssertEqual(result, .burstReadFailed(failedSources: [burst]))
    }

    func testTwoFailingBurstsAreBothReportedInSelectionOrder() async {
        let burstA = item("burst-a", burst: true)
        let burstB = item("burst-b", burst: true)
        let result = await BurstExportExpansion.expand(
            sourceItems: [burstA, burstB],
            preferredSeriesNameSource: nil,
            burstGroupReader: { _ in throw TestError.readFailed }
        )

        XCTAssertEqual(result, .burstReadFailed(failedSources: [burstA, burstB]))
    }

    func testDeduplicatesOverlappingGroupMembers() async {
        let burstA = item("burst-a", burst: true)
        let burstB = item("burst-b", burst: true)
        let sharedGroup = group(count: 3, around: burstA) + [burstA, burstB]
        let result = await BurstExportExpansion.expand(
            sourceItems: [burstA, burstB],
            preferredSeriesNameSource: nil,
            burstGroupReader: { _ in sharedGroup }
        )

        guard case .success(let items, let expandedSingleSeries) = result else {
            return XCTFail("Expected a success result, got \(result)")
        }
        XCTAssertEqual(Set(items.map(\.uid)), Set(sharedGroup.map(\.uid)))
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(expandedSingleSeries)
    }

    func testPreferredSeriesMultiSelectionFastPathKeepsSelectionOrder() async {
        let seriesMembers = ["s0", "s1", "s2"]
        let items = seriesMembers.map {
            PhotoItem(
                uid: PhotoUID(volumeID: "vol", nodeID: $0),
                captureTime: base,
                mediaType: "image/jpeg",
                burstMemberIDs: seriesMembers
            )
        }
        let result = await BurstExportExpansion.expand(
            sourceItems: items,
            preferredSeriesNameSource: items[0],
            burstGroupReader: { _ in
                XCTFail("An already-expanded series selection must not read burst groups")
                return []
            }
        )

        XCTAssertEqual(result, .success(items: items, expandedSingleSeries: true))
    }
}

private enum TestError: Error {
    case readFailed
}
