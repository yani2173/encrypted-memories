import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// "Keep Only Favorites": journal, crash recovery, the trash ordering, the shared-album refusal and the
/// dedupe collision rule. One shared `FakeSeriesServer` plays Proton for the remote, uploader and checker seams.
final class SeriesDissolutionTests: XCTestCase {
    private var tempDir: URL!
    private var server: FakeSeriesServer!
    private var journalStore: SeriesDissolutionJournalFileStore!
    private var admission: JoinedShutdownGate!

    private let main = PhotoUID(volumeID: "own", nodeID: "m1")
    private var series: [PhotoUID] { ["m1", "m2", "m3", "m4"].map { PhotoUID(volumeID: "own", nodeID: $0) } }
    private func member(_ id: String) -> PhotoUID { PhotoUID(volumeID: "own", nodeID: id) }
    /// The expected node ids of a carry-over target: the series rows that had it plus every standalone copy.
    private func expected(_ sourceNodeIDs: [String], _ copies: [PhotoUID]) -> Set<String> {
        Set(sourceNodeIDs).union(copies.map(\.nodeID))
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-dissolution-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = FakeSeriesServer(ownVolumeID: "own", seriesNodeIDs: ["m1", "m2", "m3", "m4"])
        journalStore = SeriesDissolutionJournalFileStore(accountDataDirectory: tempDir)
        admission = JoinedShutdownGate()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A new orchestrator over the same journal directory and server models the next app launch.
    private func makeOrchestrator() -> SeriesDissolutionOrchestrator {
        SeriesDissolutionOrchestrator(
            remote: server,
            albums: server,
            uploader: server,
            duplicateChecker: server,
            journalStore: journalStore,
            admission: admission,
            tempDirectory: tempDir.appendingPathComponent("work", isDirectory: true),
            currentClientUID: "this-installation"
        )
    }

    // MARK: Happy path

    func testFavoritesBecomeStandalonePhotosBeforeTheWholeSeriesMovesToTrash() async throws {
        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        XCTAssertEqual(server.uploads.map(\.name), ["m2.HEIC", "m4.HEIC"], "the copies keep the original filenames")
        XCTAssertEqual(
            server.reservedAtUpload, [true, true],
            "the person started the dissolution, so its copies may use any network")
        XCTAssertFalse(
            server.uploads.contains { $0.networkReservation?.isActive == true },
            "every copy upload releases its reservation")
        for upload in server.uploads {
            XCTAssertNil(upload.mainPhotoUID, "a kept favorite is a standalone photo, not a related photo")
            XCTAssertEqual(upload.tags, [], "a kept favorite carries no bursts tag")
            XCTAssertNotNil(upload.expectedSHA1, "the original bytes are verified on upload")
        }
        XCTAssertEqual(server.uploads.map(\.captureTime), [server.captureTime(of: "m2"), server.captureTime(of: "m4")])
        XCTAssertEqual(server.uploads.first?.additionalMetadata.map(\.name), ["Camera"])
        XCTAssertEqual(server.trashCalls, [[main]], "the members follow the main photo into the trash")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(try journalStore.pendingJournals(), [], "a finished operation leaves no journal")
        XCTAssertEqual(
            server.events.last, .trash, "every copy is confirmed before the series is touched: \(server.events)")
    }

    // MARK: Crash safety and idempotence

    func testFailureAfterAPartialUploadLeavesTheSeriesUntouchedAndResumesWithoutDuplicates() async throws {
        server.failUploads(named: "m4.HEIC", times: 1)

        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])
            XCTFail("the second favorite fails")
        } catch {}

        XCTAssertTrue(server.trashCalls.isEmpty, "the series must never be trashed before every favorite exists")
        let journal = try XCTUnwrap(try journalStore.journal(forSeries: main))
        XCTAssertEqual(journal.phase, .copyingFavorites)
        XCTAssertEqual(journal.confirmedFavoriteCount, 1, "the confirmed copy is durable across the failure")

        // Next launch: nobody confirmed the operation in this session, so the automatic resume leaves it alone.
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(server.uploads.map(\.name), ["m2.HEIC", "m4.HEIC"])
        XCTAssertTrue(server.trashCalls.isEmpty, "a series the user may have abandoned is never trashed")
        XCTAssertEqual(try journalStore.journal(forSeries: main), journal)

        // The user's Retry continues the journaled operation.
        try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])

        XCTAssertEqual(
            server.uploads.map(\.name), ["m2.HEIC", "m4.HEIC", "m4.HEIC"],
            "the confirmed favorite must not upload again; only the failed one repeats")
        XCTAssertEqual(server.activeCopyUIDs.count, 2)
        XCTAssertEqual(server.trashCalls, [[main]])
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testCrashBetweenRemoteCommitAndJournalWriteAdoptsTheCommittedCopy() async throws {
        // The upload commits on the server, but the process dies before the journal records it.
        server.commitThenFailUploads(named: "m2.HEIC", times: 1)
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("the simulated crash surfaces as an error")
        } catch {}
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.confirmedFavoriteCount, 0)
        XCTAssertTrue(server.trashCalls.isEmpty)

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.uploads.count, 1, "the retry finds the committed copy and uploads nothing")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testCrashDuringTheTrashStepResumesWithoutCopyingAgain() async throws {
        server.failNextTrash()
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
            XCTFail("the trash step fails")
        } catch {}
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
        // The main photo already moved before the failure.
        server.markTrashed(["m1"])

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertEqual(outcomes.map(\.seriesUIDs), [series], "the host learns which series left the library")
        XCTAssertEqual(try outcomes.first?.result.get().copyUIDs.count, 1)
        XCTAssertEqual(server.uploads.count, 1)
        XCTAssertEqual(server.trashCalls, [], "the resumed trash step skips a main photo that is already in the trash")
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testAbandonRemovesACopyingJournalAndKeepsTheConfirmedCopies() async throws {
        server.failUploads(named: "m4.HEIC", times: 1)
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])
            XCTFail("the second favorite fails")
        } catch {}

        // The user answers the failure with Cancel.
        try await makeOrchestrator().abandon(seriesMainUID: main)

        XCTAssertEqual(try journalStore.pendingJournals(), [])
        XCTAssertEqual(server.activeCopyUIDs.count, 1, "the confirmed copy stays as a standalone photo")
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty, "the abandoned series stays in the library")
    }

    func testAbandonKeepsAJournalWhoseTrashStepStarted() async throws {
        server.failNextTrash()
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
            XCTFail("the trash step fails")
        } catch {}

        try await makeOrchestrator().abandon(seriesMainUID: main)

        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
    }

    func testResumeReportsAFailedTrashStepAndKeepsItsJournal() async throws {
        server.failNextTrash()
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
        server.failNextTrash()

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertThrowsError(try outcomes.first?.result.get(), "the host receives the error instead of silence")
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
    }

    func testACopyThatVanishedIsCopiedAgainBeforeTheSeriesIsTrashed() async throws {
        server.failUploads(named: "m3.HEIC", times: 1)
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")])
        let confirmed = try XCTUnwrap(try journalStore.journal(forSeries: main)?.favorites.first?.copyUID)
        server.markTrashed([confirmed.nodeID])  // the user deleted the first copy in the meantime

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")]
        ).copyUIDs

        XCTAssertFalse(copies.contains(confirmed))
        XCTAssertEqual(Set(copies), server.activeCopyUIDs, "both favorites exist as active standalone photos")
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testARetryMayChangeTheSelectionWhileTheSeriesIsUntouched() async throws {
        server.failUploads(named: "m3.HEIC", times: 1)
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        XCTAssertEqual(server.uploads.map(\.name), ["m2.HEIC", "m3.HEIC", "m4.HEIC"], "m2 keeps its confirmed copy")
        XCTAssertEqual(copies.count, 2)
    }

    // MARK: Favorite tag and album carryover

    func testCopiesKeepTheFavoriteTagAndTheOwnAlbumsOfTheSeries() async throws {
        server.markFavoriteNodeIDs(["m1"])  // the user favorited the series; Proton tags its main photo
        server.addAlbum("album-own", volumeID: "own", members: ["m1"])
        server.addAlbum("album-shared", volumeID: "shared-volume", members: ["m1"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        XCTAssertEqual(
            server.favoriteNodeIDs, expected(["m1"], copies), "every copy keeps the favorite state")
        XCTAssertEqual(
            server.albumMembers("album-own"), expected(["m1"], copies), "every copy joins the own album")
        XCTAssertEqual(
            server.albumMembers("album-shared"), ["m1"],
            "a shared album lies in a foreign volume; the operation never writes there")
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testAMemberThatIsFavoritedAloneOnlyTagsItsOwnCopy() async throws {
        server.markFavoriteNodeIDs(["m2"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        let copyOfM2 = try XCTUnwrap(copies.first)
        XCTAssertEqual(server.favoriteNodeIDs, ["m2", copyOfM2.nodeID])
    }

    func testStandaloneCopiesFollowTheirOwnFavoriteTagsAndRelatedCopiesFollowTheMain() async throws {
        server.makeStandalone(["m2", "m3"])
        server.markFavoriteNodeIDs(["m1", "m3"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series,
            favoriteUIDs: [member("m2"), member("m3"), member("m4"), main]
        ).copyUIDs

        guard copies.count == 4 else { return XCTFail("all four copies must exist") }
        XCTAssertEqual(
            server.favoriteNodeIDs, ["m1", "m3", copies[1].nodeID, copies[2].nodeID, copies[3].nodeID])
        XCTAssertFalse(server.favoriteNodeIDs.contains(copies[0].nodeID), "an unmarked single frame stays unmarked")
        XCTAssertTrue(server.favoriteNodeIDs.contains(copies[1].nodeID), "the marked single frame keeps its tag")
        XCTAssertTrue(server.favoriteNodeIDs.contains(copies[2].nodeID), "a related photo follows the main photo")
        XCTAssertTrue(server.favoriteNodeIDs.contains(copies[3].nodeID), "the selected main photo keeps its tag")
        XCTAssertEqual(Array(server.reads.prefix(2)), [.roles, .favorites])
        XCTAssertEqual(server.trashCalls.map { Set($0) }, [[main, member("m2"), member("m3")]])
    }

    func testAnUnknownRoleKeepsTheMainPhotosFavoriteRule() async throws {
        server.makeStandalone(["m2"])
        server.withholdPhotoRole(["m2"])
        server.markFavoriteNodeIDs(["m1"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.favoriteNodeIDs, expected(["m1"], copies))
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testOldJournalKeepsAConfirmedFavoriteWriteButDoesNotAddAnUnconfirmedOne() async throws {
        server.makeStandalone(["m2", "m3"])
        server.markFavoriteNodeIDs(["m1", "old-copy"])
        server.addRemoteRow(name: "m2.HEIC", contentOf: "m2", state: .active, linkID: "old-copy", clientUID: nil)
        server.addRemoteRow(name: "m3.HEIC", contentOf: "m3", state: .active, linkID: "pending-copy", clientUID: nil)
        let oldJournal = SeriesDissolutionJournal(
            seriesMainUID: main, seriesUIDs: series,
            favorites: [
                .init(memberUID: member("m2"), copyUID: member("old-copy"), favoriteTagAdded: true),
                .init(memberUID: member("m3"), copyUID: member("pending-copy"), favoriteTagAdded: false),
            ])
        try journalStore.save(oldJournal)

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")]
        ).copyUIDs

        XCTAssertEqual(copies, [member("old-copy"), member("pending-copy")])
        XCTAssertEqual(
            server.favoriteNodeIDs, ["m1", "old-copy"], "the recorded tag stays; the pending tag is skipped")
        XCTAssertFalse(server.events.contains(.favorite), "the retry does not repeat the confirmed write")
        XCTAssertEqual(server.trashCalls.map { Set($0) }, [[main, member("m2"), member("m3")]])
    }

    func testCopiesJoinCurrentAlbumsInsteadOfCachedMemberships() async throws {
        server.makeStandalone(["m2"])
        server.addAlbum("old", volumeID: "own", members: ["m1", "m2"])
        server.addAlbum("new", volumeID: "own", members: [])
        server.cacheAlbumMemberships()
        server.addAlbum("old", volumeID: "own", members: [])
        server.addAlbum("new", volumeID: "own", members: ["m1", "m2"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        XCTAssertEqual(server.albumMembers("new"), expected(["m1", "m2"], copies))
        XCTAssertEqual(server.albumMembers("old"), [], "the copies must not join the album the photos left")
        XCTAssertEqual(server.freshAlbumReads, [[member("m2"), main]], "one batched fresh read covers both sources")
        XCTAssertTrue(server.cachedAlbumReads.isEmpty)
        XCTAssertEqual(server.trashCalls.map { Set($0) }, [[main, member("m2")]])
    }

    func testAFailedFreshAlbumReadKeepsTheJournalForOneBatchedRetry() async throws {
        server.addAlbum("album", volumeID: "own", members: ["m1"])
        server.failNextAlbumRead()

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])
            XCTFail("the failed fresh read must stop the operation")
        } catch {}

        let journal = try XCTUnwrap(journalStore.journal(forSeries: main))
        XCTAssertEqual(journal.phase, .copyingFavorites)
        XCTAssertEqual(journal.confirmedFavoriteCount, 2)
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertEqual(server.freshAlbumReads, [[main]])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        XCTAssertEqual(server.freshAlbumReads, [[main], [main]], "each attempt makes one batched fresh read")
        XCTAssertTrue(server.cachedAlbumReads.isEmpty)
        XCTAssertEqual(server.uploads.count, 2, "the retry reuses both confirmed copies")
        XCTAssertEqual(server.albumMembers("album"), expected(["m1"], copies))
        XCTAssertEqual(server.trashCalls, [[main]])
        XCTAssertNil(try journalStore.journal(forSeries: main))
    }

    func testTheCopyOfAStandaloneMemberJoinsItsOwnAlbumsAndARelatedPhotoFollowsTheMainPhoto() async throws {
        server.makeStandalone(["m2"])
        server.addAlbum("album-of-m2", volumeID: "own", members: ["m2"])
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])
        server.addAlbum("album-of-m4", volumeID: "own", members: ["m4"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        let copyOfM2 = try XCTUnwrap(copies.first)
        let copyOfM4 = try XCTUnwrap(copies.last)
        XCTAssertEqual(
            server.albumMembers("album-of-m2"), ["m2", copyOfM2.nodeID],
            "a standalone member has albums of its own, and its copy keeps them")
        XCTAssertEqual(
            server.albumMembers("album-of-main"), ["m1", copyOfM4.nodeID],
            "a related photo is in the albums of its main photo, and so is its copy")
        XCTAssertEqual(
            server.albumMembers("album-of-m4"), ["m4"], "a related photo joins no album through its own membership")
        XCTAssertEqual(server.trashCalls.map { Set($0) }, [[main, member("m2")]])
    }

    func testTheCopyOfAStandaloneMemberDoesNotJoinAnAlbumOfTheMainPhoto() async throws {
        server.makeStandalone(["m2", "m3", "m4"])
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])

        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(server.albumMembers("album-of-main"), ["m1"], "m2 was never in the album of the main photo")
        XCTAssertFalse(server.events.contains(.albumAdd))
    }

    func testTheCopyOfARelatedPhotoOfASecondMainPhotoJoinsTheAlbumsOfThatMainPhoto() async throws {
        server.makeStandalone(["m3"])
        server.relate(["m4"], toMain: "m3")
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])
        server.addAlbum("album-of-m3", volumeID: "own", members: ["m3"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m4")]
        ).copyUIDs

        XCTAssertEqual(server.albumMembers("album-of-m3"), expected(["m3"], copies))
        XCTAssertEqual(server.albumMembers("album-of-main"), ["m1"])
    }

    func testTheCopyOfAMemberWithoutARoleJoinsTheAlbumsOfTheSeriesMainPhoto() async throws {
        server.makeStandalone(["m2"])
        server.withholdPhotoRole(["m2"])
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.albumMembers("album-of-main"), expected(["m1"], copies))
    }

    func testACancellationInsideAnAlbumWriteStopsBeforeTheTrash() async throws {
        server.addAlbum("album-own", volumeID: "own", members: ["m1"])
        server.failAlbumWriteWithCancellation(to: "album-own")

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a cancelled album write is no refused album")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .copyingFavorites)
    }

    func testTheCopyOfTheSeriesMainPhotoJoinsItsAlbums() async throws {
        server.makeStandalone(["m2", "m3", "m4"])
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [main]
        ).copyUIDs

        XCTAssertEqual(server.albumMembers("album-of-main"), expected(["m1"], copies))
    }

    func testTheCopyOfAStandaloneMemberSkipsItsSharedAlbums() async throws {
        server.makeStandalone(["m2"])
        server.addAlbum("album-shared", volumeID: "shared-volume", members: ["m2"])

        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(server.albumMembers("album-shared"), ["m2"], "the operation never writes to a foreign volume")
    }

    func testTheCopyOfARelatedPhotoWhoseMainIsOutsideTheSeriesJoinsTheAlbumsOfThatMainPhoto() async throws {
        server.relate(["m2"], toMain: "outside")
        server.addAlbum("album-of-outside", volumeID: "own", members: ["outside"])
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.albumMembers("album-of-outside"), expected(["outside"], copies))
        XCTAssertEqual(server.albumMembers("album-of-main"), ["m1"])
    }

    func testAFailedRoleReadKeepsTheSeries() async throws {
        server.makeStandalone(["m2"])
        server.failNextRoleRead()

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("without the roles the albums of a copy are unknown")
        } catch {}

        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .copyingFavorites)
    }

    func testAFailedAlbumReadKeepsTheSeries() async throws {
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])
        server.failNextAlbumRead()

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("without the album memberships a copy would lose its albums")
        } catch {}

        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .copyingFavorites)
    }

    func testACancelAfterTheLastAlbumWriteStopsBeforeTheTrash() async throws {
        server.addAlbum("album-of-main", volumeID: "own", members: ["m1"])
        server.cancelAfterAlbumWrite(to: "album-of-main")

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a cancelled operation must not finish")
        } catch {}

        XCTAssertTrue(server.trashCalls.isEmpty, "the series stays in the library")
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .copyingFavorites)
    }

    func testAFailedAlbumWriteKeepsTheSeriesAndTheRetryAddsEachCopyOnce() async throws {
        server.addAlbum("album-own", volumeID: "own", members: ["m1"])
        server.failNextAlbumWrite()
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("the album write failed, so the operation must not finish")
        } catch {}
        XCTAssertTrue(server.trashCalls.isEmpty, "the series stays until every copy carries its albums")
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .copyingFavorites)

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.uploads.count, 1, "the confirmed copy is reused instead of uploaded again")
        XCTAssertEqual(server.albumMembers("album-own"), expected(["m1"], copies))
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testAPartialAlbumWriteKeepsTheSeriesAndDoesNotJournalTheBatch() async throws {
        server.addAlbum("album-own", volumeID: "own", members: ["m1"])
        server.failNextAlbumWriteAfterOneAdd()
        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")])
            XCTFail("a partial album write must stop before trash")
        } catch {}
        XCTAssertTrue(server.trashCalls.isEmpty)
        let journal = try XCTUnwrap(journalStore.journal(forSeries: main))
        XCTAssertEqual(journal.phase, .copyingFavorites)
        XCTAssertTrue(journal.favorites.allSatisfy { $0.addedAlbumIDs.isEmpty })
        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")]
        ).copyUIDs
        XCTAssertEqual(server.albumMembers("album-own"), expected(["m1"], copies))
        XCTAssertEqual(server.uploads.count, 2, "the retry reuses both confirmed copies")
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testACancelDuringAnAlbumWriteStopsBeforeTheTrashAndTheRetryAddsEachAlbumOnce() async throws {
        server.addAlbum("album-a", volumeID: "own", members: ["m1"])
        server.addAlbum("album-b", volumeID: "own", members: ["m1"])
        server.cancelDuringAlbumWrite(to: "album-b")

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a cancelled operation must not finish")
        } catch {}
        XCTAssertTrue(server.trashCalls.isEmpty, "a cancel is no refused album: the series stays")
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .copyingFavorites)

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.albumMembers("album-a"), expected(["m1"], copies))
        XCTAssertEqual(server.albumMembers("album-b"), expected(["m1"], copies))
        XCTAssertEqual(
            server.events.filter { $0 == .albumAdd }.count, 2,
            "the journal keeps the confirmed album from a second add")
        XCTAssertEqual(server.trashCalls, [[main]])
    }

    func testTheCarryoverRunsBeforeTheSeriesReachesTheTrash() async throws {
        server.markFavoriteNodeIDs(["m1"])
        server.addAlbum("album-own", volumeID: "own", members: ["m1"])

        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(server.events, [.upload, .favorite, .albumAdd, .trash])
    }

    // MARK: Only the main photo moves to the trash

    func testOnlyTheMainPhotoMovesToTheTrashSoARestoreBringsTheWholeSeriesBack() async throws {
        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")]
        ).copyUIDs

        XCTAssertEqual(server.trashCalls, [[main]], "the frames stay linked to the main photo")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(try journalStore.pendingJournals(), [], "the main photo alone confirms the trash step")
        XCTAssertEqual(server.trashListingNodeIDs, ["m1"], "Recently Deleted lists the series once")
        XCTAssertEqual(
            server.activeRelatedNodeIDs(ofMain: "m1"), [], "the frames leave the library with the main photo")

        // The person restores the series from Recently Deleted.
        server.restoreFromTrash("m1")

        XCTAssertEqual(
            server.activeRelatedNodeIDs(ofMain: "m1"), ["m2", "m3", "m4"], "the series returns with every frame")
    }

    func testATrashStepOfAnEarlierBuildThatTrashedFramesMovesOnlyTheMainPhoto() async throws {
        server.failNextTrash()
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
        // An earlier build trashed every photo of the series and stopped after some frames.
        server.markTrashed(["m2", "m3"])

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertNoThrow(try outcomes.first?.result.get())
        XCTAssertEqual(server.trashCalls, [[main]], "the frames that are still active are never trashed on their own")
        XCTAssertEqual(try journalStore.pendingJournals(), [])
        server.restoreFromTrash("m1")
        XCTAssertEqual(server.activeRelatedNodeIDs(ofMain: "m1"), ["m4"])
    }

    func testASeriesThatOnlyCaptureTimesGroupMovesEveryStandalonePhotoToTheTrash() async throws {
        server.makeStandalone(["m2", "m3", "m4"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.trashCalls.map { $0.map(\.nodeID).sorted() }, [["m1", "m2", "m3", "m4"]])
        XCTAssertEqual(
            server.trashListingNodeIDs, ["m1", "m2", "m3", "m4"], "no photo of the series stays in the library")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testAMixOfReportedRelatedStatelessAndRolelessMembersReportsOnlyTheRolelessOne() async throws {
        server.addRemoteRow(name: "m5.HEIC", contentOf: "m3", state: .active, linkID: "m5", clientUID: nil)
        server.relate(["m3"], toMain: "outside")
        server.omitPhotoState(["m4"])
        server.withholdPhotoRole(["m5"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series + [member("m5")], favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleUIDs, [member("m5")],
            "a role-reported related photo and a stateless member are not reported")
        XCTAssertEqual(outcome.keptWithoutReportedRoleCount, 1)
        XCTAssertEqual(
            server.trashCalls, [[main]],
            "the main photo alone moves to the trash; the unreported members stay untouched")
    }

    func testAChainedSeriesTrashesEachMainPhotoAndNoRelatedPhoto() async throws {
        server.makeStandalone(["m3"])
        server.relate(["m4"], toMain: "m3")

        let progress = ProgressRecorder()
        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")],
            onProgress: { progress.record($0) })

        XCTAssertEqual(server.trashCalls, [[main, member("m3")]])
        XCTAssertTrue(
            progress.stayedWithoutRoleCounts.isEmpty,
            "a related photo of a member that moves to the trash in the same run is not reported")
        XCTAssertTrue(
            outcome.keptWithoutReportedRoleUIDs.isEmpty,
            "a related photo of a trashed main is not kept: it follows its main into the trash")
        server.restoreFromTrash("m1")
        server.restoreFromTrash("m3")
        XCTAssertEqual(server.activeRelatedNodeIDs(ofMain: "m1"), ["m2"])
        XCTAssertEqual(server.activeRelatedNodeIDs(ofMain: "m3"), ["m4"])
    }

    func testAnActiveMemberWithoutARoleStaysInTheLibraryAndTheRestFinishes() async throws {
        server.makeStandalone(["m3"])
        server.withholdPhotoRole(["m3"])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")]
        ).copyUIDs

        XCTAssertEqual(server.trashCalls, [[main]], "a member without role data is no trash target")
        let active = try await server.activeUIDs(among: [member("m3")])
        XCTAssertEqual(active, [member("m3")], "the member stays in the library untouched")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(server.uploads.count, 1)
        XCTAssertEqual(try journalStore.pendingJournals(), [], "the confirmation ignores the member")
    }

    func testAMemberWithoutARoleIsReportedThroughProgressSoThePersonLearnsThatItStays() async throws {
        server.withholdPhotoRole(["m3"])

        let progress = ProgressRecorder()
        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")],
            onProgress: { progress.record($0) })

        XCTAssertEqual(
            progress.stayedWithoutRoleCounts, [1],
            "the person learns before the end that the member without a role stays in the library")
    }

    func testAMemberWithoutARoleThatIsAlreadyTrashedIsNotReported() async throws {
        server.markTrashed(["m3"])
        server.withholdPhotoRole(["m3"])

        let progress = ProgressRecorder()
        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")],
            onProgress: { progress.record($0) })

        XCTAssertTrue(
            progress.stayedWithoutRoleCounts.isEmpty,
            "a member that is already in the trash does not stay in the library")
    }

    func testTheInteractiveCompletionResultCarriesTheCountOfMembersThatStayedWithoutARole() async throws {
        server.withholdPhotoRole(["m3", "m4"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 2,
            "the interactive path reports the members that stay because the server reports no role")
        XCTAssertEqual(
            outcome.keptWithoutReportedRoleUIDs, [member("m3"), member("m4")],
            "the interactive path reports the UIDs of the staying members")
        XCTAssertEqual(outcome.copyUIDs.count, 1, "the standalone copy is still returned")
    }

    func testTheResumedCompletionResultCarriesTheCountOfMembersThatStayedWithoutARole() async throws {
        server.withholdPhotoRole(["m3", "m4"])
        server.failNextTrash()
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        let outcomes = try await makeOrchestrator().resumePending()

        let outcome = try XCTUnwrap(try outcomes.first?.result.get())
        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 2,
            "the resumed trash step reports the members that stay because the server reports no role")
        XCTAssertEqual(
            outcome.keptWithoutReportedRoleUIDs, [member("m3"), member("m4")],
            "the resumed path reports the UIDs of the staying members")
        XCTAssertEqual(outcome.copyUIDs.count, 1, "the standalone copy is still returned")
    }

    func testTheCompletionResultDoesNotReportAMainPhotoMemberWhoseRoleTheServerReported() async throws {
        // A standalone member is a main photo of its own: the server reports its role, so it moves to the
        // trash with the series instead of being counted as a staying member.
        server.makeStandalone(["m3"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 0,
            "a member with a reported main-photo role is trashed, not counted as staying")
        XCTAssertEqual(server.trashCalls, [[main, member("m3")]], "the standalone member is trashed with the series")
    }

    func testTheInteractiveCompletionResultDoesNotReportAMemberWithoutExplicitState() async throws {
        server.omitPhotoState(["m3"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 0,
            "a member whose state the server does not report is not counted: the safe default is no notice")
        XCTAssertEqual(server.trashCalls, [[main]], "the stateless member is never trashed on its own")
    }

    func testTheCompletionResultReportsTheStayingMemberInAMixedSeries() async throws {
        // m2 is a related photo of a main photo outside the series: it keeps its behavior and is not reported.
        // m3 is a related photo of the series main photo: it follows the main photo into the trash. m4 carries
        // an explicit state but no role data: it is the member that #988 reports.
        server.relate(["m2"], toMain: "outside")
        server.withholdPhotoRole(["m4"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleUIDs, [member("m4")],
            "only the member whose role data the server omits is reported")
        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 1,
            "the count is derived from the staying UIDs")
        XCTAssertEqual(server.trashCalls, [[main]], "only the series main photo moves to the trash")
    }

    func testTheCompletionResultReportsZeroWhenEveryMemberHasARole() async throws {
        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 0,
            "no member stays without a role in a fully reported series")
    }

    func testTheCompletionResultReportsZeroWhenTheStayingMemberIsAlreadyTrashed() async throws {
        server.withholdPhotoRole(["m3"])
        server.markTrashed(["m3"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 0,
            "a member that is already in the trash does not stay in the library")
        XCTAssertEqual(server.trashCalls, [[main]], "the already-trashed member is not trashed again")
    }

    func testTheCompletionResultDoesNotReportAMemberWhoseStateTheServerDidNotReport() async throws {
        // The answer names the outside main photo but carries no State. `isActive` keeps its client default
        // (true) for such a link, and that default is not a report from the server.
        server.relate(["m2"], toMain: "outside")
        server.omitPhotoState(["m2"])

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])

        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 0,
            "a member whose state the server did not report is not counted: the safe default is no notice")
        XCTAssertEqual(server.trashCalls, [[main]], "the member is never trashed on an unreported state")
    }

    /// Records the progress events of one operation, safely across sendable closures.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _steps: [SeriesDissolutionProgress] = []

        func record(_ progress: SeriesDissolutionProgress) { lock.withLock { _steps.append(progress) } }

        var steps: [SeriesDissolutionProgress] { lock.withLock { _steps } }

        var stayedWithoutRoleCounts: [Int] {
            steps.compactMap {
                if case .membersStayedWithoutARole(let count) = $0.step { return count }
                return nil
            }
        }
    }

    func testARoleThatIsUnknownInTheTrashStepLeavesTheMemberAndFinishes() async throws {
        server.makeStandalone(["m3"])
        server.failNextTrash()
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
        server.withholdPhotoRole(["m3"])

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertNoThrow(try XCTUnwrap(outcomes.first).result.get())
        XCTAssertEqual(server.trashCalls, [[main]])
        let active = try await server.activeUIDs(among: [member("m3")])
        XCTAssertEqual(active, [member("m3")])
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testAnInactiveMemberWithoutARoleDoesNotBlock() async throws {
        server.markTrashed(["m3"])
        server.withholdPhotoRole(["m3"])

        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(server.trashCalls, [[main]])
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testAResumedTrashStepSendsOnlyThePhotosThatAreStillActive() async throws {
        server.makeStandalone(["m2", "m3", "m4"])
        server.failNextTrash()
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
        // The earlier attempt moved part of the trash set before it stopped.
        server.markTrashed(["m1", "m3"])

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertNoThrow(try XCTUnwrap(outcomes.first).result.get())
        XCTAssertEqual(
            server.trashCalls.map { $0.map(\.nodeID) }, [["m2", "m4"]], "a trashed photo is never sent again")
        XCTAssertEqual(server.trashListingNodeIDs, ["m1", "m2", "m3", "m4"])
    }

    func testAMemberThatIsGoneForGoodIsSkipped() async throws {
        server.makeStandalone(["m4"])
        server.deleteForGood("m4")

        let outcome = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(server.trashCalls, [[main]])
        XCTAssertEqual(try journalStore.pendingJournals(), [])
        XCTAssertEqual(
            outcome.keptWithoutReportedRoleCount, 0,
            "a member that the server no longer knows does not stay in the library")
    }

    // MARK: Server-side membership and the trash confirmation

    func testAMemberThatOnlyTheServerKnowsMovesToTheTrashWithTheSeries() async throws {
        server.addRemoteRow(name: "m5.HEIC", contentOf: "m3", state: .active, linkID: "m5", clientUID: nil)
        server.addServerRelatedNodeIDs(["m1", "m2", "m3", "m4", "m5"])  // m5 arrived after the caller read the series
        server.failNextTrash()

        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        let journal = try XCTUnwrap(try journalStore.journal(forSeries: main))
        XCTAssertEqual(journal.seriesUIDs.map(\.nodeID).sorted(), ["m1", "m2", "m3", "m4", "m5"])
        _ = try await makeOrchestrator().resumePending()
        XCTAssertEqual(server.trashCalls, [[main]])
        server.restoreFromTrash("m1")
        XCTAssertEqual(server.activeRelatedNodeIDs(ofMain: "m1"), ["m2", "m3", "m4", "m5"])
    }

    func testARetryKeepsAMemberThatOnlyTheJournalKnows() async throws {
        server.addRemoteRow(name: "m5.HEIC", contentOf: "m3", state: .active, linkID: "m5", clientUID: nil)
        server.failUploads(named: "m2.HEIC", times: 1)
        let full = series + [member("m5")]
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: full, favoriteUIDs: [member("m2")])

        // The retry passes the shorter list that the timeline still shows.
        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        // m5 has no main photo, so it moves to the trash itself; the frames of m1 follow m1.
        XCTAssertEqual(server.trashCalls.first?.map(\.nodeID).sorted(), ["m1", "m5"])
        XCTAssertEqual(server.trashListingNodeIDs, ["m1", "m5"])
    }

    func testASeriesThatStaysActiveAfterTheTrashRequestKeepsItsJournal() async throws {
        server.acceptNextTrashWithoutEffect()
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("the photos stayed active, so the operation must not report success")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .trashNotConfirmed)
        }
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)

        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNoThrow(try XCTUnwrap(outcomes.first).result.get())
        XCTAssertEqual(server.uploads.count, 1, "the resume never copies again")
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    // MARK: Refusals

    func testSharedAlbumSeriesIsRefusedBeforeAnyRemoteWrite() async throws {
        let foreign = ["s1", "s2"].map { PhotoUID(volumeID: "shared-volume", nodeID: $0) }
        let orchestrator = makeOrchestrator()

        let canDissolve = await orchestrator.canDissolve(seriesUIDs: foreign)
        XCTAssertFalse(canDissolve)
        do {
            try await orchestrator.keepOnlyFavorites(
                seriesMainUID: foreign[0], seriesUIDs: foreign, favoriteUIDs: [foreign[1]])
            XCTFail("a series of a shared album must be refused")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .notOwnLibrary)
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertEqual(try journalStore.pendingJournals(), [], "a refused operation leaves no journal to resume")
    }

    func testSeriesThatMixesAForeignVolumeIsRefused() async throws {
        let mixed = series + [PhotoUID(volumeID: "shared-volume", nodeID: "s1")]
        let canDissolve = await makeOrchestrator().canDissolve(seriesUIDs: mixed)
        XCTAssertFalse(canDissolve)
    }

    func testSelectionOutsideTheSeriesOrEmptyIsRefused() async throws {
        for favorites in [[], [member("not-in-series")]] {
            do {
                try await makeOrchestrator().keepOnlyFavorites(
                    seriesMainUID: main, seriesUIDs: series, favoriteUIDs: favorites)
                XCTFail("invalid selection")
            } catch let error as SeriesDissolutionError {
                XCTAssertEqual(error, .invalidSelection)
            }
        }
        XCTAssertTrue(server.trashCalls.isEmpty)
    }

    // MARK: Temporary volume read failures

    func testAVolumeReadFailureIsATemporaryFailureNotASharedAlbum() async throws {
        // The volume read fails once, then works again: a retry after the reported failure dissolves.
        server.failNextVolumeRead()
        let orchestrator = makeOrchestrator()

        do {
            _ = try await orchestrator.keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("the unreadable own volume must fail the operation")
        } catch SeriesDissolutionError.notOwnLibrary {
            XCTFail("a failing volume read is a temporary failure, not proof of a shared album")
        } catch let error as UploadError {
            guard case UploadError.retryableBackend(503, "volume read unavailable") = error else {
                return XCTFail("expected the injected volume read failure, got \(error)")
            }
        }
        XCTAssertTrue(server.uploads.isEmpty, "no photo is copied before the own volume is known")
        XCTAssertTrue(server.trashCalls.isEmpty, "no photo moves to the trash before the own volume is known")
        XCTAssertEqual(
            try journalStore.pendingJournals(), [], "an unreadable own volume leaves no journal behind")

        _ = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
        XCTAssertEqual(server.uploads.count, 1, "the retry reads the volume again and dissolves")
        XCTAssertEqual(server.trashCalls.count, 1)
    }

    func testAVolumeReadFailureDoesNotHideKeepOnlyFavorites() async throws {
        server.failNextVolumeRead()

        let canDissolve = await makeOrchestrator().canDissolve(seriesUIDs: series)

        XCTAssertTrue(
            canDissolve,
            "an unreadable own volume is no proof of a shared album, so the option stays available")
    }

    func testALastingVolumeReadFailureNeverDissolvesTheSeries() async throws {
        server.failNextVolumeRead(times: 100)

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a lasting read failure must never report success")
        } catch SeriesDissolutionError.notOwnLibrary {
            XCTFail("a failing volume read is a temporary failure, not proof of a shared album")
        } catch let error as UploadError {
            guard case UploadError.retryableBackend(503, "volume read unavailable") = error else {
                return XCTFail("expected the injected volume read failure, got \(error)")
            }
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
    }

    func testAClosedSessionStillAnswersCanDissolveWithFalse() async throws {
        admission.closeAdmission()

        let canDissolve = await makeOrchestrator().canDissolve(seriesUIDs: series)

        XCTAssertFalse(canDissolve, "a closed session must not offer the option")
    }

    func testAnEmptySeriesStaysRefusedAsNotOwnLibrary() async throws {
        let canDissolve = await makeOrchestrator().canDissolve(seriesUIDs: [])
        XCTAssertFalse(canDissolve)

        do {
            _ = try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: [], favoriteUIDs: [])
            XCTFail("an empty series must be refused")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .notOwnLibrary)
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
    }

    // MARK: Dedupe collision rule

    func testSeriesMemberRowsNeverCountAsAnExistingCopy() {
        // The favorite's own member row has the same name and content. The standard dedupe would link to it.
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [.init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "m2")],
            sourceLinkID: "m2", compoundLinkIDs: ["m1", "m2"], currentClientUID: "me")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    func testTheMembersOwnRowIsIgnoredEvenWhenTheMembershipIsStale() {
        // The journal lost this member from its list, so `compoundLinkIDs` does not name it. Adopting its own
        // row would link the favorite to the photo that the trash step removes.
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [.init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "m2")],
            sourceLinkID: "m2", compoundLinkIDs: ["m1"], currentClientUID: "me")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    func testActiveStandalonePhotoWithTheSameNameAndContentIsAdopted() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "m2"),
                .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "standalone"),
            ],
            sourceLinkID: "m2", compoundLinkIDs: ["m1", "m2"], currentClientUID: "me")
        XCTAssertEqual(decision, .adopt(remoteLinkID: "standalone"))
    }

    func testOwnDraftIsReplacedAndAForeignDraftBlocks() {
        func decide(clientUID: String?) -> RelatedPhotoCopyPolicy.Decision {
            RelatedPhotoCopyPolicy.decide(
                nameHash: "nh", contentHash: "ch",
                remoteItems: [
                    .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "d", clientUID: clientUID)
                ],
                sourceLinkID: "m1", compoundLinkIDs: ["m1"], currentClientUID: "me")
        }
        XCTAssertEqual(decide(clientUID: "me"), .upload(replacingDraft: true))
        XCTAssertEqual(decide(clientUID: "other-device"), .blockedByForeignDraft)
        XCTAssertEqual(decide(clientUID: nil), .blockedByForeignDraft)
    }

    func testTrashedOrDifferentContentNeverSuppressesTheCopy() {
        let decision = RelatedPhotoCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: "ch", linkState: .trashed, linkID: "old"),
                .init(nameHash: "nh", contentHash: "ch", linkState: nil, linkID: "deleted"),
                .init(nameHash: "nh", contentHash: "other", linkState: .active, linkID: "same-name"),
                .init(nameHash: "unrelated", contentHash: "ch", linkState: .active, linkID: "other-name"),
            ],
            sourceLinkID: "m2", compoundLinkIDs: [], currentClientUID: "me")
        XCTAssertEqual(
            decision, .upload(replacingDraft: false),
            "the user keeps this favorite now; an older deletion of an identical file must not remove it")
    }

    func testForeignDraftStopsTheOperationAndKeepsItResumable() async throws {
        server.addRemoteRow(name: "m2.HEIC", contentOf: nil, state: .draft, linkID: "foreign", clientUID: "other")
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a foreign draft blocks the name")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .blockedByForeignDraft("m2.HEIC"))
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertNotNil(try journalStore.journal(forSeries: main))
    }

    /// F14: the blocked-name error names the person's filename, not the corrected upload name. Proton's name
    /// correction trims surrounding whitespace for the upload name, but the message must still show the name
    /// the person's file has, or it shows a different name than any listing does.
    func testAForeignDraftErrorNamesThePersonsFilenameNotTheCorrectedUploadName() async throws {
        server.renameNode("m2", to: "  m2.HEIC  ")
        server.addRemoteRow(name: "m2.HEIC", contentOf: nil, state: .draft, linkID: "foreign", clientUID: "other")
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a foreign draft blocks the name")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .blockedByForeignDraft("  m2.HEIC  "))
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertNotNil(try journalStore.journal(forSeries: main))
    }

    // MARK: Journal store

    func testJournalRoundTripsAndKeepsSeriesApart() throws {
        let other = PhotoUID(volumeID: "own", nodeID: "x1")
        var journal = SeriesDissolutionJournal(
            seriesMainUID: main, seriesUIDs: series, favorites: [.init(memberUID: member("m2"))])
        try journalStore.save(journal)
        try journalStore.save(
            SeriesDissolutionJournal(seriesMainUID: other, seriesUIDs: [other], favorites: [.init(memberUID: other)]))

        journal.favorites[0].copyUID = member("copy")
        journal.phase = .trashingSeries
        try journalStore.save(journal)

        XCTAssertEqual(try journalStore.journal(forSeries: main), journal)
        XCTAssertEqual(try journalStore.pendingJournals().count, 2)
        try journalStore.remove(forSeries: main)
        XCTAssertNil(try journalStore.journal(forSeries: main))
        XCTAssertEqual(try journalStore.pendingJournals().map(\.seriesMainUID), [other])
    }
}

