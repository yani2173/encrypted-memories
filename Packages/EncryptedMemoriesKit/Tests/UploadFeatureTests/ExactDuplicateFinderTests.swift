import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class ExactDuplicateFinderTests: XCTestCase {
    private var directory: URL!
    private var servers = ScenarioServers()
    private var server: EditScenarioServer! {
        didSet {
            if let server { servers.append(server) }
        }
    }

    private struct ScenarioServers {
        private var servers: [EditScenarioServer] = []

        mutating func append(_ server: EditScenarioServer) { servers.append(server) }

        var relatedFileTransferCallCount: Int {
            servers.reduce(0) { $0 + $1.relatedFileTransferCallCount }
        }
    }
    private var store: UploadIdentityManifestStore!
    private var journal: EditReplacementJournalFileStore!
    private let epoch = "scenario-epoch"

    override func setUpWithError() throws {
        servers = ScenarioServers()
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
        if let server {
            XCTAssertEqual(server.relatedFileTransferCallCount, 0, "Existing merge paths must not attempt a transfer")
            XCTAssertEqual(
                servers.relatedFileTransferCallCount, 0, "Replaced merge servers must not attempt a transfer")
        }
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var finder: ExactDuplicateFinder { finder() }

    /// A new store of the journal file for each finder, as after a new launch.
    private var mergeJournal: ExactDuplicateMergeJournalFileStore {
        ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)
    }

    private func finder(
        resolver: (any UploadIdentityResolving)? = nil, identities: (any UploadIdentityStore)? = nil,
        albums: (any SeriesAlbumCarryOver)? = nil, remote: (any ExactDuplicateRemote)? = nil
    ) -> ExactDuplicateFinder {
        ExactDuplicateFinder(
            checker: server,
            resolver: resolver ?? UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: identities ?? store, journal: journal, mergeJournal: mergeJournal,
            remote: remote ?? server, albums: albums ?? server)
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
        fileSize: Int64 = 10, in manifest: UploadIdentityManifestStore? = nil
    ) -> UploadSourceIdentity {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier)
        XCTAssertTrue(
            (manifest ?? store).upsert(
                UploadIdentityRecord(
                    source: source, filename: "\(identifier).JPG", correctedName: "\(identifier).JPG",
                    fileSize: fileSize,
                    modificationDate: date(0), sha1Hex: "sha1", nameHash: "nh", contentHash: contentHash,
                    hashKeyEpoch: rowEpoch ?? epoch, remoteVolumeID: "vol", remoteLinkID: link,
                    outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: date(0))))
        return source
    }

    /// Requests whose photo to keep the person chose, so the merge keeps it as named.
    private func chosen(_ pairs: [(ExactDuplicateGroup, PhotoUID)]) -> [ExactDuplicateMergeRequest] {
        pairs.map { ExactDuplicateMergeRequest(group: $0.0, kept: $0.1, isKeptChosen: true) }
    }

    private var violations: [String] { server.steps.flatMap(\.violations) }

    private func count(_ action: String) -> Int { server.steps.filter { $0.action == action }.count }

    func testTransferAccountingIncludesAReplacedScenarioServer() async throws {
        var servers = ScenarioServers()
        var remote = EditScenarioServer()
        servers.append(remote)
        let uid = PhotoUID(volumeID: "vol", nodeID: "related")
        let destination = directory.appendingPathComponent("unused.partial")
        do {
            _ = try await remote.downloadRelatedFile(uid, to: destination, allowsExpensiveNetwork: false)
            XCTFail("An unavailable download must fail")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
        }
        remote = EditScenarioServer()
        servers.append(remote)

        XCTAssertEqual(remote.relatedFileTransferCallCount, 0)
        XCTAssertEqual(servers.relatedFileTransferCallCount, 1, "Replacing the server must retain earlier calls")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testEveryScenarioRemoteDispatchesBothTransfersThroughTheExistential() async throws {
        let base = EditScenarioServer()
        let uid = PhotoUID(volumeID: "vol", nodeID: "related")
        let file = directory.appendingPathComponent("unused.partial")
        let remotes: [any ExactDuplicateRemote] = [
            FavoritesGatedRemote(base: base), TrashStoppingRemote(base: base), RestoreGatedRemote(base: base),
            TimelineDatesRemote(base: base, unknown: []), BeforeTrashRemote(base: base, before: {}),
            DateReadCountingRemote(base: base), MemberDroppingRemote(base: base, drop: uid),
        ]
        for remote in remotes {
            do {
                _ = try await remote.downloadRelatedFile(uid, to: file, allowsExpensiveNetwork: false)
                XCTFail("An unavailable download must fail")
            } catch {
                XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
            }
            do {
                _ = try await remote.uploadRelatedFile(makeDuplicateRelatedFileRequest(fileURL: file))
                XCTFail("An unavailable upload must fail")
            } catch {
                XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .unavailable)
            }
        }
        XCTAssertEqual(base.relatedFileTransferCallCount, remotes.count * 2)
        XCTAssertEqual(base.uploadRequestCount, 0)
        XCTAssertEqual(base.steps.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

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

    func testKeepOrderRanksOwnAlbumThenFavoriteThenCaptureDateThenLinkIDAndNeverTheManifest() {
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
            kept(facts(captured: date(0)), facts(manifest: true, captured: date(9))), small,
            "the photo that this device backs up does not rank: other devices back up other copies")
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

        XCTAssertEqual(ranked, [hash("a"): [album, favorite, earliest, manifest]])
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

    func testACancelledRankingCanFinishDeliveringAnAlreadyReadPage() async throws {
        let first = server.seedLink(digest: digest("late"))
        let second = server.seedLink(digest: digest("late"))
        let earlier = ExactDuplicateFingerprint(pixelWidth: 24)
        for member in [first, second] { server.setFingerprint(earlier, of: member) }
        indexServer()
        let group = try await onlyGroup()
        let finder = finder
        let delivery = FinderGate()
        let entered = expectation(description: "the real finder calls its page receiver")
        let pages = PageCollector()
        let ranking = Task {
            await finder.rankMembers(of: [group]) { page in
                entered.fulfill()
                await delivery.pass()
                XCTAssertTrue(Task.isCancelled, "delivery resumes after cancellation")
                await pages.add(page)
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        ranking.cancel()
        let changed = ExactDuplicateFingerprint(captureTime: date(99))
        server.setFingerprint(changed, of: second)
        delivery.open()
        await ranking.value

        let collected = await pages.pages
        let page = try XCTUnwrap(collected.first)
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(Set(page.members[group.id] ?? []), Set([first, second]))
        XCTAssertEqual(page.fingerprints[group.id]?[second], earlier, "the receiver carries the earlier read")
        XCTAssertNotEqual(page.fingerprints[group.id]?[second], changed, "the delivered facts predate the change")
    }

    func testTheRankingPageCarriesTheFactsAndTheSizeOfEachMemberFromTheSameReads() async throws {
        let album = server.seedLink(digest: digest("a"), captureTime: date(5))
        let manifest = server.seedLink(digest: digest("a"), captureTime: date(0))
        let shared = server.seedLink(digest: digest("a"), captureTime: date(9))
        try await server.markFavorite([album])
        try await server.addPhotos([album], toOwnAlbum: "own-album")
        server.share(shared)
        server.setNodeSize(4_200, of: album)
        server.setNodeSize(4_300, of: shared)
        row("asset-1", names: manifest.nodeID, contentHash: hash("a"))
        indexServer()
        let identities = CountingIdentityStore(base: store)
        let albums = CountingAlbums(base: server)
        let finder = finder(identities: identities, albums: albums)
        let group = try await onlyGroup()
        let favoritesBefore = server.readCounts.favorites

        let pages = PageCollector()
        await finder.rankMembers(of: [group]) { await pages.add($0) }

        let collected = await pages.pages
        let page = try XCTUnwrap(collected.first)
        let facts = try XCTUnwrap(page.facts[hash("a")])
        XCTAssertEqual(
            facts[album],
            ExactDuplicateKeepFacts(
                isInOwnAlbum: true, isFavorite: true, isNamedByManifest: false, captureDate: date(5)))
        XCTAssertEqual(
            facts[manifest],
            ExactDuplicateKeepFacts(
                isInOwnAlbum: false, isFavorite: false, isNamedByManifest: true, captureDate: date(0)))
        XCTAssertEqual(facts[shared]?.isShared, true)
        XCTAssertEqual(
            page.memberByteSizes[hash("a")], [album: 4_200, shared: 4_300], "a node without a size has none")
        XCTAssertEqual(server.readCounts.sharingMembers, 3, "still one node read for each member")
        XCTAssertEqual(server.readCounts.albumMembers, 0)
        XCTAssertEqual(server.readCounts.favorites - favoritesBefore, 1, "one favorites listing")
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 1))
        XCTAssertEqual(albums.reads, CountingAlbums.Reads(single: 0, batch: 0))
    }

    func testTheRankingPageCarriesTheMetadataOfEveryMemberAndAReadWithoutAMemberRanksNothing() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        let third = server.seedLink(digest: digest("a"))
        server.setFingerprint(described, of: first)
        server.setFingerprint(bare, of: second)
        indexServer()
        let group = try await onlyGroup()

        let pages = PageCollector()
        await finder.rankMembers(of: [group]) { await pages.add($0) }
        let collected = await pages.pages
        let page = try XCTUnwrap(collected.first)
        XCTAssertEqual(
            page.fingerprints[group.id], [first: described, second: bare, third: ExactDuplicateFingerprint()])

        // A read that leaves a member out proves nothing about its metadata, so the group keeps its fallback order.
        let partial = ExactDuplicateFinder(
            checker: server, resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal, mergeJournal: mergeJournal,
            remote: MemberDroppingRemote(base: server, drop: third), albums: server)
        let partialPages = PageCollector()
        await partial.rankMembers(of: [group]) { await partialPages.add($0) }
        let partialCollected = await partialPages.pages
        let partialPage = try XCTUnwrap(partialCollected.first)
        XCTAssertNil(partialPage.members[group.id])
        XCTAssertNil(partialPage.fingerprints[group.id])
    }

    func testTheRankingReadsTheNodesOfOneGroupAtATime() async throws {
        server.seedLinks(digests: (0..<6).flatMap { [digest("group-\($0)"), digest("group-\($0)")] })
        indexServer()
        let remote = ConcurrencyCountingRemote(base: server)
        let finder = ExactDuplicateFinder(
            checker: server,
            resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal, mergeJournal: mergeJournal, remote: remote,
            albums: server)
        let groups = try await finder.duplicateGroups().groups
        XCTAssertEqual(groups.count, 6)

        let ranked = await finder.rankedMembers(of: groups)

        XCTAssertEqual(ranked.count, 6, "every group is ranked")
        XCTAssertEqual(remote.peakConcurrentNodeReads, 1, "the groups read their nodes one after the other")
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
    func testTheScreenChecks1500GroupsBeforeShowingTheirSizesWithoutExtraNodeReads() async throws {
        let links = server.seedLinks(digests: (0..<1_500).flatMap { [digest("group-\($0)"), digest("group-\($0)")] })
        for index in 0..<1_500 {
            row("asset-\(index)", names: links[index * 2].nodeID, contentHash: hash("group-\(index)"), fileSize: 1_000)
        }
        indexServer()
        let remote = FavoritesGatedRemote(base: server)
        let finder = ExactDuplicateFinder(
            checker: server, resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal, mergeJournal: mergeJournal, remote: remote,
            albums: server)
        let model = ExactDuplicatesModel(finder: finder)
        let clock = ContinuousClock()
        let start = clock.now
        let load = Task { await model.load(checkAllGroups: true) }
        for _ in 0..<5_000 {
            if await remote.gate.hasWaiters { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let published = clock.now

        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.count, 1_500)
        let beforeRanking = server.readCounts
        XCTAssertEqual(beforeRanking.albumMembers, 0, "no node load before the groups show")
        XCTAssertEqual(beforeRanking.sharingMembers, 0, "no node load before the groups show")
        XCTAssertNotNil(model.rankingLine, "the metadata check of the shown pages shows progress")
        XCTAssertEqual(model.visibleGroups, [])
        XCTAssertEqual(model.totalFreedBytes, 0, "unchecked candidates claim no freed space")

        remote.gate.open()
        await load.value
        let reads = server.readCounts
        let pages = 1_500
        XCTAssertEqual(
            model.groups.filter(\.isRanked).count, pages, "every candidate was checked without a row appearance")
        XCTAssertNil(model.rankingLine)
        XCTAssertEqual(reads.favorites, 1)
        XCTAssertEqual(reads.albumMembers, 0, "the node read gives the albums")
        XCTAssertEqual(reads.sharingMembers, pages * 2, "one node read for each member")

        XCTAssertEqual(model.visibleGroups.count, pages)
        XCTAssertEqual(model.totalFreedBytes, 1_500_000, "the checked groups can show their known sizes")
        model.groupAppeared(model.groups[500].id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.readCounts.favorites, 1, "one favorites listing serves every page")
        XCTAssertEqual(server.readCounts.sharingMembers, pages * 2, "appearing rows reread no metadata")

        await model.load(checkAllGroups: true)
        XCTAssertEqual(server.readCounts.sharingMembers, pages * 2, "an unchanged group keeps its facts")
        XCTAssertEqual(server.readCounts.albumMembers, 0)
        XCTAssertEqual(model.groups.filter(\.isRanked).count, pages)
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

        let results = await finder.merge(chosen([(group, kept)]))

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

        let results = await finder.merge(chosen([(try await onlyGroup(), kept)]))

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

    func testAFailedTrashThatMovedThePhotosRestoresTheDuplicateWhenAnotherDeviceTrashedTheKeptPhoto() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        let keptSource = row("asset-2", names: kept.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        // The other device keeps `duplicate` and trashes `kept`. The trash of this device moves `duplicate`, and its
        // answer fails.
        server.trashAfterDuplicateTrash = kept.nodeID
        server.applyNextTrashThenFail()

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .skipped(.keptLeftLibraryDuringMerge))
        XCTAssertEqual(state(of: duplicate), .active, "one copy stays")
        XCTAssertEqual(state(of: kept), .trashed, "the merge of the other device stays")
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the row moves back")
        XCTAssertEqual(store.record(for: keptSource)?.remoteLinkID, duplicate.nodeID, "no row names a trashed photo")
        XCTAssertEqual(violations, [])
    }

    func testAFailedTrashThatMovedEveryDuplicateReportsTheMergeWhileTheKeptPhotoStays() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        server.applyNextTrashThenFail()

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(state(of: kept), .active)
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, kept.nodeID)
        let stepsBefore = server.steps.count
        _ = try await finder.duplicateGroups()
        XCTAssertEqual(server.steps.count, stepsBefore, "the next scan writes nothing")
        XCTAssertEqual(restores, [])
    }

    func testATrashRefusedForADuplicateThatAnotherDeviceTrashedReportsTheMerge() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        server.rejectsTrashOfTrashedLinks = true
        // Another device merges the same group with the same kept photo and trashes `duplicate` first.
        let server = server!
        let remote = BeforeTrashRemote(base: server) { try? await server.trashDuplicates([duplicate]) }

        let outcome = try await finder(remote: remote).merge(group, keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(state(of: kept), .active)
        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(restores, [], "nothing comes back")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, kept.nodeID, "the row names the kept photo")
        let stepsBefore = server.steps.count
        _ = try await finder.duplicateGroups()
        XCTAssertEqual(server.steps.count, stepsBefore, "the merge is no longer pending")
        XCTAssertEqual(violations, [])
    }

    func testDevicesThatMergeTheSameGroupWithTheSameKeptPhotoAtOnceAllReportTheMerge() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicates = [server.seedLink(digest: digest("a")), server.seedLink(digest: digest("a"))]
        indexServer()
        let group = try await onlyGroup()
        server.rejectsTrashOfTrashedLinks = true
        let deviceCount = 4
        // Every device reads the server state and plans before any device trashes.
        let barrier = FinderBarrier(count: deviceCount)
        var finders: [ExactDuplicateFinder] = []
        var rows: [(store: UploadIdentityManifestStore, source: UploadSourceIdentity)] = []
        for number in 0..<deviceCount {
            let folder = directory.appendingPathComponent("device-\(number)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = try XCTUnwrap(
                UploadIdentityManifestStore(
                    url: folder.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
            let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: folder))
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-\(number)")
            XCTAssertTrue(
                store.upsert(
                    UploadIdentityRecord(
                        source: source, filename: "IMG.JPG", correctedName: "IMG.JPG", fileSize: 10,
                        modificationDate: date(0), sha1Hex: "sha1", nameHash: "nh", contentHash: hash("a"),
                        hashKeyEpoch: epoch, remoteVolumeID: "vol",
                        remoteLinkID: duplicates[number % duplicates.count].nodeID,
                        outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: date(0))))
            let finder = ExactDuplicateFinder(
                checker: server,
                resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
                index: store, identities: store, journal: journal,
                mergeJournal: ExactDuplicateMergeJournalFileStore(accountDataDirectory: folder),
                remote: BeforeTrashRemote(base: server) { await barrier.arrive() }, albums: server)
            finders.append(finder)
            rows.append((store, source))
        }

        let outcomes = await withTaskGroup(of: Result<ExactDuplicateMergeOutcome, any Error>.self) { tasks in
            for finder in finders {
                tasks.addTask {
                    await finder.merge([ExactDuplicateMergeRequest(group: group, kept: kept, isKeptChosen: true)])[0]
                }
            }
            var outcomes: [Result<ExactDuplicateMergeOutcome, any Error>] = []
            for await outcome in tasks { outcomes.append(outcome) }
            return outcomes
        }

        XCTAssertEqual(
            outcomes.map { try? $0.get() },
            Array(repeating: .merged(kept: kept, trashed: duplicates, keptDuplicates: [:]), count: deviceCount))
        XCTAssertEqual(server.links.filter { $0.state == .active }.map(\.uid), [kept], "exactly one copy stays")
        XCTAssertEqual(trashCalls.count, deviceCount, "every device sent its trash")
        XCTAssertEqual(restores, [])
        for row in rows {
            XCTAssertEqual(row.store.record(for: row.source)?.remoteLinkID, kept.nodeID)
        }
        XCTAssertEqual(violations, [])
    }

    func testATrashThatLeavesADuplicateInTheLibraryStillReportsTheFailure() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let moved = server.seedLink(digest: digest("a"))
        let left = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        server.failNextTrash(leaving: left.nodeID)

        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("A duplicate stayed in the library, so a retry has to merge it")
        } catch {}

        XCTAssertEqual(state(of: kept), .active)
        XCTAssertEqual(state(of: moved), .trashed)
        XCTAssertEqual(state(of: left), .active)
        XCTAssertEqual(restores, [])
        let retry = try await finder.merge(group, keeping: kept)
        XCTAssertEqual(retry, .merged(kept: kept, trashed: [left], keptDuplicates: [:]))
        XCTAssertEqual(violations, [])
    }

    func testTheNextScanRestoresTheDuplicateWhenTheProcessEndedBetweenTheTrashAndItsCheck() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        let keptSource = row("asset-2", names: kept.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        server.trashAfterDuplicateTrash = kept.nodeID
        let stopping = TrashStoppingRemote(base: server)
        let first = finder(remote: stopping)
        let requests = chosen([(group, kept)])
        let merge = Task { await first.merge(requests) }
        for _ in 0..<5_000 {
            if await stopping.gate.hasWaiters { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stopped = await stopping.gate.hasWaiters
        XCTAssertTrue(stopped, "the trash moved the photos")
        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(state(of: kept), .trashed)

        // The process ends here. The next launch reads the same files with a new finder.
        _ = try await finder().duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .active, "one copy stays")
        XCTAssertEqual(state(of: kept), .trashed)
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the row moves back")
        XCTAssertEqual(store.record(for: keptSource)?.remoteLinkID, duplicate.nodeID, "no row names a trashed photo")
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        stopping.gate.open()
        _ = await merge.value
        XCTAssertEqual(state(of: duplicate), .active)
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID)
        XCTAssertEqual(violations, [])
    }

    func testTheNextScanRestoresTheDuplicateWhenEveryReadOfTheKeptPhotoAfterTheTrashFailed() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        server.trashAfterDuplicateTrash = kept.nodeID
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts
        var finder = finder()
        finder.keptReadRetryDelay = .zero

        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("The merge cannot tell whether the kept photo stayed")
        } catch {}
        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(state(of: kept), .trashed)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .active, "one copy stays")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the row moves back")
        let stepsBefore = server.steps.count
        _ = try await finder.duplicateGroups()
        XCTAssertEqual(server.steps.count, stepsBefore, "the resolved merge is no longer pending")
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(violations, [])
    }

    func testARestoreWhoseAnswerFailsAfterItMovedTheDuplicateBackStillMovesTheRowsBack() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset-1", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let group = try await onlyGroup()
        server.trashAfterDuplicateTrash = kept.nodeID
        server.applyNextRestoreThenFail()

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .skipped(.keptLeftLibraryDuringMerge))
        XCTAssertEqual(state(of: duplicate), .active, "one copy stays")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, duplicate.nodeID, "the row moves back")
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeRestoresAKeptPhotoTrashedAtTheMergeAndLeavesOneTrashedLongAfter() async throws {
        let keptA = server.seedLink(digest: digest("a"))
        let duplicateA = server.seedLink(digest: digest("a"))
        let keptB = server.seedLink(digest: digest("b"))
        _ = server.seedLink(digest: digest("b"))
        let source = row("asset-1", names: duplicateA.nodeID, contentHash: hash("a"))
        indexServer()
        let groups = try await finder.duplicateGroups().groups
        XCTAssertEqual(groups.count, 2)
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        let results = await finder.merge(chosen(groups.map { ($0, $0.members.contains(keptA) ? keptA : keptB) }))
        XCTAssertTrue(
            results.allSatisfy { (try? $0.get()) == nil }, "the merge cannot tell whether the kept photos stayed")
        // The person empties the trash, so the server no longer knows the trashed duplicates. Another device trashes
        // the first kept photo at the time of the merge; the person deletes the second one long after it.
        server.personEmptyTrash()
        server.personTrash(keptA)
        server.serverTime += 2 * ExactDuplicateFinder.deviceClockTrashWindow
        server.personTrash(keptB)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: keptA), .active, "the last copy comes back")
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, keptA.nodeID, "the row names the active copy")
        XCTAssertEqual(state(of: keptB), .trashed, "the person's later deletion stays")
        XCTAssertEqual(restores, ["person restore \(keptA.nodeID)"])
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    func testAPendingMergeWhosePhotosAllLeftTheServerEndsItsCheck() async throws {
        let kept = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("The merge cannot tell whether the kept photo stayed")
        } catch {}
        // The person deletes the kept photo and empties the trash: the server knows no photo of the merge anymore.
        server.personTrash(kept)
        server.personEmptyTrash()

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(mergeJournal.pendingMerges(), [], "the check ends")
        XCTAssertEqual(restores, [])
    }

    func testAnOfflineScanWaitsForOneReadOfEveryPendingMerge() async throws {
        var intents: [ExactDuplicateMergeIntent] = []
        for seed in ["a", "b", "c"] {
            let kept = server.seedLink(digest: digest(seed))
            let duplicate = server.seedLink(digest: digest(seed))
            intents.append(
                ExactDuplicateMergeIntent(
                    volumeID: "vol", kept: kept.nodeID, contentHash: hash(seed), hashKeyEpoch: epoch,
                    members: [.init(link: duplicate.nodeID, moves: [])], trashedAt: nil))
        }
        indexServer()
        // The app ended during a merge of three groups, before their check.
        XCTAssertTrue(mergeJournal.record(intents))
        server.configureOptionalReads(visibilityFails: true)
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        let readsBefore = server.readCounts.visibility

        do {
            _ = try await finder.duplicateGroups()
            XCTFail("The scan cannot read the library offline")
        } catch {}

        XCTAssertEqual(
            server.readCounts.visibility - readsBefore, ExactDuplicateFinder.keptReadAttempts + 1,
            "one read of every pending merge with its retries, then the read of the scan")
        XCTAssertEqual(mergeJournal.pendingMerges()?.count, 3, "the merges wait for the next scan")
    }

    func testAMergeMovesAnUnreadableJournalAsideAndStartsANewOne() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        let damaged = Data("not a journal".utf8)
        try damaged.write(to: directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName))

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix("exact-duplicate-merge-intents-v1.unreadable-")
        }
        XCTAssertEqual(aside.count, 1, "the damaged file stays for diagnostics")
        XCTAssertEqual(try aside.first.map { try Data(contentsOf: directory.appendingPathComponent($0)) }, damaged)
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeLeavesAKeptPhotoThatThePersonTrashedLongAfterTheMerge() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("The merge cannot tell whether the kept photo stayed")
        } catch {}
        server.serverTime += 2 * 3600
        server.personTrash(kept)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: kept), .trashed, "the person's deletion stays")
        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(restores, [])
    }

    /// A merge whose check failed, so it waits in the journal. Within the window, another device trashes the kept
    /// photo, after it uploaded `edit` with a lineage marker that names the kept photo, unless `editedBeforeMerge`
    /// uploaded the edit while the kept photo was in the library. The edit holds a related file for each of
    /// `editFiles`. With `withVideo`, both copies carry the same video.
    private func pendingMergeReplacedByEdit(
        editFiles: [String], withVideo: Bool = false, editedBeforeMerge: Bool = false,
        incompleteLineageAtMerge: Bool = false
    ) async throws -> (kept: PhotoUID, duplicate: PhotoUID, edit: PhotoUID, finder: ExactDuplicateFinder) {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        if withVideo {
            for main in [kept, duplicate] { _ = server.seedLink(digest: digest("video"), main: main) }
        }
        func uploadEdit() -> PhotoUID {
            let edit = server.seedLink(digest: digest("a edited"))
            for file in editFiles { _ = server.seedLink(digest: digest(file), main: edit) }
            server.markReplaces([kept.nodeID], by: edit)
            return edit
        }
        let earlierEdit = editedBeforeMerge ? uploadEdit() : nil
        indexServer()
        let group = try await onlyGroup()
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts
        var finder = finder()
        finder.keptReadRetryDelay = .zero
        if incompleteLineageAtMerge { server.configureLineageIndex(incomplete: .successors) }
        do {
            _ = try await finder.merge(group, keeping: kept)
            XCTFail("The merge cannot tell whether the kept photo stayed")
        } catch {}
        server.configureLineageIndex()
        let edit = earlierEdit ?? uploadEdit()
        server.personTrash(kept)
        return (kept, duplicate, edit, finder)
    }

    func testAPendingMergeLeavesTheDuplicateInTheTrashWhenAnEditReplacedTheKeptPhoto() async throws {
        let (kept, duplicate, edit, finder) = try await pendingMergeReplacedByEdit(editFiles: ["a"])

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .trashed, "no unedited copy returns next to the edit")
        XCTAssertEqual(state(of: kept), .trashed)
        XCTAssertEqual(state(of: edit), .active)
        XCTAssertEqual(restores, [])
        XCTAssertEqual(mergeJournal.pendingMerges(), [], "the check ends")
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeLeavesTheDuplicateInTheTrashWhenTheEditHoldsEveryFileOfIt() async throws {
        let (_, duplicate, _, finder) = try await pendingMergeReplacedByEdit(
            editFiles: ["a", "video"], withVideo: true)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(restores, [])
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeRestoresTheDuplicateWhenTheReplacementLacksTheBytesOfTheGroup() async throws {
        try await assertRestoresTheDuplicate(editFiles: ["a earlier edit"], withVideo: false)
    }

    func testAPendingMergeRestoresTheDuplicateWhenTheEditLacksTheVideoOfIt() async throws {
        try await assertRestoresTheDuplicate(editFiles: ["a"], withVideo: true)
    }

    private func assertRestoresTheDuplicate(
        editFiles: [String], withVideo: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let (_, duplicate, _, finder) = try await pendingMergeReplacedByEdit(
            editFiles: editFiles, withVideo: withVideo)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(
            state(of: duplicate), .active, "one copy of every file stays in the library", file: file, line: line)
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"], file: file, line: line)
        XCTAssertEqual(mergeJournal.pendingMerges(), [], file: file, line: line)
        XCTAssertEqual(violations, [], file: file, line: line)
    }

    func testAPendingMergeRestoresTheDuplicateWhenTheEditReplacedTheKeptPhotoBeforeTheMerge() async throws {
        // The person edited the photo, restored the earlier version, and merged it with its copy. Another device kept
        // the copy and trashed the earlier version at the same moment.
        let (kept, duplicate, _, finder) = try await pendingMergeReplacedByEdit(
            editFiles: ["a"], editedBeforeMerge: true)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .active, "an edit that predates the merge proves nothing")
        XCTAssertEqual(state(of: kept), .trashed)
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeRestoresTheDuplicateWhenTheLineageIndexWasIncompleteAtTheMerge() async throws {
        // An incomplete index could miss an edit that predates the merge, so no later edit proves anything.
        let (_, duplicate, _, finder) = try await pendingMergeReplacedByEdit(
            editFiles: ["a"], incompleteLineageAtMerge: true)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .active)
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeRestoresTheDuplicateWhenTheLineageReadFails() async throws {
        let (_, duplicate, _, finder) = try await pendingMergeReplacedByEdit(editFiles: ["a"])
        server.configureLineageIndex(failing: true)

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .active, "a read that proves nothing restores a copy")
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
        XCTAssertEqual(violations, [])
    }

    func testAPendingMergeWaitsWhenTheConnectionFailsDuringTheEditCheck() async throws {
        let (_, duplicate, _, finder) = try await pendingMergeReplacedByEdit(editFiles: ["a"])
        server.configureLineageIndex(failing: true, error: URLError(.notConnectedToInternet))

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicate), .trashed)
        XCTAssertEqual(restores, [], "no restore without a connection")
        XCTAssertEqual(mergeJournal.pendingMerges()?.count, 1, "the merge waits for the next check")
        XCTAssertEqual(violations, [])
    }

    /// A pending merge of `kept` and `duplicate`, recorded at the device time `trashedAt`.
    private func pendingIntent(
        kept: PhotoUID, duplicate: PhotoUID, seed: String, trashedAt: Int64?
    ) -> ExactDuplicateMergeIntent {
        ExactDuplicateMergeIntent(
            volumeID: "vol", kept: kept.nodeID, contentHash: hash(seed), hashKeyEpoch: epoch,
            members: [
                .init(
                    link: duplicate.nodeID,
                    moves: [.init(from: duplicate.nodeID, to: kept.nodeID, contentHash: hash(seed))])
            ],
            trashedAt: trashedAt)
    }

    func testAPendingMergeWhoseRestoreIsRefusedLeavesTheNextMergeChecked() async throws {
        let keptA = server.seedLink(digest: digest("a"))
        let duplicateA = server.seedLink(digest: digest("a"))
        let keptB = server.seedLink(digest: digest("b"))
        let duplicateB = server.seedLink(digest: digest("b"))
        indexServer()
        // Both merges trashed their duplicate, and another device trashed both kept photos at the same moment.
        for link in [duplicateA, keptA, duplicateB, keptB] { server.personTrash(link) }
        let first = pendingIntent(kept: keptA, duplicate: duplicateA, seed: "a", trashedAt: server.serverTime)
        let second = pendingIntent(kept: keptB, duplicate: duplicateB, seed: "b", trashedAt: server.serverTime)
        XCTAssertTrue(mergeJournal.record([first, second]))
        server.refusedRestores = [duplicateA.nodeID, keptA.nodeID]
        var finder = finder()
        finder.keptReadRetryDelay = .zero

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(state(of: duplicateB), .active, "the second merge restores its duplicate")
        XCTAssertEqual(state(of: keptA), .trashed)
        XCTAssertEqual(mergeJournal.pendingMerges(), [first], "the refused merge waits for the next scan")
    }

    /// The check at the account start and the check at the start of a scan can begin together. The second waits for the
    /// first, so only one of them restores the duplicate of an open merge.
    func testTwoPendingMergeChecksRunOneAfterTheOther() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        // The merge trashed its duplicate, and another device trashed the kept photo at the same moment.
        for link in [duplicate, kept] { server.personTrash(link) }
        XCTAssertTrue(
            mergeJournal.record([
                pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: server.serverTime)
            ]))
        let remote = RestoreGatedRemote(base: server)
        let finder = finder(remote: remote)
        let first = Task { await finder.resolvePendingMerges() }
        try await waitUntil { remote.arrivals == 1 }
        let readsBefore = server.readCounts.visibility

        let second = Task { await finder.resolvePendingMerges() }
        // A second check that does not wait reads the open merge and restores the duplicate again.
        try await waitUntil { finder.pendingChecks.waiting == 1 }
        XCTAssertEqual(server.readCounts.visibility, readsBefore, "the second check waits for the first")
        remote.gate.open()
        await first.value
        await second.value

        XCTAssertEqual(remote.arrivals, 1, "one check restores the duplicate")
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(state(of: duplicate), .active)
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    /// A check that waits for another check ends without a read when its task is cancelled, for example at sign-out.
    func testACancelledPendingMergeCheckStopsWaitingForTheRunningOne() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        for link in [duplicate, kept] { server.personTrash(link) }
        XCTAssertTrue(
            mergeJournal.record([
                pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: server.serverTime)
            ]))
        let remote = RestoreGatedRemote(base: server)
        let finder = finder(remote: remote)
        let first = Task { await finder.resolvePendingMerges() }
        try await waitUntil { remote.arrivals == 1 }
        let readsBefore = server.readCounts.visibility
        let second = Task { await finder.resolvePendingMerges() }
        let ended = EndFlag()
        Task {
            await second.value
            ended.set()
        }
        try await waitUntil { finder.pendingChecks.waiting == 1 }

        second.cancel()
        try await waitUntil { ended.isSet }
        // A check whose task was cancelled before it reached the queue does not wait either.
        let cancelledEarly = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await finder.resolvePendingMerges()
        }
        let endedEarly = EndFlag()
        Task {
            await cancelledEarly.value
            endedEarly.set()
        }
        try await waitUntil { endedEarly.isSet }

        XCTAssertEqual(finder.pendingChecks.waiting, 0)
        XCTAssertEqual(server.readCounts.visibility, readsBefore, "the cancelled checks read nothing")
        remote.gate.open()
        await first.value
        XCTAssertEqual(remote.arrivals, 1)
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    /// Waits up to five seconds for `condition`, so a missing event fails the test instead of hanging it.
    private func waitUntil(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "the condition did not become true", file: file, line: line)
    }

    func testLateJournalWritesCannotRecreateAPurgedAccountDirectory() throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let intent = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: nil)
        let retained = mergeJournal
        XCTAssertTrue(retained.record([intent]))
        XCTAssertEqual(retained.prepareForWrites(), .ready)
        // A merge can hold this journal across an asynchronous read after prepareForWrites.
        // The production purge removes the whole account root after its stores have closed.
        store = nil
        let purge = BackupLocalDataPurge.purgeAllLocalAccountData(roots: [directory])
        XCTAssertTrue(purge.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        XCTAssertFalse(retained.record([intent]), "A late record cannot create its missing parent directory")
        XCTAssertTrue(retained.clear([intent]))
        XCTAssertEqual(retained.prepareForWrites(), .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAJournalThatCannotBeReadStaysAndTakesNoWrite() throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let pending = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: nil)
        XCTAssertTrue(mergeJournal.record([pending]))
        let file = directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName)
        let saved = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let other = pendingIntent(kept: duplicate, duplicate: kept, seed: "a", trashedAt: nil)

        XCTAssertEqual(mergeJournal.prepareForWrites(), .unavailable)
        XCTAssertNil(mergeJournal.pendingMerges())
        XCTAssertFalse(mergeJournal.record([other]))
        XCTAssertFalse(mergeJournal.clear([pending]))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), saved, "the pending merge stays in its file")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                $0.hasPrefix("exact-duplicate-merge-intents-v1.unreadable-")
            }, [], "nothing moved aside")
    }

    func testADeviceClockHoursOffStillRestoresTheLastCopyOfAConcurrentTrash() async throws {
        var pending: [(kept: PhotoUID, intent: ExactDuplicateMergeIntent)] = []
        for (seed, offset) in [("a", -2 * Int64(3600)), ("b", 2 * Int64(3600))] {
            let kept = server.seedLink(digest: digest(seed))
            let duplicate = server.seedLink(digest: digest(seed))
            let intent = pendingIntent(
                kept: kept, duplicate: duplicate, seed: seed, trashedAt: server.serverTime + offset)
            pending.append((kept, intent))
        }
        indexServer()
        // The merges trashed their duplicates, and the person emptied the trash: the server no longer knows them.
        // Another device trashed each kept photo at the moment of the merge, by server time.
        for (_, intent) in pending { server.personTrash(PhotoUID(volumeID: "vol", nodeID: intent.members[0].link)) }
        server.personEmptyTrash()
        for (kept, _) in pending { server.personTrash(kept) }
        XCTAssertTrue(mergeJournal.record(pending.map(\.intent)))

        _ = try await finder.duplicateGroups()

        for (kept, _) in pending {
            XCTAssertEqual(state(of: kept), .active, "the last copy comes back, whichever way the device clock is off")
        }
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    func testAStaleTrashTimeOfADuplicateInTheLibraryDatesNoMerge() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let restoredDuplicate = server.seedLink(digest: digest("a"))
        let purgedDuplicate = server.seedLink(digest: digest("a"))
        indexServer()
        // The person trashed and restored one duplicate long before the merge; its visibility keeps that trash time.
        server.reportsTrashTimeOfRestoredLinks = true
        server.serverTime -= 2 * ExactDuplicateFinder.deviceClockTrashWindow
        server.personTrash(restoredDuplicate)
        server.personRestore(restoredDuplicate)
        server.serverTime += 2 * ExactDuplicateFinder.deviceClockTrashWindow
        // The merge trashed the other duplicate, which left the trash; the trash of the restored one failed. Another
        // device trashed the kept photo at the same moment.
        server.personTrash(purgedDuplicate)
        server.personEmptyTrash()
        server.personTrash(kept)
        let moves = [restoredDuplicate, purgedDuplicate].map {
            UploadRemoteLinkMove(from: $0.nodeID, to: kept.nodeID, contentHash: hash("a"))
        }
        let intent = ExactDuplicateMergeIntent(
            volumeID: "vol", kept: kept.nodeID, contentHash: hash("a"), hashKeyEpoch: epoch,
            members: [
                .init(link: purgedDuplicate.nodeID, moves: [moves[1]]),
                .init(link: restoredDuplicate.nodeID, moves: [moves[0]]),
            ],
            trashedAt: server.serverTime)
        XCTAssertTrue(mergeJournal.record([intent]))
        // The row of the restored duplicate moved to the kept photo before the trash.
        let source = row("asset-1", names: kept.nodeID, contentHash: hash("a"))

        _ = try await finder.duplicateGroups()

        XCTAssertEqual(
            store.record(for: source)?.remoteLinkID, restoredDuplicate.nodeID,
            "the row moves to the duplicate in the library, not to the trashed kept photo")
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    /// The restores of the merge.
    private var restores: [String] {
        server.steps.map(\.action).filter { $0.hasPrefix("person restore") }
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

        let results = await finder.merge(chosen(groups.map { ($0, $0.members[0]) }))

        XCTAssertEqual(
            results.map { try? $0.get() },
            groups.map { .merged(kept: $0.members[0], trashed: [$0.members[1]], keptDuplicates: [:]) })
        XCTAssertEqual(identities.reads, CountingIdentityStore.Reads(single: 0, batch: 1))
        let reads = server.readCounts
        XCTAssertEqual(reads.favorites - readsBefore.favorites, 1)
        XCTAssertEqual(
            reads.visibility - readsBefore.visibility, groups.count + 1,
            "each group reads its members, and one read after the trash takes every kept photo")
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

        let results = await finder(resolver: resolver).merge(chosen(groups.map { ($0, $0.members[0]) }))

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

        let results = await finder(resolver: resolver).merge(chosen(groups.map { ($0, $0.members[0]) }))

        for (index, group) in groups.enumerated() {
            XCTAssertThrowsError(try results[index].get())
            XCTAssertEqual(state(of: group.members[1]), .active, "the failed trash moved nothing")
            XCTAssertEqual(
                store.record(for: sources[index])?.remoteLinkID, group.members[0].nodeID,
                "the moved row names the kept photo, which holds the same bytes")
        }
        XCTAssertEqual(invalidations(in: log), 1)
        let movedRows = sources.map { store.record(for: $0) }

        let retry = await finder(resolver: resolver).merge(chosen(groups.map { ($0, $0.members[0]) }))

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

        let results = await finder(resolver: resolver).merge(chosen(groups.map { ($0, $0.members[0]) }))

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

    func testAFailedTrashOfManyGroupsRestoresOnlyTheGroupWhoseKeptPhotoLeftTheLibrary() async throws {
        let (groups, sources) = try await threeGroups()
        // Another device keeps the duplicate of the second group and trashes its kept photo meanwhile. The trash of
        // this device moves every duplicate, and its answer fails.
        server.trashAfterDuplicateTrash = groups[1].members[0].nodeID
        server.applyNextTrashThenFail()

        let results = await finder.merge(chosen(groups.map { ($0, $0.members[0]) }))

        XCTAssertEqual(try? results[1].get(), .skipped(.keptLeftLibraryDuringMerge))
        XCTAssertEqual(state(of: groups[1].members[1]), .active, "one copy stays")
        XCTAssertEqual(store.record(for: sources[1])?.remoteLinkID, groups[1].members[1].nodeID, "the row moves back")
        for index in [0, 2] {
            XCTAssertEqual(
                try? results[index].get(),
                .merged(kept: groups[index].members[0], trashed: [groups[index].members[1]], keptDuplicates: [:]))
            XCTAssertEqual(state(of: groups[index].members[0]), .active)
            XCTAssertEqual(state(of: groups[index].members[1]), .trashed)
        }
        XCTAssertEqual(restores, ["person restore \(groups[1].members[1].nodeID)"])
        XCTAssertEqual(mergeJournal.pendingMerges(), [], "every group was checked")
        XCTAssertEqual(violations, [])
    }

    func testACancelledTrashOfManyGroupsRestoresTheGroupWhoseKeptPhotoLeftTheLibraryAtTheNextCheck() async throws {
        let (groups, sources) = try await threeGroups()
        server.trashAfterDuplicateTrash = groups[1].members[0].nodeID
        let stopping = TrashStoppingRemote(base: server, throwsWhenCancelled: true)
        let first = finder(remote: stopping)
        let requests = chosen(groups.map { ($0, $0.members[0]) })
        let merge = Task { await first.merge(requests) }
        for _ in 0..<5_000 {
            if await stopping.gate.hasWaiters { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stopped = await stopping.gate.hasWaiters
        XCTAssertTrue(stopped, "the trash moved the photos")
        // The merge is cancelled while its trash runs, so its answer and every read after it end.
        merge.cancel()
        stopping.gate.open()
        let results = await merge.value
        XCTAssertTrue(results.allSatisfy { (try? $0.get()) == nil }, "no group knows its outcome")
        XCTAssertEqual(restores, [], "no check ran")
        XCTAssertEqual(mergeJournal.pendingMerges()?.count, groups.count, "every group waits for its check")

        _ = try await finder().duplicateGroups()

        XCTAssertEqual(state(of: groups[1].members[1]), .active, "one copy stays")
        XCTAssertEqual(store.record(for: sources[1])?.remoteLinkID, groups[1].members[1].nodeID, "the row moves back")
        for index in [0, 2] {
            XCTAssertEqual(state(of: groups[index].members[0]), .active)
            XCTAssertEqual(state(of: groups[index].members[1]), .trashed, "the merge of this group stands")
        }
        XCTAssertEqual(restores, ["person restore \(groups[1].members[1].nodeID)"])
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
        XCTAssertEqual(violations, [])
    }

    /// The check that both apps start when they install an account, on macOS also without a library window.
    @MainActor
    func testTheAccountCheckRestoresAnOpenMergeWithoutDuplicatesAndReadsNothingWithoutOne() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let lifetime = ExactDuplicatesAccountLifetime()
        let readsBefore = server.readCounts

        await lifetime.checkPendingMerges(of: finder)?.value

        XCTAssertEqual(server.readCounts, readsBefore, "no open merge, no read")
        // The app ended between the trash and its check, and another device trashed the kept photo meanwhile.
        server.personTrash(duplicate)
        server.personTrash(kept)
        let intent = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: server.serverTime)
        XCTAssertTrue(mergeJournal.record([intent]))

        // The next account start checks again; no Duplicates screen or model exists.
        await lifetime.checkPendingMerges(of: finder)?.value

        XCTAssertEqual(state(of: duplicate), .active, "one copy comes back before the person opens Duplicates")
        XCTAssertEqual(restores, ["person restore \(duplicate.nodeID)"])
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
        XCTAssertEqual(server.readCounts.favorites, readsBefore.favorites, "no scan and no ranking")
    }

    // MARK: - Empty Recently Deleted

    func testEmptyingTheTrashFirstRestoresAnOpenMergeWhoseKeptPhotoLeftTheLibrary() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        // The app ended between the trash and its check, and another device trashed the kept photo meanwhile.
        server.personTrash(duplicate)
        server.personTrash(kept)
        let intent = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: server.serverTime)
        XCTAssertTrue(mergeJournal.record([intent]))

        let confirmed = await finder.confirmNoPendingMerges()

        XCTAssertTrue(confirmed)
        XCTAssertEqual(state(of: duplicate), .active, "one copy is back before the trash is emptied")
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    func testEmptyingTheTrashWaitsWhileAnOpenMergeCannotBeChecked() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let intent = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: server.serverTime)
        XCTAssertTrue(mergeJournal.record([intent]))
        server.configureOptionalReads(visibilityFails: true)
        var finder = finder
        finder.keptReadRetryDelay = .zero

        let confirmed = await finder.confirmNoPendingMerges()

        XCTAssertFalse(confirmed, "the trash can hold the last copy of the group")
        XCTAssertEqual(mergeJournal.pendingMerges(), [intent], "the merge waits for its next check")
    }

    func testEmptyingTheTrashReadsNothingWithoutAnOpenMerge() async {
        _ = server.seedLink(digest: digest("a"))
        let readsBefore = server.readCounts

        let confirmed = await finder.confirmNoPendingMerges()

        XCTAssertTrue(confirmed)
        XCTAssertEqual(server.readCounts, readsBefore, "no open merge, no read")
    }

    func testEmptyingTheTrashWaitsOnceForADamagedMergeJournal() async throws {
        try Data("not a journal".utf8).write(
            to: directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName))

        let confirmed = await finder.confirmNoPendingMerges()

        XCTAssertFalse(confirmed, "the attempt that finds a damaged journal keeps the trash")
    }

    func testTheSharedEmptyStepEmptiesOnlyAfterTheMergeCheck() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let trash = CountingTrash()
        try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
        try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: nil, accountDataDirectory: directory)
        XCTAssertEqual(trash.emptied, 2, "without an open merge, and without Duplicates, the trash is emptied")

        let intent = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: server.serverTime)
        XCTAssertTrue(mergeJournal.record([intent]))
        server.configureOptionalReads(visibilityFails: true)
        var finder = finder
        finder.keptReadRetryDelay = .zero
        do {
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
            XCTFail("an open merge that cannot be checked keeps the trash")
        } catch {
            XCTAssertTrue(error is RecentlyDeletedEmptying.PendingMergeCheck)
        }
        XCTAssertEqual(trash.emptied, 2, "nothing was deleted")
    }

    /// The account's upload stores did not open, so no merger exists. The journal of an earlier session still counts.
    func testTheSharedEmptyStepReadsTheMergeJournalWhenNoMergerExists() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let trash = CountingTrash()
        XCTAssertTrue(mergeJournal.record([pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: 100)]))

        await assertKeepsTheTrash(
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: nil, accountDataDirectory: directory))
        XCTAssertEqual(trash.emptied, 0, "an open merge keeps the trash")

        XCTAssertTrue(mergeJournal.clear(mergeJournal.pendingMerges() ?? []))
        try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: nil, accountDataDirectory: directory)
        XCTAssertEqual(trash.emptied, 1, "without an open merge the trash is emptied")
    }

    /// A merge that trashed its copies while Recently Deleted is emptied would lose them for good before their check.
    func testAMergeWaitsWhileRecentlyDeletedIsEmptied() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        let finder = finder
        let trash = GatedServerTrash(server: server)
        let emptying = Task { [directory] in
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
        }
        try await waitUntil { trash.arrivals == 1 }

        let merging = Task { try await finder.merge(group, keeping: kept) }
        try await waitUntil { finder.mergeTurns.waiting == 1 }
        XCTAssertEqual(state(of: duplicate), .active, "the merge trashes nothing while the trash is emptied")
        trash.gate.open()
        try await emptying.value
        let outcome = try await merging.value

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(state(of: duplicate), .trashed, "the merged copy stays in Recently Deleted")
        XCTAssertEqual(state(of: kept), .active)
    }

    /// Emptying Recently Deleted waits for a running merge and then empties, instead of failing on its open record.
    func testEmptyingRecentlyDeletedWaitsForARunningMerge() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        let remote = TrashStoppingRemote(base: server)
        let finder = finder(remote: remote)
        let merging = Task { try await finder.merge(group, keeping: kept) }
        // The merge recorded its trash and holds before the check of its kept photo.
        try await waitUntil { state(of: duplicate) == .trashed }
        let trash = CountingTrash()

        let emptying = Task { [directory] in
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
        }
        try await waitUntil { finder.mergeTurns.waiting == 1 }
        XCTAssertEqual(trash.emptied, 0, "the trash is not emptied while the merge runs")
        remote.gate.open()
        let outcome = try await merging.value
        try await emptying.value

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
        XCTAssertEqual(trash.emptied, 1, "the trash is emptied after the merge checked its kept photo")
    }

    /// An emptying that waits for a merge and is cancelled deletes nothing.
    func testACancelledEmptyingThatWaitsForAMergeDeletesNothing() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        let remote = TrashStoppingRemote(base: server)
        let finder = finder(remote: remote)
        let merging = Task { try await finder.merge(group, keeping: kept) }
        try await waitUntil { state(of: duplicate) == .trashed }
        let trash = CountingTrash()
        let emptying = Task { [directory] in
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
        }
        try await waitUntil { finder.mergeTurns.waiting == 1 }

        emptying.cancel()
        // The cancelled emptying leaves the queue at once; the merge is released only afterwards, so a waiter that
        // stayed would fail the checks below instead of hanging the test.
        try await waitUntil { finder.mergeTurns.waiting == 0 }
        remote.gate.open()
        do {
            try await emptying.value
            XCTFail("a cancelled emptying throws")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await merging.value

        XCTAssertEqual(trash.emptied, 0)
        XCTAssertEqual(finder.mergeTurns.waiting, 0)
    }

    /// An emptying whose task is cancelled exactly as the merge hands the turn over deletes nothing.
    func testAnEmptyingCancelledAsTheTurnPassesToItDeletesNothing() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        let remote = TrashStoppingRemote(base: server)
        let finder = finder(remote: remote)
        let merging = Task { try await finder.merge(group, keeping: kept) }
        try await waitUntil { state(of: duplicate) == .trashed }
        let trash = CountingTrash()
        let emptying = Task { [directory] in
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
        }
        try await waitUntil { finder.mergeTurns.waiting == 1 }
        // The merge leaves the queue and hands the turn over; the cancellation lands before the emptying resumes.
        finder.mergeTurns.onHandOver = { emptying.cancel() }

        remote.gate.open()
        _ = try await merging.value
        do {
            try await emptying.value
            XCTFail("a cancelled emptying throws")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(trash.emptied, 0, "a cancelled emptying deletes nothing")
        XCTAssertEqual(finder.mergeTurns.waiting, 0)
    }

    /// A merge that is cancelled while Recently Deleted is emptied trashes nothing.
    func testAMergeCancelledWhileRecentlyDeletedIsEmptiedTrashesNothing() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        let finder = finder
        let trash = GatedServerTrash(server: server)
        let emptying = Task { [directory] in
            try await RecentlyDeletedEmptying.empty(trash, checkingMergesWith: finder, accountDataDirectory: directory)
        }
        try await waitUntil { trash.arrivals == 1 }
        let merging = Task { try await finder.merge(group, keeping: kept) }
        try await waitUntil { finder.mergeTurns.waiting == 1 }

        merging.cancel()
        try await waitUntil { finder.mergeTurns.waiting == 0 }
        trash.gate.open()
        try await emptying.value
        do {
            _ = try await merging.value
            XCTFail("a cancelled merge throws")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(state(of: duplicate), .active, "the cancelled merge trashes nothing")
        XCTAssertEqual(state(of: kept), .active)
    }

    func testADamagedMergeJournalBlocksOneEmptyAndMovesAside() async throws {
        for merger in [true, false] {
            let trash = CountingTrash()
            let damaged = Data("not a journal".utf8)
            try damaged.write(to: directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName))
            let duplicates: (any ExactDuplicateMerging)? = merger ? finder : nil

            await assertKeepsTheTrash(
                try await RecentlyDeletedEmptying.empty(
                    trash, checkingMergesWith: duplicates, accountDataDirectory: directory))
            XCTAssertEqual(trash.emptied, 0, "the attempt that finds the damaged file deletes nothing")
            let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                $0.hasPrefix("exact-duplicate-merge-intents-v1.unreadable-")
            }
            XCTAssertEqual(aside.count, 1, "the damaged file stays for diagnostics, merger: \(merger)")
            XCTAssertEqual(try aside.first.map { try Data(contentsOf: directory.appendingPathComponent($0)) }, damaged)

            try await RecentlyDeletedEmptying.empty(
                trash, checkingMergesWith: duplicates, accountDataDirectory: directory)
            XCTAssertEqual(trash.emptied, 1, "the next attempt empties, merger: \(merger)")
            for name in aside { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }

    func testAMergeJournalThatCannotBeReadKeepsTheTrashEveryTime() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a file without read permission")
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        XCTAssertTrue(mergeJournal.record([pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: 100)]))
        let file = directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName)
        let saved = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let trash = CountingTrash()

        for merger in [true, false, true] {
            await assertKeepsTheTrash(
                try await RecentlyDeletedEmptying.empty(
                    trash, checkingMergesWith: merger ? finder : nil, accountDataDirectory: directory))
        }

        XCTAssertEqual(trash.emptied, 0, "a file that cannot be read can hold open merges")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), saved, "the file stays where it is")
    }

    private func assertKeepsTheTrash(
        _ expression: @autoclosure () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("no error was thrown", file: file, line: line)
        } catch {
            XCTAssertTrue(error is RecentlyDeletedEmptying.PendingMergeCheck, file: file, line: line)
        }
    }

    @MainActor
    func testTheAccountCheckEndsWithTheAccountButNotWithANewDuplicatesModel() {
        let lifetime = ExactDuplicatesAccountLifetime()
        let check = lifetime.checkPendingMerges(of: finder)
        XCTAssertNotNil(check)

        // The Mac library window builds the Duplicates model of the same account after the account start.
        _ = lifetime.replace(with: finder)
        XCTAssertEqual(check?.isCancelled, false, "a new Duplicates model keeps the account check")

        // A sign-out or a new account ends the check of the earlier account.
        XCTAssertNil(lifetime.checkPendingMerges(of: nil))
        XCTAssertEqual(check?.isCancelled, true)
    }

    /// A check clears only the record that it read: a newer merge of the same group keeps its record for its own check.
    func testAJournalClearKeepsANewerRecordOfTheSameGroup() throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let read = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: 100)
        XCTAssertTrue(mergeJournal.record([read]))
        let checked = try XCTUnwrap(mergeJournal.pendingMerges())
        XCTAssertEqual(checked, [read])

        let newer = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: 200)
        XCTAssertTrue(mergeJournal.record([newer]))
        XCTAssertTrue(mergeJournal.clear(checked))

        XCTAssertEqual(mergeJournal.pendingMerges(), [newer], "the newer merge still waits for its check")
        XCTAssertTrue(mergeJournal.clear([newer]))
        XCTAssertEqual(mergeJournal.pendingMerges(), [])
    }

    /// Merge All records one trash time for every group of a batch. Clearing one group keeps the other groups' records.
    func testAJournalClearKeepsTheOtherGroupsOfTheSameBatch() throws {
        let keptA = server.seedLink(digest: digest("a"))
        let duplicateA = server.seedLink(digest: digest("a"))
        let keptB = server.seedLink(digest: digest("b"))
        let duplicateB = server.seedLink(digest: digest("b"))
        let first = pendingIntent(kept: keptA, duplicate: duplicateA, seed: "a", trashedAt: 100)
        let second = pendingIntent(kept: keptB, duplicate: duplicateB, seed: "b", trashedAt: 100)
        XCTAssertTrue(mergeJournal.record([first, second]))

        XCTAssertTrue(mergeJournal.clear([first]))

        XCTAssertEqual(mergeJournal.pendingMerges(), [second], "the other group of the batch still waits for its check")
    }

    func testAPendingCheckThatFinishesLateKeepsTheRecordOfANewerMerge() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        indexServer()
        let read = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: 100)
        XCTAssertTrue(mergeJournal.record([read]))
        // The check reads the open merge, and its first read of the kept photo fails, so it waits for its retry.
        server.configureOptionalReads(visibilityFails: true)
        var checker = finder
        checker.keptReadRetryDelay = .milliseconds(400)
        let check = Task { [checker] in await checker.resolvePendingMerges() }
        for _ in 0..<200 where server.readCounts.visibility == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(server.readCounts.visibility, 0, "the check read the open merge")

        // Meanwhile the person merges the same group again, and that merge records its trash.
        let newer = pendingIntent(kept: kept, duplicate: duplicate, seed: "a", trashedAt: 200)
        XCTAssertTrue(mergeJournal.record([newer]))
        server.configureOptionalReads(visibilityFails: false)
        await check.value

        // The first read failed and its retry read the kept photo, so the check finished and cleared its record.
        XCTAssertEqual(server.readCounts.visibility, 2, "the check finished with its retry")
        XCTAssertEqual(mergeJournal.pendingMerges(), [newer], "the late check must not clear the newer merge")
    }

    func testMergeAllWritesNothingWhenTheSharedFavoritesReadFails() async throws {
        let (groups, sources) = try await threeGroups()
        server.failNextFavoritesRead()

        let results = await finder.merge(chosen(groups.map { ($0, $0.members[0]) }))

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
        XCTAssertEqual(resolved.decision, .skip(.trashedDuplicate, remoteLinkID: duplicate.nodeID))
        let diagnostic = try XCTUnwrap(store.record(for: descriptor.source))
        XCTAssertEqual(diagnostic.remoteLinkID, duplicate.nodeID)
        XCTAssertFalse(diagnostic.provesUpload, "a retained trash link must never prove active adoption")
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

    func testPreselectionKeepsTheCopyWithTheOriginalAndAdjustmentData() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        let original = server.seedLink(digest: digest("original"), main: b)
        let adjustment = server.seedLink(digest: digest("adjustment"), main: b)
        let originalRow = row("original", names: original.nodeID, contentHash: hash("original"))
        let adjustmentRow = row("adjustment", names: adjustment.nodeID, contentHash: hash("adjustment"))
        indexServer()
        let reads = server.readCounts.compound

        let results = await finder.merge(preselected(try await onlyGroup(), a))

        XCTAssertEqual(try results[0].get(), .merged(kept: b, trashed: [a], keptDuplicates: [:]))
        XCTAssertEqual(state(of: a), .trashed)
        for uid in [b, original, adjustment] { XCTAssertEqual(state(of: uid), .active) }
        XCTAssertEqual(store.record(for: originalRow)?.remoteLinkID, original.nodeID)
        XCTAssertEqual(store.record(for: adjustmentRow)?.remoteLinkID, adjustment.nodeID)
        XCTAssertEqual(server.readCounts.compound - reads, 2, "the swap adds no compound read")
        XCTAssertEqual(violations, [])
    }

    func testAChosenPoorerCopyNeverSwapsToTheRicherCopy() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("original"), main: b)
        indexServer()

        let outcome = try await finder.merge(try await onlyGroup(), keeping: a)

        XCTAssertEqual(outcome, .merged(kept: a, trashed: [], keptDuplicates: [b: .relatedFileWithoutTwin]))
        XCTAssertEqual(state(of: a), .active)
        XCTAssertEqual(state(of: b), .active)
        XCTAssertEqual(violations, [])
    }

    func testEqualRelatedSetsMergeInBothPreselectionOrders() async throws {
        for keepSecond in [false, true] {
            server = EditScenarioServer()
            let a = server.seedLink(digest: digest("a"))
            let b = server.seedLink(digest: digest("a"))
            _ = server.seedLink(digest: digest("video"), main: a)
            _ = server.seedLink(digest: digest("video"), main: b)
            let kept = keepSecond ? b : a
            let duplicate = keepSecond ? a : b
            try await server.markFavorite([kept])
            indexServer()

            let results = await finder.merge(preselected(try await onlyGroup(), kept))

            XCTAssertEqual(try results[0].get(), .merged(kept: kept, trashed: [duplicate], keptDuplicates: [:]))
            XCTAssertEqual(violations, [])
        }
    }

    func testConflictingRelatedFilesKeepBothPreselectedCopies() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("x"), main: a)
        _ = server.seedLink(digest: digest("y"), main: b)
        indexServer()

        let results = await finder.merge(preselected(try await onlyGroup(), a))

        XCTAssertEqual(
            try results[0].get(), .merged(kept: a, trashed: [], keptDuplicates: [b: .relatedFileWithoutTwin]))
        XCTAssertEqual(state(of: a), .active)
        XCTAssertEqual(state(of: b), .active)
        XCTAssertEqual(violations, [])
    }

    func testThreePreselectedCopiesKeepTheCoveringCopyAndMoveRelatedRows() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        let c = server.seedLink(digest: digest("a"))
        let bVideo = server.seedLink(digest: digest("video"), main: b)
        let cVideo = server.seedLink(digest: digest("video"), main: c)
        let original = server.seedLink(digest: digest("original"), main: c)
        let aRow = row("a", names: a.nodeID, contentHash: hash("a"))
        let bRow = row("b", names: b.nodeID, contentHash: hash("a"))
        let videoRow = row("video", names: bVideo.nodeID, contentHash: hash("video"))
        indexServer()

        let results = await finder.merge(preselected(try await onlyGroup(), a))

        XCTAssertEqual(try results[0].get(), .merged(kept: c, trashed: [a, b], keptDuplicates: [:]))
        for source in [aRow, bRow] { XCTAssertEqual(store.record(for: source)?.remoteLinkID, c.nodeID) }
        XCTAssertEqual(store.record(for: videoRow)?.remoteLinkID, cVideo.nodeID)
        for uid in [c, cVideo, original] { XCTAssertEqual(state(of: uid), .active) }
        for uid in [a, b] { XCTAssertEqual(state(of: uid), .trashed) }
        XCTAssertEqual(violations, [])
    }

    func testCoveringKeeperUsesServerRankingInEverySeedAndMemberOrder() async throws {
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            for membersOrder in orders {
                server = EditScenarioServer()
                var copies: [Int: PhotoUID] = [:]
                for role in order {
                    // Different device dates deliberately disagree with the server ranking. The fingerprints
                    // have no capture time, so these dates must never rank the covering keepers.
                    copies[role] = server.seedLink(digest: digest("a"), captureTime: date(Double(2 - role)))
                }
                let a = try XCTUnwrap(copies[0])
                let b = try XCTUnwrap(copies[1])
                let c = try XCTUnwrap(copies[2])
                server.decorate(a)
                try await server.addPhotos([b], toOwnAlbum: "own-album")
                for uid in [b, c] { _ = server.seedLink(digest: digest("video"), main: uid) }
                indexServer()
                let group = ExactDuplicateGroup(
                    contentHash: hash("a"), hashKeyEpoch: epoch, members: membersOrder.compactMap { copies[$0] })

                let results = await finder.merge(preselected(group, a))

                guard case .merged(let kept, let trashed, let remaining) = try results[0].get() else {
                    return XCTFail("every order merges")
                }
                XCTAssertEqual(kept, b, "seed \(order), members \(membersOrder)")
                XCTAssertEqual(Set(trashed), [a, c])
                XCTAssertEqual(remaining, [:])
                XCTAssertEqual(violations, [])
            }
        }
    }

    func testCoveringKeepersTieByLinkIDWithoutDeviceDatesAndUseFreshFavoriteTags() async throws {
        for freshFavorite in [false, true] {
            server = EditScenarioServer()
            let a = server.seedLink(digest: digest("a"), captureTime: date(2))
            let b = server.seedLink(digest: digest("a"), captureTime: date(1))
            let c = server.seedLink(digest: digest("a"), captureTime: date(0))
            server.decorate(a)
            for uid in [b, c] { _ = server.seedLink(digest: digest("video"), main: uid) }
            // The listing predates this tag, as in a Merge All run cached before another device changed it.
            if freshFavorite { server.setTags([PhotoTag.favorites.rawValue], of: c) }
            indexServer()
            let kept = freshFavorite ? c : b
            let trashed = freshFavorite ? [a, b] : [a, c]

            let results = await finder.merge(preselected(try await onlyGroup(), a))

            XCTAssertEqual(try results[0].get(), .merged(kept: kept, trashed: trashed, keptDuplicates: [:]))
            XCTAssertEqual(violations, [])
        }
    }

    func testEqualRelatedSetsUseServerOrderEvenWhenThePreselectionCoversEveryone() async throws {
        let c = server.seedLink(digest: digest("a"), captureTime: date(2))
        let b = server.seedLink(digest: digest("a"), captureTime: date(1))
        let k = server.seedLink(digest: digest("a"), captureTime: date(0))
        for uid in [c, b, k] { _ = server.seedLink(digest: digest("video"), main: uid) }
        indexServer()
        let group = ExactDuplicateGroup(contentHash: hash("a"), hashKeyEpoch: epoch, members: [k, b, c])

        let results = await finder.merge(preselected(group, k))

        XCTAssertEqual(try results[0].get(), .merged(kept: c, trashed: [k, b], keptDuplicates: [:]))
        XCTAssertEqual(state(of: c), .active)
        XCTAssertEqual(state(of: k), .trashed)
        XCTAssertEqual(state(of: b), .trashed)
        XCTAssertEqual(violations, [])
    }

    func testASharedKeeperMergesANonsharedPoorerCopyWithoutSwapping() async throws {
        let poorer = server.seedLink(digest: digest("a"))
        let kept = server.seedLink(digest: digest("a"))
        server.share(kept)
        let original = server.seedLink(digest: digest("original"), main: kept)
        indexServer()

        let results = await finder.merge(preselected(try await onlyGroup(), kept))

        XCTAssertEqual(try results[0].get(), .merged(kept: kept, trashed: [poorer], keptDuplicates: [:]))
        XCTAssertEqual(state(of: kept), .active)
        XCTAssertEqual(state(of: original), .active)
        XCTAssertEqual(state(of: poorer), .trashed)
        XCTAssertEqual(violations, [])
    }

    func testASharedKeeperNeverSwapsEvenWhenAnotherSharedMemberIsUnreadable() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let richer = server.seedLink(digest: digest("a"))
        let shared = server.seedLink(digest: digest("a"))
        server.share(kept)
        server.share(shared)
        let video = server.seedLink(digest: digest("video"), main: richer)
        let unreadable = server.seedLink(digest: digest("original"), main: shared)
        server.personTrash(unreadable)
        indexServer()

        let results = await finder.merge(preselected(try await onlyGroup(), kept))

        XCTAssertEqual(
            try results[0].get(),
            .merged(kept: kept, trashed: [], keptDuplicates: [richer: .relatedFileWithoutTwin, shared: .shared]))
        for uid in [kept, richer, shared, video] { XCTAssertEqual(state(of: uid), .active) }
        XCTAssertEqual(violations, [])
    }

    func testASharedPoorerPreselectionNeverSwapsOrTrashes() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        server.share(a)
        server.share(b)
        _ = server.seedLink(digest: digest("original"), main: b)
        indexServer()

        let results = await finder.merge(preselected(try await onlyGroup(), a))

        XCTAssertEqual(try results[0].get(), .merged(kept: a, trashed: [], keptDuplicates: [b: .shared]))
        XCTAssertEqual(state(of: a), .active)
        XCTAssertEqual(state(of: b), .active)
        XCTAssertEqual(violations, [])
    }

    func testSwappedKeeperReceivesFavoriteAlbumCoverAndFailedTrashIntent() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("original"), main: b)
        server.decorate(a)
        server.setAlbumCover("own-album", to: a)
        let source = row("a", names: a.nodeID, contentHash: hash("a"))
        indexServer()
        server.applyNextTrashThenFail()
        // Keep the intent open after the failed trash, as when its confirmation cannot be read.
        server.failingVisibilityReadsAfterDuplicateTrash = ExactDuplicateFinder.keptReadAttempts

        let results = await finder.merge(preselected(try await onlyGroup(), a))

        XCTAssertThrowsError(try results[0].get())
        let keptLink = try XCTUnwrap(server.links.first { $0.linkID == b.nodeID })
        XCTAssertTrue(keptLink.favorite)
        XCTAssertEqual(keptLink.albums, [.init(volumeID: "vol", albumID: "own-album")])
        XCTAssertEqual(server.albumCovers, ["own-album": b.nodeID])
        XCTAssertEqual(store.record(for: source)?.remoteLinkID, b.nodeID)
        XCTAssertEqual(mergeJournal.pendingMerges()?.first?.kept, b.nodeID)
        XCTAssertEqual(violations, [])
    }

    func testOtherMetadataNeverBecomeTheCoveringKeeper() async throws {
        let a = server.seedLink(digest: digest("a"))
        let b = server.seedLink(digest: digest("a"))
        let c = server.seedLink(digest: digest("a"))
        for uid in [b, c] { _ = server.seedLink(digest: digest("video"), main: uid) }
        _ = server.seedLink(digest: digest("original"), main: b)
        server.setFingerprint(.init(pixelWidth: 42), of: b)
        indexServer()

        let results = await finder.merge(preselected(try await onlyGroup(), a))

        XCTAssertEqual(try results[0].get(), .merged(kept: c, trashed: [a], keptDuplicates: [b: .differentDetails]))
        XCTAssertEqual(state(of: b), .active)
        XCTAssertEqual(violations, [])
    }

    func testAnUnreadableActiveCompoundPreventsTheKeeperSwap() async throws {
        for excludedMember in [false, true] {
            server = EditScenarioServer()
            let a = server.seedLink(digest: digest("a"))
            let b = server.seedLink(digest: digest("a"))
            let c = server.seedLink(digest: digest("a"))
            _ = server.seedLink(digest: digest("video"), main: b)
            let unreadableFile = server.seedLink(digest: digest("original"), main: c)
            server.personTrash(unreadableFile)
            if excludedMember {
                server.setFingerprint(.init(pixelWidth: 42), of: c)
            }
            indexServer()

            let results = await finder.merge(preselected(try await onlyGroup(), a))

            XCTAssertEqual(
                try results[0].get(),
                .merged(
                    kept: a, trashed: [],
                    keptDuplicates: [b: .relatedFileWithoutTwin, c: excludedMember ? .differentDetails : .unreadable]))
            for uid in [a, b, c] { XCTAssertEqual(state(of: uid), .active) }
            XCTAssertEqual(violations, [])
        }
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

    func testMergeDoesNotTreatATrashedOutcomeAsProofAfterTheOwnerSnapshot() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        let source = row("asset", names: duplicate.nodeID, contentHash: hash("a"))
        indexServer()
        let identities = CountingIdentityStore(base: store)
        let manifest = try XCTUnwrap(store)
        identities.afterOwnerSnapshot = {
            guard var record = manifest.record(for: source) else { return }
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
            _ = manifest.upsert(record)
        }

        let outcome = try await finder(identities: identities).merge(try await onlyGroup(), keeping: kept)

        XCTAssertEqual(
            outcome, .merged(kept: kept, trashed: [], keptDuplicates: [duplicate: .neededByLocalSource]))
        XCTAssertEqual(state(of: duplicate), .active)
        XCTAssertEqual(manifest.record(for: source)?.remoteLinkID, duplicate.nodeID)
        XCTAssertEqual(manifest.record(for: source)?.outcome, "duplicateTrashed")
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

    // MARK: - Metadata

    private var described: ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(
            captureTime: Date(timeIntervalSince1970: 1_720_000_000), latitude: 10.5, longitude: -20.25,
            device: "Test Camera", pixelWidth: 4000, pixelHeight: 3000, mimeType: "image/heic")
    }

    /// An upload that carries only the capture time and the type, without location, camera, and dimensions.
    private var bare: ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(captureTime: Date(timeIntervalSince1970: 1_720_000_000), mimeType: "image/heic")
    }

    @MainActor
    func testThreeCopiesWhereOneLacksMetadataOfferOnlyTheTwoWithMetadata() async throws {
        let poorer = server.seedLink(digest: digest("a"))
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        server.setFingerprint(bare, of: poorer)
        server.setFingerprint(described, of: first)
        server.setFingerprint(described, of: second)
        indexServer()
        let fallback = await finder.fallbackMembers(of: try await finder.duplicateGroups().groups)
        XCTAssertEqual(fallback.values.first?.first, poorer, "before the ranking the poorer copy is checked")
        let model = ExactDuplicatesModel(finder: finder)

        await model.load()

        XCTAssertEqual(model.groups.count, 1)
        let group = try XCTUnwrap(model.groups.first)
        XCTAssertEqual(Set(group.members), [first, second], "the copy without metadata is not offered")
        XCTAssertNotEqual(group.kept, poorer)
        XCTAssertEqual(group.scanGroup.fingerprint, described)
        XCTAssertEqual(model.copyCount, 2)

        await model.mergeAll()

        XCTAssertEqual(server.links.first { $0.linkID == poorer.nodeID }?.state, .active, "the poorer copy stays")
        let active = [first, second].filter { uid in server.links.first { $0.linkID == uid.nodeID }?.state == .active }
        XCTAssertEqual(active, [group.kept], "one of the two equal copies moves to Recently Deleted")
        XCTAssertEqual(violations, [])
    }

    func testAMergeLeavesACopyWhoseMetadataDifferFromTheKeptPhoto() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let equal = server.seedLink(digest: digest("a"))
        let changed = server.seedLink(digest: digest("a"))
        for uid in [kept, equal, changed] { server.setFingerprint(described, of: uid) }
        indexServer()
        let group = try await onlyGroup()
        // The metadata of one copy changed after the screen read them.
        server.setFingerprint(bare, of: changed)

        let outcome = try await finder.merge(group, keeping: kept)

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [equal], keptDuplicates: [changed: .differentDetails]))
        XCTAssertEqual(server.links.first { $0.linkID == changed.nodeID }?.state, .active)
        XCTAssertEqual(violations, [])
    }

    func testAMergeWritesNothingWhenTheKeptPhotoChangedItsMetadata() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let duplicate = server.seedLink(digest: digest("a"))
        for uid in [kept, duplicate] { server.setFingerprint(described, of: uid) }
        indexServer()
        let scanned = try await onlyGroup()
        let shown = try XCTUnwrap(scanned.split(by: [kept: described, duplicate: described]).first)
        // Both copies changed alike, so they still match each other, but no longer what the screen offered.
        for uid in [kept, duplicate] { server.setFingerprint(bare, of: uid) }
        let stepsBefore = server.steps.count

        let outcome = try await finder.merge(shown, keeping: kept)

        XCTAssertEqual(outcome, .skipped(.keptDetailsChanged))
        XCTAssertEqual(server.steps.count, stepsBefore, "the merge writes nothing")
    }

    // MARK: - The same copy on every device

    /// One device of the person over the shared server: its own manifest, journal, and backup dedupe. Its timeline
    /// does not know the capture dates of `unknownDates`.
    private func device(
        _ index: Int, unknownDates: Set<PhotoUID> = []
    ) throws -> (finder: ExactDuplicateFinder, manifest: UploadIdentityManifestStore) {
        let folder = directory.appendingPathComponent("device-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: folder.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: folder))
        let records = server.links.map {
            UploadRemoteContentIndexRecord(contentHash: $0.contentHash, hashKeyEpoch: epoch, remoteLinkID: $0.linkID)
        }
        XCTAssertTrue(
            manifest.replaceRemoteContentIndex(
                records, unresolvedIssues: [], hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())))
        let finder = ExactDuplicateFinder(
            checker: server,
            resolver: UploadDedupePipeline(store: manifest, checker: server, replacementJournal: journal),
            index: manifest, identities: manifest, journal: journal,
            mergeJournal: ExactDuplicateMergeJournalFileStore(accountDataDirectory: folder),
            remote: TimelineDatesRemote(base: server, unknown: unknownDates), albums: server)
        return (finder, manifest)
    }

    private func activeMains(_ contentHash: String) -> [PhotoUID] {
        server.links.filter { $0.contentHash == contentHash && $0.state == .active && $0.mainLinkID == nil }.map(\.uid)
    }

    @MainActor
    func testTenDevicesThatMergeAllAtOnceKeepTheSameCopyOfEveryGroup() async throws {
        let decorated = (0..<10).map { _ in server.seedLink(digest: digest("a")) }
        let plain = (0..<10).map { _ in server.seedLink(digest: digest("b")) }
        try await server.markFavorite([decorated[7]])
        try await server.addPhotos([decorated[4]], toOwnAlbum: "own-album")
        for uid in plain { server.setFingerprint(described, of: uid) }
        let trashed = TrashedByDevice()
        var models: [ExactDuplicatesModel] = []
        for index in 0..<10 {
            // Every device backed up another copy, and half of the timelines miss the date of the first plain copy.
            let device = try device(index, unknownDates: index.isMultiple(of: 2) ? [] : [plain[0]])
            row("asset-a\(index)", names: decorated[index].nodeID, contentHash: hash("a"), in: device.manifest)
            row("asset-b\(index)", names: plain[index].nodeID, contentHash: hash("b"), in: device.manifest)
            let model = ExactDuplicatesModel(finder: device.finder) { trashed.add($0) }
            await model.load()
            models.append(model)
        }
        let expected = [hash("a"): decorated[4], hash("b"): plain[0]]
        for (index, model) in models.enumerated() {
            let shown = Dictionary(
                model.groups.map { ($0.scanGroup.contentHash, $0.kept) }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(shown, expected, "device \(index) preselects the same copies")
        }

        await withTaskGroup(of: Void.self) { merges in
            for model in models { merges.addTask { await model.mergeAll() } }
        }

        XCTAssertEqual(activeMains(hash("a")), [decorated[4]], "exactly the copy that every device kept stays")
        XCTAssertEqual(activeMains(hash("b")), [plain[0]], "exactly the copy that every device kept stays")
        XCTAssertTrue(trashed.uids.isDisjoint(with: expected.values), "no device trashes the copy that another keeps")
        let keptLink = try XCTUnwrap(server.links.first { $0.linkID == decorated[4].nodeID })
        XCTAssertTrue(keptLink.favorite, "the favorite moved to the kept copy")
        XCTAssertEqual(keptLink.albums, [.init(volumeID: "vol", albumID: "own-album")])
        XCTAssertEqual(violations, [])
    }

    @MainActor
    func testMergeAllReconcilesAMemberTrashedAfterItsActiveReadBeforeItsCompoundRead() async throws {
        let result = try await memberCompoundRace(.concurrentTrash)
        XCTAssertEqual(activeMains(hash("compound-race")), [result.kept])
        XCTAssertEqual(result.second.groups.map(\.id), [])
        XCTAssertEqual(
            result.first.groups.map(\.id), [], "The joined merge must reconcile the confirmed external trash")
        XCTAssertEqual(violations, [])
        XCTAssertEqual(server.relatedFileTransferCallCount, 0)
        XCTAssertEqual(server.uploadRequestCount, 0)
    }

    @MainActor
    func testMergeAllKeepsAGenuinelyUnreadableActiveMemberAfterItsCompoundReadFails() async throws {
        let result = try await memberCompoundRace(.unreadableActive)
        let visibility = try await result.checker.linkVisibility(of: [result.source.nodeID])
        XCTAssertEqual(visibility[result.source.nodeID]?.isActiveMain, true)
        XCTAssertEqual(visibility[result.source.nodeID]?.hasExplicitPhotoState, true)
        XCTAssertEqual(result.first.groups.map(\.id), [hash("compound-race")])
        XCTAssertEqual(result.first.groups.first?.keptReason, .unreadable)
        XCTAssertEqual(state(of: result.source), .active)
        XCTAssertEqual(state(of: result.kept), .active)
        XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash ") })
        XCTAssertEqual(violations, [])
        XCTAssertEqual(server.relatedFileTransferCallCount, 0)
    }

    @MainActor
    func testMergeAllKeepsUnknownMemberVisibilityAfterItsCompoundReadFails() async throws {
        for mode in [MemberCompoundRaceChecker.Mode.unknownMissingEntry, .unknownState] {
            server = EditScenarioServer()
            let result = try await memberCompoundRace(mode)
            let visibility = try await result.checker.linkVisibility(of: [result.source.nodeID])
            if mode == .unknownMissingEntry {
                XCTAssertNil(visibility[result.source.nodeID])
            } else {
                XCTAssertEqual(visibility[result.source.nodeID]?.isActive, false)
                XCTAssertEqual(
                    visibility[result.source.nodeID]?.hasExplicitPhotoState, false,
                    "A false legacy boolean without explicit state must not prove inactivity")
            }
            let actual = try await server.linkVisibility(of: [result.source.nodeID])
            XCTAssertEqual(actual[result.source.nodeID]?.isActiveMain, true)
            XCTAssertEqual(result.first.groups.map(\.id), [hash("compound-race")])
            XCTAssertEqual(result.first.groups.first?.keptReason, .unreadable)
            XCTAssertEqual(state(of: result.source), .active)
            XCTAssertEqual(state(of: result.kept), .active)
            XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash ") })
            XCTAssertEqual(violations, [])
            XCTAssertEqual(server.relatedFileTransferCallCount, 0)
        }
    }

    @MainActor
    func testUnreadableMemberWithAChangedOrUnknownKeeperDoesNotProveNoDuplicate() async throws {
        for mode in [MemberCompoundRaceChecker.Mode.keeperTrashed, .keeperUnknown, .keeperMissing, .keeperRelated] {
            server = EditScenarioServer()
            let result = try await memberCompoundRace(mode)
            XCTAssertEqual(result.first.groups.map(\.id), [hash("compound-race")])
            XCTAssertEqual(result.first.groups.first?.keptReason, .unreadable)
            XCTAssertEqual(state(of: result.source), .trashed)
            XCTAssertEqual(state(of: result.kept), mode == .keeperTrashed ? .trashed : .active)
            XCTAssertEqual(
                server.steps.filter { $0.action.hasPrefix("duplicate trash ") }.count,
                1, "Only the second model may dispatch a duplicate trash")
            XCTAssertEqual(result.checker.freshVisibilityReads, 1)
            if mode == .keeperMissing || mode == .keeperRelated {
                let visibility = try await result.checker.linkVisibility(of: [result.kept.nodeID, result.source.nodeID])
                XCTAssertEqual(visibility[result.source.nodeID]?.hasExplicitPhotoState, true)
                XCTAssertEqual(visibility[result.source.nodeID]?.isActive, false)
                if mode == .keeperMissing {
                    XCTAssertNil(visibility[result.kept.nodeID])
                } else {
                    XCTAssertEqual(visibility[result.kept.nodeID]?.hasExplicitPhotoState, true)
                    XCTAssertEqual(visibility[result.kept.nodeID]?.isActive, true)
                    XCTAssertEqual(visibility[result.kept.nodeID]?.mainPhotoLinkID, result.source.nodeID)
                    XCTAssertEqual(visibility[result.kept.nodeID]?.isActiveMain, false)
                }
            }
            XCTAssertEqual(violations, [])
            XCTAssertEqual(server.relatedFileTransferCallCount, 0)
        }
    }

    @MainActor
    func testSoleKeeperProofRequiresEveryOriginalMemberRatherThanOnlyTheInitiallyActiveMembers() async throws {
        let result = try await memberCompoundRace(.unknownOriginalMember)
        XCTAssertEqual(result.first.groups.map(\.id), [hash("compound-race")])
        XCTAssertEqual(result.first.groups.first?.members.count, 3)
        XCTAssertEqual(result.first.groups.first?.keptReason, .unreadable)
        XCTAssertEqual(activeMains(hash("compound-race")), [result.kept])
        XCTAssertEqual(server.steps.filter { $0.action.hasPrefix("duplicate trash ") }.count, 1)
        XCTAssertEqual(result.checker.freshVisibilityReads, 1)
        XCTAssertEqual(violations, [])
        XCTAssertEqual(server.relatedFileTransferCallCount, 0)
    }

    @MainActor
    func testSoleKeeperVisibilityReadFailureUsesTheExistingFailedResultWithoutClearingTheGroup() async throws {
        let result = try await memberCompoundRace(.freshReadError)
        XCTAssertEqual(result.first.groups.map(\.id), [hash("compound-race")])
        XCTAssertEqual(result.first.notice, .failed)
        XCTAssertEqual(state(of: result.source), .active)
        XCTAssertEqual(state(of: result.kept), .active)
        XCTAssertEqual(result.checker.freshVisibilityReads, 1)
        XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash ") })
        XCTAssertEqual(server.relatedFileTransferCallCount, 0)
    }

    @MainActor
    func testANonnilWrongHashCompoundNeverUsesSoleKeeperReconciliation() async throws {
        let result = try await memberCompoundRace(.wrongHash)
        XCTAssertEqual(result.first.groups.map(\.id), [hash("compound-race")])
        XCTAssertEqual(result.first.groups.first?.keptReason, .unreadable)
        XCTAssertEqual(result.checker.freshVisibilityReads, 0)
        XCTAssertEqual(state(of: result.source), .active)
        XCTAssertEqual(state(of: result.kept), .active)
        XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash ") })
        XCTAssertEqual(server.relatedFileTransferCallCount, 0)
    }

    func testSoleKeeperConfirmationPropagatesCancellationInsteadOfDeclaringAbsence() async throws {
        let kept = server.seedLink(digest: digest("compound-race"))
        let source = server.seedLink(digest: digest("compound-race"))
        let gate = MemberCompoundReadGate()
        let checker = MemberCompoundRaceChecker(
            base: server, kept: kept, source: source, mode: .freshReadCancellation, gate: gate)
        let original = try device(0).finder
        let finder = ExactDuplicateFinder(
            checker: checker, resolver: original.resolver, index: original.index, identities: original.identities,
            journal: original.journal, mergeJournal: original.mergeJournal, remote: original.remote,
            albums: original.albums)
        let groups = try await finder.duplicateGroups().groups
        let group = try XCTUnwrap(groups.first)
        checker.arm()
        let merging = Task { try await finder.merge(group, keeping: kept) }
        defer { gate.open() }
        let arrived = await gate.waitForArrival()
        guard arrived else {
            _ = await merging.result
            return
        }
        XCTAssertTrue(checker.sawPositiveActiveRead)
        gate.open()
        switch await merging.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Cancellation must propagate instead of a skipped or merged receipt")
        }
        XCTAssertEqual(checker.freshVisibilityReads, 1)
        XCTAssertEqual(state(of: source), .active)
        XCTAssertEqual(state(of: kept), .active)
        XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash ") })
        XCTAssertEqual(server.relatedFileTransferCallCount, 0)
    }

    /// Exercise the real models, Finder, manifests and shared server. Only the metadata read boundary is held.
    @MainActor
    private func memberCompoundRace(
        _ mode: MemberCompoundRaceChecker.Mode
    ) async throws -> (
        first: ExactDuplicatesModel, second: ExactDuplicatesModel, kept: PhotoUID, source: PhotoUID,
        checker: MemberCompoundRaceChecker
    ) {
        let kept = server.seedLink(digest: digest("compound-race"))
        let source = server.seedLink(digest: digest("compound-race"))
        let uncertain = mode == .unknownOriginalMember ? server.seedLink(digest: digest("compound-race")) : nil
        server.setFavorite(true, of: kept)
        let gate = MemberCompoundReadGate()
        let checker = MemberCompoundRaceChecker(
            base: server, kept: kept, source: source, mode: mode, gate: gate, uncertain: uncertain)
        let original = try device(0).finder
        let firstFinder = ExactDuplicateFinder(
            checker: checker, resolver: original.resolver, index: original.index, identities: original.identities,
            journal: original.journal, mergeJournal: original.mergeJournal, remote: original.remote,
            albums: original.albums)
        let first = ExactDuplicatesModel(finder: firstFinder)
        let second = ExactDuplicatesModel(finder: try device(1).finder)
        await first.load()
        await second.load()
        XCTAssertEqual(first.groups.first?.kept, kept)
        XCTAssertEqual(second.groups.first?.kept, kept)
        checker.arm()
        let merging = Task { await first.mergeAll() }
        defer { gate.open() }
        let arrived = await gate.waitForArrival()
        guard arrived else {
            await merging.value
            return (first, second, kept, source, checker)
        }
        XCTAssertTrue(first.isMerging)
        XCTAssertTrue(checker.sawPositiveActiveRead, "The held compound follows the merge's explicit active visibility")
        XCTAssertEqual(state(of: source), .active)
        XCTAssertEqual(state(of: kept), .active)
        if mode == .concurrentTrash || mode == .keeperUnknown || mode == .keeperTrashed || mode == .keeperMissing
            || mode == .keeperRelated || mode == .unknownOriginalMember
        {
            await second.mergeAll()
            XCTAssertEqual(state(of: source), .trashed)
            XCTAssertEqual(state(of: kept), .active)
            XCTAssertEqual(second.groups.map(\.id), [])
        }
        if mode == .keeperTrashed { server.personTrash(kept) }
        gate.open()
        await merging.value
        XCTAssertFalse(first.isMerging, "The test waits for the real merge to finish before reading its UI state")
        XCTAssertTrue(checker.didReadHeldCompound)
        return (first, second, kept, source, checker)
    }

    @MainActor
    func testMergeAllKeepsTheRulesCopyOfGroupsThatNobodyScrolledToOnEveryDeviceInOnePress() async throws {
        // More groups than the screen ranks when it opens, so the last ones show only the order that needs no request.
        let pairs = (0..<60).map { index in
            (server.seedLink(digest: digest("group-\(index)")), server.seedLink(digest: digest("group-\(index)")))
        }
        try await server.markFavorite(pairs.map(\.1))
        var models: [ExactDuplicatesModel] = []
        for index in 0..<3 {
            let device = try device(index)
            let model = ExactDuplicatesModel(finder: device.finder)
            await model.load()
            models.append(model)
        }
        for model in models {
            let unranked = model.groups.filter { !$0.isRanked }
            XCTAssertFalse(unranked.isEmpty, "some groups wait for their ranking")
            XCTAssertTrue(unranked.allSatisfy { $0.kept == $0.members[0] && !pairs.map(\.1).contains($0.kept) })
        }

        await withTaskGroup(of: Void.self) { merges in
            for model in models { merges.addTask { await model.mergeAll() } }
        }

        for (index, pair) in pairs.enumerated() {
            XCTAssertEqual(activeMains(hash("group-\(index)")), [pair.1], "group \(index) keeps its favorite only")
        }
        for (index, model) in models.enumerated() {
            XCTAssertEqual(model.groups.map(\.id), [], "device \(index) merged every group in one press")
        }
        XCTAssertEqual(violations, [])
    }

    /// Groups in three batches of Merge All, two copies each, without favorites.
    private func threeBatchesOfGroups() -> [(PhotoUID, PhotoUID)] {
        let pairs = (0..<(2 * ExactDuplicatesModel.mergeBatchSize + 10)).map { index in
            (server.seedLink(digest: digest("group-\(index)")), server.seedLink(digest: digest("group-\(index)")))
        }
        indexServer()
        return pairs
    }

    @MainActor
    func testMergeAllReadsTheFavoritesAndTheAlbumCoversOnceForAllItsBatches() async throws {
        let pairs = threeBatchesOfGroups()
        let model = ExactDuplicatesModel(finder: finder)
        await model.load()
        let readsBefore = server.readCounts

        await model.mergeAll()

        let reads = server.readCounts
        XCTAssertEqual(reads.favorites - readsBefore.favorites, 1, "one favorites listing serves every batch")
        XCTAssertEqual(reads.albumListings - readsBefore.albumListings, 1, "one album listing serves every batch")
        for (index, pair) in pairs.enumerated() {
            XCTAssertEqual(activeMains(hash("group-\(index)")), [pair.0])
        }
        XCTAssertEqual(model.groups.map(\.id), [])
        XCTAssertEqual(violations, [])
    }

    /// Two groups of two copies, sorted, and one run for both.
    private func twoGroupsInOneRun() async throws -> (
        first: (PhotoUID, PhotoUID), second: (PhotoUID, PhotoUID), groups: [ExactDuplicateGroup],
        run: ExactDuplicateMergeRun
    ) {
        let first = (server.seedLink(digest: digest("a")), server.seedLink(digest: digest("a")))
        let second = (server.seedLink(digest: digest("b")), server.seedLink(digest: digest("b")))
        indexServer()
        let groups = try await finder.duplicateGroups().groups.sorted { $0.members[0].nodeID < $1.members[0].nodeID }
        XCTAssertEqual(groups.count, 2)
        return (first, second, groups, ExactDuplicateMergeRun(members: groups.flatMap(\.members)))
    }

    private func preselected(_ group: ExactDuplicateGroup, _ kept: PhotoUID) -> [ExactDuplicateMergeRequest] {
        [ExactDuplicateMergeRequest(group: group, kept: kept, isKeptChosen: false)]
    }

    func testABatchCarriesOverAFavoriteThatAnotherDeviceSetAfterTheRunReadTheFavorites() async throws {
        let (first, second, groups, run) = try await twoGroupsInOneRun()
        let finder = finder
        let merged = await finder.merge(chosen([(groups[0], first.0)]), in: run)
        XCTAssertEqual(try merged[0].get(), .merged(kept: first.0, trashed: [first.1], keptDuplicates: [:]))
        try await server.markFavorite([second.1])

        let next = await finder.merge(chosen([(groups[1], second.0)]), in: run)

        XCTAssertEqual(try next[0].get(), .merged(kept: second.0, trashed: [second.1], keptDuplicates: [:]))
        XCTAssertEqual(server.links.first { $0.linkID == second.0.nodeID }?.favorite, true, "the favorite moved over")
        XCTAssertEqual(violations, [])
    }

    func testABatchCarriesOverAFavoriteWhenAnotherDeviceMovedItFromTheKeptPhoto() async throws {
        let (first, second, groups, run) = try await twoGroupsInOneRun()
        try await server.markFavorite([second.0])
        let finder = finder
        _ = await finder.merge(chosen([(groups[0], first.0)]), in: run)
        // Another device moves the favorite from the photo to keep to its copy.
        server.setFavorite(false, of: second.0)
        try await server.markFavorite([second.1])

        let next = await finder.merge(chosen([(groups[1], second.0)]), in: run)

        XCTAssertEqual(try next[0].get(), .merged(kept: second.0, trashed: [second.1], keptDuplicates: [:]))
        XCTAssertEqual(server.links.first { $0.linkID == second.0.nodeID }?.favorite, true, "the favorite moved over")
        XCTAssertEqual(violations, [])
    }

    func testABatchSkipsAPreselectionWhenAnotherDeviceSetAFavoriteAfterTheRunReadTheFavorites() async throws {
        let (first, second, groups, run) = try await twoGroupsInOneRun()
        let finder = finder
        let readsBefore = server.readCounts.favorites
        let merged = await finder.merge(preselected(groups[0], first.0), in: run)
        XCTAssertEqual(try merged[0].get(), .merged(kept: first.0, trashed: [first.1], keptDuplicates: [:]))
        // Another device marks the second copy of the next group as favorite, so every device ranks it first now.
        try await server.markFavorite([second.1])

        let skipped = await finder.merge(preselected(groups[1], second.0), in: run)

        XCTAssertEqual(try skipped[0].get(), .skipped(.preselectionChanged), "no copy that another device keeps leaves")
        XCTAssertEqual(activeMains(hash("b")).sorted { $0.nodeID < $1.nodeID }, [second.0, second.1])
        XCTAssertEqual(server.readCounts.favorites - readsBefore, 1, "the run reads its favorites once")
        XCTAssertEqual(violations, [])
    }

    func testABatchKeepsAPreselectionWhenAnotherDeviceRemovedAFavoriteAfterTheRunReadTheFavorites() async throws {
        let (first, second, groups, run) = try await twoGroupsInOneRun()
        try await server.markFavorite([second.1])
        let finder = finder
        _ = await finder.merge(preselected(groups[0], first.0), in: run)
        // Another device removes the favorite, so every device ranks the first copy first again.
        server.setFavorite(false, of: second.1)

        let merged = await finder.merge(preselected(groups[1], second.0), in: run)

        XCTAssertEqual(try merged[0].get(), .merged(kept: second.0, trashed: [second.1], keptDuplicates: [:]))
        XCTAssertEqual(violations, [])
    }

    func testTheRankingAfterAMergeReadsNoNewFavoritesListingAndKnowsTheCarriedFavorite() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let favorite = server.seedLink(digest: digest("a"))
        _ = server.seedLink(digest: digest("b"))
        _ = server.seedLink(digest: digest("b"))
        try await server.markFavorite([favorite])
        indexServer()
        let finder = finder
        let groups = try await finder.duplicateGroups().groups
        XCTAssertEqual(groups.count, 2)
        _ = await finder.rankedMembers(of: groups)
        let merged = try XCTUnwrap(groups.first { $0.members.contains(kept) })
        let other = try XCTUnwrap(groups.first { !$0.members.contains(kept) })

        let outcome = try await finder.merge(merged, keeping: kept)
        let readsBefore = server.readCounts.favorites
        let pages = PageCollector()
        await finder.rankMembers(of: [other, merged]) { await pages.add($0) }

        XCTAssertEqual(outcome, .merged(kept: kept, trashed: [favorite], keptDuplicates: [:]))
        XCTAssertEqual(server.readCounts.favorites, readsBefore, "the ranking keeps its favorites")
        let facts = await pages.pages.flatMap { $0.facts.values.flatMap { $0 } }
        XCTAssertEqual(facts.first { $0.key == kept }?.value.isFavorite, true, "the ranking knows the carried tag")
        XCTAssertEqual(violations, [])
    }

    /// More groups than the screen ranks when it opens, two copies each, the second one a favorite. The fallback
    /// order checks the first copy; the rule ranks the favorite first.
    @MainActor
    private func groupsBeyondTheRankedPages() async throws -> Set<PhotoUID> {
        let pairs = (0..<60).map { index in
            (server.seedLink(digest: digest("group-\(index)")), server.seedLink(digest: digest("group-\(index)")))
        }
        try await server.markFavorite(pairs.map(\.1))
        indexServer()
        return Set(pairs.map(\.1))
    }

    @MainActor
    func testASingleMergeOfAnUnrankedGroupKeepsTheRulesCopyInOnePress() async throws {
        let favorites = try await groupsBeyondTheRankedPages()
        let model = ExactDuplicatesModel(finder: finder)
        await model.load()
        let unranked = model.groups.filter { !$0.isRanked }
        XCTAssertGreaterThanOrEqual(unranked.count, 2)
        let header = unranked[0]
        let viewer = unranked[1]
        XCTAssertFalse(favorites.contains(header.kept), "the screen checks the fallback copy")
        XCTAssertFalse(favorites.contains(viewer.kept), "the screen checks the fallback copy")

        await model.merge(groupID: header.id)
        await model.merge(containing: viewer.members[1])

        for group in [header, viewer] {
            let favorite = try XCTUnwrap(group.members.first(where: favorites.contains))
            XCTAssertEqual(activeMains(group.scanGroup.contentHash), [favorite], "one press keeps the rule's copy")
            XCTAssertNil(model.group(withID: group.id))
        }
        XCTAssertNil(model.notice)
        XCTAssertEqual(violations, [])
    }

    @MainActor
    func testAFailedSingleMergeOfAnUnrankedGroupLetsMergeAllMergeItInOnePress() async throws {
        let favorites = try await groupsBeyondTheRankedPages()
        let model = ExactDuplicatesModel(finder: finder)
        await model.load()
        let group = try XCTUnwrap(model.groups.first { !$0.isRanked })
        server.failNextFavoritesRead()

        await model.merge(groupID: group.id)

        XCTAssertEqual(model.notice, .failed)
        XCTAssertEqual(Set(activeMains(group.scanGroup.contentHash)), Set(group.members), "nothing moved")

        await model.mergeAll()

        XCTAssertEqual(model.groups.map(\.id), [], "every group merged in one press")
        XCTAssertEqual(Set(server.links.filter { $0.state == .active }.map(\.uid)), favorites)
        XCTAssertEqual(violations, [])
    }

    func testTheMergeReadsTheDatesOfTheDeviceOnlyForPhotosWithoutACaptureTime() async throws {
        let dated = (0..<2).map { _ in server.seedLink(digest: digest("a")) }
        let undated = (0..<2).map { _ in server.seedLink(digest: digest("b")) }
        for uid in dated { server.setFingerprint(described, of: uid) }
        indexServer()
        let groups = try await finder.duplicateGroups().groups
        let remote = DateReadCountingRemote(base: server)
        let finder = ExactDuplicateFinder(
            checker: server, resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal, mergeJournal: mergeJournal, remote: remote,
            albums: server)

        let results = await finder.merge(
            groups.map { ExactDuplicateMergeRequest(group: $0, kept: $0.members[0], isKeptChosen: false) })

        XCTAssertEqual(try results.map { try $0.get() }.count, 2)
        XCTAssertEqual(activeMains(hash("a")), [dated[0]])
        XCTAssertEqual(activeMains(hash("b")), [undated[0]])
        XCTAssertEqual(remote.asked, [Set(undated)], "the nodes state the capture time of the other photos")
    }

    func testAMergeOfPreselectedPhotosReadsTheFavoritesOnceAndCarriesThemOver() async throws {
        let kept = server.seedLink(digest: digest("a"))
        let favorite = server.seedLink(digest: digest("a"))
        let otherKept = server.seedLink(digest: digest("b"))
        let otherDuplicate = server.seedLink(digest: digest("b"))
        try await server.addPhotos([kept], toOwnAlbum: "own-album")
        try await server.markFavorite([favorite])
        indexServer()
        let groups = try await finder.duplicateGroups().groups
        let readsBefore = server.readCounts.favorites

        let results = await finder.merge(
            groups.map { ExactDuplicateMergeRequest(group: $0, kept: $0.members[0], isKeptChosen: false) })

        XCTAssertEqual(
            try results.map { try $0.get() }.sorted { "\($0)" < "\($1)" },
            [
                .merged(kept: kept, trashed: [favorite], keptDuplicates: [:]),
                .merged(kept: otherKept, trashed: [otherDuplicate], keptDuplicates: [:]),
            ].sorted { "\($0)" < "\($1)" })
        XCTAssertEqual(server.readCounts.favorites - readsBefore, 1, "the check and the carry-over share one listing")
        XCTAssertEqual(server.links.first { $0.linkID == kept.nodeID }?.favorite, true, "the favorite moved")
        XCTAssertEqual(violations, [])
    }

    @MainActor
    func testAFavoriteSetAfterTheScreenRankedMakesTheMergeSkipTheGroupInsteadOfTrashingTheNewFirstCopy() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        let otherFirst = server.seedLink(digest: digest("b"))
        let otherSecond = server.seedLink(digest: digest("b"))
        indexServer()
        let model = ExactDuplicatesModel(finder: finder)
        await model.load()
        let single = try XCTUnwrap(model.groups.first { $0.members.contains(first) })
        XCTAssertEqual(single.kept, first)
        XCTAssertEqual(model.groups.first { $0.members.contains(otherFirst) }?.kept, otherFirst)
        // Another device marks the second copies as favorites after this screen ranked.
        try await server.markFavorite([second, otherSecond])

        await model.merge(groupID: single.id)

        XCTAssertFalse(server.steps.contains { $0.action.hasPrefix("duplicate trash") }, "the merge trashes nothing")
        XCTAssertEqual(activeMains(hash("a")), [first, second])
        XCTAssertEqual(
            model.groups.first { $0.members.contains(first) }?.kept, second,
            "the screen reads the group again and checks the favorite")

        await model.mergeAll()

        XCTAssertEqual(activeMains(hash("a")), [second])
        XCTAssertEqual(activeMains(hash("b")), [otherFirst, otherSecond], "Merge All skips the other changed group")
        XCTAssertEqual(model.groups.first { $0.members.contains(otherFirst) }?.kept, otherSecond)

        await model.mergeAll()

        XCTAssertEqual(activeMains(hash("b")), [otherSecond])
        XCTAssertEqual(violations, [])
    }

    func testAPreselectedPhotoThatNoLongerRanksFirstIsSkippedAndAChosenOneIsKept() async throws {
        let first = server.seedLink(digest: digest("a"))
        let second = server.seedLink(digest: digest("a"))
        indexServer()
        let group = try await onlyGroup()
        try await server.markFavorite([second])
        let stepsBefore = server.steps.count

        let preselected = try await finder.merge(group, keeping: first, isKeptChosen: false)

        XCTAssertEqual(preselected, .skipped(.preselectionChanged))
        XCTAssertEqual(server.steps.count, stepsBefore, "the merge writes nothing")

        let chosen = try await finder.merge(group, keeping: first, isKeptChosen: true)

        XCTAssertEqual(chosen, .merged(kept: first, trashed: [second], keptDuplicates: [:]))
        XCTAssertEqual(server.links.first { $0.linkID == first.nodeID }?.favorite, true)
    }

    @MainActor
    func testACopyThatThePersonChoseIsKeptEvenWhenTheRuleRanksAnotherFirst() async throws {
        let favorite = server.seedLink(digest: digest("a"))
        let chosen = server.seedLink(digest: digest("a"))
        let otherFavorite = server.seedLink(digest: digest("b"))
        let otherChosen = server.seedLink(digest: digest("b"))
        try await server.markFavorite([favorite, otherFavorite])
        indexServer()
        let model = ExactDuplicatesModel(finder: finder)
        await model.load()
        XCTAssertEqual(model.group(containing: chosen)?.kept, favorite)
        XCTAssertEqual(model.group(containing: otherChosen)?.kept, otherFavorite)
        model.keep(chosen)
        model.keep(otherChosen)

        // The viewer merges one group, Merge All the other.
        await model.merge(containing: chosen)
        await model.mergeAll()

        XCTAssertEqual(activeMains(hash("a")), [chosen])
        XCTAssertEqual(activeMains(hash("b")), [otherChosen])
        XCTAssertEqual(server.links.first { $0.linkID == chosen.nodeID }?.favorite, true, "the favorite moved")
        XCTAssertEqual(violations, [])
    }
}

