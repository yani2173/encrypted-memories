import XCTest

@testable import PhotosCore

@MainActor
final class BackgroundLaunchAccountStartTests: XCTestCase {
    func testAWindowStartsTheInstalledAccountStart() {
        let hook = BackgroundLaunchAccountStart()
        var starts = 0
        hook.ensureStarted()
        XCTAssertEqual(starts, 0, "nothing is installed yet")

        hook.install { starts += 1 }
        hook.ensureStarted()
        XCTAssertEqual(starts, 1, "a window without a scene starts the account")
        hook.ensureStarted()
        XCTAssertEqual(starts, 2, "every window asks; the account start itself is idempotent")
    }

    func testAWindowCancelledBeforeItsWorkStartsNothing() {
        let hook = BackgroundLaunchAccountStart()
        var starts = 0
        hook.install { starts += 1 }
        XCTAssertFalse(hook.ensureStarted(unlessCancelled: true))
        XCTAssertEqual(starts, 0, "a window that ended before its work starts no account")
        XCTAssertTrue(hook.ensureStarted(unlessCancelled: false))
        XCTAssertEqual(starts, 1)
    }
}
