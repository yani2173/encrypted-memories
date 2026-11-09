import Foundation

/// A read could not run, so its result is unknown: the connection is closed, a transaction is open, or the read
/// itself failed. A successful read with no row is absence, never this error (#1004).
///
/// With the recovering health probe (`SQLiteStoreConnection.isOperationalAfterTransientFailure()`), a reader that
/// answers nil, empty or false for such a read cannot be rechecked afterwards with `isOperational()`: the probe can
/// succeed and forget a transient failure while the failed answer is mistaken for data. Data-controlling readers
/// therefore throw this error instead of guessing. The sticky decode pins stay untouched: a row that decodes
/// wrongly is a lasting failure and keeps answering nil.
public struct SQLiteStoreUnknownReadError: Error, Equatable, Sendable {
    public init() {}
}
