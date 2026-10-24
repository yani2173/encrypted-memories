import Foundation
import XCTest

@testable import PhotosCore

final class TimelineOrderMetadataTests: XCTestCase {
    private func photo(_ node: String, _ time: Double, _ exact: Double? = nil, identity: String? = nil) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: node),
            captureTime: Date(timeIntervalSince1970: time), mediaType: "image/jpeg",
            timelineOrder: exact.map {
                TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: $0), stableIdentity: identity)
            })
    }

    func testAnEditedPhotoKeepsItsExactCaptureOrderOnAnotherDeviceAndAfterRefresh() throws {
        let earlier = photo("z-earlier", 500, 500.1, identity: "asset-1")
        let later = photo("a-later", 500, 500.8, identity: "asset-2")
        let edited = photo("0-new-link", 500, 500.8, identity: "asset-2")
        XCTAssertEqual(TimelineSnapshot(orderedItems: [later, earlier]).items.map(\.uid), [earlier.uid, later.uid])
        for input in [[edited, earlier], [earlier, edited]] {
            let restored = try JSONDecoder().decode([PhotoItem].self, from: JSONEncoder().encode(input))
            XCTAssertEqual(TimelineSnapshot(orderedItems: restored).items.map(\.uid), [earlier.uid, edited.uid])
        }
    }

    func testExactTiesUseTheStableIdentityAcrossReplacementLinks() {
        let first = photo("z", 500, 500.5, identity: "asset-1")
        let second = photo("a", 500, 500.5, identity: "asset-2")
        let edited = photo("0", 500, 500.5, identity: "asset-2")
        XCTAssertTrue(TimelineOrder.areInIncreasingOrder(first, second))
        XCTAssertTrue(TimelineOrder.areInIncreasingOrder(first, edited))
    }

    func testMetadataCannotMoveAPhotoIntoAnotherCaptureSecond() {
        let invalid = photo("a", 500, 800.1, identity: "asset-2")
        let next = photo("b", 501)
        XCTAssertTrue(TimelineOrder.areInIncreasingOrder(invalid, next))
    }
    func testMixedClientsKeepATotalOrderAndUnsupportedPhotosKeepTheirFallback() {
        let unknownA = photo("a", 500)
        let unknownZ = photo("z", 500)
        let precise = photo("0-precise", 500, 500.5, identity: "source")
        let tiedA = photo("z-link", 500, 500.5, identity: "a")
        let tiedZ = photo("a-link", 500, 500.5, identity: "é")
        let input = [precise, unknownZ, tiedZ, unknownA, tiedA]
        let sorted = input.sorted(by: TimelineOrder.areInIncreasingOrder)
        XCTAssertEqual(sorted.map(\.uid), [unknownA.uid, unknownZ.uid, tiedA.uid, precise.uid, tiedZ.uid])
        for left in sorted.indices {
            XCTAssertFalse(TimelineOrder.areInIncreasingOrder(sorted[left], sorted[left]))
            for right in sorted.indices where left < right {
                XCTAssertTrue(TimelineOrder.areInIncreasingOrder(sorted[left], sorted[right]))
                XCTAssertFalse(TimelineOrder.areInIncreasingOrder(sorted[right], sorted[left]))
            }
        }
    }
}
