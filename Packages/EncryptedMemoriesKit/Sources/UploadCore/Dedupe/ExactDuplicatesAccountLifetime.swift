import Foundation
import PhotosCore

/// Retires account-owned merges and rejects results from an earlier account lifetime.
@MainActor
public final class ExactDuplicatesAccountLifetime {
    public struct Token: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private var token = Token(id: UUID())
    private weak var model: ExactDuplicatesModel?
    private var pendingMergeCheck: Task<Void, Never>?

    public init() {}

    /// Checks the merges that the end of the app left open, without a scan, for the account that the app installs, and
    /// ends the check of the previous account. Nil only ends that check, for example at sign-out. The apps call it once
    /// for each account change, because the Duplicates screen scans only when it opens; a replaced Duplicates model of
    /// the same account keeps the check running.
    @discardableResult
    public func checkPendingMerges(of finder: (any ExactDuplicateMerging)?) -> Task<Void, Never>? {
        pendingMergeCheck?.cancel()
        pendingMergeCheck = finder.map { finder in Task { await finder.resolvePendingMerges() } }
        return pendingMergeCheck
    }

    public func isCurrent(_ token: Token) -> Bool { self.token == token }

    /// Captures the account token before any merge work starts. A callback that suspends checks it again before
    /// publishing through `isCurrent(_:)`.
    public func replace(
        with finder: (any ExactDuplicateMerging)?,
        didTrash: @escaping @MainActor ([PhotoUID], Token) async -> Void = { _, _ in }
    ) -> ExactDuplicatesModel? {
        retire()
        guard let finder else { return nil }
        let token = self.token
        let next = ExactDuplicatesModel(finder: finder) { [weak self] trashed in
            guard let self, self.isCurrent(token) else { return }
            await didTrash(trashed, token)
        }
        model = next
        return next
    }

    /// Invalidates callbacks before waking a paused run. A running backend batch remains joined by its merge task.
    public func retire() {
        token = Token(id: UUID())
        model?.retire()
        model = nil
    }
}