/// Counts the reads of the manifest rows that name a remote link.
/// Holds the favorites listing, the first read of the ranking, while its gate is closed.
private final class FavoritesGatedRemote: EditScenarioDuplicateRemote, @unchecked Sendable {
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

/// Holds the merge after its trash moved the photos, like a process that ends there.
private final class TrashStoppingRemote: EditScenarioDuplicateRemote, @unchecked Sendable {
    let base: EditScenarioServer
    let gate = FinderGate()
    /// A cancellation while the gate holds the trash fails its answer, as a cancelled request does.
    let throwsWhenCancelled: Bool

    init(base: EditScenarioServer, throwsWhenCancelled: Bool = false) {
        self.base = base
        self.throwsWhenCancelled = throwsWhenCancelled
    }

    func trashDuplicates(_ uids: [PhotoUID]) async throws {
        try await base.trashDuplicates(uids)
        await gate.pass()
        if throwsWhenCancelled { try Task.checkCancellation() }
    }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Holds every restore before it reaches the server while its gate is closed, and counts the restores that arrived.
private final class RestoreGatedRemote: EditScenarioDuplicateRemote, @unchecked Sendable {
    let base: EditScenarioServer
    let gate = FinderGate()
    private let lock = NSLock()
    private var _arrivals = 0

