import XCTest

@testable import UploadCore

final class EditedOriginalRestoredNameTests: XCTestCase {
    /// The real export plan names the hidden original `<base>-originalPhoto-<n>.<ext>`; the restored name takes the
    /// base from the edited photo and only the extension from the original.
    func testTheBaseComesFromTheEditedPhotoAndTheExtensionFromTheOriginal() {
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "IMG_0001.jpg", originalName: "IMG_0001-originalPhoto-1.heic"),
            "IMG_0001 (original).heic")
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "IMG_0002.heic", originalName: "IMG_0002-originalPhoto-1.heic"),
            "IMG_0002 (original).heic")
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "IMG_0003.mp4", originalName: "IMG_0003-originalVideo-1.mov"),
            "IMG_0003 (original).mov")
    }

    func testOnlyTheLastExtensionOfTheEditedPhotoIsDropped() {
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "Trip.2024.jpg", originalName: "x.heic"),
            "Trip.2024 (original).heic")
    }

    func testTheExtensionKeepsItsCase() {
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "A.JPG", originalName: "A-originalPhoto-1.HEIC"),
            "A (original).HEIC")
    }

    func testNamesWithoutExtensionsStayUsable() {
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "Photo", originalName: "x.heic"), "Photo (original).heic")
        XCTAssertEqual(
            EditedOriginalRestoredName.make(mainName: "IMG_0001.jpg", originalName: "original"),
            "IMG_0001 (original)")
    }

    func testNoValidNameExistsForAnEmptyBase() {
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "", originalName: "x.heic"))
    }

    /// The name becomes a file name in the work directory, so a separator must never pass.
    func testNoNameWithAPathSeparatorOrNulExists() {
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "../IMG.jpg", originalName: "x.heic"))
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "a/b.jpg", originalName: "x.heic"))
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "a\0b.jpg", originalName: "x.heic"))
        // The input names count as well, whatever the extension logic drops from them.
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "IMG.jpg/", originalName: "x.heic"))
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "IMG.jpg", originalName: "x/y.heic"))
        XCTAssertNil(EditedOriginalRestoredName.make(mainName: "IMG.jpg", originalName: "x.heic\0"))
    }

    func testTheOriginalIsNeverNamedLikeTheRestoredPhoto() {
        let original = "IMG_0001-originalPhoto-1.heic"
        XCTAssertNotEqual(
            EditedOriginalRestoredName.make(mainName: "IMG_0001.jpg", originalName: original), original)
    }
}
