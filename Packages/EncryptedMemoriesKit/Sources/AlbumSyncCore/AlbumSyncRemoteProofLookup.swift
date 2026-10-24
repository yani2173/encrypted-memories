import Foundation
import PhotosCore
import UploadCore

/// Resolves links without bytes or stored identity changes. The queue admits the lookup; exact remote proof supplies it.
public enum AlbumSyncRemoteProofLookup {
    private static let batchSize = 128

    public static func remoteLinks(
        for localIdentifiers: [String], catalog: any UploadBackupAssetCatalog,
        queue: any UploadBackupSyncQueueStore, resolver: any UploadIdentityResolving
    ) async throws -> [String: AlbumSyncRemoteLink] {
        let requested = Set(localIdentifiers)
        var result: [String: AlbumSyncRemoteLink] = [:]
        var batch: [UploadBackupAssetSnapshot] = []
        for try await candidate in catalog.candidates() {
            try Task.checkCancellation()
            let snapshot = candidate.snapshot
            guard snapshot.source.kind == .photoLibraryAsset, snapshot.source.resource == .primary,
                requested.contains(snapshot.source.identifier), snapshot.externalIdentity != nil
            else { continue }
            let row = queue.entry(for: snapshot.source, revision: snapshot.revision)
            guard queue.isOperational() else { throw AlbumSyncError.mappingStoreUnavailable }
            guard row?.state == .alreadyBackedUp else { continue }
            batch.append(snapshot)
            if batch.count == batchSize {
                result.merge(try await links(in: batch, resolver: resolver)) { existing, _ in existing }
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try Task.checkCancellation()
            result.merge(try await links(in: batch, resolver: resolver)) { existing, _ in existing }
        }
        return result
    }

    private static func links(
        in snapshots: [UploadBackupAssetSnapshot], resolver: any UploadIdentityResolving
    ) async throws -> [String: AlbumSyncRemoteLink] {
        let proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
        do {
            proofs = try await resolver.remoteAssetProofs(for: snapshots.compactMap(\.externalIdentity))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if UploadError.isCancellation(error) { throw error }
            try Task.checkCancellation()
            return [:]
        }
        try Task.checkCancellation()
        var result: [String: AlbumSyncRemoteLink] = [:]
        for snapshot in snapshots {
            guard let identity = snapshot.externalIdentity, let proof = proofs[identity],
                proof.externalIdentity == identity, proof.resourceCount == snapshot.resourceCount,
                proof.remoteLinkIDs.count == proof.resourceCount,
                Set(proof.remoteLinkIDs).count == proof.resourceCount,
                proof.remoteLinkIDs.allSatisfy({ !$0.isEmpty }),
                let primary = proof.remoteLinkIDs.first
            else { continue }
            // Proof builders and the persistent index put the main link first. Album writes resolve the account volume.
            result[snapshot.source.identifier] = AlbumSyncRemoteLink(
                uid: PhotoUID(volumeID: "", nodeID: primary), sha1Hex: nil, isTrashed: false)
        }
        return result
    }
}
