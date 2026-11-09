import XCTest

@testable import PhotosCore

final class LibraryStoragePressureTests: XCTestCase {
    func testThresholdsAndHysteresis() {
        let gib: Int64 = 1 << 30
        let mib: Int64 = 1 << 20
        let policy = DiskCacheBudgetPolicy(platform: .mobile)

        func next(_ after: LibraryStoragePressure, _ bytes: Int64?) -> LibraryStoragePressure {
            LibraryStoragePressure.next(after: after, availableBytes: bytes, policy: policy)
        }

        XCTAssertEqual(next(.normal, 2 * gib), .normal)
        XCTAssertEqual(next(.normal, 2 * gib - 1), .low)
        XCTAssertEqual(next(.normal, 512 * mib - 1), .critical)
        XCTAssertEqual(next(.low, 2 * gib + 256 * mib - 1), .low)
        XCTAssertEqual(next(.low, 2 * gib + 256 * mib), .normal)
        XCTAssertEqual(next(.critical, 512 * mib + 256 * mib - 1), .critical)
        XCTAssertEqual(next(.critical, 512 * mib + 256 * mib), .low)
        XCTAssertEqual(next(.critical, 2 * gib + 256 * mib), .normal)
        XCTAssertEqual(next(.low, nil), .low)
    }

    func testThresholdsFollowTheSharedDiskCacheBudgetPolicy() {
        let gib: Int64 = 1 << 30
        let mib: Int64 = 1 << 20
        for platform: DiskCacheBudgetPolicy.Platform in [.mobile, .macOS] {
            let policy = DiskCacheBudgetPolicy(platform: platform)
            let low = policy.lowStorageThresholdBytes
            let critical = policy.criticalStorageThresholdBytes
            let margin = policy.storageRecoveryMarginBytes

            func next(_ after: LibraryStoragePressure, _ bytes: Int64) -> LibraryStoragePressure {
                LibraryStoragePressure.next(after: after, availableBytes: bytes, policy: policy)
            }

            XCTAssertEqual(next(.normal, low), .normal)
            XCTAssertEqual(next(.normal, low - 1), .low)
            XCTAssertEqual(next(.normal, critical - 1), .critical)
            XCTAssertEqual(next(.low, low + margin - 1), .low)
            XCTAssertEqual(next(.low, low + margin), .normal)
            XCTAssertEqual(next(.critical, critical + margin - 1), .critical)
            XCTAssertEqual(next(.critical, critical + margin), .low)

            // The policy keeps the current effective thresholds: low 2 GiB, critical 512 MiB, margin 256 MiB.
            XCTAssertEqual(low, 2 * gib)
            XCTAssertEqual(critical, 512 * mib)
            XCTAssertEqual(margin, 256 * mib)
        }
    }

    func testCriticalPausesAutomaticWritingWorkOnly() {
        let policy = LibraryResourcePolicy()
        let snapshot = LibraryRuntimeSnapshot(storagePressure: .critical)
        for workload: LibraryHeavyWorkload in [.mlIndexing, .videoDerivative] {
            let automatic = LibraryWorkRequest(workload: workload, intent: .automatic)
            let budget = policy.budget(for: automatic, snapshot: snapshot)
            XCTAssertFalse(budget.isAdmitted)
            XCTAssertEqual(budget.reason, .storagePressure)
            XCTAssertTrue(
                policy.budget(
                    for: LibraryWorkRequest(workload: workload, intent: .userInitiated), snapshot: snapshot
                ).isAdmitted)
        }
        XCTAssertTrue(
            policy.budget(
                for: LibraryWorkRequest(workload: .mlInference, intent: .automatic), snapshot: snapshot
            ).isAdmitted)
        // Backup checks free space itself and shows that the device needs storage.
        XCTAssertTrue(
            policy.budget(
                for: LibraryWorkRequest(workload: .backupMaterialization, intent: .automatic), snapshot: snapshot
            ).isAdmitted)
    }

    func testOutOfSpaceErrorsAreRecognizedWhenWrapped() {
        XCTAssertTrue(DeviceStorage.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(DeviceStorage.isOutOfSpace(POSIXError(.ENOSPC)))
        let diskFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: "Transfer", code: 1, userInfo: [NSUnderlyingErrorKey: diskFull])
        XCTAssertTrue(DeviceStorage.isOutOfSpace(wrapped))
        XCTAssertFalse(DeviceStorage.isOutOfSpace(CocoaError(.fileWriteUnknown)))
        XCTAssertFalse(DeviceStorage.isOutOfSpace(URLError(.timedOut)))
    }

    func testGenerationResetKeepsObservedPressure() {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(storagePressure: .critical))
        XCTAssertEqual(state.beginNewGeneration().storagePressure, .critical)
    }

    func testActiveAutomaticWritingLeaseYieldsOnCritical() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let decision = try await coordinator.withHeavyPermit(
            LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        ) { lease in
            state.update { $0.storagePressure = .critical }
            return lease.continuationDecision()
        }
        XCTAssertEqual(decision, .yield(.storagePressure))
    }
}
