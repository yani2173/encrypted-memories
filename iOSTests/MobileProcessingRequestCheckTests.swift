import Foundation
import PhotosCore
import Testing

@testable import EncryptedMemoriesMobile

/// The pending-processing-request check that a refresh window runs before it submits a long-window request. The
/// scheduler double replaces the real `BGTaskScheduler`, which answers on no simulator, and the limit of the
/// answer wait is injected, so no test waits five real seconds.
@MainActor @Suite(.serialized) struct MobileProcessingRequestCheckTests {
    /// Answers on the main actor, where the tests read the counts; a scheduler that never answers holds its answer
    /// until the test releases it, like a real scheduler that stays silent.
    @MainActor private final class Scheduler {
        /// The pending identifiers that the scheduler reports; nil reports none.
        private let pending: [String]?
        private var heldAnswer: CheckedContinuation<[String], Never>?
        private(set) var queryCount = 0
        private(set) var submittedCount = 0

        init(pending: [String]?) { self.pending = pending }

        func identifiers() async -> [String] {
            queryCount += 1
            guard let pending else { return await withCheckedContinuation { heldAnswer = $0 } }
            return pending
        }

        func submit() { submittedCount += 1 }

        func releaseHeldAnswer() {
            heldAnswer?.resume(returning: [])
            heldAnswer = nil
        }
    }

    private func makeCheck(_ scheduler: Scheduler) -> PhotoBackupProcessingRequestCheck {
        PhotoBackupProcessingRequestCheck(
            pendingIdentifiers: { await scheduler.identifiers() },
            submit: { scheduler.submit() })
    }

    @Test func aPendingRequestStaysAndNothingNewIsSubmitted() async {
        let scheduler = Scheduler(pending: [PhotoBackupBackgroundCoordinator.processingTaskIdentifier])
        await makeCheck(scheduler).run()

        #expect(scheduler.queryCount == 1, "the scheduler was asked once for its pending requests")
        #expect(scheduler.submittedCount == 0, "the existing request stays and nothing new is submitted")
    }

    @Test func withoutAPendingRequestExactlyOneRequestIsSubmitted() async {
        let scheduler = Scheduler(pending: [])
        await makeCheck(scheduler).run()

        #expect(scheduler.queryCount == 1, "the scheduler was asked once for its pending requests")
        #expect(scheduler.submittedCount == 1, "one new request is submitted")
    }

    /// The answer wait ends at its injected limit, so the test does not sleep the real five seconds.
    @Test func aSchedulerThatDoesNotAnswerInTimeStillGetsARequest() async {
        let scheduler = Scheduler(pending: nil)
        let check = PhotoBackupProcessingRequestCheck(
            pendingIdentifiers: { await scheduler.identifiers() },
            answerDeadline: {},
            submit: { scheduler.submit() })
        defer { scheduler.releaseHeldAnswer() }

        await check.run()

        #expect(scheduler.submittedCount == 1, "the limit ended the wait, so a request is submitted anyway")
    }
}
