import Foundation
import PhotosCore
import XCTest

@testable import AlbumCore
@testable import AlbumsFeature

final class AlbumFailurePresentationTests: XCTestCase {
    @MainActor
    func testOwnedReadUsesTheReadSpecificReason() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.listError = NSError(domain: "PrivateAlbumNode", code: 17)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        await coordinator.refresh()

        XCTAssertEqual(coordinator.loadErrorMessage, L10n.string("albums.load_failed_message"))
        XCTAssertEqual(backend.listAlbumRequests, 1)
        XCTAssertEqual(coordinator.loadFailure?.canRetry, true)
    }

    @MainActor
    func testSharedReadUsesTheReadSpecificReason() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedListError = URLError(.timedOut)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        await coordinator.refreshSharedAlbums()

        XCTAssertEqual(coordinator.sharedLoadErrorMessage, L10n.string("albums.load_failed_message"))
        XCTAssertEqual(backend.listSharedAlbumRequests, 1)
        XCTAssertEqual(coordinator.sharedLoadFailure?.canRetry, true)
    }

    @MainActor
    func testCancelledReadsKeepCachedListsWithoutAnError() async {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let backend = FakeAlbumBackend(
                capabilities: .sdkCatalogWithHTTPWrites,
                albums: [AlbumSummary(id: "existing", title: "Trip", photoCount: 2, coverPhotoID: nil)]
            )
            backend.sharedAlbums = [sharedAlbum()]
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            await coordinator.refresh()
            await coordinator.refreshSharedAlbums()
            backend.listError = error
            backend.sharedListError = error

            await coordinator.refresh()
            await coordinator.refreshSharedAlbums()

            XCTAssertEqual(coordinator.albums.map(\.id), ["existing"])
            XCTAssertEqual(coordinator.sharedAlbums.map(\.node.nodeID), ["shared"])
            XCTAssertNil(coordinator.loadFailure)
            XCTAssertNil(coordinator.sharedLoadFailure)
            XCTAssertNil(coordinator.loadErrorMessage)
            XCTAssertNil(coordinator.sharedLoadErrorMessage)
            XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
            XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)
            XCTAssertEqual(backend.listAlbumRequests, 2)
            XCTAssertEqual(backend.listSharedAlbumRequests, 2)
        }
    }

    @MainActor
    func testManualReadAfterTransientFailureCanRecoverWithoutReplayingWrites() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.listError = URLError(.notConnectedToInternet)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        XCTAssertEqual(backend.listAlbumRequests, 1)
        XCTAssertEqual(coordinator.loadErrorMessage, L10n.string("albums.load_failed_message"))

        backend.listError = nil
        backend.albums = [AlbumSummary(id: "recovered", title: "Trip", photoCount: 2, coverPhotoID: nil)]
        await coordinator.refresh()

        XCTAssertEqual(coordinator.albums.map(\.id), ["recovered"])
        XCTAssertNil(coordinator.loadErrorMessage)
        XCTAssertEqual(backend.listAlbumRequests, 2)
        XCTAssertTrue(backend.created.isEmpty)
        XCTAssertTrue(backend.added.isEmpty)
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    @MainActor
    func testFixedReadFailuresKeepTheirSpecificReasonWithoutRetry() async {
        let errors: [AlbumError] = [
            .unsupported(operation: "Private operation", gap: "Private backend detail"),
            .sharedAlbumReadOnly(.roleDoesNotPermitEditing),
            .sharedAlbumReadOnly(.transportUnsupported),
        ]
        for error in errors {
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            backend.listError = error
            backend.sharedListError = error
            let coordinator = AlbumActionCoordinator(repository: repository(backend))

            await coordinator.refresh()
            await coordinator.refreshSharedAlbums()

            XCTAssertEqual(coordinator.loadErrorMessage, error.errorDescription)
            XCTAssertEqual(coordinator.sharedLoadErrorMessage, error.errorDescription)
            XCTAssertEqual(coordinator.loadFailure?.canRetry, false)
            XCTAssertEqual(coordinator.sharedLoadFailure?.canRetry, false)
            XCTAssertEqual(backend.listAlbumRequests, 1)
            XCTAssertEqual(backend.listSharedAlbumRequests, 1)
        }
    }

    @MainActor
    func testSuccessfulCreateWithFailedReloadKeepsTheSuccessAndCachedAlbums() async {
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: "existing", title: "Trip", photoCount: 2, coverPhotoID: nil)]
        )
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        backend.listError = URLError(.timedOut)

        let outcome = await coordinator.createAlbum(name: "New album")

        XCTAssertEqual(outcome, .completed(albumID: "album-0"))
        XCTAssertNil(coordinator.actionFailure)
        XCTAssertEqual(backend.created, ["New album"])
        XCTAssertEqual(coordinator.albums.map(\.id), ["existing"])
        XCTAssertEqual(coordinator.loadErrorMessage, L10n.string("albums.load_failed_message"))
        XCTAssertEqual(coordinator.loadFailure?.canRetry, true)
        XCTAssertEqual(backend.listAlbumRequests, 2)
    }

    @MainActor
    func testCancelledTaskDoesNotPublishALateSuccessfulRead() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        backend.albums = [AlbumSummary(id: "late", title: "Trip", photoCount: 2, coverPhotoID: nil)]
        backend.sharedAlbums = [sharedAlbum()]
        let cancelled = readTask {
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.refresh()
            await coordinator.refreshSharedAlbums()
        }
        await finish([cancelled])

        XCTAssertTrue(coordinator.albums.isEmpty)
        XCTAssertTrue(coordinator.sharedAlbums.isEmpty)
        XCTAssertNil(coordinator.loadFailure)
        XCTAssertNil(coordinator.sharedLoadFailure)
    }

    @MainActor
    func testFirstCancelledOwnedReadRemainsUnloadedRatherThanEmpty() async {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            backend.listError = error
            let coordinator = AlbumActionCoordinator(repository: repository(backend))

            await coordinator.refresh()

            XCTAssertFalse(coordinator.hasCompletedInitialAlbumLoad)
            XCTAssertTrue(coordinator.showsAlbumLoadingPlaceholder)
            XCTAssertNil(coordinator.loadFailure)
            XCTAssertEqual(backend.listAlbumRequests, 1)
        }
    }

    @MainActor
    func testFirstCancelledSharedReadRemainsUnloadedRatherThanEmpty() async {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            backend.sharedListError = error
            let coordinator = AlbumActionCoordinator(repository: repository(backend))

            await coordinator.refreshSharedAlbums()

            XCTAssertFalse(coordinator.hasCompletedInitialSharedAlbumLoad)
            XCTAssertTrue(coordinator.showsSharedAlbumLoadingPlaceholder)
            XCTAssertNil(coordinator.sharedLoadFailure)
            XCTAssertEqual(backend.listSharedAlbumRequests, 1)
        }
    }

    @MainActor
    func testCancelledRetriesRestoreTheEarlierFailureAndRetry() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.listError = URLError(.timedOut)
        backend.sharedListError = URLError(.timedOut)
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()
        let ownedFailure = coordinator.loadFailure
        let sharedFailure = coordinator.sharedLoadFailure
        XCTAssertEqual(ownedFailure?.canRetry, true)
        XCTAssertEqual(sharedFailure?.canRetry, true)
        backend.listError = CancellationError()
        backend.sharedListError = URLError(.cancelled)

        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()

        XCTAssertEqual(coordinator.loadFailure, ownedFailure)
        XCTAssertEqual(coordinator.sharedLoadFailure, sharedFailure)
        XCTAssertTrue(coordinator.hasCompletedInitialAlbumLoad)
        XCTAssertTrue(coordinator.hasCompletedInitialSharedAlbumLoad)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertFalse(coordinator.isLoadingShared)
    }

    @MainActor
    func testAReplacementReadIsNotDroppedWhenTheFirstReadIsCancelled() async {
        for shared in [false, true] {
            let backend = FakeAlbumBackend(
                capabilities: .sdkCatalogWithHTTPWrites,
                albums: [AlbumSummary(id: "replacement", title: "Trip", photoCount: 2, coverPhotoID: nil)]
            )
            backend.sharedAlbums = [sharedAlbum()]
            let gate = CancelledAlbumReadGate()
            backend.listHold = { await gate.hold() }
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            let first = readTask {
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [gate.heldExpectation], timeout: 5)
            first.cancel()
            let entered = expectation(description: "replacement caller started")
            let replacement = readTask {
                entered.fulfill()
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            let secondEntered = expectation(description: "another replacement caller started")
            let secondReplacement = readTask {
                secondEntered.fulfill()
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [entered, secondEntered], timeout: 5)
            await gate.open()
            await finish([first, replacement, secondReplacement])

            if shared {
                XCTAssertEqual(backend.listSharedAlbumRequests, 2)
                XCTAssertEqual(coordinator.sharedAlbums.map(\.node.nodeID), ["shared"])
                XCTAssertTrue(coordinator.hasCompletedInitialSharedAlbumLoad)
                XCTAssertNil(coordinator.sharedLoadFailure)
                XCTAssertFalse(coordinator.showsSharedAlbumLoadingPlaceholder)
            } else {
                XCTAssertEqual(backend.listAlbumRequests, 2)
                XCTAssertEqual(coordinator.albums.map(\.id), ["replacement"])
                XCTAssertTrue(coordinator.hasCompletedInitialAlbumLoad)
                XCTAssertNil(coordinator.loadFailure)
                XCTAssertFalse(coordinator.showsAlbumLoadingPlaceholder)
            }
        }
    }

    @MainActor
    func testACancelledReplacementDoesNotStartAnotherRead() async {
        for shared in [false, true] {
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            let gate = CancelledAlbumReadGate()
            backend.listHold = { await gate.hold() }
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            let first = readTask {
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [gate.heldExpectation], timeout: 5)
            first.cancel()
            let entered = expectation(description: "replacement caller started before cancellation")
            let replacement = readTask {
                entered.fulfill()
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [entered], timeout: 5)
            replacement.cancel()
            await gate.open()
            await finish([first, replacement])

            if shared {
                XCTAssertEqual(backend.listSharedAlbumRequests, 1)
                XCTAssertFalse(coordinator.hasCompletedInitialSharedAlbumLoad)
                XCTAssertTrue(coordinator.showsSharedAlbumLoadingPlaceholder)
                XCTAssertNil(coordinator.sharedLoadFailure)
            } else {
                XCTAssertEqual(backend.listAlbumRequests, 1)
                XCTAssertFalse(coordinator.hasCompletedInitialAlbumLoad)
                XCTAssertTrue(coordinator.showsAlbumLoadingPlaceholder)
                XCTAssertNil(coordinator.loadFailure)
            }
        }
    }

    @MainActor
    func testACancelledReplacementReadCannotStartAThirdRead() async {
        for shared in [false, true] {
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            let firstGate = CancelledAlbumReadGate()
            let replacementGate = CancelledAlbumReadGate()
            let secondRead = expectation(description: "the replacement read started")
            backend.listHold = {
                let count = shared ? backend.listSharedAlbumRequests : backend.listAlbumRequests
                if count == 1 {
                    await firstGate.hold()
                } else {
                    if count == 2 { secondRead.fulfill() }
                    await replacementGate.hold()
                }
            }
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            let first = readTask {
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [firstGate.heldExpectation], timeout: 5)
            first.cancel()
            let entered = expectation(description: "replacement caller joined first read")
            let replacement = readTask {
                entered.fulfill()
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [entered], timeout: 5)
            await firstGate.open()
            await fulfillment(of: [secondRead], timeout: 5)
            guard (shared ? backend.listSharedAlbumRequests : backend.listAlbumRequests) == 2 else {
                XCTFail("The replacement must start exactly one read")
                await replacementGate.open()
                await finish([first, replacement])
                continue
            }
            replacement.cancel()
            let nextEntered = expectation(description: "next caller joined replacement read")
            let next = readTask {
                nextEntered.fulfill()
                if shared { await coordinator.refreshSharedAlbums() } else { await coordinator.refresh() }
            }
            await fulfillment(of: [nextEntered], timeout: 5)
            await replacementGate.open()
            await finish([first, replacement, next])

            if shared {
                XCTAssertEqual(backend.listSharedAlbumRequests, 2)
                XCTAssertFalse(coordinator.hasCompletedInitialSharedAlbumLoad)
                XCTAssertTrue(coordinator.showsSharedAlbumLoadingPlaceholder)
            } else {
                XCTAssertEqual(backend.listAlbumRequests, 2)
                XCTAssertFalse(coordinator.hasCompletedInitialAlbumLoad)
                XCTAssertTrue(coordinator.showsAlbumLoadingPlaceholder)
            }
        }
    }

    @MainActor
    private func readTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> AlbumReadTestTask {
        let finished = expectation(description: "album read caller completed")
        let task = Task { @MainActor in
            await operation()
            finished.fulfill()
        }
        return AlbumReadTestTask(task: task, finished: finished)
    }

    @MainActor
    private func finish(_ tasks: [AlbumReadTestTask]) async {
        await fulfillment(of: tasks.map(\.finished), timeout: 5)
        for task in tasks { task.cancel() }
    }

    private func sharedAlbum() -> SharedAlbumSummary {
        SharedAlbumSummary(
            node: AlbumNodeIdentifier(volumeID: "shared-volume", nodeID: "shared"),
            title: "Shared trip", photoCount: 2, coverPhotoID: nil, owner: nil,
            lastActivityTime: nil, isSharedByURL: false, isMetadataDegraded: false
        )
    }
}

private actor CancelledAlbumReadGate {
    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?
    nonisolated let heldExpectation = XCTestExpectation(description: "album read reached gate")

    func hold() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            held = continuation
            heldExpectation.fulfill()
        }
    }

    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }
}

private struct AlbumReadTestTask {
    let task: Task<Void, Never>
    let finished: XCTestExpectation

    func cancel() { task.cancel() }
}
