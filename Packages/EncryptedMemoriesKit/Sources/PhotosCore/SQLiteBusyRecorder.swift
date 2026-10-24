import Foundation
import SQLite3

/// A busy handler that waits like SQLite's own busy timeout and remembers that it gave up.
///
/// `sqlite3_busy_timeout` installs a handler that retries a locked statement with growing delays until the
/// timeout is used up, and then lets the statement fail with `SQLITE_BUSY`. This handler uses the same delays and
/// the same total, so a store waits no longer than before. It also records when the wait ended without success,
/// so the store can tell a lock that clears by itself from a file that is unusable. Installing it replaces the
/// timeout of the connection; `PRAGMA busy_timeout` and `sqlite3_busy_timeout` replace it again.
public final class SQLiteBusyRecorder: @unchecked Sendable {
    /// The delays of SQLite's default busy handler, in milliseconds, and the sum of the delays before each.
    private static let delays = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]
    private static let totals = [0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228]

    private let timeoutMs: Int
    private let sleep: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var gaveUpFlag = false

    /// `sleep` waits for the given milliseconds. Tests pass a clock that does not sleep.
    public init(timeoutMs: Int, sleep: @escaping @Sendable (Int) -> Void = { _ = sqlite3_sleep(Int32(clamping: $0)) }) {
        self.timeoutMs = timeoutMs
        self.sleep = sleep
    }

    /// True when a statement met a lock that did not clear within the timeout since the last `reset()`.
    public var gaveUp: Bool { lock.withLock { gaveUpFlag } }

    /// Forgets an earlier give-up. A store calls this when an operation starts.
    public func reset() {
        lock.withLock { gaveUpFlag = false }
    }

    /// Reads and forgets the give-up in one step.
    public func takeGaveUp() -> Bool {
        lock.withLock {
            defer { gaveUpFlag = false }
            return gaveUpFlag
        }
    }

    /// Makes `db` use this handler. The recorder must outlive the connection.
    public func install(on db: OpaquePointer?) {
        sqlite3_busy_handler(
            db,
            { context, count in
                guard let context else { return 0 }
                let recorder = Unmanaged<SQLiteBusyRecorder>.fromOpaque(context).takeUnretainedValue()
                return recorder.shouldRetry(afterAttempts: Int(count)) ? 1 : 0
            }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// One call of the busy handler. `attempts` counts the earlier calls for the same lock. Waits and returns true
    /// to retry; returns false when the timeout is used up.
    func shouldRetry(afterAttempts attempts: Int) -> Bool {
        let last = Self.delays.count - 1
        let delay: Int
        let waited: Int
        if attempts < Self.delays.count {
            delay = Self.delays[attempts]
            waited = Self.totals[attempts]
        } else {
            delay = Self.delays[last]
            waited = Self.totals[last] + delay * (attempts - last)
        }
        var pause = delay
        if waited + delay > timeoutMs {
            pause = timeoutMs - waited
            if pause <= 0 {
                lock.withLock { gaveUpFlag = true }
                return false
            }
        }
        sleep(pause)
        return true
    }
}
