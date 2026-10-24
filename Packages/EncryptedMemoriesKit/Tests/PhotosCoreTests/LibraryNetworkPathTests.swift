import Foundation
import PhotosCore
import XCTest

/// Which network path counts as expensive (cellular data or Personal Hotspot) for the backup's mobile-data setting.
final class LibraryNetworkPathTests: XCTestCase {
    func testTheSystemsExpensiveFlagDecides() {
        let cellular = LibraryNetworkPath(isSatisfied: true, isExpensive: true, availableInterfaces: [.cellular])
        XCTAssertTrue(LibraryNetworkState.isExpensive(cellular))
        let wiFi = LibraryNetworkPath(isSatisfied: true, availableInterfaces: [.wifi])
        XCTAssertFalse(LibraryNetworkState.isExpensive(wiFi))
    }

    func testVPNOverCellularDataIsExpensive() {
        let vpn = LibraryNetworkPath(
            isSatisfied: true, usedInterfaces: [.other], availableInterfaces: [.other, .cellular])
        XCTAssertTrue(LibraryNetworkState.isExpensive(vpn))
    }

    func testVPNOverWiFiOrEthernetIsNotExpensive() {
        for physical in [LibraryNetworkInterfaceKind.wifi, .wiredEthernet] {
            let vpn = LibraryNetworkPath(
                isSatisfied: true, usedInterfaces: [.other], availableInterfaces: [.other, physical])
            XCTAssertFalse(LibraryNetworkState.isExpensive(vpn), "\(physical)")
            let both = LibraryNetworkPath(
                isSatisfied: true, usedInterfaces: [.other], availableInterfaces: [.other, .cellular, physical])
            XCTAssertFalse(LibraryNetworkState.isExpensive(both), "\(physical) next to cellular")
        }
    }

    func testCellularNextToATunnelThatThePathDoesNotUseKeepsTheSystemsAnswer() {
        let wiFi = LibraryNetworkPath(isSatisfied: true, availableInterfaces: [.other, .cellular])
        XCTAssertFalse(LibraryNetworkState.isExpensive(wiFi))
    }

    func testStateFromAPathKeepsReachabilityAndLowDataMode() {
        let state = LibraryNetworkState(
            path: LibraryNetworkPath(
                isSatisfied: false, isConstrained: true, usedInterfaces: [.other],
                availableInterfaces: [.other, .cellular]))
        XCTAssertEqual(
            state,
            LibraryNetworkState(
                isReachable: false, isConstrained: true, isExpensive: true, isDetermined: true,
                usedInterfaces: [.other], availableInterfaces: [.other, .cellular]))
        XCTAssertEqual(LibraryNetworkState.diagnosticList(state.availableInterfaces), "cellular,other")
        XCTAssertEqual(LibraryNetworkState.diagnosticList([]), "")
    }

    func testTheSharedStateStartsWithoutANetworkPath() {
        XCTAssertFalse(LibraryNetworkState.undetermined.isDetermined)
        XCTAssertTrue(LibraryNetworkState.undetermined.isReachable, "an unknown path is not offline")
        XCTAssertFalse(
            LibraryRuntimeState.makeProcessState().snapshot().network.isDetermined,
            "the process state that `shared` uses starts without a path")
    }

    /// The network queue and the main actor write at the same time. A subscriber must end on the newest snapshot.
    func testSubscribersEndOnTheNewestSnapshotWhenWritersRace() async {
        for _ in 0..<20 {
            let state = LibraryRuntimeState()
            let received = ReceivedSnapshot()
            let updates = state.updates()
            let consumer = Task {
                for await snapshot in updates { received.set(snapshot) }
            }
            DispatchQueue.concurrentPerform(iterations: 200) { index in
                state.update { $0.activeSearchCount = index + 1 }
            }
            let newest = state.snapshot()
            let deadline = Date().addingTimeInterval(2)
            while received.value != newest, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            consumer.cancel()
            XCTAssertEqual(received.value?.activeSearchCount, newest.activeSearchCount)
            if received.value != newest { return }
        }
    }
}

private final class ReceivedSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: LibraryRuntimeSnapshot?

    var value: LibraryRuntimeSnapshot? { lock.withLock { snapshot } }
    func set(_ snapshot: LibraryRuntimeSnapshot) { lock.withLock { self.snapshot = snapshot } }
}
