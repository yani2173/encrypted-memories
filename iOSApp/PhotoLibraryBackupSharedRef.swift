import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore

/// The BGProcessingTask handler outlives every SwiftUI scene, so the current account's backup
/// controller registers itself here (weak - sign-out releases it naturally).
@MainActor
final class PhotoLibraryBackupSharedRef {
    static let shared = PhotoLibraryBackupSharedRef()

    private let reference = WeakAsyncReference<PhotoLibraryBackupController>()
    var controller: PhotoLibraryBackupController? {
        get { reference.value }
        set { reference.value = newValue }
    }

    private init() {}

    /// A BG task can launch the process before SwiftUI finishes restoring the account/backend.
    /// Suspend without polling until configuration publishes the controller or the launch window times out; end
    /// earlier when the reads of the saved sign-in show that no account can come.
    func controllerWhenReady(timeout: Duration) async -> BackgroundAccountWait<PhotoLibraryBackupController> {
        await BackgroundAccountReadiness.shared.wait(for: reference, timeout: timeout)
    }
}
