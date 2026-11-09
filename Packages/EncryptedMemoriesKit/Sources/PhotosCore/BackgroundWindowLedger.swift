import Foundation

/// The OS background task that delivered a window.
public enum BackgroundWindowKind: String, Codable, Sendable, CaseIterable, Comparable, BackgroundLogName {
    case photoBackup
    case smartSearch
    /// The short app refresh task that only scans the photo library for the backup.
    case libraryRefresh

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How a background window ended.
public enum BackgroundWindowOutcome: String, Codable, Sendable, CaseIterable, Comparable, BackgroundLogName {
    /// The window did its work.
    case ran
    /// The window could not read the sign-in on a locked device and ended at once.
    case endedAtOnceLocked
    /// No account was signed in.
    case noAccount
    /// The window had no usable network path.
    case noNetwork
    /// The OS ended the window before its work ended.
    case expired
    /// Anything else.
    case failed
    /// The window found nothing to do: the feature was off or paused.
    case notNeeded
    /// The window's end was never recorded: it still runs, or its process ended first. Only the ledger writes it, for a
    /// window that has started; a handler never ends a window with it.
    case unfinished

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The window did its work or had none to do. The OS hears success only then.
    public var reportsSuccess: Bool { self == .ran || self == .notNeeded }

    /// The end of a window whose work started. An expiry decides first: a window that expired never counts as a run.
    public static func afterWork(didExpire: Bool, didComplete: Bool) -> Self {
        if didExpire { return .expired }
        return didComplete ? .ran : .failed
    }

    /// The end of a window whose work started. A pass that waited for the first network path until the window ended
    /// records that, also when the window expired.
    public static func afterWork(didExpire: Bool, didComplete: Bool, waitedForNetwork: Bool) -> Self {
        waitedForNetwork ? .noNetwork : afterWork(didExpire: didExpire, didComplete: didComplete)
    }

    /// The outcome once the end's wait for the requests returned: a window that expired during that wait is recorded as
    /// expired, not as a run. Other outcomes stay.
    public func afterTheEndWait(didExpire: Bool) -> Self {
        didExpire && (self == .ran || self == .notNeeded) ? .expired : self
    }
}

/// One background window: its kind, how it ended, and its start rounded down to the minute. The record holds nothing
/// else, so it can never name an account, a photo, a path or an error.
public struct BackgroundWindowRecord: Codable, Sendable, Equatable {
    public let kind: BackgroundWindowKind
    public let outcome: BackgroundWindowOutcome
    public let startedAt: Date

