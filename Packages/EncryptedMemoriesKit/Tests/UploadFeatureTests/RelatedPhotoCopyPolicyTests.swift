import XCTest

@testable import UploadCore

/// The shared copy rule for series members and reverted originals: ignore the source compound, adopt
/// a confirmed standalone photo or upload while skipping trashed/different rows.
final class RelatedPhotoCopyPolicyTests: XCTestCase {
    func testSeriesMemberRowIsExcludedAndAByteIdenticalStandaloneIsAdopted() {
        // The server's duplicate rows include the member itself (which must be ignored) and a
        // standalone copy from an earlier session.
        let rows: [RemotePhotoDuplicate] = [
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "member"),
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "copy-from-before"),
        ]
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch", remoteItems: rows,
            sourceLinkID: "member", compoundLinkIDs: ["main", "member"], currentClientUID: "client")
        XCTAssertEqual(decision, .adopt(remoteLinkID: "copy-from-before"))
    }

    func testByteIdenticalPinMatchesTheEarlierImplementation() {
        // Pins the recorded decision of the series-only rule that this shared policy replaced, so a change
        // here cannot silently change the series behavior. The expected values are the record; the old
        // implementation no longer exists in the tree.
        let rows: [RemotePhotoDuplicate] = [
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "m2")
        ]
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch", remoteItems: rows,
            sourceLinkID: "m2", compoundLinkIDs: ["m1", "m2"], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    /// Row 21: a row with an empty link ID must not hide a valid copy behind it.
    func testAnEmptyLinkIDRowIsSkippedAndTheValidRowBehindItIsAdopted() {
        let rows: [RemotePhotoDuplicate] = [
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: ""),
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "copy"),
        ]
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch", remoteItems: rows,
            sourceLinkID: "member", compoundLinkIDs: ["member"], currentClientUID: "client")
        XCTAssertEqual(decision, .adopt(remoteLinkID: "copy"))
    }

    /// Row 18, revert reading: the source's own row is ignored even when the compound list misses it.
    func testTheSourceRowIsIgnoredEvenWhenTheCompoundListMissesIt() {
        let rows: [RemotePhotoDuplicate] = [
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "member")
        ]
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch", remoteItems: rows,
            sourceLinkID: "member", compoundLinkIDs: [], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    /// Pins the recorded decision that an adoptable row wins over a foreign draft: adoption uploads nothing,
    /// so the draft cannot block it.
    func testAnAdoptableRowWinsOverAForeignDraft() {
        let rows: [RemotePhotoDuplicate] = [
            .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "standalone"),
            .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "draft", clientUID: "other"),
        ]
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch", remoteItems: rows,
            sourceLinkID: "member", compoundLinkIDs: ["member"], currentClientUID: "client")
        XCTAssertEqual(decision, .adopt(remoteLinkID: "standalone"))
    }

    func testForeignDraftBlocksTheCopy() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "draft", clientUID: "other")
            ],
            sourceLinkID: "member", compoundLinkIDs: ["member"], currentClientUID: "client")
        XCTAssertEqual(decision, .blockedByForeignDraft)
    }

    func testOwnDraftIsReplaced() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "draft", clientUID: "client")
            ],
            sourceLinkID: "member", compoundLinkIDs: ["member"], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: true))
    }

    func testTrashedOrDifferentContentNeverSuppressesTheCopy() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: "ch", linkState: .trashed, linkID: "old"),
                .init(nameHash: "nh", contentHash: "different", linkState: .active, linkID: "same-name"),
            ],
            sourceLinkID: "member", compoundLinkIDs: [], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    func testARowThatOnlyTheStaleCompoundListNamesIsExcluded() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "stale-compound-row")
            ],
            sourceLinkID: "member", compoundLinkIDs: ["main", "stale-compound-row"], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    func testRowsUnderADifferentNameHashAreIgnoredEntirely() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "other", contentHash: "ch", linkState: .active, linkID: "standalone"),
                .init(nameHash: "other", contentHash: nil, linkState: .draft, linkID: "draft", clientUID: "other"),
            ],
            sourceLinkID: "member", compoundLinkIDs: ["member"], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    func testMixedOwnAndForeignDraftsBlock() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "own", clientUID: "client"),
                .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "foreign", clientUID: "other"),
            ],
            sourceLinkID: "member", compoundLinkIDs: [], currentClientUID: "client")
        XCTAssertEqual(decision, .blockedByForeignDraft)
    }

    func testNoRowsAtAllUploadsPlainly() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch", remoteItems: [],
            sourceLinkID: "member", compoundLinkIDs: [], currentClientUID: "client")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }
}
