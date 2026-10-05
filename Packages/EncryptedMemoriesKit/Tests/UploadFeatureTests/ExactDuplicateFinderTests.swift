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
        _ identifier: String, names link: String, contentHash: String, epoch rowEpoch: String? = nil,
        fileSize: Int64 = 10
    ) -> UploadSourceIdentity {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier)
        XCTAssertTrue(
            store.upsert(
                UploadIdentityRecord(
                    source: source, filename: "\(identifier).JPG", correctedName: "\(identifier).JPG",
                    fileSize: fileSize,
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

        let records = server.links.map {
            UploadRemoteContentIndexRecord(contentHash: $0.contentHash, hashKeyEpoch: epoch, remoteLinkID: $0.linkID)
        }
        let issues = (1...3).map {
            UploadRemoteContentIndexIssue(
                remoteLinkID: "unreadable-\($0)", reason: .decryptFailure, firstObservedAt: date(0),
                lastObservedAt: date(0), lastRepairAttemptAt: nil, indexGeneration: "event-1")
        }
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                records, unresolvedIssues: issues, hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())))
        let degraded = try await finder.duplicateGroups()
        XCTAssertEqual(degraded.coverage, .incomplete(unresolvedCount: 3))
        XCTAssertEqual(degraded.groups, expected)

        indexServer()
        let completeCoverage = try await finder.duplicateGroups().coverage
        XCTAssertEqual(completeCoverage, .complete)
    }

    func testTheScanReadsTheCoverageFromTheIndexAndNeverWaitsForTheBuildOfTheBackup() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        indexServer()
        // The health read of the backend refreshes the index first, so it waits for a running build of the backup.
        server.indexHealth = .unavailable

        let scan = try await finder.duplicateGroups()

        XCTAssertEqual(scan.coverage, .complete)
        XCTAssertEqual(scan.groups.map(\.members), [[first, second]])
        XCTAssertEqual(server.indexBuilds, 0, "a scan builds nothing")
    }

    func testPrepareIndexBuildsAMissingIndexWithTheBuildOfTheBackupAndTheNextScanFindsTheGroups() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        let records = server.links.map {
            UploadRemoteContentIndexRecord(contentHash: $0.contentHash, hashKeyEpoch: epoch, remoteLinkID: $0.linkID)
        }
        let unbuilt = try await finder.duplicateGroups()
        XCTAssertEqual(unbuilt, ExactDuplicateScan(groups: [], coverage: .indexing))
        let store = try XCTUnwrap(store)
        server.indexBuild = { [epoch] progress in
            await progress(.init(phase: .indexing, completed: 1, total: 2))
            _ = store.replaceRemoteContentIndex(
                records, unresolvedIssues: [], hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date()))
            await progress(.init(phase: .ready))
        }
        let reported = ProgressLog()

        let changed = try await finder.prepareIndex { await reported.append($0) }

        XCTAssertTrue(changed)
        XCTAssertEqual(server.indexBuilds, 1, "the backup's build runs through its resolver")
        let steps = await reported.steps
        XCTAssertEqual(steps, [.init(phase: .indexing, completed: 1, total: 2), .init(phase: .ready)])
        let built = try await finder.duplicateGroups()
        XCTAssertEqual(built.coverage, .complete)
        XCTAssertEqual(built.groups.map(\.members), [[first, second]])

        server.indexBuild = nil
        let unchanged = try await finder.prepareIndex { _ in }
        XCTAssertFalse(unchanged, "a build that changes nothing needs no new scan")
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
        let ranked = await finder.rankedMembers(of: [group])

        XCTAssertEqual(ranked, [hash("a"): [album, favorite, manifest, earliest]])
    }

    func testTheRankingReadsOneNodeForEachMemberAndTheMergeReadsTheManifestOnce() async throws {
        let members = (0..<4).map { _ in server.seedLink(digest: digest("a")) }
        for (index, member) in members.enumerated() {
            row("asset-\(index)", names: member.nodeID, contentHash: hash("a"))
        }
        indexServer()
        let identities = CountingIdentityStore(base: store)
        let albums = CountingAlbums(base: server)
        let finder = finder(identities: identities, albums: albums)
        let group = try await onlyGroup()

        _ = await finder.rankedMembers(of: [group])
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 1))
        XCTAssertEqual(albums.reads, CountingAlbums.Reads(single: 0, batch: 0), "the node read gives the albums")
        XCTAssertEqual(server.readCounts.sharingMembers, 4, "one node read for each member")
        XCTAssertEqual(server.readCounts.albumMembers, 0)

        let outcome = try await finder.merge(group, keeping: members[0])
        XCTAssertEqual(outcome, .merged(kept: members[0], trashed: Array(members.dropFirst()), keptDuplicates: [:]))
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 2))
    }

    func testASharedMemberIsKeptFirstAndAMissingNodeLeavesOnlyItsGroupInTheFallbackOrder() async throws {
        let album = server.seedLink(digest: digest("a"), captureTime: date(0))
        let shared = server.seedLink(digest: digest("a"), captureTime: date(5))
        try await server.markFavorite([album])
        try await server.addPhotos([album], toOwnAlbum: "own-album")
        server.share(shared)
        let lost = server.seedLink(digest: digest("b"), captureTime: date(9))
        let other = server.seedLink(digest: digest("b"), captureTime: date(1))
        server.loseNode(lost)
        indexServer()
        let groups = try await finder.duplicateGroups().groups

        let ranked = await finder.rankedMembers(of: groups)

        XCTAssertEqual(ranked, [hash("a"): [shared, album]], "a trash would end the sharing, so it stays")
        let fallback = await finder.fallbackMembers(of: groups)
        XCTAssertEqual(fallback[hash("b")], [other, lost], "the group of the missing node keeps the earliest photo")
    }

    func testTheScanOf1500GroupsReadsNoAlbumNoSharingStateAndNoFavorites() async throws {
        server.seedLinks(digests: (0..<1_500).flatMap { [digest("group-\($0)"), digest("group-\($0)")] })
        indexServer()
        let clock = ContinuousClock()
        let start = clock.now

        let scan = try await finder.duplicateGroups()
        let scanned = clock.now
        _ = await finder.fallbackMembers(of: scan.groups)

        XCTAssertEqual(scan.groups.count, 1_500)
        let reads = server.readCounts
        XCTAssertEqual(reads.visibility, 20, "3,000 links in reads of 150")
        XCTAssertEqual(reads.albumMembers, 0)
        XCTAssertEqual(reads.sharingMembers, 0)
        XCTAssertEqual(reads.favorites, 0)
        print(
            "[Duplicates timing] scan=\(start.duration(to: scanned)) fallback=\(scanned.duration(to: clock.now)) "
                + "visibilityRequests=\(reads.visibility)")
    }

    @MainActor
    func testTheScreenShows1500GroupsAndTheirSizesBeforeAnyNodeLoadAndRanksOnlyTheShownPages() async throws {
        let links = server.seedLinks(digests: (0..<1_500).flatMap { [digest("group-\($0)"), digest("group-\($0)")] })
        for index in 0..<1_500 {
            row("asset-\(index)", names: links[index * 2].nodeID, contentHash: hash("group-\(index)"), fileSize: 1_000)
        }
        indexServer()
        let remote = FavoritesGatedRemote(base: server)
        let finder = ExactDuplicateFinder(
            checker: server, resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal, remote: remote, albums: server)
        let model = ExactDuplicatesModel(finder: finder)
        let clock = ContinuousClock()
        let start = clock.now
        let load = Task { await model.load() }
        for _ in 0..<5_000 where model.rankingLine == nil { try await Task.sleep(for: .milliseconds(1)) }
        let published = clock.now

        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.count, 1_500)
        let beforeRanking = server.readCounts
        XCTAssertEqual(beforeRanking.albumMembers, 0, "no node load before the groups show")
        XCTAssertEqual(beforeRanking.sharingMembers, 0, "no node load before the groups show")
        XCTAssertNotNil(model.rankingLine)
        XCTAssertEqual(model.totalFreedBytes, 1_500_000, "the manifest knows every size before any node load")

        remote.gate.open()
        await load.value
        let reads = server.readCounts
        let pages = 2 * ExactDuplicatesModel.rankingPageSize
        XCTAssertEqual(model.groups.filter(\.isRanked).count, pages, "the shown page and the page after it")
        XCTAssertNil(model.rankingLine)
        XCTAssertEqual(reads.favorites, 1)
        XCTAssertEqual(reads.albumMembers, 0, "the node read gives the albums")
        XCTAssertEqual(reads.sharingMembers, pages * 2, "one node read for each member")

        model.groupAppeared(model.groups[500].id)
        for _ in 0..<5_000 where model.groups.filter(\.isRanked).count < 2 * pages {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.groups.filter(\.isRanked).count, 2 * pages, "scrolling ranks two more pages")
        XCTAssertEqual(server.readCounts.favorites, 1, "one favorites listing serves every page")
        XCTAssertEqual(server.readCounts.sharingMembers, 2 * pages * 2)

        await model.load()
        XCTAssertEqual(server.readCounts.sharingMembers, 2 * pages * 2, "an unchanged group keeps its facts")
        XCTAssertEqual(server.readCounts.albumMembers, 0)
        XCTAssertEqual(model.groups.filter(\.isRanked).count, 2 * pages)
        print(
            "[Duplicates timing] firstGroups=\(start.duration(to: published)) "
                + "ranking=\(published.duration(to: clock.now)) visibilityRequests=\(reads.visibility) "
                + "favoritesListings=\(reads.favorites) albumReads=\(reads.albumMembers) "
                + "sharingReads=\(reads.sharingMembers)")
    }

    @MainActor
    func testEachGroupShowsTheSpaceItsMergeFreesFromTheManifestOrTheNodeAndNoneWhenUnknown() async throws {
        let manifest = (0..<3).map { _ in server.seedLink(digest: digest("manifest")) }
        let node = (0..<2).map { _ in server.seedLink(digest: digest("node")) }
        _ = (0..<2).map { _ in server.seedLink(digest: digest("unknown")) }
        row("asset-1", names: manifest[0].nodeID, contentHash: hash("manifest"), fileSize: 4_000)
        server.setNodeSize(1_500, of: node[1])
        indexServer()

        let scan = try await finder.duplicateGroups()
        XCTAssertEqual(scan.byteSizes, [hash("manifest"): 4_000], "the scan reads sizes from the manifest only")

        let model = ExactDuplicatesModel(finder: finder)
        await model.load()
        let sizes = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.id, $0.freedBytes) })
        XCTAssertEqual(sizes[hash("manifest")], 8_000, "two duplicates of 4,000 bytes")
        XCTAssertEqual(sizes[hash("node")], 1_500, "the node read of the ranking gives the size")
        XCTAssertEqual(sizes[hash("unknown")] ?? nil, nil, "no size until it is known")
        XCTAssertEqual(model.totalFreedBytes, 9_500)
        let unknown = try XCTUnwrap(model.groups.first { $0.id == hash("unknown") })
        XCTAssertNil(unknown.freedText)
    }

    func testRelatedFilesOfAProvenCompoundAreNoCandidates() throws {
        let records = [
            UploadRemoteContentIndexRecord(contentHash: "original", hashKeyEpoch: epoch, remoteLinkID: "earlier-main"),
            UploadRemoteContentIndexRecord(contentHash: "original", hashKeyEpoch: epoch, remoteLinkID: "edit-original"),
            UploadRemoteContentIndexRecord(contentHash: "edited", hashKeyEpoch: epoch, remoteLinkID: "edit-main"),
            UploadRemoteContentIndexRecord(contentHash: "copy", hashKeyEpoch: epoch, remoteLinkID: "copy-1"),
            UploadRemoteContentIndexRecord(contentHash: "copy", hashKeyEpoch: epoch, remoteLinkID: "copy-2"),
        ]
        let compound = UploadRemoteAssetIndexRecord(
            externalIdentity: UploadBackupExternalIdentity(identifier: "cloud-1", revision: .init(rawValue: 1)),
            resourceCount: 2, remoteLinkIDs: ["edit-main", "edit-original"], hashKeyEpoch: epoch)
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                records, remoteAssetRecords: [compound], unresolvedIssues: [], hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())))

        XCTAssertEqual(store.remoteContentDuplicateGroups(hashKeyEpoch: epoch), ["copy": ["copy-1", "copy-2"]])
    }

    // MARK: - Merge

    func testMergeKeepsEverySharedDuplicateAndReadsTheSharingStateOfItsGroupOnly() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let sharedA = server.seedLink(digest: digest("a"))
        let sharedB = server.seedLink(digest: digest("a"))
        let plain = server.seedLink(digest: digest("a"))
        server.share(sharedA)
        server.share(sharedB)
        _ = server.seedLink(digest: digest("b"))
        _ = server.seedLink(digest: digest("b"))
        indexServer()
        let groups = try await finder.duplicateGroups().groups
        let group = try XCTUnwrap(groups.first { $0.contentHash == hash("a") })

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(
            outcome, .merged(kept: kept, trashed: [plain], keptDuplicates: [sharedA: .shared, sharedB: .shared]))
        XCTAssertEqual(server.links.first { $0.linkID == sharedA.nodeID }?.state, .active)
        XCTAssertEqual(server.readCounts.sharingMembers, 4, "only the members of the merged group")
    }

    func testAMergeWhoseNodeReadFailsTrashesNothingAndCarriesNothingOver() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        server.decorate(duplicate)
        indexServer()
        let group = try await onlyGroup()
        server.loseNode(duplicate)
        let stepsBefore = server.steps.count

        let results = await finder.merge([(group, kept)])

        guard case .failure = results[0] else { return XCTFail("expected a failure, got \(results[0])") }
        XCTAssertEqual(server.steps.count, stepsBefore, "no favorite, album, cover, or trash write")
        XCTAssertEqual(server.links.first { $0.linkID == duplicate.nodeID }?.state, .active)
    }

    func testAMergeWhoseCoverWriteFailsFailsBeforeTheTrashAndMovesNoRow() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        try await server.addPhotos([duplicate], toOwnAlbum: "own-album")
        server.setAlbumCover("own-album", to: duplicate)
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        server.failNextCoverWrite()

        let results = await finder.merge([(try await onlyGroup(), kept)])

        guard case .failure = results[0] else { return XCTFail("expected a failure, got \(results[0])") }
        XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash") }, "nothing is trashed")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the manifest row stays")
        XCTAssertEqual(server.albumCovers, ["own-album": duplicate.nodeID])
    }

    func testTheCarryOverReadsTheAlbumsOfTheDuplicatesFreshBeforeTheTrash() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let albums = CachingAlbums(base: server)
        // An earlier read, for example of the album screen, cached the duplicate in no album.
        _ = try await albums.albums(containing: [duplicate])
        try await server.addPhotos([duplicate], toOwnAlbum: "own-album")

        let outcome = try await finder(albums: albums).merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(
            server.links.first { $0.linkID == kept.nodeID }?.albums, [.init(volumeID: "vol", albumID: "own-album")],
            "the album added after the earlier read gets the kept photo")
    }

    func testSizesLeaveOutAHashThatOnlyRelatedFilesHold() throws {
        let records = [
            UploadRemoteContentIndexRecord(contentHash: "video", hashKeyEpoch: epoch, remoteLinkID: "video-1"),
            UploadRemoteContentIndexRecord(contentHash: "video", hashKeyEpoch: epoch, remoteLinkID: "video-2"),
            UploadRemoteContentIndexRecord(contentHash: "main-1", hashKeyEpoch: epoch, remoteLinkID: "live-1"),
            UploadRemoteContentIndexRecord(contentHash: "main-2", hashKeyEpoch: epoch, remoteLinkID: "live-2"),
            UploadRemoteContentIndexRecord(contentHash: "copy", hashKeyEpoch: epoch, remoteLinkID: "copy-1"),
            UploadRemoteContentIndexRecord(contentHash: "copy", hashKeyEpoch: epoch, remoteLinkID: "copy-2"),
        ]
        let compounds = (1...2).map { index in
            UploadRemoteAssetIndexRecord(
                externalIdentity: UploadBackupExternalIdentity(
                    identifier: "cloud-\(index)", revision: .init(rawValue: 1)),
                resourceCount: 2, remoteLinkIDs: ["live-\(index)", "video-\(index)"], hashKeyEpoch: epoch)
        }
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                records, remoteAssetRecords: compounds, unresolvedIssues: [], hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())))
        row("asset-video", names: "video-1", contentHash: "video", fileSize: 9_000)
        row("asset-copy", names: "copy-1", contentHash: "copy", fileSize: 500)

        XCTAssertEqual(store.remoteContentDuplicateSizes(hashKeyEpoch: epoch), ["copy": 500])
        XCTAssertEqual(store.remoteContentDuplicateGroups(hashKeyEpoch: epoch), ["copy": ["copy-1", "copy-2"]])
    }

    func testMergeMovesTheCoverOfAnOwnAlbumFromATrashedDuplicateToTheKeptPhoto() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        try await server.addPhotos([duplicate], toOwnAlbum: "own-album")
        server.setAlbumCover("own-album", to: duplicate)
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(server.albumCovers, ["own-album": kept.nodeID])
        let actions = server.steps.map(\.action)
        let coverStep = try XCTUnwrap(actions.firstIndex(of: "cover own-album"))
        let trashStep = try XCTUnwrap(actions.firstIndex(of: "duplicate trash [\"\(duplicate.nodeID)\"]"))
        XCTAssertLessThan(coverStep, trashStep, "the album never shows a trashed cover")
    }

    func testMergeLeavesACoverThatIsTheKeptPhotoOrAnotherPhoto() async throws {
        for coverIsKept in [true, false] {
            server = EditScenarioServer()
            let kept = server.seedLink(digest: digest("a"))
            let duplicate = server.seedLink(digest: digest("a"))
            let other = server.seedLink(digest: digest("x"))
            try await server.addPhotos([kept, duplicate, other], toOwnAlbum: "own-album")
            let cover = coverIsKept ? kept : other
            server.setAlbumCover("own-album", to: cover)
            indexServer()

            _ = try await finder.merge(try await onlyGroup(), keeping: kept)

            XCTAssertEqual(server.albumCovers, ["own-album": cover.nodeID], "cover is kept: \(coverIsKept)")
            XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("cover ") }, "cover is kept: \(coverIsKept)")
        }
    }

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
/// Holds the favorites listing, the first read of the ranking, while its gate is closed.
private final class FavoritesGatedRemote: ExactDuplicateRemote, @unchecked Sendable {
    let base: EditScenarioServer
    let gate = FinderGate()

