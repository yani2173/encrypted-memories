import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// A Proton photo restored from Recently Deleted on iPhone and iPad takes its local photo back into the backup (#829).
@MainActor @Suite struct MobileTrashRestoreBackupTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var all: [String] { lock.withLock { values } }
        func append(_ value: String) { lock.withLock { values.append(value) } }
    }

    private struct RecordingRemote: PendingRemoteEffects {
        let calls: Calls
        func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            calls.append("trash")
            return .done
        }
        func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            calls.append("restore")
            return .done
        }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
    }

    @Test func aRestoredProtonPhotoReturnsItsLocalPhotoToTheBackup() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let model = MobileLibraryModel()
        let suite = "mobile-trash-restore-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        defer {
            store.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let photo = try #require(fixture.sections.first?.items.first)
        let source = PendingSourceKey(kind: .photoLibraryAsset, identifier: "fixture-restored-photo")
        // A delete in this app moved the Proton photo of this local photo to the Proton trash.
        let presentation = PendingPresentationMetadata(
            captureTime: photo.captureTime, mediaType: photo.mediaType, displayName: "Restored.heic")
        let deleted = PendingExclusionRequest(key: source, presentation: presentation, remote: photo.uid)
        _ = try #require(store.exclude([deleted], at: Date()))
        #expect(store.completeEffect(.remoteTrash, for: source, generation: 1, at: Date()))
        fixture.install(
            into: model, backend: MobileFixtureBackend(sections: fixture.sections, thumbnails: [:]),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        model.installIsolatedDuplicatesForTesting(MobileFixtureDuplicates(groups: []))
        let calls = Calls()
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: MobilePendingTestBackend(), uploader: MobilePendingTestBackend(), pendingStore: store,
            requiresPendingStore: true)
        do {
            model.installIsolatedPendingBackupForTesting(controller, store: store, remote: RecordingRemote(calls: calls))
            let session = try #require(model.pendingGrid)
            #expect(await eventually { session.pendingSnapshot.excludedTiles.contains { $0.key == source } })

            try await model.restoreItems([photo])

            #expect(store.sourceState(for: source)?.desired != .excluded, "the local photo is backed up again")
            #expect(await eventually { !session.pendingSnapshot.excludedTiles.contains { $0.key == source } })
            #expect(calls.all.isEmpty, "the photo is out of the Proton trash already")
        } catch {
            await model.pendingGrid?.close()
            await controller.shutdown()
            throw error
        }
        await model.pendingGrid?.close()
        await controller.shutdown()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
