import DesignSystemCore
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileTimelineSurfaceBannerTests: XCTestCase {
    func testTheLibraryRefreshNoticeShowsOnTheLibrarySurfaceOnly() {
        XCTAssertTrue(
            MobileTimelineSurface.library.presentsActivityBanner(connectivity: .hidden, libraryIsRefreshing: true))
        XCTAssertFalse(
            MobileTimelineSurface.search.presentsActivityBanner(connectivity: .hidden, libraryIsRefreshing: true))
        XCTAssertFalse(
            MobileTimelineSurface.library.presentsActivityBanner(connectivity: .hidden, libraryIsRefreshing: false))
        XCTAssertFalse(
            MobileTimelineSurface.search.presentsActivityBanner(connectivity: .hidden, libraryIsRefreshing: false))
    }

    func testConnectivityMessagesStayOnEverySurface() {
        for surface in [MobileTimelineSurface.library, .search] {
            for connectivity in [LibraryConnectivityBannerState.offline, .connectionRestored] {
                for refreshing in [false, true] {
                    XCTAssertTrue(
                        surface.presentsActivityBanner(connectivity: connectivity, libraryIsRefreshing: refreshing))
                }
            }
        }
    }
}
