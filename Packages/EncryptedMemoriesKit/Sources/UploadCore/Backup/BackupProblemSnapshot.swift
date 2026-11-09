import Foundation

/// Metadata for one complete read. Paging never reads the store again.
public struct BackupProblemSnapshot: Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public enum ID: Hashable, Sendable {
            case decision(UploadSourceIdentity)
            case item(String)
        }
        public let id: ID
        public let item: BackupFailedItem
    }

    public struct Cursor: Equatable, Sendable {
        let snapshotID: UUID
        let offset: Int
    }

    public struct Page: Sendable {
        public let rows: [Row]
        public let next: Cursor?
    }

    public let id = UUID()
    public let rows: [Row]
    public let revisionsBySource: [UploadSourceIdentity: Set<UploadBackupRevision>]
    public let decisionIssue: BackupIssueKind
    public let decisionCount: Int

    public init(items: [BackupFailedItem], decisionIssue: BackupIssueKind = .deletedElsewhere) {
        let selection = BackupProblemPhotoSelection(items, decisionIssue: decisionIssue)
        self.decisionIssue = decisionIssue
        decisionCount = selection.items.filter { $0.issue == decisionIssue }.count
        revisionsBySource = selection.revisionsBySource
        rows = selection.items.map { item in
            let identity: Row.ID
            if item.issue == decisionIssue, let source = item.source {
                identity = .decision(source)
            } else {
                identity = .item(item.id)
            }
            return Row(id: identity, item: item)
        }
    }

    public static func album(items: [BackupFailedItem]) -> BackupProblemSnapshot? {
        let snapshot = BackupProblemSnapshot(items: items, decisionIssue: .remoteDeletion)
        guard Set(snapshot.rows.map(\.id)).count == snapshot.rows.count else { return nil }
        return snapshot
    }

    enum CaptureEvent: String { case willRead, didRead, willBuild, didBuild }

    public static func backup(in queue: UploadBackupSyncQueueManifestStore) -> BackupProblemSnapshot? {
        capture(in: queue, onEvent: nil)
    }

    static func capture(
        in queue: UploadBackupSyncQueueManifestStore,
        onEvent: ((CaptureEvent) -> Void)?
    ) -> BackupProblemSnapshot? {
        guard queue.isOperational() else { return nil }
        let categories: [BackupIssueCategory] = [.userResolvable, .decision, .automatic, .permanent]
        var decisions: [BackupFailedItem] = []
        var other: [BackupIssueCategory: [BackupFailedItem]] = [:]
        func collect(_ entry: UploadBackupSyncQueueEntry) {
            let item = BackupFailedItem(entry: entry)
            if item.issue == .deletedElsewhere {
                decisions.append(item)
            } else if other[item.category, default: []].count < 200 {
                other[item.category, default: []].append(item)
            }
        }
        onEvent?(.willRead)
        do {
            // A list that a failed read cut short is no snapshot: a bulk action would miss the rest (#1004 B2).
            try queue.decisionForEachProblemEntry { entry in
                #if canImport(ObjectiveC)
                    autoreleasepool { collect(entry) }
                #else
                    collect(entry)
                #endif
                return true
            }
        } catch {
            return nil
        }
        onEvent?(.didRead)
        guard queue.isOperational() else { return nil }
        onEvent?(.willBuild)
        defer { onEvent?(.didBuild) }
        var items = decisions + categories.flatMap { other[$0] ?? [] }.prefix(200)
        items.sort { lhs, rhs in
            let left = categories.firstIndex(of: lhs.category) ?? categories.count
            let right = categories.firstIndex(of: rhs.category) ?? categories.count
            if left != right { return left < right }
            if lhs.revision != rhs.revision {
                return (lhs.revision?.rawValue ?? Int64.min) > (rhs.revision?.rawValue ?? Int64.min)
            }
            return lhs.id < rhs.id
        }
        return BackupProblemSnapshot(items: items)
    }

    public func page(after cursor: Cursor? = nil, size: Int = 200) -> Page? {
        let offset = cursor?.offset ?? 0
        guard size > 0, offset >= 0, offset <= rows.count,
            cursor.map({ $0.snapshotID == id }) ?? true
        else { return nil }
        let end = offset + min(size, rows.count - offset)
        return Page(rows: Array(rows[offset..<end]), next: end < rows.count ? Cursor(snapshotID: id, offset: end) : nil)
    }
}
