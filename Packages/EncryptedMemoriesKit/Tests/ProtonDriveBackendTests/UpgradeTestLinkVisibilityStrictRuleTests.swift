#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore
    import Testing

    @testable import ProtonDriveBackend

    /// Issue 876: a root photo counts as backed up only when the state answer explicitly carries the
    /// photo state. The synthetic upgrade-test server feeds the duplicate check of both app
    /// installations, so its answers must prove an uploaded main photo; otherwise every released
    /// version re-uploads its roots and fails the journey's duplicate-upload gate.
    @Suite("Upgrade test link visibility strict role rule")
    struct UpgradeTestLinkVisibilityStrictRuleTests {
        @Test("the synthetic answers prove an uploaded main photo")
        func answersProveARootBackup() {
            let visibility = UpgradeTestBackend.linkVisibility(
                of: ["uploaded", "trashed"], activeLinkIDs: ["uploaded"])
            // The root branch of UploadDedupePipeline.countsAsBackup: an active main photo with
            // explicit photo state. A role-less answer never proves a root backup.
            func provesRootBackup(_ answer: RemoteLinkVisibility?) -> Bool {
                answer.map { $0.isActive && $0.isActiveMain && $0.hasExplicitPhotoState } == true
            }
            #expect(provesRootBackup(visibility["uploaded"]))
            #expect(!provesRootBackup(visibility["trashed"]))
            #expect(!provesRootBackup(visibility["absent"]))
        }
    }
#endif
