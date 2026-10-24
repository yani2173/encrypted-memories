import AlbumCore
import AlbumSyncCore
import Foundation
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
