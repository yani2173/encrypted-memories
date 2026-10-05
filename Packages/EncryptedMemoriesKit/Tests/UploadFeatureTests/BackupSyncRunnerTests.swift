import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Fake time: `now` only advances when the runner sleeps, so backoff scheduling is fully
/// deterministic and instant.
final class BackupTestClock: BackupSchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleeps: [TimeInterval] = []

    init(start: Date = Date(timeIntervalSince1970: 1_720_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func sleep(for seconds: TimeInterval) async throws {
        lock.withLock {
            _sleeps.append(seconds)
            current = current.addingTimeInterval(max(0, seconds))
        }
        await Task.yield()
    }
}

/// Records the tags that backup adds to existing photos; can fail every call.
final class SpyTagAdder: PhotoTagAdding, @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Bool
    private var _calls: [(tags: [Int], uid: PhotoUID)] = []

    init(failing: Bool = false) {
        self.failing = failing
    }

    var calls: [(tags: [Int], uid: PhotoUID)] { lock.withLock { _calls } }

    func addTags(_ tags: [Int], to uid: PhotoUID) async throws {
        lock.withLock { _calls.append((tags, uid)) }
        if failing { throw UploadError.backend("tag update rejected") }
    }
}

/// Scripted `BackupResourceResolving`: per-source behavior, resolve counting.
final class ScriptedBackupResolver: BackupResourceResolving, @unchecked Sendable {
    enum Behavior {
        case standard
        case missing
        /// Throw `error` for the first `times` resolves, then behave like `.standard`.
        case transientFailure(times: Int)
        /// Throw `BackupTempFileError.diskBudgetExceeded` for the first `times` resolves, then
        /// behave like `.standard`. Models a device low on space while a pass runs.
        case diskPressure(times: Int)
        /// Throw `UploadError.sourceNotReady(until:)` for the first `times` resolves, then behave like
        /// `.standard`. Models a new photo the camera still processes.
        case notReady(times: Int, until: Date)
        /// Throw `BackupTempFileError.needsFreeSpace` from the first `times` copies for upload, after the duplicate
        /// check. Models a large video whose copy does not fit on the device.
        case needsFreeSpaceOnCopy(times: Int)
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var remainingFailures: [String: Int] = [:]
    private var _resolveCounts: [String: Int] = [:]
    /// Fixed mtime so resolved revisions match the seeded queue rows (no drift) unless a test
    /// overrides it per source.
    let defaultModified: Date
    private var modifiedOverrides: [String: Date] = [:]
    /// Secondary filenames per source id - resolved entries become Live-Photo-style compounds.
    private var secondaryNames: [String: [String]] = [:]
    private var metadataByIdentifier: [String: [PhotoUploadAdditionalMetadata]] = [:]
    private var deferredIdentifiers: Set<String> = []
    private var preparationProgressIdentifiers: Set<String> = []
    private var capturedPreparationHandlers: [String: BackupResourcePreparationHandler] = [:]
    private var mismatchOnceIdentifiers: Set<String> = []
    private var materializeCounts: [String: Int] = [:]
    private var slowIdentifiers: Set<String> = []
    private var activeResolves: [String: Int] = [:]
    private var peakResolves: [String: Int] = [:]

    /// Holds each resolve of `identifier` briefly, so overlapping resolves of one source would show.
    func setSlowResolve(for identifier: String) {
        _ = lock.withLock { slowIdentifiers.insert(identifier) }
    }

    func peakConcurrentResolves(for identifier: String) -> Int {
        lock.withLock { peakResolves[identifier] ?? 0 }
    }

    private var editRevisions: [String: UploadBackupEditRevision] = [:]

    /// The edit revision that resolves report for `identifier`; `.unavailable` (edit evidence) by default.
    func setEditRevision(_ revision: UploadBackupEditRevision, for identifier: String) {
        lock.withLock { editRevisions[identifier] = revision }
    }

    func setSecondaries(_ names: [String], for identifier: String) {
        lock.withLock { secondaryNames[identifier] = names }
    }

    /// Secondary resources other than the Live Photo video, by filename, for example the original of an edit.
    private var secondaryResources: [String: UploadSourceIdentity.Resource] = [:]

    func setSecondaryResource(_ resource: UploadSourceIdentity.Resource, forName name: String) {
        lock.withLock { secondaryResources[name] = resource }
    }

    /// Member filenames per source id - the resolved entry becomes the main photo of a series compound.
    private var burstMemberNames: [String: [String]] = [:]

    func setBurstMembers(_ names: [String], for identifier: String) {
        lock.withLock { burstMemberNames[identifier] = names }
    }

    func setAdditionalMetadata(_ metadata: [PhotoUploadAdditionalMetadata], for identifier: String) {
        lock.withLock { metadataByIdentifier[identifier] = metadata }
    }

    func setDeferredMaterialization(for identifier: String, mismatchOnce: Bool = false) {
        lock.withLock {
            deferredIdentifiers.insert(identifier)
            if mismatchOnce { mismatchOnceIdentifiers.insert(identifier) }
        }
    }

    func setPreparationProgress(for identifier: String) {
        _ = lock.withLock { preparationProgressIdentifiers.insert(identifier) }
    }

    func emitCapturedPreparationProgress(
        for identifier: String,
        _ progress: BackupResourcePreparationProgress
    ) {
        lock.withLock { capturedPreparationHandlers[identifier] }?(progress)
    }

    func materializeCount(for identifier: String) -> Int {
        lock.withLock { materializeCounts[identifier] ?? 0 }
    }

    init(defaultModified: Date) {
        self.defaultModified = defaultModified
    }

    func set(_ behavior: Behavior, for identifier: String) {
        lock.withLock {
            behaviors[identifier] = behavior
            if case .transientFailure(let times) = behavior { remainingFailures[identifier] = times }
            if case .diskPressure(let times) = behavior { remainingFailures[identifier] = times }
            if case .notReady(let times, _) = behavior { remainingFailures[identifier] = times }
            if case .needsFreeSpaceOnCopy(let times) = behavior { remainingFailures[identifier] = times }
        }
    }

    func setModified(_ date: Date, for identifier: String) {
        lock.withLock { modifiedOverrides[identifier] = date }
    }

    func resolveCount(for identifier: String) -> Int {
        lock.withLock { _resolveCounts[identifier] ?? 0 }
    }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        let id = entry.source.identifier
        let isSlow = lock.withLock {
            activeResolves[id, default: 0] += 1
            peakResolves[id] = max(peakResolves[id] ?? 0, activeResolves[id] ?? 0)
            return slowIdentifiers.contains(id)
        }
        defer { lock.withLock { activeResolves[id, default: 1] -= 1 } }
        if isSlow { try? await Task.sleep(for: .milliseconds(30)) }
        let behavior: Behavior = lock.withLock {
            _resolveCounts[id, default: 0] += 1
            return behaviors[id] ?? .standard
        }
        func consumeFailure() -> Bool {
            lock.withLock {
                let left = remainingFailures[id] ?? 0
                if left > 0 {
                    remainingFailures[id] = left - 1
                    return true
                }
                return false
            }
        }
        switch behavior {
        case .missing:
            return nil
        case .transientFailure:
            if consumeFailure() { throw UploadError.backend("transient resolve failure for \(id)") }
        case .diskPressure:
            if consumeFailure() { throw BackupTempFileStore.BackupTempFileError.diskBudgetExceeded }
        case .notReady(_, let until):
            if consumeFailure() { throw UploadError.sourceNotReady(id, until: until) }
        case .standard, .needsFreeSpaceOnCopy:
            break
        }

        // Standard resolution (also reached once a transient/disk-pressure budget is exhausted).
        do {
            let modified = lock.withLock { modifiedOverrides[id] } ?? defaultModified
            let secondaries = lock.withLock { secondaryNames[id] } ?? []
            let secondaryResources = lock.withLock { self.secondaryResources }
            let burstMembers = lock.withLock { burstMemberNames[id] } ?? []
            let additionalMetadata = lock.withLock { metadataByIdentifier[id] } ?? []
            let isDeferred = lock.withLock { deferredIdentifiers.contains(id) }
            let snapshot = UploadBackupAssetSnapshot(
                source: entry.source,
                revision: UploadBackupRevision(date: modified),
                editRevision: lock.withLock { editRevisions[id] } ?? .unavailable,
                resourceCount: 1 + secondaries.count + burstMembers.count
            )
            let descriptor = UploadResourceDescriptor(
                source: entry.source,
                fileURL: URL(fileURLWithPath: entry.source.identifier),
                filename: entry.originalFilename,
                fileSize: entry.byteCount ?? 1,
                modificationDate: modified,
                precomputedSHA1Digest: isDeferred ? Self.digest(seed: entry.source.identifier) : nil
            )
            let materialize: (@Sendable () async throws -> UploadResourceDescriptor)?
            if isDeferred {
                materialize = { @Sendable [self] in
                    let (shouldMismatch, copyFails) = lock.withLock { () -> (Bool, Bool) in
                        materializeCounts[id, default: 0] += 1
                        var copyFails = false
                        if case .needsFreeSpaceOnCopy = behaviors[id], let left = remainingFailures[id], left > 0 {
                            remainingFailures[id] = left - 1
                            copyFails = true
                        }
                        return (mismatchOnceIdentifiers.remove(id) != nil, copyFails)
                    }
                    if copyFails {
                        throw BackupTempFileStore.BackupTempFileError.needsFreeSpace(requiredBytes: 1 << 34)
                    }
                    return UploadResourceDescriptor(
                        source: entry.source,
                        fileURL: URL(fileURLWithPath: entry.source.identifier + ".materialized"),
                        filename: entry.originalFilename,
                        fileSize: entry.byteCount ?? 1,
                        modificationDate: modified,
                        precomputedSHA1Digest: shouldMismatch
                            ? Data(repeating: 0xFF, count: 20)
                            : Self.digest(seed: entry.source.identifier)
                    )
                }
            } else {
                materialize = nil
            }
            return BackupResolvedResource(
                candidate: UploadBackupAssetCandidate(
                    snapshot: snapshot,
                    originalFilename: entry.originalFilename,
                    byteCount: entry.byteCount
                ),
                descriptor: descriptor,
                mediaType: "image/jpeg",
                additionalMetadata: additionalMetadata,
                captureDate: modified,
                secondaries: secondaries.map { name in
                    BackupSecondaryResource(
                        descriptor: UploadResourceDescriptor(
                            source: UploadSourceIdentity(
                                kind: entry.source.kind,
                                identifier: entry.source.identifier,
                                resource: secondaryResources[name] ?? .livePairedVideo
                            ),
                            fileURL: URL(fileURLWithPath: "\(entry.source.identifier)#\(name)"),
                            filename: name,
                            fileSize: 2,
                            modificationDate: modified
                        ),
                        mediaType: "video/quicktime",
                        additionalMetadata: additionalMetadata
                    )
                }
                    + burstMembers.enumerated().map { ordinal, name in
                        BackupSecondaryResource(
                            descriptor: UploadResourceDescriptor(
                                source: UploadSourceIdentity(
                                    kind: entry.source.kind,
                                    identifier: entry.source.identifier,
                                    resource: .burstMember(ordinal: ordinal)
                                ),
                                fileURL: URL(fileURLWithPath: "\(entry.source.identifier)#\(name)"),
                                filename: name,
                                fileSize: 3,
                                modificationDate: modified
                            ),
                            mediaType: "image/jpeg",
                            additionalMetadata: additionalMetadata
                        )
                    },
                materialize: materialize
            )
        }
    }

    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        let reportsProgress = lock.withLock {
            preparationProgressIdentifiers.contains(entry.source.identifier)
        }
        guard reportsProgress else { return try await resolve(entry) }
        lock.withLock { capturedPreparationHandlers[entry.source.identifier] = onPreparationProgress }

        onPreparationProgress(.init(phase: .identity, fraction: 0.25))
        await Task.yield()
        guard let resolved = try await resolve(entry) else { return nil }
        onPreparationProgress(.init(phase: .identity, fraction: 1))
        await Task.yield()
        guard resolved.hasDeferredMaterialization else { return resolved }

        return BackupResolvedResource(
            candidate: resolved.candidate,
            descriptor: resolved.descriptor,
            mediaType: resolved.mediaType,
            additionalMetadata: resolved.additionalMetadata,
            captureDate: resolved.captureDate,
            secondaries: resolved.secondaries,
            materializeWithProgress: { reporter in
                reporter(.init(phase: .materializing, fraction: 0.2))
                await Task.yield()
                reporter(.init(phase: .materializing, fraction: 0.6))
                await Task.yield()
                reporter(.init(phase: .materializing, fraction: 1))
                return try await resolved.materializedDescriptor()
            },
            cleanup: resolved.cleanup
        )
    }

    private static func digest(seed: String) -> Data {
        var digest = Data(repeating: 0, count: 20)
        for (index, byte) in seed.utf8.enumerated() { digest[index % 20] ^= byte }
        return digest
    }
}

/// Removes its source while the runner still waits for the resolve, like a deletion during an iCloud download.
final class SourceRemovedDuringResolveResolver: BackupResourceResolving, @unchecked Sendable {
    private let inner: ScriptedBackupResolver
    private let lock = NSLock()
    private var cleanups = 0
    private var _onResolve: (@Sendable (UploadBackupSyncQueueEntry) async -> Void)?

    init(inner: ScriptedBackupResolver) { self.inner = inner }

    var onResolve: (@Sendable (UploadBackupSyncQueueEntry) async -> Void)? {
        get { lock.withLock { _onResolve } }
        set { lock.withLock { _onResolve = newValue } }
    }

    var cleanupCount: Int { lock.withLock { cleanups } }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        await onResolve?(entry)
        guard let resolved = try await inner.resolve(entry) else { return nil }
        return BackupResolvedResource(
            candidate: resolved.candidate,
            descriptor: resolved.descriptor,
            mediaType: resolved.mediaType,
            additionalMetadata: resolved.additionalMetadata,
            captureDate: resolved.captureDate,
            secondaries: resolved.secondaries,
            cleanup: { [weak self] in self?.recordCleanup() }
        )
    }

    private func recordCleanup() {
        lock.withLock { cleanups += 1 }
    }
}

/// Adds source tags to the scripted resource, as the PhotoKit resolver does for an Apple Photos favorite.
final class TaggingBackupResolver: BackupResourceResolving, @unchecked Sendable {
    private let inner: ScriptedBackupResolver
    private let tags: [Int]

    init(inner: ScriptedBackupResolver, tags: [Int]) {
        self.inner = inner
        self.tags = tags
    }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard let resolved = try await inner.resolve(entry) else { return nil }
        return BackupResolvedResource(
            candidate: resolved.candidate,
            descriptor: resolved.descriptor,
            mediaType: resolved.mediaType,
            additionalMetadata: resolved.additionalMetadata,
            tags: tags,
            captureDate: resolved.captureDate,
            secondaries: resolved.secondaries,
            cleanup: resolved.cleanup
        )
    }
}

