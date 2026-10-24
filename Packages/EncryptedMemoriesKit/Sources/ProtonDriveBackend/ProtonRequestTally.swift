import Foundation
import PhotosCore

/// Code-owned names of the work that sends Proton requests. The names enter support reports and logs.
enum ProtonRequestCause: String, CaseIterable, Sendable {
    case timelineFull = "timeline.full"
    case timelineProbe = "timeline.probe"
    case timelineValidation = "timeline.validation"
    case timelineFilter = "timeline.filter"
    case reconcile
    case thumbnails
    case viewer
    case viewerMetadata = "viewer.metadata"
    /// The lookup of the hidden original of an edited photo in the viewer.
    case viewerOriginal = "viewer.original"
    case export
    case favorites
    case trashList = "trash.list"
    case trashWrite = "trash.write"
    case account
    case backup
    /// Reads of the Duplicates screen: its content index build, the ranking node reads and the merge plan.
    case duplicatesRead = "duplicates.read"
    /// Trash and restore of a duplicate merge.
    case duplicatesMerge = "duplicates.merge"
    case series
    case albums
    case librarySave = "library.save"
    case tags
    /// Shared reads and favorite writes that keep a photo's albums and favorite state when another copy replaces
    /// it: series dissolution, duplicate merge and edit replacement all use them.
    case carryOver = "carryover"
    case photosRoot = "photos.root"
    /// The one-time read of the file names that search matches.
    case photoNames = "photo.names"
    /// Session-gated work that normally reads only local stores.
    case local
}

/// Method and endpoint template of one request. The template keeps only path words that have the shape of a route word
/// (see `isFixedWord`); the host, the query and the fragment are dropped.
struct ProtonRequestLabel: Sendable, Equatable {
    static let storageEndpoint = "<storage>"
    static let maximumSegments = 8

    let method: String
    let endpoint: String

    static func api(method: String, path: String) -> ProtonRequestLabel {
        var rest = Substring(path)
        // An input with a scheme is a full URL: its host is not part of the route.
        if let marker = rest.range(of: "://"), isScheme(rest[..<marker.lowerBound]) {
            let afterScheme = rest[marker.upperBound...]
            rest = afterScheme.firstIndex(where: { "/?#".contains($0) }).map { afterScheme[$0...] } ?? ""
        }
        // The query and the fragment are not part of the route, whatever they contain.
        let pathOnly = rest.prefix { $0 != "?" && $0 != "#" }
        let segments = pathOnly.split(separator: "/").prefix(maximumSegments).map {
            isFixedWord($0) ? String($0) : "{id}"
        }
        return ProtonRequestLabel(method: normalizedMethod(method), endpoint: "/" + segments.joined(separator: "/"))
    }

    /// Block storage URLs are pre-signed or token-addressed, so no part of them is recorded.
    static func storage(method: String) -> ProtonRequestLabel {
        ProtonRequestLabel(method: normalizedMethod(method), endpoint: storageEndpoint)
    }

    /// A URL scheme: an ASCII letter, then ASCII letters, digits, `+`, `-` or `.`.
    private static func isScheme(_ value: Substring) -> Bool {
        guard let first = value.unicodeScalars.first, ("a"..."z").contains(first) || ("A"..."Z").contains(first) else {
            return false
        }
        let punctuation = "+-.".unicodeScalars
        return value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || punctuation.contains($0)
        }
    }

    /// A path word is kept when it has the shape of a route word: 3 to 32 ASCII lowercase letters, underscores or
    /// hyphens, or a version such as `v4`. Identifiers carry digits or capitals and become `{id}`. This is a shape
    /// rule, a heuristic and not a list: a lowercase-only token of that length in a path segment would be kept.
    /// Proton identifiers are mixed-case base64 or hex with digits, and every route word of the app and the SDK core
    /// is a fixed lowercase word.
    static func isFixedWord(_ segment: Substring) -> Bool {
        // Unicode scalars, not Characters: a letter with a combining mark would compare as a lowercase letter.
        let scalars = segment.unicodeScalars
        if (2...4).contains(scalars.count), scalars.first == "v",
            scalars.dropFirst().allSatisfy({ ("0"..."9").contains($0) })
        {
            return true
        }
        guard (3...32).contains(scalars.count) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" || $0 == "-" }
    }

    private static func normalizedMethod(_ method: String) -> String {
        let value = method.uppercased()
        return ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(value) ? value : "OTHER"
    }
}

enum ProtonRequestStatusClass: String, Sendable {
    /// A thrown cancellation, either Swift's or the one URLSession reports for a cancelled task.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    case success = "2xx"
    case redirect = "3xx"
    case unauthorized = "401"
    case notFound = "404"
    case timeout = "408"
    case rateLimited = "429"
    case clientError = "4xx"
    case serverError = "5xx"
    case transport
    /// The caller cancelled the request, for example a thumbnail that scrolled away. Not a network failure.
    case cancelled

    init(statusCode: Int?, cancelled: Bool = false) {
        switch statusCode {
        case nil: self = cancelled ? .cancelled : .transport
        case 401: self = .unauthorized
        case 404: self = .notFound
        case 408: self = .timeout
        case 429: self = .rateLimited
        case let code? where (200...299).contains(code): self = .success
        case let code? where (300...399).contains(code): self = .redirect
        case let code? where (400...499).contains(code): self = .clientError
        case let code? where (500...599).contains(code): self = .serverError
        default: self = .transport
        }
    }
}

