#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore
    import Testing

    @testable import ProtonDriveBackend

    @Suite("Upgrade test link visibility")
    struct UpgradeTestLinkVisibilityTests {
        @Test("the synthetic server gives no explicit photo role data")
        func answersAreNotExplicit() {
            let visibility = UpgradeTestBackend.linkVisibility(
                of: ["listed", "missing"], activeLinkIDs: ["listed", "other"])
            func answer(isActive: Bool) -> RemoteLinkVisibility {
                RemoteLinkVisibility(isActive: isActive, mainPhotoLinkID: nil, hasExplicitPhotoState: false)
            }
            #expect(visibility == ["listed": answer(isActive: true), "missing": answer(isActive: false)])
            #expect(visibility.values.allSatisfy { !$0.hasExplicitPhotoState })
        }

        @Test("the state of a listed link still decides whether it is active")
        func listedLinksStayActive() {
            let visibility = UpgradeTestBackend.linkVisibility(of: ["a", "b"], activeLinkIDs: ["a"])
            #expect(visibility["a"]?.isActiveMain == true)
            #expect(visibility["b"]?.isActiveMain == false)
        }
    }
#endif