// MARK: - Fake Proton

/// In-memory Proton for the dissolution seams: nodes with names, bytes and states, the duplicates endpoint,
/// uploads and the trash. Thread-safe; failure injection models errors and crashes.
///
/// A related photo keeps its own state, as on Proton (probes of 2026-10-04): trashing the main photo leaves its
/// related photos active but hidden from the photos and trash listings, and restoring the main photo brings them
/// back. A related photo trashed on its own stays trashed after that restore and never shows in the trash listing.
private final class FakeSeriesServer: SeriesDissolutionRemote, SeriesAlbumCarryOver, PhotoUploading,
    UploadDuplicateChecking, @unchecked Sendable
{
    enum Event: Equatable { case upload, trash, favorite, albumAdd }
    enum Read: Equatable { case roles, favorites }

    private struct Node {
        var name: String
        var bytes: Data
        var state: RemotePhotoDuplicate.LinkState
        var clientUID: String?
        var isCopy: Bool
        /// The main photo of a related photo; nil for a main or a standalone photo.
        var mainNodeID: String?
    }

    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private let ownVolumeID: String
    private var nodes: [String: Node] = [:]
    private var uploadFailures: [String: Int] = [:]
    private var commitThenFail: [String: Int] = [:]
    private var trashFailures = 0
    private var favoriteFailures = 0
    private var albumFailures = 0
    private var partialAlbumFailures = 0
    private var albumCancels = Set<String>()
    private var albumCancellationErrors = Set<String>()
    private var cancelsAfterAlbumWrite = Set<String>()
    private var roleReadFailures = 0
    private var albumReadFailures = 0
    private var volumeReadFailures = 0
    private var _uploads: [PhotoUploadRequest] = []
    private var _trashCalls: [[PhotoUID]] = []
    private var _events: [Event] = []
    private var _reads: [Read] = []
    private var _favorites = Set<String>()
    /// Album memberships of this fake Proton, keyed by album node id, plus the volume the album lives in.
    private var _albums: [String: (volumeID: String, members: Set<String>)] = [:]
    private var cachedAlbums: [String: (volumeID: String, members: Set<String>)]?
    private var _freshAlbumReads: [[PhotoUID]] = []
    private var _cachedAlbumReads: [[PhotoUID]] = []
    /// Links whose state answer carries no Photo role data.
    private var _withheldRoles = Set<String>()
    /// Links whose answer carries no State at all: the role data still names a main photo, but the server did
    /// not report the state, so `RemoteLinkVisibility.isActive` keeps its client default (true).
    private var _omittedStates = Set<String>()
    private var _trashRemainsActive = false

    private let seriesMainNodeID: String?

    /// The first node is the main photo of the series; the others are its related photos.
    init(ownVolumeID: String, seriesNodeIDs: [String]) {
        self.ownVolumeID = ownVolumeID
        seriesMainNodeID = seriesNodeIDs.first
        for id in seriesNodeIDs {
            nodes[id] = Node(
                name: "\(id).HEIC", bytes: Data("bytes-of-\(id)".utf8), state: .active, isCopy: false,
                mainNodeID: id == seriesMainNodeID ? nil : seriesMainNodeID)
        }
    }

    var uploads: [PhotoUploadRequest] { lock.withLock { _uploads } }
    var trashCalls: [[PhotoUID]] { lock.withLock { _trashCalls } }
    var events: [Event] { lock.withLock { _events } }
    var reads: [Read] { lock.withLock { _reads } }
    var freshAlbumReads: [[PhotoUID]] { lock.withLock { _freshAlbumReads } }
    var cachedAlbumReads: [[PhotoUID]] { lock.withLock { _cachedAlbumReads } }
    var activeCopyUIDs: Set<PhotoUID> {
        lock.withLock {
            Set(nodes.filter { $0.value.isCopy && $0.value.state == .active }.map { uid($0.key) })
        }
    }

    /// What Recently Deleted lists: trashed photos without a main photo. A series shows once, as its main photo.
    var trashListingNodeIDs: Set<String> {
        lock.withLock { Set(nodes.filter { $0.value.state == .trashed && $0.value.mainNodeID == nil }.map(\.key)) }
    }

    /// The related photos that the series of `mainNodeID` shows: none while its main photo is not active.
    func activeRelatedNodeIDs(ofMain mainNodeID: String) -> Set<String> {
        lock.withLock {
            guard nodes[mainNodeID]?.state == .active else { return [] }
            return Set(nodes.filter { $0.value.mainNodeID == mainNodeID && $0.value.state == .active }.map(\.key))
        }
    }

    /// A series that the viewer groups by capture time: its burst photos are standalone photos without a main photo.
    func makeStandalone(_ ids: [String]) { lock.withLock { for id in ids { nodes[id]?.mainNodeID = nil } } }
    /// Makes the nodes related photos of `mainNodeID`, for example a second main photo of a chained series.
    func relate(_ ids: [String], toMain mainNodeID: String) {
        lock.withLock { for id in ids { nodes[id]?.mainNodeID = mainNodeID } }
    }
    /// Renames a node, as a person's filename with surrounding whitespace: Proton's name correction trims
    /// that for the upload name, so the node name and the upload name differ.
    func renameNode(_ id: String, to name: String) {
        lock.withLock { nodes[id]?.name = name }
    }

    /// The state answer of these links carries no Photo role data.
    func withholdPhotoRole(_ ids: [String]) { lock.withLock { _withheldRoles = Set(ids) } }
    /// The state answer of these links carries no State: the role data still names a main photo.
    func omitPhotoState(_ ids: [String]) { lock.withLock { _omittedStates = Set(ids) } }
    /// The person deleted the photo for good; the server no longer knows it.
    func deleteForGood(_ id: String) { lock.withLock { nodes[id] = nil } }

    /// The person restores a photo from Recently Deleted. Only the restored node changes its state.
    func restoreFromTrash(_ id: String) { lock.withLock { nodes[id]?.state = .active } }

    func captureTime(of id: String) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(id.unicodeScalars.last?.value ?? 0))
    }

    var favoriteNodeIDs: Set<String> { lock.withLock { _favorites } }
    func albumMembers(_ albumID: String) -> Set<String> { lock.withLock { _albums[albumID]?.members ?? [] } }

    func markFavoriteNodeIDs(_ ids: [String]) { lock.withLock { _favorites.formUnion(ids) } }
    func addAlbum(_ albumID: String, volumeID: String, members: [String]) {
        lock.withLock { _albums[albumID] = (volumeID, Set(members)) }
    }
    func cacheAlbumMemberships() { lock.withLock { cachedAlbums = _albums } }
    /// Makes the nodes related photos of the series main photo on the server, even when the caller does not know them.
    func addServerRelatedNodeIDs(_ ids: [String]) {
        lock.withLock {
            for id in ids where id != seriesMainNodeID { nodes[id]?.mainNodeID = seriesMainNodeID }
        }
    }

    func failNextFavoriteWrite() { lock.withLock { favoriteFailures = 1 } }
    func failNextAlbumWrite() { lock.withLock { albumFailures = 1 } }
    func failNextAlbumWriteAfterOneAdd() { lock.withLock { partialAlbumFailures = 1 } }
    /// The next write to the album cancels the task that sends it, as a sign-out or a closed screen does. The network
    /// layer reports that cancel as `URLError.cancelled`.
    func cancelDuringAlbumWrite(to albumID: String) { lock.withLock { _ = albumCancels.insert(albumID) } }
    /// The next write to the album ends with `CancellationError` while the task that sends it stays running, as a
    /// cancel inside the SDK does.
    func failAlbumWriteWithCancellation(to albumID: String) {
        lock.withLock { _ = albumCancellationErrors.insert(albumID) }
    }
    /// The next write to the album succeeds, and then the task that sent it is cancelled.
    func cancelAfterAlbumWrite(to albumID: String) { lock.withLock { _ = cancelsAfterAlbumWrite.insert(albumID) } }
    func failNextRoleRead() { lock.withLock { roleReadFailures = 1 } }
    func failNextAlbumRead() { lock.withLock { albumReadFailures = 1 } }
    /// Makes the next `times` reads of the own photos volume fail with a temporary backend error.
    func failNextVolumeRead(times: Int = 1) { lock.withLock { volumeReadFailures = times } }
    /// The next trash request reports success while its photos stay active, as Proton did in the field.
    func acceptNextTrashWithoutEffect() { lock.withLock { _trashRemainsActive = true } }

    func failUploads(named name: String, times: Int) { lock.withLock { uploadFailures[name] = times } }
    func commitThenFailUploads(named name: String, times: Int) { lock.withLock { commitThenFail[name] = times } }
    func failNextTrash() { lock.withLock { trashFailures = 1 } }
    func markTrashed(_ ids: [String]) { lock.withLock { for id in ids { nodes[id]?.state = .trashed } } }

    func addRemoteRow(
        name: String, contentOf id: String?, state: RemotePhotoDuplicate.LinkState, linkID: String, clientUID: String?
    ) {
        lock.withLock {
            nodes[linkID] = Node(
                name: name, bytes: id.flatMap { nodes[$0]?.bytes } ?? Data(), state: state, clientUID: clientUID,
                isCopy: false)
        }
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: ownVolumeID, nodeID: id) }

    // SeriesDissolutionRemote

    func ownPhotosVolumeID() async throws -> String {
        try lock.withLock {
            if volumeReadFailures > 0 {
                volumeReadFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "volume read unavailable")
            }
        }
        return ownVolumeID
    }

    func source(for member: PhotoUID) async throws -> SeriesMemberSource {
        let node = try lock.withLock { try XCTUnwrap(nodes[member.nodeID]) }
        return SeriesMemberSource(
            filename: node.name,
            mediaType: "image/heic",
            captureTime: captureTime(of: member.nodeID),
            modificationDate: captureTime(of: member.nodeID),
            additionalMetadata: [.init(name: "Camera", utf8JsonValue: Data("{}".utf8))]
        )
    }

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let node = try lock.withLock { try XCTUnwrap(nodes[uid.nodeID]) }
        try node.bytes.write(to: destination)
        onProgress(1)
    }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { Set(uids.filter { nodes[$0.nodeID]?.state == .active }) }
    }

    func memberRoles(of uids: [PhotoUID]) async throws -> [PhotoUID: RemoteLinkVisibility] {
        try lock.withLock {
            _reads.append(.roles)
            if roleReadFailures > 0 {
                roleReadFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "role read unavailable")
            }
        }
        let links = try await linkVisibility(of: uids.map(\.nodeID))
        return Dictionary(uniqueKeysWithValues: uids.compactMap { uid in links[uid.nodeID].map { (uid, $0) } })
    }

    func trashSeries(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if trashFailures > 0 {
                trashFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "trash unavailable")
            }
            _trashCalls.append(uids)
            _events.append(.trash)
            guard !_trashRemainsActive else {
                _trashRemainsActive = false
                return
            }
            for uid in uids { nodes[uid.nodeID]?.state = .trashed }
        }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock {
            _reads.append(.favorites)
            return Set(uids.filter { _favorites.contains($0.nodeID) })
        }
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if favoriteFailures > 0 {
                favoriteFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "tag write unavailable")
            }
            _events.append(.favorite)
            _favorites.formUnion(uids.map(\.nodeID))
        }
    }

    // SeriesAlbumCarryOver

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        try await albums(containing: [uid])[uid] ?? []
    }

    func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        try lock.withLock {
            _cachedAlbumReads.append(uids)
            return try albumMemberships(uids, in: cachedAlbums ?? _albums)
        }
    }

    func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        try lock.withLock {
            _freshAlbumReads.append(uids)
            return try albumMemberships(uids, in: _albums)
        }
    }

    private func albumMemberships(
        _ uids: [PhotoUID], in albums: [String: (volumeID: String, members: Set<String>)]
    ) throws -> [PhotoUID: [SeriesAlbumReference]] {
        if albumReadFailures > 0 {
            albumReadFailures -= 1
            throw UploadError.retryableBackend(code: 503, message: "album read unavailable")
        }
        return Dictionary(
            uids.map { uid in
                let matches = albums.filter { $0.value.members.contains(uid.nodeID) }
                    .map { SeriesAlbumReference(volumeID: $0.value.volumeID, albumID: $0.key) }
                    .sorted { $0.albumID < $1.albumID }
                return (uid, matches)
            }, uniquingKeysWith: { first, _ in first })
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try lock.withLock {
            if partialAlbumFailures > 0 {
                partialAlbumFailures -= 1
                if let first = uids.first { _albums[albumID]?.members.insert(first.nodeID) }
                throw UploadError.retryableBackend(code: 429, message: "partial album write")
            }
            if albumCancels.remove(albumID) != nil {
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
            if albumCancellationErrors.remove(albumID) != nil { throw CancellationError() }
            if albumFailures > 0 {
                albumFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "album write unavailable")
            }
            _events.append(.albumAdd)
            _albums[albumID]?.members.formUnion(uids.map(\.nodeID))
            if cancelsAfterAlbumWrite.remove(albumID) != nil { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }

    // PhotoUploading

    let admission = UploadNetworkAdmission()
    private var _reservedAtUpload: [Bool] = []
    /// For each upload: it started with an active reservation of `admission` that may use expensive networks.
    var reservedAtUpload: [Bool] { lock.withLock { _reservedAtUpload } }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await admission.reserve(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let bytes = try Data(contentsOf: request.fileURL)
        let reserved =
            request.networkReservation.map { $0.isActive && admission.issued($0) && $0.allowsExpensiveNetwork }
            ?? false
        return try lock.withLock {
            _reservedAtUpload.append(reserved)
            _uploads.append(request)
            if let left = uploadFailures[request.name], left > 0 {
                uploadFailures[request.name] = left - 1
                throw UploadError.retryableBackend(code: 503, message: "upload failed")
            }
            let id = "copy-\(_uploads.count)"
            nodes[id] = Node(name: request.name, bytes: bytes, state: .active, isCopy: true)
            _events.append(.upload)
            if let left = commitThenFail[request.name], left > 0 {
                commitThenFail[request.name] = left - 1
                throw CancellationError()
            }
            return uid(id)
        }
    }

    func cancel(token: UUID) async {}

    // UploadDuplicateChecking

    func nameHash(forCorrectedName name: String) async throws -> String { "nh(\(name))" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "ch(\(sha1Hex))" }
    func hashKeyEpoch() async throws -> String { "epoch" }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        lock.withLock { Set(nodes.filter { $0.value.mainNodeID == mainLinkID }.map(\.key)) }
    }

    /// The state and main photo of each link that the server knows, as `links/fetch_metadata` reports them.
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        lock.withLock {
            var visibility: [String: RemoteLinkVisibility] = [:]
            for id in linkIDs {
                guard let node = nodes[id] else { continue }
                let withheld = _withheldRoles.contains(id)
                // An answer without State keeps the role data: `isActive` falls back to its client default.
                let stateless = _omittedStates.contains(id)
                visibility[id] = RemoteLinkVisibility(
                    isActive: stateless || node.state == .active,
                    mainPhotoLinkID: withheld ? nil : node.mainNodeID,
                    hasExplicitState: !stateless,
                    hasExplicitPhotoState: !withheld && !stateless)
            }
            return visibility
        }
    }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock {
            nodes.sorted { $0.key < $1.key }.compactMap { id, node in
                guard nameHashes.contains("nh(\(node.name))") else { return nil }
                let sha1 = UploadContentSHA1.hexString(digest: Self.sha1(node.bytes))
                return RemotePhotoDuplicate(
                    nameHash: "nh(\(node.name))",
                    contentHash: node.state == .draft ? nil : "ch(\(sha1))",
                    linkState: node.state,
                    linkID: id,
                    clientUID: node.clientUID
                )
            }
        }
    }

    private static func sha1(_ data: Data) -> Data {
        let accumulator = UploadSHA1Accumulator()
        accumulator.update(data)
        return accumulator.finalizeDigest()
    }
}
