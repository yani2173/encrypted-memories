import Foundation
import PhotosCore

/// The pending-request check of the iOS background host: asks the scheduler for the pending processing request
/// and submits one only when none is pending, so a short window never moves the next long one. When the scheduler
/// does not answer within the end-of-window limit, the request is submitted anyway: a moved long window is better
/// than none.
@MainActor
final class PhotoBackupProcessingRequestCheck {
    /// The request whose pending state the check asks the scheduler for.
    let identifier: String
    /// Asks the scheduler for the identifiers of its pending task requests.
    private let pendingIdentifiers: @Sendable () async -> [String]
    /// Ends the wait for the scheduler's answer; by default after `BackgroundTaskRequestSubmitter.endOfWindowWaitLimit`.
    private let answerDeadline: @Sendable () async -> Void
    /// Submits the processing request.
    private let submit: @MainActor () -> Void

    init(
        identifier: String = PhotoBackupBackgroundCoordinator.processingTaskIdentifier,
        pendingIdentifiers: @escaping @Sendable () async -> [String],
        answerDeadline: @escaping @Sendable () async -> Void = BackgroundTaskRequestSubmitter.defaultDeadline,
        submit: @escaping @MainActor () -> Void
    ) {
        self.identifier = identifier
        self.pendingIdentifiers = pendingIdentifiers
        self.answerDeadline = answerDeadline
        self.submit = submit
    }

    /// Runs the check: keeps a pending request and submits one only when none is pending.
    func run() async {
        let isPending = await BackgroundTaskRequestSubmitter.answer(of: pendingIdentifiers, deadline: answerDeadline)
            .map { $0.contains(identifier) }
        BackgroundWorkLog.system.notice(
            .photoBackup, "request.ensured",
            [
                (.init("kind"), .name(BackgroundWindowKind.photoBackup)),
                (.init("pending"), isPending.map { .flag($0) } ?? .word("unknown")),
            ])
        guard isPending != true else { return }
        submit()
    }
}
