import Foundation
import PhotosCore

/// Removes pending-trash entries after the merge check and commits only after Proton emptying succeeds.
@MainActor public enum TrashEmptying {
    private enum PendingRemovalFailed: Error { case failed }
    /// Only the mobile host deliberately passes a nil pending adapter when its pending session is missing.
    /// The macOS host never passes nil; its adapter returns false when its session is missing.
    /// A nil adapter silently skips pending removal. False stops the sequence with CancellationError.
    /// Only a merge-guard or Proton failure runs recovery; pending-removal failure does not reload the timeline.
    public static func empty(
        _ trash: any TrashProvider,
        pendingUIDs: [PhotoUID],
        removePending: (@MainActor ([PhotoUID]) async -> Bool)?,
        includesProtonTrash: Bool,
        checkingMergesWith duplicates: @autoclosure () -> (any ExactDuplicateMerging)?,
        accountDataDirectory: @autoclosure () -> URL?,
        commit: () -> Void,
        recoverFromTrashFailure: (any Error) async -> Void = { _ in }
    ) async throws {
        let removePendingItems: @MainActor () async throws -> Void = {
            if !pendingUIDs.isEmpty, let removePending {
                guard await removePending(pendingUIDs) else {
                    throw PendingRemovalFailed.failed
                }
            }
        }
        guard includesProtonTrash else {
            do { try await removePendingItems() } catch is PendingRemovalFailed { throw CancellationError() }
            return
        }
        do {
            try await RecentlyDeletedEmptying.empty(
                trash, checkingMergesWith: duplicates(), accountDataDirectory: accountDataDirectory(),
                beforeEmpty: removePendingItems)
            commit()
        } catch is PendingRemovalFailed {
            throw CancellationError()
        } catch {
            await recoverFromTrashFailure(error)
            throw error
        }
    }
}
