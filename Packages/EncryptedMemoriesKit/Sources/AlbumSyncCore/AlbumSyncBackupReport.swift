import Foundation
import UploadCore

public extension AlbumSyncBackupReport {
    /// Reads the current album scratch queue, including respected remote deletions.
    static func read(
        from queue: UploadBackupSyncQueueManifestStore, localIdentifiers: [String]
    ) throws -> AlbumSyncBackupReport {
        guard queue.isOperational() else { throw AlbumSyncError.mappingStoreUnavailable }
        let requested = Set(localIdentifiers)
        var summary = UploadBackupSyncQueueSummary()
        var problems: [String: BackupFailedItem] = [:]
        // Complete reads only: a photo missing from a cut-short problem list would count as fully backed up.
        let rows: [UploadBackupQueueRowState]
        do {
            try queue.decisionForEachProblemEntry { entry in
                if entry.source.kind == .photoLibraryAsset, requested.contains(entry.source.identifier),
                    problems[entry.source.identifier] == nil
                {
                    problems[entry.source.identifier] = BackupFailedItem(entry: entry)
                }
                return true
            }
            rows = try queue.decisionRows(kind: .photoLibraryAsset, identifiers: requested)
        } catch {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        var filenames: [String: String] = [:]
        for row in rows {
            summary.include(row.state)
            let id = row.source.identifier
            if row.state == .skippedRemoteDeletion,
                problems[id] == nil || row.source.resource == .primary
            {
                guard let entry = (try? queue.entry(for: row.source, revision: row.revision)) else {
                    throw AlbumSyncError.mappingStoreUnavailable
                }
                problems[id] = BackupFailedItem(entry: entry)
            }
            if !row.originalFilename.isEmpty, row.source.resource == .primary || filenames[id] == nil {
                filenames[id] = row.originalFilename
            }
        }
        guard queue.isOperational() else { throw AlbumSyncError.mappingStoreUnavailable }
        return AlbumSyncBackupReport(
            total: summary.total, backedUp: summary.resolved, failed: summary.failed,
            sourceMissing: summary.sourceMissing, skippedRemoteDeletion: summary.skippedRemoteDeletions,
            problems: problems, filenames: filenames)
    }
}
