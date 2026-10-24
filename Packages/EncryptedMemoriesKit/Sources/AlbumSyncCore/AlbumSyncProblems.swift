import Foundation
import PhotosCore
import UploadCore

/// Builds the per-photo list behind an album row's "not in the album" count. It reuses the backup's
/// `BackupFailedItem`, so both native hosts show it with the shared problem sheet.
public enum AlbumSyncProblemList {
    /// The id prefix of a photo that is in the Proton album while its backup is not complete. The last-run file
    /// keeps item ids, so the album row can tell these photos from photos that are not in the album.
    public static let incompleteIDPrefix = "album-incomplete/"

    /// One item for each photo without a usable remote link, one for each failed attach and one for each photo
    /// in the album whose backup is not complete.
    /// - Parameters:
    ///   - missingIdentifiers: Local identifiers without a usable remote link after the backup step.
    ///   - attachFailedIdentifiers: Local identifiers whose remote photo could not be attached.
    ///   - incompleteIdentifiers: Local identifiers with a usable remote link whose backup row is unresolved.
    ///   - backup: The backup step's report with its unresolved rows and filenames.
    public static func items(
        missingIdentifiers: [String],
        attachFailedIdentifiers: [String],
        incompleteIdentifiers: [String] = [],
        trashedIdentifiers: [String] = [],
        backup: AlbumSyncBackupReport
    ) -> [BackupFailedItem] {
        var items: [BackupFailedItem] = []
        items.reserveCapacity(missingIdentifiers.count + attachFailedIdentifiers.count + incompleteIdentifiers.count)
        // First, so that the list limit of the last-run store never cuts the photos that decide the row text.
        for identifier in incompleteIdentifiers {
            // The backup row names the reason. Without one, the photo is not incomplete.
            guard let problem = backup.problems[identifier] else { continue }
            items.append(albumItem(from: problem, id: incompleteIDPrefix + identifier))
        }
        for identifier in missingIdentifiers {
            if let problem = backup.problems[identifier] {
                items.append(albumItem(from: problem))
            } else {
                items.append(
                    albumOnlyItem(
                        identifier: identifier, filename: backup.filenames[identifier],
                        reason: L10n.string("albumsync.issue_not_backed_up")))
            }
        }
        for identifier in trashedIdentifiers {
            items.append(remoteDeletionItem(identifier: identifier, backup: backup))
        }
        for identifier in attachFailedIdentifiers {
            items.append(
                albumOnlyItem(
                    identifier: identifier, filename: backup.filenames[identifier],
                    reason: L10n.string("albumsync.issue_attach_failed")))
        }
        return items
    }

    static func remoteDeletionItem(identifier: String, backup: AlbumSyncBackupReport) -> BackupFailedItem {
        if let problem = backup.problems[identifier], problem.issue == .remoteDeletion {
            return albumItem(from: problem)
        }
        return BackupFailedItem(
            id: "album/\(identifier)",
            filename: backup.filenames[identifier] ?? L10n.string("albumsync.issue_photo_fallback"),
            reason: L10n.string("backup.state_skipped_remote_deletion"), isPermanent: false,
            issue: .remoteDeletion, isRetryable: false,
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier))
    }

    /// The album scratch queue runs only on Sync now. A backup wait therefore does not continue by
    /// itself here: the row's Sync now is the retry, and no retry date applies.
    static func albumItem(from item: BackupFailedItem, id: String? = nil) -> BackupFailedItem {
        BackupFailedItem(
            id: id ?? item.id, filename: item.filename, reason: item.reason, isPermanent: item.isPermanent,
            issue: item.issue, nextAttemptAt: nil, isRetryable: item.isRetryable, source: item.source,
            revision: item.revision,
            category: item.category == .automatic ? .userResolvable : item.category,
            technicalDetail: item.technicalDetail)
    }

    private static func albumOnlyItem(identifier: String, filename: String?, reason: String) -> BackupFailedItem {
        BackupFailedItem(
            id: "album/\(identifier)",
            filename: filename.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("albumsync.issue_photo_fallback"),
            reason: reason, isPermanent: false, issue: .unknown, isRetryable: true,
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier, resource: .primary),
            category: .userResolvable)
    }
}

