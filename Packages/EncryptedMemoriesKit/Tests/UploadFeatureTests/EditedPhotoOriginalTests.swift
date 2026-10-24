import Foundation
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// The original of an edited photo among its related files, as the photo library backup names them. The fixtures run
/// the real export plan, so the related file names are the ones the backup uploads.
final class EditedPhotoOriginalTests: XCTestCase {
    private typealias Resource = PhotoBackupAssetInfo.Resource

    /// The adjustment data of an edit, as Photos names it.
    private let adjustments = Resource(role: .adjustmentData, originalFilename: "Adjustments.plist")

    // MARK: - Fixtures through the backup's export plan

    func testAnEditedHEICWithAHEICRenderFindsItsOriginal() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0001.HEIC", mimeType: "image/heic")
        let render = Resource(role: .fullSizePhoto, originalFilename: "FullSizeRender.heic", mimeType: "image/heic")
        for base in adjustmentBaseNames(original: "IMG_0001.HEIC", render: "IMG_0001.heic", ext: "heic") {
            try assertFindsOriginal(photo([original, render, adjustments, base]))
        }
    }

    func testAnEditedHEICWithAJPEGRenderFindsItsOriginal() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0002.HEIC", mimeType: "image/heic")
        let render = Resource(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg")
        for base in adjustmentBaseNames(original: "IMG_0002.HEIC", render: "IMG_0002.jpg", ext: "jpg") {
            try assertFindsOriginal(photo([original, render, adjustments, base]))
        }
    }

    func testAnEditedJPEGFindsItsOriginal() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0003.JPG", mimeType: "image/jpeg")
        let render = Resource(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg")
        for base in adjustmentBaseNames(original: "IMG_0003.JPG", render: "IMG_0003.jpg", ext: "jpg") {
            try assertFindsOriginal(photo([original, render, adjustments, base]))
        }
    }

    func testAnEditedRAWPlusJPEGPairFindsTheJPEGAndNeverTheRAWFile() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0004.JPG", mimeType: "image/jpeg")
        let raw = Resource(role: .alternatePhoto, originalFilename: "IMG_0004.DNG", mimeType: "image/x-adobe-dng")
        let render = Resource(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg")
        for base in adjustmentBaseNames(original: "IMG_0004.JPG", render: "IMG_0004.jpg", ext: "jpg") {
            try assertFindsOriginal(photo([original, raw, render, adjustments, base]))
        }
    }

    func testAnEditedVideoFindsItsOriginal() throws {
        let original = Resource(role: .originalVideo, originalFilename: "IMG_0006.MOV", mimeType: "video/quicktime")
        let render = Resource(
            role: .fullSizeVideo, originalFilename: "FullSizeRender.mov", mimeType: "video/quicktime")
        let bases = [
            Resource(role: .adjustmentBaseVideo, originalFilename: "penultimateFullSizeRender.mov"),
            Resource(role: .adjustmentBaseVideo, originalFilename: "IMG_0006.MOV"),
            Resource(role: .adjustmentBaseVideo, originalFilename: "IMG_0006.mov"),
        ]
        for base in bases {
            try assertFindsOriginal(asset([original, render, adjustments, base], video: true))
        }
    }

    /// Fails closed: the names of a ProRAW edit equal those of a RAW+JPEG pair whose edit uploaded without a render.
    func testAnEditedProRAWPhotoOffersNoOriginal() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0005.DNG", mimeType: "image/x-adobe-dng")
        let render = Resource(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg")
        XCTAssertNil(try found(photo([original, render, adjustments])))
    }

    func testARAWPlusJPEGPairWhoseEditUploadedWithoutARenderOffersNoOriginal() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0009.JPG", mimeType: "image/jpeg")
        let raw = Resource(role: .alternatePhoto, originalFilename: "IMG_0009.DNG", mimeType: "image/x-adobe-dng")
        XCTAssertNil(try found(photo([original, raw, adjustments])))
    }

    func testAnEditWithoutARenderOffersNoOriginal() throws {
        // The photo is the original then.
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0008.HEIC", mimeType: "image/heic")
        XCTAssertNil(try found(photo([original, adjustments])))
    }

    func testAnUneditedRAWPlusJPEGPairOffersNoOriginal() throws {
        let original = Resource(role: .originalPhoto, originalFilename: "IMG_0007.JPG", mimeType: "image/jpeg")
        let raw = Resource(role: .alternatePhoto, originalFilename: "IMG_0007.DNG", mimeType: "image/x-adobe-dng")
        XCTAssertNil(try found(photo([original, raw])))
    }

    // MARK: - Names that leave the answer open

    func testANameThatDoesNotDecryptLeavesTheAnswerOpen() {
        let related = files(["IMG_1.HEIC", "Adjustments.plist"]) + [.init(linkID: "unknown", name: nil)]
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.jpg", isVideo: false, related: related))
    }

    func testTwoCandidatesLeaveTheAnswerOpen() {
        let marked = files(["IMG_1-originalPhoto-1.heic", "IMG_1-originalPhoto-2.heic", "Adjustments.plist"])
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.heic", isVideo: false, related: marked))
        let sameBase = files(["IMG_1.HEIC", "IMG_1.PNG", "Adjustments.plist"])
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.jpg", isVideo: false, related: sameBase))
    }

    func testAMarkedOriginalDecidesBeforeASameBaseName() {
        let related = files(["IMG_1-originalPhoto-1.heic", "IMG_1.JPG", "Adjustments.plist"])
        XCTAssertEqual(
            EditedPhotoOriginal.linkID(mainName: "IMG_1.heic", isVideo: false, related: related),
            "IMG_1-originalPhoto-1.heic")
    }

    func testWithoutAdjustmentDataNoFileIsTheOriginal() {
        let related = files(["IMG_1.HEIC"])
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.jpg", isVideo: false, related: related))
    }

    func testAnAAEFileProvesTheEditToo() {
        let related = files(["IMG_1.HEIC", "IMG_1.AAE"])
        XCTAssertEqual(
            EditedPhotoOriginal.linkID(mainName: "IMG_1.jpg", isVideo: false, related: related), "IMG_1.HEIC")
    }

    func testOnlyAFileOfThePhotosKindCounts() {
        let photo = files(["IMG_1.MOV", "Adjustments.plist"])
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.jpg", isVideo: false, related: photo))
        let video = files(["IMG_1.HEIC", "Adjustments.plist"])
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.mov", isVideo: true, related: video))
    }

    func testARoleMarkerNeedsANumber() {
        let related = files(["IMG_1-originalPhoto-x.heic", "Adjustments.plist"])
        XCTAssertNil(EditedPhotoOriginal.linkID(mainName: "IMG_1.heic", isVideo: false, related: related))
    }

    // MARK: - Helpers

    /// The adjustment base image under the name Photos is assumed to use, and under the names of the original and of
    /// the uploaded photo. The backup renames a clash, so none of them may hide the original.
    private func adjustmentBaseNames(original: String, render: String, ext: String) -> [Resource] {
        ["penultimateFullSizeRender.\(ext)", original, render].map {
            Resource(role: .adjustmentBasePhoto, originalFilename: $0)
        }
    }

    private func photo(_ resources: [Resource]) -> PhotoBackupAssetInfo {
        asset(resources, video: false)
    }

    private func asset(_ resources: [Resource], video: Bool) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: "asset", creationDate: nil, modificationDate: nil, pixelWidth: 4032, pixelHeight: 3024,
            durationSeconds: video ? 3 : 0, isLivePhoto: false, isVideo: video, resources: resources,
            hasAdjustments: resources.contains { $0.role == .adjustmentData })
    }

    /// The link of each related file is its role and ordinal in the plan, so a test can name the expected file.
    private func found(_ info: PhotoBackupAssetInfo) throws -> String? {
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info))
        let related = plan.secondaries.map {
            EditedPhotoOriginal.RelatedFile(linkID: "\($0.role.rawValue)#\($0.ordinal)", name: $0.uploadFilename)
        }
        return EditedPhotoOriginal.linkID(
            mainName: plan.primary.uploadFilename, isVideo: info.isVideo, related: related)
    }

    private func assertFindsOriginal(
        _ info: PhotoBackupAssetInfo, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let role = info.isVideo ? "originalVideo" : "originalPhoto"
        let names = PhotoBackupAssetPlanner.exportPlan(for: info).map {
            [$0.primary.uploadFilename] + $0.secondaries.map(\.uploadFilename)
        }
        XCTAssertEqual(try found(info), "\(role)#0", "uploaded names: \(names ?? [])", file: file, line: line)
    }

    private func files(_ names: [String]) -> [EditedPhotoOriginal.RelatedFile] {
        names.map { .init(linkID: $0, name: $0) }
    }
}
