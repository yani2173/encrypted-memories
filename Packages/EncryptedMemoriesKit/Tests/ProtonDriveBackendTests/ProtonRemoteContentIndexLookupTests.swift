import Foundation
import Testing
import UploadCore

@testable import ProtonDriveBackend

struct ProtonRemoteContentIndexLookupTests {
    @Test func exactRecordAlwaysWins() throws {
        let record = UploadRemoteContentIndexRecord(
            contentHash: "content",
            hashKeyEpoch: "epoch",
            remoteLinkID: "remote-link"
        )

        let duplicate = try ProtonRemoteContentIndexLookup.duplicates(
            contentHash: "content",
            records: [record],
            health: .degraded(indexedCount: 10, unresolvedCount: 20)
        ).first

        #expect(duplicate?.linkID == "remote-link")
        #expect(duplicate?.linkState == .active)
    }

    @Test func legacyMetadataGapPermitsAvailabilityFirstMiss() throws {
        let duplicate = try ProtonRemoteContentIndexLookup.duplicates(
            contentHash: "content",
            records: [],
            health: .degraded(indexedCount: 900, unresolvedCount: 100)
        ).first

        #expect(duplicate == nil)
    }

    @Test func unavailableLocalIndexRemainsFailClosed() {
        #expect(throws: (any Error).self) {
            _ = try ProtonRemoteContentIndexLookup.duplicates(
                contentHash: "content",
                records: [],
                health: .unavailable
            )
        }
    }

    @Test func warningThresholdIsBoundedAndPercentageBased() {
        #expect(UploadRemoteContentIndexHealth.degraded(indexedCount: 989, unresolvedCount: 11).shouldWarn)
        #expect(!UploadRemoteContentIndexHealth.degraded(indexedCount: 991, unresolvedCount: 9).shouldWarn)
        #expect(
            UploadRemoteContentIndexHealth.degraded(indexedCount: 19_900, unresolvedCount: 100).warningThreshold == 100)
    }
}
