import Foundation

@testable import UploadCore

// Short reads for assertions. Production code uses the `…Read` and `completeEffectResult` forms, which keep the
// "incomplete" and "failed" answers apart from "empty".

extension PendingBackupManifestStore {
    /// The handoffs of a complete reverse lookup; empty when the lookup is not complete.
    func handoffs(forRemoteLinkIDs linkIDs: [String]) -> [PendingHandoff] {
        guard case .complete(let handoffs) = handoffsRead(forRemoteLinkIDs: linkIDs) else { return [] }
        return handoffs
    }

    /// The rows that decode.
    func sourceStates() -> [PendingSourceState] {
        sourceStatesRead().states
    }

    /// Sources with an effect that is due by `date`.
    func dueSourceStates(by date: Date) -> [PendingSourceState] {
        dueSourceStatesRead(by: date).states
    }

    func dueActions(by date: Date) -> [PendingAction] {
        dueActionsRead(by: date).actions
    }

    /// True unless the completion failed.
    @discardableResult
    func completeEffect(
        _ effect: PendingSourceEffect,
        for key: PendingSourceKey,
        generation: Int64,
        remoteLinkID: String? = nil,
        at date: Date
    ) -> Bool {
        completeEffectResult(effect, for: key, generation: generation, remoteLinkID: remoteLinkID, at: date) != .failed
    }
}
