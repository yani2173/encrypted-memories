import Foundation
import PhotosCore

/// The one way both apps empty Recently Deleted. A duplicate merge that waits for its check can have left the last copy
/// of a group in the trash, so the trash is emptied only after every open merge is checked.
public enum RecentlyDeletedEmptying {
    /// Thrown when an open merge could not be checked. Nothing was deleted; a later attempt checks again.
    public struct PendingMergeCheck: Error, Equatable {}

    /// `accountDataDirectory` holds the merge journal. Without a merger, for example when the account's upload stores
    /// did not open, the journal is read directly: an earlier session can have left a merge open in it.
    public static func empty(
        _ trash: any TrashProvider, checkingMergesWith duplicates: (any ExactDuplicateMerging)?,
        accountDataDirectory: URL?
    ) async throws {
        if let duplicates {
            // A merge that trashed its copies after the check and before the emptying would lose them for good.
            try await duplicates.excludingMerges {
                guard await duplicates.confirmNoPendingMerges() else { throw PendingMergeCheck() }
                try await trash.emptyTrash()
            }
            return
        }
        let noOpenMerge: Bool
        if let accountDataDirectory {
            noOpenMerge = ExactDuplicateMergeJournalFileStore(accountDataDirectory: accountDataDirectory)
                .confirmsNoOpenMerge()
        } else {
            noOpenMerge = true
        }
        guard noOpenMerge else { throw PendingMergeCheck() }
        try await trash.emptyTrash()
    }
}