/// The last finished run's per-photo list for each album. It keeps the lists in memory and in
/// `album-sync-last-run-v1.json`, so a list survives a relaunch. The file is a rebuildable cache:
/// a missing or unreadable file means empty lists, and the next sync of an album rewrites its list.
/// Reasons are stored as localized text, so a language change applies after the next sync.
/// The lists live on the main actor; the file is read and written off it, in the order of the changes.
@MainActor
public final class AlbumSyncLastRunStore {
    public static let fileName = "album-sync-last-run-v1.json"
    /// The most photos one album keeps, as in the backup's own list; the row count stays exact.
    public static let itemLimit = 200

    private let file: AlbumSyncLastRunFile
    private var lists: [String: [BackupFailedItem]] = [:]
    /// Albums that a run of this launch recorded; the file never overrides them.
    private var recorded: Set<String> = []
    /// A write before the load would replace the file without the albums that only the file knows.
    private var isLoaded = false
    private var lastWrite: Task<Void, Never>?

    public init(directory: URL) {
        file = AlbumSyncLastRunFile(url: directory.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    /// Reads the file once. A list that a run recorded meanwhile wins, and the file then gets it.
    public func load() async {
        guard !isLoaded else { return }
        let stored = await file.read()
        guard !isLoaded else { return }
        for (albumID, items) in stored where !recorded.contains(albumID) {
            lists[albumID] = items
        }
        isLoaded = true
        if recorded.contains(where: { lists[$0] != stored[$0] }) { writeLists() }
    }

    /// The last run's list for one album; empty when the album has none.
    public func items(albumID: String) -> [BackupFailedItem] {
        lists[albumID] ?? []
    }

    /// Replaces one album's list after a finished run. An empty list clears it.
    public func record(_ items: [BackupFailedItem], albumID: String) {
        let kept = Array(items.prefix(Self.itemLimit))
        recorded.insert(albumID)
        guard kept != (lists[albumID] ?? []) else { return }
        lists[albumID] = kept.isEmpty ? nil : kept
        if isLoaded { writeLists() }
    }

    private func writeLists() {
        let snapshot = lists
        let previous = lastWrite
        lastWrite = Task { [file] in
            await previous?.value
            await file.write(snapshot)
        }
    }

    /// Waits until every recorded change is in the file.
    public func flush() async {
        await lastWrite?.value
    }
}

/// The file behind `AlbumSyncLastRunStore`, read and written off the main actor.
actor AlbumSyncLastRunFile {
    private struct StoredItem: Codable, Equatable {
        var id: String
        var filename: String
        var reason: String
        var category: String
        var issue: BackupIssueKind
        var isPermanent: Bool
        var isRetryable: Bool
    }

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func read() -> [String: [BackupFailedItem]] {
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([String: [StoredItem]].self, from: data)
        else { return [:] }
        return stored.filter { !$0.value.isEmpty }.mapValues { items in
            items.map { item in
                // An unknown category falls back to the issue's own category.
                BackupFailedItem(
                    id: item.id, filename: item.filename, reason: item.reason, isPermanent: item.isPermanent,
                    issue: item.issue, isRetryable: item.isRetryable,
                    category: BackupIssueCategory(rawValue: item.category))
            }
        }
    }

    /// A failed write leaves the previous file; the next finished run writes again.
    func write(_ lists: [String: [BackupFailedItem]]) {
        let stored = lists.mapValues { items in
            items.map { item in
                StoredItem(
                    id: item.id, filename: item.filename, reason: item.reason,
                    category: item.category.rawValue, issue: item.issue, isPermanent: item.isPermanent,
                    isRetryable: item.isRetryable)
            }
        }
        if stored.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? JSONEncoder().encode(stored).write(to: url, options: .atomic)
        }
    }
}