    init(base: EditScenarioServer) { self.base = base }

    var arrivals: Int { lock.withLock { _arrivals } }

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws {
        lock.withLock { _arrivals += 1 }
        await gate.pass()
        try await base.restoreDuplicates(uids)
    }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Turns true once.
private final class EndFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The server as one device reads it: its timeline does not know the capture dates of `unknown`.
private struct TimelineDatesRemote: EditScenarioDuplicateRemote {
    let base: EditScenarioServer
    let unknown: Set<PhotoUID>

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] {
        await base.captureDates(of: uids).filter { !unknown.contains($0.key) }
    }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Runs `before` right before each trash, for example the trash of another device.
private struct BeforeTrashRemote: EditScenarioDuplicateRemote {
    let base: EditScenarioServer
    let before: @Sendable () async -> Void

    func trashDuplicates(_ uids: [PhotoUID]) async throws {
        await before()
        try await base.trashDuplicates(uids)
    }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Records the photos whose dates the device is asked for.
private final class DateReadCountingRemote: EditScenarioDuplicateRemote, @unchecked Sendable {
    let base: EditScenarioServer
    private let lock = NSLock()
    private var _asked: [Set<PhotoUID>] = []

    init(base: EditScenarioServer) { self.base = base }

    var asked: [Set<PhotoUID>] { lock.withLock { _asked } }

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] {
        lock.withLock { _asked.append(Set(uids)) }
        return await base.captureDates(of: uids)
    }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Holds callers until `count` callers arrived, or for at most 10 seconds, so a missing caller fails the test instead
/// of hanging it.
private actor FinderBarrier {
    private let count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    init(count: Int) { self.count = count }

    func arrive() async {
        guard !isOpen else { return }
        if waiters.count + 1 >= count {
            release()
            return
        }
        if waiters.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(10))
                await self.release()
            }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// The photos that the merges of all devices moved to Recently Deleted.
@MainActor
private final class TrashedByDevice {
    private(set) var uids: Set<PhotoUID> = []
    func add(_ trashed: [PhotoUID]) { uids.formUnion(trashed) }
}

/// Leaves one photo out of every node read.
private struct MemberDroppingRemote: EditScenarioDuplicateRemote {
    let base: EditScenarioServer
    let drop: PhotoUID

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        try await base.nodeFacts(of: uids).filter { $0.key != drop }
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Counts the node reads that run at once. Each read waits a moment, so reads that can overlap do.
private final class ConcurrencyCountingRemote: EditScenarioDuplicateRemote, @unchecked Sendable {
    let base: EditScenarioServer
    private let lock = NSLock()
    private var running = 0
    private var peak = 0

