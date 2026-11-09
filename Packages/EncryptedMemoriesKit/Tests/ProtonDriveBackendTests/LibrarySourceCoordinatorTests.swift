import AlbumCore
import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Library source coordinator")
struct LibrarySourceCoordinatorTests {
    @Test func provisionalThumbnailsNeverBecomeInventoryAndDoNotReplaceTheTrashRegistration() async throws {
        let uid = PhotoUID(volumeID: "primary-volume", nodeID: "provisional")
        let trashUID = PhotoUID(volumeID: "primary-volume", nodeID: "in-trash")
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.setIdentitiesOutsideInventory([trashUID], sequence: 1)
        let before = await coordinator.snapshot()
        let lease = try #require(await coordinator.beginProvisionalThumbnailAccess())
        await coordinator.updateProvisionalThumbnailAccess([uid], using: lease)
        let delivered = ThumbnailDeliveryRecorder()
        let result = await coordinator.loadThumbnails(for: [uid, trashUID], priority: .visibleNow) { uid, data in
            delivered.store(data, for: uid)
        }
        #expect(delivered.data(for: uid) != nil, "A known provisional photo must load its thumbnail")
        #expect(result.itemErrors[uid] == nil)
        #expect(delivered.data(for: trashUID) != nil)
        let during = await coordinator.snapshot()
        #expect(during.selectedProjection.timeline.uids == before.selectedProjection.timeline.uids)
        #expect(during.retentionProjection.timeline.uids == before.retentionProjection.timeline.uids)
        #expect(during.selectedScope.uids == before.selectedScope.uids)
        #expect(during.analysisScope.uids == before.analysisScope.uids)
        #expect(during.retentionScope.uids == before.retentionScope.uids)
        #expect(!during.retentionScope.isAuthoritative)
        #expect(during.orphanedUIDs.isEmpty, "A provisional page cannot orphan inventory")
        await coordinator.endProvisionalThumbnailAccess(lease)
        await coordinator.updateProvisionalThumbnailAccess([uid], using: lease)
        let withdrawn = await coordinator.loadThumbnails(for: [uid, trashUID], priority: .visibleNow) { _, _ in }
        #expect(withdrawn.itemErrors[uid] == "source unavailable", "A retired presentation cannot authorize bytes")
        #expect(withdrawn.itemErrors[trashUID] == nil, "Its closure must preserve Recently Deleted")
        let after = await coordinator.snapshot()
        #expect(after.analysisScope.uids == before.analysisScope.uids)
        #expect(after.retentionScope.uids == before.retentionScope.uids)
        #expect(!after.retentionScope.isAuthoritative)
        #expect(after.orphanedUIDs.isEmpty)
        await coordinator.shutdown()
    }

    @Test func closingOneProvisionalPresentationKeepsTheOtherAndRecentlyDeletedAuthorized() async throws {
        let first = PhotoUID(volumeID: "primary-volume", nodeID: "first-page")
        let second = PhotoUID(volumeID: "primary-volume", nodeID: "second-page")
        let shared = PhotoUID(volumeID: "primary-volume", nodeID: "shared-photo")
        let trash = PhotoUID(volumeID: "primary-volume", nodeID: "in-trash")
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.setIdentitiesOutsideInventory([trash], sequence: 1)
        let before = await coordinator.snapshot()
        let firstLease = try #require(await coordinator.beginProvisionalThumbnailAccess())
        let secondLease = try #require(await coordinator.beginProvisionalThumbnailAccess())
        await coordinator.updateProvisionalThumbnailAccess([first, shared], using: firstLease)
        await coordinator.updateProvisionalThumbnailAccess([second, shared], using: secondLease)
        await coordinator.endProvisionalThumbnailAccess(firstLease)
        await coordinator.updateProvisionalThumbnailAccess([first], using: firstLease)
        let delivered = ThumbnailDeliveryRecorder()
        let result = await coordinator.loadThumbnails(for: [first, second, shared, trash], priority: .visibleNow) {
            uid, data in
            delivered.store(data, for: uid)
        }
        #expect(result.itemErrors[first] == "source unavailable")
        for uid in [second, shared, trash] {
            #expect(result.itemErrors[uid] == nil)
            #expect(delivered.data(for: uid) != nil)
        }
        #expect(delivered.data(for: first) == nil)
        let during = await coordinator.snapshot()
        #expect(during.selectedScope.uids == before.selectedScope.uids)
        #expect(during.analysisScope.uids == before.analysisScope.uids)
        #expect(during.retentionScope.uids == before.retentionScope.uids)
        #expect(!during.retentionScope.isAuthoritative)
        #expect(during.orphanedUIDs.isEmpty)
        await coordinator.endProvisionalThumbnailAccess(secondLease)
        let ended = await coordinator.loadThumbnails(for: [second, shared, trash], priority: .visibleNow) { _, _ in }
        #expect(ended.itemErrors[second] == "source unavailable")
        #expect(ended.itemErrors[shared] == "source unavailable")
        #expect(ended.itemErrors[trash] == nil)
        await coordinator.shutdown()
        #expect(await coordinator.beginProvisionalThumbnailAccess() == nil)
        await coordinator.updateProvisionalThumbnailAccess([first, second], using: secondLease)
        let closed = await coordinator.loadThumbnails(for: [first, second], priority: .visibleNow) { _, _ in }
        #expect(closed.batchError == "source runtime closed")
    }

