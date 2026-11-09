import Foundation
import PhotosCore
import UploadCore

/// Explicit recovery never authorizes an upload or establishes backup completion.
public enum AlbumSyncPhotoRecovery {
    public enum Error: Swift.Error, Equatable { case unavailable }
    public enum Result: Sendable, Equatable { case restored, alreadyActive }
    public enum RemoteState: Sendable, Equatable { case unavailable, trashed, active }

    public struct Context: Sendable, Equatable {
        public let sessionID: UUID
        public let volumeID: String
        public let hashKeyEpoch: String

        public init(sessionID: UUID, volumeID: String, hashKeyEpoch: String) {
            self.sessionID = sessionID
            self.volumeID = volumeID
            self.hashKeyEpoch = hashKeyEpoch
        }
    }

    /// A complete targeted catalog read must name exactly one current source.
    public static func candidate(
        for source: UploadSourceIdentity, catalog: any UploadBackupAssetCatalog
    ) async throws -> UploadBackupAssetCandidate {
        var match: UploadBackupAssetCandidate?
        for try await candidate in catalog.candidates() {
            try Task.checkCancellation()
            guard candidate.snapshot.source == source else { continue }
            guard match == nil else { throw Error.unavailable }
            match = candidate
        }
        try Task.checkCancellation()
        guard let match else { throw Error.unavailable }
        return match
    }

    /// Resource preparation does not always carry the catalog's optional cloud identifier.
    public static func sameVersion(_ first: UploadBackupAssetSnapshot, _ second: UploadBackupAssetSnapshot) -> Bool {
        first.source == second.source && first.revision == second.revision
            && first.editRevision == second.editRevision && first.resourceCount == second.resourceCount
    }

    public static func restore(
        record: UploadIdentityRecord, descriptor: UploadResourceDescriptor,
        remote: any AlbumSyncRemoteAlbumOps, expectedContext: Context, validate: @Sendable () async throws -> Void
    ) async throws -> Result {
        try Task.checkCancellation()
        guard record.source.kind == .photoLibraryAsset, record.source.resource == .primary,
            descriptor.precomputedSHA1Digest?.count == 20,
            record.isValid(for: descriptor, hashKeyEpoch: expectedContext.hashKeyEpoch),
            !record.nameHash.isEmpty, !record.contentHash.isEmpty,
            let linkID = record.remoteLinkID, !linkID.isEmpty,
            record.provesUpload || record.outcome == UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue,
            !expectedContext.volumeID.isEmpty, !expectedContext.hashKeyEpoch.isEmpty,
            record.remoteVolumeID == nil || record.remoteVolumeID == expectedContext.volumeID
        else { throw Error.unavailable }
        guard try await remote.photoRecoveryContext() == expectedContext else { throw Error.unavailable }
        try await validate()
        try Task.checkCancellation()
        let state = try await remote.photoRecoveryState(for: record)
        try Task.checkCancellation()
        try await validate()
        guard try await remote.photoRecoveryContext() == expectedContext else { throw Error.unavailable }
        try Task.checkCancellation()
        switch state {
        case .unavailable:
            throw Error.unavailable
        case .active:
            try await validate()
            try Task.checkCancellation()
            return .alreadyActive
        case .trashed:
            let uid = PhotoUID(volumeID: expectedContext.volumeID, nodeID: linkID)
            try await remote.restorePhoto(uid, context: expectedContext, validate: validate)
            try Task.checkCancellation()
            return .restored
        }
    }
}
