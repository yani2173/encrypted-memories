import XCTest

/// These tests drive the absence decision with scripted answers and never launch the app.
final class ConfirmationDialogAbsenceTests: XCTestCase {
    private func decide(_ answers: [Bool], checks: Int = 3) -> (gone: Bool, calls: Int) {
        var calls = 0
        let gone = XCUIApplication.isConfirmedGone(
            exists: {
                defer { calls += 1 }
                return calls < answers.count ? answers[calls] : answers.last ?? false
            },
            checks: checks, interval: 0
        )
        return (gone, calls)
    }

    func testOneStaleMissDoesNotCountAsGone() {
        let result = decide([false, true])
        XCTAssertFalse(result.gone, "A later sighting proves that the dialog stayed")
        XCTAssertEqual(result.calls, 2, "The first sighting ends the check")
    }

    func testConsecutiveMissesCountAsGone() {
        let result = decide([false])
        XCTAssertTrue(result.gone)
        XCTAssertEqual(result.calls, 3, "Every check must miss, and the number of checks is bounded")
    }

    func testImmediateSightingIsNotGone() {
        let result = decide([true])
        XCTAssertFalse(result.gone)
        XCTAssertEqual(result.calls, 1)
    }
}
