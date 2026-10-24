import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@Suite @MainActor struct PendingGridSessionPauseTests {
    @Test func theGridFollowsThePauseOfTheBackupController() async throws {
        let suite = "pending-grid-pause-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil,
            uploader: MockUploader(),
            pendingStore: store,
            requiresPendingStore: true
        )
        let session = try #require(PendingGridSession(store: store, photoBackup: controller, remote: NoRemoteEffects()))
        session.start()
        #expect(!session.presenter.isBackupPaused)

        controller.pauseBackup()
        #expect(await eventually { session.presenter.isBackupPaused }, "the grid shows the pause")

        await controller.resumeBackup()
        #expect(await eventually { !session.presenter.isBackupPaused }, "the grid shows progress again")

        await session.close()
        await controller.shutdown()
        store.close()
    }

    @Test func closingTheGridReleasesItsSessionAndBackupController() async throws {
        let suite = "pending-grid-deallocation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        var controller: PhotoLibraryBackupController? = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil, uploader: MockUploader(), pendingStore: store, requiresPendingStore: true)
        var session: PendingGridSession? = try #require(
            PendingGridSession(store: store, photoBackup: controller!, remote: NoRemoteEffects()))
        weak var releasedSession = session
        weak var releasedController = controller
        session?.start()
        await session?.close()
        await controller?.shutdown()
        session = nil
        controller = nil
        #expect(await eventually { releasedSession == nil && releasedController == nil })
        store.close()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private struct NoRemoteEffects: PendingRemoteEffects {
    func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}
