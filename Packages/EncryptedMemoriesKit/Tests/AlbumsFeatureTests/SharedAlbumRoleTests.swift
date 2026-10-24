import PhotosCore
import XCTest

@testable import AlbumCore
@testable import AlbumsFeature

private func sharedAlbum(
    _ nodeID: String,
    role: SharedAlbumRole,
    invitation: SharedAlbumInvitation? = nil,
    photoCount: Int = 3
) -> SharedAlbumSummary {
    SharedAlbumSummary(
        node: AlbumNodeIdentifier(volumeID: "foreign-volume", nodeID: nodeID),
        title: "Shared \(nodeID)",
        photoCount: photoCount,
        coverPhotoID: nil,
        owner: "owner@example.test",
        lastActivityTime: nil,
        isSharedByURL: false,
        isMetadataDegraded: false,
        role: role,
        invitation: invitation
    )
}

private var sharedWriteTransport: AlbumCapabilities {
    var capabilities = AlbumCapabilities.sdkCatalogWithHTTPWrites
    capabilities.canWriteSharedAlbums = true
    return capabilities
}

final class SharedAlbumPermissionTests: XCTestCase {
    func testWiredHTTPTransportDoesNotAddressSharedAlbums() {
        XCTAssertFalse(AlbumCapabilities.sdkCatalogWithHTTPWrites.canWriteSharedAlbums)
    }

    func testViewerAndInheritedAccessStayReadOnlyEvenWithATransport() {
        for role in [SharedAlbumRole.viewer, .inherited] {
            for capabilities in [AlbumCapabilities.sdkCatalogWithHTTPWrites, sharedWriteTransport] {
                let permissions = SharedAlbumPermissions.resolve(role: role, capabilities: capabilities)
                XCTAssertTrue(permissions.canView)
                XCTAssertFalse(permissions.canAddPhotos, "\(role)")
                XCTAssertFalse(permissions.canRemovePhotos, "\(role)")
                XCTAssertFalse(permissions.canSetCover, "\(role)")
                XCTAssertFalse(permissions.canDelete, "\(role)")
                XCTAssertFalse(permissions.canManageMembers, "\(role)")
                XCTAssertEqual(permissions.writeRestriction, .roleDoesNotPermitEditing)
            }
        }
    }

    func testEditorAndAdminAreReadOnlyWithoutASharedAlbumTransport() {
        for role in [SharedAlbumRole.editor, .admin] {
            let permissions = SharedAlbumPermissions.resolve(
                role: role, capabilities: .sdkCatalogWithHTTPWrites)
            XCTAssertTrue(permissions.isReadOnly, "\(role)")
            XCTAssertEqual(permissions.writeRestriction, .transportUnsupported)
        }
    }

    func testEditorAndAdminEditOnlyWithAConfirmedTransportAndNeverDeleteOrManageMembers() {
        for role in [SharedAlbumRole.editor, .admin] {
            let permissions = SharedAlbumPermissions.resolve(role: role, capabilities: sharedWriteTransport)
            XCTAssertTrue(permissions.canAddPhotos, "\(role)")
            XCTAssertTrue(permissions.canRemovePhotos, "\(role)")
            XCTAssertTrue(permissions.canSetCover, "\(role)")
            XCTAssertFalse(permissions.canDelete, "\(role)")
            XCTAssertFalse(permissions.canManageMembers, "\(role)")
            XCTAssertNil(permissions.writeRestriction)
        }
    }

    func testEffectiveRoleWinsOverALowerInvitationRole() {
        let invitation = SharedAlbumInvitation(
            role: .viewer, sharedBy: "a@example.test", isSharedByVerified: true, inviteTime: nil)
        let album = sharedAlbum("one", role: .editor, invitation: invitation)
        let permissions = SharedAlbumPermissions.resolve(role: album.role, capabilities: sharedWriteTransport)
        XCTAssertTrue(permissions.canAddPhotos)
    }

