import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The pipeline and guarded executor read the same server links, including lineage and external identity.
final class UploadLineageReplacementTests: XCTestCase {
    private var directory: URL!
    private var library: EditScenarioLibrary!
    private var server: EditScenarioServer!
    private var identities: FakeIdentityStore!
    private var journal: EditReplacementJournalFileStore!
    private var pipeline: UploadDedupePipeline!
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = EditScenarioLibrary(directory: directory)
        library.add()
        server = EditScenarioServer()
        identities = FakeIdentityStore()
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        pipeline = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func descriptor(
        _ bytes: String, filename: String = "Render.JPG", cloudID: String? = "cloud-asset-1", edited: Bool = true,
        editTime: Date? = Date(timeIntervalSince1970: 1_720_000_010), unique: Bool = true
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source, fileURL: directory.appendingPathComponent(filename), filename: filename,
            fileSize: Int64(bytes.utf8.count), modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
            precomputedSHA1Digest: Data(Insecure.SHA1.hash(data: Data(bytes.utf8))),
            externalIdentifier: cloudID, isEditedPhoto: edited,
            photoLibraryEditTime: editTime,
            photoLibraryCreationDate: Date(timeIntervalSince1970: 1_720_000_000),
            externalIdentifierIsUnique: unique,
            originalSHA1Hex: [
                UploadContentSHA1.hexString(digest: Data(Insecure.SHA1.hash(data: Data("original".utf8))))
            ])
    }

    private func seed(
        _ bytes: String, filename: String = "Remote.JPG", cloudID: String? = "cloud-asset-1",
        replacing: Set<String> = [], modificationDate: Date? = nil, main: PhotoUID? = nil,
        mimeType: String = "image/jpeg", includeOriginal: Bool = true
    ) throws -> PhotoUID {
        let descriptor = descriptor(bytes, filename: filename, cloudID: cloudID)
        let uid = server.seedV105Upload(
            descriptor, digest: try XCTUnwrap(descriptor.precomputedSHA1Digest),
            asset: try XCTUnwrap(library.snapshot.first), main: main,
            externalIdentifier: cloudID, replacing: replacing, mimeType: mimeType)
        if let modificationDate { server.setModificationDate(modificationDate, of: uid) }
        if main == nil, bytes != "original", includeOriginal {
            _ = try seed("original", filename: "Anchor.HEIC", cloudID: cloudID, main: uid, mimeType: "image/heic")
        }
        return uid
    }

    private func rememberOriginal(_ uid: PhotoUID) async throws {
        let original = descriptor("original", filename: "IMG_1.HEIC", edited: false)
        let result = try await pipeline.resolve(original)
        try await pipeline.recordUploaded(
            original, identity: result.identity, remoteVolumeID: uid.volumeID, remoteLinkID: uid.nodeID)
    }

    private func superseded() -> Set<String> { Set(journal.entry(for: source).allSuperseded.map(\.nodeID)) }

    func testLineageHeadReplacesMissingLastUpload() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        server.personEmptyTrash()
        let head = try seed("head", replacing: [original.nodeID])

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .upload)
        XCTAssertTrue(superseded().contains(head.nodeID))
    }

    func testLineageHeadExtendsScopeWithAnActiveAncestor() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        server.personEmptyTrash()
        let ancestor = try seed("ancestral", filename: "Render.JPG", cloudID: nil)
        let head = try seed("head", replacing: [original.nodeID, ancestor.nodeID])

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .upload)
        XCTAssertTrue(superseded().contains(head.nodeID))
        // The ancestor has no iCloud identifier, so nothing proves it is this asset: it stays (decision 5 of the
        // #220 design).
        XCTAssertFalse(superseded().contains(ancestor.nodeID), "an unproven ancestor is never a trash target")
    }

    func testIdentityHeadReplacesWithoutALocalManifest() async throws {
        let head = try seed("remote-edit")

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(superseded(), [head.nodeID])
    }

    /// Another device's newer edit proves the photo live: the older edit uploads next to it and asks nothing.
    func testNewerHeadOfAnotherDeviceProvesThePhotoLiveWithoutBecomingATarget() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        let head = try seed(
            "newer-edit", replacing: [original.nodeID], modificationDate: Date(timeIntervalSince1970: 1_720_000_020))
        try journal.keepDeleted(for: source)

        let older = descriptor("older-edit")
        let result = try await pipeline.resolve(older)
        await pipeline.uploadDidFail(older)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertFalse(superseded().contains(head.nodeID), "a newer version is never a target")
        XCTAssertNil(journal.entry(for: source).keptDeleted, "the live photo ends the earlier choice")
    }

    /// A newer version that the person trashes during the check proves nothing, so the deletion check stays.
    func testNewerHeadTrashedDuringTheCheckProvesNothing() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        let head = try seed(
            "newer-edit", replacing: [original.nodeID], modificationDate: Date(timeIntervalSince1970: 1_720_000_020))
        server.trashAfterCompoundRead = head.nodeID

        let result = try await pipeline.resolve(descriptor("older-edit"))

        XCTAssertEqual(result.decision, .awaitDeletionCheck)
    }

    func testDifferentIdentityWithEditedBytesIsNotAdoptedOrTrashed() async throws {
        let head = try seed("head")
        let other = try seed("next", filename: "Render.JPG", cloudID: "other-asset")
        let result = try await pipeline.resolve(descriptor("next"))
        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(superseded(), [head.nodeID])
        let replacement = try seed(
            "next", filename: "Winner.JPG", modificationDate: descriptor("next").photoLibraryEditTime)
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)

        let outcome = try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: true,
            externalIdentifier: descriptor("next").externalIdentifier,
            localEditTime: descriptor("next").photoLibraryEditTime,
            localCreationDate: descriptor("next").photoLibraryCreationDate,
            externalIdentifierIsUnique: descriptor("next").externalIdentifierIsUnique,
            originalSHA1Hex: descriptor("next").originalSHA1Hex)

        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .trashed)
        XCTAssertEqual(server.links.first { $0.uid == other }?.state, .active)
    }

    func testIncompleteIndexKeepsTodaysDuplicateDecisionWithoutAddingTargets() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")
        server.configureLineageIndex(incomplete: .identity)

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertTrue(journal.entry(for: source).isEmpty)
    }

    func testIncompleteSuccessorReadAddsNoRemoteHead() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        let head = try seed("head", replacing: [original.nodeID])
        server.configureLineageIndex(incomplete: .successors)

        _ = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(superseded(), [original.nodeID])
        XCTAssertFalse(superseded().contains(head.nodeID))
    }

    func testIncompleteAncestryReadAddsNoRemoteHead() async throws {
        let head = try seed("head")
        server.configureLineageIndex(incomplete: .ancestry)

        _ = try await pipeline.resolve(descriptor("next"))

        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testIncompleteMainIdentityReadAddsNoRemoteHead() async throws {
        let head = try seed("head")
        server.configureLineageIndex(incomplete: .external)

        _ = try await pipeline.resolve(descriptor("next"))

        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testRetryKeepsTheForeignAdoptedMainOutOfTheTargets() async throws {
        let other = try seed("original", filename: "IMG_1.HEIC", cloudID: "other-asset")
        try await rememberOriginal(other)
        let head = try seed("head")
        _ = try await pipeline.resolve(descriptor("next"))
        // The app stopped before the manifest recorded the upload: after a relaunch the retry reads the same manifest.
        let relaunched = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        _ = try await relaunched.resolve(descriptor("next"))

        XCTAssertEqual(superseded(), [head.nodeID])
        XCTAssertFalse(superseded().contains(other.nodeID))
    }

    func testEarlierVersionsDoNotSeeARemoteTarget() async throws {
        let head = try seed("head")
        _ = try await pipeline.resolve(descriptor("next"))

        // Earlier versions read only `superseded` and lack the guards that prove a remote target.
        XCTAssertTrue(journal.entry(for: source).superseded.isEmpty)
        XCTAssertEqual(journal.entry(for: source).remoteSuperseded, [head.nodeID])
    }

    func testLocallyAdoptedMainOfAnotherAssetIsNotAReplacementTarget() async throws {
        let other = try seed("original", filename: "IMG_1.HEIC", cloudID: "other-asset")
        try await rememberOriginal(other)
        let head = try seed("head")

        _ = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(superseded(), [head.nodeID])
        XCTAssertFalse(superseded().contains(other.nodeID))
    }

    func testFailedIndexReadKeepsTodaysDuplicateDecisionWithoutAddingTargets() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")
        server.configureLineageIndex(failing: true)

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertTrue(journal.entry(for: source).isEmpty)
    }

    func testRemoteTargetProvenanceSurvivesReopeningTheJournal() async throws {
        let head = try seed("head")
        _ = try await pipeline.resolve(descriptor("next"))
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))

        XCTAssertEqual(reopened.entry(for: source).allSuperseded.map(\.nodeID), [head.nodeID])
        XCTAssertEqual(reopened.entry(for: source).remoteSuperseded, [head.nodeID])
    }

    func testIncompleteIndexAtSettlementKeepsTheRemoteHead() async throws {
        let head = try seed("head")
        _ = try await pipeline.resolve(descriptor("next"))
        let replacement = try seed(
            "next", filename: "Winner.JPG", modificationDate: descriptor("next").photoLibraryEditTime)
        XCTAssertEqual(journal.entry(for: source).remoteSuperseded, [head.nodeID])
        server.configureLineageIndex(incomplete: .ancestry)
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)

        let outcome = try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: true,
            externalIdentifier: descriptor("next").externalIdentifier,
            localEditTime: descriptor("next").photoLibraryEditTime,
            localCreationDate: descriptor("next").photoLibraryCreationDate,
            externalIdentifierIsUnique: descriptor("next").externalIdentifierIsUnique,
            originalSHA1Hex: descriptor("next").originalSHA1Hex)

        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testFailedIndexReadAtSettlementKeepsTheRemoteHead() async throws {
        let head = try seed("head")
        _ = try await pipeline.resolve(descriptor("next"))
        let replacement = try seed(
            "next", filename: "Winner.JPG", modificationDate: descriptor("next").photoLibraryEditTime)
        server.configureLineageIndex(failing: true)
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)

        let outcome = try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: true,
            externalIdentifier: descriptor("next").externalIdentifier,
            localEditTime: descriptor("next").photoLibraryEditTime,
            localCreationDate: descriptor("next").photoLibraryCreationDate,
            externalIdentifierIsUnique: descriptor("next").externalIdentifierIsUnique,
            originalSHA1Hex: descriptor("next").originalSHA1Hex)

        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testAssetWithoutICloudIDKeepsTodaysDuplicateDecision() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")

        let result = try await pipeline.resolve(descriptor("next", cloudID: nil))

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertTrue(journal.entry(for: source).isEmpty)
    }

    func testUnchangedPhotoKeepsADuplicateWithDifferentIdentity() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")

        let result = try await pipeline.resolve(descriptor("next", edited: false))

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertTrue(journal.entry(for: source).isEmpty)
    }

    func testUneditedByteDriftKeepsTodaysDuplicateDecision() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")

        let result = try await pipeline.resolve(descriptor("next", edited: false))

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertEqual(superseded(), [original.nodeID], "The existing local scope must retain today's behavior")
    }

    func testIdentityHeadStillWaitsWhenTheReplacementLacksAnOriginal() async throws {
        let head = try seed("head")
        _ = try await pipeline.resolve(descriptor("next"))
        let replacement = try seed(
            "next", filename: "Winner.JPG", modificationDate: descriptor("next").photoLibraryEditTime)
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)

        let outcome = try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: false,
            externalIdentifier: descriptor("next").externalIdentifier,
            localEditTime: descriptor("next").photoLibraryEditTime,
            localCreationDate: descriptor("next").photoLibraryCreationDate,
            externalIdentifierIsUnique: descriptor("next").externalIdentifierIsUnique,
            originalSHA1Hex: descriptor("next").originalSHA1Hex)

        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testIdentityHeadNeededByAnotherSourceStaysActive() async throws {
        let head = try seed("head")
        let record = UploadIdentityRecord(
            source: .init(kind: .photoLibraryAsset, identifier: "another-source"), filename: "Remote.JPG",
            correctedName: "Remote.JPG", fileSize: 4, modificationDate: Date(), sha1Hex: "unused",
            nameHash: "unused", contentHash: "unused", hashKeyEpoch: "scenario-epoch",
            remoteVolumeID: "vol", remoteLinkID: head.nodeID, outcome: "uploaded", updatedAt: Date())
        XCTAssertTrue(identities.upsert(record))
        _ = try await pipeline.resolve(descriptor("next"))
        let replacement = try seed(
            "next", filename: "Winner.JPG", modificationDate: descriptor("next").photoLibraryEditTime)
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)

        let outcome = try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: true,
            externalIdentifier: descriptor("next").externalIdentifier,
            localEditTime: descriptor("next").photoLibraryEditTime,
            localCreationDate: descriptor("next").photoLibraryCreationDate,
            externalIdentifierIsUnique: descriptor("next").externalIdentifierIsUnique,
            originalSHA1Hex: descriptor("next").originalSHA1Hex)

        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    private func settle(_ replacement: PhotoUID) async throws -> EditedPhotoReplacement.Outcome {
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: server, identities: identities, journal: journal)
        return try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: true,
            externalIdentifier: descriptor("next").externalIdentifier,
            localEditTime: descriptor("next").photoLibraryEditTime,
            localCreationDate: descriptor("next").photoLibraryCreationDate,
            externalIdentifierIsUnique: descriptor("next").externalIdentifierIsUnique,
            originalSHA1Hex: descriptor("next").originalSHA1Hex)
    }

    private func uploadAfterResolving(_ bytes: String, includeOriginal: Bool = true) async throws -> PhotoUID {
        let local = descriptor(bytes)
        let result = try await pipeline.resolve(local)
        XCTAssertEqual(result.decision, .upload)
        let uid = try seed(
            bytes, filename: "Winner.JPG", modificationDate: local.photoLibraryEditTime,
            includeOriginal: includeOriginal)
        try await pipeline.recordUploaded(
            local, identity: result.identity, remoteVolumeID: uid.volumeID, remoteLinkID: uid.nodeID)
        return uid
    }

    func testOlderLocalEditKeepsNewerRemoteHead() async throws {
        let head = try seed("newer", modificationDate: Date(timeIntervalSince1970: 1_720_000_020))
        let replacement = try await uploadAfterResolving("older")

        _ = try await settle(replacement)

        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
        XCTAssertFalse(server.steps.contains { $0.trashedByBackup.contains(head.nodeID) })
    }

    func testEqualModificationTimeKeepsRemoteHead() async throws {
        let head = try seed("equal-date", modificationDate: descriptor("next").photoLibraryEditTime)
        let replacement = try await uploadAfterResolving("next")

        _ = try await settle(replacement)

        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
    }

    func testUnknownModificationTimeKeepsRemoteHead() async throws {
        let head = try seed("unknown-date")
        server.setModificationDate(nil, of: head)
        let replacement = try await uploadAfterResolving("next")

        _ = try await settle(replacement)

        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
    }

    func testTwoRemoteHeadsAreNeverTrashed() async throws {
        let first = try seed("head-one")
        let second = try seed("head-two", filename: "Second.JPG")
        let replacement = try await uploadAfterResolving("next")
        XCTAssertTrue(journal.entry(for: source).isEmpty)

        _ = try await settle(replacement)

        for head in [first, second] {
            XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
            XCTAssertFalse(server.steps.contains { $0.trashedByBackup.contains(head.nodeID) })
        }
    }

    func testOlderLocalEditKeepsNewerLineageHeadWithoutIdentity() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        server.personEmptyTrash()
        let head = try seed(
            "newer-lineage", cloudID: nil, replacing: [original.nodeID],
            modificationDate: Date(timeIntervalSince1970: 1_720_000_020))

        // Nothing with this photo's identity is live, so the older edit waits for the deletion check instead of
        // uploading a second photo; the newer photo is never a target.
        let result = try await pipeline.resolve(descriptor("older"))

        XCTAssertEqual(result.decision, .awaitDeletionCheck)
        XCTAssertFalse(superseded().contains(head.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testRemoteRelatedResourceWithoutTwinKeepsItsMain() async throws {
        let head = try seed("head")
        let related = try seed("unique-motion", filename: "Motion.MOV", main: head)
        let replacement = try await uploadAfterResolving("next")
        _ = try seed("original", filename: "Original.HEIC", main: replacement)

        _ = try await settle(replacement)

        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == related }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
    }

    func testRemoteRelatedResourcesWithAllTwinsRetireTheirMain() async throws {
        let head = try seed("head", includeOriginal: false)
        _ = try seed("original", filename: "Original.HEIC", main: head)
        _ = try seed("motion", filename: "Motion.MOV", main: head)
        let replacement = try await uploadAfterResolving("next", includeOriginal: false)
        let original = try seed("original", filename: "Copy.HEIC", main: replacement)
        let motion = try seed("motion", filename: "Copy.MOV", main: replacement)

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .trashed)
        for resource in [original, motion] {
            XCTAssertEqual(server.links.first { $0.uid == resource }?.state, .active)
            XCTAssertEqual(server.links.first { $0.uid == resource }?.mainLinkID, replacement.nodeID)
        }
    }

    func testFailedCompoundReadKeepsRemoteMainAndCompletesUpload() async throws {
        let head = try seed("head")
        let replacement = try await uploadAfterResolving("next")
        server.configureOptionalReads(compoundFails: true)

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
    }

    func testFailedVisibilityReadKeepsTodaysDuplicateDecision() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")
        let baseline = UploadDedupePipeline(store: FakeIdentityStore(), checker: server)
        let today = try await baseline.resolve(descriptor("next"))
        server.configureOptionalReads(visibilityFails: true)

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(today.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertEqual(result.decision, today.decision)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
    }

    func testMissingLocalEditTimeKeepsTodaysScope() async throws {
        let head = try seed("head")
        let local = descriptor("next", editTime: nil)
        let baseline = UploadDedupePipeline(store: FakeIdentityStore(), checker: server)
        let today = try await baseline.resolve(local)
        let result = try await pipeline.resolve(local)
        XCTAssertEqual(result.decision, today.decision)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testSharedCloudIdentifierKeepsTodaysScope() async throws {
        let head = try seed("head")
        library.add("asset-2")
        library.shareCloudIdentifier("shared-cloud", between: ["asset-1", "asset-2"])
        let matching = library.snapshot.filter { $0.info.cloudIdentifier == "shared-cloud" }
        XCTAssertEqual(matching.count, 2)
        let local = descriptor("next", unique: matching.count == 1)
        let baseline = UploadDedupePipeline(store: FakeIdentityStore(), checker: server)
        let today = try await baseline.resolve(local)
        let result = try await pipeline.resolve(local)
        XCTAssertEqual(result.decision, today.decision)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testOlderEditAfterFavoriteToggleStillKeepsNewerHead() async throws {
        let head = try seed("head", modificationDate: Date(timeIntervalSince1970: 1_720_000_020))
        library.edit("next", at: Date(timeIntervalSince1970: 1_720_000_010))
        for _ in 0..<30 { library.changeModificationDate() }
        let asset = try XCTUnwrap(library.snapshot.first)
        XCTAssertGreaterThan(asset.modificationDate, Date(timeIntervalSince1970: 1_720_000_020))
        let local = descriptor("next", editTime: asset.adjustmentTimestamp)
        _ = try await pipeline.resolve(local)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testSeriesHeadRetiresWhenEveryFrameHasATwin() async throws {
        let head = try seed("head")
        server.setTags([7], of: head)
        _ = try seed("frame", filename: "Frame.JPG", main: head)
        let replacement = try await uploadAfterResolving("next")
        server.setTags([7], of: replacement)
        let frame = try seed("frame", filename: "Frame.JPG", main: replacement)

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .trashed)
        XCTAssertEqual(server.links.first { $0.uid == frame }?.mainLinkID, replacement.nodeID)
    }

    func testSeriesHeadStaysWhenAFrameHasNoTwin() async throws {
        let head = try seed("head")
        server.setTags([7], of: head)
        let frame = try seed("frame-deleted-here", filename: "Frame.JPG", main: head)
        let replacement = try await uploadAfterResolving("next")
        server.setTags([7], of: replacement)

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .kept, "the earlier series holds a frame that the new series lacks")
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == frame }?.state, .active)
    }

    func testSeriesHeadIsATargetAtDiscovery() async throws {
        let head = try seed("head")
        server.setTags([7], of: head)
        let result = try await pipeline.resolve(descriptor("next"))
        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(superseded(), [head.nodeID])
    }

    /// Another device replaced the series with a newer edit: it proves the series live, so nothing asks.
    func testNewerSeriesOfAnotherDeviceProvesThePhotoLive() async throws {
        let original = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(original)
        server.personTrash(original)
        let head = try seed(
            "newer-edit", replacing: [original.nodeID], modificationDate: Date(timeIntervalSince1970: 1_720_000_020))
        server.setTags([7], of: head)
        try journal.keepDeleted(for: source)

        let older = descriptor("older-edit")
        let result = try await pipeline.resolve(older)
        await pipeline.uploadDidFail(older)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertFalse(superseded().contains(head.nodeID), "a newer version is never a target")
        XCTAssertNil(journal.entry(for: source).keptDeleted, "the live series ends the earlier choice")
    }

    func testRAWWithoutTwinKeepsItsMain() async throws {
        try await uniqueResourceKeepsMain(filename: "Unique.DNG", mimeType: "image/x-adobe-dng")
    }

    func testFrameWithoutTwinKeepsItsMain() async throws {
        try await uniqueResourceKeepsMain(filename: "Frame.JPG", mimeType: "image/jpeg")
    }

    private func uniqueResourceKeepsMain(filename: String, mimeType: String) async throws {
        let head = try seed("head")
        let related = try seed("unique-resource", filename: filename, main: head, mimeType: mimeType)
        let replacement = try await uploadAfterResolving("next")
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
        XCTAssertEqual(server.links.first { $0.uid == related }?.state, .active)
    }

    func testReplacementMainCountsAsAContentTwin() async throws {
        let head = try seed("head")
        _ = try seed("next", filename: "EarlierRelated.JPG", main: head)
        let replacement = try await uploadAfterResolving("next")
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .trashed)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
    }

    func testTransportCancellationInEveryOptionalLineageFallbackPropagates() async throws {
        let errors: [any Error] = [
            URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: URLError.cancelled.rawValue, message: "cancelled"),
        ]
        for route in ["discovery", "foreign", "ancestry"] {
            for failure in errors {
                let localDirectory = directory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
                let localJournal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: localDirectory))
                let head = try seed("head")
                if route != "discovery" {
                    try localJournal.addSuperseded(head, for: source)
                }
                server.configureLineageIndex(failing: false)
                if route == "ancestry" {
                    server.configureLineageFailureAtAncestry(failure)
                } else {
                    server.configureLineageIndex(failing: true, error: failure)
                }
                let localPipeline = UploadDedupePipeline(
                    store: FakeIdentityStore(), checker: server, replacementJournal: localJournal)
                let before = localJournal.entry(for: source)
                let next = descriptor("next", edited: route != "foreign")
                do {
                    let result = try await localPipeline.resolve(next)
                    XCTFail("\(route) cancellation must propagate: \(result.decision)")
                    await localPipeline.uploadDidFail(next)
                } catch {
                    XCTAssertTrue(UploadError.isCancellation(error))
                    XCTAssertFalse(Task.isCancelled)
                }
                XCTAssertEqual(localJournal.entry(for: source), before)
                server.configureLineageFailureAtAncestry(nil)
            }
        }
    }

    func testCancellationAtDiscoveryLeavesJournalUnchanged() async throws {
        _ = try seed("head")
        let before = journal.entry(for: source)
        server.configureOptionalReads(compoundCancels: true)
        do {
            _ = try await pipeline.resolve(descriptor("next"))
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertEqual(journal.entry(for: source), before)
    }

    func testCancellationAtRetirementLeavesJournalUnchanged() async throws {
        let head = try seed("head")
        let replacement = try await uploadAfterResolving("next")
        try journal.prepareToRetire([head.nodeID: ["earlier-intent"]], for: source)
        let before = journal.entry(for: source)
        server.configureOptionalReads(compoundCancels: true)
        do {
            _ = try await settle(replacement)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertEqual(journal.entry(for: source), before)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testFailedCompoundAtDiscoveryGivesTodaysDecision() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: "other-asset")
        let baseline = UploadDedupePipeline(store: FakeIdentityStore(), checker: server)
        let today = try await baseline.resolve(descriptor("next"))
        server.configureOptionalReads(compoundFails: true)
        let result = try await pipeline.resolve(descriptor("next"))
        XCTAssertEqual(today.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertEqual(result.decision, today.decision)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
    }

    func testMissingIdentityCandidateRemainsAdoptable() async throws {
        _ = try seed("head")
        let duplicate = try seed("next", filename: "Render.JPG", cloudID: nil)
        let result = try await pipeline.resolve(descriptor("next"))
        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
    }

    private func editAfterAdopting(cloudID: String?) async throws -> (PhotoUID, UploadLineageMarker?) {
        let adopted = try seed("original", filename: "IMG_1.HEIC", cloudID: cloudID)
        let first = try await pipeline.resolve(descriptor("original", filename: "IMG_1.HEIC", edited: false))
        XCTAssertEqual(first.decision, .skip(.activeDuplicate, remoteLinkID: adopted.nodeID))
        let relaunched = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        let result = try await relaunched.resolve(descriptor("next"))
        XCTAssertEqual(superseded(), [adopted.nodeID])
        return (adopted, result.lineage)
    }

    func testAnAdoptedLinkWithoutItsIdentityIsNotNamed() async throws {
        let (_, lineage) = try await editAfterAdopting(cloudID: nil)

        XCTAssertNil(lineage, "nothing proves that the adopted copy is this photo")
    }

    func testAnAdoptedLinkWithItsIdentityIsNamed() async throws {
        let (adopted, lineage) = try await editAfterAdopting(cloudID: "cloud-asset-1")

        XCTAssertEqual(lineage?.replaces, [adopted.nodeID])
    }

    /// Another device uploaded a Live Photo whose main file matches this still photo. This device adopted it, then
    /// the person edits the still photo here.
    private func editAfterAdoptingALivePhoto(
        cloudID: String?
    ) async throws -> (
        adopted: PhotoUID, video: PhotoUID, replacement: PhotoUID
    ) {
        let adopted = try seed("original", filename: "IMG_1.HEIC", cloudID: cloudID)
        let video = try seed(
            "motion", filename: "IMG_1.MOV", cloudID: cloudID, main: adopted, mimeType: "video/quicktime")
        let first = try await pipeline.resolve(descriptor("original", filename: "IMG_1.HEIC", edited: false))
        XCTAssertEqual(first.decision, .skip(.activeDuplicate, remoteLinkID: adopted.nodeID))
        XCTAssertEqual(
            identities.record(for: source)?.outcome, UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
        let relaunched = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        let local = descriptor("next")
        let edit = try await relaunched.resolve(local)
        XCTAssertEqual(edit.decision, .upload)
        XCTAssertEqual(superseded(), [adopted.nodeID])
        let replacement = try seed("next", filename: "Winner.JPG", modificationDate: local.photoLibraryEditTime)
        try await relaunched.recordUploaded(
            local, identity: edit.identity, remoteVolumeID: replacement.volumeID, remoteLinkID: replacement.nodeID)
        return (adopted, video, replacement)
    }

    func testAnAdoptedCopyWithoutItsIdentityKeepsItsOnlyLivePhotoVideo() async throws {
        let (adopted, video, replacement) = try await editAfterAdoptingALivePhoto(cloudID: nil)

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .kept)
        for uid in [adopted, video, replacement] {
            XCTAssertEqual(server.links.first { $0.uid == uid }?.state, .active)
        }
        XCTAssertFalse(server.steps.contains { $0.trashedByBackup.contains(adopted.nodeID) })
        XCTAssertTrue(superseded().isEmpty)
    }

    func testAnOwnLivePhotoUploadAdoptedAgainAfterAManifestResetIsReplaced() async throws {
        // The adopted copy is this photo's own earlier upload: the edit uploaded its video again under the new photo.
        let (earlier, video, replacement) = try await editAfterAdoptingALivePhoto(cloudID: nil)
        let copy = try seed("motion", filename: "IMG_1.MOV", main: replacement, mimeType: "video/quicktime")

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == earlier }?.state, .trashed)
        XCTAssertTrue(server.steps.contains { $0.trashedByBackup == [earlier.nodeID] })
        for uid in [replacement, copy] { XCTAssertEqual(server.links.first { $0.uid == uid }?.state, .active) }
        XCTAssertTrue(journal.entry(for: source).retired.contains(video.nodeID))
    }

    func testAnAdoptedCopyWithARelatedFileWithoutATwinStays() async throws {
        let (adopted, video, replacement) = try await editAfterAdoptingALivePhoto(cloudID: nil)
        let adjustments = try seed(
            "older-adjustments", filename: "Adjustments.plist", cloudID: nil, main: adopted,
            mimeType: "application/xml")
        _ = try seed("motion", filename: "IMG_1.MOV", main: replacement, mimeType: "video/quicktime")

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .kept)
        for uid in [adopted, video, adjustments, replacement] {
            XCTAssertEqual(server.links.first { $0.uid == uid }?.state, .active)
        }
        XCTAssertFalse(server.steps.contains { $0.trashedByBackup.contains(adopted.nodeID) })
    }

    func testAnAdoptedCopyStaysWhenItsIdentityReadIsIncomplete() async throws {
        server.configureLineageIndex(incomplete: .external)
        let (adopted, video, replacement) = try await editAfterAdoptingALivePhoto(cloudID: "other-asset")

        let outcome = try await settle(replacement)

        XCTAssertEqual(outcome, .kept)
        for uid in [adopted, video, replacement] {
            XCTAssertEqual(server.links.first { $0.uid == uid }?.state, .active)
        }
        XCTAssertFalse(server.steps.contains { $0.trashedByBackup.contains(adopted.nodeID) })
    }

    func testAnOwnLivePhotoUploadIsStillReplacedWithItsVideo() async throws {
        let earlier = try seed("original", filename: "IMG_1.HEIC")
        let video = try seed("motion", filename: "IMG_1.MOV", main: earlier, mimeType: "video/quicktime")
        try await rememberOriginal(earlier)
        let livePairedVideo = UploadSourceIdentity(
            kind: source.kind, identifier: source.identifier, resource: .livePairedVideo)
        func recordVideo(at link: PhotoUID) {
            _ = identities.upsert(
                UploadIdentityRecord(
                    source: livePairedVideo, filename: "IMG_1.MOV", correctedName: "IMG_1.MOV", fileSize: 6,
                    modificationDate: .distantPast, sha1Hex: "motion", nameHash: "nh", contentHash: "ch",
                    hashKeyEpoch: "epoch", remoteVolumeID: link.volumeID, remoteLinkID: link.nodeID,
                    outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: .distantPast))
        }
        recordVideo(at: video)
        let replacement = try await uploadAfterResolving("next")
        // The edit uploaded the video again under the new photo.
        let copy = try seed("motion", filename: "IMG_1.MOV", main: replacement, mimeType: "video/quicktime")
        recordVideo(at: copy)

        let reads = server.readCounts.compound
        let outcome = try await settle(replacement)

        XCTAssertEqual(server.readCounts.compound, reads, "a proven earlier upload needs no compound read")
        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == earlier }?.state, .trashed)
        XCTAssertTrue(server.steps.contains { $0.trashedByBackup == [earlier.nodeID] })
        for uid in [replacement, copy] { XCTAssertEqual(server.links.first { $0.uid == uid }?.state, .active) }
        XCTAssertTrue(journal.entry(for: source).retired.contains(video.nodeID))
    }

    func testTheNextEditStillNamesWhatARemoteHeadReplaced() async throws {
        let ancestor = try seed("ancestral", filename: "Render.JPG", cloudID: nil)
        let head = try seed("head", replacing: [ancestor.nodeID])
        let local = descriptor("next")
        let first = try await pipeline.resolve(local)
        XCTAssertEqual(first.lineage?.replaces, [head.nodeID, ancestor.nodeID])
        let replacement = try seed("next", filename: "Winner.JPG", modificationDate: local.photoLibraryEditTime)
        try await pipeline.recordUploaded(
            local, identity: first.identity, remoteVolumeID: replacement.volumeID, remoteLinkID: replacement.nodeID)
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .replaced(retiredAny: true))

        let relaunched = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        let result = try await relaunched.resolve(descriptor("third"))

        // The anchor that the trash took along with the head is a related file, so it never appears.
        XCTAssertEqual(result.lineage?.replaces, [replacement.nodeID, head.nodeID, ancestor.nodeID])
    }

    /// Adopts a remote head whose marker names `ancestor`, then edits the photo once.
    private func editAfterAdoptingAHead() async throws -> (
        head: PhotoUID, ancestor: PhotoUID, edit: UploadPreflightResult
    ) {
        let ancestor = try seed("ancestral", filename: "Ancestor.JPG", cloudID: nil)
        let head = try seed("head", filename: "IMG_1.JPG", replacing: [ancestor.nodeID])
        let adopted = try await pipeline.resolve(descriptor("head", filename: "IMG_1.JPG", edited: false))
        XCTAssertEqual(adopted.decision, .skip(.activeDuplicate, remoteLinkID: head.nodeID))
        let relaunched = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        let edit = try await relaunched.resolve(descriptor("next"))
        XCTAssertEqual(superseded(), [head.nodeID])
        return (head, ancestor, edit)
    }

    func testAnAdoptedHeadKeepsWhatItsMarkerNamedAfterTheNextEdit() async throws {
        let (head, ancestor, edit) = try await editAfterAdoptingAHead()
        XCTAssertEqual(edit.lineage?.replaces, [head.nodeID, ancestor.nodeID])
        let local = descriptor("next")
        let replacement = try seed("next", filename: "Winner.JPG", modificationDate: local.photoLibraryEditTime)
        let recorder = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        try await recorder.recordUploaded(
            local, identity: edit.identity, remoteVolumeID: replacement.volumeID, remoteLinkID: replacement.nodeID)
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .trashed)

        let relaunched = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
        let result = try await relaunched.resolve(descriptor("third"))

        XCTAssertEqual(result.lineage?.replaces, [replacement.nodeID, head.nodeID, ancestor.nodeID])
    }

    /// A remote head names a trashed upload of the local bytes.
    private func trashedNamedCopy() throws -> (head: PhotoUID, named: PhotoUID) {
        let named = try seed("next", filename: "Render.JPG", cloudID: nil)
        let head = try seed("head", replacing: [named.nodeID])
        server.personTrash(named)
        return (head, named)
    }

    func testATrashedNamedCopyIsReplacedWhileItsHolderIsActive() async throws {
        _ = try trashedNamedCopy()

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .upload)
    }

    func testATrashedNamedCopyIsADeletionOnceItsHolderLeft() async throws {
        let (head, named) = try trashedNamedCopy()
        server.personTrash(head)

        let result = try await pipeline.resolve(descriptor("next"))

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: named.nodeID))
    }

    func testAnAdoptedHeadWithAnIncompleteMarkerReadInheritsNothing() async throws {
        server.configureLineageIndex(incomplete: .ancestry)

        let (head, _, edit) = try await editAfterAdoptingAHead()

        XCTAssertEqual(edit.lineage?.replaces, [head.nodeID])
        XCTAssertNil(journal.entry(for: source).inherited, "a partial list never enters the journal")
    }

    func testLocalTargetStillReplacesBesideTwoRemoteHeads() async throws {
        let local = try seed("original", filename: "IMG_1.HEIC")
        try await rememberOriginal(local)
        let first = try seed("remote-one")
        let second = try seed("remote-two", filename: "Other.JPG")
        let replacement = try await uploadAfterResolving("next")
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == local }?.state, .trashed)
        for head in [first, second] { XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active) }
    }

    func testNewMainAbsentFromIndexStillRetiresItsTarget() async throws {
        let head = try seed("head")
        let clock = BackupTestClock()
        let index = EditScenarioDeviceIndex(server: server, staleLineage: true, now: { clock.now })
        let pipeline = UploadDedupePipeline(store: identities, checker: index, replacementJournal: journal)
        let local = descriptor("next")
        let result = try await pipeline.resolve(local)
        XCTAssertEqual(result.decision, .upload)
        let replacement = try seed("next", filename: "Winner.JPG")
        server.setModificationDate(nil, of: replacement)
        try await pipeline.recordUploaded(
            local, identity: result.identity, remoteVolumeID: replacement.volumeID, remoteLinkID: replacement.nodeID)
        let indexed = try await index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
        XCTAssertEqual(indexed.links, [head.nodeID])
        let executor = EditedPhotoReplacement(
            remote: server, albums: server, relations: index, identities: identities, journal: journal)
        let outcome = try await executor.replaceSuperseded(
            of: source, with: replacement, edited: true, holdsOriginal: true,
            externalIdentifier: local.externalIdentifier, localEditTime: local.photoLibraryEditTime,
            localCreationDate: local.photoLibraryCreationDate, externalIdentifierIsUnique: true,
            originalSHA1Hex: local.originalSHA1Hex)
        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .trashed)
        XCTAssertEqual(server.links.first { $0.uid == replacement }?.state, .active)
        let delayed = try await index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
        XCTAssertFalse(delayed.links.contains(replacement.nodeID))
        clock.advance(by: 15)
        let visible = try await index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
        XCTAssertEqual(visible.links, [replacement.nodeID])
    }

    func testSecondHeadAppearingBeforeRetirementKeepsTarget() async throws {
        let head = try seed("head")
        let replacement = try await uploadAfterResolving("next")
        let other = try seed("concurrent-head", filename: "Concurrent.JPG")
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .kept)
        for uid in [head, replacement, other] {
            XCTAssertEqual(server.links.first { $0.uid == uid }?.state, .active)
        }
    }

    func testDiscoveryDoesNotRefreshAStaleIndex() async throws {
        let clock = BackupTestClock()
        let index = EditScenarioDeviceIndex(server: server, staleLineage: true, now: { clock.now })
        let pipeline = UploadDedupePipeline(store: identities, checker: index, replacementJournal: journal)
        let head = try seed("head")
        let result = try await pipeline.resolve(descriptor("next"))
        XCTAssertEqual(result.decision, .upload)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
        let stale = try await index.activeMainLinkIDs(forExternalIdentifier: "cloud-asset-1")
        XCTAssertTrue(stale.links.isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }
    func testMissingOriginalAnchorKeepsTodaysScope() async throws {
        let head = try seed("head", includeOriginal: false)
        _ = try await pipeline.resolve(descriptor("next"))
        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testCaptureTimeMismatchKeepsTodaysScope() async throws {
        let head = try seed("head")
        let base = descriptor("next")
        let local = base.withPhotoLibraryIdentity(
            identifier: base.externalIdentifier, edited: true, editTime: base.photoLibraryEditTime,
            creationDate: Date(timeIntervalSince1970: 1_720_000_001), isUnique: true,
            originalSHA1Hex: base.originalSHA1Hex)
        _ = try await pipeline.resolve(local)
        XCTAssertTrue(journal.entry(for: source).isEmpty)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }

    func testCaptureTimeMatchesByWholeSecondLikeTheServer() async throws {
        let head = try seed("head")
        let base = descriptor("next")
        // PhotoKit dates carry fractions of a second; the server keeps whole seconds.
        let local = base.withPhotoLibraryIdentity(
            identifier: base.externalIdentifier, edited: true, editTime: base.photoLibraryEditTime,
            creationDate: Date(timeIntervalSince1970: 1_720_000_000.6), isUnique: true,
            originalSHA1Hex: base.originalSHA1Hex)
        let result = try await pipeline.resolve(local)
        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(superseded(), [head.nodeID])
    }

    func testDerivedCorrespondenceCannotReuseOneReplacementFile() async throws {
        let head = try seed("head")
        _ = try seed("old-adjustment-one", filename: "Adjustments.AAE", main: head)
        _ = try seed("old-adjustment-two", filename: "Adjustments.AAE", main: head)
        let replacement = try await uploadAfterResolving("next")
        let derived = try seed("new-adjustment", filename: "Adjustments.AAE", main: replacement)
        let secondary = UploadResourceDescriptor(
            source: .init(
                kind: .photoLibraryAsset, identifier: source.identifier,
                resource: .photoKit(role: "adjustmentData", ordinal: 0)),
            fileURL: directory.appendingPathComponent("unused"), filename: "Adjustments.AAE", fileSize: 14,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
            precomputedSHA1Digest: Data(Insecure.SHA1.hash(data: Data("new-adjustment".utf8))))
        let resolved = try await pipeline.resolve(secondary)
        try await pipeline.recordUploaded(
            secondary, identity: resolved.identity, remoteVolumeID: derived.volumeID, remoteLinkID: derived.nodeID)
        let outcome = try await settle(replacement)
        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(server.links.first { $0.uid == head }?.state, .active)
    }
}
