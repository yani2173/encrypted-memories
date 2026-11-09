import Foundation
import PhotosCore

/// Counts of the backup queue for the background log. It holds only state names, issue kinds and numbers.
public struct UploadBackupQueueDiagnostics: Sendable, Equatable {
    /// Why a row waits for its check or is in it: the kind of its recorded issue, no issue, or a text that is not
    /// an issue record (for example from an earlier version).
    public enum CheckReason: Hashable, Sendable {
        case none
        case unrecognized
        case issue(BackupIssueKind)
    }

    /// Rows per state.
    public var rows: [UploadBackupSyncQueueState: Int] = [:]
    /// Rows that wait for their check (`discovered`) or are in it (`checking`), per reason.
    public var checkReasons: [UploadBackupSyncQueueState: [CheckReason: Int]] = [:]

    public init() {}

    /// The reason of one row's last error.
    public static func checkReason(lastError: String?) -> CheckReason {
        guard let lastError, !lastError.isEmpty else { return .none }
        guard let record = BackupIssueRecord.decode(lastError) else { return .unrecognized }
        return .issue(record.kind)
    }
}

extension UploadBackupSyncQueueState: BackgroundLogName {}
extension BackupIssueKind: BackgroundLogName {}
