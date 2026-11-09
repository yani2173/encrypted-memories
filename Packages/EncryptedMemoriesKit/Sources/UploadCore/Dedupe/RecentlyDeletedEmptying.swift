import Foundation
import PhotosCore

/// Protects the last copy of an unresolved duplicate group while Recently Deleted is emptied.
public enum RecentlyDeletedEmptying {
    public struct PendingMergeCheck: Error, Equatable {
        public enum Reason: Sendable, Equatable { case mergeWaits, journalUnreadable, unknown }
        public let reason: Reason
        public init(reason: Reason = .unknown) { self.reason = reason }
    }

    public static func empty(
        _ trash: any TrashProvider, checkingMergesWith duplicates: (any ExactDuplicateMerging)?,
        accountDataDirectory: URL?, beforeEmpty: @MainActor () async throws -> Void = {}
    ) async throws {
        let journal = accountDataDirectory.map(ExactDuplicateMergeJournalFileStore.init(accountDataDirectory:))
        func blocked() -> PendingMergeCheck {
            guard let journal else { return PendingMergeCheck() }
            if journal.cannotBeRead() { return PendingMergeCheck(reason: .journalUnreadable) }
            if let pending = journal.pendingMerges(), !pending.isEmpty {
                return PendingMergeCheck(reason: .mergeWaits)
            }
            return PendingMergeCheck()
        }
        if let duplicates {
            try await duplicates.excludingMerges {
                guard await duplicates.confirmNoPendingMerges() else { throw blocked() }
                try Task.checkCancellation()
                try await beforeEmpty()
                try Task.checkCancellation()
                try await trash.emptyTrash()
            }
            return
        }
        guard journal?.confirmsNoOpenMerge() ?? true else { throw blocked() }
        try Task.checkCancellation()
        try await beforeEmpty()
        try Task.checkCancellation()
        try await trash.emptyTrash()
    }

    public static func failureMessageKey(for error: any Error) -> String {
        switch (error as? PendingMergeCheck)?.reason {
        case .mergeWaits: "trash.empty_blocked_merge_message"
        case .journalUnreadable: "trash.empty_blocked_journal_message"
        case .unknown, nil: "trash.empty_failed_message"
        }
    }
}
