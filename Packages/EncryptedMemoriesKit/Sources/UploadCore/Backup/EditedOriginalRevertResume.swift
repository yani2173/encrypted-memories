import Foundation

/// What one resume at app start did. A host logs it. The iOS host also refreshes the library when `finished` is above
/// zero; the Mac library follows the remote change events, so the Mac host only logs.
public struct EditedOriginalRevertResumeSummary: Sendable {
    /// Reverts whose trash and device steps finished now.
    public let finished: Int
    /// Reverts whose step failed. Their journals stay pending for the next start.
    public let failures: [any Error]
    /// Set when the journals could not be read, or the account shut down before the resume ran.
    public let readFailure: (any Error)?

    /// One line for the host log: the counts, and the kind of each error. A log can reach a support report, so the
    /// line never holds an error payload: a blocked draft names the person's file, and a file error names a path.
    public var logLine: String {
        var line = "revert: resumed trash steps finished=\(finished) failed=\(failures.count)"
        if !failures.isEmpty { line += " errors=" + failures.map(Self.kind).joined(separator: ",") }
        if let readFailure { line += " unread=" + Self.kind(readFailure) }
        return line
    }

    /// The case of a revert error, or the domain and code of any other error. Neither holds a payload.
    private static func kind(_ error: any Error) -> String {
        if let revertError = error as? EditedOriginalRevert.RevertError { return revertError.kind }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}

extension EditedOriginalRevert.RevertError {
    /// The case name without its payload.
    fileprivate var kind: String {
        switch self {
        case .editAlreadyRunning: "editAlreadyRunning"
        case .editAlreadyTrashed: "editAlreadyTrashed"
        case .copyNotConfirmed: "copyNotConfirmed"
        case .editNotTrashed: "editNotTrashed"
        case .blockedByForeignDraft: "blockedByForeignDraft"
        case .invalidRestoredName: "invalidRestoredName"
        case .originalMismatch: "originalMismatch"
        }
    }
}

extension EditedOriginalRevert {
    /// The resume that both hosts run at app start. It finishes only the trash and device steps of a confirmed copy
    /// (see `resumePending`) and never makes a copy, so it needs no tap of the person.
    public func resumeAndSummarize() async -> EditedOriginalRevertResumeSummary {
        do {
            let outcomes = try await resumePending()
            var finished = 0
            var failures: [any Error] = []
            for outcome in outcomes {
                switch outcome.result {
                case .success: finished += 1
                case .failure(let error): failures.append(error)
                }
            }
            return EditedOriginalRevertResumeSummary(finished: finished, failures: failures, readFailure: nil)
        } catch {
            return EditedOriginalRevertResumeSummary(finished: 0, failures: [], readFailure: error)
        }
    }
}

/// Runs the resume of one account at app start and owns its task. A host keeps one slot per account owner: a second
/// start cancels the first, so no resume runs twice at the same time, and `cancel()` ends a running resume.
/// The account shutdown gate also cancels and joins a resume that runs inside the revert, so a sign-out never waits
/// for the slot.
@MainActor
public final class EditedOriginalRevertResumeSlot {
    private var task: Task<Void, Never>?

    public init() {}

    /// Starts `resume` at utility priority and passes its summary to `report` unless the slot cancelled it first.
    public func start(
        resume: @escaping @Sendable () async -> EditedOriginalRevertResumeSummary,
        report: @escaping @MainActor (EditedOriginalRevertResumeSummary) -> Void
    ) {
        task?.cancel()
        task = Task(priority: .utility) {
            let summary = await resume()
            guard !Task.isCancelled else { return }
            report(summary)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
