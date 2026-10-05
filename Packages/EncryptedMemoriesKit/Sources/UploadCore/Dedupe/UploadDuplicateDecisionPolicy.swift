import Foundation

/// Applies the remote duplicate contract to one upload compound.
/// A completed primary match requires both name and content hashes. Its link state determines
/// whether to skip, inspect secondary resources, or reject inconsistent remote data.
/// Draft replacement is limited to work owned by this installation. Missing secondary resources
/// upload through the matched primary link.
public enum UploadDuplicateDecisionPolicy {
    /// One hashed resource of the compound, as the policy sees it.
    public struct Resource: Sendable, Equatable {
        public let source: UploadSourceIdentity
        public let nameHash: String
        public let contentHash: String

        public init(source: UploadSourceIdentity, nameHash: String, contentHash: String) {
            self.source = source
            self.nameHash = nameHash
            self.contentHash = contentHash
        }
    }

    public static func decide(
        primary: Resource,
        secondaries: [Resource] = [],
        remoteItems: [RemotePhotoDuplicate],
        currentClientUID: String? = nil
    ) -> UploadDuplicateDecision {
        // Disjoint name hashes need no content comparison.
        let localNameHashes = Set([primary.nameHash] + secondaries.map(\.nameHash))
        guard remoteItems.contains(where: { localNameHashes.contains($0.nameHash) }) else {
            return .upload
        }

        // Prefer an exact-content remote result over an unrelated same-name draft. Camera
        // counters legitimately repeat after a device reset, so a filename is never photo identity.
        let primaryNameMatches = remoteItems.filter { $0.nameHash == primary.nameHash }
        let contentMatches = primaryNameMatches.filter {
            $0.contentHash == primary.contentHash && $0.linkState != .draft
        }
        // An active copy proves the backup, whatever order the server lists the copies in: after a merge of
        // duplicates, a trashed copy of the same bytes sits next to the kept one.
        if let remotePrimary = contentMatches.first(where: { $0.linkState == .active }) ?? contentMatches.first {
            switch remotePrimary.linkState {
            case .draft:
                preconditionFailure("draft excluded above")
            case .trashed:
                return .skip(.trashedDuplicate, remoteLinkID: remotePrimary.linkID)
            case nil:
                return .skip(.deletedRemotely, remoteLinkID: remotePrimary.linkID)
            case .active:
                guard let primaryLinkID = remotePrimary.linkID else {
                    return .skip(.inconsistentRemoteState, remoteLinkID: nil)
                }
                let missing = secondaries.filter { secondary in
                    !remoteItems.contains { remote in
                        remote.nameHash == secondary.nameHash
                            && (remote.contentHash == secondary.contentHash || remote.linkState == .draft)
                    }
                }
                if missing.isEmpty {
                    return .skip(.activeDuplicate, remoteLinkID: primaryLinkID)
                }
                return .uploadMissingSecondaries(primaryLinkID: primaryLinkID, missing: missing.map(\.source))
            }
        }

        // A draft is replaceable only when Proton identifies it as this installation's own
        // interrupted work. Foreign/unknown drafts remain fail-closed until they resolve.
        let drafts = primaryNameMatches.filter { $0.linkState == .draft }
        if !drafts.isEmpty {
            if let currentClientUID,
                drafts.allSatisfy({ $0.clientUID == currentClientUID })
            {
                return .uploadReplacingDraft
            }
            return .skip(.draftExists, remoteLinkID: drafts.first?.linkID)
        }

        // A matching filename with different bytes is a different photo and uploads unchanged.
        return .upload
    }

    /// Remote rows that count for a burst member (a related photo of a series' main photo).
    ///
    /// Earlier builds uploaded the representative and every user pick of a series as standalone photos, so a
    /// member's bytes can already be an active photo. Proton has no write that sets `MainPhotoLinkID` on an
    /// existing link. An active row with the member's content therefore settles the member only when its link is
    /// a related photo of the member's main photo now (`relatedLinkIDs`): this installation after a lost
    /// manifest, or another device, uploaded the series. Every other active row is a standalone photo and is
    /// dropped here, so the member uploads as a related photo of its main photo. The old standalone photo is user
    /// data and stays untouched; the user sees the pick twice and can delete the standalone photo. Trashed,
    /// deleted and draft rows keep their standard meaning, and the backup runner applies a respected deletion to
    /// that member only.
    public static func burstMemberCandidates(
        _ remoteItems: [RemotePhotoDuplicate],
        contentHash: String,
        relatedLinkIDs: Set<String>
    ) -> [RemotePhotoDuplicate] {
        remoteItems.filter { item in
            guard item.linkState == .active, item.contentHash == contentHash else { return true }
            return item.linkID.map(relatedLinkIDs.contains) ?? false
        }
    }
}