    init(base: EditScenarioServer) { self.base = base }

    var peakConcurrentNodeReads: Int { lock.withLock { peak } }

    func trashDuplicates(_ uids: [PhotoUID]) async throws { try await base.trashDuplicates(uids) }
    func restoreDuplicates(_ uids: [PhotoUID]) async throws { try await base.restoreDuplicates(uids) }
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date] { await base.captureDates(of: uids) }
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts] {
        lock.withLock {
            running += 1
            peak = max(peak, running)
        }
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        return try await base.nodeFacts(of: uids)
    }
    func ownPhotosVolumeID() async throws -> String { try await base.ownPhotosVolumeID() }
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.activeUIDs(among: uids) }
    func markFavorite(_ uids: [PhotoUID]) async throws { try await base.markFavorite(uids) }
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> { try await base.favoriteUIDs(among: uids) }
}

/// Holds callers until it opens.
private actor FinderGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiters: Bool { !waiters.isEmpty }

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

private actor PageCollector {
    private(set) var pages: [ExactDuplicateRankingPage] = []
    func add(_ page: ExactDuplicateRankingPage) { pages.append(page) }
}

private actor ProgressLog {
    private(set) var steps: [UploadRemoteIndexPreparationProgress] = []
    func append(_ step: UploadRemoteIndexPreparationProgress) { steps.append(step) }
}

/// Empties the trash of the server once its gate opens, and counts the emptyings that arrived.
private final class GatedServerTrash: TrashProvider, @unchecked Sendable {
    let server: EditScenarioServer
    let gate = FinderGate()
    private let lock = NSLock()
    private var count = 0

