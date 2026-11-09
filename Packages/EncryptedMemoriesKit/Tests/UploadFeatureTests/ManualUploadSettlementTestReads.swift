import Foundation

@testable import UploadCore

// Short reads for assertions. The upload manager reads only `readOutcome(for:)` and `readAllOutcome()`, which keep
// an unreadable store apart from an absent row or an empty list.

extension UploadManualSettlementStoreProtocol {
    /// The row, or nil when it is absent or unreadable.
    func record(for queueItemID: UploadQueueItemID) -> UploadManualSettlementRecord? {
        if case .found(let record) = readOutcome(for: queueItemID) { return record }
        return nil
    }

    /// Every row, or an empty list when the store is unreadable.
    func allRecords() -> [UploadManualSettlementRecord] {
        if case .records(let records) = readAllOutcome() { return records }
        return []
    }
}