    init(base: EditScenarioServer) { self.base = base }

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        await gate.pass()
        return try await base.favoriteUIDs(among: uids)
    }
}

/// Holds callers until it opens.
private actor FinderGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    nonisolated func open() { Task { await self.release() } }

    private func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor ProgressLog {
    private(set) var steps: [UploadRemoteIndexPreparationProgress] = []
    func append(_ step: UploadRemoteIndexPreparationProgress) { steps.append(step) }
}

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
/// Caches every membership read like the album repository, and reads the server for `currentAlbums`.
private final class CachingAlbums: SeriesAlbumCarryOver, @unchecked Sendable {
    private let base: EditScenarioServer
    private let lock = NSLock()
    private var cache: [PhotoUID: [SeriesAlbumReference]] = [:]

    init(base: EditScenarioServer) { self.base = base }

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        try await albums(containing: [uid])[uid] ?? []
    }
    func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        var result: [PhotoUID: [SeriesAlbumReference]] = [:]
        for uid in uids {
            if let cached = lock.withLock({ cache[uid] }) {
                result[uid] = cached
            } else {
                let read = try await base.albums(containing: uid)
                lock.withLock { cache[uid] = read }
                result[uid] = read
            }
        }
        return result
    }
    func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        var result: [PhotoUID: [SeriesAlbumReference]] = [:]
        for uid in uids { result[uid] = try await base.albums(containing: uid) }
        lock.withLock { cache.merge(result) { _, new in new } }
        return result
    }
    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try await base.addPhotos(uids, toOwnAlbum: albumID)
    }
    func ownAlbumCovers() async throws -> [String: String] { try await base.ownAlbumCovers() }
    func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws {
        try await base.setCover(uid, ofOwnAlbum: albumID)
    }
}

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