    @Test func additionalInventoryParticipatesInAnalysisButNotThePrimaryProjection() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([
            AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album"): [Self.item(remoteUID)]
        ])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        let primaryUID = PhotoUID(volumeID: "primary-volume", nodeID: "primary-photo")
        await coordinator.replacePrimaryInventory(
            [
                PhotoItem(
                    uid: primaryUID,
                    captureTime: Date(timeIntervalSince1970: 1),
                    mediaType: "image/jpeg"
                )
            ], authority: .authoritative)

        await coordinator.refresh()

        let change = try #require(await recorder.latest())
        #expect(change.selectedScope.uids == [primaryUID])
        #expect(change.analysisScope.uids == [primaryUID, remoteUID])
        #expect(change.thumbnailRetentionScope.uids == [primaryUID, remoteUID])
        #expect(change.selectedProjection.timeline.uids == [primaryUID])
        await coordinator.shutdown()
    }

    @Test func burstMemberThumbnailsAreAuthorizedThroughTheirSeries() async throws {
        let keyUID = PhotoUID(volumeID: "primary-volume", nodeID: "burst-key")
        let memberUID = PhotoUID(volumeID: "primary-volume", nodeID: "burst-member")
        let strangerUID = PhotoUID(volumeID: "primary-volume", nodeID: "not-a-member")
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.replacePrimaryInventory(
            [
                PhotoItem(
                    uid: keyUID,
                    captureTime: Date(timeIntervalSince1970: 1),
                    mediaType: "image/jpeg",
                    burstMemberIDs: [keyUID.nodeID, memberUID.nodeID]
                )
            ], authority: .authoritative)
        let delivered = ThumbnailDeliveryRecorder()

        let result = await coordinator.loadThumbnails(for: [memberUID, strangerUID], priority: .visibleNow) {
            uid, data in
            delivered.store(data, for: uid)
        }

        #expect(delivered.data(for: memberUID) != nil, "an opened series must load its member thumbnails")
        #expect(result.itemErrors[memberUID] == nil)
        #expect(delivered.data(for: strangerUID) == nil)
        #expect(result.itemErrors[strangerUID] == "source unavailable")
        await coordinator.shutdown()
    }

    @Test func recentlyDeletedThumbnailsLoadAfterTheirRouteRegistersThem() async throws {
        let itemUID = PhotoUID(volumeID: "primary-volume", nodeID: "library-item")
        let trashedUID = PhotoUID(volumeID: "primary-volume", nodeID: "trashed-photo")
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.replacePrimaryInventory(
            [PhotoItem(uid: itemUID, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")],
            authority: .authoritative)
        let delivered = ThumbnailDeliveryRecorder()

        // Before the trash listing runs, nothing proves that the user may read this photo.
        let refused = await coordinator.loadThumbnails(for: [trashedUID], priority: .visibleNow) { uid, data in
            delivered.store(data, for: uid)
        }
        #expect(refused.itemErrors[trashedUID] == "source unavailable")

        await coordinator.setIdentitiesOutsideInventory([trashedUID], sequence: 1)
        let result = await coordinator.loadThumbnails(for: [trashedUID], priority: .visibleNow) { uid, data in
            delivered.store(data, for: uid)
        }

        #expect(delivered.data(for: trashedUID) != nil, "a Recently Deleted tile must load its thumbnail")
        #expect(result.itemErrors[trashedUID] == nil)

        await coordinator.setIdentitiesOutsideInventory([], sequence: 2)
        let withdrawn = await coordinator.loadThumbnails(for: [trashedUID], priority: .visibleNow) { _, _ in }
        #expect(withdrawn.itemErrors[trashedUID] == "source unavailable")
        await coordinator.shutdown()
    }

    @Test func aDelayedOlderRecentlyDeletedReportCannotReplaceANewerOne() async throws {
        let trashedUID = PhotoUID(volumeID: "primary-volume", nodeID: "just-trashed")
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.replacePrimaryInventory([], authority: .authoritative)

        // The newer report (with the photo just trashed) arrives first; a listing's older report arrives late.
        await coordinator.setIdentitiesOutsideInventory([trashedUID], sequence: 5)
        await coordinator.setIdentitiesOutsideInventory([], sequence: 4)

        let delivered = ThumbnailDeliveryRecorder()
        let result = await coordinator.loadThumbnails(for: [trashedUID], priority: .visibleNow) { uid, data in
            delivered.store(data, for: uid)
        }
        #expect(result.itemErrors[trashedUID] == nil, "the newer report must stay in force")
        #expect(delivered.data(for: trashedUID) != nil)
        await coordinator.shutdown()
    }

    @Test func removedSourceRejectsThumbnailBytesWhichArriveAfterRevocation() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        await backend.setSources([
            AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album"): [Self.item(remoteUID)]
        ])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        await coordinator.refresh()
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [remoteUID]) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() {
            await Task.yield()
        }

        await backend.setSources([:])
        await coordinator.refresh()
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect(delivered.data(for: remoteUID) == nil)
        #expect(result.withheldUIDs == [remoteUID])
        #expect(result.itemErrors.isEmpty, "a withheld thumbnail is not a refusal")
        await coordinator.shutdown()
    }

    @Test func aThumbnailThatArrivesAfterItsPhotoWasRefreshedIsStillDelivered() async throws {
        let uid = PhotoUID(volumeID: "primary-volume", nodeID: "photo")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        let captured = Date(timeIntervalSince1970: 1)
        await coordinator.replacePrimaryInventory(
            [PhotoItem(uid: uid, captureTime: captured, mediaType: "image/jpeg")], authority: .authoritative)
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [uid], priority: .visibleNow) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() { await Task.yield() }

        // After sign-in the library keeps refreshing photos it already lists, for example their tags. The photo
        // stays in the library, so its thumbnail must not be refused and then never requested again.
        await coordinator.replacePrimaryInventory(
            [PhotoItem(uid: uid, captureTime: captured, mediaType: "image/jpeg", tags: [.favorites])],
            authority: .authoritative)
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect(delivered.data(for: uid) != nil)
        #expect(result.itemErrors[uid] == nil)
        await coordinator.shutdown()
    }

    @Test func aSeriesMemberThumbnailSurvivesARefreshOfItsSeries() async throws {
        let keyUID = PhotoUID(volumeID: "primary-volume", nodeID: "burst-key")
        let memberUID = PhotoUID(volumeID: "primary-volume", nodeID: "burst-member")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        func series(tags: Set<PhotoTag>) -> [PhotoItem] {
            [
                PhotoItem(
                    uid: keyUID, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg", tags: tags,
                    burstMemberIDs: [keyUID.nodeID, memberUID.nodeID])
            ]
        }
        await coordinator.replacePrimaryInventory(series(tags: []), authority: .authoritative)
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [memberUID], priority: .visibleNow) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() { await Task.yield() }

        await coordinator.replacePrimaryInventory(series(tags: [.favorites]), authority: .authoritative)
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect(delivered.data(for: memberUID) != nil)
        #expect(result.withheldUIDs.isEmpty)
        await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func aRecentlyDeletedThumbnailFollowsTheCurrentListing(photoWasRestored: Bool) async throws {
        let itemUID = PhotoUID(volumeID: "primary-volume", nodeID: "library-item")
        let trashedUID = PhotoUID(volumeID: "primary-volume", nodeID: "trashed-photo")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        let captured = Date(timeIntervalSince1970: 1)
        await coordinator.replacePrimaryInventory(
            [PhotoItem(uid: itemUID, captureTime: captured, mediaType: "image/jpeg")], authority: .authoritative)
        await coordinator.setIdentitiesOutsideInventory([trashedUID], sequence: 1)
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [trashedUID], priority: .visibleNow) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() { await Task.yield() }

        // A refresh of another photo keeps the trashed photo readable; a listing without it withholds its bytes.
        await coordinator.replacePrimaryInventory(
            [PhotoItem(uid: itemUID, captureTime: captured, mediaType: "image/jpeg", tags: [.favorites])],
            authority: .authoritative)
        if photoWasRestored { await coordinator.setIdentitiesOutsideInventory([], sequence: 2) }
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect((delivered.data(for: trashedUID) != nil) == !photoWasRestored)
        #expect(result.withheldUIDs == (photoWasRestored ? [trashedUID] : []))
        await coordinator.shutdown()
    }

    @Test func aThumbnailThatArrivesAfterItsPhotoLeftTheLibraryIsRefused() async throws {
        let uid = PhotoUID(volumeID: "primary-volume", nodeID: "photo")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.replacePrimaryInventory(
            [PhotoItem(uid: uid, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")],
            authority: .authoritative)
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [uid], priority: .visibleNow) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() { await Task.yield() }

        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect(delivered.data(for: uid) == nil)
        #expect(result.withheldUIDs == [uid])
        #expect(result.itemErrors.isEmpty)
        await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func thumbnailsStreamBeforeTheBatchEndsAndLateBytesRemainFenced(closeRuntime: Bool) async throws {
        let firstUID = PhotoUID(volumeID: "remote-volume", nodeID: "first")
        let lateUID = PhotoUID(volumeID: "remote-volume", nodeID: "late")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend(blockAfterFirstThumbnail: true, repeatFirstThumbnail: true)
        await backend.setSources([locator: [Self.item(firstUID), Self.item(lateUID)]])
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.refresh()
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [firstUID, lateUID], priority: .visibleNow) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() { await Task.yield() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while delivered.data(for: firstUID) == nil, ContinuousClock.now < deadline { await Task.yield() }
        let deliveredBeforeCompletion = delivered.data(for: firstUID) != nil
        if closeRuntime {
            await coordinator.shutdown()
        } else {
            await coordinator.revokeAdditionalSource(for: locator)
        }
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect(deliveredBeforeCompletion, "An available thumbnail must not wait for the remaining download")
        #expect(delivered.data(for: lateUID) == nil)
        #expect(result.withheldUIDs == [lateUID], "Already delivered items must not also be reported as withheld")
        #expect(result.itemErrors.isEmpty, "Unrequested callbacks must not create item errors")
        await coordinator.shutdown()
    }

    @Test func cancelledThumbnailStreamJoinsTheLoaderWithoutReportingAccessLoss() async throws {
        let uid = PhotoUID(volumeID: "remote-volume", nodeID: "photo")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        await backend.setSources([
            AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album"): [Self.item(uid)]
        ])
        let coordinator = LibrarySourceCoordinator(remote: backend, thumbnailLoader: backend, inventoryStore: nil)
        await coordinator.prepare()
        await coordinator.refresh()
        let delivered = ThumbnailDeliveryRecorder()
        let completion = SynchronousCompletionProbe()
        let load = Task {
            let result = await coordinator.loadThumbnails(for: [uid]) { uid, data in
                delivered.store(data, for: uid)
            }
            completion.markCompleted()
            return result
        }
        while await !backend.isThumbnailLoadWaiting() { await Task.yield() }
        load.cancel()
        while await !backend.wasThumbnailLoadCancelled() { await Task.yield() }
        // This loader deliberately does not cooperate with cancellation. The caller still owns
        // its structured child and cannot finish while the backend has not returned.
        #expect(!completion.isCompleted)
        await backend.releaseThumbnailLoad()
        let result = await load.value
        #expect(result.batchError == "cancelled")
        #expect(result.itemErrors.isEmpty)
        #expect(delivered.data(for: uid) == nil)
        await coordinator.shutdown()
    }

    @Test func confirmedAccessLossImmediatelyRemovesDerivedDataMembership() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await coordinator.refresh()
        #expect(await recorder.latest()?.analysisScope.uids == [remoteUID])

        await coordinator.revokeAdditionalSource(for: locator)

        let revoked = try #require(await recorder.latest())
        #expect(revoked.analysisScope.uids.isEmpty)
        #expect(revoked.analysisScope.isAuthoritative)
        #expect(revoked.thumbnailRetentionScope.uids.isEmpty)
        #expect(revoked.orphanedUIDs == [remoteUID])
        await coordinator.shutdown()
    }

    @Test func confirmedAccessLossRejectsAnInFlightInventoryResult() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        await backend.blockNextItemEnumeration(for: locator)
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)

        let refresh = Task { await coordinator.refresh() }
        while await !backend.isItemEnumerationWaiting() {
            await Task.yield()
        }

        await coordinator.revokeAdditionalSource(for: locator)
        await backend.releaseItemEnumeration()
        await refresh.value

        let change = try #require(await recorder.latest())
        #expect(change.analysisScope.uids.isEmpty)
        #expect(change.analysisScope.isAuthoritative)
        #expect(change.thumbnailRetentionScope.uids.isEmpty)
        #expect(!change.analysisScope.sourceIDs.contains(where: { $0.rawValue.hasPrefix("additional:") }))
        #expect(await backend.itemEnumerationCalls == 1)
        await coordinator.shutdown()
    }

    @Test func unchangedAndTransientRefreshesDoNotRepublishConsumerWork() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        #expect(await coordinator.refresh() == .complete)
        let baseline = await recorder.count()

        #expect(await coordinator.refresh() == .complete)
        #expect(await recorder.count() == baseline)

        await backend.setDiscoveryFailure(true)
        #expect(await coordinator.refresh() == .retryableFailure)
        #expect(await recorder.count() == baseline)

        await backend.setDiscoveryFailure(false)
        #expect(await coordinator.refresh() == .complete)
        #expect(await recorder.count() == baseline)

        let addedUID = PhotoUID(volumeID: "remote-volume", nodeID: "added-photo")
        await backend.setSources([locator: [Self.item(remoteUID), Self.item(addedUID)]])
        await coordinator.refresh()
        #expect(await recorder.count() == baseline + 1)
        let latest = try #require(await recorder.latest())
        #expect(latest.analysisScope.uids.contains(addedUID))
        await coordinator.shutdown()
    }

    @Test func cancelledCallerCannotAdmitANewRemoteRefresh() async {
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let admission = CancelledTaskAdmissionGate()
        let refresh = Task {
            await admission.wait()
            await coordinator.refresh()
        }
        while await !admission.isWaiting { await Task.yield() }

        refresh.cancel()
        await admission.release()
        await refresh.value

        #expect(await backend.discoveryCalls == 0)
        await coordinator.shutdown()
    }

    @Test func refreshRequestedWhileARefreshIsActiveRunsOneCoalescedFollowUp() async throws {
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        await backend.blockNextItemEnumeration(for: locator)
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()

        let first = Task { await coordinator.refresh() }
        while await !backend.isItemEnumerationWaiting() { await Task.yield() }
        let secondStarted = SynchronousCompletionProbe()
        let second = Task {
            secondStarted.markCompleted()
            return await coordinator.refresh()
        }
        while !secondStarted.isCompleted { await Task.yield() }
        // Give the already-unblocked coordinator actor a scheduling turn before the remote result resumes.
        try await Task.sleep(for: .milliseconds(10))
        await backend.releaseItemEnumeration()

        #expect(await first.value == .complete)
        #expect(await second.value == .complete)
        #expect(await backend.discoveryCalls == 2)
        #expect(await backend.itemEnumerationCalls == 2)
        await coordinator.shutdown()
    }

    @Test func oneFinalRefreshProjectionPreservesLastReferenceRemoval() async throws {
        let removedUID = PhotoUID(volumeID: "remote-volume", nodeID: "removed-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(removedUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await coordinator.refresh()
        let baselineCount = await recorder.count()

        await backend.setSources([locator: []])
        await coordinator.refresh()

        let change = try #require(await recorder.latest())
        #expect(await recorder.count() == baselineCount + 1)
        #expect(change.analysisScope.uids.isEmpty)
        #expect(change.analysisScope.isAuthoritative)
        #expect(change.orphanedUIDs == [removedUID])
        await coordinator.shutdown()
    }

    @Test func membershipFailurePublishesAuthorityDowngradeAndRetainsCachedIdentity() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await coordinator.refresh()
        let baseline = await recorder.count()

        await backend.setItemEnumerationFailure(true)
        await coordinator.refresh()

        let degraded = try #require(await recorder.latest())
        #expect(await recorder.count() == baseline + 1)
        #expect(degraded.analysisScope.uids == [remoteUID])
        #expect(!degraded.analysisScope.isAuthoritative)

        await backend.setItemEnumerationFailure(false)
        await coordinator.refresh()
        #expect(await recorder.count() == baseline + 2)
        #expect(await recorder.latest()?.analysisScope.isAuthoritative == true)
        await coordinator.shutdown()
    }

    @Test func confirmedAccessLossRemainsFencedAcrossRestartUntilRemoteAbsence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EncryptedMemories-SourceCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(data: Data(repeating: 0x31, count: 32))
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])

        let first = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: LibrarySourceInventoryStore(
                directory: directory,
                accountUID: "account",
                encryptionKey: key
            )
        )
        await first.prepare()
        await first.replacePrimaryInventory([], authority: .authoritative)
        await first.refresh()
        #expect(await backend.itemEnumerationCalls == 1)
        let persistenceBarrier = BlockingLibrarySourceChangeSink()
        _ = await first.attach { change in await persistenceBarrier.receive(change) }
        await persistenceBarrier.blockNextChange()
        let revoke = Task { await first.revokeAdditionalSource(for: locator) }
        while await !persistenceBarrier.isWaiting { await Task.yield() }
        let shutdownCompleted = SynchronousCompletionProbe()
        let shutdown = Task {
            await first.shutdown()
            shutdownCompleted.markCompleted()
        }
        for _ in 0..<1_000 where !shutdownCompleted.isCompleted { await Task.yield() }
        #expect(!shutdownCompleted.isCompleted)

        await persistenceBarrier.release()
        await revoke.value
        await shutdown.value
        #expect(shutdownCompleted.isCompleted)

        let second = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: LibrarySourceInventoryStore(
                directory: directory,
                accountUID: "account",
                encryptionKey: key
            )
        )
        await second.prepare()
        let secondRecorder = LibrarySourceChangeRecorder()
        _ = await second.attach { change in await secondRecorder.store(change) }
        await second.replacePrimaryInventory([], authority: .authoritative)
        await second.refresh()
        #expect(await secondRecorder.latest()?.analysisScope.uids.isEmpty == true)
        #expect(await backend.itemEnumerationCalls == 1)

        await backend.setSources([:])
        await second.refresh()
        await second.shutdown()

        await backend.setSources([locator: [Self.item(remoteUID)]])
        let third = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: LibrarySourceInventoryStore(
                directory: directory,
                accountUID: "account",
                encryptionKey: key
            )
        )
        await third.prepare()
        let thirdRecorder = LibrarySourceChangeRecorder()
        _ = await third.attach { change in await thirdRecorder.store(change) }
        await third.replacePrimaryInventory([], authority: .authoritative)
        await third.refresh()

        #expect(await thirdRecorder.latest()?.analysisScope.uids == [remoteUID])
        #expect(await backend.itemEnumerationCalls == 2)
        await third.shutdown()
    }

    private static func item(_ uid: PhotoUID) -> LibrarySourceItem {
        LibrarySourceItem(
            item: PhotoItem(
                uid: uid,
                captureTime: Date(timeIntervalSince1970: 2),
                mediaType: ""
            ),
            knownFields: [.captureTime]
        )
    }
}

