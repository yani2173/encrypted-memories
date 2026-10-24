import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Records the remote writes of an edit replacement.
final class FakeEditReplacementRemote: EditReplacementRemote, @unchecked Sendable {
    private let lock = NSLock()
    var active: Set<PhotoUID> = []
    var favorites: Set<PhotoUID> = []
    /// The number of trash writes that fail before one succeeds.
    var trashFailures = 0
    private(set) var trashed: [[PhotoUID]] = []
    private(set) var markedFavorite: [[PhotoUID]] = []

    func ownPhotosVolumeID() async throws -> String { "vol" }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { active.intersection(uids) }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { favorites.intersection(uids) }
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        lock.withLock {
            markedFavorite.append(uids)
            favorites.formUnion(uids)
        }
    }

    func trashReplaced(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if trashFailures > 0 {
                trashFailures -= 1
                throw UploadError.backend("trash failed")
            }
            trashed.append(uids)
            active.subtract(uids)
        }
    }

    var trashCalls: [[PhotoUID]] { lock.withLock { trashed } }
    var favoriteCalls: [[PhotoUID]] { lock.withLock { markedFavorite } }
}

final class FakeAlbumCarryOver: SeriesAlbumCarryOver, @unchecked Sendable {
    private let lock = NSLock()
    var memberships: [PhotoUID: [SeriesAlbumReference]] = [:]
    private(set) var added: [(uids: [PhotoUID], albumID: String)] = []

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        lock.withLock { memberships[uid] ?? [] }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        lock.withLock { added.append((uids, albumID)) }
    }

    var addCalls: [(uids: [PhotoUID], albumID: String)] { lock.withLock { added } }
}

/// Answers album reads from a cache that missed a change of another device; only `currentAlbums` reads the server.
final class CachedAlbumCarryOver: SeriesAlbumCarryOver, @unchecked Sendable {
    private let lock = NSLock()
    private let remote: FakeEditReplacementRemote
    var cached: [PhotoUID: [SeriesAlbumReference]] = [:]
    var current: [PhotoUID: [SeriesAlbumReference]] = [:]
    private(set) var added: [(uids: [PhotoUID], albumID: String, trashCallsBefore: Int)] = []

    init(remote: FakeEditReplacementRemote) {
        self.remote = remote
    }

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        lock.withLock { cached[uid] ?? [] }
    }

    func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        lock.withLock { Dictionary(uniqueKeysWithValues: uids.map { ($0, current[$0] ?? []) }) }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        let trashCalls = remote.trashCalls.count
        lock.withLock { added.append((uids, albumID, trashCalls)) }
    }

    var addCalls: [(uids: [PhotoUID], albumID: String, trashCallsBefore: Int)] { lock.withLock { added } }
}

final class EditReplacementTests: XCTestCase {
    private var directory: URL!
    private var journal: EditReplacementJournalFileStore!
    private var store: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!

