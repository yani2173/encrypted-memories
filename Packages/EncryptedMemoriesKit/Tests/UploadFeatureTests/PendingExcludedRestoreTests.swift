import PhotosCore
import XCTest

@testable import UploadFeature

/// "Back Up Again" on an excluded photo must say why nothing happened when the pending store refuses: the same
/// decision on macOS, iOS and iPadOS, drawn once by the excluded-photos list.
final class PendingExcludedRestoreTests: XCTestCase {
    func testARefusedIncludeShowsTheAgreedMessage() {
        XCTAssertEqual(
            PendingExcludedRestoreFailure.message(includeSucceeded: false),
            L10n.string("backup.excluded_include_failed"))
    }

    func testASuccessfulIncludeShowsNoMessage() {
        XCTAssertNil(PendingExcludedRestoreFailure.message(includeSucceeded: true))
    }

    func testAFollowUpSuccessKeepsAnEarlierFailureMessage() {
        let afterFailure = PendingExcludedRestoreFailure.updated(
            PendingExcludedRestoreFailure.message(includeSucceeded: false), includeSucceeded: true)
        XCTAssertEqual(afterFailure, L10n.string("backup.excluded_include_failed"))
    }

    func testASuccessAloneKeepsNoMessage() {
        XCTAssertNil(PendingExcludedRestoreFailure.updated(nil, includeSucceeded: true))
    }

    func testAFollowUpFailureKeepsTheMessage() {
        let afterFailure = PendingExcludedRestoreFailure.updated(
            L10n.string("backup.excluded_include_failed"), includeSucceeded: false)
        XCTAssertEqual(afterFailure, L10n.string("backup.excluded_include_failed"))
    }
}
