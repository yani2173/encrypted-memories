import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

private struct UnusedUploader: PhotoUploading {
    let capabilities = UploadBackendCapabilities(
        canUpload: true, supportsCancel: true, supportsPauseResume: false, supportsResumeAcrossRelaunch: false)

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID { throw CancellationError() }
    func cancel(token: UUID) async {}
}

@MainActor
@Suite(.serialized) struct PhotoBackupBackgroundCoordinatorTests {
    /// Turning backup off detaches the controller and cancels the background request. Turning it on again in the
    /// same session must re-arm both; before, background backup stayed off until the next launch.
    @Test func turningBackupOnAgainRearmsBackgroundBackup() async throws {
        let suite = "photo-backup-background-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil,
            uploader: UnusedUploader())
        let coordinator = PhotoBackupBackgroundCoordinator.shared

        coordinator.backupStopped()
        #expect(coordinator.isSchedulingStopped)
        #expect(PhotoLibraryBackupSharedRef.shared.controller == nil)

        coordinator.backupResumed(controller: controller)
        #expect(!coordinator.isSchedulingStopped)
        #expect(PhotoLibraryBackupSharedRef.shared.controller === controller)

        coordinator.backupStopped()
        await controller.shutdown()
    }
}