    private let asset = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-replacement-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        store = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker, replacementJournal: journal)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func digest(_ seed: String) -> Data {
        var digest = Data(repeating: 0, count: 20)
        for (index, byte) in seed.utf8.enumerated() { digest[index % 20] ^= byte }
        return digest
    }

    private func contentHash(_ seed: String) -> String {
        "ch(\(UploadContentSHA1.hexString(digest: digest(seed))))"
    }

    private func descriptor(
        _ source: UploadSourceIdentity,
        filename: String,
        bytes: String,
        mainRemoteLinkID: String? = nil,
        requiresRelatedMatch: Bool = false
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: URL(fileURLWithPath: "/export/\(filename)"),
            filename: filename,
            fileSize: 10,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            precomputedSHA1Digest: digest(bytes),
            mainRemoteLinkID: mainRemoteLinkID,
            requiresRelatedMatch: requiresRelatedMatch
        )
    }

    private func upload(_ descriptor: UploadResourceDescriptor, as linkID: String) async throws {
        let result = try await pipeline.resolve(descriptor)
        XCTAssertEqual(result.decision, .upload)
        try await pipeline.recordUploaded(
            descriptor, identity: result.identity, remoteVolumeID: "vol", remoteLinkID: linkID)
    }

    // MARK: - Journal

    func testATrashedCachedMainNeverBecomesAReplacementTarget() async throws {
        try await upload(descriptor(asset, filename: "IMG.HEIC", bytes: "original"), as: "old")
        var saved = try XCTUnwrap(store.record(for: asset))
        saved.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        XCTAssertTrue(store.upsert(saved))
        let edited = descriptor(asset, filename: "IMG.JPG", bytes: "edited")
        let result = try await pipeline.resolve(edited)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
        XCTAssertNil(journal.entry(for: asset).backUpAgainRevision)
        if result.decision.uploadsBytes { await pipeline.uploadDidFail(edited) }
    }

    func testAnEditedPhotoKeepsItsEarlierUploadInTheJournalEvenWhenTheCheckFails() async throws {
        try await upload(descriptor(asset, filename: "IMG_1.HEIC", bytes: "original"), as: "old")

        checker.findError = UploadError.transport(code: NSURLErrorTimedOut, message: "offline")
        do {
            _ = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))
            XCTFail("the offline duplicate check must fail")
        } catch {}

        XCTAssertNil(store.record(for: asset)?.remoteLinkID, "the manifest record now describes the edited bytes")
        XCTAssertEqual(
            EditReplacementJournalFileStore(accountDataDirectory: directory)?.entry(for: asset).superseded,
            [PhotoUID(volumeID: "vol", nodeID: "old")],
            "the earlier photo must survive on disk before the manifest forgets it")
    }

    func testAnUnchangedPhotoWritesNoJournal() async throws {
        let original = descriptor(asset, filename: "IMG_1.HEIC", bytes: "original")
        try await upload(original, as: "old")

        let again = try await pipeline.resolve(original)

        XCTAssertEqual(again.decision, .skip(.knownFromManifest, remoteLinkID: "old"))
        XCTAssertTrue(journal.entry(for: asset).isEmpty)
    }

    func testOnlyPhotoLibraryPhotosWithAProvenEarlierUploadAreReplaced() async throws {
        // Uploaded by another client: the duplicate check proved that photo is this one, so it is replaced too.
        let adopted = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-adopted")
        let before = descriptor(adopted, filename: "IMG_2.HEIC", bytes: "theirs")
        checker.remoteItemsByNameHash["nh(IMG_2.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_2.HEIC)", contentHash: contentHash("theirs"), linkState: .active, linkID: "theirs")
        ]
        _ = try await pipeline.resolve(before)
        _ = try await pipeline.resolve(descriptor(adopted, filename: "IMG_2.JPG", bytes: "edited"))
        XCTAssertEqual(journal.entry(for: adopted).superseded, [PhotoUID(volumeID: "", nodeID: "theirs")])

        // A trashed duplicate proves nothing that is still visible.
        let trashed = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-trashed")
        checker.remoteItemsByNameHash["nh(IMG_4.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_4.HEIC)", contentHash: contentHash("gone"), linkState: .trashed, linkID: "gone")
        ]
        _ = try await pipeline.resolve(descriptor(trashed, filename: "IMG_4.HEIC", bytes: "gone"))
        _ = try await pipeline.resolve(descriptor(trashed, filename: "IMG_4.JPG", bytes: "gone-edited"))
        XCTAssertTrue(journal.entry(for: trashed).isEmpty)

        // A file of a watched folder has no photo-library edit.
        let file = UploadSourceIdentity.file(URL(fileURLWithPath: "/folder/IMG_3.HEIC"))
        try await upload(descriptor(file, filename: "IMG_3.HEIC", bytes: "first"), as: "file-old")
        _ = try await pipeline.resolve(descriptor(file, filename: "IMG_3.HEIC", bytes: "second"))
        XCTAssertTrue(journal.entry(for: file).isEmpty)
    }

    func testTheJournalRetiresTrashedPhotosWithTheirRelatedPhotosAndSurvivesARelaunch() throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: asset)

        try journal.settle(["a"], related: ["a-video"], trashed: true, for: asset)
        try journal.settle(["b"], related: [], trashed: false, for: asset)

        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(
            reopened.entry(for: asset), EditReplacementJournalEntry(superseded: [], retired: ["a", "a-video"]))
    }

    func testTheReplacementHistoryNamesProvenMainsNewestFirstAndSurvivesARelaunch() throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "z-old"), for: asset)
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a-new"), for: asset)
        try journal.addProven("z-old", inherited: [], for: asset)
        try journal.addProven("a-new", inherited: ["ancestor"], for: asset)
        try journal.settle(["z-old", "a-new"], related: ["b-video"], trashed: true, for: asset)
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "edit"), for: asset)
        try journal.addProven("edit", inherited: [], for: asset)

        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).retired, ["z-old", "a-new", "b-video"])
        XCTAssertEqual(
            reopened.entry(for: asset).replacementHistory(excluding: []),
            [["edit"], ["a-new"], ["ancestor"], ["z-old"]],
            "newest first, with what a remote photo replaced, and without related files")

        try reopened.settle(["edit"], related: [], trashed: false, for: asset)
        XCTAssertEqual(reopened.entry(for: asset).replacementHistory(excluding: []), [], "a kept link names nothing")
        XCTAssertFalse(reopened.entry(for: asset).proven?.contains("edit") == true)
    }

    func testAJournalFromAnEarlierBuildDecodesWithoutARetireIntent() throws {
        let encoded = Data(
            #"{"photoLibraryAsset|asset-1|primary":{"superseded":[],"retired":["old"],"uploadedEdit":true}}"#.utf8)
        try encoded.write(to: directory.appendingPathComponent(EditReplacementJournalFileStore.fileName))

        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).retired, ["old"])
        XCTAssertNil(reopened.entry(for: asset).retireIntent)
        XCTAssertTrue(reopened.entry(for: asset).lastUploadWasEdit)
    }

    private var logURL: URL { directory.appendingPathComponent(EditReplacementJournalFileStore.logFileName) }

    func testAChangeAppendsOneLineInsteadOfWritingEveryEntry() throws {
        for index in 0..<200 {
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-\(index)")
            try journal.recordUpload(edited: true, for: source)
        }
        let before = try Data(contentsOf: logURL).count

        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)

        let grown = try Data(contentsOf: logURL).count - before
        XCTAssertLessThan(grown, 300, "one change writes one line, not the 200 other entries")
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).superseded.map(\.nodeID), ["old"])
        XCTAssertTrue(
            reopened.entry(for: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-199"))
                .lastUploadWasEdit)
    }

    func testTheLogIsRewrittenWhenItHoldsManyMoreLinesThanEntries() throws {
        for round in 0..<1_500 {
            try journal.recordUpload(edited: round % 2 == 0, for: asset)
            try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old-\(round)"), for: asset)
            try journal.settle(["old-\(round)"], related: [], trashed: false, for: asset)
        }
        let lines = try String(decoding: Data(contentsOf: logURL), as: UTF8.self).split(separator: "\n")

        XCTAssertLessThanOrEqual(lines.count, 1_001, "the log stays bounded")
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset), journal.entry(for: asset))
    }

    func testALineCutOffByAStopIsDroppedAndTheLogStaysUsable() throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "kept"), for: asset)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"key":"photoLibraryAsset|asset-1|primary","ent"#.utf8))
        try handle.close()

        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).superseded.map(\.nodeID), ["kept"])
        try reopened.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "next"), for: asset)
        let again = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(again.entry(for: asset).superseded.map(\.nodeID), ["kept", "next"])
    }

    func testAnEarlierBuildCannotReadTheJournalOnceTheLogHoldsIt() throws {
        let earlierURL = directory.appendingPathComponent(EditReplacementJournalFileStore.fileName)
        try Data(#"{"photoLibraryAsset|asset-1|primary":{"superseded":[],"retired":["old"]}}"#.utf8)
            .write(to: earlierURL)

        let migrated = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(migrated.entry(for: asset).retired, ["old"])
        let barrier = try Data(contentsOf: earlierURL)
        XCTAssertNil(
            try? JSONDecoder().decode([String: EditReplacementJournalEntry].self, from: barrier),
            "an earlier build finds no journal it can read, so it keeps earlier uploads")
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).retired, ["old"], "the log, not the barrier, holds the journal")
    }

    func testTheFirstLineOfANewJournalBlocksEarlierBuildsAsWell() throws {
        let earlierURL = directory.appendingPathComponent(EditReplacementJournalFileStore.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlierURL.path))

        try journal.recordUpload(edited: true, for: asset)

        XCTAssertEqual(try Data(contentsOf: earlierURL), EditReplacementJournalFileStore.earlierBuildBarrier)
    }

    func testTheAppOpensOneJournalForEachDirectory() throws {
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let first = try XCTUnwrap(EditReplacementJournalFileStore.shared(accountDataDirectory: other))
        let second = try XCTUnwrap(EditReplacementJournalFileStore.shared(accountDataDirectory: other))

        XCTAssertTrue(first === second, "two stores of one log would write over each other's lines")
        try first.recordUpload(edited: true, for: asset)
        XCTAssertTrue(second.entry(for: asset).lastUploadWasEdit)
    }

    func testADamagedLineInsideTheLogDisablesReplacement() throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)
        let valid = try Data(contentsOf: logURL)
        try (Data("not json\n".utf8) + valid).write(to: logURL)

        XCTAssertNil(EditReplacementJournalFileStore(accountDataDirectory: directory))
    }

    func testAnUnreadableJournalDisablesReplacementInsteadOfForgettingWaitingPhotos() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent(EditReplacementJournalFileStore.fileName))

        XCTAssertNil(EditReplacementJournalFileStore(accountDataDirectory: directory))
    }

    func testRetiredLinksHaveNoLimitSoAnUndoAfterManyEditsStillUploads() throws {
        for edit in 0..<100 {
            try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "edit-\(edit)"), for: asset)
            try journal.settle(["edit-\(edit)"], related: ["edit-\(edit)-original"], trashed: true, for: asset)
        }

        XCTAssertEqual(journal.entry(for: asset).retired.count, 200)
        XCTAssertTrue(journal.entry(for: asset).retired.contains("edit-0-original"))
    }

    // MARK: - Dedupe rules

    func testASecondaryOfAReplacingEditIgnoresItsCopyUnderTheEarlierPhoto() async throws {
        let original = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: "asset-1", resource: .photoKit(role: "originalPhoto", ordinal: 0))
        try await upload(descriptor(original, filename: "IMG_1.HEIC", bytes: "original"), as: "original-old")

        let strict = try await pipeline.resolve(
            descriptor(
                original, filename: "IMG_1.HEIC", bytes: "original", mainRemoteLinkID: "edited-new",
                requiresRelatedMatch: true))
        XCTAssertEqual(strict.decision, .upload, "the earlier copy moves to the trash with the earlier photo")
        await pipeline.uploadDidFail(descriptor(original, filename: "IMG_1.HEIC", bytes: "original"))

        checker.relatedLinkIDsByMainLinkID["edited-new"] = ["original-new"]
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash("original"), linkState: .active,
                linkID: "original-new")
        ]
        await pipeline.invalidateCachedRemoteState()
        let retried = try await pipeline.resolve(
            descriptor(
                original, filename: "IMG_1.HEIC", bytes: "original", mainRemoteLinkID: "edited-new",
                requiresRelatedMatch: true))
        XCTAssertEqual(
            retried.decision, .skip(.activeDuplicate, remoteLinkID: "original-new"),
            "a copy under the edited photo settles the secondary, so a retry uploads nothing twice")
    }

    func testUndoingAnEditUploadsTheOriginalAgainInsteadOfAdoptingAHiddenOrTrashedCopy() async throws {
        // State after one completed replacement: the original "old" is trashed (retired); the edited photo
        // "edited" is the current upload and carries the original as its hidden related photo "hidden".
        try await upload(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"), as: "edited")
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        let hiddenSource = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: "asset-1", resource: .photoKit(role: "originalPhoto", ordinal: 0))
        store.upsert(
            UploadIdentityRecord(
                source: hiddenSource, filename: "IMG_1.HEIC", correctedName: "IMG_1.HEIC", fileSize: 10,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                sha1Hex: UploadContentSHA1.hexString(digest: digest("original")), nameHash: "nh(IMG_1.HEIC)",
                contentHash: contentHash("original"), hashKeyEpoch: checker.epoch, remoteVolumeID: "vol",
                remoteLinkID: "hidden", outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue,
                updatedAt: Date()))
        checker.relatedLinkIDsByMainLinkID["edited"] = ["hidden"]
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash("original"), linkState: .trashed, linkID: "old"),
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash("original"), linkState: .active, linkID: "hidden"),
        ]

        let reverted = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.HEIC", bytes: "original"))

        XCTAssertEqual(reverted.decision, .upload, "the original shows as a photo again")
        XCTAssertEqual(journal.entry(for: asset).superseded, [PhotoUID(volumeID: "vol", nodeID: "edited")])
    }

    func testAPhotoThePersonTrashedStaysTrashed() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"), linkState: .trashed,
                linkID: "deleted-by-person")
        ]

        let result = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "deleted-by-person"))
    }

    func testOmittedReplacementVisibilityNeverManufacturesAKnownDeletion() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        let hash = contentHash("rotated")
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            .init(nameHash: "nh(IMG_1.JPG)", contentHash: hash, linkState: .active, linkID: "unknown")
        ]
        // Same content exists under another name; neither listing proves this link's trash state.
        checker.remoteItemsByContentHash[hash] = .init(
            nameHash: "nh(Another.JPG)", contentHash: hash, linkState: .active, linkID: "cross-name")
        checker.linkVisibilityByID["unknown"] = .some(nil)
        checker.linkVisibilityByID["cross-name"] = .some(nil)
        let d = descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated")
        let result = try await pipeline.resolve(d)
        XCTAssertEqual(result.decision, .skip(.inconsistentRemoteState, remoteLinkID: "unknown"))
        XCTAssertNotEqual(store.record(for: asset)?.outcome, "duplicateTrashed")
        checker.remoteItemsByNameHash = [:]
        checker.remoteItemsByContentHash = [:]
        await pipeline.invalidateCachedRemoteState()
        let retried = try await pipeline.resolve(d)
        XCTAssertEqual(retried.decision, .awaitDeletionCheck, "absence cannot retain a fabricated deletion")
    }

    func testReplacementVisibilityWithoutExplicitStateCannotProveAnActiveCopy() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            .init(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"),
                linkState: .active, linkID: "unproven")
        ]
        checker.linkVisibilityByID["unproven"] = .init(
            isActive: true, mainPhotoLinkID: nil, hasExplicitPhotoState: false)
        let result = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))
        XCTAssertEqual(result.decision, .skip(.inconsistentRemoteState, remoteLinkID: "unproven"))
        XCTAssertFalse(try XCTUnwrap(store.record(for: asset)).provesUpload)
    }

    func testReplacementVisibilityWithoutExplicitStateCannotMakeAMainLinkedCopyRelated() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            .init(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"),
                linkState: .active, linkID: "unproven")
        ]
        // The decoded metadata answer without State that still carries Photo role data with a main photo.
        checker.linkVisibilityByID["unproven"] = .init(
            isActive: true, mainPhotoLinkID: "some-main", hasExplicitPhotoState: false)
        let d = descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated")

        let unasked = try await pipeline.resolve(d)

        XCTAssertEqual(
            unasked.decision, .skip(.inconsistentRemoteState, remoteLinkID: "unproven"),
            "a role without a state proves no related file, so the unknown copy is no deletion question")

        // Consent for exactly this version must not upload past an unknown copy either.
        try journal.backUpAgain(
            revision: UploadBackupRevision(date: Date(timeIntervalSince1970: 1_700_000_000)), for: asset)
        let journalBefore = journal.entry(for: asset)
        await pipeline.invalidateCachedRemoteState()

        let consented = try await pipeline.resolve(d)

        XCTAssertEqual(consented.decision, .skip(.inconsistentRemoteState, remoteLinkID: "unproven"))
        XCTAssertFalse(consented.decision.uploadsBytes, "the unknown copy blocks a second upload")
        XCTAssertNotEqual(store.record(for: asset)?.outcome, "duplicateTrashed", "no deletion is claimed")
        XCTAssertFalse(store.record(for: asset)?.provesUpload ?? false)
        XCTAssertEqual(journal.entry(for: asset), journalBefore, "the journal settles and consumes nothing")
        let resolver = try XCTUnwrap(pipeline)
        let finished = expectation(description: "a second resolve obtains the released claims")
        let retry = Task {
            let result = try await resolver.resolve(d)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finished], timeout: 2)
        await resolver.uploadDidFail(d)  // Unblock a broken implementation after the assertion.
        let retried = try await retry.value
        XCTAssertEqual(retried.decision, .skip(.inconsistentRemoteState, remoteLinkID: "unproven"))
    }

    func testReplacementVisibilityWithAnExplicitStateKeepsRelatedFilesAndLiveMainPhotos() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        let d = descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated")
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            .init(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"),
                linkState: .active, linkID: "related")
        ]
        checker.linkVisibilityByID["related"] = .init(isActive: true, mainPhotoLinkID: "some-main")

        let related = try await pipeline.resolve(d)

        XCTAssertEqual(
            related.decision, .awaitDeletionCheck,
            "an active related file of another photo is no backup, so the deletion question stays")

        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            .init(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"),
                linkState: .active, linkID: "live")
        ]
        checker.linkVisibilityByID["live"] = .init(isActive: true, mainPhotoLinkID: nil)
        await pipeline.invalidateCachedRemoteState()

        let live = try await pipeline.resolve(d)

        XCTAssertEqual(live.decision, .skip(.activeDuplicate, remoteLinkID: "live"))
        XCTAssertTrue(try XCTUnwrap(store.record(for: asset)).provesUpload)
    }

    func testInactiveVisibilityWithoutATrashStateDoesNotInventDeletion() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"), linkState: .active,
                linkID: "trashed-since")
        ]
        // Inactive visibility alone distinguishes neither trash, draft nor permanent deletion.
        checker.linkVisibilityByID["trashed-since"] = RemoteLinkVisibility(isActive: false, mainPhotoLinkID: nil)

        let result = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))

        XCTAssertEqual(
            result.decision, .skip(.inconsistentRemoteState, remoteLinkID: "trashed-since"),
            "unknown state blocks upload without manufacturing a deletion")
    }

    // MARK: - Replacement

    func testTheReplacementCarriesFavoriteAndAlbumsOverBeforeItTrashesTheEarlierPhoto() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        let new = PhotoUID(volumeID: "vol", nodeID: "new")
        try supersedeOwnUpload(old)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        remote.favorites = [old]
        let albums = FakeAlbumCarryOver()
        albums.memberships[old] = [
            SeriesAlbumReference(volumeID: "vol", albumID: "own-album"),
            SeriesAlbumReference(volumeID: "shared-vol", albumID: "shared-album"),
        ]
        checker.relatedLinkIDsByMainLinkID["old"] = ["old-video"]
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: albums, relations: checker, identities: store, journal: journal)

        try await replacement.replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertEqual(remote.favoriteCalls, [[new]])
        XCTAssertEqual(albums.addCalls.map(\.albumID), ["own-album"], "a shared album is never a write target")
        XCTAssertEqual(albums.addCalls.first?.uids, [new])
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(
            journal.entry(for: asset),
            EditReplacementJournalEntry(
                superseded: [], retired: ["old", "old-video"], uploadedEdit: true, proven: ["old"]))
    }

    func testTheReplacementReadsTheAlbumsOfTheEarlierPhotoFreshBeforeTheTrash() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        let new = PhotoUID(volumeID: "vol", nodeID: "new")
        try supersedeOwnUpload(old)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        // Another device added the earlier photo to a second album after this device cached its albums.
        let albums = CachedAlbumCarryOver(remote: remote)
        albums.cached[old] = [SeriesAlbumReference(volumeID: "vol", albumID: "album-1")]
        albums.current[old] = [
            SeriesAlbumReference(volumeID: "vol", albumID: "album-1"),
            SeriesAlbumReference(volumeID: "vol", albumID: "album-2"),
        ]
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: albums, relations: checker, identities: store, journal: journal)

        try await replacement.replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertEqual(albums.addCalls.map(\.albumID).sorted(), ["album-1", "album-2"])
        XCTAssertTrue(albums.addCalls.allSatisfy { $0.uids == [new] && $0.trashCallsBefore == 0 })
        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testTheReplacementNeverTrashesThePhotoThatCarriesTheNewOne() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try supersedeOwnUpload(old)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]
        checker.relatedLinkIDsByMainLinkID["old"] = ["new"]
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: FakeAlbumCarryOver(), relations: checker, identities: store, journal: journal)

        try await replacement.replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertTrue(remote.trashCalls.isEmpty, "the trash takes related photos along")
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
    }

    private func makeReplacement(_ remote: FakeEditReplacementRemote) -> EditedPhotoReplacement {
        EditedPhotoReplacement(
            remote: remote, albums: FakeAlbumCarryOver(), relations: checker, identities: store, journal: journal)
    }

    func testAnEarlierPhotoThatAnotherLibraryAssetNeedsStays() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try supersedeOwnUpload(old)
        // A duplicate in Photos proved its backup through the same photo.
        try await upload(
            descriptor(
                UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-duplicate"), filename: "IMG_9.HEIC",
                bytes: "shared"), as: "old")
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]

        try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertTrue(remote.trashCalls.isEmpty)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
    }

    func testAnEarlierPhotoStaysWhenTheNewCompoundDoesNotHoldTheOriginal() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try supersedeOwnUpload(old)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: false)

        XCTAssertEqual(outcome, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the earlier photo may be the only copy of the original")
        XCTAssertEqual(
            journal.entry(for: asset).superseded, [old], "an upload that holds the original replaces it later")
    }

    func testOnlyAnUneditedPrimaryOrAnOriginalSecondaryHoldsTheOriginal() {
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .revision(UploadBackupRevision(rawValue: 1)), secondaries: []))
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .unavailable, secondaries: [.photoKit(role: "originalPhoto", ordinal: 0)]))
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .unavailable, secondaries: [.photoKit(role: "originalVideo", ordinal: 0)]))
        XCTAssertFalse(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .unavailable,
                secondaries: [.livePairedVideo, .photoKit(role: "adjustmentData", ordinal: 0)]))
    }

    /// A manifest row of `asset` that names `linkID`, as the backup writes it after an upload.
    private func row(_ resource: UploadSourceIdentity.Resource, at linkID: String) -> UploadSourceIdentity {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: asset.identifier, resource: resource)
        store.upsert(
            UploadIdentityRecord(
                source: source, filename: linkID, correctedName: linkID, fileSize: 1, modificationDate: .distantPast,
                sha1Hex: linkID, nameHash: "nh(\(linkID))", contentHash: "ch(\(linkID))", hashKeyEpoch: "epoch",
                remoteVolumeID: "vol", remoteLinkID: linkID,
                outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: .distantPast))
        return source
    }

    /// The journal entry that an edit writes for an earlier upload of this photo: a target that proves itself.
    private func supersedeOwnUpload(_ uid: PhotoUID) throws {
        try journal.addSuperseded(uid, for: asset)
        try journal.addProven(uid.nodeID, inherited: [], for: asset)
    }

    private func supersede(_ nodeID: String, related: Set<String> = []) -> (PhotoUID, FakeEditReplacementRemote) {
        let old = PhotoUID(volumeID: "vol", nodeID: nodeID)
        try? supersedeOwnUpload(old)
        checker.relatedLinkIDsByMainLinkID[nodeID] = related
        let remote = FakeEditReplacementRemote()
        // The photo that replaces the earlier one is in the library, like the upload that just finished.
        remote.active = [old, new]
        return (old, remote)
    }

    private let new = PhotoUID(volumeID: "vol", nodeID: "new")

    private func compound(_ main: String, related: [String: String]) -> UploadRemoteCompound {
        func file(_ linkID: String, _ content: String) -> UploadRemoteCompound.File {
            .init(linkID: linkID, contentHash: "ch(\(content))", nameHash: "nh(\(linkID))", mimeType: "image/jpeg")
        }
        return UploadRemoteCompound(
            main: file(main, main), related: related.sorted { $0.key < $1.key }.map { file($0.key, $0.value) },
            tags: [], externalIdentifier: nil, captureDate: nil, modificationDate: nil)
    }

    func testAnUnprovenEarlierPhotoStaysWhenOneOfItsFilesHasNoTwinUnderTheNewPhoto() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        checker.compoundsByMainLinkID["old"] = compound(
            "old", related: ["old-video": "video", "old-adjustments": "older-adjustments"])
        checker.compoundsByMainLinkID["new"] = compound(
            "new", related: ["new-original": "old", "new-video": "video"])

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the trash would take the only copy of the adjustments along")
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
        XCTAssertTrue(checker.relatedLookups.isEmpty, "the compound names the related files")

        // With a twin of each file the trash loses nothing, so the photo leaves.
        try journal.addSuperseded(old, for: asset)
        checker.compoundsByMainLinkID["old"] = compound("old", related: ["old-video": "video"])
        let replaced = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(replaced, .replaced(retiredAny: true))
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(Set(journal.entry(for: asset).retired), ["old", "old-video"])
    }

    func testAnUnprovenEarlierEditWithoutRelatedFilesStaysWhenNoFileHoldsItsBytes() async throws {
        // An earlier edit without related files, adopted again after a reinstall: only its main file holds the render.
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        checker.compoundsByMainLinkID["old"] = compound("old", related: [:])
        checker.compoundsByMainLinkID["new"] = compound("new", related: ["new-original": "original"])

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the trash would take the only copy of the earlier edit along")
    }

    func testCancellationInEveryOptionalReplacementReadPreservesTheJournal() async throws {
        for route in ["remote-target", "replacement", "unproven"] {
            for failure in [
                URLError(.cancelled) as any Error, UploadError.cancelled,
                UploadError.transport(code: -999, message: "cancelled"),
            ] {
                let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: UUID().uuidString)
                let old = PhotoUID(volumeID: "vol", nodeID: "old")
                let remote = FakeEditReplacementRemote()
                remote.active = [old, new]
                let relations = FakeChecker()
                if route == "unproven" {
                    try journal.addSuperseded(old, for: source)
                } else {
                    try journal.addRemoteSuperseded(old, for: source)
                }
                let earlier = compound("old", related: [:])
                relations.compoundsByMainLinkID["old"] = .init(
                    main: earlier.main, related: earlier.related, tags: [], externalIdentifier: "cloud",
                    captureDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1))
                relations.externalMainLinks["cloud"] = (links: ["old"], complete: true)
                relations.replacedLinks["old"] = (links: [], complete: true)
                relations.replacingLinks["old"] = (links: [], complete: true)
                relations.compoundErrorsByMainLinkID[route == "replacement" ? "new" : "old"] = [failure]
                let executor = EditedPhotoReplacement(
                    remote: remote, albums: FakeAlbumCarryOver(),
                    relations: relations, identities: store, journal: journal)
                let before = journal.entry(for: source)
                do {
                    _ = try await executor.replaceSuperseded(
                        of: source, with: new, edited: true, holdsOriginal: true,
                        externalIdentifier: "cloud", localEditTime: Date(timeIntervalSince1970: 2),
                        localCreationDate: Date(timeIntervalSince1970: 1), externalIdentifierIsUnique: true)
                    XCTFail("\(route) must propagate cancellation")
                } catch { XCTAssertTrue(UploadError.isCancellation(error)) }
                XCTAssertEqual(journal.entry(for: source), before)
                XCTAssertTrue(remote.trashCalls.isEmpty)
            }
        }
    }

    func testAFailedCompoundReadOfAnUnprovenPhotoRetriesTheReplacementLater() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        checker.compoundsByMainLinkID["old"] = compound("old", related: ["old-video": "video"])
        checker.compoundsByMainLinkID["new"] = compound(
            "new", related: ["new-original": "old", "new-video": "video"])
        checker.compoundErrorsByMainLinkID["old"] = [
            UploadError.transport(code: NSURLErrorTimedOut, message: "offline"),
            UploadError.retryableBackend(code: 503, message: "unavailable"),
        ]

        for _ in 0..<2 {
            do {
                try await makeReplacement(remote).replaceSuperseded(
                    of: asset, with: new, edited: true, holdsOriginal: true)
                XCTFail("a transient failure retries the replacement")
            } catch {}
            XCTAssertEqual(journal.entry(for: asset).superseded, [old], "the earlier photo still waits")
            XCTAssertTrue(remote.trashCalls.isEmpty)
        }

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testAnIncompleteOrFinalCompoundAnswerKeepsAnUnprovenPhoto() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        checker.compoundsByMainLinkID["new"] = compound(
            "new", related: ["new-original": "old", "new-video": "video"])

        // The server state is incomplete: no compound.
        try journal.addSuperseded(old, for: asset)
        let incomplete = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(incomplete, .kept)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)

        // A failure that a retry cannot fix.
        try journal.addSuperseded(old, for: asset)
        checker.compoundErrorsByMainLinkID["old"] = [UploadError.backend("The name cannot be decrypted")]
        let final = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(final, .kept)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
        XCTAssertTrue(remote.trashCalls.isEmpty)
    }

    func testOtherBytesOfAPhotoThatWasNeverEditedReplaceNothing() async throws {
        let (_, remote) = supersede("old")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertTrue(remote.trashCalls.isEmpty, "only an edit or its undo replaces the earlier photo")
        XCTAssertTrue(journal.entry(for: asset).isEmpty)
    }

    func testUndoingAnEditThatTheBackupUploadedReplacesTheEdit() async throws {
        try await makeReplacement(FakeEditReplacementRemote()).replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "edit"), edited: true, holdsOriginal: true)
        XCTAssertTrue(journal.entry(for: asset).lastUploadWasEdit)
        let (old, remote) = supersede("edit")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertFalse(journal.entry(for: asset).lastUploadWasEdit)
    }

    func testAPhotoThatAnEarlierBuildReplacedCountsAsEdited() async throws {
        // Journals of earlier builds have no edit flag, only the retired photos.
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "original"), for: asset)
        try journal.settle(["original"], related: [], trashed: true, for: asset)
        let (old, remote) = supersede("edit")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testAnEarlierPhotoStaysWhileTheLivePhotoVideoLivesOnlyUnderIt() async throws {
        let video = row(.livePairedVideo, at: "old-video")
        let (old, remote) = supersede("old", related: ["old-video"])

        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the edit did not upload the video of the Live Photo again")
        XCTAssertEqual(
            journal.entry(for: asset).superseded, [old], "the earlier photo waits instead of staying for good")

        // The next edit uploads the video again under the new photo.
        _ = row(.livePairedVideo, at: "new-video")
        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(store.record(for: video)?.remoteLinkID, "new-video")
    }

    func testATrashedPairedVideoTwinCannotProveTheOriginalWasCarriedOver() async throws {
        _ = row(.livePairedVideo, at: "old-video")
        let twin = row(.photoKit(role: "pairedVideo", ordinal: 0), at: "trash-video")
        var trashed = try XCTUnwrap(store.record(for: twin))
        trashed.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        XCTAssertTrue(store.upsert(trashed))
        let (old, remote) = supersede("old", related: ["old-video"])
        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(outcome, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty)
        XCTAssertEqual(journal.entry(for: asset).superseded, [old])
    }

    func testAStillPhotoReplacesItsLivePhotoOnceThePairedVideoIsUploadedAsAPlainFile() async throws {
        // The Live Photo backup recorded the video as a Live Photo video. With the Live effect off, the new photo
        // carries the same video again as a plain related file.
        let liveVideo = row(.livePairedVideo, at: "old-video")
        let plainVideo = row(.photoKit(role: "pairedVideo", ordinal: 0), at: "new-video")
        let (old, remote) = supersede("old", related: ["old-video"])

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertNotEqual(store.record(for: liveVideo)?.remoteLinkID, "old-video", "the trashed video proves no backup")
        XCTAssertEqual(store.record(for: plainVideo)?.remoteLinkID, "new-video")
    }

    func testALivePhotoReplacesItsStillOnceThePairedVideoIsUploadedAsALivePhotoVideo() async throws {
        _ = row(.photoKit(role: "pairedVideo", ordinal: 0), at: "old-video")
        _ = row(.livePairedVideo, at: "new-video")
        // Turning the Live effect on again undoes the edit that turned it off.
        try journal.recordUpload(edited: true, for: asset)
        let (old, remote) = supersede("old", related: ["old-video"])

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(outcome, .replaced(retiredAny: true))
        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testAPairedVideoWhoseBothIdentitiesNameTheEarlierPhotoKeepsItWaiting() async throws {
        _ = row(.livePairedVideo, at: "old-video")
        _ = row(.photoKit(role: "pairedVideo", ordinal: 0), at: "old-video")
        let (old, remote) = supersede("old", related: ["old-video"])

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(outcome, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the video lives only under the earlier photo")
        XCTAssertEqual(journal.entry(for: asset).superseded, [old])
    }

    func testAWaitingUndoStillReplacesTheEditOnItsNextAttempt() async throws {
        _ = row(.livePairedVideo, at: "old-video")
        try journal.recordUpload(edited: true, for: asset)
        let (old, remote) = supersede("old", related: ["old-video"])

        let first = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: false, holdsOriginal: true)
        let second = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(first, .waiting)
        XCTAssertEqual(second, .waiting, "the retry still knows that the waiting upload undoes an edit")
        XCTAssertEqual(journal.entry(for: asset).superseded, [old])
        XCTAssertTrue(remote.trashCalls.isEmpty)
    }

    func testEarlierPhotosDoNotWaitForAPhotoThatThePersonTrashed() async throws {
        _ = row(.livePairedVideo, at: "old-video")
        let (old, remote) = supersede("old", related: ["old-video"])
        remote.active = [old]

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(outcome, .replacementGone)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the earlier photo stays")
    }

    func testTheOriginalOfAnEditStaysUntilAnUneditedPrimaryCarriesIt() async throws {
        _ = row(.photoKit(role: "originalPhoto", ordinal: 0), at: "old-original")
        try journal.recordUpload(edited: true, for: asset)
        let (old, remote) = supersede("old", related: ["old-original"])

        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the new edit did not upload the original again")

        // The undo uploads the original itself as the new photo.
        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)
        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testRowsThatNameATrashedPhotoNoLongerProveABackup() async throws {
        let adjustments = row(.photoKit(role: "adjustmentData", ordinal: 0), at: "old-adjustments")
        let (old, remote) = supersede("old", related: ["old-adjustments"])

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)
        XCTAssertTrue(remote.trashCalls.isEmpty)
        XCTAssertEqual(store.record(for: adjustments)?.remoteLinkID, "old-adjustments")

        try journal.recordUpload(edited: true, for: asset)
        try supersedeOwnUpload(old)
        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
        let forgotten = try XCTUnwrap(store.record(for: adjustments))
        XCTAssertNil(forgotten.remoteLinkID, "a trashed photo must not count as the backup of equal bytes")
        XCTAssertNil(forgotten.outcome)
        XCTAssertNil(store.trustedRecord(contentHash: "ch(old-adjustments)", hashKeyEpoch: "epoch"))
    }

    func testARestoredPhotoThatAnotherSourceAdoptedKeepsItsRow() async throws {
        // An earlier edit trashed "restored"; the person restored it, and a duplicate in Photos proved its backup.
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "restored"), for: asset)
        try journal.settle(["restored"], related: [], trashed: true, for: asset)
        try await upload(
            descriptor(
                UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-duplicate"), filename: "IMG_9.HEIC",
                bytes: "restored"), as: "restored")
        let (old, remote) = supersede("old")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(
            store.sources(withRemoteLinkID: "restored")?.map(\.identifier), ["asset-duplicate"],
            "only the rows of the edited photo forget its trashed photos")
    }

    func testARetryAfterAFailedManifestWriteStillForgetsTheTrashedPhotos() async throws {
        let adjustments = row(.photoKit(role: "adjustmentData", ordinal: 0), at: "old-adjustments")
        let (old, remote) = supersede("old", related: ["old-adjustments"])
        store.rejectNextForget()

        do {
            try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: true, holdsOriginal: true)
            XCTFail("the manifest write fails")
        } catch {}
        XCTAssertEqual(remote.trashCalls, [[old]])

        XCTAssertTrue(journal.entry(for: asset).retired.isEmpty)
        XCTAssertEqual(journal.entry(for: asset).retireIntent, ["old": ["old-adjustments"]])
        checker.relatedLinkIDsByMainLinkID["old"] = []
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        let changed = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(changed, .replaced(retiredAny: true), "the cached rows still show the trashed photo")
        XCTAssertEqual(journal.entry(for: asset).retired, ["old", "old-adjustments"])
        XCTAssertNil(journal.entry(for: asset).retireIntent)
        XCTAssertEqual(remote.trashCalls, [[old]], "the trash runs once")
        XCTAssertNil(store.record(for: adjustments)?.remoteLinkID)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
    }

    func testARetryAfterPartialTrashRetiresOnlyTheConfirmedMainAndItsRecordedRelatedFiles() async throws {
        let first = PhotoUID(volumeID: "vol", nodeID: "first")
        let second = PhotoUID(volumeID: "vol", nodeID: "second")
        try supersedeOwnUpload(first)
        try supersedeOwnUpload(second)
        try journal.prepareToRetire(
            ["first": ["first-adjustments"], "second": ["second-video"]], for: asset)
        let adjustments = row(.photoKit(role: "adjustmentData", ordinal: 0), at: "first-adjustments")
        _ = row(.livePairedVideo, at: "second-video")
        checker.relatedLinkIDsByMainLinkID["second"] = ["second-video"]
        let remote = FakeEditReplacementRemote()
        remote.active = [second, new]
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))

        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the remaining main protects the video")
        XCTAssertEqual(journal.entry(for: asset).retired, ["first", "first-adjustments"])
        XCTAssertEqual(journal.entry(for: asset).superseded, [second])
        XCTAssertNil(journal.entry(for: asset).retireIntent)
        XCTAssertNil(store.record(for: adjustments)?.remoteLinkID)

        _ = row(.livePairedVideo, at: "new-video")
        let replaced = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(replaced, .replaced(retiredAny: true))
        XCTAssertEqual(remote.trashCalls, [[second]])
        XCTAssertEqual(
            Set(journal.entry(for: asset).retired), ["first", "first-adjustments", "second", "second-video"])
    }

    func testOnlyPhotoLibraryPhotosRecordTheirEdits() async throws {
        let file = UploadSourceIdentity.file(URL(fileURLWithPath: "/folder/IMG_3.HEIC"))

        try await makeReplacement(FakeEditReplacementRemote()).replaceSuperseded(
            of: file, with: new, edited: true, holdsOriginal: true)

        XCTAssertTrue(journal.entry(for: file).isEmpty)
    }

    func testRelatedPhotosAreJournaledBeforeTheTrashSoACrashCannotLoseThem() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try supersedeOwnUpload(old)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]
        remote.trashFailures = 1
        checker.relatedLinkIDsByMainLinkID["old"] = ["old-video"]

        do {
            try await makeReplacement(remote).replaceSuperseded(
                of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: true)
            XCTFail("the trash write fails")
        } catch {}

        XCTAssertTrue(journal.entry(for: asset).retired.isEmpty, "the failed trash leaves related files active")
        XCTAssertEqual(journal.entry(for: asset).retireIntent, ["old": ["old-video"]])
        XCTAssertEqual(journal.entry(for: asset).superseded, [old], "the earlier photo still waits for its trash")

        // On retry, the earlier main is still active and protects this source's original video.
        _ = row(.livePairedVideo, at: "old-video")
        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertNil(journal.entry(for: asset).retireIntent, "an active target loses the earlier trash intent")
        XCTAssertTrue(journal.entry(for: asset).retired.isEmpty)
        XCTAssertTrue(remote.trashCalls.isEmpty)
    }
}
