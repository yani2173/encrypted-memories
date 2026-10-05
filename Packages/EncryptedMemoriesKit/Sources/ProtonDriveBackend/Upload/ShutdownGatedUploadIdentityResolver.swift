import PhotosCore
import UploadCore

/// Account-lifecycle adapter for the shared upload identity pipeline.
///
/// The resolver owns SQLite and remote SDK work outside `DriveSDKBridge` actor isolation. Routing
/// every call through the bridge's shutdown gate prevents an old facade reference from touching
/// those resources after account teardown begins.
struct ShutdownGatedUploadIdentityResolver: UploadIdentityResolving {
    let base: any UploadIdentityResolving
    let admission: JoinedShutdownGate

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await admission.withAdmission {
            try await self.base.resolve(descriptor)
        }
    }

    func revalidateKnownRemote(
        _ descriptor: UploadResourceDescriptor
    ) async throws -> UploadDuplicateDecision? {
        try await admission.withAdmission {
            try await self.base.revalidateKnownRemote(descriptor)
        }
    }

    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        try await admission.withAdmission {
            try await self.base.remoteAssetProofs(for: identities)
        }
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await admission.withAdmission {
            try await self.base.prepareRemoteIndex(progress: progress)
        }
    }

    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        try await admission.withAdmission {
            try await self.base.remoteContentIndexHealth()
        }
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        _ = try? await admission.withAdmission {
            await self.base.prime(descriptors)
        }
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        try await admission.withAdmission {
            try await self.base.recordUploaded(
                descriptor,
                identity: identity,
                remoteVolumeID: remoteVolumeID,
                remoteLinkID: remoteLinkID
            )
        }
    }

    func invalidateCachedRemoteState() async {
        _ = try? await admission.withAdmission {
            await self.base.invalidateCachedRemoteState()
        }
    }

    func remoteMainsChangedHere() async {
        _ = try? await admission.withAdmission {
            await self.base.remoteMainsChangedHere()
        }
    }

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        _ = try? await admission.withAdmission {
            await self.base.uploadDidFail(descriptor)
        }
    }

    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        _ = try? await admission.withAdmission {
            await self.base.remoteCommitNeedsReconciliation(descriptor)
        }
    }

    func identityRecord(for source: UploadSourceIdentity) async -> UploadIdentityRecord? {
        try? await admission.withAdmission {
            await self.base.identityRecord(for: source)
        }
    }
}