private actor ControlledLibrarySourceBackend: LibrarySourceRemoteBackend, PriorityThumbnailBatchLoader {
    private var sources: [AlbumNodeIdentifier: [LibrarySourceItem]] = [:]
    private var discoveryFails = false
    private var itemEnumerationFails = false
    private(set) var discoveryCalls = 0
    private(set) var itemEnumerationCalls = 0
    private var blockedItemEnumeration: AlbumNodeIdentifier?
    private var itemEnumerationContinuation: CheckedContinuation<Void, Never>?
    private let blockThumbnailLoads: Bool
    private let blockAfterFirstThumbnail: Bool
    private let repeatFirstThumbnail: Bool
    private let thumbnailCancellation = SynchronousCompletionProbe()
    private var thumbnailContinuation: CheckedContinuation<Void, Never>?

    init(
        blockThumbnailLoads: Bool = false, blockAfterFirstThumbnail: Bool = false, repeatFirstThumbnail: Bool = false
    ) {
        self.blockThumbnailLoads = blockThumbnailLoads
        self.blockAfterFirstThumbnail = blockAfterFirstThumbnail
        self.repeatFirstThumbnail = repeatFirstThumbnail
    }

    func setSources(_ sources: [AlbumNodeIdentifier: [LibrarySourceItem]]) {
        self.sources = sources
    }

    func setDiscoveryFailure(_ fails: Bool) {
        discoveryFails = fails
    }

    func setItemEnumerationFailure(_ fails: Bool) {
        itemEnumerationFails = fails
    }

    func blockNextItemEnumeration(for locator: AlbumNodeIdentifier) {
        blockedItemEnumeration = locator
    }

    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        discoveryCalls += 1
        if discoveryFails { throw ControlledLibrarySourceBackendError.discoveryFailed }
        return sources.keys.sorted {
            if $0.volumeID != $1.volumeID { return $0.volumeID < $1.volumeID }
            return $0.nodeID < $1.nodeID
        }
    }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        itemEnumerationCalls += 1
        if blockedItemEnumeration == album {
            blockedItemEnumeration = nil
            await withCheckedContinuation { continuation in
                itemEnumerationContinuation = continuation
            }
        }
        if itemEnumerationFails { throw ControlledLibrarySourceBackendError.itemEnumerationFailed }
        return sources[album] ?? []
    }

    func isItemEnumerationWaiting() -> Bool {
        itemEnumerationContinuation != nil
    }

    func releaseItemEnumeration() {
        itemEnumerationContinuation?.resume()
        itemEnumerationContinuation = nil
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        if blockThumbnailLoads {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    thumbnailContinuation = continuation
                }
            } onCancel: { [thumbnailCancellation] in
                thumbnailCancellation.markCompleted()
            }
        }
        for (index, uid) in uids.enumerated() {
            onLoaded(uid, Data("thumbnail".utf8))
            if blockAfterFirstThumbnail, index == 0 {
                await withCheckedContinuation { thumbnailContinuation = $0 }
            }
            if repeatFirstThumbnail, index == 0 {
                for _ in 0..<64 { onLoaded(uid, Data("duplicate".utf8)) }
                onLoaded(PhotoUID(volumeID: "unrequested", nodeID: "unrequested"), Data("unrequested".utf8))
            }
        }
        if repeatFirstThumbnail, let firstUID = uids.first {
            return ThumbnailBatchLoadResult(itemErrors: [firstUID: "late duplicate failure"])
        }
        return .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        await loadThumbnails(for: uids, onLoaded: onLoaded)
    }

    func isThumbnailLoadWaiting() -> Bool {
        thumbnailContinuation != nil
    }

    func wasThumbnailLoadCancelled() -> Bool {
        thumbnailCancellation.isCompleted
    }

    func releaseThumbnailLoad() {
        thumbnailContinuation?.resume()
        thumbnailContinuation = nil
    }
}