    /// Rounds `startedAt` down to the minute.
    public init(kind: BackgroundWindowKind, outcome: BackgroundWindowOutcome, startedAt: Date) {
        self.kind = kind
        self.outcome = outcome
        self.startedAt = Date(timeIntervalSince1970: (startedAt.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

/// The background-window section of the support report.
public struct BackgroundWindowSupportSnapshot: Codable, Sendable, Equatable {
    public struct Count: Codable, Sendable, Equatable {
        public let kind: BackgroundWindowKind
        public let outcome: BackgroundWindowOutcome
        public let count: Int

        public init(kind: BackgroundWindowKind, outcome: BackgroundWindowOutcome, count: Int) {
            self.kind = kind
            self.outcome = outcome
            self.count = count
        }
    }

    /// One entry for each kind and outcome that occurs, sorted by kind and then outcome.
    public let counts: [Count]
    /// The kept records, oldest first.
    public let records: [BackgroundWindowRecord]
}

/// A started window, as `BackgroundWindowLedger.begin` returns it for `end`. It ends once: a second end writes nothing.
public final class BackgroundWindowStart: @unchecked Sendable {
    /// The unfinished record that the end replaces.
    public let record: BackgroundWindowRecord
    /// The sign-out purge generation of the start; nil when the start wrote nothing. Such a window writes nothing at its
    /// end either.
    let purgeGeneration: Int?
    /// Guarded by the ledger lock.
    fileprivate var didEnd = false
    /// The device log has the end of this window. Guarded by the ledger lock.
    fileprivate var didLogEnd = false

    fileprivate init(record: BackgroundWindowRecord, purgeGeneration: Int?) {
        self.record = record
        self.purgeGeneration = purgeGeneration
    }
}

/// The last background windows of this device, kept in one small file. A night window's record must outlive the
/// process, which iOS ends after the window; the in-memory diagnostics cannot do that. Only the iOS background tasks
/// record windows; macOS records none.
///
/// The file has no file protection, so a window before the first unlock after a restart can record too. It holds only
/// kinds, outcomes and minutes. It lies in the local data that sign-out removes. A file that cannot be read or written
/// only skips a record; it never changes a window.
///
/// Records are in the order in which their windows ended, oldest first. A window that never ended, because its process
/// ended first, keeps the place of its start as an unfinished record. The limit drops the oldest records first in this
/// order.
///
/// Unfinished records of one kind and minute look alike. To end the right one, the ledger keeps the order of this
/// process's open windows in memory: a window's record is the matching unfinished record that comes before the records
/// of the alike windows that started after it. Unfinished records of earlier processes come before all of them.
///
/// A sign-out purge removes the file. A window that started before the purge was requested, or while it was pending,
/// writes nothing afterwards, so it cannot bring the file back.
public final class BackgroundWindowLedger: @unchecked Sendable {
    public static let limit = 200
    public static let defaultFileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("EncryptedMemories/background-windows-v1.json", isDirectory: false)
    public static let shared = BackgroundWindowLedger(fileURL: defaultFileURL)
    /// No file protection, so a window before the first unlock after a restart can write its record.
    static let fileWriteOptions: Data.WritingOptions = [.atomic, .noFileProtection]
    /// Counts the damaged files that the ledger replaced with an empty one.
    static let resetCounterKey = "backgroundWindows.ledgerReset"

    private struct File: Codable {
        var records: [BackgroundWindowRecord]
    }

    /// One lock for every ledger file and for the purge generation. A write checks the generation and writes under it,
    /// and a sign-out purge request advances the generation under it, so no request can come between check and write.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var purgeGeneration = 0
    private let fileURL: URL?
    /// This process's started windows that have not ended, in the order of their starts. Guarded by the lock.
    private var openStarts: [BackgroundWindowStart] = []
    private let diagnostics: PhotoDiagnostics
    private let isPurgePending: @Sendable () -> Bool
    private let log: BackgroundWorkLog

    public init(
        fileURL: URL?,
        diagnostics: PhotoDiagnostics = .shared,
        isPurgePending: @escaping @Sendable () -> Bool = { BackupLocalDataPurge.isPurgePending() },
        log: BackgroundWorkLog = .system
    ) {
        self.fileURL = fileURL
        self.diagnostics = diagnostics
        self.isPurgePending = isPurgePending
        self.log = log
    }

    /// A sign-out purge was requested: windows that started before write nothing more.
    static func signOutPurgeWasRequested() {
        lock.withLock { purgeGeneration += 1 }
    }

    /// Records a window that has just started, and returns its start for `end(_:with:)`. Until then the record says
    /// `unfinished`: a process that iOS ends during the window leaves exactly that.
    public func begin(_ kind: BackgroundWindowKind, at date: Date = Date()) -> BackgroundWindowStart {
        let started = BackgroundWindowRecord(kind: kind, outcome: .unfinished, startedAt: date)
        log.notice(BackgroundWorkLog.category(for: kind), "window.began", [(.init("kind"), .name(kind))])
        return Self.lock.withLock {
            let generation = updateLocked(startedIn: nil) { $0.append(started) }
            let start = BackgroundWindowStart(record: started, purgeGeneration: generation)
            if generation != nil { openStarts.append(start) }
            return start
        }
    }

    /// Moves the record of a started window to the end, with its outcome. A start that the ledger no longer holds gets
    /// a new record. A second end of the same start writes nothing.
    public func end(_ start: BackgroundWindowStart, with outcome: BackgroundWindowOutcome) {
        let ended = BackgroundWindowRecord(kind: start.record.kind, outcome: outcome, startedAt: start.record.startedAt)
        // A window that the ledger cannot record still logs its end once.
        let isFirstEnd = Self.lock.withLock {
            let isFirstEnd = !start.didLogEnd
            start.didLogEnd = true
            guard !start.didEnd, let generation = start.purgeGeneration else { return isFirstEnd }
            start.didEnd = true
            let index = openStarts.firstIndex { $0 === start }
            // The alike windows that started later and are still open own the last alike unfinished records.
            let laterAlike = index.map { openStarts[($0 + 1)...].filter { $0.record == start.record }.count } ?? 0
            if let index { openStarts.remove(at: index) }
            updateLocked(startedIn: generation) { records in
                let alike = records.indices.filter { records[$0] == start.record }
                if alike.count > laterAlike { records.remove(at: alike[alike.count - 1 - laterAlike]) }
                records.append(ended)
            }
            return isFirstEnd
        }
        guard isFirstEnd else { return }
        log.notice(
            BackgroundWorkLog.category(for: ended.kind), "window.ended",
            [(.init("kind"), .name(ended.kind)), (.init("outcome"), .name(outcome))])
    }

    /// The kept records, oldest first.
    public func records() -> [BackgroundWindowRecord] {
        guard let fileURL else { return [] }
        return Self.lock.withLock { load(fileURL, replacesDamagedFile: false) ?? [] }
    }

    public func supportSnapshot() -> BackgroundWindowSupportSnapshot {
        let records = records()
        var counts: [BackgroundWindowKind: [BackgroundWindowOutcome: Int]] = [:]
        for record in records {
            counts[record.kind, default: [:]][record.outcome, default: 0] += 1
        }
        return BackgroundWindowSupportSnapshot(
            counts: counts.keys.sorted().flatMap { kind in
                counts[kind, default: [:]].sorted { $0.key < $1.key }.map {
                    BackgroundWindowSupportSnapshot.Count(kind: kind, outcome: $0.key, count: $0.value)
                }
            },
            records: records)
    }

    /// Changes the stored records and returns the purge generation of the write, or nil when nothing was written.
    /// `generation` is the generation of the window's start; nil for a start. The caller holds the lock: the checks and
    /// the write happen inside the one critical section that a sign-out request also takes.
    @discardableResult
    private func updateLocked(
        startedIn generation: Int?, _ change: (inout [BackgroundWindowRecord]) -> Void
    ) -> Int? {
        guard let fileURL else { return nil }
        // A sign-out purge removes this file with the other local data; a window must not bring it back.
        guard !isPurgePending() else { return nil }
        guard generation == nil || generation == Self.purgeGeneration else { return nil }
        guard var records = load(fileURL, replacesDamagedFile: true) else { return nil }
        change(&records)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        return write(records, to: fileURL) ? Self.purgeGeneration : nil
    }

    /// The stored records; empty for a missing file, and for a damaged file when the caller replaces it. Nil when the
    /// file cannot be read: its content is not known, so nothing may overwrite it.
    private func load(_ fileURL: URL, replacesDamagedFile: Bool) -> [BackgroundWindowRecord]? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }
        do {
            return try Self.decoder.decode(File.self, from: data).records
        } catch {
            guard replacesDamagedFile else { return [] }
            diagnostics.increment(Self.resetCounterKey)
            return []
        }
    }

    private func write(_ records: [BackgroundWindowRecord], to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(File(records: records)).write(to: fileURL, options: Self.fileWriteOptions)
            return true
        } catch {
            return false
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Ends one OS background window exactly once: it records the outcome, then tells the OS.
public final class BackgroundWindowCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: BackgroundWindowLedger
    private let started: BackgroundWindowStart
    private let complete: (Bool) -> Void
    private var didFinish = false
    private var expired = false

    /// Records the start of the window at once.
    public init(
        kind: BackgroundWindowKind,
        ledger: BackgroundWindowLedger = .shared,
        startedAt: Date = Date(),
        complete: @escaping (Bool) -> Void
    ) {
        self.ledger = ledger
        self.complete = complete
        started = ledger.begin(kind, at: startedAt)
    }

    /// True after the OS expired the window.
    public var didExpire: Bool { lock.withLock { expired } }

    /// Called by the expiration handler, on any thread.
    public func markExpired() {
        lock.withLock { expired = true }
    }

    /// Waits for `wait`, then records the outcome and tells the OS. A handler passes the wait for its pending requests, so
    /// the next request reaches the scheduler before the window ends; that wait must be bounded. `decide` runs after the
    /// wait, so it reads the window's state at its end; it returns the outcome and, for a handler whose success value
    /// predates the outcome, the success to report.
    @MainActor
    public func finish(
        after wait: @Sendable () async -> Void,
        deciding decide: () -> (outcome: BackgroundWindowOutcome, reportsSuccess: Bool?)
    ) async {
        await wait()
        let decision = decide()
        finish(decision.outcome, reportsSuccess: decision.reportsSuccess)
    }

    /// Waits for `wait`, then ends the window with a fixed outcome.
    @MainActor
    public func finish(
        _ outcome: BackgroundWindowOutcome, reportsSuccess: Bool? = nil, after wait: @Sendable () async -> Void
    ) async {
        await finish(after: wait) { (outcome, reportsSuccess) }
    }

    /// Records the outcome and tells the OS at once. Only the waiting variants are public, so a handler cannot end a
    /// window without waiting for its requests.
    func finish(_ outcome: BackgroundWindowOutcome, reportsSuccess: Bool? = nil) {
        let shouldFinish = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        guard shouldFinish else { return }
        ledger.end(started, with: outcome)
        complete(reportsSuccess ?? outcome.reportsSuccess)
    }
}
