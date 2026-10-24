import PhotosCore
import XCTest

@testable import AlbumCore
@testable import AlbumsFeature

private func coordinatorUID(_ nodeID: String) -> PhotoUID {
    PhotoUID(volumeID: "volume", nodeID: nodeID)
}

/// Holds every catalog listing until the test opens it, and tells the test how many listings wait.
private actor ListGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            let ready = heldWaiters.filter { $0.count <= waiting.count }
            heldWaiters.removeAll { $0.count <= waiting.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitUntilHeld(_ count: Int) async {
        guard waiting.count < count else { return }
        await withCheckedContinuation { heldWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

final class AlbumActionCoordinatorTests: XCTestCase {
    private func sharedAlbum(_ nodeID: String) -> SharedAlbumSummary {
        SharedAlbumSummary(
            node: AlbumNodeIdentifier(volumeID: "shared-volume", nodeID: nodeID),
            title: "Shared \(nodeID)",
            photoCount: 4,
            coverPhotoID: nil,
            owner: "Owner",
            lastActivityTime: nil,
            isSharedByURL: false,
            isMetadataDegraded: false
        )
    }

    @MainActor
    func testAlbumLoadingPlaceholdersDisappearPermanentlyAfterInitialRefresh() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        XCTAssertTrue(coordinator.showsAlbumLoadingPlaceholder)
        XCTAssertTrue(coordinator.showsSharedAlbumLoadingPlaceholder)

        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()

        XCTAssertTrue(coordinator.hasCompletedInitialAlbumLoad)
        XCTAssertTrue(coordinator.hasCompletedInitialSharedAlbumLoad)
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)

        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()

        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)
    }

    /// A retry after a failed load shows the loading row while it runs, not "No albums yet", and a second failure
    /// shows the error again.
    @MainActor
    func testRetryAfterAFailedLoadShowsLoadingUntilTheResultArrives() async {
        struct Offline: Error {}
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.listError = Offline()
        backend.sharedListError = Offline()
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()
        XCTAssertNotNil(coordinator.loadErrorMessage)
        XCTAssertNotNil(coordinator.sharedLoadErrorMessage)
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)

        let gate = ListGate()
        backend.listHold = { await gate.pass() }
        let retry = Task { await coordinator.refresh() }
        let sharedRetry = Task { await coordinator.refreshSharedAlbums() }
        await gate.waitUntilHeld(2)
        XCTAssertNil(coordinator.loadErrorMessage)
        XCTAssertNil(coordinator.sharedLoadErrorMessage)
        XCTAssertTrue(coordinator.showsAlbumLoadingPlaceholder, "a running retry shows the loading row")
        XCTAssertTrue(coordinator.showsSharedAlbumLoadingPlaceholder, "a running retry shows the loading row")

        await gate.open()
        await retry.value
        await sharedRetry.value
        XCTAssertNotNil(coordinator.loadErrorMessage, "a second failure shows the error again")
        XCTAssertNotNil(coordinator.sharedLoadErrorMessage, "a second failure shows the error again")
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)
    }

    /// A retry after a failure that finds no albums ends on the empty list, without the loading row or the error.
    @MainActor
    func testRetryThatFindsNoAlbumsShowsTheEmptyList() async {
        struct Offline: Error {}
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.listError = Offline()
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        XCTAssertNotNil(coordinator.loadErrorMessage)

        backend.listError = nil
        await coordinator.refresh()
        XCTAssertTrue(coordinator.albums.isEmpty)
        XCTAssertNil(coordinator.loadErrorMessage)
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder, "an empty result shows the empty list")
    }

    /// A retry after a failure that finds albums shows them, without the loading row or the error.
    @MainActor
    func testRetryThatFindsAlbumsShowsThem() async {
        struct Offline: Error {}
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.listError = Offline()
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        XCTAssertNotNil(coordinator.loadErrorMessage)

        backend.listError = nil
        backend.albums = [AlbumSummary(id: "album", title: "Holidays", photoCount: 3, coverPhotoID: nil)]
        await coordinator.refresh()
        XCTAssertEqual(coordinator.albums.map(\.title), ["Holidays"])
        XCTAssertNil(coordinator.loadErrorMessage)
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
    }

    /// A reload of an empty list that loaded fine keeps the empty list on screen; only a retry after a failure shows
    /// the loading row.
    @MainActor
    func testReloadOfAnEmptyListThatLoadedFineKeepsTheEmptyList() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()
        XCTAssertTrue(coordinator.albums.isEmpty)
        XCTAssertTrue(coordinator.sharedAlbums.isEmpty)

        let gate = ListGate()
        backend.listHold = { await gate.pass() }
        let reload = Task { await coordinator.refresh() }
        let sharedReload = Task { await coordinator.refreshSharedAlbums() }
        await gate.waitUntilHeld(2)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertTrue(coordinator.isLoadingShared)
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder, "an ordinary reload keeps the empty list")
        XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder, "an ordinary reload keeps the empty list")

        await gate.open()
        await reload.value
        await sharedReload.value
        XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
        XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)
    }

    @MainActor
    func testCreateAndAddRefreshesSharedAlbumState() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let outcome = await coordinator.createAlbum(
            name: "  Summer  ",
            adding: [coordinatorUID("one"), coordinatorUID("two")]
        )

        XCTAssertEqual(outcome, .completed(albumID: "album-0"))
        XCTAssertEqual(coordinator.albums.map(\.title), ["Summer"])
        XCTAssertEqual(backend.added.first?.uids.count, 2)
        XCTAssertNil(coordinator.actionFailure)
        XCTAssertFalse(coordinator.isWorking)
    }

    @MainActor
    func testCreatedAlbumMembershipFailureKeepsAlbumAndReportsRetryOutcome() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.addError = AlbumError.partialAdd(succeeded: 1, total: 2, message: "retry later")
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let outcome = await coordinator.createAlbum(
            name: "Summer",
            adding: [coordinatorUID("one"), coordinatorUID("two")]
        )

        XCTAssertEqual(outcome, .albumCreatedNeedsMembershipRetry(albumID: "album-0"))
        XCTAssertEqual(coordinator.albums.map(\.id), ["album-0"])
        XCTAssertNotNil(coordinator.actionFailure)
        XCTAssertTrue(coordinator.actionFailure?.message.contains("Summer") == true)
        XCTAssertFalse(coordinator.actionFailure?.message.contains("retry later") == true)
    }

    @MainActor
    func testExistingAlbumAddFailurePreservesSelectionForRetry() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.addError = NSError(
            domain: "ProtonAlbumAPI",
            code: 2_000,
            userInfo: [NSLocalizedDescriptionKey: "service unavailable"]
        )
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let succeeded = await coordinator.add([coordinatorUID("one")], to: "album-existing")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(coordinator.actionFailure?.message, L10n.string("error.album_backend"))
        XCTAssertFalse(coordinator.actionFailure?.message.contains("service unavailable") == true)
        XCTAssertFalse(coordinator.isWorking)
    }

    @MainActor
    func testSharedCatalogRefreshAndLeaveUpdateOneSharedStateMachine() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedAlbums = [sharedAlbum("one"), sharedAlbum("two")]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        await coordinator.refreshSharedAlbums()
        XCTAssertEqual(coordinator.sharedAlbums.map(\.node.nodeID), ["one", "two"])

        let left = await coordinator.leaveSharedAlbum(coordinator.sharedAlbums[0])

        XCTAssertTrue(left)
        XCTAssertEqual(backend.leftSharedAlbums.map(\.nodeID), ["one"])
        XCTAssertEqual(coordinator.sharedAlbums.map(\.node.nodeID), ["two"])
    }

    @MainActor
    func testMembershipHintsAvoidRedundantAddAndOnlySubmitMissingPhotos() async {
        let first = coordinatorUID("one")
        let second = coordinatorUID("two")
        let albumID = "album-existing"
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: albumID, title: "Existing", photoCount: 1, coverPhotoID: nil)]
        )
        backend.memberships[first] = [AlbumNodeIdentifier(volumeID: "volume", nodeID: albumID)]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        await coordinator.loadMemberships(for: [first, second])
        XCTAssertEqual(coordinator.membershipState(for: albumID), .some)
        XCTAssertEqual(coordinator.membershipState(for: "another-album"), AlbumMembershipState.none)

        let added = await coordinator.add([first, second], to: albumID)

        XCTAssertTrue(added)
        XCTAssertEqual(backend.added.count, 1)
        XCTAssertEqual(Set(backend.added[0].uids), Set([second]))
        XCTAssertEqual(coordinator.membershipState(for: albumID), .all)

        let redundantAdd = await coordinator.add([first, second], to: albumID)
        XCTAssertTrue(redundantAdd)
        XCTAssertEqual(backend.added.count, 1)
    }

    @MainActor
    func testLargeSelectionDoesNotSchedulePerPhotoMembershipReads() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        let selection = (0...AlbumActionCoordinator.membershipSelectionLimit)
            .map { coordinatorUID("\($0)") }

        await coordinator.loadMemberships(for: selection)

        XCTAssertTrue(backend.membershipRequests.isEmpty)
        XCTAssertNil(coordinator.membershipState(for: "album"))
    }
}
