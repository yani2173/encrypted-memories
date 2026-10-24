import XCTest

@testable import PhotosCore

final class PhotoFilterEmptyStateTests: XCTestCase {
    func testTrashEmptyStateCopyIsShared() {
        let copy = PhotoFilter.trash.emptyStateCopy

        XCTAssertEqual(copy.title, L10n.string("empty.trash_title"))
        XCTAssertEqual(copy.description, L10n.string("empty.trash_description"))
        XCTAssertEqual(copy.systemImage, "trash")
    }

    func testMapFilterEmptyCopyDoesNotClaimTheWholeLibraryIsEmpty() {
        let copy = PhotoFilter.map.emptyStateCopy
        XCTAssertNotEqual(copy.title, PhotoFilter.all.emptyStateCopy.title)
        XCTAssertEqual(copy.title, L10n.string("empty.filter_title \(L10n.string("map.cluster_title"))"))
        XCTAssertEqual(copy.description, L10n.string("empty.filter_description"))
        XCTAssertEqual(copy.systemImage, "map")
    }

    func testSmartFilterEmptyStateUsesTagCopy() {
        let copy = PhotoFilter.tag(.favorites).emptyStateCopy

        XCTAssertEqual(copy.title, L10n.string("empty.filter_title \(PhotoTag.favorites.title)"))
        XCTAssertEqual(copy.description, L10n.string("empty.filter_description"))
        XCTAssertEqual(copy.systemImage, PhotoTag.favorites.systemImage)
    }
}
