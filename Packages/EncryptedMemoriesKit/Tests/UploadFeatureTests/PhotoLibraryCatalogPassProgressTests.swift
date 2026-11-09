import Foundation
import PhotosCore
import UploadCore
import XCTest

/// The rule every catalog pass uses to step past unknown rows (#1160).
final class PhotoLibraryCatalogPassProgressTests: XCTestCase {
    private let counter = "test.catalogPass.undecodableRow"

    private func entry(_ id: String) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogEntry(
            localIdentifier: id, creationDate: nil, modificationDate: nil, pixelWidth: 1, pixelHeight: 1,
            durationSeconds: 0, mediaKind: .image, isLivePhoto: false,
            resources: [PhotoLibraryCatalogResource(role: "originalPhoto", originalFilename: "\(id).heic")],
            contentFingerprint: 0, metadataRevision: 0, firstSeenAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 0))
    }

    private func page(_ decoded: [String], unknown: [String] = []) -> PhotoLibraryCatalogPage {
        PhotoLibraryCatalogPage(entries: decoded.map(entry), undecodableIdentifiers: unknown)
    }

    func testCleanPagesOfferEveryKeyAndAllowCompletion() {
        var progress = PhotoLibraryCatalogPassProgress(after: "start")
        XCTAssertEqual(progress.advance(past: page(["a", "b"])), .advanced(resumePoint: "b"))
        XCTAssertEqual(progress.advance(past: page(["c"])), .advanced(resumePoint: "c"))
        XCTAssertEqual(progress.advance(past: page([])), .end)
        XCTAssertEqual(progress.cursor, "c")
        let counted = PhotoDiagnostics.shared.counter(counter)
        XCTAssertTrue(progress.mayComplete(countingUnknownRowsAs: counter))
        XCTAssertEqual(PhotoDiagnostics.shared.counter(counter), counted, "a clean pass counts nothing")
    }

    func testAnUnknownRowOnTheFirstPageWithholdsEveryLaterResumePointAndCompletion() {
        var progress = PhotoLibraryCatalogPassProgress()
        XCTAssertEqual(progress.advance(past: page(["a"], unknown: ["b"])), .advanced(resumePoint: nil))
        XCTAssertEqual(progress.cursor, "b", "the cursor still moves past the unknown row")
        XCTAssertEqual(
            progress.advance(past: page(["c"])), .advanced(resumePoint: nil), "a later clean page offers no key")
        XCTAssertEqual(progress.advance(past: page(["d"])), .advanced(resumePoint: nil))
        XCTAssertEqual(progress.advance(past: page([])), .end)
        let counted = PhotoDiagnostics.shared.counter(counter)
        XCTAssertFalse(progress.mayComplete(countingUnknownRowsAs: counter))
        XCTAssertEqual(PhotoDiagnostics.shared.counter(counter), counted + 1, "the pass counts itself once")
    }

    func testAnUnknownRowOnlyOnTheLastPageKeepsTheEarlierResumePoints() {
        var progress = PhotoLibraryCatalogPassProgress()
        XCTAssertEqual(progress.advance(past: page(["a"])), .advanced(resumePoint: "a"))
        XCTAssertEqual(progress.advance(past: page(["b"], unknown: ["c"])), .advanced(resumePoint: nil))
        XCTAssertEqual(progress.cursor, "c", "the unknown last row moves the cursor")
        XCTAssertEqual(progress.advance(past: page([])), .end)
        XCTAssertFalse(progress.mayComplete(countingUnknownRowsAs: counter))
    }

    func testAPageOfOnlyUnknownRowsIsNotTheEnd() {
        var progress = PhotoLibraryCatalogPassProgress()
        XCTAssertEqual(progress.advance(past: page([], unknown: ["a", "b"])), .advanced(resumePoint: nil))
        XCTAssertEqual(progress.cursor, "b")
        XCTAssertEqual(progress.advance(past: page(["c"])), .advanced(resumePoint: nil))
        XCTAssertFalse(progress.mayComplete(countingUnknownRowsAs: counter))
    }

    func testAnEmptyFirstPageEndsAtTheSavedCursor() {
        var progress = PhotoLibraryCatalogPassProgress(after: "saved")
        XCTAssertEqual(progress.advance(past: page([])), .end)
        XCTAssertEqual(progress.cursor, "saved")
        XCTAssertTrue(progress.mayComplete(countingUnknownRowsAs: counter))
    }
}
