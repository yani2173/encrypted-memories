import Foundation

/// Selects a reusable standalone copy or a safe upload action for a related photo. The series dissolution and the
/// revert of an edited photo use the same rule. The series dissolution passes the member's link ID and the series link
/// IDs unchanged.
///
/// The standard upload dedupe cannot be used here. The source's bytes already exist remotely as the source
/// itself, so the standard rule would answer "active duplicate" and link the copy to the very photo that is
/// about to move to the trash. The copy would be lost.
///
/// Rule. Proton's duplicate rows for the upload name are read, and every row that belongs to the source
/// compound is ignored, because the compound is the source and not a copy. The source's own row is ignored
/// even when a stale membership list misses it. Then:
/// 1. An active row with the same content is a standalone copy that already exists: an earlier attempt
///    committed it before the journal recorded it, or the person uploaded the same file separately. It is
///    adopted. No bytes upload, so a retry never creates a duplicate.
/// 2. A draft of this installation is an interrupted copy attempt. The upload replaces it.
/// 3. A draft of another client blocks the name. The operation stops and stays resumable.
/// 4. A trashed or deleted row with the same content does not block. The person chose to keep this copy
///    now, so an older deletion of an identical file must not remove it from the result.
/// 5. A row with the same name and other content is another photo. The copy uploads under the same name.
///
/// A row with an empty link ID cannot be adopted itself, but it does not stop the search for a valid copy behind it.
public enum RelatedPhotoCopyPolicy {
    public enum Decision: Sendable, Equatable {
        case adopt(remoteLinkID: String)
        case upload(replacingDraft: Bool)
        case blockedByForeignDraft
    }

    /// Decides how one related photo becomes a standalone copy.
    ///
    /// - Parameters:
    ///   - nameHash: The remote name hash of the photo to copy.
    ///   - contentHash: The remote content hash HMAC of the photo to copy.
    ///   - remoteItems: Duplicate rows for the name hash from the backend.
    ///   - sourceLinkID: The link ID of the source photo (the member or related file being copied).
    ///   - compoundLinkIDs: The link IDs of the source compound (all related files of the source).
    ///   - currentClientUID: The uploading client's self-chosen identifier.
    /// - Returns: The decision for the copy operation.
    public static func decide(
        nameHash: String,
        contentHash: String,
        remoteItems: [RemotePhotoDuplicate],
        sourceLinkID: String,
        compoundLinkIDs: Set<String>,
        currentClientUID: String?
    ) -> Decision {
        let candidates = remoteItems.filter { item in
            item.nameHash == nameHash && item.linkID != sourceLinkID
                && !(item.linkID.map { compoundLinkIDs.contains($0) } ?? false)
        }
        if let linkID = candidates.first(where: {
            $0.linkState == .active && $0.contentHash == contentHash && !($0.linkID ?? "").isEmpty
        })?.linkID {
            return .adopt(remoteLinkID: linkID)
        }
        let drafts = candidates.filter { $0.linkState == .draft }
        guard !drafts.isEmpty else { return .upload(replacingDraft: false) }
        if let currentClientUID, drafts.allSatisfy({ $0.clientUID == currentClientUID }) {
            return .upload(replacingDraft: true)
        }
        return .blockedByForeignDraft
    }
}
