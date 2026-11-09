import Foundation
import PhotosCore

/// Per-source events of the backup runner for the pending grid. Upload decisions and handoffs are durable:
/// the runner makes them before it moves a row on or clears a commit receipt, so a crash cannot lose the
/// fact that a source has a Proton photo.
public protocol BackupItemEventSink: Sendable {
    /// The duplicate check decided that this revision needs an upload.
    func recordUploadEvidence(source: UploadSourceIdentity, revision: UploadBackupRevision, replaces: [PhotoUID])
    /// Narrows this revision's in-memory mains to those actually retired after replacement settled.
    func settleUploadEvidence(
        source: UploadSourceIdentity, revision: UploadBackupRevision, retired: Set<String>
    )
    /// The source has a Proton photo: its primary committed, or the check mapped it to an existing photo.
    /// An empty `remote.volumeID` means the account's photos volume.
    @discardableResult
    func recordHandoff(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        remote: PhotoUID,
        kind: PendingHandoffKind
    ) -> PendingHandoffOutcome
    /// Whether the person excluded the source, or nil when that is unknown. The runner removes excluded work
    /// before bytes move, lets only an unreadable source wait, and pauses without removing anything when the
    /// answer is unknown.
    func exclusion(of source: UploadSourceIdentity) -> BackupSourceExclusion?
    /// Progress of an active source in 5 % steps (0...20), or nil when its work ended.
    func reportProgress(source: UploadSourceIdentity, revision: UploadBackupRevision, step: Int?)
}

/// What the pending store says about a source right before its bytes move.
public enum BackupSourceExclusion: Sendable, Equatable {
    case included
    /// The person excluded the source.
    case excluded
    /// A row of the source that this build cannot read, for example one that a newer build wrote. A newer build may
    /// have excluded the source, so it waits; its rows stay (#982).
    case unreadable
}

/// Drops candidates of excluded sources before the backup engine writes queue rows.
public protocol UploadBackupExclusionFiltering: Sendable {
    /// The excluded and unreadable identifiers among `identifiers`; a missing identifier is included. Nil when the
    /// answer is unknown. The engine then refuses to enqueue, because uploading a photo the person deleted would
    /// break their decision.
    func exclusions(kind: UploadSourceIdentity.Kind, among identifiers: [String]) -> [String: BackupSourceExclusion]?
}

extension PendingBackupManifestStore: UploadBackupExclusionFiltering {}

/// Quantizes a compound fraction to the 5 % steps of the upload ring.
public enum BackupProgressStep {
    public static let count = 20

    public static func step(for fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(1, max(0, fraction)) * Double(count)).rounded(.down))
    }
}
