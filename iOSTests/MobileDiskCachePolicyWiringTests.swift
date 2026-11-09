import PhotosCore
import Testing

@testable import EncryptedMemoriesMobile

@MainActor @Suite struct MobileDiskCachePolicyWiringTests {
    @Test func originalsLimitFollowsSharedMobilePolicy() {
        let policy = DiskCacheBudgetPolicy(platform: .mobile)
        guard case .bytes(let bytes) = policy.originalsBudget else {
            Issue.record("The current mobile originals policy must have a byte limit")
            return
        }
        #expect(MobileLibraryModel().originalsCacheCapBytes == bytes)
    }
}