    func testInviteTimePlausibility() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            SharedAlbumInvitation.plausibleInviteTime(1_700_000_000, now: now),
            Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(SharedAlbumInvitation.plausibleInviteTime(0, now: now))
        XCTAssertNil(SharedAlbumInvitation.plausibleInviteTime(-5, now: now))
        XCTAssertNil(SharedAlbumInvitation.plausibleInviteTime(.nan, now: now))
        XCTAssertNil(SharedAlbumInvitation.plausibleInviteTime(.infinity, now: now))
        XCTAssertNil(SharedAlbumInvitation.plausibleInviteTime(1_800_000_000 + 2 * 86_400, now: now))
        XCTAssertNotNil(SharedAlbumInvitation.plausibleInviteTime(1_800_000_000 + 3_600, now: now))
    }

    func testInvitationDegradedWhenInviterMissingUnverifiedOrTimeInvalid() {
        let complete = SharedAlbumInvitation(
            role: .viewer, sharedBy: "a@example.test", isSharedByVerified: true, inviteTime: Date())
        XCTAssertFalse(complete.isDegraded)
        XCTAssertTrue(
            SharedAlbumInvitation(role: .viewer, sharedBy: "  ", isSharedByVerified: true, inviteTime: Date())
                .isDegraded)
        XCTAssertTrue(
            SharedAlbumInvitation(role: .viewer, sharedBy: "a@x", isSharedByVerified: false, inviteTime: Date())
                .isDegraded)
        XCTAssertTrue(
            SharedAlbumInvitation(role: .viewer, sharedBy: "a@x", isSharedByVerified: true, inviteTime: nil)
                .isDegraded)
    }
}

final class SharedAlbumRepositoryGuardTests: XCTestCase {
    func testOwnedWritesRejectAKnownSharedAlbumBeforeAnyRequest() async throws {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedAlbums = [sharedAlbum("viewer-album", role: .viewer), sharedAlbum("editor-album", role: .editor)]
        let repo = repository(backend)
        _ = try await repo.listAlbums()
        _ = try await repo.listSharedWithMeAlbums()
        let photo = PhotoUID(volumeID: "vol", nodeID: "p")

        await assertReadOnly(.roleDoesNotPermitEditing) { try await repo.addPhotos([photo], to: "viewer-album") }
        await assertReadOnly(.roleDoesNotPermitEditing) { try await repo.removePhotos([photo], from: "viewer-album") }
        await assertReadOnly(.roleDoesNotPermitEditing) {
            try await repo.setAlbumCover(albumID: "viewer-album", photoUID: photo)
        }
        await assertReadOnly(.roleDoesNotPermitEditing) { try await repo.deleteAlbum(albumID: "viewer-album") }
        await assertReadOnly(.transportUnsupported) { try await repo.addPhotos([photo], to: "editor-album") }

        XCTAssertTrue(backend.added.isEmpty)
        XCTAssertTrue(backend.removed.isEmpty)
        XCTAssertTrue(backend.covers.isEmpty)
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    func testOwnedAlbumWritesAreUnchangedWhenSharedAlbumsAreLoaded() async throws {
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: "owned", title: "Mine", photoCount: 0, coverPhotoID: nil)])
        backend.sharedAlbums = [sharedAlbum("shared", role: .viewer)]
        let repo = repository(backend)
        _ = try await repo.listAlbums()
        _ = try await repo.listSharedWithMeAlbums()
        let photo = PhotoUID(volumeID: "vol", nodeID: "p")

        try await repo.addPhotos([photo], to: "owned")
        try await repo.removePhotos([photo], from: "owned")
        try await repo.setAlbumCover(albumID: "owned", photoUID: photo)
        try await repo.deleteAlbum(albumID: "owned")

        XCTAssertEqual(backend.added.map(\.album), ["owned"])
        XCTAssertEqual(backend.removed.map(\.album), ["owned"])
        XCTAssertEqual(backend.covers.map(\.album), ["owned"])
        XCTAssertEqual(backend.deleted, ["owned"])
    }

    private func assertReadOnly(
        _ expected: SharedAlbumWriteRestriction,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("shared album write was not rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AlbumError, .sharedAlbumReadOnly(expected), file: file, line: line)
        }
    }
}

final class SharedAlbumCoordinatorTests: XCTestCase {
    @MainActor
    func testMultipleSharedAlbumsKeepSeparatePermissions() async {
        let backend = FakeAlbumBackend(capabilities: sharedWriteTransport)
        backend.sharedAlbums = [
            sharedAlbum("viewer", role: .viewer),
            sharedAlbum("editor", role: .editor),
            sharedAlbum("admin", role: .admin),
            sharedAlbum("inherited", role: .inherited),
        ]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refreshSharedAlbums()

        let canAdd = Dictionary(
            uniqueKeysWithValues: coordinator.sharedAlbums.map {
                ($0.node.nodeID, coordinator.permissions(for: $0).canAddPhotos)
            })
        XCTAssertEqual(canAdd, ["viewer": false, "editor": true, "admin": true, "inherited": false])
    }

    @MainActor
    func testWiredCapabilitiesKeepEditorAndAdminReadOnly() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedAlbums = [sharedAlbum("editor", role: .editor), sharedAlbum("admin", role: .admin)]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refreshSharedAlbums()

