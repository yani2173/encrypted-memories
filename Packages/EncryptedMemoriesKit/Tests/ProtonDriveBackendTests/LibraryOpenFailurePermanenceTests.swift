import PhotosCore
import ProtonAuth
import XCTest

@testable import ProtonDriveBackend

/// The library-open sheet shows Retry only when another attempt with the same session can succeed. The
/// classifier proves permanence; every unclear or transient cause keeps the button.
final class LibraryOpenFailurePermanenceTests: XCTestCase {
    func testAnAccountWithoutAPhotosShareIsPermanent() {
        // A Retry cannot create the missing photos share, so the Retry button hides.
        XCTAssertTrue(LibraryOpenFailurePermanence.isPermanent(DriveBridgeError.noPhotosShare))
    }

    func testATerminallyLostDriveScopeIsPermanent() {
        // The marker protocol marks a scope failure that polling the same remote scope cannot recover.
        struct LostScope: Error, LibraryChangeTerminalError {}
        XCTAssertTrue(LibraryOpenFailurePermanence.isPermanent(LostScope()))
    }

    func testARejectedSessionAfterOneFailedRefreshIsPermanent() {
        // A surviving 401 means the token refresh already failed to renew the session.
        let rejectedSession = ProtonAuthError.apiError(code: 401, message: "unauthorized")
        XCTAssertTrue(LibraryOpenFailurePermanence.isPermanent(rejectedSession))
    }

    func testANetworkFailureKeepsRetry() {
        XCTAssertFalse(LibraryOpenFailurePermanence.isPermanent(URLError(.notConnectedToInternet)))
        XCTAssertFalse(LibraryOpenFailurePermanence.isPermanent(URLError(.timedOut)))
    }

    func testAnUnclearServerErrorKeepsRetry() {
        // A server answer other than a rejected session does not prove that a new attempt fails.
        XCTAssertFalse(LibraryOpenFailurePermanence.isPermanent(ProtonAuthError.apiError(code: 500, message: "oops")))
        XCTAssertFalse(LibraryOpenFailurePermanence.isPermanent(ProtonAuthError.apiError(code: 429, message: "slow")))
        XCTAssertFalse(LibraryOpenFailurePermanence.isPermanent(ProtonAuthError.invalidResponse))
    }

    func testAnUnknownCauseKeepsRetry() {
        struct UnclearFailure: Error {}
        XCTAssertFalse(LibraryOpenFailurePermanence.isPermanent(UnclearFailure()))
    }
}
