import XCTest

@testable import PhotosCore

final class TimelineOrderRefinementPolicyTests: XCTestCase {
    func testVisiblePhotosStayInTheirSlotsUntilTheCorrectionIsOffscreen() {
        let old = (0..<6).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0 / 2)), mediaType: "image/jpeg")
        }
        var corrected = old
        for index in corrected.indices {
            corrected[index].timelineOrder = .init(
                exactCaptureTime: old[index].captureTime.addingTimeInterval(index.isMultiple(of: 2) ? 0.8 : 0.1))
        }
        corrected.sort(by: TimelineOrder.areInIncreasingOrder)
        let indices = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.uid, $0.offset) })
        func decision(
            _ visible: Set<Int>, _ incoming: [PhotoItem] = corrected
        ) -> TimelineOrderRefinementPolicy.Decision {
            TimelineOrderRefinementPolicy.decision(
                incoming: incoming, previousCount: old.count, visibleIndices: visible,
                previous: { uid in indices[uid].map { ($0, old[$0]) } })
        }
        XCTAssertEqual(decision([2, 3]), .deferVisibleCorrection)
        XCTAssertEqual(decision([]), .applyCorrection)
        XCTAssertEqual(decision([2, 3], old), .ordinaryUpdate)
        var metadataOnly = old
        for index in metadataOnly.indices {
            metadataOnly[index].timelineOrder = .init(
                exactCaptureTime: old[index].captureTime.addingTimeInterval(index.isMultiple(of: 2) ? 0.1 : 0.8))
        }
        XCTAssertEqual(decision([2, 3], metadataOnly), .applyCorrection)
        XCTAssertEqual(decision([2, 3], Array(corrected.dropLast())), .ordinaryUpdate)
        var replaced = corrected
        replaced[0] = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "replacement"),
            captureTime: replaced[0].captureTime, mediaType: "image/jpeg")
        XCTAssertEqual(decision([2, 3], replaced), .ordinaryUpdate)
    }
}
