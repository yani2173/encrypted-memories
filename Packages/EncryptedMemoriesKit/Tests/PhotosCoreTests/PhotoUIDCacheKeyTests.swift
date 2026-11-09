import XCTest

@testable import PhotosCore

final class PhotoUIDCacheKeyTests: XCTestCase {
    func testTheKeyJoinsVolumeAndNodeWithATilde() {
        XCTAssertEqual(PhotoUID(volumeID: "vol", nodeID: "node").cacheKey, "vol~node" as NSString)
    }

    func testPhotosOfAnotherVolumeOrNodeHaveAnotherKey() {
        let uid = PhotoUID(volumeID: "vol", nodeID: "node")

        XCTAssertNotEqual(uid.cacheKey, PhotoUID(volumeID: "other", nodeID: "node").cacheKey)
        XCTAssertNotEqual(uid.cacheKey, PhotoUID(volumeID: "vol", nodeID: "other").cacheKey)
        XCTAssertEqual(uid.cacheKey, PhotoUID(volumeID: "vol", nodeID: "node").cacheKey)
    }
}
