import XCTest

enum ConfirmationDialogTestError: Error {
    case notHittable(String)
    case notAcknowledged(String)
}

extension XCUIApplication {
    /// Hosted snapshot stalls reached 19.3 s; allow several cycles for each dialog wait.
    static let dialogWaitTimeout: TimeInterval = 45

    /// The system dialog can list an action twice; wait for a hittable copy instead of using a hidden fallback.
    func hittableDialogButton(_ identifier: String) throws -> XCUIElement {
        let matches = buttons.matching(identifier: identifier)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in matches.allElementsBoundByIndex.contains { $0.isHittable } },
            object: nil
        )
        guard XCTWaiter.wait(for: [ready], timeout: Self.dialogWaitTimeout) == .completed,
            let button = matches.allElementsBoundByIndex.first(where: { $0.isHittable })
        else { throw ConfirmationDialogTestError.notHittable(identifier) }
        return button
    }

    /// One accessibility snapshot can lose presented sheets while the dialog stays visible (merge-queue run 38441899952).
    /// Only consecutive misses prove that the button is gone; the first sighting ends the check at once.
    /// The loop runs `checks` times at most, so it cannot wait without a limit.
    static func isConfirmedGone(
        exists: () -> Bool, checks: Int = 5, interval: TimeInterval = 1
    ) -> Bool {
        precondition(checks > 0, "At least one check must decide")
        for check in 0..<checks {
            if check > 0 { Thread.sleep(forTimeInterval: interval) }
            if exists() { return false }
        }
        return true
    }

    /// Closing the dialog acknowledges the decision. Repeat only a tap that the dialog did not acknowledge.
    func tapDialogButton(
        _ identifier: String, tap: (XCUIElement) -> Void = { $0.tap() }
    ) throws {
        let isGone = { Self.isConfirmedGone(exists: { self.buttons[identifier].firstMatch.exists }) }
        for attempt in 0..<2 {
            if attempt > 0, isGone() { return }
            tap(try hittableDialogButton(identifier))
            let acknowledged = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: buttons[identifier].firstMatch
            )
            // Allow several snapshot cycles before retrying input. One stale miss must not end the wait.
            if XCTWaiter.wait(for: [acknowledged], timeout: Self.dialogWaitTimeout) == .completed, isGone() { return }
        }
        throw ConfirmationDialogTestError.notAcknowledged(identifier)
    }
}