        for album in coordinator.sharedAlbums {
            XCTAssertEqual(coordinator.permissions(for: album).writeRestriction, .transportUnsupported)
        }
    }

    @MainActor
    func testFailedMembershipReadKeepsTheOwnedWritePathEnabled() async {
        let backend = FailingMembershipBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: "owned", title: "Mine", photoCount: 0, coverPhotoID: nil)])
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        let photo = PhotoUID(volumeID: "vol", nodeID: "p")

        await coordinator.loadMemberships(for: [photo])

        XCTAssertNil(coordinator.membershipState(for: "owned"))
        XCTAssertTrue(coordinator.canAddPhotos)
        let added = await coordinator.add([photo], to: "owned")
        XCTAssertTrue(added)
        XCTAssertEqual(backend.added.map(\.album), ["owned"])
    }

    @MainActor
    func testPartialAddStaysVisibleAndDoesNotCreateAnotherAlbum() async {
        let backend = FakeAlbumBackend(
            capabilities: .sdkCatalogWithHTTPWrites,
            albums: [AlbumSummary(id: "owned", title: "Mine", photoCount: 0, coverPhotoID: nil)])
        backend.addError = AlbumError.partialAdd(succeeded: 1, total: 2, message: "code 2011")
        let coordinator = AlbumActionCoordinator(repository: repository(backend))

        let added = await coordinator.add(
            [PhotoUID(volumeID: "vol", nodeID: "a"), PhotoUID(volumeID: "vol", nodeID: "b")], to: "owned")

        XCTAssertFalse(added)
        XCTAssertEqual(
            coordinator.actionFailure?.message,
            AlbumError.partialAdd(succeeded: 1, total: 2, message: "").errorDescription)
        XCTAssertTrue(backend.created.isEmpty)
    }

    @MainActor
    func testSharedAlbumWriteRejectionIsReportedAsAFailure() async {
        let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
        backend.sharedAlbums = [sharedAlbum("viewer", role: .viewer)]
        let coordinator = AlbumActionCoordinator(repository: repository(backend))
        await coordinator.refresh()
        await coordinator.refreshSharedAlbums()

        let added = await coordinator.add([PhotoUID(volumeID: "vol", nodeID: "a")], to: "viewer")

        XCTAssertFalse(added)
        XCTAssertEqual(
            coordinator.actionFailure?.message, SharedAlbumWriteRestriction.roleDoesNotPermitEditing.localizedReason)
        XCTAssertTrue(backend.added.isEmpty)
    }
}

final class SharedAlbumPresentationTests: XCTestCase {
    func testRowTextContainsTheEffectiveRoleAndNeverCallsInheritedAccessAnInvitation() {
        for role in SharedAlbumRole.allCases {
            let album = sharedAlbum("one", role: role)
            let presentation = SharedAlbumPresentation(
                album: album,
                permissions: .resolve(role: role, capabilities: .sdkCatalogWithHTTPWrites))
            let title = SharedAlbumPresentation.roleTitle(role)
            XCTAssertTrue(presentation.detailLine.contains(title), "\(role)")
            XCTAssertTrue(presentation.accessibilityLabel.contains(title), "\(role)")
            XCTAssertNil(presentation.invitationDetail, "\(role)")
            XCTAssertNotNil(presentation.writeRestrictionReason, "\(role)")
            XCTAssertEqual(presentation.accessibilityHint, presentation.writeRestrictionReason)
        }
        XCTAssertEqual(
            SharedAlbumPresentation.roleTitle(.inherited), L10n.string("albums.shared_role_inherited"))
    }

    // String Catalogs are compiled to `.lproj` only by Xcode's build system; plain SwiftPM copies the raw
    // catalog, so the lookups below skip there and run under `scripts/verify-tests.sh`.
    private var catalogCompiledIntoBundle: Bool {
        L10n.resourceBundle.localizations.contains("de")
    }

