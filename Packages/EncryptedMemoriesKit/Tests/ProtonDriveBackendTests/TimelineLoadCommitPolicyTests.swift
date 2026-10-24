import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite struct TimelineLoadCommitPolicyTests {
    @Test func unchangedCachedTimelineUsesSDKEnumeration() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-4",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .sdkCache)
    }

    @Test func changedServerRevisionUsesAuthoritativePhotosList() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-5",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
    }

    @Test func pendingLocalUploadBypassesSDKCacheBeforeEventAdvances() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-4",
                hasPendingLocalUploads: true,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
    }

    @Test func persistedUploadEvidenceRepairsAPreviouslyCommittedStaleTimeline() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-4",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: true
            ) == .authoritativePhotosList)
    }

    @Test func firstLoadWithoutCacheUsesCompleteMetadataListing() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: nil,
                currentEventToken: "event-1",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
    }

    @Test func inventoryTokenContractForcesOneAuthoritativeRefreshForLegacyCaches() {
        let current = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-4")

        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: current,
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
        #expect(TimelineInventoryValidationTokenPolicy.remoteEventToken(from: current) == "event-4")
    }

    @Test func stableCompleteEnumerationPublishesCurrentToken() {
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: "event-4",
            endEventToken: "event-4",
            enrichmentComplete: true
        )

        #expect(
            decision
                == TimelineLoadCommitDecision(
                    persistedValidationToken: "event-4",
                    monitorBaseline: "event-4"
                ))
    }

    @Test func concurrentMutationKeepsUsableInventoryButForcesConvergence() {
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: "event-4",
            endEventToken: "event-5",
            enrichmentComplete: true
        )

        #expect(
            decision
                == TimelineLoadCommitDecision(
                    persistedValidationToken: "event-4",
                    monitorBaseline: "event-4"
                ))
    }

    @Test func incompleteOptionalEnrichmentStaysMemoryOnlyAndForcesRetry() {
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: "event-4",
            endEventToken: "event-4",
            enrichmentComplete: false
        )

        #expect(
            decision
                == TimelineLoadCommitDecision(
                    persistedValidationToken: nil,
                    monitorBaseline: ""
                ))
    }

    @Test func continuityRecoveryRequiresThreeMatchingPassesAcrossQuietWindow() throws {
        let start = ContinuousClock.now
        let first = TimelineContinuityRecoveryPolicy.decide(
            previous: nil,
            startCursor: "event-12",
            endCursor: "event-12",
            endRequiresAuthoritativeRefresh: false,
            inventoryFingerprint: "inventory-a",
            now: start
        )
        guard case .wait(let firstState) = first else {
            Issue.record("The first full listing must remain uncommitted")
            return
        }
        #expect(firstState.qualifiedPassCount == 1)
        #expect(
            !TimelineContinuityRecoveryPolicy.isEligibleForFullInventory(
                previous: firstState,
                candidateCursor: "event-12",
                now: start.advanced(by: .seconds(11))
            ))
        #expect(
            TimelineContinuityRecoveryPolicy.isEligibleForFullInventory(
                previous: firstState,
                candidateCursor: "event-12",
                now: start.advanced(by: .seconds(12))
            ))

        let tooEarly = TimelineContinuityRecoveryPolicy.decide(
            previous: firstState,
            startCursor: "event-12",
            endCursor: "event-12",
            endRequiresAuthoritativeRefresh: false,
            inventoryFingerprint: "inventory-a",
            now: start.advanced(by: .seconds(11))
        )
        #expect(tooEarly == .wait(firstState))

        let second = TimelineContinuityRecoveryPolicy.decide(
            previous: firstState,
            startCursor: "event-12",
            endCursor: "event-12",
            endRequiresAuthoritativeRefresh: false,
            inventoryFingerprint: "inventory-a",
            now: start.advanced(by: .seconds(12))
        )
        guard case .wait(let secondState) = second else {
            Issue.record("The second qualified listing must remain uncommitted")
            return
        }
        #expect(secondState.qualifiedPassCount == 2)
        #expect(
            !TimelineContinuityRecoveryPolicy.isEligibleForFullInventory(
                previous: secondState,
                candidateCursor: "event-12",
                now: start.advanced(by: .seconds(29))
            ))
        #expect(
            TimelineContinuityRecoveryPolicy.isEligibleForFullInventory(
                previous: secondState,
                candidateCursor: "event-12",
                now: start.advanced(by: .seconds(30))
            ))

        #expect(
            TimelineContinuityRecoveryPolicy.decide(
                previous: secondState,
                startCursor: "event-12",
                endCursor: "event-12",
                endRequiresAuthoritativeRefresh: false,
                inventoryFingerprint: "inventory-a",
                now: start.advanced(by: .seconds(30))
            ) == .ready)
    }

    @Test func qualifiedContinuityRecoveryRequiresSuccessfulAtomicCacheSave() {
        #expect(
            !TimelineContinuityPersistencePolicy.permitsMonitorAdvance(
                recoveryQualified: true,
                cacheSaved: false
            ))
        #expect(
            TimelineContinuityPersistencePolicy.permitsMonitorAdvance(
                recoveryQualified: true,
                cacheSaved: true
            ))
    }

    @Test func continuityBridgeSeamRetainsOldSQLiteInventoryAndCursorUntilRetrySaveSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuityBridgeSeam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library-v1.sqlite")
        let store = try #require(TimelineMetadataStore(url: databaseURL))
        let oldItems = [timelineItem(nodeID: "old", captureTime: 1)]
        let recoveredItems = [timelineItem(nodeID: "recovered", captureTime: 2)]
        let oldToken = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-7")
        let recoveredToken = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-12")
        #expect(store.save(oldItems, validationToken: oldToken).succeeded)

        let recovery = TimelineContinuityRecoveryCoordinator()
        let start = ContinuousClock.now
        var fullInventoryPasses = 0
        var postInventoryProbes = 0
        await #expect(throws: TimelineContinuityRecoveryPendingError.self) {
            let inventory = try await recovery.fetchInventory(cursor: "event-12", now: start) {
                fullInventoryPasses += 1
                return recoveredItems
            }
            _ = try await recovery.qualify(
                startCursor: "event-12",
                inventoryFingerprint: "recovered-inventory",
                now: start
            ) {
                postInventoryProbes += 1
                #expect(inventory == recoveredItems)
                return TimelineContinuityPostInventoryProbe(
                    cursor: "event-12",
                    requiresAuthoritativeRefresh: false
                )
            }
        }
        #expect(fullInventoryPasses == 1)
        #expect(postInventoryProbes == 1)
        #expect(try store.load() == oldItems)
        #expect(store.validationToken() == oldToken)

        await #expect(throws: TimelineContinuityRecoveryPendingError.self) {
            _ = try await recovery.fetchInventory(
                cursor: "event-12",
                now: start.advanced(by: .seconds(11))
            ) {
                Issue.record("an early retry invoked the complete Photos listing")
                fullInventoryPasses += 1
                return recoveredItems
            }
        }
        #expect(fullInventoryPasses == 1, "an early retry must not run another full Photos listing")
        #expect(postInventoryProbes == 1, "an early retry must not run a post-list event probe")

        let secondInventory = try await recovery.fetchInventory(
            cursor: "event-12",
            now: start.advanced(by: .seconds(12))
        ) {
            fullInventoryPasses += 1
            return recoveredItems
        }
        await #expect(throws: TimelineContinuityRecoveryPendingError.self) {
            _ = try await recovery.qualify(
                startCursor: "event-12",
                inventoryFingerprint: "recovered-inventory",
                now: start.advanced(by: .seconds(12))
            ) {
                postInventoryProbes += 1
                #expect(secondInventory == recoveredItems)
                return TimelineContinuityPostInventoryProbe(
                    cursor: "event-12",
                    requiresAuthoritativeRefresh: false
                )
            }
        }
        #expect(fullInventoryPasses == 2)
        #expect(postInventoryProbes == 2)
        #expect(try store.load() == oldItems)
        #expect(store.validationToken() == oldToken)

        await #expect(throws: TimelineContinuityRecoveryPendingError.self) {
            _ = try await recovery.fetchInventory(
                cursor: "event-12",
                now: start.advanced(by: .seconds(29))
            ) {
                Issue.record("the final full listing ran before the complete quiet window")
                fullInventoryPasses += 1
                return recoveredItems
            }
        }
        #expect(fullInventoryPasses == 2, "the final full listing must wait for the complete quiet window")
        #expect(postInventoryProbes == 2)

        let finalInventory = try await recovery.fetchInventory(
            cursor: "event-12",
            now: start.advanced(by: .seconds(30))
        ) {
            fullInventoryPasses += 1
            return recoveredItems
        }
        let firstQualification = try await recovery.qualify(
            startCursor: "event-12",
            inventoryFingerprint: "recovered-inventory",
            now: start.advanced(by: .seconds(30))
        ) {
            postInventoryProbes += 1
            #expect(finalInventory == recoveredItems)
            return TimelineContinuityPostInventoryProbe(
                cursor: "event-12",
                requiresAuthoritativeRefresh: false
            )
        }
        #expect(firstQualification.recoveryQualified)
        #expect(fullInventoryPasses == 3)
        #expect(postInventoryProbes == 3)

        // Closing the real SQLite connection makes this production save return `succeeded == false`.
        // The coordinator must keep the proof and the monitor must retain its old cursor.
        store.close()
        var monitorCursor = oldToken
        #expect(throws: TimelineContinuityRecoveryPendingError.self) {
            let cacheSaved = try recovery.persist(recoveryQualified: firstQualification.recoveryQualified) {
                store.save(recoveredItems, validationToken: recoveredToken).succeeded
            }
            if cacheSaved { monitorCursor = recoveredToken }
        }
        #expect(monitorCursor == oldToken)
        #expect(recovery.state?.qualifiedPassCount == 2)

        let reopened = try #require(TimelineMetadataStore(url: databaseURL))
        #expect(try reopened.load() == oldItems)
        #expect(reopened.validationToken() == oldToken)

        let retryInventory = try await recovery.fetchInventory(
            cursor: "event-12",
            now: start.advanced(by: .seconds(31))
        ) {
            fullInventoryPasses += 1
            return recoveredItems
        }
        let retryQualification = try await recovery.qualify(
            startCursor: "event-12",
            inventoryFingerprint: "recovered-inventory",
            now: start.advanced(by: .seconds(31))
        ) {
            postInventoryProbes += 1
            #expect(retryInventory == recoveredItems)
            return TimelineContinuityPostInventoryProbe(
                cursor: "event-12",
                requiresAuthoritativeRefresh: false
            )
        }
        let cacheSaved = try recovery.persist(recoveryQualified: retryQualification.recoveryQualified) {
            reopened.save(recoveredItems, validationToken: recoveredToken).succeeded
        }
        if cacheSaved { monitorCursor = recoveredToken }

        #expect(fullInventoryPasses == 4)
        #expect(postInventoryProbes == 4, "the failed final save must require a fresh post-list probe")
        #expect(recovery.state == nil)
        #expect(monitorCursor == recoveredToken)
        #expect(try reopened.load() == recoveredItems)
        #expect(reopened.validationToken() == recoveredToken)
        reopened.close()
    }

    @Test func continuityRecoveryRestartsOnInventoryOrCursorMovement() {
        let start = ContinuousClock.now
        let previous = TimelineContinuityRecoveryState(
            cursor: "event-12",
            inventoryFingerprint: "inventory-a",
            firstObservedAt: start,
            qualifiedPassCount: 2
        )

        let changedInventory = TimelineContinuityRecoveryPolicy.decide(
            previous: previous,
            startCursor: "event-12",
            endCursor: "event-12",
            endRequiresAuthoritativeRefresh: false,
            inventoryFingerprint: "inventory-b",
            now: start.advanced(by: .seconds(30))
        )
        guard case .wait(let restarted) = changedInventory else {
            Issue.record("A changed inventory must start a new proof window")
            return
        }
        #expect(restarted.qualifiedPassCount == 1)
        #expect(restarted.inventoryFingerprint == "inventory-b")

        #expect(
            TimelineContinuityRecoveryPolicy.decide(
                previous: previous,
                startCursor: "event-12",
                endCursor: "event-13",
                endRequiresAuthoritativeRefresh: false,
                inventoryFingerprint: "inventory-a",
                now: start.advanced(by: .seconds(30))
            ) == .restartWindow)
        #expect(
            TimelineContinuityRecoveryPolicy.decide(
                previous: previous,
                startCursor: "event-12",
                endCursor: "event-12",
                endRequiresAuthoritativeRefresh: true,
                inventoryFingerprint: "inventory-a",
                now: start.advanced(by: .seconds(30))
            ) == .restartWindow)
    }

    @Test func continuityInventoryFingerprintIsCanonicalAndCoversTimelineFields() {
        let first = PhotosListEntry(
            linkID: "one",
            captureTime: 1,
            tags: [3, 1],
            relatedPhotos: [.init(linkID: "live")]
        )
        let second = PhotosListEntry(
            linkID: "two",
            captureTime: 2,
            tags: [],
            relatedPhotos: []
        )
        let changed = PhotosListEntry(
            linkID: "two",
            captureTime: 3,
            tags: [],
            relatedPhotos: []
        )

        #expect(
            TimelineContinuityInventoryFingerprint.make(entries: [first, second])
                == TimelineContinuityInventoryFingerprint.make(entries: [second, first]))
        #expect(
            TimelineContinuityInventoryFingerprint.make(entries: [first, second])
                != TimelineContinuityInventoryFingerprint.make(entries: [first, changed]))
    }

    @Test func remoteEventEvidenceTracksOnlyActiveFilesInThePhotosShare() throws {
        let data = Data(
            #"""
            {
              "Events": [
                {"EventType": 1, "ContextShareID": "photos", "Link": {"LinkID": "new-photo", "Type": 2, "State": 1}},
                {"EventType": 1, "ContextShareID": "other", "Link": {"LinkID": "other-file", "Type": 2, "State": 1}},
                {"EventType": 0, "Link": {"LinkID": "removed", "Type": 2, "State": 0}}
              ],
              "EventID": "event-5", "More": 0, "Refresh": 0
            }
            """#.utf8)
        let page = try JSONDecoder().decode(VolumeEventPage.self, from: data)
        var changes = TimelineRemoteEventChanges(active: ["removed"])

        TimelineRemoteEventVisibilityPolicy.apply(page.events, photosShareID: "photos", to: &changes)

        #expect(changes.active == Set(["new-photo"]))
        #expect(changes.removed == Set(["removed"]))
    }

    @Test func aPhotoMovedToTheTrashCountsAsRemovedUntilItIsRestored() throws {
        let data = Data(
            #"""
            {
              "Events": [
                {"EventType": 1, "ContextShareID": "photos", "Link": {"LinkID": "edited", "Type": 2, "State": 1}},
                {"EventType": 2, "ContextShareID": "photos", "Link": {"LinkID": "earlier", "Type": 2, "State": 2}},
                {"EventType": 2, "ContextShareID": "photos", "Link": {"LinkID": "restored", "Type": 2, "State": 2}},
                {"EventType": 2, "ContextShareID": "photos", "Link": {"LinkID": "restored", "Type": 2, "State": 1}}
              ],
              "EventID": "event-6", "More": 0, "Refresh": 0
            }
            """#.utf8)
        let page = try JSONDecoder().decode(VolumeEventPage.self, from: data)
        var changes = TimelineRemoteEventChanges()

        TimelineRemoteEventVisibilityPolicy.apply(page.events, photosShareID: "photos", to: &changes)

        #expect(changes.active == Set(["edited", "restored"]))
        #expect(changes.removed == Set(["earlier"]), "the listing must not show the trashed photo again")
    }

    @Test func relatedFilesOfATrashedPhotoDoNotHoldTheListingBack() {
        // Evidence of 2026-09-30: an edit replacement trashed the main photo; its original, edit data, and Live Photo
        // video stayed active on the server and never appeared in a listing again.
        typealias Link = TimelineRemoteVisibilityRequirement.Link
        let links: [String: Link] = [
            "original": Link(isActive: true, mainPhotoLinkID: "trashed-edit"),
            "video": Link(isActive: true, mainPhotoLinkID: "trashed-edit"),
            "new-video": Link(isActive: true, mainPhotoLinkID: "new-edit"),
            "new-photo": Link(isActive: true, mainPhotoLinkID: nil),
            "trashed-photo": Link(isActive: false, mainPhotoLinkID: nil),
        ]
        let mainPhotos: [String: Link] = [
            "trashed-edit": Link(isActive: false, mainPhotoLinkID: nil),
            "new-edit": Link(isActive: true, mainPhotoLinkID: nil),
        ]
        #expect(TimelineRemoteVisibilityRequirement.mainPhotoLinkIDs(of: links) == ["trashed-edit", "new-edit"])

        let awaited = TimelineRemoteVisibilityRequirement.awaited(
            ["original", "video", "new-video", "new-photo", "trashed-photo", "deleted"], links: links,
            mainPhotos: mainPhotos)

        #expect(awaited == ["new-video", "new-photo"], "only files of active photos can still appear")
    }

    @Test func aRelatedFileWhoseMainPhotoIsGoneForGoodDoesNotHoldTheListingBack() {
        typealias Link = TimelineRemoteVisibilityRequirement.Link
        let links = ["original": Link(isActive: true, mainPhotoLinkID: "deleted-edit")]

        #expect(TimelineRemoteVisibilityRequirement.awaited(["original"], links: links, mainPhotos: [:]).isEmpty)
    }

    @Test func remoteVisibilityFailureUsesTheSharedConvergenceMarker() {
        let error: any Error = TimelineInventoryVisibilityError.remoteChangesNotVisible(1)
        #expect(error is any TimelineInventoryConvergenceError)
    }

    private func timelineItem(nodeID: String, captureTime: TimeInterval) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "photos-volume", nodeID: nodeID),
            captureTime: Date(timeIntervalSince1970: captureTime),
            mediaType: "image/jpeg"
        )
    }
}
