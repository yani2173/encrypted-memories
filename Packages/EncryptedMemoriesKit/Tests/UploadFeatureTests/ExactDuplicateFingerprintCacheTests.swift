import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// The metadata that a ranking read is kept for the next launch, as long as the content index stands at the same
/// cursor. The details only split groups on the screen; no test lets them join groups or decide a merge.
final class ExactDuplicateFingerprintCacheTests: XCTestCase {
    private var directory: URL!
    private var server: EditScenarioServer!
    private var manifest: UploadIdentityManifestStore!
    private var journal: EditReplacementJournalFileStore!
    private var openCaches: [ExactDuplicateFingerprintCache] = []
    private let epoch = "scenario-epoch"
    private let accountID = "account-one"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fingerprint-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manifest = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        server = EditScenarioServer()
    }

    override func tearDownWithError() throws {
        openCaches.forEach { $0.store.close() }
        openCaches = []
        manifest = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixture

    private var databaseURL: URL { directory.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName) }

    /// A cache on the account's file, as a launch opens it.
    private func openCache(accountID: String? = nil) throws -> ExactDuplicateFingerprintCache {
        let store = try XCTUnwrap(ExactDuplicateFingerprintStore(url: databaseURL, cacheDirectory: directory))
        let cache = ExactDuplicateFingerprintCache(store: store, accountID: accountID ?? self.accountID)
        openCaches.append(cache)
        return cache
    }

    private func finder(
        cache: ExactDuplicateFingerprintCache?, remote: (any ExactDuplicateRemote)? = nil,
        checker: (any UploadDuplicateChecking)? = nil
    ) -> ExactDuplicateFinder {
        ExactDuplicateFinder(
            checker: checker ?? server,
            resolver: UploadDedupePipeline(store: manifest, checker: server, replacementJournal: journal),
            index: manifest, identities: manifest, journal: journal,
            mergeJournal: ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory),
            remote: remote ?? server, albums: server, fingerprintCache: cache)
    }

    private func digest(_ seed: String) -> Data {
        var digest = Data(repeating: 0, count: 20)
        for (index, byte) in seed.utf8.enumerated() { digest[index % 20] ^= byte }
        return digest
    }

    private func details(_ device: String) -> ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(
            captureTime: Date(timeIntervalSince1970: 1_700_000_000), device: device, pixelWidth: 100, pixelHeight: 100)
    }

    /// Two copies of the same bytes. With one device name each, their metadata match; with two, they differ.
    @discardableResult
    private func seedPair(_ name: String, devices: (String, String)) -> [PhotoUID] {
        let pair = [server.seedLink(digest: digest(name)), server.seedLink(digest: digest(name))]
        server.setFingerprint(details(devices.0), of: pair[0])
        server.setFingerprint(details(devices.1), of: pair[1])
        return pair
    }

    /// The index as a backup build leaves it, with the cursor `eventID`.
    private func publishIndex(eventID: String, epoch: String? = nil) {
        Self.publishIndex(eventID: eventID, server: server, manifest: manifest, epoch: epoch ?? self.epoch)
    }

    private static func publishIndex(
        eventID: String, server: EditScenarioServer, manifest: UploadIdentityManifestStore, epoch: String
    ) {
        let records = server.links.map {
            UploadRemoteContentIndexRecord(contentHash: $0.contentHash, hashKeyEpoch: epoch, remoteLinkID: $0.linkID)
        }
        XCTAssertTrue(
            manifest.replaceRemoteContentIndex(
                records, unresolvedIssues: [], hashKeyEpoch: epoch,
                checkpoint: .init(eventID: eventID, refreshedAt: Date())))
    }

    /// One real duplicate and `different` candidate groups that the metadata check removes.
    private func seedLibrary(different: Int = 3) {
        seedPair("same", devices: ("camera", "camera"))
        for index in 0..<different { seedPair("other-\(index)", devices: ("camera", "phone")) }
        publishIndex(eventID: "event-1")
    }

    private var nodeReads: Int { server.readCounts.sharingMembers }

    // MARK: Relaunch

    @MainActor
    func testARelaunchWithoutAChangeOnTheVolumeShowsTheFinalCountOnTheFirstPageAndReadsOnlyTheSurvivors() async throws {
        seedLibrary()
        let first = ExactDuplicatesModel(finder: finder(cache: try openCache()))
        await first.load(checkAllGroups: true)
        XCTAssertEqual(first.groups.count, 1, "the metadata check leaves the one real duplicate")
        XCTAssertEqual(nodeReads, 8, "the first launch reads the node of every member of every candidate group")

        // A launch later: the same files, a new finder and a new model, and nothing changed on the volume.
        let held = HeldRanking(base: server)
        let relaunched = ExactDuplicatesModel(finder: finder(cache: try openCache(), remote: held))
        let readsBefore = nodeReads
        let loading = Task { await relaunched.load(checkAllGroups: true) }
        let arrived = await held.gate.waitForArrival()
        XCTAssertTrue(arrived, "the ranking of the surviving group starts")

        XCTAssertEqual(
            relaunched.groups.count, 1, "the first page already shows the final count; no group leaves it later")
        XCTAssertEqual(nodeReads - readsBefore, 0, "no node was read before the ranking of the surviving group")
        await held.gate.release()
        await loading.value
        XCTAssertEqual(relaunched.groups.count, 1)
        XCTAssertEqual(nodeReads - readsBefore, 2, "only the two members of the surviving group are read")
    }

    @MainActor
    func testAChangeOnTheVolumeBetweenTwoScansMakesTheNextLaunchReadEveryNode() async throws {
        seedLibrary()
        let first = ExactDuplicatesModel(finder: finder(cache: try openCache()))
        await first.load(checkAllGroups: true)
        publishIndex(eventID: "event-2")

        let readsBefore = nodeReads
        let relaunched = ExactDuplicatesModel(finder: finder(cache: try openCache()))
        await relaunched.load(checkAllGroups: true)

        XCTAssertEqual(relaunched.groups.count, 1)
        XCTAssertEqual(nodeReads - readsBefore, 8, "a moved cursor discards all details, so every node is read again")
    }

    func testDetailsOfAnotherAccountNeverSplitAGroup() async throws {
        seedLibrary()
        let writer = finder(cache: try openCache())
        let scan = try await writer.duplicateGroups()
        _ = await writer.rankedMembers(of: scan.groups)
        let own = await writer.storedFingerprints(of: scan.groups)
        XCTAssertFalse(own.isEmpty, "the account that wrote the details uses them")

        let other = finder(cache: try openCache(accountID: "account-two"))
        let again = try await other.duplicateGroups()
        let stored = await other.storedFingerprints(of: again.groups)
        XCTAssertTrue(stored.isEmpty, "another account's scope discards the details")
    }

    func testDetailsOfAnotherKeyEpochNeverSplitAGroup() async throws {
        seedLibrary()
        let cache = try openCache()
        let scan = try await finder(cache: cache).duplicateGroups()
        _ = await finder(cache: cache).rankedMembers(of: scan.groups)
        let members = scan.groups.flatMap(\.members)
        let foreign = ExactDuplicateGroup(contentHash: "foreign", hashKeyEpoch: "another-epoch", members: members)

        XCTAssertTrue(cache.details(of: [foreign]).isEmpty, "a group of another key epoch uses no details")
        XCTAssertFalse(cache.details(of: scan.groups).isEmpty, "the group of the scan's own epoch does")
    }

    // MARK: Order of the cursor

    func testACursorThatMovesBetweenTheScanAndTheRankingStoresNothing() async throws {
        seedLibrary()
        let cache = try openCache()
        let finder = finder(cache: cache)
        let scan = try await finder.duplicateGroups()
        publishIndex(eventID: "event-2")

        _ = await finder.rankedMembers(of: scan.groups)

        let members = scan.groups.flatMap(\.members)
        let store = cache.store
        let scope = ExactDuplicateFingerprintStore.Scope(accountID: accountID, volumeID: "vol", hashKeyEpoch: epoch)
        let older = try XCTUnwrap(store.prepare(scope: scope, eventID: "event-1"))
        XCTAssertNil(
            store.fingerprints(for: members, in: older), "nothing is saved under a cursor that the index left")
    }

    func testTheCursorIsReadBeforeTheFirstReadOfTheScan() async throws {
        seedLibrary()
        let cache = try openCache()
        // An event is applied to the index while the scan reads the link states.
        let (server, manifest, epoch) = (server!, manifest!, epoch)
        let moving = CursorMovingChecker(base: server) {
            Self.publishIndex(eventID: "event-2", server: server, manifest: manifest, epoch: epoch)
        }
        let finder = finder(cache: cache, checker: moving)
        let scan = try await finder.duplicateGroups()

        _ = await finder.rankedMembers(of: scan.groups)

        let scope = ExactDuplicateFingerprintStore.Scope(accountID: accountID, volumeID: "vol", hashKeyEpoch: epoch)
        let newer = try XCTUnwrap(cache.store.prepare(scope: scope, eventID: "event-2"))
        XCTAssertNil(
            cache.store.fingerprints(for: scan.groups.flatMap(\.members), in: newer),
            "the details of reads that began under event-1 are not usable under event-2")
    }

    @MainActor
    func testAChangeOfTheHashKeyEpochAtTheSameCursorMakesTheNextLaunchReadEveryNode() async throws {
        seedLibrary()
        let first = ExactDuplicatesModel(finder: finder(cache: try openCache()))
        await first.load(checkAllGroups: true)
        // The same links and the same cursor, indexed under another key epoch.
        publishIndex(eventID: "event-1", epoch: "epoch-two")

        let readsBefore = nodeReads
        let changed = finder(cache: try openCache(), checker: CursorMovingChecker(base: server, epoch: "epoch-two"))
        let relaunched = ExactDuplicatesModel(finder: changed)
        await relaunched.load(checkAllGroups: true)

        XCTAssertEqual(relaunched.groups.count, 1)
        XCTAssertEqual(nodeReads - readsBefore, 8, "details of another key epoch split nothing")
    }

    @MainActor
    func testWhatThisSessionReadBeatsWhatAnEarlierLaunchSaved() async throws {
        seedLibrary()
        let cache = try openCache()
        let model = ExactDuplicatesModel(finder: finder(cache: cache))
        await model.load(checkAllGroups: true)
        XCTAssertEqual(model.groups.count, 1)
        // The file now holds other details for the same links and the same cursor, as an older launch could leave.
        let scope = ExactDuplicateFingerprintStore.Scope(accountID: accountID, volumeID: "vol", hashKeyEpoch: epoch)
        let snapshot = try XCTUnwrap(cache.store.prepare(scope: scope, eventID: "event-1"))
        let pair = try XCTUnwrap(model.groups.first?.members)
        XCTAssertTrue(
            cache.store.store([pair[0]: details("one"), pair[1]: details("another")], for: snapshot),
            "the file holds different details for the real duplicate")

        await model.load(checkAllGroups: true)

        XCTAssertEqual(model.groups.count, 1, "the details that this session read decide, not the older ones")
    }

    @MainActor
    func testSavedDetailsOnlySplitGroupsAndNeverJoinTwoGroups() async throws {
        // Two candidate groups with different bytes, each a real duplicate, and the same metadata in both.
        seedPair("first", devices: ("camera", "camera"))
        seedPair("second", devices: ("camera", "camera"))
        publishIndex(eventID: "event-1")
        let first = ExactDuplicatesModel(finder: finder(cache: try openCache()))
        await first.load(checkAllGroups: true)
        XCTAssertEqual(first.groups.count, 2)

        let relaunched = ExactDuplicatesModel(finder: finder(cache: try openCache()))
        await relaunched.load(checkAllGroups: true)

        XCTAssertEqual(relaunched.groups.count, 2, "equal details in two groups never join them")
        XCTAssertEqual(Set(relaunched.groups.map { Set($0.members.map(\.nodeID)) }).count, 2)
    }

    func testARankingThatBeganBeforeANewerScanSavesNothingUnderTheNewerCursor() async throws {
        seedLibrary()
        let cache = try openCache()
        let held = HeldRanking(base: server)
        let finder = finder(cache: cache, remote: held)
        let scan = try await finder.duplicateGroups()
        let ranking = Task { await finder.rankedMembers(of: scan.groups) }
        let arrived = await held.gate.waitForArrival()
        XCTAssertTrue(arrived, "the ranking has taken its snapshot and waits before its node reads")
        // The index applies an event and a second scan begins, while the first ranking is still reading.
        publishIndex(eventID: "event-2")
        let rescan = try await finder.duplicateGroups()
        await held.gate.release()
        _ = await ranking.value

        let newer = try XCTUnwrap(cache.currentSnapshot())
        XCTAssertEqual(newer.eventID, "event-2")
        XCTAssertNil(
            cache.store.fingerprints(for: rescan.groups.flatMap(\.members), in: newer),
            "the details of reads that began under event-1 never carry event-2")
    }

    func testAFailedNodeReadSavesNothingForItsGroup() async throws {
        let lost = seedPair("lost", devices: ("camera", "camera"))
        seedPair("read", devices: ("camera", "camera"))
        publishIndex(eventID: "event-1")
        server.loseNode(lost[0])
        let cache = try openCache()
        let finder = finder(cache: cache)
        let scan = try await finder.duplicateGroups()

        _ = await finder.rankedMembers(of: scan.groups)

        let stored = await finder.storedFingerprints(of: scan.groups)
        XCTAssertTrue(lost.allSatisfy { stored[$0] == nil }, "no details exist for a group whose read failed")
        XCTAssertEqual(stored.count, 2, "the group that was read keeps its details")
    }

    // MARK: Fallbacks

    func testAScanWithoutACursorSavesAndUsesNothing() throws {
        let cache = try openCache()
        let member = [PhotoUID(volumeID: "vol", nodeID: "a"), PhotoUID(volumeID: "vol", nodeID: "b")]
        let group = ExactDuplicateGroup(contentHash: "hash", hashKeyEpoch: epoch, members: member)

        cache.begin(volumeID: "vol", hashKeyEpoch: epoch, eventID: nil)
        cache.record(
            Dictionary(uniqueKeysWithValues: member.map { ($0, details("camera")) }), for: cache.currentSnapshot(),
            currentEventID: nil)

        XCTAssertTrue(cache.details(of: [group]).isEmpty)
        cache.begin(volumeID: "vol", hashKeyEpoch: epoch, eventID: "event-1")
        XCTAssertTrue(cache.details(of: [group]).isEmpty, "the earlier call without a cursor saved nothing")
    }

    func testADamagedStoreFileKeepsEveryNodeReadAndNeverBlocksTheScan() async throws {
        seedLibrary()
        let cache = try openCache()
        let first = finder(cache: cache)
        let scan = try await first.duplicateGroups()
        _ = await first.rankedMembers(of: scan.groups)
        cache.store.close()
        try Data("this is not a database".utf8).write(to: databaseURL)

        // A damaged file opens no cache. The finder then runs without one, as on the first launch.
        XCTAssertNil(ExactDuplicateFingerprintCache.open(accountDirectory: directory))
        let later = finder(cache: nil)
        let again = try await later.duplicateGroups()
        let ranked = await later.rankedMembers(of: again.groups)
        XCTAssertEqual(again.groups.count, 4, "the scan is not blocked")
        XCTAssertEqual(ranked.count, 4, "the ranking reads every node")
    }

    func testAMissingStoreKeepsEveryNodeReadAndNeverBlocksTheScan() async throws {
        seedLibrary()
        let plain = finder(cache: nil)
        let scan = try await plain.duplicateGroups()
        let ranked = await plain.rankedMembers(of: scan.groups)
        XCTAssertEqual(scan.groups.count, 4)
        XCTAssertEqual(ranked.count, 4)
        let stored = await plain.storedFingerprints(of: scan.groups)
        XCTAssertTrue(stored.isEmpty)
    }

    func testAGroupWithAnUnreadableRowFallsBackToNodeReadsWhileOthersKeepTheirDetails() async throws {
        seedLibrary()
        let cache = try openCache()
        let first = finder(cache: cache)
        let scan = try await first.duplicateGroups()
        _ = await first.rankedMembers(of: scan.groups)
        let broken = try XCTUnwrap(scan.groups.first)
        cache.store.close()
        try changeDatabase("UPDATE fingerprint SET payload=x'00' WHERE link_id='\(broken.members[0].nodeID)';")

        let later = finder(cache: try openCache())
        let again = try await later.duplicateGroups()
        let stored = await later.storedFingerprints(of: again.groups)

        XCTAssertTrue(broken.members.allSatisfy { stored[$0] == nil }, "the whole group keeps the ranking path")
        let others = scan.groups.dropFirst().flatMap(\.members)
        XCTAssertFalse(others.isEmpty)
        XCTAssertTrue(others.allSatisfy { stored[$0] != nil }, "the other groups keep their details")
    }

    // MARK: Cleanup

    /// The cache of the account `uid`, opened where production opens it, with a fingerprint saved in it.
    private func productionCache(uid: String, in base: URL) throws -> (cache: ExactDuplicateFingerprintCache, url: URL)
    {
        let account = LibraryDatabaseLocation.prepareAccountDirectory(uid: uid, in: base)
        let cache = try XCTUnwrap(ExactDuplicateFingerprintCache.open(accountDirectory: account))
        let members = [PhotoUID(volumeID: "vol", nodeID: "a"), PhotoUID(volumeID: "vol", nodeID: "b")]
        cache.begin(volumeID: "vol", hashKeyEpoch: "e", eventID: "event")
        cache.record(
            Dictionary(uniqueKeysWithValues: members.map { ($0, details("camera")) }), for: cache.currentSnapshot(),
            currentEventID: "event")
        let group = ExactDuplicateGroup(contentHash: "h", hashKeyEpoch: "e", members: members)
        XCTAssertFalse(cache.details(of: [group]).isEmpty, "the cache holds details before the purge")
        return (cache, account.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName))
    }

    func testTheStoreLivesInTheAccountDirectoryThatSignOutRemoves() async throws {
        let base = directory.appendingPathComponent("accounts", isDirectory: true)
        let (cache, url) = try productionCache(uid: "uid-sign-out", in: base)
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            LibraryDatabaseLocation.accountDirectory(uid: "uid-sign-out", in: base).standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        cache.close()

        XCTAssertTrue(LibraryDatabaseLocation.purgeAccountData(uid: "uid-sign-out", in: base))

        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix), "file \(suffix) is gone")
        }
    }

    func testTheSignOutPurgeOfTheLocalRootsRemovesTheStoreFileWithItsSidecars() async throws {
        let root = directory.appendingPathComponent("EncryptedMemories", isDirectory: true)
        let (cache, url) = try productionCache(uid: "uid-purge", in: root)
        cache.close()

        let result = BackupLocalDataPurge.purgeAllLocalAccountData(roots: [root])

        XCTAssertTrue(result.succeeded)
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }
    }

    func testAnAccountSwitchUsesAnotherFileAndNeverTheDetailsOfTheFirstAccount() async throws {
        let base = directory.appendingPathComponent("accounts", isDirectory: true)
        let (first, firstURL) = try productionCache(uid: "uid-one", in: base)
        let second = try XCTUnwrap(
            ExactDuplicateFingerprintCache.open(
                accountDirectory: LibraryDatabaseLocation.prepareAccountDirectory(uid: "uid-two", in: base)))
        let group = ExactDuplicateGroup(
            contentHash: "h", hashKeyEpoch: "e",
            members: [PhotoUID(volumeID: "vol", nodeID: "a"), PhotoUID(volumeID: "vol", nodeID: "b")])
        second.begin(volumeID: "vol", hashKeyEpoch: "e", eventID: "event")

        XCTAssertTrue(second.details(of: [group]).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path), "the first account keeps its own file")
        first.close()
        second.close()
    }

    // MARK: Helpers

    private func changeDatabase(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}