/// Shared ordered event log for cross-component ordering assertions.
final class BackupEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) { lock.withLock { _events.append(event) } }
    var events: [String] { lock.withLock { _events } }

    func firstIndex(of event: String) -> Int? { events.firstIndex(of: event) }
}

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UploadProgress] = []
    func append(_ value: UploadProgress) { lock.withLock { values.append(value) } }
    var snapshots: [UploadProgress] { lock.withLock { values } }
}

final class BackupProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BackupSyncProgress] = []

    func append(_ value: BackupSyncProgress) { lock.withLock { values.append(value) } }
    var snapshots: [BackupSyncProgress] { lock.withLock { values } }
}

/// Queue store spy: delegates to the real SQLite store while logging every state write.
final class SpyQueueStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    private let inner: UploadBackupSyncQueueManifestStore
    private let log: BackupEventLog

    init(inner: UploadBackupSyncQueueManifestStore, log: BackupEventLog) {
        self.inner = inner
        self.log = log
    }

    @discardableResult
    func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        log.append("queue.upsert:\(entry.state.rawValue)")
        return inner.upsert(entry)
    }

    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        inner.entry(for: source, revision: revision)
    }

    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] { inner.nextRunnable(limit: limit) }

    func nextRunnableDate() -> Date? { inner.nextRunnableDate() }

    func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        log.append("queue.claimRunnable")
        return inner.claimRunnable(limit: limit, claimedAt: claimedAt)
    }

    func entries(in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int) -> [UploadBackupSyncQueueEntry]
    {
        inner.entries(in: state, updatedBefore: updatedBefore, limit: limit)
    }

    @discardableResult
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        log.append("queue.requeueStaleActive")
        return inner.requeueStaleActive(before: cutoff, updatedAt: updatedAt)
    }

    @discardableResult
    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        log.append("queue.state:\(state.rawValue)")
        return inner.updateState(
            source: source, revision: revision, state: state,
            attempts: attempts, lastError: lastError, updatedAt: updatedAt)
    }

    func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        inner.remove(source: source, revision: revision)
    }
    func removeSettledRevisions(of source: UploadSourceIdentity, except revision: UploadBackupRevision) -> Bool {
        inner.removeSettledRevisions(of: source, except: revision)
    }

    func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        inner.removeSources(kind: kind, identifiers: identifiers)
    }

    func summary() -> UploadBackupSyncQueueSummary { inner.summary() }
    func count() -> Int { inner.count() }
}

/// Simulates a scan upsert racing the runner immediately after it persisted a future retry. The
/// row becomes due again before `updateState` returns, exactly as a concurrent PhotoKit scan can do.
final class ReenqueueOnFirstRetryQueueStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    private let inner: UploadBackupSyncQueueManifestStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var didReenqueue = false

    init(inner: UploadBackupSyncQueueManifestStore, now: @Sendable @escaping () -> Date) {
        self.inner = inner
        self.now = now
    }

    func isOperational() -> Bool { inner.isOperational() }
    func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool { inner.upsert(entry) }
    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        inner.entry(for: source, revision: revision)
    }
    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] { inner.nextRunnable(limit: limit) }
    func nextRunnableDate() -> Date? { inner.nextRunnableDate() }
    func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        inner.claimRunnable(limit: limit, claimedAt: claimedAt)
    }
    func entries(in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int) -> [UploadBackupSyncQueueEntry]
    {
        inner.entries(in: state, updatedBefore: updatedBefore, limit: limit)
    }
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        inner.requeueStaleActive(before: cutoff, updatedAt: updatedAt)
    }
    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        guard
            inner.updateState(
                source: source,
                revision: revision,
                state: state,
                attempts: attempts,
                lastError: lastError,
                updatedAt: updatedAt
            )
        else { return false }
        let shouldReenqueue = lock.withLock {
            guard !didReenqueue, state == .discovered, updatedAt > now() else { return false }
            didReenqueue = true
            return true
        }
        guard shouldReenqueue,
            var entry = inner.entry(for: source, revision: revision)
        else { return true }
        entry.state = .discovered
        entry.attempts = 0
        entry.lastError = nil
        entry.updatedAt = now()
        return inner.upsert(entry)
    }
    func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        inner.remove(source: source, revision: revision)
    }
    func removeSettledRevisions(of source: UploadSourceIdentity, except revision: UploadBackupRevision) -> Bool {
        inner.removeSettledRevisions(of: source, except: revision)
    }
    func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        inner.removeSources(kind: kind, identifiers: identifiers)
    }
    func summary() -> UploadBackupSyncQueueSummary { inner.summary() }
    func count() -> Int { inner.count() }
}

final class BackupThrottleSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BackupThrottleInputs]

    init(_ values: [BackupThrottleInputs]) { self.values = values }

    func next() -> BackupThrottleInputs {
        lock.withLock {
            guard values.count > 1 else { return values.first ?? .unconstrained }
            return values.removeFirst()
        }
    }
}

/// Identity-resolver spy: delegates to the real pipeline while logging `recordUploaded`.
final class SpyIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: UploadDedupePipeline
    private let log: BackupEventLog

    init(inner: UploadDedupePipeline, log: BackupEventLog) {
        self.inner = inner
        self.log = log
    }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await inner.prepareRemoteIndex(progress: progress)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        await inner.prime(descriptors)
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        log.append("manifest.recordUploaded")
        try await inner.recordUploaded(
            descriptor, identity: identity,
            remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID)
    }

    func invalidateCachedRemoteState() async {
        log.append("manifest.invalidateCachedRemoteState")
        await inner.invalidateCachedRemoteState()
    }

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        log.append("manifest.uploadDidFail")
        await inner.uploadDidFail(descriptor)
    }
}

final class PreparationFailingIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: any UploadIdentityResolving
    init(inner: any UploadIdentityResolving) { self.inner = inner }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        await progress(.init(phase: .indexing, completed: 10, total: 100))
        throw UploadError.backend("index unavailable")
    }
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        try await inner.recordUploaded(
            descriptor, identity: identity, remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID
        )
    }
}

final class RecordFailingIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: UploadDedupePipeline
    private let lock = NSLock()
    private var remainingFailures: Int

    init(inner: UploadDedupePipeline, failures: Int) {
        self.inner = inner
        remainingFailures = failures
    }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await inner.prepareRemoteIndex(progress: progress)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        await inner.prime(descriptors)
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        let shouldFail = lock.withLock {
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if shouldFail {
            await inner.remoteCommitNeedsReconciliation(descriptor)
            throw UploadError.backend("simulated manifest failure")
        }
        try await inner.recordUploaded(
            descriptor,
            identity: identity,
            remoteVolumeID: remoteVolumeID,
            remoteLinkID: remoteLinkID
        )
    }

    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await inner.remoteCommitNeedsReconciliation(descriptor)
    }
}

actor StopAfterResolveIdentityResolver: UploadIdentityResolving {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var failureSettlements = 0

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        let digest = Data(repeating: 0x11, count: 20)
        return UploadPreflightResult(
            identity: UploadIdentity(
                correctedName: descriptor.filename,
                nameHash: "name-hash",
                sha1Hex: UploadContentSHA1.hexString(digest: digest),
                sha1Digest: digest,
                contentHash: "content-hash"
            ),
            decision: .upload
        )
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {}

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        failureSettlements += 1
    }

    func hasStarted() -> Bool { started }
    func resumeResolve() {
        continuation?.resume()
        continuation = nil
    }
    func settlementCount() -> Int { failureSettlements }
}

/// Uploader that "crashes" after the remote side already accepted the bytes: the first call
/// registers an active remote duplicate with the checker, then throws - simulating a process
/// death between upload success and the manifest write.
final class CrashAfterUploadUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private let checker: FakeChecker
    private let contentHashByName: [String: String]
    private var _attempts = 0

    init(checker: FakeChecker, contentHashByName: [String: String]) {
        self.checker = checker
        self.contentHashByName = contentHashByName
    }

    var attempts: Int { lock.withLock { _attempts } }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let attempt: Int = lock.withLock {
            _attempts += 1
            return _attempts
        }
        let nameHash = "nh(\(request.name))"
        checker.remoteItemsByNameHash[nameHash] = [
            RemotePhotoDuplicate(
                nameHash: nameHash,
                contentHash: contentHashByName[request.name],
                linkState: .active,
                linkID: "remote-\(request.name)"
            )
        ]
        if attempt == 1 {
            throw UploadError.backend("process died after server accepted the upload")
        }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {}
}

/// First transfer never completes until cancelled; the retry succeeds. Models an SDK continuation
/// that otherwise leaves one queue row in `.uploading` forever.
final class StallOnceUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private var attempts = 0
    private var cancellationCount = 0
    private var stalledContinuation: CheckedContinuation<PhotoUID, Error>?

    var uploadAttempts: Int { lock.withLock { attempts } }
    var cancellations: Int { lock.withLock { cancellationCount } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        if attempt > 1 { return testUID(request.name) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { stalledContinuation = continuation }
        }
    }

    func cancel(token: UUID) async {
        let continuation: CheckedContinuation<PhotoUID, Error>? = lock.withLock {
            cancellationCount += 1
            defer { stalledContinuation = nil }
            return stalledContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

actor BackupUploadTestLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }

    func isSignaled() -> Bool { signaled }
}

/// Holds the first upload until the test releases it; every other upload finishes at once.
final class FirstUploadHoldingUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    let release = BackupUploadTestLatch()

    private let lock = NSLock()
    private var _heldName: String?
    private var _finished: [String] = []

    var heldName: String? { lock.withLock { _heldName } }
    var finished: [String] { lock.withLock { _finished } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let holds = lock.withLock { () -> Bool in
            guard _heldName == nil else { return false }
            _heldName = request.name
            return true
        }
        if holds { await release.wait() }
        lock.withLock { _finished.append(request.name) }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {}
}

/// Ignores Swift task cancellation until its upload and native-cancel latches are released.
/// This models an SDK continuation that can return late after the caller requests cancellation.
final class NonCooperativeBackupUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    let uploadStarted = BackupUploadTestLatch()
    let uploadRelease = BackupUploadTestLatch()
    let cancelStarted = BackupUploadTestLatch()
    let cancelRelease = BackupUploadTestLatch()

    private let lock = NSLock()
    private var _uploadAttempts = 0
    private var _cancellations = 0

    var uploadAttempts: Int { lock.withLock { _uploadAttempts } }
    var cancellations: Int { lock.withLock { _cancellations } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        lock.withLock { _uploadAttempts += 1 }
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        await uploadStarted.signal()
        await uploadRelease.wait()
        return testUID(request.name)
    }

    func cancel(token: UUID) async {
        lock.withLock { _cancellations += 1 }
        await cancelStarted.signal()
        await cancelRelease.wait()
    }
}

