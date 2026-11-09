/// Polls `condition` every `interval` until it holds or `timeout` has passed, and returns its last answer.
/// A false result is for the caller to judge.
func eventually(
    timeout: Duration, interval: Duration = .milliseconds(10), _ condition: () async -> Bool
) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}
