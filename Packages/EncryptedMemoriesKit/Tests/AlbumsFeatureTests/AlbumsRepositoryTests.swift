import PhotosCore
import XCTest

@testable import AlbumCore

/// A configurable in-memory backend so the repository's validation + capability gating can be tested
/// without any SDK/HTTP.
final class FakeAlbumBackend: AlbumCatalogBackend, AlbumWriteBackend, @unchecked Sendable {
    var capabilities: AlbumCapabilities
    private(set) var created: [String] = []
    private(set) var deleted: [AlbumID] = []
    private(set) var added: [(uids: [PhotoUID], album: AlbumID)] = []
    private(set) var removed: [(uids: [PhotoUID], album: AlbumID)] = []
    private(set) var covers: [(album: AlbumID, photo: PhotoUID)] = []
    private(set) var leftSharedAlbums: [AlbumNodeIdentifier] = []
    private(set) var membershipRequests: [[PhotoUID]] = []
    private(set) var listAlbumRequests = 0
    private(set) var listSharedAlbumRequests = 0
    var albums: [AlbumSummary]
    var sharedAlbums: [SharedAlbumSummary] = []
    var memberships: [PhotoUID: Set<AlbumNodeIdentifier>] = [:]
    var addError: (any Error)?
    var listError: (any Error)?
    var sharedListError: (any Error)?
    /// Runs inside every catalog listing before it returns, so a test can hold a load while it checks the state.
    var listHold: (@Sendable () async -> Void)?

    init(capabilities: AlbumCapabilities, albums: [AlbumSummary] = []) {
        self.capabilities = capabilities
        self.albums = albums
    }

    func listAlbums() async throws -> [AlbumSummary] {
        listAlbumRequests += 1
        await listHold?()
        if let listError { throw listError }
        return albums
    }
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] {
        listSharedAlbumRequests += 1
        await listHold?()
        if let sharedListError { throw sharedListError }
        return sharedAlbums
    }
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {
        leftSharedAlbums.append(album)
        sharedAlbums.removeAll { $0.node == album }
    }
    func albumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        membershipRequests.append(photoUIDs)
        return Dictionary(uniqueKeysWithValues: photoUIDs.map { ($0, memberships[$0] ?? []) })
    }

    func createAlbum(name: String) async throws -> AlbumID {
        let id = "album-\(created.count)"
        created.append(name)
        albums.append(AlbumSummary(id: id, title: name, photoCount: 0, coverPhotoID: nil))
        return id
    }

    func deleteAlbum(albumID: AlbumID) async throws {
        deleted.append(albumID)
    }

    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        if let addError { throw addError }
        added.append((photoUIDs, albumID))
    }

    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
        removed.append((photoUIDs, albumID))
    }

    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        covers.append((albumID, photoUID))
    }
}

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "vol", nodeID: n) }
func repository(_ backend: FakeAlbumBackend) -> AlbumsRepository {
    AlbumsRepository(
        catalogBackend: backend,
        writeBackend: backend,
        capabilities: backend.capabilities
    )
}

final class AlbumsRepositoryTests: XCTestCase {
    func testHTTPBackendCapabilityPresetIncludesEveryWiredAlbumOperation() {
        let capabilities = AlbumCapabilities.sdkCatalogWithHTTPWrites
        XCTAssertTrue(capabilities.canList)
        XCTAssertTrue(capabilities.canCreate)
        XCTAssertTrue(capabilities.canDelete)
        XCTAssertTrue(capabilities.canAddPhotos)
        XCTAssertTrue(capabilities.canRemovePhotos)
        XCTAssertTrue(capabilities.canSetCover)
    }

