#if canImport(UIKit) && !os(watchOS)
    import Testing
    import PhotosCore
    @testable import MediaCacheUIKitAdapter

    @MainActor
    @Suite("UIKit memory-pressure ownership")
    struct UIKitMemoryPressureCoordinatorTests {
        private final class Owner {
            var tiers: [MemoryBudgetTier] = []
        }

        @Test func separateOwnersReceiveEveryTierChange() {
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
            #expect(coordinator.activeAttachmentCount == 2)
        }

        @Test func detachingOneOwnerDoesNotRemoveAnotherOwner() {
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
            coordinator.detach(first)
            governor.update(MemoryConditions(pressure: .critical))

            #expect(first.tiers == [.normal])
            #expect(second.tiers == [.normal, .minimal])
            #expect(coordinator.activeAttachmentCount == 1)
        }

        @Test func inactiveOwnerKeepsRegistrationUntilTeardown() {
            let governor = MemoryPressureGovernor()
            let coordinator = UIKitMemoryPressureCoordinator(testGovernor: governor)
            let owner = Owner()

            coordinator.attach(owner) { [weak owner] tier in
                owner?.tiers.append(tier)
            }

            // A hidden tab suspends rendering, but it does not detach its cache owner.
            governor.update(MemoryConditions(pressure: .warning))
            #expect(owner.tiers == [.normal, .reduced])
            #expect(coordinator.activeAttachmentCount == 1)

            coordinator.detach(owner)
            governor.update(MemoryConditions(pressure: .critical))
            #expect(owner.tiers == [.normal, .reduced])
            #expect(coordinator.activeAttachmentCount == 0)
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
#endif
