import Foundation
import PhotosCore

public struct UploadBackupAssetCandidate: Sendable, Equatable {
    public let snapshot: UploadBackupAssetSnapshot
    public let originalFilename: String
    public let byteCount: Int64?

    public init(snapshot: UploadBackupAssetSnapshot, originalFilename: String, byteCount: Int64? = nil) {
        self.snapshot = snapshot
        self.originalFilename = originalFilename
        self.byteCount = byteCount
    }
}

/// A candidate whose backed-up revision can lack a file that the asset lists now, such as a late rendered file.
public struct UploadBackupReopening: Sendable, Equatable {
    public let candidate: UploadBackupAssetCandidate
    /// The source under which a backup with the late file as main file keeps the former main file. Nil when the
    /// asset lists no such file.
    public let formerMain: UploadSourceIdentity?

    public init(candidate: UploadBackupAssetCandidate, formerMain: UploadSourceIdentity?) {
        self.candidate = candidate
        self.formerMain = formerMain
    }
}

public protocol UploadBackupAssetCatalog: Sendable {
    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error>
}

/// The per-candidate enqueue seam. A scan driver that owns its own loop (the photo catalog sync)
/// depends on this rather than the concrete engine, so its ordering guarantees are testable.
public protocol UploadBackupCandidateEnqueueing: Sendable {
    @discardableResult
    func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult
    @discardableResult
    func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult
    /// Re-opens the backed-up revision of each candidate, unless its backup already holds the file that the asset now
    /// lists. Returns the candidates whose revision is pending work. With `deferringWithoutRemoteProof`, a remote proof
    /// that cannot be read throws `UploadBackupRemoteProofUnavailable` and changes nothing; without it, the revisions
    /// that only the proof could settle re-open.
    @discardableResult
    func reopenBackedUpRevisions(
        _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
    ) async throws -> [UploadBackupAssetCandidate]
    /// Requeues terminal missing rows for explicit Photos changes, even when their revision is unchanged.
    /// Dismissed missing rows retain their reason until the runner proves their bytes returned.
    func enqueueChangedMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws
    /// Local-only recovery. Complete states and sources with any queue row stay untouched.
    func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws
    func missingSourceDiscardGeneration() async throws -> Int64
    /// Makes every queue row written so far survive a power loss. Returns false when that is not certain.
    func synchronizeQueueToDisk() async -> Bool
}

/// The remote proof could not be read, so revisions that only the proof can settle stay as they are for now.
public struct UploadBackupRemoteProofUnavailable: Error, Sendable {
    public init() {}
}

public extension UploadBackupCandidateEnqueueing {
    func enqueueChangedMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {}

    func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
        throw UploadError.backend("Backup source recovery is unavailable")
    }
    func missingSourceDiscardGeneration() async throws -> Int64 {
        throw UploadError.backend("Backup source recovery is unavailable")
    }

    @discardableResult
    func reopenBackedUpRevisions(
        _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
    ) async throws -> [UploadBackupAssetCandidate] {
        []
    }

    @discardableResult
    func reopenBackedUpRevisions(_ reopenings: [UploadBackupReopening]) async throws -> [UploadBackupAssetCandidate] {
        try await reopenBackedUpRevisions(reopenings, deferringWithoutRemoteProof: false)
    }

    func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult {
        var result = UploadBackupSyncScanResult()
        for candidate in candidates {
            try Task.checkCancellation()
            result.merge(try await enqueue(candidate))
        }
        return result
    }
}

public struct UploadBackupSyncScanResult: Sendable, Equatable {
    public var scanned = 0
    public var alreadyBackedUp = 0
    public var queuedForWork = 0
    public var pendingResources = 0
    public var backendChecksRequired = 0

    public init() {}

    /// Folds a per-candidate delta into a running total (used when the loop is driven externally).
    public mutating func merge(_ delta: UploadBackupSyncScanResult) {
        scanned += delta.scanned
        alreadyBackedUp += delta.alreadyBackedUp
        queuedForWork += delta.queuedForWork
        pendingResources += delta.pendingResources
        backendChecksRequired += delta.backendChecksRequired
    }
}

