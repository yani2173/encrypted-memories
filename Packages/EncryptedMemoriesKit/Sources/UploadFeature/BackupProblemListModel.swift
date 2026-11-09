import UploadCore

/// The shared states of the native backup problem sheets.
public enum BackupProblemListModel {
    /// What a sheet shows.
    public enum Presentation: Equatable, Sendable {
        case list
        case loading
        case unavailable
        /// Only this one says that nothing needs attention.
        case empty
    }
}

/// The sections of a backup problem list, in the order of `BackupIssueSection`.
public enum BackupProblemSection {
    public struct Group<Item>: Identifiable {
        public let id: BackupIssueSection
        public let items: [Item]
        public var title: String { id.localizedTitle }
    }

    public static func grouped<Item>(
        _ items: [Item], section: (Item) -> BackupIssueSection
    ) -> [Group<Item>] {
        BackupIssueSection.allCases.compactMap { category in
            let rows = items.filter { section($0) == category }
            return rows.isEmpty ? nil : Group(id: category, items: rows)
        }
    }
}

public extension BackupProblemListSession {
    func presentation(expectsItems: Bool) -> BackupProblemListModel.Presentation {
        if !rows.isEmpty { return .list }
        if isUnavailable { return .unavailable }
        if !hasRead || isReading { return .loading }
        return expectsItems ? .unavailable : .empty
    }
}