private actor CancelledTaskAdmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LibrarySourceChangeRecorder {
    private var changes: [LibrarySourceChange] = []

    func store(_ change: LibrarySourceChange) {
        changes.append(change)
    }

    func latest() -> LibrarySourceChange? {
        changes.last
    }

    func count() -> Int {
        changes.count
    }
}

private actor BlockingLibrarySourceChangeSink {
    private var shouldBlockNextChange = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func blockNextChange() {
        shouldBlockNextChange = true
    }

    func receive(_ change: LibrarySourceChange) async {
        _ = change
        guard shouldBlockNextChange else { return }
        shouldBlockNextChange = false
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ControlledLibrarySourceBackendError: Error {
    case discoveryFailed
    case itemEnumerationFailed
}

private final class ThumbnailDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoUID: Data] = [:]

    func store(_ data: Data, for uid: PhotoUID) {
        lock.withLock { values[uid] = data }
    }

    func data(for uid: PhotoUID) -> Data? {
        lock.withLock { values[uid] }
    }
}

private final class SynchronousCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool { lock.withLock { completed } }

    func markCompleted() {
        lock.withLock { completed = true }
    }
}

/// How a refresh enumerates the items of the additional library sources: at most four at once, every source ends
/// with an answer or with none, and a source without an answer makes the refresh retryable without hiding the others.
@Suite(.serialized)
struct LibrarySourceEnumerationTests {
    @Test func sourcesAreEnumeratedFourAtATimeAndAllArePublished() async throws {
        let locators = (0..<6).map { AlbumNodeIdentifier(volumeID: "remote", nodeID: "album-\($0)") }
        let remote = EnumerationRemote(locators: locators, delay: .milliseconds(40))
        let coordinator = LibrarySourceCoordinator(remote: remote, thumbnailLoader: NoThumbnails(), inventoryStore: nil)
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }

