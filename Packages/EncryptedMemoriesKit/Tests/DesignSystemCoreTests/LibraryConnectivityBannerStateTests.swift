import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct LibraryConnectivityBannerStateTests {
    @Test func offlineOutranksTheRestoredPulse() {
        #expect(
            LibraryConnectivityBannerState.resolve(
                isOnline: false,
                didRecentlyRestoreConnection: true
            ) == .offline
        )
    }

    @Test func restoredIsBrieflyVisibleAfterConnectivityReturns() {
        #expect(
            LibraryConnectivityBannerState.resolve(
                isOnline: true,
                didRecentlyRestoreConnection: true
            ) == .connectionRestored
        )
    }

    /// Cellular data and Personal Hotspot are online, also while the backup waits for Wi-Fi.
    @Test func expensiveReachablePathIsNeverOffline() {
        for isConstrained in [false, true] {
            let network = LibraryNetworkState(isReachable: true, isConstrained: isConstrained, isExpensive: true)
            #expect(NetworkMonitor.isOnline(network))
            for restored in [false, true] {
                #expect(
                    LibraryConnectivityBannerState.resolve(
                        isOnline: NetworkMonitor.isOnline(network),
                        didRecentlyRestoreConnection: restored
                    ) != .offline
                )
            }
        }
        #expect(!NetworkMonitor.isOnline(LibraryNetworkState(isReachable: false, isExpensive: true)))
    }

    @Test func routineOnlineStateDoesNotOccupyTheBanner() {
        #expect(
            LibraryConnectivityBannerState.resolve(
                isOnline: true,
                didRecentlyRestoreConnection: false
            ) == .hidden
        )
    }
}
