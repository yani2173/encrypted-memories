/// What the Map says while the location index holds no place to draw. macOS and iOS show the same states: offline,
/// scanning with its counts, a failed scan, a finished scan without any geotagged photo, and a crawl that has not
/// started yet.
public enum MapEmptyState: Equatable, Sendable {
    case offline
    case scanning(scanned: Int, total: Int)
    case failed
    case completed
    case idle

    /// Only a failed scan can be tried again.
    public var offersRetry: Bool { self == .failed }
}
