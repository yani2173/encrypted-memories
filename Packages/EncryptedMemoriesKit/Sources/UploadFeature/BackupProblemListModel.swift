import Observation
import UploadCore

/// Shared in-memory rows for the native backup sheets. Album sheets supply their live rows directly.
@MainActor
@Observable
public final class BackupProblemListModel {
    /// Where the list stands. It starts as `loading`, so a sheet never shows an answer that nobody read yet.
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        /// The list stayed empty after the bounded re-reads although the summary counts items.
        case unavailable
    }

    /// What a sheet shows.
    public enum Presentation: Equatable, Sendable {
        case list
        case loading
        case unavailable
        /// Only this one says that nothing needs attention.
        case empty
    }

    public private(set) var items: [BackupFailedItem] = []
    public private(set) var phase: Phase = .loading

    public init() {}

    public var sections: [BackupProblemSection] { BackupProblemSection.group(items) }

    /// `expectsItems` is whether the summary counts items. An empty list that the summary contradicts is no answer:
    /// the sheet keeps loading while the re-reads run and reports when they end empty.
    public func presentation(expectsItems: Bool) -> Presentation {
        if !items.isEmpty { return .list }
        switch phase {
        case .loading: return .loading
        case .unavailable: return .unavailable
        case .loaded: return expectsItems ? .loading : .empty
        }
    }

    public func replaceItems(_ items: [BackupFailedItem]) {
        self.items = items
        phase = .loaded
    }

    /// The bounded re-reads ended with an empty list while the summary counts items.
    public func markUnavailable() {
        phase = .unavailable
    }

    /// A new read starts for a list that was reported unavailable.
    public func beginReading() {
        if items.isEmpty { phase = .loading }
    }

    public func dismissItem(id: String) {
        items.removeAll { $0.id == id }
    }
}

public struct BackupProblemSection: Identifiable {
    public let id: BackupIssueSection
    public let items: [BackupFailedItem]
    public var title: String { id.localizedTitle }

    public static func group(_ items: [BackupFailedItem]) -> [Self] {
        BackupIssueSection.allCases.compactMap { section in
            let rows = items.filter { $0.category.section == section }
            return rows.isEmpty ? nil : Self(id: section, items: rows)
        }
    }
}