    func testDetailLineShowsTheLocalizedPhotoCountInsteadOfTheCatalogKey() throws {
        try XCTSkipUnless(catalogCompiledIntoBundle, "String Catalog not compiled (plain SwiftPM build).")
        let presentation = SharedAlbumPresentation(
            album: sharedAlbum("one", role: .viewer, photoCount: 12),
            permissions: .resolve(role: .viewer, capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertFalse(presentation.detailLine.contains("albums.photo_count"), presentation.detailLine)
        XCTAssertTrue(presentation.detailLine.contains("12"), presentation.detailLine)
        XCTAssertFalse(presentation.accessibilityLabel.contains("albums.photo_count"), presentation.accessibilityLabel)
    }

    func testPhotoCountIsTranslatedIntoEnglishAndGerman() throws {
        try XCTSkipUnless(catalogCompiledIntoBundle, "String Catalog not compiled (plain SwiftPM build).")
        let expected: [(language: String, count: Int, text: String)] = [
            ("en", 1, "1 photo"), ("en", 12, "12 photos"),
            ("de", 1, "1 Foto"), ("de", 12, "12 Fotos"),
        ]
        for (language, count, text) in expected {
            let path = try XCTUnwrap(L10n.resourceBundle.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path), language)
            let translated = String(
                localized: "albums.photo_count \(count)", bundle: bundle, locale: Locale(identifier: language))
            XCTAssertEqual(translated, text, "\(language) \(count)")
        }
    }

    func testInheritedAccessNeverShowsInvitationDetailsEvenIfTheSDKSendsThem() {
        let invitation = SharedAlbumInvitation(
            role: .viewer, sharedBy: "a@example.test", isSharedByVerified: true, inviteTime: Date())
        let presentation = SharedAlbumPresentation(
            album: sharedAlbum("one", role: .inherited, invitation: invitation),
            permissions: .resolve(role: .inherited, capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertNil(presentation.invitationDetail)
    }

    func testEditorWithoutTransportIsMarkedReadOnlyInText() {
        let album = sharedAlbum("one", role: .editor)
        let presentation = SharedAlbumPresentation(
            album: album, permissions: .resolve(role: .editor, capabilities: .sdkCatalogWithHTTPWrites))
        let editor = SharedAlbumPresentation.roleTitle(.editor)
        XCTAssertTrue(presentation.detailLine.contains(L10n.string("albums.shared_role_read_only \(editor)")))
        XCTAssertEqual(
            presentation.writeRestrictionReason, SharedAlbumWriteRestriction.transportUnsupported.localizedReason)
    }

    func testVerifiedAndUnverifiedInviterWording() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let verified = SharedAlbumPresentation(
            album: sharedAlbum(
                "one", role: .viewer,
                invitation: .init(
                    role: .viewer, sharedBy: "a@example.test", isSharedByVerified: true, inviteTime: date)),
            permissions: .resolve(role: .viewer, capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertEqual(
            verified.invitationDetail,
            L10n.string("albums.shared_invited_by \("a@example.test")") + " • "
                + L10n.string("albums.shared_invited_on \(date.formatted(date: .abbreviated, time: .omitted))"))

        let unverified = SharedAlbumPresentation(
            album: sharedAlbum(
                "one", role: .viewer,
                invitation: .init(
                    role: .viewer, sharedBy: "a@example.test", isSharedByVerified: false, inviteTime: nil)),
            permissions: .resolve(role: .viewer, capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertEqual(
            unverified.invitationDetail, L10n.string("albums.shared_invited_by_unverified \("a@example.test")"))
        XCTAssertNotEqual(unverified.invitationDetail, L10n.string("albums.shared_invited_by \("a@example.test")"))

        let anonymous = SharedAlbumPresentation(
            album: sharedAlbum(
                "one", role: .viewer,
                invitation: .init(role: .viewer, sharedBy: nil, isSharedByVerified: false, inviteTime: nil)),
            permissions: .resolve(role: .viewer, capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertEqual(anonymous.invitationDetail, L10n.string("albums.shared_inviter_unverified"))

        let missing = SharedAlbumPresentation(
            album: sharedAlbum(
                "one", role: .viewer,
                invitation: .init(role: .viewer, sharedBy: nil, isSharedByVerified: true, inviteTime: nil)),
            permissions: .resolve(role: .viewer, capabilities: .sdkCatalogWithHTTPWrites))
        XCTAssertNil(missing.invitationDetail)
    }
}

private final class FailingMembershipBackend: AlbumCatalogBackend, AlbumWriteBackend, @unchecked Sendable {
    let capabilities: AlbumCapabilities
    let albums: [AlbumSummary]
    private(set) var added: [(uids: [PhotoUID], album: AlbumID)] = []

    init(capabilities: AlbumCapabilities, albums: [AlbumSummary]) {
        self.capabilities = capabilities
        self.albums = albums
    }

    func listAlbums() async throws -> [AlbumSummary] { albums }
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        throw AlbumError.backend("membership read failed")
    }
    func createAlbum(name: String) async throws -> AlbumID { "unexpected" }
    func deleteAlbum(albumID: AlbumID) async throws {}
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws { added.append((photoUIDs, albumID)) }
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {}
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {}
}

private func repository(_ backend: FailingMembershipBackend) -> AlbumsRepository {
    AlbumsRepository(catalogBackend: backend, writeBackend: backend, capabilities: backend.capabilities)
}
