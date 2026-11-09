import Foundation
import PhotosCore

@testable import UploadCore

// Short reads for assertions. Each one goes through the production read that the app uses.

extension ExactDuplicateFingerprintStore {
    /// The saved details of `members` through the group read of the Duplicates screen. Nil when one member has none.
    func fingerprints(for members: [PhotoUID], in snapshot: Snapshot) -> [PhotoUID: ExactDuplicateFingerprint]? {
        guard !members.isEmpty else { return [:] }
        let group = ExactDuplicateGroup(contentHash: "", hashKeyEpoch: snapshot.scope.hashKeyEpoch, members: members)
        let saved = fingerprints(ofGroups: [group], in: snapshot)
        return saved.isEmpty ? nil : saved
    }
}

extension ExactDuplicateFinder {
    /// The members of each group by group ID, the photo to keep first, from all pages of `rankMembers`.
    func rankedMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        let collected = RankedPages()
        await rankMembers(of: groups) { await collected.add($0.members) }
        return await collected.members
    }
}

private actor RankedPages {
    private(set) var members: [String: [PhotoUID]] = [:]

    func add(_ page: [String: [PhotoUID]]) {
        members.merge(page) { _, new in new }
    }
}

extension UploadIdentityStore {
    /// One row of `trustedRecords`.
    func trustedRecord(contentHash: String, hashKeyEpoch: String) -> UploadIdentityRecord? {
        trustedRecords(contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, limit: 1).first
    }
}

extension UploadRemoteContentIndexStore {
    /// One record of `remoteContentRecords`.
    func remoteContentRecord(contentHash: String, hashKeyEpoch: String) -> UploadRemoteContentIndexRecord? {
        remoteContentRecords(contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, limit: 1).first
    }
}
