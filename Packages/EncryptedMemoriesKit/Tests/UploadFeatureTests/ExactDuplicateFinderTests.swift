import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class ExactDuplicateFinderTests: XCTestCase {
    private var directory: URL!
    private var server: EditScenarioServer!
    private var store: UploadIdentityManifestStore!
    private var journal: EditReplacementJournalFileStore!
    private let epoch = "scenario-epoch"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exact-duplicate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        server = EditScenarioServer()
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var finder: ExactDuplicateFinder { finder() }

    private func finder(
        resolver: (any UploadIdentityResolving)? = nil, identities: (any UploadIdentityStore)? = nil,
        albums: (any SeriesAlbumCarryOver)? = nil
    ) -> ExactDuplicateFinder {
        ExactDuplicateFinder(
            checker: server,
            resolver: resolver ?? UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: identities ?? store, journal: journal, remote: server, albums: albums ?? server)
    }

    private func digest(_ seed: String) -> Data {
        var digest = Data(repeating: 0, count: 20)
        for (index, byte) in seed.utf8.enumerated() { digest[index % 20] ^= byte }
        return digest
    }

    private func hash(_ seed: String) -> String { EditScenarioServer.contentHash(digest(seed)) }

    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    /// Indexes every link that the server knows, trashed links too, as an index before its next refresh holds them.
    private func indexServer(extra: [UploadRemoteContentIndexRecord] = []) {
        let records = server.links.map {
            UploadRemoteContentIndexRecord(contentHash: $0.contentHash, hashKeyEpoch: epoch, remoteLinkID: $0.linkID)
        }
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                records + extra, unresolvedIssues: [], hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())))
    }

    private func onlyGroup() async throws -> ExactDuplicateGroup {
        let groups = try await finder.duplicateGroups().groups
        XCTAssertEqual(groups.count, 1)
        return try XCTUnwrap(groups.first)
    }

    /// A manifest row of a local source that counts `link` as its backup.
    @discardableResult
    private func row(
        _ identifier: String, names link: String, contentHash: String, epoch rowEpoch: String? = nil
    ) -> UploadSourceIdentity {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier)
        XCTAssertTrue(
            store.upsert(
                UploadIdentityRecord(
                    source: source, filename: "\(identifier).JPG", correctedName: "\(identifier).JPG", fileSize: 10,
                    modificationDate: date(0), sha1Hex: "sha1", nameHash: "nh", contentHash: contentHash,
                    hashKeyEpoch: rowEpoch ?? epoch, remoteVolumeID: "vol", remoteLinkID: link,
                    outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: date(0))))
        return source
    }

    private var violations: [String] { server.steps.flatMap(\.violations) }

    private func count(_ action: String) -> Int { server.steps.filter { $0.action == action }.count }

    // MARK: - Groups

    func testGroupsHoldOnlyActiveMainsOfTheOwnLibraryInTheCurrentKeyEpoch() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        let trashed = server.seedLink(digest: digest("a"))
        server.personTrash(trashed)
        let otherMain = server.seedLink(digest: digest("x"))
        _ = server.seedLink(digest: digest("a"), main: otherMain)
        let large = (0..<3).map { _ in server.seedLink(digest: digest("d")) }
        let earlierKeyA = server.seedLink(digest: digest("b"))
        let earlierKeyB = server.seedLink(digest: digest("b"))
        let current = server.links.filter { ![earlierKeyA.nodeID, earlierKeyB.nodeID].contains($0.linkID) }
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                current.map {
                    UploadRemoteContentIndexRecord(
                        contentHash: $0.contentHash, hashKeyEpoch: epoch, remoteLinkID: $0.linkID)
                }
                    // A photo of a shared album lives in another volume, which the server of the own library does
                    // not answer for.
                    + [.init(contentHash: hash("a"), hashKeyEpoch: epoch, remoteLinkID: "shared-link")],
                unresolvedIssues: [], hashKeyEpoch: epoch, checkpoint: .init(eventID: "event-1", refreshedAt: Date())))
        for link in [earlierKeyA, earlierKeyB] {
            XCTAssertTrue(
                store.upsertRemoteContentRecord(
                    .init(contentHash: hash("b"), hashKeyEpoch: "earlier-epoch", remoteLinkID: link.nodeID)))
        }

        let scan = try await finder.duplicateGroups()

        XCTAssertEqual(scan.coverage, .complete)
        XCTAssertEqual(
            scan.groups,
            [
                ExactDuplicateGroup(contentHash: hash("d"), hashKeyEpoch: epoch, members: large),
                ExactDuplicateGroup(contentHash: hash("a"), hashKeyEpoch: epoch, members: [first, second]),
            ])
    }

    func testAnIndexThatIsNotBuiltOrIncompleteReportsItsStateAndStillFindsExactGroups() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        for link in [first, second] {
            XCTAssertTrue(
                store.upsertRemoteContentRecord(
                    .init(contentHash: hash("a"), hashKeyEpoch: epoch, remoteLinkID: link.nodeID)))
        }
        let expected = [ExactDuplicateGroup(contentHash: hash("a"), hashKeyEpoch: epoch, members: [first, second])]

        let unbuilt = try await finder.duplicateGroups()
        XCTAssertEqual(unbuilt.coverage, .indexing)
        XCTAssertEqual(unbuilt.groups, expected)

        indexServer()
        server.indexHealth = .degraded(indexedCount: 2, unresolvedCount: 3)
        let degraded = try await finder.duplicateGroups()
        XCTAssertEqual(degraded.coverage, .incomplete(unresolvedCount: 3))
        XCTAssertEqual(degraded.groups, expected)

        server.indexHealth = .unavailable
        let unavailableCoverage = try await finder.duplicateGroups().coverage
        XCTAssertEqual(unavailableCoverage, .indexing)

        server.indexHealth = nil
        let completeCoverage = try await finder.duplicateGroups().coverage
        XCTAssertEqual(completeCoverage, .complete)
    }

    // MARK: - Keep order

    func testKeepOrderRanksOwnAlbumThenFavoriteThenManifestThenCaptureDateThenLinkID() {
        let small = PhotoUID(volumeID: "vol", nodeID: "link-0001")
        let large = PhotoUID(volumeID: "vol", nodeID: "link-0002")
        func facts(
            album: Bool = false, favorite: Bool = false, manifest: Bool = false, captured: Date? = nil
        ) -> ExactDuplicateKeepFacts {
            .init(isInOwnAlbum: album, isFavorite: favorite, isNamedByManifest: manifest, captureDate: captured)
        }
        func kept(_ smallFacts: ExactDuplicateKeepFacts, _ largeFacts: ExactDuplicateKeepFacts) -> PhotoUID? {
            ExactDuplicateFinder.keepOrder([small, large], facts: [small: smallFacts, large: largeFacts]).first
        }

        XCTAssertEqual(
            kept(facts(favorite: true, manifest: true, captured: date(0)), facts(album: true, captured: date(9))),
            large, "an own album outranks every later fact")
        XCTAssertEqual(
            kept(facts(manifest: true, captured: date(0)), facts(favorite: true, captured: date(9))), large,
            "a favorite outranks the manifest and the capture date")
        XCTAssertEqual(
            kept(facts(captured: date(0)), facts(manifest: true, captured: date(9))), large,
            "the photo that this device backs up outranks the capture date")
        XCTAssertEqual(kept(facts(captured: date(9)), facts(captured: date(0))), large, "the earliest capture wins")
        XCTAssertEqual(kept(facts(), facts(captured: date(9))), large, "a known capture date outranks a missing one")
        XCTAssertEqual(kept(facts(captured: date(0)), facts(captured: date(0))), small, "the smallest link ID decides")
    }

    func testRankedMembersReadTheFactsOfEveryMember() async throws {
        let earliest = server.seedLink(digest: digest("a"), captureTime: date(0))
        let manifest = server.seedLink(digest: digest("a"), captureTime: date(5))
        let favorite = server.seedLink(digest: digest("a"), captureTime: date(5))
        let album = server.seedLink(digest: digest("a"), captureTime: date(5))
        try await server.markFavorite([favorite])
        try await server.addPhotos([album], toOwnAlbum: "own-album")
        row("asset-1", names: manifest.nodeID, contentHash: hash("a"))
        indexServer()

        let group = try await onlyGroup()
        let ranked = try await finder.rankedMembers(of: [group])

        XCTAssertEqual(ranked, [hash("a"): [album, favorite, manifest, earliest]])
    }

    func testTheRankingAndTheMergeReadTheManifestAndTheAlbumsOnceForAllMembers() async throws {
        let members = (0..<4).map { _ in server.seedLink(digest: digest("a")) }
        for (index, member) in members.enumerated() {
            row("asset-\(index)", names: member.nodeID, contentHash: hash("a"))
        }
        indexServer()
        let identities = CountingIdentityStore(base: store)
        let albums = CountingAlbums(base: server)
        let finder = finder(identities: identities, albums: albums)
        let group = try await onlyGroup()

        _ = try await finder.rankedMembers(of: [group])
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 1))
        XCTAssertEqual(albums.reads, CountingAlbums.Reads(single: 0, batch: 1))

        let outcome = try await finder.merge(group, keeping: members[0])
        XCTAssertEqual(outcome, .merged(kept: members[0], trashed: Array(members.dropFirst()), keptDuplicates: [:]))
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 2))
    }

    // MARK: - Merge

    func testMergeCarriesTheFavoriteAndOwnAlbumsToTheKeptPhotoBeforeTheTrash() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        server.decorate(duplicate)
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        let keptLink = try XCTUnwrap(server.links.first { $0.linkID == kept.nodeID })
        XCTAssertTrue(keptLink.favorite)
        XCTAssertEqual(keptLink.albums, [.init(volumeID: "vol", albumID: "own-album")])
        XCTAssertEqual(server.links.first { $0.linkID == duplicate.nodeID }?.state, .trashed)
        let actions = server.steps.map(\.action)
        let favoriteStep = try XCTUnwrap(actions.firstIndex(of: "mark favorite"))
        let albumStep = try XCTUnwrap(actions.firstIndex(of: "carry album own-album"))
        let trashStep = try XCTUnwrap(actions.firstIndex(of: "duplicate trash [\"\(duplicate.nodeID)\"]"))
        XCTAssertLessThan(favoriteStep, trashStep)
        XCTAssertLessThan(albumStep, trashStep)
        XCTAssertEqual(violations, [])
        let groupsAfter = try await finder.duplicateGroups().groups
        XCTAssertEqual(groupsAfter, [])
    }

    func testMergeAddsTheKeptPhotoToEveryAlbumEvenWhenAStaleReadListsItThere() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        server.decorate(duplicate)
        server.reportStaleAlbums([.init(volumeID: "vol", albumID: "own-album")], of: kept)
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(
            server.links.first { $0.linkID == kept.nodeID }?.albums, [.init(volumeID: "vol", albumID: "own-album")],
            "the album keeps the photo after its duplicate leaves")
    }

    func testMergeRestoresTheDuplicatesWhenAnotherDeviceTrashesTheKeptPhotoMeanwhile() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        let keptSource = row("asset-2", names: kept.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        // The other device keeps `duplicate` and trashes `kept` while this device trashes `duplicate`.
        server.trashAfterDuplicateTrash = kept.nodeID

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .skipped(.keptLeftLibraryDuringMerge))
        XCTAssertEqual(server.links.first { $0.linkID == duplicate.nodeID }?.state, .active, "one copy stays")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the row moves back")
        XCTAssertEqual(store.record(for: keptSource)?.remoteLinkID, duplicate.nodeID, "no row names a trashed photo")
        XCTAssertEqual(violations, [])
    }

    func testMergeReadsTheKeptPhotoAgainWhenItsReadAfterTheTrashFailsAndRestoresTheDuplicates() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        server.trashAfterDuplicateTrash = kept.nodeID
        server.failingVisibilityReadsAfterDuplicateTrash = 1
        var finder = finder()
        finder.keptReadRetryDelay = .zero

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .skipped(.keptLeftLibraryDuringMerge))
        XCTAssertEqual(server.links.first { $0.linkID == duplicate.nodeID }?.state, .active, "one copy stays")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the row moves back")
        XCTAssertEqual(violations, [])
    }

    func testMergeThrowsWhenEveryReadOfTheKeptPhotoAfterTheTrashFails() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        let readsBefore = server.readCounts.visibility

        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("The merge cannot tell whether the kept photo stayed")
        } catch {}

        XCTAssertEqual(server.readCounts.visibility - readsBefore, 1 + ExactDuplicateFinder.keptReadAttempts)
        XCTAssertEqual(server.links.first { $0.linkID == duplicate.nodeID }?.state, .trashed)
    }

    func testMergeReadsTheKeptPhotoNoMoreAfterACancellation() async throws {
        let kept = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        server.failingVisibilityReadsAfterDuplicateTrash = 1
        server.visibilityErrorAfterDuplicateTrash = CancellationError()
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        let readsBefore = server.readCounts.visibility

        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("A cancelled read ends the merge")
        } catch is CancellationError {}

        XCTAssertEqual(server.readCounts.visibility - readsBefore, 2, "the members and one read of the kept photo")
    }

    func testMergeAllReadsTheManifestAndTheFavoritesOnceAndTheServerStateOfEveryGroup() async throws {
        for seed in ["a", "b", "c"] {
            _ = server.seedLink(digest: digest(seed))
            let duplicate = server.seedLink(digest: digest(seed))
            row("asset-\(seed)", names: duplicate.nodeID, contentHash: hash(seed))
        }
        indexServer()
        let groups = try await finder.duplicateGroups().groups
        XCTAssertEqual(groups.count, 3)
        let identities = CountingIdentityStore(base: store)
        let finder = finder(identities: identities)
        let readsBefore = server.readCounts

        let results = await finder.merge(groups.map { ($0, $0.members[0]) })

        XCTAssertEqual(
            results.map { try? $0.get() },
            groups.map { .merged(kept: $0.members[0], trashed: [$0.members[1]], keptDuplicates: [:]) })
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 1))
        let reads = server.readCounts
        XCTAssertEqual(reads.favorites - readsBefore.favorites, 1)
        XCTAssertEqual(
            reads.visibility - readsBefore.visibility, 2 * groups.count,
            "each group reads its members and, after its trash, the kept photo")
        XCTAssertEqual(reads.compound - readsBefore.compound, 2 * groups.count, "each group reads every compound")
        XCTAssertEqual(violations, [])
    }

    /// Three groups whose second member a local source counts as its backup, and the finder for them.
    private func threeGroups() async throws -> (groups: [ExactDuplicateGroup], sources: [UploadSourceIdentity]) {
        var sources: [UploadSourceIdentity] = []
        for seed in ["a", "b", "c"] {
            _ = server.seedLink(digest: digest(seed))
            let duplicate = server.seedLink(digest: digest(seed))
            sources.append(row("asset-\(seed)", names: duplicate.nodeID, contentHash: hash(seed)))
        }
        indexServer()
        let groups = try await finder.duplicateGroups().groups.sorted { $0.contentHash < $1.contentHash }
        XCTAssertEqual(groups.count, 3)
        return (groups, sources)
    }

    private func state(of uid: PhotoUID) -> EditScenarioServer.State? {
        server.links.first { $0.linkID == uid.nodeID }?.state
    }

    /// The backup's duplicate check of this finder, which logs every drop of its cached remote state.
    private func loggingResolver() -> (resolver: SpyIdentityResolver, log: BackupEventLog) {
        let log = BackupEventLog()
        let pipeline = UploadDedupePipeline(store: store, checker: server, replacementJournal: journal)
        return (SpyIdentityResolver(inner: pipeline, log: log), log)
    }

    private func invalidations(in log: BackupEventLog) -> Int {
        log.events.filter { $0 == "manifest.invalidateCachedRemoteState" }.count
    }

    /// The trash requests of the merge, failed ones too.
    private var trashCalls: [String] {
        server.steps.map(\.action).filter { $0.hasPrefix("duplicate trash") || $0 == "failed duplicate trash" }
    }

    func testMergeAllTrashesEveryGroupWithOneTrashAndDropsTheBackupCacheOnce() async throws {
        let (groups, sources) = try await threeGroups()
        let (resolver, log) = loggingResolver()

        let results = await finder(resolver: resolver).merge(groups.map { ($0, $0.members[0]) })

        XCTAssertEqual(
            results.map { try? $0.get() },
            groups.map { .merged(kept: $0.members[0], trashed: [$0.members[1]], keptDuplicates: [:]) })
        XCTAssertEqual(trashCalls, ["duplicate trash \(groups.map(\.members[1].nodeID))"])
        XCTAssertEqual(invalidations(in: log), 1)
        for (group, source) in zip(groups, sources) {
            XCTAssertEqual(state(of: group.members[1]), .trashed)
            XCTAssertEqual(store.record(for: source)?.remoteLinkID, group.members[0].nodeID)
        }
        XCTAssertEqual(violations, [])
    }

    func testAFailedTrashFailsEveryGroupAndARetryMovesNoRowTwice() async throws {
        let (groups, sources) = try await threeGroups()
        let (resolver, log) = loggingResolver()
        server.failNextTrash()

        let results = await finder(resolver: resolver).merge(groups.map { ($0, $0.members[0]) })

        for (index, group) in groups.enumerated() {
            XCTAssertThrowsError(try results[index].get())
            XCTAssertEqual(state(of: group.members[1]), .active, "the failed trash moved nothing")
            XCTAssertEqual(
                store.record(for: sources[index])?.remoteLinkID, group.members[0].nodeID,
                "the moved row names the kept photo, which holds the same bytes")
        }
        XCTAssertEqual(invalidations(in: log), 1)
        let movedRows = sources.map { store.record(for: $0) }

        let retry = await finder(resolver: resolver).merge(groups.map { ($0, $0.members[0]) })

        XCTAssertEqual(
            retry.map { try? $0.get() },
            groups.map { .merged(kept: $0.members[0], trashed: [$0.members[1]], keptDuplicates: [:]) })
        XCTAssertEqual(sources.map { store.record(for: $0) }, movedRows, "the retry moves no row twice")
        XCTAssertEqual(
            trashCalls, ["failed duplicate trash", "duplicate trash \(groups.map(\.members[1].nodeID))"])
        XCTAssertEqual(violations, [])
    }

    func testMergeAllRestoresOnlyTheGroupWhoseKeptPhotoLeftDuringTheTrash() async throws {
        let (groups, sources) = try await threeGroups()
        let (resolver, log) = loggingResolver()
        // Another device keeps the duplicate of the second group and trashes its kept photo meanwhile.
        server.trashAfterDuplicateTrash = groups[1].members[0].nodeID

        let results = await finder(resolver: resolver).merge(groups.map { ($0, $0.members[0]) })

        XCTAssertEqual(try? results[1].get(), .skipped(.keptLeftLibraryDuringMerge))
        XCTAssertEqual(state(of: groups[1].members[1]), .active, "one copy stays")
        XCTAssertEqual(store.record(for: sources[1])?.remoteLinkID, groups[1].members[1].nodeID, "the row moves back")
        for index in [0, 2] {
            XCTAssertEqual(
                try? results[index].get(),
                .merged(kept: groups[index].members[0], trashed: [groups[index].members[1]], keptDuplicates: [:]))
            XCTAssertEqual(state(of: groups[index].members[1]), .trashed)
            XCTAssertEqual(store.record(for: sources[index])?.remoteLinkID, groups[index].members[0].nodeID)
        }
        XCTAssertEqual(
            server.steps.map(\.action).filter { $0.hasPrefix("person restore") },
            ["person restore \(groups[1].members[1].nodeID)"])
        XCTAssertEqual(invalidations(in: log), 2, "once after the trash and once after the restore")
        XCTAssertEqual(violations, [])
    }

    func testMergeAllWritesNothingWhenTheSharedFavoritesReadFails() async throws {
        let (groups, sources) = try await threeGroups()
        server.failNextFavoritesRead()

        let results = await finder.merge(groups.map { ($0, $0.members[0]) })

        for (index, group) in groups.enumerated() {
            XCTAssertThrowsError(try results[index].get())
            XCTAssertEqual(state(of: group.members[1]), .active)
            XCTAssertEqual(store.record(for: sources[index])?.remoteLinkID, group.members[1].nodeID, "no row moved")
        }
        XCTAssertEqual(count("mark favorite"), 0)
        XCTAssertEqual(violations, [])
    }

    func testMergeDropsTheCachedRemoteStateOfTheBackupSoItNeverAdoptsATrashedDuplicate() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        // The local file has the name of `duplicate`, so the name lookup of the backup finds it.
        let descriptor = UploadResourceDescriptor(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1"),
            fileURL: URL(fileURLWithPath: "/export/\(duplicate.nodeID)"), filename: duplicate.nodeID, fileSize: 10,
            modificationDate: date(0), precomputedSHA1Digest: digest("a"))
        let pipeline = UploadDedupePipeline(store: store, checker: server, replacementJournal: journal)
        await pipeline.prime([descriptor])

        let outcome = try await finder(resolver: pipeline).merge(try await onlyGroup(), keeping: kept)
        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        let resolved = try await pipeline.resolve(descriptor)
        if resolved.decision == .upload { await pipeline.uploadDidFail(descriptor) }

        XCTAssertNotEqual(resolved.decision, .skip(.activeDuplicate, remoteLinkID: duplicate.nodeID))
        XCTAssertNotEqual(store.record(for: descriptor.source)?.remoteLinkID, duplicate.nodeID)
    }

    func testMergeKeepsADuplicateWhoseRelatedFileHasNoCopyUnderTheKeptPhoto() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let keptVideo = server.seedLink(digest: digest("video"), main: kept)
        let twin = server.seedLink(digest: digest("a"))
        let twinVideo = server.seedLink(digest: digest("video"), main: twin)
        let different = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("other video"), main: different)
        let videoRow = row("asset-video", names: twinVideo.nodeID, contentHash: hash("video"))
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(
            outcome, .merged(kept: kept, trashed: [twin], keptDuplicates: [different: .relatedFileWithoutTwin]))
        XCTAssertEqual(server.links.first { $0.linkID == different.nodeID }?.state, .active)
        XCTAssertEqual(store.record(for: videoRow)?.remoteLinkID, keptVideo.nodeID, "the related row moves to its twin")
        XCTAssertEqual(violations, [])
    }

    func testMergeKeepsADuplicateThatAPendingEditReplacementNames() async throws {
        let kept = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("video"), main: kept)
        let superseded = server.seedLink(digest: digest("a"))
        let retiring = server.seedLink(digest: digest("a"))
        let retiringVideo = server.seedLink(digest: digest("video"), main: retiring)
        let free = server.seedLink(digest: digest("a"))
        let asset = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-edit")
        try journal.addSuperseded(superseded, for: asset)
        try journal.prepareToRetire(["link-9999": [retiringVideo.nodeID]], for: asset)
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(
            outcome,
            .merged(
                kept: kept, trashed: [free],
                keptDuplicates: [superseded: .pendingEditReplacement, retiring: .pendingEditReplacement]))
        XCTAssertEqual(server.links.first { $0.linkID == superseded.nodeID }?.state, .active)
        XCTAssertEqual(server.links.first { $0.linkID == retiring.nodeID }?.state, .active)
        XCTAssertEqual(violations, [])
    }

    func testMergeKeepsADuplicateThatALocalSourceNeedsWhenItsRowCannotMove() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let earlierKey = server.seedLink(digest: digest("a"))
        let otherBytes = server.seedLink(digest: digest("a"))
        let movable = server.seedLink(digest: digest("a"))
        let earlierRow = row("asset-1", names: earlierKey.nodeID, contentHash: hash("a"), epoch: "earlier-epoch")
        let otherRow = row("asset-2", names: otherBytes.nodeID, contentHash: hash("b"))
        let movableRow = row("asset-3", names: movable.nodeID, contentHash: hash("a"))
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(
            outcome,
            .merged(
                kept: kept, trashed: [movable],
                keptDuplicates: [earlierKey: .neededByLocalSource, otherBytes: .neededByLocalSource]))
        XCTAssertEqual(store.record(for: earlierRow)?.remoteLinkID, earlierKey.nodeID)
        XCTAssertEqual(store.record(for: otherRow)?.remoteLinkID, otherBytes.nodeID)
        XCTAssertEqual(store.record(for: movableRow)?.remoteLinkID, kept.nodeID)
    }

    func testMergeMovesTheManifestRowSoTheNextBackupSkipsWithoutAnUpload() async throws {
        let descriptor = UploadResourceDescriptor(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1"),
            fileURL: URL(fileURLWithPath: "/export/IMG_1.JPG"), filename: "IMG_1.JPG", fileSize: 10,
            modificationDate: date(0), precomputedSHA1Digest: digest("a"))
        let pipeline = UploadDedupePipeline(store: store, checker: server, replacementJournal: journal)
        let first = try await pipeline.resolve(descriptor)
        XCTAssertEqual(first.decision, .upload)
        let kept = server.seedLink(digest: digest("a"))
        let ownUpload = server.seedLink(digest: digest("a"))
        try await pipeline.recordUploaded(
            descriptor, identity: first.identity, remoteVolumeID: "vol", remoteLinkID: ownUpload.nodeID)
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)
        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [ownUpload], keptDuplicates: [:]))
        let moved = try XCTUnwrap(store.record(for: descriptor.source))
        XCTAssertEqual(moved.remoteLinkID, kept.nodeID)
        XCTAssertEqual(moved.outcome, UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)

        let stepsBefore = server.steps.count
        let next = UploadDedupePipeline(store: store, checker: server, replacementJournal: journal)
        let again = try await next.resolve(descriptor)

        XCTAssertEqual(again.decision, .skip(.knownFromManifest, remoteLinkID: kept.nodeID))
        XCTAssertEqual(server.steps.count, stepsBefore, "the next backup neither uploads nor trashes")
    }

    func testRebindMovesOnlyCurrentRowsAndRepeatsNothing() throws {
        let current = row("asset-1", names: "link-dup", contentHash: hash("a"))
        let earlierKey = row("asset-2", names: "link-dup", contentHash: hash("a"), epoch: "earlier-epoch")
        let otherBytes = row("asset-3", names: "link-dup", contentHash: hash("b"))
        let move = UploadRemoteLinkMove(from: "link-dup", to: "link-kept", contentHash: hash("a"))

        XCTAssertTrue(store.rebindRemoteLinks([move], hashKeyEpoch: epoch))
        let moved = try XCTUnwrap(store.record(for: current))
        XCTAssertTrue(store.rebindRemoteLinks([move], hashKeyEpoch: epoch))

        XCTAssertEqual(moved.remoteLinkID, "link-kept")
        XCTAssertEqual(store.record(for: current), moved, "a repeated move writes nothing")
        XCTAssertEqual(store.record(for: earlierKey)?.remoteLinkID, "link-dup")
        XCTAssertEqual(store.record(for: otherBytes)?.remoteLinkID, "link-dup")
    }

    func testARetryAfterAFailedTrashRepeatsNoWriteAndLosesNothing() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        server.decorate(duplicate)
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()

        server.failNextTrash()
        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("The failed trash must surface")
        } catch {}
        XCTAssertEqual(server.links.first { $0.linkID == duplicate.nodeID }?.state, .active)
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, kept.nodeID)
        let movedRow = store.record(for: source)

        let retry = try await finder.merge(group, keeping: kept)
        XCTAssertEqual(retry, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(count("mark favorite"), 1)
        XCTAssertEqual(
            server.links.first { $0.linkID == kept.nodeID }?.albums, [.init(volumeID: "vol", albumID: "own-album")],
            "the repeated album add keeps one membership")
        XCTAssertEqual(store.record(for: source), movedRow, "the retry moves no row twice")

        // A crash after the trash leaves no duplicate to merge.
        let stepsBefore = server.steps.count
        let afterTrash = try await finder.merge(group, keeping: kept)
        XCTAssertEqual(afterTrash, .skipped(.noDuplicateLeft))
        XCTAssertEqual(server.steps.count, stepsBefore)
        XCTAssertEqual(violations, [])
    }
}