final class BackupSyncRunnerTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var stateStore: MemoryBackupStateStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

    private final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }

        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }

        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
            return true
        }

        func removeRecords(for source: UploadSourceIdentity, keeping revisions: Set<UploadBackupRevision>) -> Bool {
            lock.withLock { rows[source] = rows[source]?.filter { revisions.contains($0.key) } }
            return true
        }

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-sync-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
            ))
        stateStore = MemoryBackupStateStore()
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnavailableQueueStartsNoWorkAndCannotLookDrained() async throws {
        _ = seedEntry("must-remain-pending.heic")
        queueStore.close()

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()
        let queueIsOperational = await runner.isQueueOperational()

        XCTAssertFalse(queueIsOperational)
        XCTAssertFalse(progress.isRunning)
        XCTAssertTrue(uploader.requests.isEmpty, "a failed queue read must never start an upload")
    }

    func testDiskPressureNeverBurnsRetryBudgetAndRecovers() async throws {
        // More disk-pressure failures than the park threshold must not consume retry attempts.
        // Disk pressure must not park an item as `.failed`.
        let entry = seedEntry("crowded.jpg")
        resolver.set(.diskPressure(times: 7), for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed, "disk pressure must never park an item as failed")
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 8, "7 pressure failures, then success")
    }

    func testPhotoTheCameraStillProcessesWaitsForTheEndOfItsWindowWithoutPolling() async throws {
        let entry = seedEntry("processing.heic")
        let windowEnd = clock.now.addingTimeInterval(600)
        resolver.set(.notReady(times: 1, until: windowEnd), for: entry.source.identifier)

        // The library pass waits for nothing: the photo stays due at the end of the camera window.
        let runner = makeRunner()
        let parked = await runner.runUntilDrained(mode: .eligibleOnly)
        let row = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(row.state, .discovered, "a state that older builds know, never a failure")
        XCTAssertEqual(row.attempts, 0)
        let issue = try XCTUnwrap(BackupIssueRecord.decode(row.lastError))
        XCTAssertEqual(issue.kind, .unknown)
        XCTAssertEqual(issue.detail, "error.upload_source_not_ready")
        XCTAssertEqual(issue.nextAttemptAt, windowEnd)
        XCTAssertEqual(BackupFailedItem(entry: row).category, .automatic)
        XCTAssertEqual(row.updatedAt.timeIntervalSince1970, windowEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(parked.failed, 0)
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertTrue(uploader.requests.isEmpty)

        // A pass before that date does not look at the photo again.
        clock.advance(by: 300)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)

        // One check at the end of the window backs up whatever version exists.
        clock.advance(by: 301)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 2)
    }

    func testAnAlbumBackupTheUserWaitsForChecksAWaitingPhotoEvery30Seconds() async throws {
        let entry = seedEntry("processing-wait.heic")
        resolver.set(.notReady(times: 2, until: clock.now.addingTimeInterval(600)), for: entry.source.identifier)

        // A one-shot drain must not sleep through the camera's whole window once the finished photo exists.
        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(clock.sleeps.count, 2)
        XCTAssertEqual(try XCTUnwrap(clock.sleeps.first), 30, accuracy: 0.001)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 3)
    }

    func testAPhotoThatDoesNotFitIntoTheAccountWaitsWithoutACopyOrAnAttempt() async throws {
        let entry = seedEntry("huge.mov")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        uploader.remoteCapacityBytes = 0

        let progress = await makeRunner().runUntilDrained(mode: .eligibleOnly)

        let row = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(row.state, .discovered, "a full account is not the photo's fault")
        XCTAssertEqual(row.attempts, 0)
        let issue = try XCTUnwrap(BackupIssueRecord.decode(row.lastError))
        XCTAssertEqual(issue.kind, .accountStorage)
        XCTAssertEqual(
            row.updatedAt.timeIntervalSince(clock.now), BackupSyncRunner.accountStorageRecheckInterval, accuracy: 1)
        XCTAssertEqual(resolver.materializeCount(for: entry.source.identifier), 0, "no copy of a file that cannot fit")
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(progress.failed, 0)

        // More storage, then Back Up Now.
        uploader.remoteCapacityBytes = nil
        queueStore.makeRetryableWorkEligible(updatedAt: clock.now)
        _ = await makeRunner().runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testReplacingOwnDraftLeavesTheStorageDecisionToProton() async throws {
        // The draft's own blocks may be what fills the account.
        let entry = seedEntry("full-draft.jpg")
        let hashes = expectedHashes(id: "full-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: hashes.contentHash,
                linkState: .draft,
                linkID: "full-draft",
                clientUID: "this-installation"
            )
        ]
        let pipeline = UploadDedupePipeline(
            store: identityStore,
            hasher: hasher,
            checker: checker,
            currentClientUID: "this-installation",
            now: { [clock] in clock!.now }
        )
        uploader.remoteCapacityBytes = 0

        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertTrue(try XCTUnwrap(uploader.requests.first).overrideExistingDraft)
    }

    func testAnAlbumBackupTheUserWaitsForEndsWhenTheAccountIsFull() async throws {
        let entry = seedEntry("full-account.mov")
        uploader.remoteCapacityBytes = 0

        let progress = await makeRunner().runUntilDrained()

        XCTAssertFalse(progress.isRunning)
        XCTAssertTrue(clock.sleeps.isEmpty, "the drain must not sleep until the next storage check")
        XCTAssertEqual(state(of: entry), .discovered)
        XCTAssertEqual(progress.failed, 0)
    }

    func testALivePhotoVideoThatDoesNotFitIntoTheAccountWaitsWithoutAnAttempt() async throws {
        let entry = seedEntry("fits.heic")
        resolver.setSecondaries(["too-large.mov"], for: entry.source.identifier)
        // The photo (1 byte) fits, its paired video (2 bytes) does not.
        uploader.remoteCapacityBytes = 1

        let progress = await makeRunner().runUntilDrained(mode: .eligibleOnly)

        let row = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertFalse(row.state.isTerminalSuccess)
        XCTAssertEqual(row.attempts, 0)
        XCTAssertEqual(try XCTUnwrap(BackupIssueRecord.decode(row.lastError)).kind, .accountStorage)
        XCTAssertFalse(uploader.requests.contains { $0.name == "too-large.mov" })
        XCTAssertEqual(progress.failed, 0)

        uploader.remoteCapacityBytes = nil
        queueStore.makeRetryableWorkEligible(updatedAt: clock.now)
        _ = await makeRunner().runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(uploader.requests.filter { $0.name == "fits.heic" }.count, 1, "the photo uploads only once")
    }

    func testALargeVideoWithoutSpaceOnTheDeviceWaitsForSpace() async throws {
        let entry = seedEntry("prores.mov")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        resolver.set(.needsFreeSpaceOnCopy(times: 1), for: entry.source.identifier)

        let progress = await makeRunner().runUntilDrained(mode: .eligibleOnly)

        let row = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(row.state, .discovered)
        XCTAssertEqual(row.attempts, 0, "missing space on the device is not the photo's fault")
        let issue = try XCTUnwrap(BackupIssueRecord.decode(row.lastError))
        XCTAssertEqual(issue.kind, .deviceStorage)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(resolver.materializeCount(for: entry.source.identifier), 1)
        XCTAssertTrue(uploader.requests.isEmpty)

        queueStore.makeRetryableWorkEligible(updatedAt: clock.now)
        _ = await makeRunner().runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testBackUpNowChecksAWaitingPhotoAgain() async throws {
        let entry = seedEntry("waiting.heic")
        resolver.set(.notReady(times: 1, until: clock.now.addingTimeInterval(600)), for: entry.source.identifier)
        let runner = makeRunner()
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)

        // The camera finished without a change notification reaching the app; Back Up Now finds it done.
        queueStore.makeRetryableWorkEligible(updatedAt: clock.now)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 2)
    }

    func testTwoRevisionsOfOnePhotoNeverRunAtTheSameTime() async throws {
        // The camera's preliminary version and the finished photo can both be due in one wave.
        let preliminary = seedEntry("same.heic")
        let finished = seedEntry("same.heic", revisionOffset: 1_000_000)
        resolver.setSlowResolve(for: preliminary.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(resolver.peakConcurrentResolves(for: preliminary.source.identifier), 1)
        XCTAssertEqual(resolver.resolveCount(for: preliminary.source.identifier), 2)
        XCTAssertEqual(uploader.requests.count, 1, "the second revision finds the photo backed up")
        XCTAssertEqual(progress.failed, 0)
        XCTAssertNotEqual(state(of: finished), .failed)
    }

    func testPersistedRetryDelaySurvivesRunnerRecreation() async throws {
        let entry = seedEntry("resume-after-backoff.jpg", ageSeconds: -30)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(try XCTUnwrap(clock.sleeps.first), 30, accuracy: 0.001)
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(uploader.requests.count, 1)
    }

    func testEligibleOnlyDrainLeavesFutureRetryAndProcessesNewDueWork() async throws {
        let delayed = seedEntry("delayed-retry.jpg", ageSeconds: -3_600)
        let runner = makeRunner()

        let idle = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertFalse(idle.isRunning)
        XCTAssertEqual(state(of: delayed), .discovered)
        XCTAssertTrue(clock.sleeps.isEmpty, "reconcile must not sleep behind a future retry date")
        XCTAssertTrue(uploader.requests.isEmpty)

        let newlyDiscovered = seedEntry("newly-discovered.jpg")
        let drained = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: newlyDiscovered), .completed)
        XCTAssertEqual(state(of: delayed), .discovered, "the delayed row keeps its eligibility date")
        XCTAssertEqual(uploader.requests.map(\.name), ["newly-discovered.jpg"])
        XCTAssertEqual(drained.uploaded, 1)
        XCTAssertFalse(drained.isRunning)
        XCTAssertTrue(clock.sleeps.isEmpty, "eligible-only reconciliation must return to observe new queue writes")
    }

    func testEligibleOnlyDrainReturnsImmediatelyWhenRuntimePolicyIsClosed() async throws {
        let due = seedEntry("offline.jpg")
        let runner = makeRunner(throttleInputs: {
            BackupThrottleInputs(isNetworkAvailable: false)
        })

        let progress = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(progress.isPausedByPolicy)
        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(state(of: due), .discovered)
        XCTAssertTrue(clock.sleeps.isEmpty, "the controller owns the next date-driven retry")
        XCTAssertEqual(resolver.resolveCount(for: due.source.identifier), 0)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testClaimedRetryCannotBeDroppedWhenScanMakesItDueAgain() async throws {
        let entry = seedEntry("raced-retry.jpg")
        resolver.set(.transientFailure(times: 1), for: entry.source.identifier)
        let queue = ReenqueueOnFirstRetryQueueStore(inner: queueStore, now: { [clock] in clock!.now })

        let progress = await makeRunner(queue: queue).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 2)
        XCTAssertEqual(uploader.requests.map(\.name), ["raced-retry.jpg"])
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.checking, 0, "every atomically claimed row must have a worker")
    }

    func testEligibleOnlyPreservesPolicyPauseFromSecondRuntimeSample() async throws {
        let due = seedEntry("network-changed.jpg")
        let inputs = BackupThrottleSequence([
            .unconstrained,
            BackupThrottleInputs(isNetworkAvailable: false),
        ])

        let progress = await makeRunner(throttleInputs: { inputs.next() })
            .runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(progress.isPausedByPolicy)
        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(state(of: due), .discovered)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testSustainedDiskPressureEndsPassRunnableNotFailed() async throws {
        // The volume stays full for the whole pass: no item can ever export.
        let a = seedEntry("a.jpg")
        let b = seedEntry("b.jpg")
        resolver.set(.diskPressure(times: .max), for: a.source.identifier)
        resolver.set(.diskPressure(times: .max), for: b.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(progress.failed, 0, "a full disk must not manufacture permanent failures")
        XCTAssertEqual(uploader.requests.count, 0)
        XCTAssertEqual(state(of: a), .discovered, "rows stay runnable for the next pass")
        XCTAssertEqual(state(of: b), .discovered)
        let issue = try XCTUnwrap(
            BackupIssueRecord.decode(
                queueStore.entry(for: a.source, revision: a.revision)?.lastError
            ))
        XCTAssertEqual(issue.kind, .deviceStorage)
        XCTAssertNotNil(issue.nextAttemptAt)
    }

    func testRequeueFailedResetsParkedRowsToRunnable() {
        let failed = seedEntry("stuck.jpg", state: .failed, attempts: 4)
        let done = seedEntry("done.jpg", state: .completed)

        let count = queueStore.requeueFailed(updatedAt: clock.now)

        XCTAssertEqual(count, 1, "only the failed row is requeued")
        XCTAssertEqual(state(of: failed), .discovered)
        XCTAssertEqual(
            queueStore.entry(for: failed.source, revision: failed.revision)?.attempts, 0,
            "requeue grants a fresh retry budget")
        XCTAssertEqual(state(of: done), .completed, "terminal-success rows are untouched")
    }

    func testRequeueAndTheDefaultManualRetryKeepTheReason() throws {
        let reason = BackupIssueRecord(kind: .permission, detail: "denied").persistedValue
        func seedFailed(_ id: String) -> UploadBackupSyncQueueEntry {
            var entry = seedEntry(id, state: .failed, attempts: 8)
            entry.lastError = reason
            queueStore.upsert(entry)
            return entry
        }
        let requeued = seedFailed("requeued.jpg")
        XCTAssertEqual(queueStore.requeueFailed(updatedAt: clock.now), 1)
        let afterRequeue = try XCTUnwrap(queueStore.entry(for: requeued.source, revision: requeued.revision))
        XCTAssertEqual(afterRequeue.state, .discovered)
        XCTAssertEqual(afterRequeue.lastError, reason, "the photo keeps its place in the problem list")

        // A store without its own implementation uses the protocol's default.
        let retried = seedFailed("retried.jpg")
        let spyQueue = SpyQueueStore(inner: queueStore, log: BackupEventLog())
        XCTAssertGreaterThan(spyQueue.makeRetryableWorkEligible(updatedAt: clock.now), 0)
        let afterRetry = try XCTUnwrap(queueStore.entry(for: retried.source, revision: retried.revision))
        XCTAssertEqual(afterRetry.state, .discovered)
        XCTAssertEqual(afterRetry.lastError, reason, "Back Up Now keeps the reason")
    }

    private func makePipeline(resourceCoordinator: LibraryResourceCoordinator = .shared) -> UploadDedupePipeline {
        UploadDedupePipeline(
            store: identityStore,
            hasher: hasher,
            checker: checker,
            resourceCoordinator: resourceCoordinator,
            now: { [clock] in clock!.now }
        )
    }

    func testTransientNetworkClassification() {
        // These are the network's fault, not the item's to never park, and they drive concurrency backoff.
        for code in [
            URLError.networkConnectionLost, .timedOut, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
        ] {
            XCTAssertTrue(BackupSyncRunner.isTransientNetwork(URLError(code)), "\(code) must be transient-network")
        }
        // The Proton SDK may surface the same as an NSError in the URL-error domain.
        XCTAssertTrue(
            BackupSyncRunner.isTransientNetwork(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        XCTAssertTrue(
            BackupSyncRunner.isTransientNetwork(
                UploadError.transport(code: NSURLErrorTimedOut, message: "timed out")))
        // Item-specific / non-network failures must not be treated as transient network.
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(URLError(.badURL)))
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(UploadError.backend("server said no")))
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(NSError(domain: "Other", code: NSURLErrorTimedOut)))
    }

    private func makeRunner(
        uploader: (any PhotoUploading)? = nil,
        tagAdder: (any PhotoTagAdding)? = nil,
        identityResolver: (any UploadIdentityResolving)? = nil,
        editReplacement: EditedPhotoReplacement? = nil,
        resolver: (any BackupResourceResolving)? = nil,
        queue: (any UploadBackupSyncQueueStore)? = nil,
        retry: BackupRetryPolicy = BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
        throttle: BackupThrottlePolicy = BackupThrottlePolicy(baseConcurrency: 2),
        uploadStallTimeout: TimeInterval = 180,
        uploadStallPollInterval: TimeInterval = 5,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        events: (any BackupItemEventSink)? = nil,
        throttleInputs: @Sendable @escaping () -> BackupThrottleInputs = { .unconstrained }
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queue ?? queueStore,
            preflight: preflight,
            resolver: resolver ?? self.resolver,
            identityResolver: identityResolver ?? makePipeline(resourceCoordinator: resourceCoordinator),
            uploader: uploader ?? self.uploader,
            tagAdder: tagAdder,
            editReplacement: editReplacement,
            resourceCoordinator: resourceCoordinator,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: uploadStallTimeout,
                uploadStallPollInterval: uploadStallPollInterval,
                retry: retry,
                throttle: throttle
            ),
            throttleInputs: throttleInputs,
            clock: clock,
            events: events,
            now: { [clock] in clock!.now }
        )
    }

    func testStalledUploadIsCancelledAndRetriedWithoutParkingItem() async throws {
        let entry = seedEntry("stalled.jpg")
        let stalledUploader = StallOnceUploader()
        let runner = makeRunner(
            uploader: stalledUploader,
            uploadStallTimeout: 0.05,
            uploadStallPollInterval: 0.01
        )

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(stalledUploader.cancellations, 1)
        XCTAssertEqual(stalledUploader.uploadAttempts, 2)
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.failed, 0, "a stalled transport is retryable, not an item failure")
    }

    func testTimeoutJoinsNativeCancellationAndUploadBeforeRetry() async throws {
        let entry = seedEntry("timeout-join.jpg")
        let stalledUploader = NonCooperativeBackupUploader()
        let runner = makeRunner(
            uploader: stalledUploader,
            uploadStallTimeout: 0.05,
            uploadStallPollInterval: 0.01
        )
        let drainReturned = BackupUploadTestLatch()
        let drain = Task {
            let progress = await runner.runUntilDrained()
            await drainReturned.signal()
            return progress
        }

        await stalledUploader.uploadStarted.wait()
        await stalledUploader.cancelStarted.wait()
        await Task.yield()
        XCTAssertEqual(stalledUploader.cancellations, 1)
        let returnedBeforeNativeCancel = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeNativeCancel)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "timeout must not requeue while native cancellation and upload remain blocked")

        await stalledUploader.cancelRelease.signal()
        await Task.yield()
        let returnedBeforeUploadSettlement = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeUploadSettlement)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "native cancellation alone must not release the uploading row")

        await stalledUploader.uploadRelease.signal()
        _ = await drain.value

        let returnedAfterSettlement = await drainReturned.isSignaled()
        XCTAssertTrue(returnedAfterSettlement)
        XCTAssertEqual(stalledUploader.cancellations, 1, "timeout must issue one native cancellation")
        XCTAssertEqual(stalledUploader.uploadAttempts, 2, "the settled timeout may retry once")
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testTaskCancellationJoinsNativeCancellationAndUploadBeforeReversion() async throws {
        let entry = seedEntry("task-cancel-join.jpg")
        let stalledUploader = NonCooperativeBackupUploader()
        let runner = makeRunner(uploader: stalledUploader, uploadStallTimeout: 60, uploadStallPollInterval: 5)
        let drainReturned = BackupUploadTestLatch()
        let drain = Task {
            let progress = await runner.runUntilDrained()
            await drainReturned.signal()
            return progress
        }

        await stalledUploader.uploadStarted.wait()
        drain.cancel()
        await stalledUploader.cancelStarted.wait()
        await Task.yield()
        XCTAssertEqual(stalledUploader.cancellations, 1)
        let returnedBeforeNativeCancel = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeNativeCancel)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "task cancellation must not requeue while native cancellation and upload remain blocked")

        await stalledUploader.cancelRelease.signal()
        await Task.yield()
        let returnedBeforeUploadSettlement = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeUploadSettlement)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "task cancellation must join the upload after native cancellation returns")

        await stalledUploader.uploadRelease.signal()
        _ = await drain.value

        let returnedAfterSettlement = await drainReturned.isSignaled()
        XCTAssertTrue(returnedAfterSettlement)
        XCTAssertEqual(stalledUploader.cancellations, 1, "task cancellation must issue one native cancellation")
        XCTAssertEqual(state(of: entry), .queuedForUpload)
    }

    func testStopJoinsNativeCancellationAndUploadBeforeReversion() async throws {
        let entry = seedEntry("stop-join.jpg")
        let stalledUploader = NonCooperativeBackupUploader()
        let runner = makeRunner(uploader: stalledUploader, uploadStallTimeout: 60, uploadStallPollInterval: 5)
        let drainReturned = BackupUploadTestLatch()
        let stopReturned = BackupUploadTestLatch()
        let drain = Task {
            let progress = await runner.runUntilDrained()
            await drainReturned.signal()
            return progress
        }

        await stalledUploader.uploadStarted.wait()
        let stop = Task {
            await runner.stop()
            await stopReturned.signal()
        }
        await stalledUploader.cancelStarted.wait()
        await Task.yield()
        XCTAssertEqual(stalledUploader.cancellations, 1)
        let stopReturnedBeforeNativeCancel = await stopReturned.isSignaled()
        let drainReturnedBeforeNativeCancel = await drainReturned.isSignaled()
        XCTAssertFalse(stopReturnedBeforeNativeCancel)
        XCTAssertFalse(drainReturnedBeforeNativeCancel)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "stop must not requeue while native cancellation and upload remain blocked")

        await stalledUploader.cancelRelease.signal()
        await Task.yield()
        let stopReturnedBeforeUploadSettlement = await stopReturned.isSignaled()
        let drainReturnedBeforeUploadSettlement = await drainReturned.isSignaled()
        XCTAssertFalse(stopReturnedBeforeUploadSettlement)
        XCTAssertFalse(drainReturnedBeforeUploadSettlement)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "stop must join the upload after native cancellation returns")

        await stalledUploader.uploadRelease.signal()
        await stop.value
        _ = await drain.value

        let stopReturnedAfterSettlement = await stopReturned.isSignaled()
        let drainReturnedAfterSettlement = await drainReturned.isSignaled()
        XCTAssertTrue(stopReturnedAfterSettlement)
        XCTAssertTrue(drainReturnedAfterSettlement)
        XCTAssertEqual(stalledUploader.cancellations, 1, "stop must issue one native cancellation")
        XCTAssertEqual(state(of: entry), .queuedForUpload)
    }

    func testStopAfterUploadDecisionSettlesClaimBeforeRevertingQueueRow() async throws {
        let entry = seedEntry("stop-after-resolve.jpg")
        let identityResolver = StopAfterResolveIdentityResolver()
        let runner = makeRunner(identityResolver: identityResolver)
        let drain = Task { await runner.runUntilDrained() }

        while !(await identityResolver.hasStarted()) {
            await Task.yield()
        }
        await runner.stop()
        await identityResolver.resumeResolve()
        let progress = await drain.value
        let settlementCount = await identityResolver.settlementCount()

        XCTAssertEqual(settlementCount, 1)
        XCTAssertEqual(state(of: entry), .discovered)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertFalse(progress.isRunning)
    }

    func testManifestFailureAfterRemoteCommitReconcilesWithoutSecondUpload() async throws {
        let entry = seedEntry("committed-before-manifest.jpg")
        let pipeline = makePipeline()
        let failing = RecordFailingIdentityResolver(inner: pipeline, failures: 2)

        _ = await makeRunner(identityResolver: failing).runUntilDrained(mode: .eligibleOnly)

        let pending = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(pending.state, .needsRemoteReconciliation)
        XCTAssertNotNil(pending.remoteCommitReconciliation)
        XCTAssertEqual(pending.remoteCommitReconciliation?.descriptor?.source, entry.source)
        XCTAssertEqual(pending.remoteCommitReconciliation?.descriptor?.filename, entry.originalFilename)
        XCTAssertEqual(pending.remoteCommitReconciliation?.descriptor?.fileSize, entry.byteCount)
        XCTAssertEqual(pending.remoteCommitReconciliation?.queueBinding?.source, entry.source)
        XCTAssertEqual(pending.remoteCommitReconciliation?.queueBinding?.revision, entry.revision)
        XCTAssertEqual(uploader.requests.count, 1, "the server commit happened exactly once")

        clock.advance(by: 2)
        let progress = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(uploader.requests.count, 1, "reconciliation must never upload committed bytes again")
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    private func seedEntry(
        _ id: String,
        state: UploadBackupSyncQueueState = .discovered,
        attempts: Int = 0,
        ageSeconds: TimeInterval = 60,
        revisionOffset: Int64 = 0
    ) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/\(id)")),
            // A nonzero offset queues the same source again under a new revision, as a rescan does.
            revision: UploadBackupRevision(
                rawValue: UploadBackupRevision(date: resolver.defaultModified).rawValue + revisionOffset),
            originalFilename: id,
            byteCount: 4,
            state: state,
            attempts: attempts,
            updatedAt: clock.now.addingTimeInterval(-ageSeconds)
        )
        queueStore.upsert(entry)
        return entry
    }

    /// The (nameHash, contentHash) pair the pipeline will compute for a standard resolved entry.
    private func expectedHashes(id: String) -> (nameHash: String, contentHash: String) {
        let path = URL(fileURLWithPath: "/backup/\(id)").standardizedFileURL.path
        return ("nh(\(id))", expectedContentHash(path: path))
    }

    private func expectedContentHash(path: String) -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in path.utf8.enumerated() { digest[i % 20] ^= byte }
        let hex = UploadContentSHA1.hexString(digest: digest)
        return "ch(\(hex))"
    }

    private func state(of entry: UploadBackupSyncQueueEntry) -> UploadBackupSyncQueueState? {
        queueStore.entry(for: entry.source, revision: entry.revision)?.state
    }

    func testRemoteIndexPreparationFailureLeavesQueueRunnableAndFailsClosed() async throws {
        let entry = seedEntry("waiting.jpg")
        let runner = makeRunner(identityResolver: PreparationFailingIdentityResolver(inner: makePipeline()))

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .discovered)
        XCTAssertTrue(progress.remoteIndexPreparationFailed)
        XCTAssertEqual(progress.remoteIndexPreparation?.completed, 10)
        XCTAssertEqual(progress.remoteIndexPreparationIssue?.kind, .remoteService)
        var persistedIssue = try XCTUnwrap(queueStore.runtimeIssue(for: .remoteIndexPreparation))
        XCTAssertEqual(persistedIssue.kind, .remoteService)
        XCTAssertEqual(persistedIssue.automaticRetryAttempt, 1)
        XCTAssertEqual(persistedIssue.nextAttemptAt, clock.now.addingTimeInterval(1))
        XCTAssertTrue(uploader.requests.isEmpty)

        let secondFailure = makeRunner(identityResolver: PreparationFailingIdentityResolver(inner: makePipeline()))
        _ = await secondFailure.runUntilDrained()
        persistedIssue = try XCTUnwrap(queueStore.runtimeIssue(for: .remoteIndexPreparation))
        XCTAssertEqual(persistedIssue.automaticRetryAttempt, 2)
        XCTAssertEqual(persistedIssue.nextAttemptAt, clock.now.addingTimeInterval(2))

        let retry = makeRunner()
        let recovered = await retry.runUntilDrained()
        XCTAssertNil(queueStore.runtimeIssue(for: .remoteIndexPreparation))
        XCTAssertEqual(recovered.uploaded, 1)
    }

    func testScopedUserRetryInvalidatesTheRemoteViewWithoutChangingEligibility() async throws {
        let entry = seedEntry("future-network.jpg")
        let future = clock.now.addingTimeInterval(600)
        XCTAssertTrue(
            queueStore.updateState(
                source: entry.source, revision: entry.revision, state: .discovered, attempts: 3,
                lastError: BackupIssueRecord(kind: .network, detail: "offline", nextAttemptAt: future).persistedValue,
                updatedAt: future))
        let before = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        let log = BackupEventLog()
        let runner = makeRunner(identityResolver: SpyIdentityResolver(inner: makePipeline(), log: log))
        await runner.invalidateRemoteStateForUserRetry()
        XCTAssertEqual(log.events, ["manifest.invalidateCachedRemoteState"])
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision), before)
    }

    func testManualRetryClearsPersistedRemoteIndexBackoff() async throws {
        XCTAssertTrue(
            queueStore.setRuntimeIssue(
                BackupIssueRecord(
                    kind: .remoteService,
                    detail: "temporarily unavailable",
                    nextAttemptAt: clock.now.addingTimeInterval(64),
                    automaticRetryAttempt: 7
                ),
                for: .remoteIndexPreparation
            ))

        let changed = await makeRunner().makeRetryableWorkEligibleNow()

        XCTAssertEqual(changed, 1)
        XCTAssertNil(queueStore.runtimeIssue(for: .remoteIndexPreparation))
    }

    func testRunRequeuesStaleActiveRowsAndProcessesThem() async throws {
        let log = BackupEventLog()
        let spyQueue = SpyQueueStore(inner: queueStore, log: log)
        let stuckUploading = seedEntry("stuck-upload.jpg", state: .uploading)
        let stuckChecking = seedEntry("stuck-check.jpg", state: .checking)

        let runner = makeRunner(queue: spyQueue)
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(log.events.first, "queue.requeueStaleActive", "recovery must run before any draining")
        XCTAssertEqual(state(of: stuckUploading), .completed)
        XCTAssertEqual(state(of: stuckChecking), .completed)
        XCTAssertEqual(uploader.requests.count, 2)
        XCTAssertEqual(progress.uploaded, 2)
        XCTAssertEqual(progress.backedUp, 2)
        XCTAssertFalse(progress.isRunning)
    }

    func testSourceMissingIsRemovedWithoutFailure() async throws {
        let entry = seedEntry("gone.jpg")
        resolver.set(.missing, for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.sourceMissing, 0)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)

        // A second pass has no row to resurrect or re-resolve.
        _ = await runner.runUntilDrained()
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision))
    }

    func testPhotoLibraryDeletionCancelsInFlightUploadAndDoesNotRecreateQueueRow() async throws {
        let source = UploadSourceIdentity(
            kind: .photoLibraryAsset,
            identifier: "deleted-during-upload",
            resource: .primary
        )
        let entry = UploadBackupSyncQueueEntry(
            source: source,
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: "deleted.heic",
            byteCount: 4,
            updatedAt: clock.now
        )
        XCTAssertTrue(queueStore.upsert(entry))

        let stalledUploader = NonCooperativeBackupUploader()
        let runner = BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: resolver,
            identityResolver: makePipeline(),
            uploader: stalledUploader,
            configuration: .init(uploadStallTimeout: 60, uploadStallPollInterval: 5),
            clock: BackupContinuousClock(),
            now: { [clock] in clock!.now }
        )
        let drain = Task { await runner.runUntilDrained() }
        await stalledUploader.uploadStarted.wait()

        let removal = Task { await runner.removePhotoLibraryAssets([source.identifier]) }
        await stalledUploader.cancelStarted.wait()

        XCTAssertNil(
            queueStore.entry(for: source, revision: entry.revision),
            "local deletion must become authoritative before native cancellation returns")
        let progressWhileNativeCancellationIsPending = await runner.currentProgress()
        XCTAssertEqual(progressWhileNativeCancellationIsPending.total, 0)

        await stalledUploader.cancelRelease.signal()
        await stalledUploader.uploadRelease.signal()
        let removed = await removal.value
        XCTAssertEqual(removed, 1)
        let progress = await drain.value

        XCTAssertEqual(stalledUploader.cancellations, 1)
        XCTAssertNil(queueStore.entry(for: source, revision: entry.revision))
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(progress.sourceMissing, 0)
    }

    func testPhotoDeletedDuringItsIdentityPassReleasesItsTempFiles() async throws {
        let entry = seedEntry("deleted-during-download.heic")
        let removing = SourceRemovedDuringResolveResolver(inner: resolver)
        let runner = makeRunner(resolver: removing)
        removing.onResolve = { entry in
            _ = await runner.removeSources(kind: entry.source.kind, identifiers: [entry.source.identifier])
        }

        _ = await runner.runUntilDrained()

        XCTAssertEqual(removing.cleanupCount, 1, "a staged iCloud original must not outlive a deleted photo")
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    /// Optimize Storage: the identity pass downloads the original from iCloud and stages it. When Proton already
    /// holds the same bytes, nothing uploads and the staged copy leaves the device.
    func testAnICloudOriginalAlreadyInProtonIsNotUploadedAndItsStagedCopyIsReleased() async throws {
        let entry = seedEntry("icloud-duplicate.heic")
        let hashes = expectedHashes(id: "icloud-duplicate.heic")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash, contentHash: hashes.contentHash, linkState: .active, linkID: "remote-1"
            )
        ]
        // Without a removal, the wrapper only counts the release of the staged files.
        let staging = SourceRemovedDuringResolveResolver(inner: resolver)
        let runner = makeRunner(resolver: staging)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertTrue(uploader.requests.isEmpty, "a photo already in Proton must not upload again")
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(staging.cleanupCount, 1, "the staged iCloud original must not stay on the device")
    }

    func testDraftBlocksWithBackoffAndNeverCountsAsBackedUp() async throws {
        let entry = seedEntry("draft.jpg")
        let hashes = expectedHashes(id: "draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash, contentHash: nil, linkState: .draft, linkID: nil
            )
        ]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 1)
        XCTAssertEqual(progress.blocked, 1)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertLessThan(progress.fraction, 1.0, "a blocked row must keep the fraction honest")
        let issue = try XCTUnwrap(
            BackupIssueRecord.decode(
                queueStore.entry(for: entry.source, revision: entry.revision)?.lastError
            ))
        XCTAssertEqual(issue.kind, .remoteDraft)
        XCTAssertNotNil(issue.nextAttemptAt)

        // Next pass after the backoff window: re-checked once more, still blocked, attempts grow.
        clock.advance(by: 120)
        let findsBefore = checker.findCallCount
        _ = await runner.runUntilDrained()
        XCTAssertGreaterThan(checker.findCallCount, findsBefore, "the draft must be re-checked")
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 2)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testManualRetryRechecksDraftImmediatelyWithoutBlindUpload() async throws {
        let entry = seedEntry("manual-draft.jpg")
        let hashes = expectedHashes(id: "manual-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: nil,
                linkState: .draft,
                linkID: nil
            )
        ]
        let runner = makeRunner()
        _ = await runner.runUntilDrained()
        let first = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(first.state, .blockedByDraft)
        XCTAssertGreaterThan(first.updatedAt, clock.now)

        let findsBefore = checker.findCallCount
        let madeEligible = await runner.makeRetryableWorkEligibleNow()
        XCTAssertEqual(madeEligible, 1)
        let madeDue = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(madeDue.state, .discovered)
        XCTAssertEqual(madeDue.updatedAt, clock.now)
        XCTAssertEqual(madeDue.attempts, 1)

        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertGreaterThan(checker.findCallCount, findsBefore, "manual retry must bypass the cached draft answer")
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.state, .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 2)
        XCTAssertTrue(uploader.requests.isEmpty, "a repeated draft must remain fail-closed")
    }

    func testForeignDraftBecomesDismissiblePermanentFailureAtRetryLimit() async throws {
        let entry = seedEntry("foreign-draft.jpg")
        let hashes = expectedHashes(id: "foreign-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: nil,
                linkState: .draft,
                linkID: "foreign-draft",
                clientUID: "another-installation"
            )
        ]
        let runner = makeRunner(retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 2))

        _ = await runner.runUntilDrained()
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        clock.advance(by: 120)
        let progress = await runner.runUntilDrained()

        let parked = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(parked.state, .failedPermanent)
        XCTAssertEqual(parked.attempts, 2)
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .remoteDraftStale)
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.blocked, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testOwnInterruptedDraftUploadsThroughExplicitOverride() async throws {
        let entry = seedEntry("own-draft.jpg")
        let hashes = expectedHashes(id: "own-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: hashes.contentHash,
                linkState: .draft,
                linkID: "own-draft",
                clientUID: "this-installation"
            )
        ]
        let pipeline = UploadDedupePipeline(
            store: identityStore,
            hasher: hasher,
            checker: checker,
            currentClientUID: "this-installation",
            now: { [clock] in clock!.now }
        )
        let runner = makeRunner(identityResolver: pipeline)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(uploader.requests.first).overrideExistingDraft)
    }

    func testApplePhotosTagsReachTheUploadOfTheMainPhoto() async throws {
        let entry = seedEntry("favorite-screenshot.png")
        let tags = [PhotoTag.favorites.rawValue, PhotoTag.screenshots.rawValue]
        let runner = makeRunner(resolver: TaggingBackupResolver(inner: resolver, tags: tags))

        _ = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(uploader.requests.map(\.tags), [tags], "the photo must land in Favorites and Screenshots")
    }

    func testCompoundTagsJoinTheSourceTagsOnce() {
        XCTAssertEqual(BackupSyncRunner.primaryTags(for: [], sourceTags: [1, 0, 1]), [0, 1])
        XCTAssertEqual(BackupSyncRunner.primaryTags(for: []), [])
    }

    func testActiveDuplicateBecomesAlreadyBackedUpWithoutUpload() async throws {
        let entry = seedEntry("dup.jpg")
        let hashes = expectedHashes(id: "dup.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash, contentHash: hashes.contentHash, linkState: .active, linkID: "remote-1"
            )
        ]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertTrue(uploader.requests.isEmpty, "an active duplicate must never re-upload bytes")
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(progress.fraction, 1.0)

        // The preflight index now proves the revision complete - the "backed up" claim is durable.
        let record = stateStore.record(
            for: entry.source,
            revision: UploadBackupRevision(date: resolver.defaultModified)
        )
        XCTAssertEqual(record?.isComplete, true)
    }

    func testActiveDuplicateNeverMaterializesDeferredBytes() async throws {
        let entry = seedEntry("deferred-duplicate.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        let hashes = expectedHashes(id: "deferred-duplicate.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: hashes.contentHash,
                linkState: .active,
                linkID: "remote-deferred"
            )
        ]

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(
            resolver.materializeCount(for: entry.source.identifier), 0,
            "hash-only PhotoKit probes must not create temp files for known duplicates")
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(progress.backedUp, 1)
    }

    func testNewDeferredResourceMaterializesExactlyOnceBeforeUpload() async throws {
        let entry = seedEntry("deferred-new.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(resolver.materializeCount(for: entry.source.identifier), 1)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertTrue(uploader.requests[0].fileURL.path.hasSuffix(".materialized"))
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testDeferredResourceChangeIsRehashedBeforeAnyUpload() async throws {
        let entry = seedEntry("deferred-changing.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier, mismatchOnce: true)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            resolver.materializeCount(for: entry.source.identifier), 2,
            "a changed export must be discarded and freshly resolved")
        XCTAssertEqual(uploader.requests.count, 1, "stale hash identity must never reach the uploader")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testTrashedAndDeletedRemoteDuplicatesAreNotBackedUp() async throws {
        let trashed = seedEntry("trashed.jpg")
        let deleted = seedEntry("deleted.jpg")
        let trashedHashes = expectedHashes(id: "trashed.jpg")
        let deletedHashes = expectedHashes(id: "deleted.jpg")
        checker.remoteItemsByNameHash[trashedHashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: trashedHashes.nameHash, contentHash: trashedHashes.contentHash, linkState: .trashed,
                linkID: "t-1"
            )
        ]
        checker.remoteItemsByNameHash[deletedHashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: deletedHashes.nameHash, contentHash: deletedHashes.contentHash, linkState: nil, linkID: "d-1"
            )
        ]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: trashed), .skippedRemoteDeletion)
        XCTAssertEqual(state(of: deleted), .skippedRemoteDeletion)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(progress.skippedRemoteDeletions, 2)
        XCTAssertEqual(progress.backedUp, 0, "respected deletions must never count as backed up")
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertEqual(state(of: trashed)?.isTerminalSuccess, true)
        XCTAssertEqual(state(of: deleted)?.isTerminalSuccess, true)
        XCTAssertEqual(stateStore.count(), 0, "no preflight completeness record may exist for skipped deletions")
    }

    func testUploadRecordsManifestBeforeQueueCompletion() async throws {
        let log = BackupEventLog()
        let spyQueue = SpyQueueStore(inner: queueStore, log: log)
        let spyResolver = SpyIdentityResolver(inner: makePipeline(), log: log)
        _ = seedEntry("fresh.jpg")

        let runner = makeRunner(identityResolver: spyResolver, queue: spyQueue)
        _ = await runner.runUntilDrained()

        let recordIndex = try XCTUnwrap(log.firstIndex(of: "manifest.recordUploaded"))
        let completedIndex = try XCTUnwrap(log.firstIndex(of: "queue.state:completed"))
        XCTAssertLessThan(
            recordIndex, completedIndex,
            "the manifest must remember the upload before the queue row turns terminal")
    }

    func testCrashAfterUploadBeforeRecordResolvesToDuplicateOnRetry() async throws {
        let entry = seedEntry("crash.jpg")
        let hashes = expectedHashes(id: "crash.jpg")
        let crashingUploader = CrashAfterUploadUploader(
            checker: checker,
            contentHashByName: ["crash.jpg": hashes.contentHash]
        )

        let runner = makeRunner(uploader: crashingUploader)
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(crashingUploader.attempts, 1, "the retry must NOT upload the bytes again")
        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(hasher.hashCount, 1, "the persisted identity must spare the rehash on retry")
    }

    func testTransientFailuresBackOffAndEventuallySucceed() async throws {
        let entry = seedEntry("flaky.jpg")
        resolver.set(.transientFailure(times: 3), for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 4)
        // Exponential waits for attempts 1..3 must actually be scheduled (no hot loop).
        for expected in [1.0, 2.0, 4.0] {
            XCTAssertTrue(clock.sleeps.contains(expected), "missing backoff wait of \(expected)s in \(clock.sleeps)")
        }
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testRetryBudgetParksAsFailedInsteadOfHotLooping() async throws {
        let entry = seedEntry("broken.jpg")
        resolver.set(.transientFailure(times: 99), for: entry.source.identifier)

        let runner = makeRunner(retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 3))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .failed)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 3)
        XCTAssertEqual(
            resolver.resolveCount(for: entry.source.identifier), 3, "parked items must stop consuming attempts")
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.needsAttention, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testRetryableServiceFailureDoesNotExhaustItemBudget() async throws {
        let entry = seedEntry("server-flaky.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            serviceFailures: ["server-flaky.jpg": 5]
        )

        let runner = makeRunner(
            uploader: flakyUploader,
            retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 2)
        )
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(flakyUploader.requests.count, 6)
        XCTAssertEqual(progress.failed, 0, "temporary service failures must never strand valid media")
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0)
        XCTAssertEqual(
            clock.sleeps.filter { $0 >= 1 }, [1, 2, 4, 8, 16],
            "service retries use durable capped backoff without consuming the item budget")
    }

    func testEnvironmentalBackoffOrdinalSurvivesRunnerRecreation() async throws {
        let entry = seedEntry("recreated-runner.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            serviceFailures: ["recreated-runner.jpg": 2]
        )
        let retry = BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 2)

        _ = await makeRunner(uploader: flakyUploader, retry: retry)
            .runUntilDrained(mode: .eligibleOnly)
        var stored = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        var issue = try XCTUnwrap(BackupIssueRecord.decode(stored.lastError))
        XCTAssertEqual(issue.automaticRetryAttempt, 1)
        XCTAssertEqual(issue.nextAttemptAt, clock.now.addingTimeInterval(1))
        XCTAssertEqual(stored.attempts, 0)

        clock.advance(by: 1)
        _ = await makeRunner(uploader: flakyUploader, retry: retry)
            .runUntilDrained(mode: .eligibleOnly)
        stored = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        issue = try XCTUnwrap(BackupIssueRecord.decode(stored.lastError))
        XCTAssertEqual(issue.automaticRetryAttempt, 2)
        XCTAssertEqual(issue.nextAttemptAt, clock.now.addingTimeInterval(2))
        XCTAssertEqual(stored.attempts, 0)

        clock.advance(by: 2)
        let recovered = await makeRunner(uploader: flakyUploader, retry: retry)
            .runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(recovered.uploaded, 1)
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testNetworkAndServiceFailuresShareOneEnvironmentalBackoffSequence() async throws {
        let entry = seedEntry("mixed-outage.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            networkFailures: ["mixed-outage.jpg": 1],
            serviceFailures: ["mixed-outage.jpg": 1]
        )

        let progress = await makeRunner(uploader: flakyUploader).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0)
        XCTAssertEqual(
            clock.sleeps.filter { $0 >= 1 }, [1, 2],
            "switching from a timeout to a Proton 503 must not reset automatic backoff")
    }

    func testEnvironmentalBackoffCapsWithoutParkingValidItem() async throws {
        let entry = seedEntry("long-outage.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            serviceFailures: ["long-outage.jpg": 7]
        )
        let retry = BackupRetryPolicy(baseDelay: 1, maxDelay: 4, maxAttempts: 2)

        let progress = await makeRunner(uploader: flakyUploader, retry: retry).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0)
        XCTAssertEqual(clock.sleeps.filter { $0 >= 1 }, [1, 2, 4, 4, 4, 4, 4])
    }

    func testLegacyThrottleDoesNotOwnCriticalHeavyWorkAdmission() async throws {
        let entry = seedEntry("hot.jpg")

        let runner = makeRunner(throttleInputs: { BackupThrottleInputs(thermalLevel: .critical) })
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            state(of: entry), .completed,
            "the legacy network throttle does not own local heavy-work admission")
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testAutomaticBackgroundBackupCompletesWithReducedCacheBudget() async throws {
        let entry = seedEntry("background.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        await MainActor.run {
            MemoryPressureGovernor(runtimeState: runtimeState).update(MemoryConditions(isBackgrounded: true))
        }
        let coordinator = LibraryResourceCoordinator(runtimeState: runtimeState)
        let budget = await coordinator.budget(
            for: LibraryWorkRequest(workload: .backupMaterialization, intent: .automatic))
        XCTAssertTrue(budget.isAdmitted)
        guard budget.isAdmitted else { return }

        let progress = await makeRunner(resourceCoordinator: coordinator).runUntilDrained(
            mode: .eligibleOnly, workIntent: .automatic
        )

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(resolver.materializeCount(for: entry.source.identifier), 1)
        XCTAssertEqual(runtimeState.snapshot().memoryBudgetTier, .reduced)
        let metrics = await coordinator.metrics()
        XCTAssertGreaterThanOrEqual(metrics.permitsAcquired, 2)
        XCTAssertEqual(metrics.permitsAcquired, metrics.permitsReleased)
    }

    func testEnforcedCoordinatorDefersAutomaticBackupHeavyWorkUntilStableRecovery() async throws {
        let entry = seedEntry("coordinated.jpg")
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .critical))
        let coordinator = LibraryResourceCoordinator(
            runtimeState: runtimeState,
            recoveryDelay: .milliseconds(20)
        )
        await coordinator.startObserving()
        let runner = makeRunner(resourceCoordinator: coordinator)

        let drain = Task {
            await runner.runUntilDrained(mode: .eligibleOnly, workIntent: .automatic)
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        let pausedMetrics = await coordinator.metrics()
        XCTAssertEqual(pausedMetrics.policyPauses, 1)

        runtimeState.update { $0.thermalLevel = .nominal }
        let progress = await drain.value
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        let finalMetrics = await coordinator.metrics()
        XCTAssertGreaterThanOrEqual(finalMetrics.permitsAcquired, 2)
        XCTAssertEqual(finalMetrics.permitsAcquired, finalMetrics.permitsReleased)
    }

    func testEnforcedCoordinatorAllowsOneFileManualBackupAtSeriousPressure() async throws {
        let entry = seedEntry("manual-hot.jpg")
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .serious))
        let coordinator = LibraryResourceCoordinator(runtimeState: runtimeState)
        let runner = makeRunner(resourceCoordinator: coordinator)

        let progress = await runner.runUntilDrained(
            mode: .eligibleOnly,
            workIntent: .userInitiated
        )

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        let metrics = await coordinator.metrics()
        XCTAssertGreaterThanOrEqual(metrics.permitsAcquired, 2)
        XCTAssertEqual(metrics.permitsAcquired, metrics.permitsReleased)
    }

    func testConcurrentIdenticalContentUploadsExactlyOnce() async throws {
        let first = seedEntry("copy-a.jpg")
        let second = seedEntry("copy-b.jpg")
        hasher.contentSeeds["/backup/copy-a.jpg"] = "identical-bytes"
        hasher.contentSeeds["/backup/copy-b.jpg"] = "identical-bytes"
        let slowUploader = MockUploader(workDuration: .milliseconds(40), deliverProgress: false)

        let runner = makeRunner(uploader: slowUploader, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            slowUploader.requests.count, 1,
            "identical bytes in the same wave must coalesce to one upload")
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 2, "both sources must end up proven backed up")
        let states = [state(of: first), state(of: second)]
        XCTAssertTrue(states.contains(.completed) && states.contains(.alreadyBackedUp), "got \(states)")
    }

    func testLivePhotoCompoundUploadsPairedVideoWithPrimaryReference() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["live.heic", "live.mov"],
            "the paired video uploads after its primary")
        XCTAssertEqual(
            uploader.requests.map(\.tags),
            [
                [PhotoTag.livePhotos.rawValue],
                [PhotoTag.livePhotos.rawValue],
            ], "both resources must carry Proton's Live Photo classification")
        let pairedRequest = try XCTUnwrap(uploader.requests.last)
        XCTAssertEqual(
            pairedRequest.mainPhotoUID, testUID("live.heic"),
            "the paired video must reference its freshly-uploaded primary")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1, "a compound is ONE user-facing item")
        let record = stateStore.record(
            for: entry.source, revision: UploadBackupRevision(date: resolver.defaultModified)
        )
        XCTAssertEqual(record?.isComplete, true)
        XCTAssertEqual(record?.resourceCount, 2)
    }

    // MARK: - Edited photos replace their earlier upload

    private struct ReplacementHarness {
        let journal: EditReplacementJournalFileStore
        let pipeline: UploadDedupePipeline
        let remote: FakeEditReplacementRemote
        let replacement: EditedPhotoReplacement
    }

    private func makeReplacementHarness() throws -> ReplacementHarness {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: tempDir))
        let pipeline = UploadDedupePipeline(
            store: identityStore, hasher: hasher, checker: checker, replacementJournal: journal,
            now: { [clock] in clock!.now })
        let remote = FakeEditReplacementRemote()
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: FakeAlbumCarryOver(), relations: checker, identities: identityStore,
            journal: journal)
        // The server names every upload that referenced a main photo as one of its related photos, and each upload
        // creates a new photo even when its name uploaded before.
        uploader.distinctNodesForRepeatedNames = true
        checker.relatedLinkIDsProvider = { [uploader] mainLinkID in
            Set(uploader!.uploaded.filter { $0.request.mainPhotoUID?.nodeID == mainLinkID }.map(\.uid.nodeID))
        }
        // The duplicate check reads link states from the same fake that the replacement trashes in.
        checker.linkActivityProvider = { [remote] linkID in remote.active.contains { $0.nodeID == linkID } }
        return ReplacementHarness(journal: journal, pipeline: pipeline, remote: remote, replacement: replacement)
    }

    private func seedLibraryEntry(_ name: String, revisionOffset: Int64 = 0) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "/library/IMG_1"),
            revision: UploadBackupRevision(
                rawValue: UploadBackupRevision(date: resolver.defaultModified).rawValue + revisionOffset),
            originalFilename: name,
            byteCount: 4,
            state: .discovered,
            attempts: 0,
            updatedAt: clock.now.addingTimeInterval(-60)
        )
        queueStore.upsert(entry)
        return entry
    }

    /// Uploads IMG_1.HEIC with a Live Photo video, then edits the photo in the library: new bytes, new name, and
    /// the original becomes a secondary of the edit.
    private func uploadThenEdit(
        _ harness: ReplacementHarness, keepsOriginal: Bool = true
    ) async -> UploadBackupSyncQueueEntry {
        let first = seedLibraryEntry("IMG_1.HEIC")
        resolver.setSecondaries(["IMG_1.MOV"], for: first.source.identifier)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()
        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_1.HEIC", "IMG_1.MOV"])
        XCTAssertTrue(harness.remote.trashCalls.isEmpty, "a first upload replaces nothing")

        hasher.contentSeeds[first.source.identifier] = "rotated"
        harness.remote.active = [testUID("IMG_1.HEIC"), testUID("IMG_1.JPG")]
        if keepsOriginal {
            resolver.setSecondaries(["IMG_1.HEIC", "IMG_1.MOV"], for: first.source.identifier)
            resolver.setSecondaryResource(.photoKit(role: "originalPhoto", ordinal: 0), forName: "IMG_1.HEIC")
        }
        return seedLibraryEntry("IMG_1.JPG", revisionOffset: 1)
    }

    func testUploadEvidenceCarriesOnlyTheRevisionsSupersededMain() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness)
        let historical = PhotoUID(volumeID: "vol", nodeID: "restored-history")
        try harness.journal.addSuperseded(historical, for: edited.source)
        try harness.journal.settle(
            [historical.nodeID], related: ["historical-video"], trashed: true, for: edited.source)
        let pending = try XCTUnwrap(
            PendingBackupManifestStore(url: tempDir.appendingPathComponent("pending-evidence.sqlite")))
        defer { pending.close() }
        let recorder = PendingBackupEventRecorder(store: pending)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement, events: recorder)
            .runUntilDrained()
        XCTAssertEqual(state(of: edited), .completed)
        let record = try XCTUnwrap(
            recorder.replacementLedger.evidence(for: PendingSourceKey(edited.source), revision: edited.revision))
        XCTAssertEqual(record.replaces?.map(\.nodeID), [testUID("IMG_1.HEIC").nodeID])
        XCTAssertTrue(
            harness.journal.entry(for: edited.source).superseded.isEmpty, "the journal has already retired the main")
    }

    func testCosmeticSettlementDoesNotRetryFinishedUploadOrChangeTrash() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness)
        let events = SpyBackupItemEvents(queue: queueStore)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement, events: events)
            .runUntilDrained()
        XCTAssertTrue(events.events.contains(.settlement(edited.source.identifier)))
        XCTAssertEqual(state(of: edited), .completed)
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])
        XCTAssertEqual(
            uploader.requests.map(\.name), ["IMG_1.HEIC", "IMG_1.MOV", "IMG_1.JPG", "IMG_1.HEIC", "IMG_1.MOV"])
    }

    func testAnEditedPhotoReplacesItsEarlierUploadAndKeepsItsSecondariesUnderTheNewPhoto() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness)
        // The resource structure of the unedited photo, as the preflight index remembers it.
        let unedited = UploadBackupRevision(rawValue: 1)
        stateStore.upsert(
            UploadBackupAssetRecord(
                source: edited.source, revision: unedited, resourceCount: 2, pendingResourceCount: 0,
                updatedAt: clock.now))

        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["IMG_1.HEIC", "IMG_1.MOV", "IMG_1.JPG", "IMG_1.HEIC", "IMG_1.MOV"],
            "the original and the video upload again: their earlier copies leave with the earlier photo")
        XCTAssertEqual(uploader.requests.last?.mainPhotoUID, testUID("IMG_1.JPG"))
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])
        XCTAssertEqual(state(of: edited), .completed)
        XCTAssertNil(
            stateStore.record(for: edited.source, revision: unedited),
            "the earlier upload is trashed, so undoing the edit must reach the duplicate check again")
        XCTAssertNotNil(
            stateStore.record(for: edited.source, revision: UploadBackupRevision(date: resolver.defaultModified)))
        XCTAssertEqual(
            harness.journal.entry(for: edited.source),
            EditReplacementJournalEntry(
                superseded: [], retired: [testUID("IMG_1.HEIC").nodeID, testUID("IMG_1.MOV").nodeID],
                uploadedEdit: true, proven: [testUID("IMG_1.HEIC").nodeID]))
    }

    func testAnEditedPhotoNamesTheUploadItReplacesForOtherDevices() async throws {
        let harness = try makeReplacementHarness()
        _ = await uploadThenEdit(harness)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()

        let lineage = UploadLineageMarker.sectionName
        let first = try XCTUnwrap(uploader.requests.first)
        XCTAssertEqual(first.name, "IMG_1.HEIC")
        XCTAssertFalse(first.additionalMetadata.contains { $0.name == lineage }, "a first upload replaces nothing")
        let edit = try XCTUnwrap(uploader.requests.first { $0.name == "IMG_1.JPG" })
        let section = try XCTUnwrap(edit.additionalMetadata.first { $0.name == lineage })
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: section.utf8JsonValue) as? [String: Any])
        XCTAssertEqual(marker["V"] as? Int, 1)
        XCTAssertEqual(marker["Reason"] as? String, "edit")
        XCTAssertEqual(marker["Replaces"] as? [String], [testUID("IMG_1.HEIC").nodeID])
        XCTAssertTrue(
            uploader.requests.filter { $0.mainPhotoUID != nil }
                .allSatisfy { request in !request.additionalMetadata.contains { $0.name == lineage } },
            "related files carry no marker")
    }

    func testAFailedTrashRetriesWithoutUploadingTheEditedPhotoAgain() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness)
        harness.remote.trashFailures = 1

        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["IMG_1.HEIC", "IMG_1.MOV", "IMG_1.JPG", "IMG_1.HEIC", "IMG_1.MOV"])
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])
        XCTAssertEqual(state(of: edited)?.isTerminalSuccess, true)
    }

    func testAnEditWithoutItsOriginalKeepsTheEarlierUpload() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness, keepsOriginal: false)
        let runner = makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)

        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(harness.remote.trashCalls.isEmpty, "the earlier upload may be the only copy of the original")
        // The marker names the earlier upload already. It stays active until the original arrives, and a reader
        // counts only a named link outside the library as replaced.
        let section = try XCTUnwrap(
            try XCTUnwrap(uploader.requests.first { $0.name == "IMG_1.JPG" }).additionalMetadata
                .first { $0.name == UploadLineageMarker.sectionName })
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: section.utf8JsonValue) as? [String: Any])
        XCTAssertEqual(marker["Replaces"] as? [String], [testUID("IMG_1.HEIC").nodeID])
        let waiting = try XCTUnwrap(queueStore.entry(for: edited.source, revision: edited.revision))
        XCTAssertEqual(waiting.state, .discovered)
        XCTAssertEqual(waiting.attempts, edited.attempts)
        XCTAssertEqual(waiting.updatedAt.timeIntervalSince(clock.now), 64)
        let issue = try XCTUnwrap(BackupIssueRecord.decode(waiting.lastError))
        XCTAssertEqual(BackupFailedItem(entry: waiting).category, .automatic)
        XCTAssertEqual(BackupFailedItem(entry: waiting).reason, L10n.string("backup.issue_waiting_original"))
        XCTAssertEqual(issue.nextAttemptAt, waiting.updatedAt)
        XCTAssertEqual(issue.detail, "backup.issue_waiting_original", "the reason does not depend on the language")
        XCTAssertEqual(
            stateStore.record(for: edited.source, revision: UploadBackupRevision(date: resolver.defaultModified))?
                .isComplete, false,
            "an incomplete replacement must not count as backed up")
        XCTAssertEqual(
            harness.journal.entry(for: edited.source).superseded.map(\.nodeID), [testUID("IMG_1.HEIC").nodeID],
            "an upload that holds the original replaces the earlier photo later")

        let requests = uploader.requests.count
        clock.advance(by: 63)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(uploader.requests.count, requests, "the retry date prevents another early pass")
        XCTAssertEqual(state(of: edited), .discovered)

        resolver.setSecondaries(["IMG_1.HEIC", "IMG_1.MOV"], for: edited.source.identifier)
        resolver.setSecondaryResource(.photoKit(role: "originalPhoto", ordinal: 0), forName: "IMG_1.HEIC")
        clock.advance(by: 2)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(state(of: edited)?.isTerminalSuccess, true)
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])
        XCTAssertEqual(uploader.requests.filter { $0.name == "IMG_1.JPG" }.count, 1)
    }

    func testAnEditThatWaitedInAnEarlierBuildKeepsItsWaitCount() async throws {
        let harness = try makeReplacementHarness()
        var edited = await uploadThenEdit(harness, keepsOriginal: false)
        // An earlier build stored its own sentence as the reason of the wait.
        edited.lastError =
            BackupIssueRecord(
                kind: .unknown,
                detail: "The edited photo is waiting for its original resources. Backup will retry automatically.",
                nextAttemptAt: clock.now, automaticRetryAttempt: 2
            ).persistedValue
        XCTAssertTrue(queueStore.upsert(edited))

        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained(mode: .eligibleOnly)

        let waiting = try XCTUnwrap(queueStore.entry(for: edited.source, revision: edited.revision))
        XCTAssertEqual(waiting.state, .discovered)
        XCTAssertEqual(BackupIssueRecord.decode(waiting.lastError)?.automaticRetryAttempt, 3)
    }

    func testAnEditWaitsWhileItsLivePhotoVideoExistsOnlyUnderTheEarlierMain() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness)
        resolver.setSecondaries(["IMG_1.HEIC"], for: edited.source.identifier)
        let runner = makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)

        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        let waiting = try XCTUnwrap(queueStore.entry(for: edited.source, revision: edited.revision))
        XCTAssertEqual(waiting.state, .discovered)
        XCTAssertEqual(waiting.attempts, 0)
        XCTAssertTrue(harness.remote.trashCalls.isEmpty, "the original video still needs the earlier main")
        XCTAssertFalse(harness.journal.entry(for: edited.source).superseded.isEmpty)

        resolver.setSecondaries(["IMG_1.HEIC", "IMG_1.MOV"], for: edited.source.identifier)
        clock.advance(by: waiting.updatedAt.timeIntervalSince(clock.now) + 1)
        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: edited)?.isTerminalSuccess, true)
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])
        XCTAssertEqual(uploader.requests.filter { $0.name == "IMG_1.JPG" }.count, 1)
    }

    func testUndoingAnEditReplacesTheEditWithTheOriginal() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadThenEdit(harness)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])

        // Undo in Photos: the original bytes, the Live Photo video, and no edit evidence.
        hasher.contentSeeds[edited.source.identifier] = nil
        resolver.setSecondaries(["IMG_1.MOV"], for: edited.source.identifier)
        resolver.setEditRevision(.revision(UploadBackupRevision(rawValue: 7)), for: edited.source.identifier)
        harness.remote.active = [testUID("IMG_1.JPG")]
        let undone = seedLibraryEntry("IMG_1.HEIC", revisionOffset: 2)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()

        XCTAssertEqual(state(of: undone), .completed)
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")], [testUID("IMG_1.JPG")]])
        XCTAssertFalse(harness.journal.entry(for: edited.source).lastUploadWasEdit)
    }

    func testOtherBytesOfAnUneditedPhotoNameNoReplacement() async throws {
        let harness = try makeReplacementHarness()
        let first = seedLibraryEntry("IMG_1.HEIC")
        resolver.setEditRevision(.revision(UploadBackupRevision(rawValue: 7)), for: first.source.identifier)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()

        // Photos delivers other bytes of the same unedited photo, for example after an iCloud download.
        hasher.contentSeeds[first.source.identifier] = "redelivered"
        harness.remote.active = [testUID("IMG_1.HEIC")]
        let redelivered = seedLibraryEntry("IMG_1-1.HEIC", revisionOffset: 1)
        _ = await makeRunner(identityResolver: harness.pipeline, editReplacement: harness.replacement)
            .runUntilDrained()

        XCTAssertEqual(state(of: redelivered), .completed)
        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_1.HEIC", "IMG_1-1.HEIC"])
        XCTAssertTrue(harness.remote.trashCalls.isEmpty, "both photos stay")
        XCTAssertTrue(harness.journal.entry(for: redelivered.source).isEmpty)
        XCTAssertFalse(
            uploader.requests.contains { request in
                request.additionalMetadata.contains { $0.name == UploadLineageMarker.sectionName }
            }, "an upload that keeps its earlier upload names no replacement")
    }

    /// Uploads the series IMG_1.HEIC with the frames IMG_2.HEIC and IMG_3.HEIC, then edits its main frame: new
    /// bytes, a new name, and the original becomes a secondary of the edit. The earlier frames stay active rows with
    /// the same bytes under the earlier main photo.
    private func uploadSeriesThenEdit(_ harness: ReplacementHarness) async -> UploadBackupSyncQueueEntry {
        let first = seedLibraryEntry("IMG_1.HEIC")
        resolver.setBurstMembers(["IMG_2.HEIC", "IMG_3.HEIC"], for: first.source.identifier)
        _ = await makeRunner(
            tagAdder: SpyTagAdder(), identityResolver: harness.pipeline, editReplacement: harness.replacement
        ).runUntilDrained()
        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_1.HEIC", "IMG_2.HEIC", "IMG_3.HEIC"])
        for frame in ["IMG_2.HEIC", "IMG_3.HEIC"] {
            checker.remoteItemsByNameHash["nh(\(frame))"] = [
                RemotePhotoDuplicate(
                    nameHash: "nh(\(frame))", contentHash: expectedContentHash(path: "/library/IMG_1#\(frame)"),
                    linkState: .active, linkID: testUID(frame).nodeID)
            ]
        }

        hasher.contentSeeds[first.source.identifier] = "rotated"
        harness.remote.active = [testUID("IMG_1.HEIC"), testUID("IMG_1.JPG")]
        resolver.setSecondaries(["IMG_1.HEIC"], for: first.source.identifier)
        resolver.setSecondaryResource(.photoKit(role: "originalPhoto", ordinal: 0), forName: "IMG_1.HEIC")
        return seedLibraryEntry("IMG_1.JPG", revisionOffset: 1)
    }

    func testAnEditedSeriesReplacesItsEarlierSeries() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadSeriesThenEdit(harness)
        harness.remote.favorites = [testUID("IMG_1.HEIC")]

        _ = await makeRunner(
            tagAdder: SpyTagAdder(), identityResolver: harness.pipeline, editReplacement: harness.replacement
        ).runUntilDrained()

        let edit = Array(uploader.uploaded.dropFirst(3))
        XCTAssertEqual(
            edit.map(\.request.name), ["IMG_1.JPG", "IMG_1.HEIC", "IMG_2.HEIC", "IMG_3.HEIC"],
            "the original and every frame upload again under the edited main photo")
        let main = try XCTUnwrap(edit.first?.uid)
        XCTAssertEqual(edit.dropFirst().map(\.request.mainPhotoUID), Array(repeating: main, count: 3))
        XCTAssertEqual(edit.first?.request.tags, [PhotoTag.bursts.rawValue])
        XCTAssertTrue(
            try XCTUnwrap(edit.first).request.additionalMetadata.contains {
                $0.name == UploadLineageMarker.sectionName
            },
            "the edited series names the series it replaces")
        XCTAssertEqual(
            harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]],
            "only the earlier main photo moves to the trash; the server hides its frames with it")
        XCTAssertEqual(harness.remote.favoriteCalls, [[main]])
        XCTAssertEqual(state(of: edited), .completed)
        XCTAssertTrue(harness.journal.entry(for: edited.source).superseded.isEmpty)
    }

    func testAFrameThatThePersonDeletedStaysDeletedWhenTheSeriesIsEdited() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadSeriesThenEdit(harness)
        checker.remoteItemsByNameHash["nh(IMG_3.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_3.HEIC)", contentHash: expectedContentHash(path: "/library/IMG_1#IMG_3.HEIC"),
                linkState: .trashed, linkID: testUID("IMG_3.HEIC").nodeID)
        ]

        _ = await makeRunner(
            tagAdder: SpyTagAdder(), identityResolver: harness.pipeline, editReplacement: harness.replacement
        ).runUntilDrained()

        XCTAssertEqual(
            uploader.requests.dropFirst(3).map(\.name), ["IMG_1.JPG", "IMG_1.HEIC", "IMG_2.HEIC"],
            "the deleted frame does not come back with the edit")
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")]])
        XCTAssertEqual(state(of: edited), .completed)
    }

    func testUndoingASeriesEditReplacesTheEditedSeries() async throws {
        let harness = try makeReplacementHarness()
        let edited = await uploadSeriesThenEdit(harness)
        _ = await makeRunner(
            tagAdder: SpyTagAdder(), identityResolver: harness.pipeline, editReplacement: harness.replacement
        ).runUntilDrained()
        let editedMain = try XCTUnwrap(uploader.uploaded.first { $0.request.name == "IMG_1.JPG" }?.uid)

        // Undo in Photos: the original bytes and no edit evidence.
        hasher.contentSeeds[edited.source.identifier] = nil
        resolver.setSecondaries([], for: edited.source.identifier)
        resolver.setEditRevision(.revision(UploadBackupRevision(rawValue: 7)), for: edited.source.identifier)
        harness.remote.active = [editedMain]
        let undone = seedLibraryEntry("IMG_1.HEIC", revisionOffset: 2)
        _ = await makeRunner(
            tagAdder: SpyTagAdder(), identityResolver: harness.pipeline, editReplacement: harness.replacement
        ).runUntilDrained()

        let undo = Array(uploader.uploaded.dropFirst(7))
        XCTAssertEqual(undo.map(\.request.name), ["IMG_1.HEIC", "IMG_2.HEIC", "IMG_3.HEIC"])
        let main = try XCTUnwrap(undo.first?.uid)
        XCTAssertEqual(undo.dropFirst().map(\.request.mainPhotoUID), [main, main])
        XCTAssertEqual(harness.remote.trashCalls, [[testUID("IMG_1.HEIC")], [editedMain]])
        XCTAssertEqual(state(of: undone), .completed)
        XCTAssertFalse(harness.journal.entry(for: edited.source).lastUploadWasEdit)
    }

    func testSeriesUploadsMembersAsRelatedPhotosWithTheBurstsTag() async throws {
        let entry = seedEntry("IMG_0001.HEIC")
        resolver.setBurstMembers(["IMG_0002.HEIC", "IMG_0003.HEIC"], for: entry.source.identifier)
        let tagAdder = SpyTagAdder()

        let progress = await makeRunner(tagAdder: tagAdder).runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0003.HEIC"])
        XCTAssertEqual(
            uploader.requests.map(\.tags),
            Array(repeating: [PhotoTag.bursts.rawValue], count: 3),
            "the main photo and every member carry Proton's bursts tag at creation")
        XCTAssertEqual(
            uploader.requests.map(\.mainPhotoUID),
            [nil, testUID("IMG_0001.HEIC"), testUID("IMG_0001.HEIC")],
            "every member is a related photo of the freshly uploaded main photo")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1, "a series is ONE user-facing item")
        XCTAssertTrue(tagAdder.calls.isEmpty, "a main photo that uploads now is tagged at creation, not afterwards")
    }

    func testSeriesMigrationUploadsOnlyMissingMembersAndTagsTheExistingMainPhoto() async throws {
        // Build 77 state: the representative photo is already uploaded as a plain, untagged photo.
        let entry = seedEntry("IMG_0001.HEIC")
        _ = await makeRunner().runUntilDrained()
        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_0001.HEIC"])
        XCTAssertEqual(uploader.requests.first?.tags, [])

        // The fixed planner now reports the members, so the same main photo is queued under its series revision.
        resolver.setBurstMembers(["IMG_0002.HEIC", "IMG_0003.HEIC"], for: entry.source.identifier)
        let reopened = seedEntry("IMG_0001.HEIC", revisionOffset: 1)
        let tagAdder = SpyTagAdder()
        _ = await makeRunner(tagAdder: tagAdder).runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0003.HEIC"],
            "the representative photo must never upload a second time")
        let members = uploader.requests.dropFirst()
        XCTAssertTrue(members.allSatisfy { $0.mainPhotoUID?.nodeID == testUID("IMG_0001.HEIC").nodeID })
        XCTAssertTrue(members.allSatisfy { $0.tags == [PhotoTag.bursts.rawValue] })
        XCTAssertEqual(tagAdder.calls.map(\.tags), [[PhotoTag.bursts.rawValue]])
        XCTAssertEqual(tagAdder.calls.first?.uid.nodeID, testUID("IMG_0001.HEIC").nodeID)
        XCTAssertEqual(state(of: reopened), .alreadyBackedUp)
    }

    func testSeriesMigrationStaysPendingWhenTheExistingMainPhotoCannotBeTagged() async throws {
        let entry = seedEntry("IMG_0001.HEIC")
        _ = await makeRunner().runUntilDrained()
        resolver.setBurstMembers(["IMG_0002.HEIC"], for: entry.source.identifier)
        let reopened = seedEntry("IMG_0001.HEIC", revisionOffset: 1)

        _ = await makeRunner(tagAdder: SpyTagAdder(failing: true)).runUntilDrained()

        XCTAssertNotEqual(
            state(of: reopened)?.isTerminalSuccess, true,
            "an untagged main photo would still show as a normal photo, so the series is not backed up yet")
    }

    func testSeriesMigrationRelatesAPickThatAnEarlierBuildUploadedStandalone() async throws {
        // An earlier build uploaded the user's pick as a standalone photo. Its bytes are an active remote photo.
        let entry = seedEntry("IMG_0001.HEIC")
        resolver.setBurstMembers(["IMG_0002.HEIC", "IMG_0003.HEIC"], for: entry.source.identifier)
        let pickContentHash = expectedContentHash(path: "/backup/IMG_0001.HEIC#IMG_0002.HEIC")
        checker.remoteItemsByNameHash["nh(IMG_0002.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_0002.HEIC)",
                contentHash: pickContentHash,
                linkState: .active,
                linkID: "standalone-pick"
            )
        ]

        _ = await makeRunner(tagAdder: SpyTagAdder()).runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0003.HEIC"],
            "an active standalone photo is not a related photo, so the pick uploads into the series")
        XCTAssertEqual(
            uploader.requests.dropFirst().map(\.mainPhotoUID),
            [testUID("IMG_0001.HEIC"), testUID("IMG_0001.HEIC")])
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testSeriesMemberThatIsAlreadyARelatedPhotoOfTheMainPhotoNeverUploadsAgain() async throws {
        // Another device, or this one before its manifest was lost, uploaded the member into the series.
        let entry = seedEntry("IMG_0001.HEIC")
        resolver.setBurstMembers(["IMG_0002.HEIC", "IMG_0003.HEIC"], for: entry.source.identifier)
        checker.remoteItemsByNameHash["nh(IMG_0002.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_0002.HEIC)",
                contentHash: expectedContentHash(path: "/backup/IMG_0001.HEIC#IMG_0002.HEIC"),
                linkState: .active,
                linkID: "related-member"
            )
        ]
        checker.relatedLinkIDsByMainLinkID[testUID("IMG_0001.HEIC").nodeID] = ["related-member"]

        _ = await makeRunner(tagAdder: SpyTagAdder()).runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_0001.HEIC", "IMG_0003.HEIC"])
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testRemotelyTrashedSeriesMemberSkipsOnlyThatMember() async throws {
        let entry = seedEntry("IMG_0001.HEIC")
        resolver.setBurstMembers(["IMG_0002.HEIC", "IMG_0003.HEIC"], for: entry.source.identifier)
        checker.remoteItemsByNameHash["nh(IMG_0002.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_0002.HEIC)",
                contentHash: expectedContentHash(path: "/backup/IMG_0001.HEIC#IMG_0002.HEIC"),
                linkState: .trashed,
                linkID: "trashed-pick"
            )
        ]

        let progress = await makeRunner(tagAdder: SpyTagAdder()).runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["IMG_0001.HEIC", "IMG_0003.HEIC"],
            "the deleted photo stays deleted, and the other member still uploads")
        XCTAssertEqual(uploader.requests.last?.mainPhotoUID, testUID("IMG_0001.HEIC"))
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testPhotoMetadataFlowsToPrimaryAndSecondaryUploads() async throws {
        let entry = seedEntry("metadata.heic")
        let metadata = PhotoUploadAdditionalMetadata(name: "Media", utf8JsonValue: Data(#"{"Width":4032}"#.utf8))
        resolver.setSecondaries(["metadata.mov"], for: entry.source.identifier)
        resolver.setAdditionalMetadata([metadata], for: entry.source.identifier)

        let runner = makeRunner()
        _ = await runner.runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.additionalMetadata), [[metadata], [metadata]])
    }

    func testTrashedSecondaryNeverMarksLivePhotoBackedUp() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        checker.remoteItemsByNameHash["nh(live.mov)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(live.mov)",
                contentHash: expectedContentHash(path: "/backup/live.heic#live.mov"),
                linkState: .trashed,
                linkID: "trashed-paired"
            )
        ]

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic"])
        XCTAssertEqual(state(of: entry), .skippedRemoteDeletion)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertNil(
            stateStore.record(
                for: entry.source,
                revision: UploadBackupRevision(date: resolver.defaultModified)
            ))
    }

    func testDraftSecondaryParksLivePhotoInsteadOfClaimingSuccess() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        checker.remoteItemsByNameHash["nh(live.mov)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(live.mov)",
                contentHash: nil,
                linkState: .draft,
                linkID: "draft-paired"
            )
        ]

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic"])
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertEqual(progress.blocked, 1)
    }

    func testDraftSecondaryRespectsPrimaryDeletedAfterSuccessfulUpload() async throws {
        let entry = seedEntry("edited.jpg")
        resolver.setSecondaries(["Adjustments.plist"], for: entry.source.identifier)
        let pipeline = makePipeline()
        let primaryDescriptor = UploadResourceDescriptor(
            source: entry.source,
            fileURL: URL(fileURLWithPath: entry.source.identifier),
            filename: entry.originalFilename,
            fileSize: entry.byteCount ?? 1,
            modificationDate: resolver.defaultModified
        )
        let uploaded = try await pipeline.resolve(primaryDescriptor)
        try await pipeline.recordUploaded(
            primaryDescriptor,
            identity: uploaded.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "uploaded-primary"
        )
        checker.remoteItemsByNameHash[uploaded.identity.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: uploaded.identity.nameHash,
                contentHash: uploaded.identity.contentHash,
                linkState: .trashed,
                linkID: "uploaded-primary"
            )
        ]
        checker.remoteItemsByNameHash["nh(Adjustments.plist)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(Adjustments.plist)",
                contentHash: nil,
                linkState: .draft,
                linkID: "unfinished-adjustment"
            )
        ]

        let progress = await makeRunner(identityResolver: pipeline).runUntilDrained()

        XCTAssertEqual(state(of: entry), .skippedRemoteDeletion)
        XCTAssertEqual(progress.skippedRemoteDeletions, 1)
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertTrue(uploader.requests.isEmpty, "a deliberately trashed primary must never be recreated")
        XCTAssertNil(stateStore.record(for: entry.source, revision: entry.revision))
    }

    func testPairedVideoFailureRetriesWithoutReuploadingPrimary() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let flaky = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            transientFailures: ["live.mov": 1]
        )

        let runner = makeRunner(uploader: flaky)
        let progress = await runner.runUntilDrained()

        // The retry pass resolves the primary via the manifest, so the compound settles as
        // alreadyBackedUp - either success state is honest; what matters is the byte counts.
        XCTAssertEqual(state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(
            flaky.requests.filter { $0.name == "live.heic" }.count, 1,
            "the primary must never re-upload when only its paired video failed")
        XCTAssertEqual(
            flaky.requests.filter { $0.name == "live.mov" }.count, 2,
            "the paired video retries after its transient failure")
        // The retried paired video references the primary via its manifest link (no volume known
        // from a skip row - the transport resolves the photos volume for it).
        let retriedPaired = try XCTUnwrap(flaky.requests.last)
        XCTAssertEqual(retriedPaired.mainPhotoUID?.nodeID, testUID("live.heic").nodeID)
        XCTAssertEqual(progress.backedUp, 1)
    }

    func testSecondaryNetworkTimeoutNeverParksCompoundOrReuploadsPrimary() async throws {
        let entry = seedEntry("network-live.heic")
        resolver.setSecondaries(["network-live.mov"], for: entry.source.identifier)
        let flaky = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            networkFailures: ["network-live.mov": 6]
        )

        let progress = await makeRunner(uploader: flaky).runUntilDrained()

        XCTAssertEqual(state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(progress.failed, 0, "a secondary timeout is environmental, never a permanent item failure")
        XCTAssertEqual(flaky.requests.filter { $0.name == "network-live.heic" }.count, 1)
        XCTAssertEqual(flaky.requests.filter { $0.name == "network-live.mov" }.count, 7)
        XCTAssertEqual(
            queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0,
            "transient network retries must not burn the compound retry budget")
        XCTAssertEqual(
            clock.sleeps.filter { $0 >= 1 }, [1, 2, 4, 8, 16, 32],
            "network retries must not hot-loop at the first-delay interval")
    }

    func testLargeTransferPublishesEphemeralByteLivenessWithoutChangingDurableCount() async throws {
        let entry = seedEntry("large.mov")
        let recorder = BackupProgressRecorder()
        let runner = makeRunner(uploader: MockUploader(deliverProgress: true))
        await runner.setOnProgress { recorder.append($0) }

        let final = await runner.runUntilDrained()
        let active = recorder.snapshots.compactMap(\.activeTransfer)

        XCTAssertTrue(active.contains { ($0.fraction ?? 0) > 0 && $0.completedBytes > 0 })
        XCTAssertTrue(active.allSatisfy { $0.completedItemEquivalents < 1 })
        XCTAssertEqual(final.backedUp, 1)
        XCTAssertNil(final.activeTransfer, "ephemeral byte state must disappear when the item settles")
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testPreparationAndUploadProgressHandoffIsMonotonicAndNeverDoubleCountsTerminalItem() async throws {
        let entry = seedEntry("prepared.mov")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        resolver.setPreparationProgress(for: entry.source.identifier)
        let recorder = BackupProgressRecorder()
        let runner = makeRunner(uploader: MockUploader(deliverProgress: true))
        await runner.setOnProgress { recorder.append($0) }

        let final = await runner.runUntilDrained()
        // Let already-enqueued, generation-guarded progress callbacks reach the actor. None may
        // resurrect execution state after the item has settled.
        resolver.emitCapturedPreparationProgress(
            for: entry.source.identifier,
            .init(phase: .materializing, fraction: 1)
        )
        for _ in 0..<5 { await Task.yield() }
        let afterLateCallbacks = await runner.currentProgress()
        let snapshots = recorder.snapshots.filter { $0.total > 0 }
        let execution = snapshots.map { Double($0.settled) + $0.activeExecutionItemEquivalents }

        XCTAssertTrue(
            snapshots.contains {
                $0.activeTransfer == nil && $0.activeExecutionItemEquivalents > 0
            }, "identity work must advance background liveness before upload bytes exist")
        XCTAssertTrue(
            snapshots.contains {
                $0.activeTransfer == nil && $0.activeExecutionItemEquivalents > 0.45
            }, "deferred PhotoKit materialization must remain visible before SDK upload starts")
        XCTAssertTrue(
            snapshots.contains {
                $0.activeTransfer != nil && $0.activeExecutionItemEquivalents > 0.70
            }, "upload progress must continue forward from the preparation floor")
        XCTAssertTrue(
            zip(execution, execution.dropFirst()).allSatisfy { $0 <= $1 },
            "stage and terminal handoffs must never move execution backwards")
        XCTAssertTrue(
            execution.allSatisfy { $0 <= 1 },
            "an active fraction and the same terminal item must never be counted together")
        XCTAssertEqual(final.backedUp, 1)
        XCTAssertEqual(final.activeExecutionItemEquivalents, 0)
        XCTAssertEqual(afterLateCallbacks.activeExecutionItemEquivalents, 0)
    }

    func testUploadProgressGateKeepsPhaseEdgesAndTerminalHighWaterMark() {
        let forwarded = UploadProgressRecorder()
        let gate = BackupUploadCallbackGate { forwarded.append($0) }

        gate.publish(.init(phase: .preparing))
        gate.publish(.init(phase: .preparing))
        gate.publish(.init(phase: .hashing))
        gate.publish(.init(phase: .hashing))
        gate.publish(.init(phase: .uploading, fraction: 0.001))
        gate.publish(.init(phase: .uploading, fraction: 0.009))
        gate.publish(.init(phase: .uploading, fraction: 0.01))
        gate.publish(.init(phase: .uploading, fraction: 0.50))
        gate.publish(.init(phase: .uploading, fraction: 0.40))
        gate.publish(.init(phase: .uploading, fraction: 1.0))
        // A phase callback after bytes must not reset the upload high-water mark.
        gate.publish(.init(phase: .preparing))
        gate.publish(.init(phase: .uploading, fraction: 0.10))

        XCTAssertEqual(
            forwarded.snapshots,
            [
                .init(phase: .preparing),
                .init(phase: .hashing),
                .init(phase: .uploading, fraction: 0.001),
                .init(phase: .uploading, fraction: 0.01),
                .init(phase: .uploading, fraction: 0.50),
                .init(phase: .uploading, fraction: 1.0),
                .init(phase: .preparing),
            ]
        )
    }

    func testCompositeResolverRoutesAndRejectsUnknownKinds() async throws {
        let composite = CompositeBackupResourceResolver([.fileURL: resolver])
        let fileEntry = seedEntry("routed.jpg")
        let resolved = try await composite.resolve(fileEntry)
        XCTAssertEqual(resolved?.descriptor.filename, "routed.jpg")

        let photoEntry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1"),
            revision: UploadBackupRevision(rawValue: 1),
            originalFilename: "IMG.HEIC",
            updatedAt: clock.now
        )
        do {
            _ = try await composite.resolve(photoEntry)
            XCTFail("unregistered source kinds must fail loudly, not guess")
        } catch {}
    }

    func testUploadConcurrencyRespectsThrottleLimit() async throws {
        for index in 0..<8 { _ = seedEntry("file-\(index).jpg") }
        let slowUploader = MockUploader(workDuration: .milliseconds(30), deliverProgress: false)

        let runner = makeRunner(uploader: slowUploader, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(progress.uploaded, 8)
        XCTAssertLessThanOrEqual(slowUploader.peakConcurrent, 2)
    }

    func testASlowUploadDoesNotHoldBackTheNextPhotos() async throws {
        for index in 0..<5 { _ = seedEntry("photo-\(index).jpg") }
        let holding = FirstUploadHoldingUploader()
        let runner = makeRunner(uploader: holding, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let drain = Task { await runner.runUntilDrained() }

        // The second slot takes the next photo each time one finishes, while the first upload still runs.
        let deadline = Date().addingTimeInterval(10)
        while holding.finished.count < 4, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let heldName = try XCTUnwrap(holding.heldName)
        XCTAssertEqual(holding.finished.count, 4, "the other photos upload while the first one still runs")
        XCTAssertFalse(holding.finished.contains(heldName))

        await holding.release.signal()
        let progress = await drain.value
        XCTAssertEqual(progress.uploaded, 5)
        XCTAssertEqual(holding.finished.count, 5)
    }

    func testSentBytesCountEveryFinishedUploadInFullAcrossPasses() async throws {
        for index in 0..<3 { _ = seedEntry("sized-\(index).jpg") }
        // No progress callbacks: only the finished uploads move the count.
        let quiet = MockUploader(deliverProgress: false)
        let recorder = BackupProgressRecorder()
        let runner = makeRunner(uploader: quiet)
        await runner.setOnProgress { recorder.append($0) }

        let first = await runner.runUntilDrained()
        let sent = quiet.requests.reduce(Int64(0)) { $0 + $1.fileSize }
        XCTAssertGreaterThan(sent, 0)
        XCTAssertEqual(first.transferredBytes, sent)
        let counts = recorder.snapshots.map(\.transferredBytes)
        XCTAssertFalse(zip(counts, counts.dropFirst()).contains { $0 > $1 }, "the count never goes back")

        _ = seedEntry("later.jpg")
        let second = await runner.runUntilDrained()
        XCTAssertEqual(
            second.transferredBytes, quiet.requests.reduce(Int64(0)) { $0 + $1.fileSize },
            "a later pass of the same runner keeps counting")
    }

    func testFileChangedAfterScanUploadsCurrentContentAndClosesBothRows() async throws {
        let entry = seedEntry("edited.jpg")
        let newModified = resolver.defaultModified.addingTimeInterval(500)
        resolver.setModified(newModified, for: entry.source.identifier)

        let runner = makeRunner()
        _ = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed, "the scanned row must not linger as runnable")
        let driftedRow = queueStore.entry(for: entry.source, revision: UploadBackupRevision(date: newModified))
        XCTAssertEqual(driftedRow?.state, .completed, "the resolved revision must get its own truthful row")
        let record = stateStore.record(for: entry.source, revision: UploadBackupRevision(date: newModified))
        XCTAssertEqual(record?.isComplete, true, "backed-up proof must be recorded for the revision that was uploaded")
        XCTAssertEqual(uploader.requests.count, 1)
    }
}