    func testListPassesThroughWhenSupported() async throws {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: false, canAddPhotos: false, canSetCover: false),
            albums: [AlbumSummary(id: "a", title: "Trip", photoCount: 3, coverPhotoID: nil)])
        let repo = repository(backend)
        let albums = try await repo.listAlbums()
        XCTAssertEqual(albums.map(\.id), ["a"])
    }

    func testSuccessfulSharedLeavePublishesConfirmedAccessLoss() async throws {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        let recorder = SharedLeaveRecorder()
        let repo = AlbumsRepository(
            catalogBackend: backend,
            writeBackend: backend,
            capabilities: backend.capabilities,
            didLeaveSharedAlbum: { album in await recorder.record(album) }
        )
        let album = AlbumNodeIdentifier(volumeID: "shared-volume", nodeID: "shared-album")

        try await repo.leaveSharedAlbum(album)

        XCTAssertEqual(backend.leftSharedAlbums, [album])
        let recorded = await recorder.values
        XCTAssertEqual(recorded, [album])
    }

    func testAlbumMembershipTitlesMatchLosslessVolumeAndSortForViewer() async throws {
        let photo = uid("photo")
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [
                AlbumSummary(id: "summer", volumeID: "vol", title: "Summer", photoCount: 1, coverPhotoID: nil),
                AlbumSummary(id: "family", volumeID: "vol", title: "Family", photoCount: 1, coverPhotoID: nil),
                AlbumSummary(
                    id: "foreign", volumeID: "another", title: "Wrong volume", photoCount: 1, coverPhotoID: nil),
            ]
        )
        backend.memberships[photo] = [
            AlbumNodeIdentifier(volumeID: "vol", nodeID: "summer"),
            AlbumNodeIdentifier(volumeID: "vol", nodeID: "family"),
            AlbumNodeIdentifier(volumeID: "vol", nodeID: "foreign"),
        ]

        let repo = repository(backend)
        let titles = try await repo.albumMembershipTitles(for: photo)
        let cachedTitles = try await repo.albumMembershipTitles(for: photo)

        XCTAssertEqual(titles, ["Family", "Summer"])
        XCTAssertEqual(cachedTitles, titles)
        XCTAssertEqual(backend.listAlbumRequests, 1)
        XCTAssertEqual(backend.membershipRequests.count, 1)
    }

    func testViewerResolvesSharedAlbumTitleWithoutCrossVolumeCollision() async throws {
        let photo = PhotoUID(volumeID: "foreign", nodeID: "photo")
        let sharedNode = AlbumNodeIdentifier(volumeID: "foreign", nodeID: "album")
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: "album", volumeID: "vol", title: "Wrong album", photoCount: 1, coverPhotoID: nil)]
        )
        backend.sharedAlbums = [
            SharedAlbumSummary(
                node: sharedNode, title: "Shared family", photoCount: 1, coverPhotoID: nil,
                owner: nil, lastActivityTime: nil, isSharedByURL: false, isMetadataDegraded: false)
        ]
        backend.memberships[photo] = [sharedNode]
        let repo = repository(backend)

        let titles = try await repo.albumMembershipTitles(for: photo)
        let cached = try await repo.albumMembershipTitles(for: photo)

        XCTAssertEqual(titles, ["Shared family"])
        XCTAssertEqual(cached, titles)
        XCTAssertEqual(backend.listSharedAlbumRequests, 1)
        XCTAssertEqual(backend.membershipRequests.count, 1)
    }

    func testCreateThrowsUnsupportedWhenBackendCannot() async {
        let backend = FakeAlbumBackend(capabilities: .readOnly)
        let repo = repository(backend)
        do {
            _ = try await repo.createAlbum(name: "New")
            XCTFail("expected unsupported")
        } catch let AlbumError.unsupported(operation, _) {
            XCTAssertEqual(operation, "Create album")
        } catch { XCTFail("wrong error: \(error)") }
        XCTAssertTrue(backend.created.isEmpty, "must not have created anything")
    }

    func testCreateRejectsEmptyName() async {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true))
        let repo = repository(backend)
        do {
            _ = try await repo.createAlbum(name: "   ")
            XCTFail("expected error")
        } catch let AlbumError.backend(message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testCreateSucceedsAndForwardsTrimmedName() async throws {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true))
        let repo = repository(backend)
        let id = try await repo.createAlbum(name: "  Holiday  ")
        XCTAssertEqual(id, "album-0")
        XCTAssertEqual(backend.created, ["Holiday"])
    }

    func testCreateAndAddPreflightsBothCapabilitiesBeforeCreating() async {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: false, canSetCover: false)
        )
        let repo = repository(backend)

        do {
            _ = try await repo.createAlbum(name: "Trip", adding: [uid("1")])
            XCTFail("expected unsupported")
        } catch let AlbumError.unsupported(operation, _) {
            XCTAssertEqual(operation, "Add to album")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(backend.created.isEmpty, "unsupported membership must not leave an empty album")
    }

    func testCreateAndAddAttachesExistingPhotosAfterCreation() async throws {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: false)
        )
        let repo = repository(backend)
        let photos = [uid("1"), uid("2")]

        let albumID = try await repo.createAlbum(name: "  Trip  ", adding: photos)

        XCTAssertEqual(backend.created, ["Trip"])
        XCTAssertEqual(backend.added.first?.album, albumID)
        XCTAssertEqual(backend.added.first?.uids, photos)
    }

    func testPendingPhotosGoToTheBackupAndNeverToProton() async throws {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: false)
        )
        let repo = repository(backend)
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset")
        let recorded = RecordedPendingAlbumAdds()
        await repo.setPendingAlbumAdds { uids, albumID in
            await recorded.append(uids, albumID)
            return true
        }

        try await repo.addPhotos([uid("1"), local], to: "album-9")

        XCTAssertEqual(backend.added.map(\.uids), [[uid("1")]])
        let adds = await recorded.adds
        XCTAssertEqual(adds.map(\.uids), [[local]])
        XCTAssertEqual(adds.map(\.album), ["album-9"])
    }

    func testPendingPhotosFailWithoutABackupRecorder() async {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: false)
        )
        let repo = repository(backend)
        do {
            try await repo.addPhotos([PhotoUID(localPending: .photoLibrary, identifier: "asset")], to: "album-9")
            XCTFail("a local photo needs the backup")
        } catch {
            XCTAssertTrue(backend.added.isEmpty)
        }
    }

    func testCreateAndAddReportsCreatedAlbumWhenMembershipFails() async {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: false)
        )
        backend.addError = AlbumError.backend("membership unavailable")
        let repo = repository(backend)

        do {
            _ = try await repo.createAlbum(name: "Trip", adding: [uid("1")])
            XCTFail("expected partial creation")
        } catch let AlbumError.albumCreatedButPhotosNotAdded(albumID, albumName, message) {
            XCTAssertEqual(albumID, "album-0")
            XCTAssertEqual(albumName, "Trip")
            XCTAssertTrue(message.contains("membership unavailable"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(backend.created, ["Trip"], "the UI must know the album already exists")
    }

    func testAddPhotosUnsupportedDoesNotCallBackend() async {
        let backend = FakeAlbumBackend(capabilities: .readOnly)
        let repo = repository(backend)
        do {
            try await repo.addPhotos([uid("1")], to: "a")
            XCTFail("expected unsupported")
        } catch let AlbumError.unsupported(operation, _) { XCTAssertEqual(operation, "Add to album") } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(backend.added.isEmpty)
    }

    func testDeleteAlbumRequiresCapabilityAndForwardsID() async throws {
        let unsupported = FakeAlbumBackend(capabilities: .readOnly)
        let unsupportedRepo = repository(unsupported)
        do {
            try await unsupportedRepo.deleteAlbum(albumID: "a")
            XCTFail("expected unsupported")
        } catch let AlbumError.unsupported(operation, _) {
            XCTAssertEqual(operation, "Delete album")
        }
        XCTAssertTrue(unsupported.deleted.isEmpty)

        let supported = FakeAlbumBackend(
            capabilities: .init(
                canList: true, canCreate: false, canDelete: true, canAddPhotos: false, canSetCover: false)
        )
        try await repository(supported).deleteAlbum(albumID: "album-9")
        XCTAssertEqual(supported.deleted, ["album-9"])
    }

    func testRemovePhotosRequiresCapabilityAndForwardsMembershipOnly() async throws {
        let unsupported = FakeAlbumBackend(capabilities: .readOnly)
        do {
            try await repository(unsupported).removePhotos([uid("1")], from: "album")
            XCTFail("expected unsupported")
        } catch let AlbumError.unsupported(operation, _) {
            XCTAssertEqual(operation, "Remove from album")
        }
        XCTAssertTrue(unsupported.removed.isEmpty)

        let supported = FakeAlbumBackend(
            capabilities: .init(
                canList: true,
                canCreate: false,
                canAddPhotos: false,
                canRemovePhotos: true,
                canSetCover: false
            )
        )
        let photos = [uid("1"), uid("2")]
        try await repository(supported).removePhotos(photos, from: "album")
        XCTAssertEqual(supported.removed.first?.album, "album")
        XCTAssertEqual(supported.removed.first?.uids, photos)
    }

    func testSetCoverForwardsWhenSupported() async throws {
        let backend = FakeAlbumBackend(
            capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true))
        let repo = repository(backend)
        try await repo.setAlbumCover(albumID: "a", photoUID: uid("9"))
        XCTAssertEqual(backend.covers.count, 1)
        XCTAssertEqual(backend.covers.first?.album, "a")
    }
}

private actor SharedLeaveRecorder {
    private(set) var values: [AlbumNodeIdentifier] = []

    func record(_ album: AlbumNodeIdentifier) {
        values.append(album)
    }
}

private actor RecordedPendingAlbumAdds {
    private(set) var adds: [(uids: [PhotoUID], album: AlbumID)] = []
    func append(_ uids: [PhotoUID], _ album: AlbumID) { adds.append((uids, album)) }
}
