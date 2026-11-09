import Foundation
import PhotosCore

/// A runner event after the recorder captured its durable facts and cosmetic replacement state.
public enum PendingRuntimeEvent: Sendable, Equatable {
    case evidence(PendingUploadEvidence)
    case handoff(PendingHandoff, PendingHandoffOutcome)
    case progress(PendingSourceKey, UploadBackupRevision, step: Int?)
}

/// The runner's event sink. It writes durable facts to the pending store synchronously, then forwards every
/// event to the coordinator without blocking the runner.
public final class PendingBackupEventRecorder: BackupItemEventSink, @unchecked Sendable {
    public let events: AsyncStream<PendingRuntimeEvent>
    private let continuation: AsyncStream<PendingRuntimeEvent>.Continuation
    private let store: PendingBackupManifestStore
    public let replacementLedger: PendingReplacementLedger
    private let replacementJournal: (any EditReplacementJournaling)?
    private let now: @Sendable () -> Date

    public init(
        store: PendingBackupManifestStore,
        replacementLedger: PendingReplacementLedger = PendingReplacementLedger(),
        replacementJournal: (any EditReplacementJournaling)? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        self.replacementLedger = replacementLedger
        self.replacementJournal = replacementJournal
        (events, continuation) = AsyncStream.makeStream(of: PendingRuntimeEvent.self, bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    public func finish() { continuation.finish() }

    public func recordUploadEvidence(
        source: UploadSourceIdentity, revision: UploadBackupRevision, replaces: [PhotoUID] = []
    ) {
        let key = PendingSourceKey(source)
        let replaces = source.kind == .photoLibraryAsset && source.resource == .primary ? replaces : []
        guard store.recordUploadEvidence(key, revision: revision, at: now()) else { return }
        replacementLedger.record(key, revision: revision, replaces: replaces)
        let evidence =
            replacementLedger.evidence(for: key, revision: revision)
            ?? PendingUploadEvidence(key: key, revision: revision, replaces: nil)
        continuation.yield(.evidence(evidence))
    }

    public func settleUploadEvidence(
        source: UploadSourceIdentity, revision: UploadBackupRevision, retired: Set<String>
    ) {
        let key = PendingSourceKey(source)
        if let replaces = replacementLedger.settle(key, revision: revision, retired: retired) {
            continuation.yield(.evidence(PendingUploadEvidence(key: key, revision: revision, replaces: replaces)))
        }
    }

    @discardableResult
    public func recordHandoff(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        remote: PhotoUID,
        kind: PendingHandoffKind
    ) -> PendingHandoffOutcome {
        var handoff = PendingHandoff(
            key: PendingSourceKey(source),
            revision: revision,
            remote: remote,
            kind: kind,
            createdAt: now()
        )
        let outcome = store.recordHandoff(handoff)
        guard outcome != .failed else { return outcome }
        // The store keeps the first time of a repeated upload record, and the coordinator orders by that time.
        if let recorded = store.handoffTime(for: handoff.key, revision: revision), recorded != handoff.createdAt {
            handoff = PendingHandoff(
                key: handoff.key, revision: revision, remote: remote, kind: kind, createdAt: recorded)
        }
        if source.resource == .primary {
            replacementLedger.recordHandoff(handoff) { replacementJournal?.entry(for: source).allSuperseded ?? [] }
        }
        continuation.yield(.handoff(handoff, outcome))
        return outcome
    }

    public func exclusion(of source: UploadSourceIdentity) -> BackupSourceExclusion? {
        store.exclusions(kind: source.kind, among: [source.identifier]).map { $0[source.identifier] ?? .included }
    }

    public func reportProgress(source: UploadSourceIdentity, revision: UploadBackupRevision, step: Int?) {
        continuation.yield(.progress(PendingSourceKey(source), revision, step: step))
    }
}