/// Counts the reads of the manifest rows that name a remote link.
private final class CountingIdentityStore: UploadIdentityStore, @unchecked Sendable {
    struct Reads: Equatable {
        var single = 0
        var batch = 0
    }

    private let base: UploadIdentityManifestStore
    private let lock = NSLock()
    private var counted = Reads()

    init(base: UploadIdentityManifestStore) { self.base = base }

    var reads: Reads { lock.withLock { counted } }

    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? { base.record(for: source) }
    func trustedRecords(contentHash: String, hashKeyEpoch: String, limit: Int) -> [UploadIdentityRecord] {
        base.trustedRecords(contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, limit: limit)
    }
    func upsert(_ record: UploadIdentityRecord) -> Bool { base.upsert(record) }
    func sources(withRemoteLinkID linkID: String) -> [UploadSourceIdentity]? {
        lock.withLock { counted.single += 1 }
        return base.sources(withRemoteLinkID: linkID)
    }
    func sources(withRemoteLinkIDs linkIDs: Set<String>) -> [String: [UploadSourceIdentity]]? {
        lock.withLock { counted.batch += 1 }
        return base.sources(withRemoteLinkIDs: linkIDs)
    }
    func forgetRemoteLinks(_ linkIDs: Set<String>, of source: UploadSourceIdentity) -> Bool {
        base.forgetRemoteLinks(linkIDs, of: source)
    }
    func rebindRemoteLinks(_ moves: [UploadRemoteLinkMove], hashKeyEpoch: String) -> Bool {
        base.rebindRemoteLinks(moves, hashKeyEpoch: hashKeyEpoch)
    }
}

/// Counts the album reads.
private final class CountingAlbums: SeriesAlbumCarryOver, @unchecked Sendable {
    struct Reads: Equatable {
        var single = 0
        var batch = 0
    }

    private let base: EditScenarioServer
    private let lock = NSLock()
    private var counted = Reads()

    init(base: EditScenarioServer) { self.base = base }

    var reads: Reads { lock.withLock { counted } }

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        lock.withLock { counted.single += 1 }
        return try await base.albums(containing: uid)
    }
    func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        lock.withLock { counted.batch += 1 }
        var albumsByPhoto: [PhotoUID: [SeriesAlbumReference]] = [:]
        for uid in uids { albumsByPhoto[uid] = try await base.albums(containing: uid) }
        return albumsByPhoto
    }
    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try await base.addPhotos(uids, toOwnAlbum: albumID)
    }
}
