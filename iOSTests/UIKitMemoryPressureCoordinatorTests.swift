import PhotosCore
import Testing

@testable import MediaCacheUIKitAdapter

@MainActor
@Suite("UIKit memory-pressure ownership in the iOS test host")
struct UIKitMemoryPressureCoordinatorAppTests {
    private final class Owner {
        var tiers: [MemoryBudgetTier] = []
    }

    @Test func separateOwnersStayIndependent() {
        let governor = MemoryPressureGovernor()
        let coordinator = UIKitMemoryPressureCoordinator(testGovernor: governor)
        let first = Owner()
        let second = Owner()

        coordinator.attach(first) { [weak first] tier in
            first?.tiers.append(tier)
        }
        coordinator.attach(second) { [weak second] tier in
            second?.tiers.append(tier)
        }

        governor.update(MemoryConditions(pressure: .warning))
        #expect(first.tiers == [.normal, .reduced])
        #expect(second.tiers == [.normal, .reduced])

        coordinator.detach(first)
        governor.update(MemoryConditions(pressure: .critical))
        #expect(first.tiers == [.normal, .reduced])
        #expect(second.tiers == [.normal, .reduced, .minimal])
    }

    @Test func attachingTheSameOwnerAgainKeepsTheFirstRegistration() {
        let governor = MemoryPressureGovernor()
        let coordinator = UIKitMemoryPressureCoordinator(testGovernor: governor)
        let owner = Owner()
        let ignored = Owner()

        coordinator.attach(owner) { [weak owner] tier in
            owner?.tiers.append(tier)
        }
        coordinator.attach(owner) { [weak ignored] tier in
            ignored?.tiers.append(tier)
        }
        governor.update(MemoryConditions(pressure: .warning))

        #expect(owner.tiers == [.normal, .reduced])
        #expect(ignored.tiers.isEmpty)
        #expect(governor.responderCount == 1)
    }

    @Test func coordinatorDeinitEndsEveryLiveOwnerRegistration() async {
        let governor = MemoryPressureGovernor()
        let owner = Owner()
        var coordinator: UIKitMemoryPressureCoordinator? = UIKitMemoryPressureCoordinator(testGovernor: governor)

        coordinator?.attach(owner) { [weak owner] tier in
            owner?.tiers.append(tier)
        }
        #expect(owner.tiers == [.normal])

        coordinator = nil
        for _ in 0..<100 where governor.responderCount != 0 {
            await Task.yield()
        }
        #expect(governor.responderCount == 0)

        governor.update(MemoryConditions(pressure: .warning))
        #expect(owner.tiers == [.normal])
    }
}
