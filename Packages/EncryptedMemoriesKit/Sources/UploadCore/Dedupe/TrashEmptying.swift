import Foundation
import PhotosCore

/// Removes pending-trash entries before guarded Proton emptying and commits only after success.
@MainActor public enum TrashEmptying {
    /// Only the mobile host deliberately passes a nil pending adapter when its pending session is missing.
    /// The macOS host never passes nil; its adapter returns false when its session is missing.
    /// A nil adapter silently skips pending removal. False stops the sequence with CancellationError.
    /// Merge context is read after pending removal, matching the mobile account lookup across that suspension.
    /// Only a merge-guard or Proton failure runs recovery; pending-removal failure does not reload the timeline.
    public static func empty(
        _ trash: any TrashProvider,
        pendingUIDs: [PhotoUID],
        removePending: (([PhotoUID]) async -> Bool)?,
        includesProtonTrash: Bool,
        checkingMergesWith duplicates: @autoclosure () -> (any ExactDuplicateMerging)?,
        accountDataDirectory: @autoclosure () -> URL?,
        commit: () -> Void,
        recoverFromTrashFailure: (any Error) async -> Void = { _ in }
    ) async throws {
        if !pendingUIDs.isEmpty, let removePending {
            guard await removePending(pendingUIDs) else { throw CancellationError() }
        }
        guard includesProtonTrash else { return }
        do {
            try await RecentlyDeletedEmptying.empty(
                trash, checkingMergesWith: duplicates(), accountDataDirectory: accountDataDirectory())
            commit()
        } catch {
            await recoverFromTrashFailure(error)
            throw error
        }
    }
}