        #expect(await coordinator.refresh() == .complete)

        #expect(await remote.peak == 4, "four sources run at once, never more")
        #expect(await remote.calls == 6)
        let latest = try #require(await recorder.latest())
        for locator in locators {
            #expect(latest.analysisScope.uids.contains(EnumerationRemote.uid(of: locator)), "\(locator.nodeID)")
        }
        await coordinator.shutdown()
    }

    @Test(arguments: [0, 3, 5])
    func eachSourceReceivesTheAnswerOfItsOwnRead(revoked: Int) async throws {
        let locators = (0..<6).map { AlbumNodeIdentifier(volumeID: "remote", nodeID: "album-\($0)") }
        // The first sources are the slowest, so the reads end in another order than the sources start.
        let remote = EnumerationRemote(locators: locators, delay: .milliseconds(10), skew: true)
        let coordinator = LibrarySourceCoordinator(remote: remote, thumbnailLoader: NoThumbnails(), inventoryStore: nil)
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        #expect(await coordinator.refresh() == .complete)
        let all = Set(locators.map(EnumerationRemote.uid(of:)))
        #expect(try #require(await recorder.latest()).analysisScope.uids == all)

        // Revoking one source removes exactly the item that this source's own read returned.
        await coordinator.revokeAdditionalSource(for: locators[revoked])

        let remaining = try #require(await recorder.latest()).analysisScope.uids
        #expect(remaining == all.subtracting([EnumerationRemote.uid(of: locators[revoked])]))
        await coordinator.shutdown()
    }

    @Test func aSourceWithoutAnAnswerMakesTheRefreshRetryableAndHidesNoOtherSource() async throws {
        let locators = (0..<6).map { AlbumNodeIdentifier(volumeID: "remote", nodeID: "album-\($0)") }
        let failing = locators[2]
        let remote = EnumerationRemote(locators: locators, delay: .milliseconds(5), failing: [failing])
        let coordinator = LibrarySourceCoordinator(remote: remote, thumbnailLoader: NoThumbnails(), inventoryStore: nil)
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }

        #expect(await coordinator.refresh() == .retryableFailure)

        let latest = try #require(await recorder.latest())
        for locator in locators where locator != failing {
            #expect(latest.analysisScope.uids.contains(EnumerationRemote.uid(of: locator)), "\(locator.nodeID)")
        }
        #expect(!latest.analysisScope.uids.contains(EnumerationRemote.uid(of: failing)))
        await coordinator.shutdown()
    }
}