    init(server: EditScenarioServer) { self.server = server }

    var arrivals: Int { lock.withLock { count } }

    func trash(_ uids: [PhotoUID]) async throws {}
    func restore(_ uids: [PhotoUID]) async throws {}
    func emptyTrash() async throws {
        lock.withLock { count += 1 }
        await gate.pass()
        server.personEmptyTrash()
    }
}

private final class CountingTrash: TrashProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var emptied: Int { lock.withLock { count } }

    func trash(_ uids: [PhotoUID]) async throws {}
    func restore(_ uids: [PhotoUID]) async throws {}
    func emptyTrash() async throws { lock.withLock { count += 1 } }
}

private final class CountingIdentityStore: UploadIdentityStore, @unchecked Sendable {
    struct Reads: Equatable {
        var single = 0
        var batch = 0
    }

    private let base: UploadIdentityManifestStore
    private let lock = NSLock()
    private var counted = Reads()
    var afterOwnerSnapshot: (@Sendable () -> Void)?

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
        let snapshot = base.sources(withRemoteLinkIDs: linkIDs)
        afterOwnerSnapshot?()
        return snapshot
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

/// Test-local proxy: preserve server behavior except the explicitly selected unreadable/unknown control.
private final class MemberCompoundRaceChecker: UploadDuplicateChecking, @unchecked Sendable {
    enum Mode: Equatable {
        case concurrentTrash, unreadableActive, unknownMissingEntry, unknownState
        case keeperTrashed, keeperUnknown, keeperMissing, keeperRelated
        case unknownOriginalMember, freshReadError, wrongHash, freshReadCancellation
    }
    let base: EditScenarioServer
    let kept: PhotoUID
    let source: PhotoUID
    let mode: Mode
    let gate: MemberCompoundReadGate
    let uncertain: PhotoUID?
    private let lock = NSLock()
    private var armed = false
    private var held = false
    private var readHeld = false
    private var sawActive = false
    private var freshReads = 0