/// Holds the favorites listing, the first read of a ranking, while its gate is closed.
private final class HeldRanking: EditScenarioDuplicateRemote, @unchecked Sendable {
    let base: EditScenarioServer
    let gate = RankingGate()

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

private actor RankingGate {
    private var isOpen = false
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrived = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// True once a read arrived at the gate; false after ten seconds.
    func waitForArrival() async -> Bool {
        for _ in 0..<200 {
            if arrived { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return arrived
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Runs `onVisibilityRead` when the scan reads the link states, as an event applied to the index during the scan.
private struct CursorMovingChecker: UploadDuplicateChecking {
    let base: EditScenarioServer
    let onVisibilityRead: @Sendable () -> Void
    /// The key epoch that the checker reports, as after a change of the hash key. Nil: the server's own.
    let epoch: String?

    init(base: EditScenarioServer, epoch: String? = nil, onVisibilityRead: @escaping @Sendable () -> Void = {}) {
        self.base = base
        self.epoch = epoch
        self.onVisibilityRead = onVisibilityRead
    }

    func nameHash(forCorrectedName name: String) async throws -> String {
        try await base.nameHash(forCorrectedName: name)
    }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        try await base.contentHash(forSHA1Hex: sha1Hex)
    }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        try await base.findDuplicates(nameHashes: nameHashes)
    }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        try await base.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
    }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        try await linkVisibility(of: linkIDs, requiresCompleteResponse: true)
    }
    func linkVisibility(
        of linkIDs: [String], requiresCompleteResponse: Bool
    ) async throws -> [String: RemoteLinkVisibility] {
        onVisibilityRead()
        return try await base.linkVisibility(of: linkIDs)
    }
    func compound(ofMainLink linkID: String) async throws -> UploadRemoteCompound? {
        try await base.compound(ofMainLink: linkID)
    }
    func hashKeyEpoch() async throws -> String {
        if let epoch { return epoch }
        return try await base.hashKeyEpoch()
    }
    func replacingMainLinkIDs(ofReplacedLink linkID: String) async throws -> (links: Set<String>, complete: Bool) {
        try await base.replacingMainLinkIDs(ofReplacedLink: linkID)
    }
}