private actor EnumerationRemote: LibrarySourceRemoteBackend {
    private let locators: [AlbumNodeIdentifier]
    private let delay: Duration
    private let failing: Set<AlbumNodeIdentifier>
    private var inFlight = 0
    private(set) var peak = 0
    private(set) var calls = 0

    private let skew: Bool

    init(
        locators: [AlbumNodeIdentifier], delay: Duration, failing: Set<AlbumNodeIdentifier> = [], skew: Bool = false
    ) {
        self.locators = locators
        self.delay = delay
        self.failing = failing
        self.skew = skew
    }

    static func uid(of locator: AlbumNodeIdentifier) -> PhotoUID {
        PhotoUID(volumeID: locator.volumeID, nodeID: "photo-of-\(locator.nodeID)")
    }

    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] { locators }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        calls += 1
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        // With `skew` the first sources are the slowest, so the reads end in the reverse order.
        let position = locators.firstIndex(of: album) ?? 0
        let wait = skew ? delay * (locators.count - position) : delay
        try await Task.sleep(for: wait)
        if failing.contains(album) { throw URLError(.timedOut) }
        return [
            LibrarySourceItem(
                item: PhotoItem(
                    uid: Self.uid(of: album), captureTime: Date(timeIntervalSince1970: 2), mediaType: ""),
                knownFields: [.captureTime])
        ]
    }
}

private struct NoThumbnails: PriorityThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }

    func loadThumbnails(
        for uids: [PhotoUID], priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
