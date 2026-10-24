import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// Empty Recently Deleted on iPhone and iPad asks the duplicate merges first.
@MainActor @Suite struct MobileEmptyTrashTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var current: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private func makeLibrary(confirmsNoPendingMerges: Bool) async throws -> (MobileLibraryModel, Count) {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let emptied = Count()
        var backend = MobileFixtureBackend(sections: fixture.sections, thumbnails: [:])
        backend.trashEmptier = { emptied.increment() }
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.installIsolatedDuplicatesForTesting(
            MobileFixtureDuplicates(groups: [], confirmsNoPendingMerges: confirmsNoPendingMerges))
        return (model, emptied)
    }

    @Test func anOpenMergeThatCannotBeCheckedKeepsRecentlyDeleted() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: false)

        await #expect(throws: RecentlyDeletedEmptying.PendingMergeCheck.self) {
            try await model.emptyTrash()
        }
        #expect(emptied.current == 0, "nothing is deleted while a merge waits for its check")
    }

    @Test func localOnlyEmptyingSkipsProtonAndTheMergeCheck() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: false)

        let checks = Count()
        model.installIsolatedDuplicatesForTesting(CountingDuplicates(checks: checks))

        try await model.emptyTrash(includesProtonTrash: false)

        #expect(emptied.current == 0)
        #expect(checks.current == 0, "local-only emptying must not consult the merge check")
    }

    @Test(arguments: [false, true])
    func pendingRemovalPrecedesProtonAndFailureStopsIt(storeFails: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let model = MobileLibraryModel()
        let suite = "mobile-empty-trash-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        defer {
            store.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = PendingSourceKey(kind: .photoLibraryAsset, identifier: "fixture-paused-photo")
        let emptied = Count()
        var backend = MobileFixtureBackend(sections: fixture.sections, thumbnails: [:])
        backend.trashEmptier = {
            #expect(store.sourceState(for: source)?.listedInTrash == false, "pending removal must finish before Proton")
            emptied.increment()
        }
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.installIsolatedDuplicatesForTesting(MobileFixtureDuplicates(groups: []))
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: PendingBackend(), uploader: PendingBackend(), pendingStore: store,
            requiresPendingStore: true)
        do {
            #expect(controller.installPausedBackupFixtureForTesting())
            model.installIsolatedPendingBackupForTesting(controller, store: store, remote: PendingRemote())
            let session = try #require(model.pendingGrid)
            #expect(await eventually { session.pendingSnapshot.tiles.contains { $0.item.uid == source.localUID } })
            #expect(await session.delete([source.localUID]))
            #expect(await eventually { model.pendingTrash.localUIDs == [source.localUID] })
            #expect(store.sourceState(for: source)?.listedInTrash == true)

            if storeFails {
                store.close()
                await #expect(throws: CancellationError.self) { try await model.emptyTrash() }
                #expect(emptied.current == 0, "a failed pending removal must stop before Proton")
                #expect(model.pendingTrash.localUIDs == [source.localUID])
            } else {
                try await model.emptyTrash()
                #expect(emptied.current == 1)
                #expect(store.sourceState(for: source)?.listedInTrash == false)
                #expect(await eventually { model.pendingTrash.isEmpty })
            }
        } catch {
            await model.pendingGrid?.close()
            await controller.shutdown()
            throw error
        }
        await model.pendingGrid?.close()
        await controller.shutdown()
    }

    @Test func withoutABackendEmptyingDoesNothing() async throws {
        let model = MobileLibraryModel()
        let checks = Count()
        model.installIsolatedDuplicatesForTesting(CountingDuplicates(checks: checks))

        try await model.emptyTrash()

        #expect(checks.current == 0)
        #expect(model.pendingGrid == nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    private struct CountingDuplicates: ExactDuplicateMerging {
        let checks: Count
        private let base = MobileFixtureDuplicates(groups: [], confirmsNoPendingMerges: false)
        func confirmNoPendingMerges() async -> Bool {
            checks.increment()
            return await base.confirmNoPendingMerges()
        }
        func duplicateGroups(
            progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
        ) async throws -> ExactDuplicateScan { try await base.duplicateGroups(progress: progress) }
        func prepareIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws -> Bool { try await base.prepareIndex(progress: progress) }
        func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
            await base.fallbackMembers(of: groups)
        }
        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async { await base.rankMembers(of: groups, ranked: ranked) }
        func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            await base.merge(requests)
        }
    }

    private struct PendingBackend: PhotoUploading, UploadIdentityResolving {
        let capabilities = UploadBackendCapabilities(
            canUpload: true, supportsCancel: true, supportsPauseResume: false, supportsResumeAcrossRelaunch: false)
        func upload(
            _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID { throw CancellationError() }
        func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
            throw CancellationError()
        }
        func cancel(token: UUID) async {}
        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw CancellationError()
        }
        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String,
            remoteLinkID: String
        ) async throws { throw CancellationError() }
    }

    private struct PendingRemote: PendingRemoteEffects {
        func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            Issue.record("a local pending photo must not call Proton trash")
            return .done
        }
        func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
    }

    @Test func withoutAnOpenMergeRecentlyDeletedIsEmptied() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: true)

        try await model.emptyTrash()

        #expect(emptied.current == 1)
    }
}
