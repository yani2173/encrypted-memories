import XCTest

// Polling waits that several test files share. Each keeps the timeout, interval and failure style of the copies it
// replaces, and runs `condition` in the caller's isolation, as the private helpers did.

/// Polls `condition` every 5 ms until it holds or `timeout` has passed, and returns its last answer. A false result is
/// for the caller to judge, so a wait that must stay false can assert that it does.
func pollUntil(
    timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Polls `condition` every 5 ms for at most 5 s and returns without judging it. A cancelled task throws.
func pollWhileFalse(isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

/// Polls `condition` every millisecond, at most 2,000 times, then asserts it with `message`.
func assertEventually(
    _ condition: () -> Bool, _ message: String, isolation: isolated (any Actor)? = #isolation,
    file: StaticString = #filePath, line: UInt = #line
) async {
    for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    XCTAssertTrue(condition(), message, file: file, line: line)
}
