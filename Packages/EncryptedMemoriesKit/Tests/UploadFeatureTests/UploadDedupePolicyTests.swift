import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Name correction trims, limits length to 255 characters, removes invalid characters, and applies the SHA-1 fallback when required.
final class ProtonPhotoNameCorrectionTests: XCTestCase {
    private func uppercaseSHA1(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    func testCleanNamePassesThroughUnchanged() {
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "IMG_0001.HEIC"), "IMG_0001.HEIC")
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "Ünïcode näme.jpg"), "Ünïcode näme.jpg")
    }

    func testNoLowercasingOrNormalization() {
        // The corrected name feeds the HMAC byte-for-byte - case must survive.
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "PHOTO.JPG"), "PHOTO.JPG")
    }

    func testInvalidCharactersAreDeletedNotReplaced() {
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "a/b\\c.jpg"), "abc.jpg")
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "bad\u{01}name\u{1F}.png"), "badname.png")
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "zero\u{200B}width\u{200F}.gif"), "zerowidth.gif")
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "rtl\u{202E}override.jpg"), "rtloverride.jpg")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "  padded.jpg\n"), "padded.jpg")
    }

    func testOverlongNameKeepsSuffixSoExtensionSurvives() {
        let name = String(repeating: "a", count: 300) + ".jpg"
        let corrected = ProtonPhotoNameCorrection.correctedName(for: name)
        XCTAssertEqual(corrected.count, 255)
        XCTAssertTrue(corrected.hasSuffix(".jpg"))
    }

    func testNameThatCleansToEmptyFallsBackToPlaceholder() {
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "///"), uppercaseSHA1("///"))
    }

    func testCleanedNameWithExposedLeadingWhitespaceFallsBackToPlaceholder() {
        // Deleting the leading slash exposes a leading space to validation fails to placeholder
        // (uppercase SHA-1 of the pre-cleaning name, extension re-attached).
        XCTAssertEqual(
            ProtonPhotoNameCorrection.correctedName(for: "/ x.jpg"),
            uppercaseSHA1("/ x.jpg") + ".jpg"
        )
    }

    func testDotAndDotDotFallBackToPlaceholder() {
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "."), uppercaseSHA1("."))
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: ".."), uppercaseSHA1(".."))
    }

    func testUTF8ByteBudgetUsesBytesNotCharacters() {
        // 100 emoji = 100 characters but 400 UTF-8 bytes to over budget to placeholder.
        let name = String(repeating: "😀", count: 100)
        let corrected = ProtonPhotoNameCorrection.correctedName(for: name)
        XCTAssertEqual(corrected, uppercaseSHA1(name))
    }

    func testEmptyNameBecomesEmptyNamePlaceholder() {
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: ""), "emptyName")
        XCTAssertEqual(ProtonPhotoNameCorrection.correctedName(for: "   "), "emptyName")
    }

    func testDeterministic() {
        XCTAssertEqual(
            ProtonPhotoNameCorrection.correctedName(for: "a/b.jpg"),
            ProtonPhotoNameCorrection.correctedName(for: "a/b.jpg")
        )
    }
}

/// The Proton duplicate decision tree, branch by branch.
final class UploadDuplicateDecisionPolicyTests: XCTestCase {
    private func resource(_ id: String, name: String, content: String) -> UploadDuplicateDecisionPolicy.Resource {
        .init(
            source: UploadSourceIdentity(kind: .fileURL, identifier: id),
            nameHash: name,
            contentHash: content
        )
    }

    private let primary = UploadDuplicateDecisionPolicy.Resource(
        source: UploadSourceIdentity(kind: .fileURL, identifier: "/p.jpg"),
        nameHash: "nh-p",
        contentHash: "ch-p"
    )