/// Records runner events for the pending grid, with the queue state at the moment of each handoff.
private final class SpyBackupItemEvents: BackupItemEventSink, @unchecked Sendable {
    enum Event: Equatable {
        case evidence(String)
        case handoff(String, PhotoUID, PendingHandoffKind, queueState: UploadBackupSyncQueueState?)
        case progress(String, Int?)
        case settlement(String)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private let queue: UploadBackupSyncQueueManifestStore
    var excluded: Set<String> = []
    var exclusionsUnknown = false
    var handoffOutcome = PendingHandoffOutcome.recorded

    init(queue: UploadBackupSyncQueueManifestStore) {
        self.queue = queue
    }

    var events: [Event] { lock.withLock { recorded } }

    func recordUploadEvidence(source: UploadSourceIdentity, revision: UploadBackupRevision, replaces: [PhotoUID]) {
        lock.withLock { recorded.append(.evidence(source.identifier)) }
    }

    func settleUploadEvidence(
        source: UploadSourceIdentity, revision: UploadBackupRevision, retired: Set<String>
    ) {
        lock.withLock { recorded.append(.settlement(source.identifier)) }
    }

    func recordHandoff(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        remote: PhotoUID,
        kind: PendingHandoffKind
    ) -> PendingHandoffOutcome {
        let state = queue.entry(for: source, revision: revision)?.state
        lock.withLock { recorded.append(.handoff(source.identifier, remote, kind, queueState: state)) }
        return handoffOutcome
    }

