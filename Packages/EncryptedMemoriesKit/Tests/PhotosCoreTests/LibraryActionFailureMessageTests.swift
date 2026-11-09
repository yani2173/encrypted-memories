import Foundation
import XCTest

@testable import PhotosCore

final class LibraryActionFailureMessageTests: XCTestCase {
    private let failure = NSError(
        domain: "ExampleLibraryAction", code: 503,
        userInfo: [NSLocalizedDescriptionKey: "Example service diagnostic"])

    func testCoverFailureUsesTheShortFallbackWithoutDiagnostics() {
        XCTAssertEqual(message(failure, .albumCover), "cover generic")
    }

    func testExportFailureUsesTheShortFallbackWithoutDiagnostics() {
        XCTAssertEqual(message(failure, .export), "export generic")
    }

    func testSaveFailureKeepsTheTitleOnlyAlertPresented() {
        let body = message(failure, .saveToLibrary)
        XCTAssertEqual(body, Optional.some(""))
        XCTAssertNotNil(body)
        XCTAssertTrue(body != nil)
    }

    func testExportCancellationStaysSilent() {
        XCTAssertNil(message(CancellationError(), .export))
    }

    func testLowDiskKeepsItsSpecificReason() {
        XCTAssertEqual(message(OriginalExportWriter.Failure.lowDisk, .export), "low disk")
        XCTAssertEqual(
            LibraryActionFailureMessage.exportTitle(for: OriginalExportWriter.Failure.lowDisk), .lowDiskTitle)
        XCTAssertEqual(LibraryActionFailureMessage.exportTitle(for: failure), .exportTitle)
    }

    func testSpecificAlbumReasonsKeepTheirExactText() {
        let reasons = [
            L10n.string("error.album_action_unavailable"),
            "Proton does not allow this change.",
            L10n.string("error.album_partial_add \(1) \(3)"),
        ]
        for reason in reasons {
            XCTAssertEqual(
                LibraryActionFailureMessage.message(
                    for: failure, action: .albumCover, specificAlbumReason: reason, text: localized),
                reason)
        }
    }

    func testCancellationShowsNoAlertForAnyAction() {
        let actions: [LibraryActionFailureMessage.Action] = [.albumCover, .export, .saveToLibrary]
        for action in actions {
            XCTAssertNil(message(CancellationError(), action))
            XCTAssertNil(message(URLError(.cancelled), action))
        }
    }

    func testUnderlyingAlbumCancellationShowsNoAlert() {
        XCTAssertNil(
            LibraryActionFailureMessage.message(
                for: failure, action: .albumCover, underlyingError: URLError(.cancelled), text: localized))
    }

    func testPartialAlbumReasonSurvivesAnUnderlyingCancellation() {
        let reason = L10n.string("error.album_partial_add \(1) \(3)")
        XCTAssertEqual(
            LibraryActionFailureMessage.message(
                for: failure, action: .albumCover, specificAlbumReason: reason,
                underlyingError: CancellationError(), text: localized),
            reason)
    }

    func testAnUnrelatedErrorCodeDoesNotCountAsCancellation() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(message(error, .albumCover), "cover generic")
        XCTAssertEqual(message(error, .export), "export generic")
        XCTAssertEqual(message(error, .saveToLibrary), Optional.some(""))
    }

    private func message(_ error: any Error, _ action: LibraryActionFailureMessage.Action) -> String? {
        LibraryActionFailureMessage.message(for: error, action: action, text: localized)
    }

    private func localized(_ text: LibraryActionFailureMessage.Text) -> String {
        switch text {
        case .albumCover: "cover generic"
        case .export: "export generic"
        case .lowDisk: "low disk"
        case .exportTitle: "export title"
        case .lowDiskTitle: "low disk title"
        }
    }
}
