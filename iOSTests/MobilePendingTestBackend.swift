import Foundation
import PhotosCore
import UploadCore

/// A backup backend for tests of the pending grid: it uploads and resolves nothing.
struct MobilePendingTestBackend: PhotoUploading, UploadIdentityResolving {
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