    func isExcluded(source: UploadSourceIdentity) -> Bool? {
        lock.withLock { exclusionsUnknown ? nil : excluded.contains(source.identifier) }
    }

    func reportProgress(source: UploadSourceIdentity, revision: UploadBackupRevision, step: Int?) {
        lock.withLock { recorded.append(.progress(source.identifier, step)) }
    }
}

extension BackupSyncRunnerTests {
    func testUploadRecordsEvidenceThenHandoffBeforeTheRowSettles() async throws {
        let entry = seedEntry("fresh.jpg")
        let events = SpyBackupItemEvents(queue: queueStore)

        _ = await makeRunner(events: events).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        let recorded = events.events.filter {
            if case .progress = $0 { return false }
            return true
        }
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first, .evidence(entry.source.identifier))
        guard case .handoff(let id, let remote, let kind, let queueState) = recorded.last else {
            return XCTFail("expected a handoff after the evidence")
        }
        XCTAssertEqual(id, entry.source.identifier)
        XCTAssertEqual(remote, testUID("fresh.jpg"))
        XCTAssertEqual(kind, .uploaded)
        XCTAssertNotEqual(queueState, .completed, "the handoff must be durable before the row settles")
    }

    func testActiveDuplicateRecordsDeduplicatedHandoffWithoutEvidence() async throws {
        let entry = seedEntry("dup.jpg")
        let hashes = expectedHashes(id: "dup.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash, contentHash: hashes.contentHash, linkState: .active, linkID: "remote-1"
            )
        ]
        let events = SpyBackupItemEvents(queue: queueStore)