/// Tracks which works run right now. A native SDK callback starts its request in a new task without the caller's
/// task-local values, so its cause can only be inferred from this set.
final class ProtonRequestCauseScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: ProtonRequestCause] = [:]

    /// Runs `operation` under `cause`. An enclosing cause wins unless `replacing` is set, so a duplicate merge that
    /// trashes photos stays a duplicates request. Work that starts its own unstructured task replaces the cause it
    /// inherited from the scheduling caller.
    func run<T>(
        _ cause: ProtonRequestCause,
        replacing: Bool = false,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        let effective = replacing ? cause : (ProtonRequestContext.cause ?? cause)
        let id = UUID()
        // Local work sends no request, so it must not take part in inferring the cause of a callback request.
        if effective != .local { lock.withLock { active[id] = effective } }
        defer { _ = lock.withLock { active.removeValue(forKey: id) } }
        return try await ProtonRequestContext.$cause.withValue(effective) {
            try await operation()
        }
    }

    /// The exact task-local cause, or the inferred active causes marked with `~`.
    func resolve(taskCause: ProtonRequestCause?) -> String {
        if let taskCause { return taskCause.rawValue }
        let names = Set(lock.withLock { active.values }.map(\.rawValue)).sorted()
        guard !names.isEmpty else { return "unattributed" }
        let shown = names.prefix(3).joined(separator: "+")
        return "~" + shown + (names.count > 3 ? "+more" : "")
    }
}

/// The cause that a service names for its own requests. Services outside `DriveSDKBridge` actor isolation run their
/// requests through their own shutdown admission, so they open the scope there. An enclosing cause still wins.
struct ProtonRequestCauseBinding: Sendable {
    let scopes: ProtonRequestCauseScopes
    let cause: ProtonRequestCause

    func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await scopes.run(cause, operation: operation)
    }
}

/// Request counts kept by the governor. They last since the latest construction of the backend; a rebuild starts them
/// again. The keys hold causes, status classes and endpoint templates made of route shapes (see
/// `ProtonRequestLabel.isFixedWord` for the limit of that rule).
struct ProtonRequestTally: Sendable {
    struct Key: Hashable, Sendable {
        let scope: ProtonRequestScope
        let method: String
        let endpoint: String
        let cause: String
        let status: ProtonRequestStatusClass
    }

    struct ScopeTotals: Sendable {
        var peakInFlight = 0
        var maximumRetryAfter: TimeInterval?
        var cooldownSeconds: TimeInterval = 0
    }

    static let maximumKeys = 512
    static let summaryInterval: TimeInterval = 60

    private(set) var counts: [Key: Int] = [:]
    private(set) var overflowRequests = 0
    private(set) var scopes: [ProtonRequestScope: ScopeTotals] = [:]
    private var summaryStart: Date?
    private var summaryCauses: [String: Int] = [:]
    private var summaryStatuses: [ProtonRequestStatusClass: Int] = [:]

    mutating func record(_ key: Key, at timestamp: Date) -> [String: String]? {
        if counts[key] != nil || counts.count < Self.maximumKeys {
            counts[key, default: 0] += 1
        } else {
            overflowRequests += 1
        }
        let summary = dueSummary(at: timestamp)
        if summaryStart == nil { summaryStart = timestamp }
        summaryCauses[key.cause, default: 0] += 1
        summaryStatuses[key.status, default: 0] += 1
        return summary
    }

    mutating func recordInFlight(_ inFlight: Int, scope: ProtonRequestScope) {
        scopes[scope, default: ScopeTotals()].peakInFlight = max(scopes[scope]?.peakInFlight ?? 0, inFlight)
    }

    mutating func recordRateLimit(
        scope: ProtonRequestScope, retryAfter: TimeInterval?, cooldownFrom start: Date, until end: Date
    ) {
        var totals = scopes[scope] ?? ScopeTotals()
        // A malformed header can parse as infinity, which a JSON report cannot hold; a negative wait means nothing.
        if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
            totals.maximumRetryAfter = max(totals.maximumRetryAfter ?? 0, retryAfter)
        }
        totals.cooldownSeconds += max(0, end.timeIntervalSince(start))
        scopes[scope] = totals
    }

    /// At most one line per minute, written by the first request after the window: the requests of the window by cause
    /// and status class. An idle app writes no line, so no timer wakes it.
    private mutating func dueSummary(at timestamp: Date) -> [String: String]? {
        guard let start = summaryStart, timestamp.timeIntervalSince(start) >= Self.summaryInterval else { return nil }
        let total = summaryCauses.values.reduce(0, +)
        // The line is written by the first request after the minute, so it states the real window length.
        var fields = ["requests": "\(total)", "windowSeconds": "\(Int(timestamp.timeIntervalSince(start)))"]
        fields["causes"] = summaryCauses.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        fields["statuses"] = summaryStatuses.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
        summaryStart = nil
        summaryCauses.removeAll()
        summaryStatuses.removeAll()
        return fields
    }
}

extension ProtonRequestScope {
    var supportName: String {
        switch self {
        case .api: "api"
        case .storageDownload: "storageDownload"
        case .storageUpload: "storageUpload"
        }
    }
}