/// Shared sync scanner. Platform adapters enumerate assets; this actor owns the safe local
/// decision and persistent queue update so iOS/iPadOS/macOS never fork backup semantics.
public actor UploadBackupSyncEngine: UploadBackupCandidateEnqueueing {
    private static let scanBatchSize = 128

    private let preflight: UploadBackupPreflightIndex
    private let queue: any UploadBackupSyncQueueStore
    private let remoteProofResolver: (any UploadIdentityResolving)?
    private let exclusions: (any UploadBackupExclusionFiltering)?
    private let now: @Sendable () -> Date

    public init(
        preflight: UploadBackupPreflightIndex,
        queue: any UploadBackupSyncQueueStore,
        remoteProofResolver: (any UploadIdentityResolving)? = nil,
        exclusions: (any UploadBackupExclusionFiltering)? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.preflight = preflight
        self.queue = queue
        self.remoteProofResolver = remoteProofResolver
        self.exclusions = exclusions
        self.now = now
    }

    public func scan(_ catalog: any UploadBackupAssetCatalog) async throws -> UploadBackupSyncScanResult {
        var result = UploadBackupSyncScanResult()
        var batch: [UploadBackupAssetCandidate] = []
        batch.reserveCapacity(Self.scanBatchSize)
        var iterator = catalog.candidates().makeAsyncIterator()

        while true {
            let candidate: UploadBackupAssetCandidate?
            do {
                candidate = try await iterator.next()
            } catch {
                if !batch.isEmpty {
                    result.merge(try await enqueueBatch(batch))
                }
                throw error
            }
            guard let candidate else { break }

            try Task.checkCancellation()
            batch.append(candidate)
            if batch.count == Self.scanBatchSize {
                result.merge(try await enqueueBatch(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            result.merge(try await enqueueBatch(batch))
        }
        return result
    }

    /// Classifies one candidate against the preflight and durably records its queue row. The single
    /// safe decision + queue write, shared by `scan` and by callers that drive the loop themselves
    /// (the photo catalog sync interleaves this with its own persistence so the queue row is written
    /// before the catalog marks the asset seen). Returns the per-candidate result delta.
    @discardableResult
    public func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
        try await enqueueBatch([candidate])
    }

    public func synchronizeQueueToDisk() -> Bool {
        queue.synchronizeToDisk()
    }

    public func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult {
        // A photo the person deleted before upload stays out of the backup, also when a rescan offers it again.
        let included = try withoutExcludedSources(candidates)
        guard !included.isEmpty else { return UploadBackupSyncScanResult() }
        var candidates: [UploadBackupAssetCandidate] = []
        var result = UploadBackupSyncScanResult()
        let mayHaveDismissals = queue.containsAny(in: [.dismissedFailure, .discovered, .checking])
        guard queue.isOperational() else { throw Self.localStateError("Backup queue could not be read") }
        for candidate in included {
            try Task.checkCancellation()
            if mayHaveDismissals {
                let row = queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision)
                guard queue.isOperational() else { throw Self.localStateError("Backup queue could not be read") }
                if let row, row.isDismissedSourceRecheck || row.state == .dismissedFailure {
                    result.scanned += 1
                    if row.state == .dismissedFailure, row.source.kind == .photoLibraryAsset,
                        let reason = row.lastError, BackupIssueRecord.decode(reason)?.kind == .sourceMissing,
                        row.remoteCommitReconciliation == nil
                    {
                        var pending = row
                        pending.state = .discovered
                        pending.updatedAt = now()
                        guard
                            queue.updateDismissedSourceRecheck(
                                pending, matchingState: .dismissedFailure, matchingLastError: reason) != nil
                        else { throw Self.localStateError("Backup queue could not persist a source check") }
                    }
                    continue
                }
            }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else { return result }
        var decisions = try await preflight.classifyBatch(candidates.map(\.snapshot))
        try Task.checkCancellation()
        guard decisions.count == candidates.count else {
            throw UploadError.backend("Backup preflight classification was incomplete")
        }

        // A trusted external identity can prove an existing active remote compound before any
        // original bytes are requested. This is optional: a missing, stale, or unavailable remote
        // proof falls through to the normal SHA-1 + Proton duplicate path.
        if let remoteProofResolver {
            let identities: [UploadBackupExternalIdentity] = candidates.indices.compactMap {
                index -> UploadBackupExternalIdentity? in
                guard Self.remoteProofCanSettle(decisions[index]) else { return nil }
                return candidates[index].snapshot.externalIdentity
            }
            if !identities.isEmpty {
                let proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
                do {
                    proofs = try await remoteProofResolver.remoteAssetProofs(for: identities)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if UploadError.isCancellation(error) { throw error }
                    proofs = [:]
                }
                try Task.checkCancellation()
                if !proofs.isEmpty {
                    var provenSnapshots: [UploadBackupAssetSnapshot] = []
                    for index in candidates.indices {
                        guard Self.remoteProofCanSettle(decisions[index]),
                            let identity = candidates[index].snapshot.externalIdentity,
                            let proof = proofs[identity],
                            proof.externalIdentity == identity,
                            proof.resourceCount == candidates[index].snapshot.resourceCount
                        else {
                            continue
                        }
                        decisions[index] = .alreadyBackedUp
                        provenSnapshots.append(candidates[index].snapshot)
                    }
                    try await preflight.markBackedUpBatch(provenSnapshots)
                    try Task.checkCancellation()
                }
            }
        }
        var entries: [UploadBackupSyncQueueEntry] = []
        entries.reserveCapacity(candidates.count)
        for (candidate, decision) in zip(candidates, decisions) {
            let prepared = prepare(candidate, decision: decision)
            result.merge(prepared.delta)
            entries.append(prepared.entry)
        }
        try Task.checkCancellation()
        guard queue.upsertBatch(entries) else {
            throw Self.localStateError("Backup queue could not persist an asset batch")
        }
        try removeUnsavedEarlierRevisions(of: entries.filter { $0.state == .alreadyBackedUp })
        return result
    }

    public func missingSourceDiscardGeneration() async throws -> Int64 {
        guard let generation = queue.missingSourceDiscardGeneration(), queue.isOperational() else {
            throw Self.localStateError("Backup queue could not be read")
        }
        return generation
    }

    public func enqueueChangedMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
        var missing: [UploadBackupAssetCandidate] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let row = queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision)
            guard queue.isOperational() else { throw Self.localStateError("Backup queue could not be read") }
            if row?.state == .sourceMissing || row?.state == .dismissedFailure { missing.append(candidate) }
        }
        if !missing.isEmpty { _ = try await enqueueBatch(missing) }
    }

    public func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
        let included = try withoutExcludedSources(candidates)
        guard !included.isEmpty else { return }
        guard let existing = queue.sourcesWithEntries(included.map(\.snapshot.source)), queue.isOperational() else {
            throw Self.localStateError("Backup queue could not be read")
        }
        let missing = included.filter { !existing.contains($0.snapshot.source) }
        let decisions = try await preflight.classifyBatch(missing.map(\.snapshot))
        try Task.checkCancellation()
        guard decisions.count == missing.count else {
            throw UploadError.backend("Backup preflight classification was incomplete")
        }
        let entries = zip(missing, decisions).compactMap { candidate, decision in
            decision == .alreadyBackedUp ? nil : prepare(candidate, decision: decision).entry
        }
        // The conditional insert also protects a row added while the preflight actor was awaited.
        guard queue.insertMissingSources(entries) else {
            throw Self.localStateError("Backup queue could not persist missing sources")
        }
    }

    /// A complete revision becomes pending work again; its settled queue row goes away, so the next `enqueueBatch`
    /// queues the upload. A revision whose backup already holds the late file as main file, or that has no state,
    /// keeps the usual classification. So does a revision that the remote proof settled on this device and still
    /// settles.
    @discardableResult
    public func reopenBackedUpRevisions(
        _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
    ) async throws -> [UploadBackupAssetCandidate] {
        var pending: [UploadBackupAssetCandidate] = []
        let kept = Set(try withoutExcludedSources(reopenings.map(\.candidate)).map(\.snapshot.source))
        let offered = reopenings.filter { kept.contains($0.candidate.snapshot.source) }
        let proven = try await settledByRemoteProof(offered, deferringWithoutProof: deferringWithoutRemoteProof)
        for reopening in offered {
            let snapshot = reopening.candidate.snapshot
            if proven.contains(snapshot.source) { continue }
            if await backupHoldsLateMain(snapshot.source, formerMain: reopening.formerMain) { continue }
            try Task.checkCancellation()
            guard try await preflight.reopen(snapshot) else { continue }
            pending.append(reopening.candidate)
            try Task.checkCancellation()
            let row = queue.entry(for: snapshot.source, revision: snapshot.revision)
            guard queue.isOperational() else { throw Self.localStateError("Backup queue could not be read") }
            guard let row, row.state == .completed || row.state == .alreadyBackedUp else { continue }
            guard queue.remove(source: snapshot.source, revision: snapshot.revision) else {
                throw Self.localStateError("Backup queue could not re-open an asset")
            }
        }
        return pending
    }

    /// The manifest proves that the backup holds the late file as main file: the main file has a proven upload, and
    /// the former main file, which such a backup keeps as a related file, has other bytes. A backup with the former
    /// main file as main file has no such related record, or the same bytes in both records. Without proof, the
    /// revision re-opens; the duplicate check then keeps an upload that is already there.
    private func backupHoldsLateMain(_ source: UploadSourceIdentity, formerMain: UploadSourceIdentity?) async -> Bool {
        guard let remoteProofResolver, let formerMain,
            let main = await remoteProofResolver.identityRecord(for: source), main.provesUpload,
            let former = await remoteProofResolver.identityRecord(for: formerMain)
        else {
            return false
        }
        return former.sha1Hex != main.sha1Hex
    }

    /// The sources whose complete revision the remote proof settles. A revision qualifies when this device holds no
    /// manifest record for its former main file: such a record marks a backup with the late file as main file that
    /// this device made, which `backupHoldsLateMain` checks. A record for the main file alone, such as the unedited
    /// original hashed before another device uploaded the edit, does not tell what the backup holds. The proof counts
    /// the files of the backup, so a backup without the late file settles nothing. An identity that two photos share
    /// proves neither. When the proof cannot be read, `deferringWithoutProof` throws
    /// `UploadBackupRemoteProofUnavailable` before anything changes; otherwise those revisions re-open as usual.
    private func settledByRemoteProof(
        _ reopenings: [UploadBackupReopening], deferringWithoutProof: Bool
    ) async throws -> Set<UploadSourceIdentity> {
        guard let remoteProofResolver, !reopenings.isEmpty else { return [] }
        let complete = try await preflight.completeStates(reopenings.map(\.candidate.snapshot))
        var unhashed: [UploadBackupExternalIdentity: [UploadBackupAssetSnapshot]] = [:]
        for (reopening, isComplete) in zip(reopenings, complete) where isComplete {
            try Task.checkCancellation()
            let snapshot = reopening.candidate.snapshot
            guard let identity = snapshot.externalIdentity else { continue }
            if let formerMain = reopening.formerMain, await remoteProofResolver.identityRecord(for: formerMain) != nil {
                continue
            }
            unhashed[identity, default: []].append(snapshot)
        }
        guard !unhashed.isEmpty else { return [] }
        let proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
        do {
            proofs = try await remoteProofResolver.remoteAssetProofs(for: Array(unhashed.keys))
        } catch {
            // A cancelled index build ends the lookup with a cancellation error even when this pass goes on.
            if Task.isCancelled { throw CancellationError() }
            if !(error is CancellationError), UploadError.isCancellation(error) { throw error }
            if deferringWithoutProof { throw UploadBackupRemoteProofUnavailable() }
            return []
        }
        try Task.checkCancellation()
        var proven: Set<UploadSourceIdentity> = []
        for (identity, snapshots) in unhashed {
            guard snapshots.count == 1, let snapshot = snapshots.first,
                let proof = proofs[identity], proof.externalIdentity == identity,
                proof.resourceCount == snapshot.resourceCount
            else { continue }
            proven.insert(snapshot.source)
        }
        return proven
    }

    private func prepare(
        _ candidate: UploadBackupAssetCandidate,
        decision: UploadBackupCheckDecision
    ) -> (delta: UploadBackupSyncScanResult, entry: UploadBackupSyncQueueEntry) {
        var delta = UploadBackupSyncScanResult()
        delta.scanned = 1
        let state: UploadBackupSyncQueueState
        switch decision {
        case .alreadyBackedUp:
            delta.alreadyBackedUp = 1
            state = .alreadyBackedUp

        case .pendingUpload(let remainingResources):
            delta.pendingResources = remainingResources
            delta.queuedForWork = 1
            state = .queuedForUpload

        case .newAsset:
            delta.queuedForWork = 1
            state = .discovered

        case .needsBackendCheck:
            delta.backendChecksRequired = 1
            delta.queuedForWork = 1
            state = .checking
        }
        return (delta, entry(for: candidate, state: state))
    }

    /// A remote proof settles a photo that this device knows nothing about. A pending state record means
    /// unfinished work for this exact revision, such as an earlier photo that still waits for its replacement;
    /// the uploaded files alone do not finish that.
    private static func remoteProofCanSettle(_ decision: UploadBackupCheckDecision) -> Bool {
        switch decision {
        case .alreadyBackedUp, .pendingUpload: false
        case .newAsset, .needsBackendCheck: true
        }
    }

    private func withoutExcludedSources(
        _ candidates: [UploadBackupAssetCandidate]
    ) throws -> [UploadBackupAssetCandidate] {
        guard let exclusions, !candidates.isEmpty else { return candidates }
        var excluded: [UploadSourceIdentity.Kind: Set<String>] = [:]
        for kind in Set(candidates.map(\.snapshot.source.kind)) {
            let identifiers = candidates.filter { $0.snapshot.source.kind == kind }.map(\.snapshot.source.identifier)
            guard let kindExclusions = exclusions.excludedIdentifiers(kind: kind, among: identifiers) else {
                throw UploadError.backend("Backup exclusions are unavailable")
            }
            excluded[kind] = kindExclusions
        }
        return candidates.filter { candidate in
            excluded[candidate.snapshot.source.kind]?.contains(candidate.snapshot.source.identifier) != true
        }
    }

    public func markCompleted(_ candidate: UploadBackupAssetCandidate) async throws {
        try await preflight.markBackedUp(candidate.snapshot)
        try Task.checkCancellation()
        let completed = entry(for: candidate, state: .completed)
        guard queue.upsert(completed) else {
            throw Self.localStateError("Backup queue could not persist completion")
        }
        try removeUnsavedEarlierRevisions(of: [completed])
    }

    private func removeUnsavedEarlierRevisions(of entries: [UploadBackupSyncQueueEntry]) throws {
        for start in stride(from: 0, to: entries.count, by: Self.scanBatchSize) {
            let batch = Array(entries[start..<min(start + Self.scanBatchSize, entries.count)])
            guard queue.removeUnsavedEarlierRevisions(of: batch) else {
                throw Self.localStateError("Backup queue could not remove obsolete failures")
            }
        }
    }

    private static func localStateError(_ diagnostic: StaticString) -> UploadError {
        PhotoDiagnostics.shared.increment("backup.queue.localStateUnavailable")
        PhotoDiagnostics.shared.emitDebug("BackupSync", ["error": String(describing: diagnostic)])
        return .backend(L10n.string("backup.error_local_state_unavailable"))
    }

    public func summary() -> UploadBackupSyncQueueSummary {
        queue.summary()
    }

    private func entry(
        for candidate: UploadBackupAssetCandidate,
        state: UploadBackupSyncQueueState
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: candidate.snapshot.source,
            revision: candidate.snapshot.revision,
            originalFilename: candidate.originalFilename,
            byteCount: candidate.byteCount,
            state: state,
            updatedAt: now()
        )
    }
}