    func testNoRemoteItemsUploads() {
        XCTAssertEqual(UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: []), .upload)
    }

    func testDisjointNameHashesUploadWithoutContentComparison() {
        let remote = [RemotePhotoDuplicate(nameHash: "nh-other", contentHash: "ch-p", linkState: .active, linkID: "l1")]
        XCTAssertEqual(UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote), .upload)
    }

    func testNameMatchWithDifferentContentUploadsUnderSameName() {
        // Proton photo shares tolerate duplicate name hashes - no rename, no block.
        let remote = [
            RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-DIFFERENT", linkState: .active, linkID: "l1")
        ]
        XCTAssertEqual(UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote), .upload)
    }

    func testActiveExactDuplicateSkips() {
        let remote = [RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: "l1")]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote),
            .skip(.activeDuplicate, remoteLinkID: "l1")
        )
    }

    func testTrashedExactDuplicateSkips() {
        let remote = [RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .trashed, linkID: "l1")]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote),
            .skip(.trashedDuplicate, remoteLinkID: "l1")
        )
    }

    func testAnActiveExactDuplicateWinsOverATrashedOneListedFirst() {
        // After a merge of duplicates, one copy is in the trash and the kept copy is active. The photo is backed up,
        // whatever order the server lists them in.
        for state: RemotePhotoDuplicate.LinkState? in [.trashed, nil] {
            let remote = [
                RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: state, linkID: "merged-away"),
                RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: "kept"),
            ]
            XCTAssertEqual(
                UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote),
                .skip(.activeDuplicate, remoteLinkID: "kept"))
        }
    }

    func testNilLinkStateMeansDeletedAndSkips() {
        let remote = [RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: nil, linkID: "l1")]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote),
            .skip(.deletedRemotely, remoteLinkID: "l1")
        )
    }

    func testExactActiveContentWinsOverUnrelatedSameNameDraft() {
        let remote = [
            RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-DIFFERENT", linkState: .draft, linkID: "l-draft"),
            RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: "l-active"),
        ]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote),
            .skip(.activeDuplicate, remoteLinkID: "l-active")
        )
    }

    func testForeignDraftBlocksWithoutTreatingFilenameAsIdentity() {
        let remote = [
            RemotePhotoDuplicate(
                nameHash: "nh-p", contentHash: "ch-DIFFERENT", linkState: .draft,
                linkID: "l-draft", clientUID: "other-installation"
            )
        ]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(
                primary: primary,
                remoteItems: remote,
                currentClientUID: "this-installation"
            ),
            .skip(.draftExists, remoteLinkID: "l-draft")
        )
    }

    func testOwnInterruptedDraftUsesExplicitReplacement() {
        let remote = [
            RemotePhotoDuplicate(
                nameHash: "nh-p", contentHash: "ch-p", linkState: .draft,
                linkID: "l-draft", clientUID: "this-installation"
            )
        ]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(
                primary: primary,
                remoteItems: remote,
                currentClientUID: "this-installation"
            ),
            .uploadReplacingDraft
        )
    }

    func testMixedOwnerDraftsRemainFailClosed() {
        let remote = [
            RemotePhotoDuplicate(
                nameHash: "nh-p", contentHash: "ch-p", linkState: .draft,
                linkID: "own", clientUID: "this-installation"),
            RemotePhotoDuplicate(
                nameHash: "nh-p", contentHash: "other", linkState: .draft,
                linkID: "foreign", clientUID: "other-installation"),
        ]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(
                primary: primary,
                remoteItems: remote,
                currentClientUID: "this-installation"
            ),
            .skip(.draftExists, remoteLinkID: "own")
        )
    }

    func testActiveDuplicateWithoutLinkIDSkipsAsInconsistent() {
        let remote = [RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: nil)]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, remoteItems: remote),
            .skip(.inconsistentRemoteState, remoteLinkID: nil)
        )
    }

    func testCompleteCompoundSkips() {
        let secondary = resource("/p.mov", name: "nh-s", content: "ch-s")
        let remote = [
            RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: "l1"),
            RemotePhotoDuplicate(nameHash: "nh-s", contentHash: "ch-s", linkState: .active, linkID: "l2"),
        ]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, secondaries: [secondary], remoteItems: remote),
            .skip(.activeDuplicate, remoteLinkID: "l1")
        )
    }

    func testMissingSecondaryYieldsPartialUpload() {
        let secondary = resource("/p.mov", name: "nh-s", content: "ch-s")
        let remote = [RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: "l1")]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, secondaries: [secondary], remoteItems: remote),
            .uploadMissingSecondaries(primaryLinkID: "l1", missing: [secondary.source])
        )
    }

    func testSecondaryMatchedByDraftCountsAsUploaded() {
        let secondary = resource("/p.mov", name: "nh-s", content: "ch-s")
        let remote = [
            RemotePhotoDuplicate(nameHash: "nh-p", contentHash: "ch-p", linkState: .active, linkID: "l1"),
            RemotePhotoDuplicate(nameHash: "nh-s", contentHash: "ch-DIFFERENT", linkState: .draft, linkID: "l2"),
        ]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, secondaries: [secondary], remoteItems: remote),
            .skip(.activeDuplicate, remoteLinkID: "l1")
        )
    }

    func testSecondaryNameCollisionAloneDoesNotBlockUpload() {
        // The secondary's name hash matches remotely, but no primary match exists.
        // Stage 2 finds no remote primary, so the compound uploads.
        let secondary = resource("/p.mov", name: "nh-s", content: "ch-s")
        let remote = [RemotePhotoDuplicate(nameHash: "nh-s", contentHash: "ch-other", linkState: .active, linkID: "l2")]
        XCTAssertEqual(
            UploadDuplicateDecisionPolicy.decide(primary: primary, secondaries: [secondary], remoteItems: remote),
            .upload
        )
    }
}
