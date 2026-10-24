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
        queue.forEachProblemEntry { entry in
            if entry.source.kind == .photoLibraryAsset, requested.contains(entry.source.identifier),
                problems[entry.source.identifier] == nil
            {
                problems[entry.source.identifier] = BackupFailedItem(entry: entry)
            }
            return true
        }
        var filenames: [String: String] = [:]
        for row in queue.rows(kind: .photoLibraryAsset, identifiers: requested) {
            summary.include(row.state)
            let id = row.source.identifier
            if row.state == .skippedRemoteDeletion,
                problems[id] == nil || row.source.resource == .primary
            {
                guard let entry = queue.entry(for: row.source, revision: row.revision) else {
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