    init(
        base: EditScenarioServer, kept: PhotoUID, source: PhotoUID, mode: Mode, gate: MemberCompoundReadGate,
        uncertain: PhotoUID? = nil
    ) {
        self.base = base
        self.kept = kept
        self.source = source
        self.mode = mode
        self.gate = gate
        self.uncertain = uncertain
    }
    var freshVisibilityReads: Int { lock.withLock { freshReads } }
    func arm() { lock.withLock { armed = true } }
    var sawPositiveActiveRead: Bool { lock.withLock { sawActive } }
    var didReadHeldCompound: Bool { lock.withLock { readHeld } }

    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        var visibility = try await base.linkVisibility(of: linkIDs)
        let afterFailure = lock.withLock {
            if armed, !held, visibility[kept.nodeID]?.isActiveMain == true,
                visibility[kept.nodeID]?.hasExplicitPhotoState == true,
                visibility[source.nodeID]?.isActiveMain == true,
                visibility[source.nodeID]?.hasExplicitPhotoState == true
            {
                sawActive = true
            }
            let after = armed && readHeld
            if after { freshReads += 1 }
            return after
        }
        if mode == .unknownOriginalMember, lock.withLock({ armed }), let uncertain {
            visibility[uncertain.nodeID] = nil
        }
        if afterFailure, mode == .freshReadError { throw URLError(.networkConnectionLost) }
        if afterFailure, mode == .freshReadCancellation { throw CancellationError() }
        if afterFailure, mode == .keeperUnknown, var keeper = visibility[kept.nodeID] {
            keeper.hasExplicitPhotoState = false
            visibility[kept.nodeID] = keeper
        }
        if afterFailure, mode == .keeperMissing { visibility[kept.nodeID] = nil }
        if afterFailure, mode == .keeperRelated {
            visibility[kept.nodeID] = RemoteLinkVisibility(
                isActive: true, mainPhotoLinkID: source.nodeID, hasExplicitPhotoState: true)
        }
        if afterFailure, linkIDs.contains(source.nodeID) {
            if mode == .unknownMissingEntry { visibility[source.nodeID] = nil }
            if mode == .unknownState {
                visibility[source.nodeID] = RemoteLinkVisibility(
                    isActive: false, mainPhotoLinkID: nil, hasExplicitPhotoState: false)
            }
        }
        return visibility
    }