        _ = await makeRunner(events: events).runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertFalse(events.events.contains(.evidence(entry.source.identifier)))
        XCTAssertTrue(
            events.events.contains {
                if case .handoff(_, let remote, .deduplicated, _) = $0 {
                    return remote == PhotoUID(volumeID: "", nodeID: "remote-1")
                }
                return false
            })
    }

    func testExcludedSourceStopsBeforeBytesMoveAndLeavesNoRow() async throws {
        let entry = seedEntry("excluded.jpg")
        let events = SpyBackupItemEvents(queue: queueStore)
        events.excluded = [entry.source.identifier]

        let progress = await makeRunner(events: events).runUntilDrained()

        XCTAssertTrue(uploader.requests.isEmpty, "an excluded photo must never upload")
        XCTAssertNil(state(of: entry), "an exclusion removes the row like a local deletion")
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertFalse(events.events.contains(.evidence(entry.source.identifier)))
    }

    func testUnknownExclusionsPauseWithoutRemovingWork() async throws {
        let entry = seedEntry("unknown.jpg")
        let events = SpyBackupItemEvents(queue: queueStore)
        events.exclusionsUnknown = true

        _ = await makeRunner(events: events).runUntilDrained()

        XCTAssertTrue(uploader.requests.isEmpty, "no photo may upload while its exclusion cannot be read")
        XCTAssertNotNil(state(of: entry), "an unknown answer must never remove work")
        XCTAssertNotEqual(state(of: entry), .completed)
    }

    func testFailedHandoffKeepsTheRowFromSettling() async throws {
        let entry = seedEntry("unsaved.jpg")
        let events = SpyBackupItemEvents(queue: queueStore)
        events.handoffOutcome = .failed

        _ = await makeRunner(events: events).runUntilDrained()

        XCTAssertNotEqual(state(of: entry), .completed, "the grid needs the handoff before the row settles")
    }

    func testProgressStepsRiseAndEndWhenTheSourceSettles() async throws {
        let progressingUploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: true)
        let entry = seedEntry("progress.jpg")
        let events = SpyBackupItemEvents(queue: queueStore)

        _ = await makeRunner(uploader: progressingUploader, events: events).runUntilDrained()

        let steps = events.events.compactMap { event -> Int?? in
            if case .progress(entry.source.identifier, let step) = event { return step }
            return nil
        }
        XCTAssertEqual(steps.last, .some(nil), "the progress ends when the source settles")
        let values = steps.compactMap { $0 }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values, values.sorted(), "progress never moves backwards")
        XCTAssertTrue(values.allSatisfy { (0...BackupProgressStep.count).contains($0) })
    }
}
