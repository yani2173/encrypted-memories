import Foundation

/// Request counts for a support report. They last since the latest construction of the backend (sign-in, launch or
/// a rebuild); a rebuild starts them again.
/// The report holds only route shapes, causes, status classes and counts. The route shape is a heuristic: a path word
/// is kept when it looks like a route word (3 to 32 lowercase letters, underscores or hyphens), so a token of that
/// shape inside a path segment would be kept.
public struct RemoteRequestSupportSnapshot: Codable, Sendable, Equatable {
    public struct Count: Codable, Sendable, Equatable {
        public let scope: String
        public let method: String
        /// Path with every identifier segment replaced by `{id}` and without the query.
        public let endpoint: String
        /// The work that sent the request. A leading `~` marks a cause inferred from the work that was active when a
        /// native SDK callback sent the request; `a+b` names several such works.
        public let cause: String
        /// `2xx`, `3xx`, `401`, `404`, `408`, `429`, `4xx`, `5xx`, `transport` (no HTTP answer) or `cancelled` (the
        /// caller stopped waiting, for example for a thumbnail that scrolled away).
        public let status: String
        public let count: Int

        public init(scope: String, method: String, endpoint: String, cause: String, status: String, count: Int) {
            self.scope = scope
            self.method = method
            self.endpoint = endpoint
            self.cause = cause
            self.status = status
            self.count = count
        }
    }

    public struct Scope: Codable, Sendable, Equatable {
        public let scope: String
        public let inFlight: Int
        public let queued: Int
        public let concurrencyLimit: Int
        public let admissionIntervalMilliseconds: Int
        public let admittedLastMinute: Int
        public let rateLimitedLastMinute: Int
        public let peakInFlight: Int
        /// The largest Retry-After a response asked for, before the governor's own bounds.
        public let maximumRetryAfterSeconds: Double?
        /// Time that rate-limit cooldowns closed admission, without double-counting overlapping cooldowns.
        public let totalCooldownSeconds: Double

        public init(
            scope: String, inFlight: Int, queued: Int, concurrencyLimit: Int, admissionIntervalMilliseconds: Int,
            admittedLastMinute: Int, rateLimitedLastMinute: Int, peakInFlight: Int,
            maximumRetryAfterSeconds: Double?, totalCooldownSeconds: Double
        ) {
            self.scope = scope
            self.inFlight = inFlight
            self.queued = queued
            self.concurrencyLimit = concurrencyLimit
            self.admissionIntervalMilliseconds = admissionIntervalMilliseconds
            self.admittedLastMinute = admittedLastMinute
            self.rateLimitedLastMinute = rateLimitedLastMinute
            self.peakInFlight = peakInFlight
            self.maximumRetryAfterSeconds = maximumRetryAfterSeconds
            self.totalCooldownSeconds = totalCooldownSeconds
        }
    }

    public let counts: [Count]
    /// Requests that arrived after the bounded key table was full; they are counted here only.
    public let overflowRequests: Int
    public let scopes: [Scope]

    public init(counts: [Count], overflowRequests: Int, scopes: [Scope]) {
        self.counts = counts
        self.overflowRequests = overflowRequests
        self.scopes = scopes
    }
}

public protocol RemoteRequestSupportSource: AnyObject, Sendable {
    func remoteRequestSupportSnapshot() async -> RemoteRequestSupportSnapshot
}
