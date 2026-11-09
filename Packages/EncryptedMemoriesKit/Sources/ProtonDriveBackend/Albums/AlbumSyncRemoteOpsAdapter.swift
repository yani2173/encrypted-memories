import AlbumCore
import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore

/// `AlbumSyncCore.AlbumSyncRemoteAlbumOps` over the album write service + the bridge's decrypted
/// album listing. Thin translation only - if Proton's SDK gains album-write APIs, this adapter is
/// the single type to swap.
struct ProtonAlbumSyncRemoteOps: AlbumSyncRemoteAlbumOps {
    let service: ProtonAlbumWriteService
    /// The bridge's album listing (ids + decrypted titles) - shared with the sidebar/repository.
    let listProvider: @Sendable () async throws -> [AlbumSummary]
    /// The upload duplicate checker over the account's content index; nil when the account has none.
    var duplicateChecker: (any UploadDuplicateChecking)?
    /// Copies of one photo per lookup; more copies of the same bytes are rare.
    static let sameContentLimit = 16
    var recoveryVolumeProvider: (@Sendable () async throws -> String)?
    var recoveryRestore: (@Sendable (PhotoUID) async throws -> Void)?
    var recoverySessionID = UUID()

    /// Composition uses the existing trash route, including related photos and session shutdown admission.
    static func withRecovery(
        service: ProtonAlbumWriteService,
        listProvider: @escaping @Sendable () async throws -> [AlbumSummary],
        duplicateChecker: (any UploadDuplicateChecking)?, bridge: DriveSDKBridge
    ) -> Self {
        Self(
            service: service, listProvider: listProvider, duplicateChecker: duplicateChecker,
            recoveryVolumeProvider: { try await bridge.photosShareContext().volumeID },
            recoveryRestore: { uid in try await bridge.restore([uid]) })
    }

    func photoRecoveryContext() async throws -> AlbumSyncPhotoRecovery.Context? {
        guard let duplicateChecker, let recoveryVolumeProvider, recoveryRestore != nil else { return nil }
        let volume = try await recoveryVolumeProvider()
        let epoch = try await duplicateChecker.hashKeyEpoch()
        try Task.checkCancellation()
        guard !volume.isEmpty, !epoch.isEmpty else { return nil }
        return .init(sessionID: recoverySessionID, volumeID: volume, hashKeyEpoch: epoch)
    }

    func photoRecoveryState(for record: UploadIdentityRecord) async throws -> AlbumSyncPhotoRecovery.RemoteState {
        guard let duplicateChecker, let linkID = record.remoteLinkID, !linkID.isEmpty,
            !record.nameHash.isEmpty, !record.contentHash.isEmpty,
            try await duplicateChecker.hashKeyEpoch() == record.hashKeyEpoch
        else { return .unavailable }
        try Task.checkCancellation()
        let rows = try await duplicateChecker.findDuplicates(nameHashes: [record.nameHash])
        try Task.checkCancellation()
        let exact = rows.filter {
            $0.linkID == linkID && $0.nameHash == record.nameHash && $0.contentHash == record.contentHash
        }
        guard let state = exact.first?.linkState, state == .trashed || state == .active,
            exact.allSatisfy({ $0.linkState == state })
        else { return .unavailable }
        let role = try await duplicateChecker.linkVisibility(of: [linkID])[linkID]
        try Task.checkCancellation()
        guard let role, role.hasExplicitPhotoState, role.mainPhotoLinkID == nil,
            role.isActive == (state == .active)
        else { return .unavailable }
        let metadata = try await duplicateChecker.linkStateSnapshot(of: [linkID])
        try Task.checkCancellation()
        guard metadata.complete, metadata.states[linkID] == state.rawValue else { return .unavailable }
        return state == .trashed ? .trashed : .active
    }

    func restorePhoto(
        _ uid: PhotoUID, context: AlbumSyncPhotoRecovery.Context,
        validate: @Sendable () async throws -> Void
    ) async throws {
        guard let recoveryRestore, uid.volumeID == context.volumeID, !uid.nodeID.isEmpty,
            try await photoRecoveryContext() == context
        else { throw AlbumSyncPhotoRecovery.Error.unavailable }
        try await validate()
        try Task.checkCancellation()
        try await recoveryRestore(uid)
    }

    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] {
        try await listProvider().map { AlbumSyncRemoteAlbum(id: $0.id, title: $0.title) }
    }

    func createAlbum(name: String) async throws -> String {
        try await service.createAlbum(name: name)
    }

    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await service.childMainLinkIDs(albumID: albumID)
    }

    func remoteDeletionStates(for links: [AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState] {
        guard let duplicateChecker else { return [:] }
        return try await UploadRemoteDeletionLookup.states(for: links.map { $0.uid.nodeID }, checker: duplicateChecker)
    }

    func activeMainLinkIDs(withSameContentAs sha1Hexes: Set<String>) async throws -> [String: Set<String>] {
        guard let duplicateChecker else { return [:] }
        var result: [String: Set<String>] = [:]
        for sha1Hex in sha1Hexes.sorted() {
            try Task.checkCancellation()
            let contentHash = try await duplicateChecker.contentHash(forSHA1Hex: sha1Hex)
            let copies = try await duplicateChecker.findDuplicates(
                contentHash: contentHash, limit: Self.sameContentLimit)
            let active = Set(copies.filter { $0.linkState == .active }.compactMap(\.linkID).filter { !$0.isEmpty })
            if !active.isEmpty { result[sha1Hex] = active }
        }
        return result
    }

    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        let result = try await service.attach(
            photos.map { AlbumAttachRequestItem(uid: $0.uid, sha1Hex: $0.sha1Hex) },
            albumID: albumID
        )
        return AlbumSyncAttachResult(
            attached: result.attachedCount,
            alreadyMember: result.alreadyMemberCount,
            failed: result.failedCount,
            firstFailureMessage: result.firstFailureMessage,
            failedLinkIDs: result.outcomes.filter { if case .failed = $0.value { true } else { false } }.map(\.key),
            failureMessages: result.outcomes.compactMapValues { outcome in
                if case .failed(_, let message) = outcome { message } else { nil }
            }
        )
    }
}
