import XCTest

@testable import PhotosCore

final class DiskCacheBudgetPolicyTests: XCTestCase {
    private let gib: Int64 = 1 << 30
    private let mib: Int64 = 1 << 20

    func testCurrentDefaultsForBothPlatforms() {
        for platform: DiskCacheBudgetPolicy.Platform in [.mobile, .macOS] {
            let policy = DiskCacheBudgetPolicy(platform: platform)
            XCTAssertEqual(policy.thumbnailBudget, .unlimited)
            XCTAssertEqual(policy.previewBudget, .bytes(2 * gib))
            XCTAssertEqual(policy.originalsBudget, .bytes(platform == .mobile ? 512 * mib : 5 * gib))
            XCTAssertEqual(policy.videoBudget, .bytes(512 * mib))
            XCTAssertEqual(policy.locationBudget, .unlimited)
            XCTAssertEqual(policy.backupMaximumBytes, 2 * gib)
            XCTAssertEqual(policy.backupMinimumFreeBytes, gib)
            XCTAssertEqual(policy.lowStorageThresholdBytes, 2 * gib)
            XCTAssertEqual(policy.criticalStorageThresholdBytes, 512 * mib)
            XCTAssertEqual(policy.storageRecoveryMarginBytes, 256 * mib)
        }
    }

    func testMacOriginalsOverrideDistinguishesAbsentBoundedAndUnlimited() {
        let absent = DiskCacheBudgetPolicy(platform: .macOS)
        let bounded = DiskCacheBudgetPolicy(platform: .macOS, originalsOverride: .bounded(3 * gib))
        let unlimited = DiskCacheBudgetPolicy(platform: .macOS, originalsOverride: .unlimited)
        XCTAssertEqual(absent.originalsBudget, .bytes(5 * gib))
        XCTAssertEqual(bounded.originalsBudget, .bytes(3 * gib))
        XCTAssertEqual(unlimited.originalsBudget, .unlimited)
        XCTAssertEqual(
            DiskCacheBudgetPolicy(platform: .macOS, originalsOverride: .bounded(0)).originalsBudget, .bytes(0))
    }

    func testMobileIgnoresMacOnlyOverride() {
        let policy = DiskCacheBudgetPolicy(platform: .mobile, originalsOverride: .unlimited)
        XCTAssertEqual(policy.originalsBudget, .bytes(512 * mib))
    }

    func testVolumeFactsDoNotChangeDefaults() {
        let unknown = DiskCacheBudgetPolicy(platform: .mobile)
        for total: Int64? in [nil, 0, 32_000_000_000, Int64.max] {
            for available: Int64? in [nil, 0, Int64.max] {
                let policy = DiskCacheBudgetPolicy(platform: .mobile, totalBytes: total, availableBytes: available)
                XCTAssertEqual(policy, unknown)
                XCTAssertEqual(policy.originalsBudget, .bytes(512 * mib))
                XCTAssertEqual(policy.videoBudget, .bytes(512 * mib))
            }
        }
    }

    func testExtremeBoundedOverrideDoesNotOverflow() {
        XCTAssertEqual(
            DiskCacheBudgetPolicy(platform: .macOS, originalsOverride: .bounded(Int64.max)).originalsBudget,
            .bytes(Int64.max))
        XCTAssertEqual(
            DiskCacheBudgetPolicy(platform: .macOS, originalsOverride: .bounded(Int64.min)).originalsBudget,
            .bytes(0))
    }
}