    func compound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        let shouldHold = lock.withLock {
            guard armed, linkID == source.nodeID, !held else { return false }
            held = true
            return true
        }
        if shouldHold { await gate.pass() }
        let actual = try await base.compound(ofMainLink: linkID)
        let intercept = lock.withLock {
            guard armed, linkID == source.nodeID else { return false }
            readHeld = true
            return true
        }
        if intercept, mode == .wrongHash, let actual {
            return UploadRemoteCompound(
                main: .init(
                    linkID: actual.main.linkID, contentHash: "wrong-content-hash",
                    nameHash: actual.main.nameHash, mimeType: actual.main.mimeType),
                related: actual.related, tags: actual.tags, externalIdentifier: actual.externalIdentifier,
                captureDate: actual.captureDate, modificationDate: actual.modificationDate)
        }
        if intercept, mode != .concurrentTrash && mode != .keeperUnknown && mode != .unknownOriginalMember {
            return nil
        }
        return actual
    }

    func nameHash(forCorrectedName name: String) async throws -> String {
        try await base.nameHash(forCorrectedName: name)
    }
    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        try await base.nameHashes(forCorrectedNames: names)
    }
    func contentHash(forSHA1Hex value: String) async throws -> String { try await base.contentHash(forSHA1Hex: value) }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        try await base.findDuplicates(nameHashes: nameHashes)
    }
    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async throws -> [PhotoUID] {
        try await base.findExactActiveDuplicates(correctedName: correctedName, sha1Digest: sha1Digest)
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        try await base.findDuplicate(contentHash: contentHash)
    }
    func findDuplicates(contentHash: String, limit: Int) async throws -> [RemotePhotoDuplicate] {
        try await base.findDuplicates(contentHash: contentHash, limit: limit)
    }
    func relatedPhotoLinkIDs(ofMainLinkID linkID: String) async throws -> Set<String> {
        try await base.relatedPhotoLinkIDs(ofMainLinkID: linkID)
    }
    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        try await base.linkStateSnapshot(of: linkIDs)
    }
    func activeMainLinkIDs(
        forExternalIdentifier identifier: String
    ) async throws -> (links: Set<String>, complete: Bool) {
        try await base.activeMainLinkIDs(forExternalIdentifier: identifier)
    }
    func replacingMainLinkIDs(ofReplacedLink linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        try await base.replacingMainLinkIDs(ofReplacedLink: linkID)
    }
    func externalIdentifier(ofMainLink linkID: String) async throws -> (identifier: String?, complete: Bool) {
        try await base.externalIdentifier(ofMainLink: linkID)
    }
    func modificationDate(ofMainLink linkID: String) async throws -> Date? {
        try await base.modificationDate(ofMainLink: linkID)
    }
    func replacedLinkIDs(ofReplacingMain linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        try await base.replacedLinkIDs(ofReplacingMain: linkID)
    }
    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await base.prepareRemoteIndex(progress: progress)
    }
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        try await base.remoteContentIndexHealth()
    }
    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        try await base.findRemoteAssetProofs(for: identities)
    }
    func invalidateCachedRemoteState() async { await base.invalidateCachedRemoteState() }
    func remoteMainsChangedHere() async { await base.remoteMainsChangedHere() }
    func recordUploaded(contentHash: String, remoteLinkID: String) async {
        await base.recordUploaded(contentHash: contentHash, remoteLinkID: remoteLinkID)
    }
    func hashKeyEpoch() async throws -> String { try await base.hashKeyEpoch() }
}

/// The timeout is a setup bound only. It always releases the test's held reader before the caller joins it.
private actor MemberCompoundReadGate {
    private let arrival = XCTestExpectation(description: "Member compound read after active visibility")
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pass() async {
        arrival.fulfill()
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitForArrival() async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [arrival], timeout: 5)
        if result != .completed { release() }
        XCTAssertEqual(result, .completed, "The production merge must reach the held compound boundary")
        return result == .completed
    }
    nonisolated func open() { Task { await self.release() } }
    private func release() {
        openState = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
