import XCTest

@testable import PhotosCore

final class SequenceUniquedTests: XCTestCase {
    func testKeepsTheFirstOfEachElementInOrder() {
        XCTAssertEqual([3, 1, 3, 2, 1].uniqued(), [3, 1, 2])
        XCTAssertEqual([Int]().uniqued(), [])
    }
}
