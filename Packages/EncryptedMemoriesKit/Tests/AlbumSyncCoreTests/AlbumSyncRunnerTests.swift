import Foundation
import PhotosCore
import SQLite3
import Testing
import UploadCore

@testable import AlbumSyncCore

private struct FakeLocalSource: AlbumSyncLocalAlbumSource {
    var albums: [LocalAlbumSummary] = []
    var contents: [String: AlbumSyncLocalAlbumContents] = [:]

    func listAlbums() async throws -> [LocalAlbumSummary] { albums }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        contents[albumID] ?? .missing
    }

    func albumExists(albumID: String) async throws -> Bool {
        guard case .present = contents[albumID] else { return false }
        return true
    }
}

private actor ScriptedLocalAlbumSource: AlbumSyncLocalAlbumSource {
    private var contents: AlbumSyncLocalAlbumContents
    private var existenceResults: [Bool]

    init(contents: AlbumSyncLocalAlbumContents, existenceResults: [Bool] = []) {
        self.contents = contents
        self.existenceResults = existenceResults
    }

    func listAlbums() async throws -> [LocalAlbumSummary] { [] }

    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents { contents }

    func albumExists(albumID: String) async throws -> Bool {
        if !existenceResults.isEmpty { return existenceResults.removeFirst() }
        guard case .present = contents else { return false }
        return true
    }

    func setContents(_ newContents: AlbumSyncLocalAlbumContents) {
        contents = newContents
    }
}

private final class FakeBackupExecutor: AlbumSyncBackupExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [[String]] = []
    var runs: [[String]] { lock.withLock { _runs } }
    var proofLinks: [String: AlbumSyncRemoteLink] = [:]
    var proofError: (any Error)?
    var cancelsProofCaller = false
    private var _proofRuns: [[String]] = []
    var proofRuns: [[String]] { lock.withLock { _proofRuns } }
    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        lock.withLock { _proofRuns.append(localIdentifiers) }
        if cancelsProofCaller { withUnsafeCurrentTask { $0?.cancel() } }
        if let proofError { throw proofError }
        return proofLinks
    }
    var stopped = false
    var onStop: (@Sendable () async -> Void)?
    /// The unresolved scratch-queue rows and filenames the next run reports.
    var problems: [String: BackupFailedItem] = [:]
    var filenames: [String: String] = [:]

    func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        lock.withLock { _runs.append(localIdentifiers) }
        var progress = BackupSyncProgress()
        progress.total = localIdentifiers.count
        progress.uploaded = localIdentifiers.count
        onProgress(progress)
        return AlbumSyncBackupReport(
            total: localIdentifiers.count, backedUp: localIdentifiers.count - problems.count,
            failed: problems.count, sourceMissing: 0, skippedRemoteDeletion: 0,
            problems: problems, filenames: filenames
        )
    }

    func stop() async {
        lock.withLock { stopped = true }
        await onStop?()
    }
}

private final class FakeRemoteOps: AlbumSyncRemoteAlbumOps, @unchecked Sendable {
    private let lock = NSLock()
    var remoteAlbums: [AlbumSyncRemoteAlbum] = []
    var children: Set<String> = []
    var failAttachOf: Set<String> = []
    /// The reason that the fake backend gives for a failed link; "attach failed" otherwise.
    var failureMessageOf: [String: String] = [:]
    var alreadyMemberOf: Set<String> = []
    private var _created: [String] = []
    private var _attached: [[String]] = []
    private var _listCount = 0
    private var _childCount = 0
    var childCount: Int { lock.withLock { _childCount } }
    var createdNames: [String] { lock.withLock { _created } }
    var attachedBatches: [[String]] { lock.withLock { _attached } }
    var listCount: Int { lock.withLock { _listCount } }
    var nextAlbumID = "remote-album-1"
    var sameContent: [String: Set<String>] = [:]
    var sameContentError: (any Error)?
    var deletionStates: [String: UploadRemoteDeletionState] = [:]
    var deletionError: (any Error)?
    var deletionLookup: (@Sendable ([AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState])?
    private var _deletionRequests: [[String]] = []
    var deletionRequests: [[String]] { lock.withLock { _deletionRequests } }

    func remoteDeletionStates(for links: [AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState] {
        lock.withLock { _deletionRequests.append(links.map(\.uid.nodeID).sorted()) }
        if let deletionError { throw deletionError }
        if let deletionLookup { return try await deletionLookup(links) }
        return deletionStates
    }
    /// The first lookup call (1-based) that throws `sameContentError`; earlier calls answer normally.
    var sameContentFailsFromCall = 1
    private var _sameContentRequests: [Set<String>] = []
    var sameContentRequests: [Set<String>] { lock.withLock { _sameContentRequests } }

    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] {
        lock.withLock { _listCount += 1 }
        return remoteAlbums
    }

    func createAlbum(name: String) async throws -> String {
        lock.withLock { _created.append(name) }
        return nextAlbumID
    }

    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        lock.withLock { _childCount += 1 }
        return children
    }

    func activeMainLinkIDs(withSameContentAs sha1Hexes: Set<String>) async throws -> [String: Set<String>] {
        let call = lock.withLock {
            _sameContentRequests.append(sha1Hexes)
            return _sameContentRequests.count
        }
        if let sameContentError, call >= sameContentFailsFromCall { throw sameContentError }
        return sameContent.filter { sha1Hexes.contains($0.key) }
    }

    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        lock.withLock { _attached.append(photos.map(\.uid.nodeID)) }
        var result = AlbumSyncAttachResult()
        for photo in photos {
            if failAttachOf.contains(photo.uid.nodeID) {
                let message = failureMessageOf[photo.uid.nodeID] ?? "attach failed"
                result.failed += 1
                result.failedLinkIDs.append(photo.uid.nodeID)
                result.failureMessages[photo.uid.nodeID] = message
                if result.firstFailureMessage == nil { result.firstFailureMessage = message }
            } else if alreadyMemberOf.contains(photo.uid.nodeID) {
                result.alreadyMember += 1
            } else {
                result.attached += 1
            }
        }
        return result
    }
}

private final class FakeLinkLookup: AlbumSyncRemoteLinkLookup, @unchecked Sendable {
    var links: [String: AlbumSyncRemoteLink] = [:]
    func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink] {
        links.filter { localIdentifiers.contains($0.key) }
    }
}

private func makeStore() -> AlbumSyncMappingStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("album-sync-tests-\(UUID().uuidString).sqlite")
    return AlbumSyncMappingStore(url: url)!
}

private func link(_ id: String, trashed: Bool = false) -> AlbumSyncRemoteLink {
    // Each photo has its own bytes.
    AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: "sha-\(id)", isTrashed: trashed)
}

@Suite struct AlbumSyncRunnerTests {
    private func makeRunner(
        contents: [String: [String]],
        links: [String: AlbumSyncRemoteLink],
        remote: FakeRemoteOps = FakeRemoteOps(),
        backup: FakeBackupExecutor = FakeBackupExecutor(),
        store: AlbumSyncMappingStore = makeStore(),
        localSource: (any AlbumSyncLocalAlbumSource)? = nil
    ) -> (AlbumSyncRunner, FakeRemoteOps, FakeBackupExecutor, AlbumSyncMappingStore) {
        let lookup = FakeLinkLookup()
        lookup.links = links
        let typedContents = contents.mapValues { AlbumSyncLocalAlbumContents.present($0) }
        let runner = AlbumSyncRunner(
            localSource: localSource ?? FakeLocalSource(albums: [], contents: typedContents),
            backup: backup,
            remoteOps: remote,
            linkLookup: lookup,
            mappingStore: store,
            attachChunkSize: 2
        )
        return (runner, remote, backup, store)
    }

    private let album = LocalAlbumSummary(id: "local-1", title: "Urlaub", assetCount: 3)

    @Test func freshExplicitTrashIsReportedWithoutAnAttach() async throws {
        let remote = FakeRemoteOps()
        remote.deletionStates = ["trash": .trashed]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["photo"]], links: ["photo": link("trash")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(remote.attachedBatches.isEmpty)
        #expect(report.trashedSkipped == 1)
        #expect(report.problems.first?.issue == .remoteDeletion)
        #expect(!report.isFullySynced)
    }

    @Test func unknownOrFailedDeletionEvidenceKeepsTheExistingAttach() async throws {
        for fails in [false, true] {
            let remote = FakeRemoteOps()
            if fails { remote.deletionError = AlbumSyncError.mappingStoreUnavailable }
            let (runner, _, _, _) = makeRunner(
                contents: ["album": ["photo"]], links: ["photo": link("unknown")], remote: remote)
            let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
            #expect(remote.deletionRequests == [["unknown"]])
            #expect(remote.attachedBatches.flatMap { $0 } == ["unknown"])
            #expect(report.problems.isEmpty)
            #expect(report.isFullySynced)
        }
    }

    @Test func transportAndTypedDeletionCancellationPreventAttachment() async throws {
        let errors: [any Error] = [
            URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: URLError.cancelled.rawValue, message: "cancelled"),
        ]
        for error in errors {
            let remote = FakeRemoteOps()
            remote.deletionError = error
            let (runner, _, _, _) = makeRunner(
                contents: ["album": ["photo"]], links: ["photo": link("known")], remote: remote)
            do {
                _ = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
                Issue.record("cancellation must end sync")
            } catch {
                #expect(!Task.isCancelled)
            }
            #expect(remote.attachedBatches.isEmpty)
        }
    }

    @Test func stopCancelsAndJoinsDeletionLookupBeforeAnotherMetadataBatch() async throws {
        let entered = Gate()
        let release = Gate()
        let stopEntered = Gate()
        let stopReturned = Gate()
        let checker = GatedDeletionChecker(entered: entered, release: release)
        let remote = FakeRemoteOps()
        remote.deletionLookup = { links in
            try await UploadRemoteDeletionLookup.states(for: links.map { $0.uid.nodeID }, checker: checker)
        }
        let backup = FakeBackupExecutor()
        backup.onStop = { await stopEntered.open() }
        let ids = (0..<301).map { "photo-\($0)" }
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ids], links: Dictionary(uniqueKeysWithValues: ids.map { ($0, link($0)) }),
            remote: remote, backup: backup)
        let sync = Task { try await runner.sync(album: .init(id: "album", title: "Album", assetCount: ids.count)) }
        #expect(await waitForDeletionGate(entered))
        let stop = Task {
            await runner.stop()
            await stopReturned.open()
        }
        #expect(await waitForDeletionGate(stopEntered))
        // The metadata operation ignores cancellation until released. Stop must retain and join it.
        for _ in 0..<20 { await Task.yield() }
        #expect(await stopReturned.opened == false)
        await release.open()
        await stop.value
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(checker.requestCount == 1)
        #expect(checker.observedCancellation)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func callerCancellationCancelsAndJoinsTheDeletionLookup() async throws {
        let entered = Gate()
        let release = Gate()
        let checker = GatedDeletionChecker(entered: entered, release: release)
        let remote = FakeRemoteOps()
        remote.deletionLookup = { links in
            try await UploadRemoteDeletionLookup.states(for: links.map { $0.uid.nodeID }, checker: checker)
        }
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["photo"]], links: ["photo": link("known")], remote: remote)
        let sync = Task { try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1)) }
        #expect(await waitForDeletionGate(entered))
        sync.cancel()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(checker.observedCancellation)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func aFullySyncedAlbumDoesNotReadDeletionEvidence() async throws {
        let remote = FakeRemoteOps()
        remote.children = ["member"]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["photo"]], links: ["photo": link("member")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(remote.deletionRequests.isEmpty)
        #expect(report.isFullySynced)
    }

    @Test func asksProofOnlyForMissingManifestLinksAndKeepsExistingAndTrashedLinks() async throws {
        let backup = FakeBackupExecutor()
        backup.proofLinks = ["known": link("wrong"), "missing": link("proven"), "trashed": link("wrong-trash")]
        let (runner, remote, _, _) = makeRunner(
            contents: ["album": ["known", "missing", "trashed"]],
            links: ["known": link("existing"), "trashed": link("deleted", trashed: true)], backup: backup)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 3))
        #expect(backup.proofRuns == [["missing"]])
        #expect(remote.attachedBatches.flatMap { $0 } == ["existing", "proven"])
        #expect(report.attached == 2)
        #expect(report.trashedSkipped == 1)
        #expect(report.unattachable == 0)
    }

    @Test func aPhotoWhoseCopyIsAlreadyInTheAlbumIsNotAddedAgain() async throws {
        // Device B's copy of a shared photo has its own link; device A's copy with the same bytes is a member.
        let remote = FakeRemoteOps()
        remote.children = ["copy-a"]
        remote.sameContent = ["sha-copy-b": ["copy-a", "copy-b"]]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["shared", "own"]], links: ["shared": link("copy-b"), "own": link("own")],
            remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(remote.sameContentRequests == [["sha-copy-b", "sha-own"]])
        #expect(remote.attachedBatches.flatMap { $0 } == ["own"])
        #expect(report.attached == 1)
        #expect(report.alreadyMember == 1)
        #expect(report.isFullySynced)
    }

    @Test func aCopyOutsideTheAlbumDoesNotStandInForTheAlbum() async throws {
        let remote = FakeRemoteOps()
        remote.children = ["member"]
        remote.sameContent = ["sha-copy-b": ["a-copy-elsewhere", "copy-b"]]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["shared"]], links: ["shared": link("copy-b")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(remote.attachedBatches.flatMap { $0 } == ["copy-b"])
        #expect(report.attached == 1)
        #expect(report.alreadyMember == 0)
    }

    @Test func aFailedSameContentLookupAddsThePhotoAsBefore() async throws {
        let remote = FakeRemoteOps()
        remote.children = ["copy-a"]
        remote.sameContent = ["sha-copy-b": ["copy-a"]]
        remote.sameContentError = AlbumSyncError.mappingStoreUnavailable
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["shared"]], links: ["shared": link("copy-b")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(remote.sameContentRequests.count == 1)
        #expect(remote.attachedBatches.flatMap { $0 } == ["copy-b"])
        #expect(report.attached == 1)
        #expect(report.isFullySynced)
    }

    @Test func aCancelledIndexRefreshAddsThePhotoAsBefore() async throws {
        // The content index throws CancellationError when it is reset; the sync itself was not cancelled.
        let remote = FakeRemoteOps()
        remote.children = ["copy-a"]
        remote.sameContentError = CancellationError()
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["shared"]], links: ["shared": link("copy-b")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(remote.attachedBatches.flatMap { $0 } == ["copy-b"])
        #expect(report.attached == 1)
    }

    @Test func aFailedLaterChunkKeepsTheMembersAlreadyFound() async throws {
        let remote = FakeRemoteOps()
        remote.children = ["copy-a"]
        remote.sameContent = ["sha-copy-b": ["copy-a"]]
        remote.sameContentError = AlbumSyncError.mappingStoreUnavailable
        remote.sameContentFailsFromCall = 2
        // Chunks of two, in SHA-1 order: [sha-copy-b, sha-own-1], then [sha-own-2].
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["shared", "own-1", "own-2"]],
            links: ["shared": link("copy-b"), "own-1": link("own-1"), "own-2": link("own-2")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 3))
        #expect(remote.sameContentRequests.count == 2)
        #expect(remote.attachedBatches.flatMap { $0 } == ["own-1", "own-2"])
        #expect(report.alreadyMember == 1)
    }

    @Test func stopBetweenLookupChunksAddsNothingAndAsksNoFurther() async throws {
        let entered = Gate()
        let release = Gate()
        let remote = FakeRemoteOps()
        remote.children = ["member"]
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("la"), "b": link("lb"), "c": link("lc")]
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(albums: [], contents: ["album": .present(["a", "b", "c"])]),
            backup: FakeBackupExecutor(),
            remoteOps: GatedSameContentRemoteOps(base: remote, entered: entered, release: release),
            linkLookup: lookup, mappingStore: makeStore(), attachChunkSize: 2)
        let sync = Task { try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 3)) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(remote.sameContentRequests == [["sha-la", "sha-lb"]], "the second chunk is never asked")
        #expect(remote.attachedBatches.isEmpty)
    }

    private func sameBytes(_ id: String) -> AlbumSyncRemoteLink {
        AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: "same", isTrashed: false)
    }

    @Test func aTwinWithTheSameBytesAttachesWhenTheFirstLinkFails() async throws {
        // The first link fails, for example because it was deleted in Proton Drive; the twin's own link still works.
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la"]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "b"]], links: ["a": sameBytes("la"), "b": sameBytes("lb")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(remote.attachedBatches == [["la"], ["lb"]])
        #expect(report.attached == 1)
        #expect(report.attachFailed == 0, "the bytes are in the album through the twin")
        #expect(report.problems.isEmpty)
        #expect(report.isFullySynced)
    }

    @Test func aTwinThatAttachedKeepsItsOpenBackupReason() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la"]
        let backup = FakeBackupExecutor()
        backup.problems = [
            "b": BackupFailedItem(
                id: "queue-b", filename: "b.heic", reason: "still finishing", isPermanent: false,
                issue: .remoteDraft, source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "b"),
                category: .automatic)
        ]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "b"]], links: ["a": sameBytes("la"), "b": sameBytes("lb")], remote: remote,
            backup: backup)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(report.attached == 1)
        #expect(report.incomplete == 1, "photo b is in the album with an open backup row")
        #expect(report.problems.map { $0.source?.identifier } == ["b"])
    }

    @Test func everyTriedTwinIsNamedWhenNoneAttaches() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la", "lb"]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "b"]], links: ["a": sameBytes("la"), "b": sameBytes("lb")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(remote.attachedBatches == [["la"], ["lb"]])
        #expect(report.attached == 0)
        #expect(report.attachFailed == 2)
        #expect(report.problems.map { $0.source?.identifier } == ["a", "b"])
        #expect(!report.isFullySynced)
    }

    @Test func theNextTwinIsTriedAfterTheSecondFails() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la", "lb"]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "b", "c"]],
            links: ["a": sameBytes("la"), "b": sameBytes("lb"), "c": sameBytes("lc")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 3))
        #expect(remote.attachedBatches == [["la"], ["lb"], ["lc"]])
        #expect(report.attached == 1)
        #expect(report.attachFailed == 0)
        #expect(report.problems.isEmpty)
    }

    private func own(_ id: String) -> AlbumSyncRemoteLink {
        AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: "own-\(id)", isTrashed: false)
    }

    @Test func theMessageNamesAFailureThatRemainsNotOneThatATwinResolved() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la", "lc"]
        remote.failureMessageOf = ["la": "M1", "lc": "M2"]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "c", "b"]], links: ["a": sameBytes("la"), "b": sameBytes("lb"), "c": own("lc")],
            remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 3))
        #expect(remote.attachedBatches == [["la", "lc"], ["lb"]])
        #expect(report.attachFailed == 1)
        #expect(report.problems.map { $0.source?.identifier } == ["c"])
        #expect(await runner.currentProgress.message == "M2", "photo a is in the album through its twin")
    }

    @Test func twoPlannedLinksFailInOneRoundAndOnlyTheUnresolvedOnesAreNamed() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la", "lc", "ld"]
        let other = { (id: String) in
            AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: "other", isTrashed: false)
        }
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "c", "b", "d"]],
            links: ["a": sameBytes("la"), "b": sameBytes("lb"), "c": other("lc"), "d": other("ld")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 4))
        #expect(remote.attachedBatches == [["la", "lc"], ["lb", "ld"]])
        #expect(report.attached == 1)
        #expect(report.attachFailed == 2)
        #expect(report.problems.map { $0.source?.identifier } == ["c", "d"])
    }

    @Test func aTwinThatIsAlreadyAMemberResolvesTheFailedLink() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la"]
        remote.alreadyMemberOf = ["lb"]
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "b"]], links: ["a": sameBytes("la"), "b": sameBytes("lb")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(report.attached == 0)
        #expect(report.alreadyMember == 1)
        #expect(report.attachFailed == 0)
        #expect(report.problems.isEmpty)
    }

    @Test func theFailureCountDoesNotRiseWhileTwinsAreTried() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["la", "lb"]
        let progress = ProgressBox()
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["a", "b", "c"]],
            links: ["a": sameBytes("la"), "b": sameBytes("lb"), "c": sameBytes("lc")], remote: remote)
        await runner.setOnProgress { progress.append($0) }
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 3))
        #expect(report.attachFailed == 0)
        let published = progress.snapshot().map(\.attachFailed)
        #expect(published.max() == 1, "only the planned link's failure shows before the twins resolve it")
        #expect(published.last == 0)
    }

    @Test func aLocalMemberWithTheSameBytesCountsWhenTheLookupFails() async throws {
        let remote = FakeRemoteOps()
        remote.children = ["lx"]
        remote.sameContentError = AlbumSyncError.mappingStoreUnavailable
        let (runner, _, _, _) = makeRunner(
            contents: ["album": ["x", "y"]], links: ["x": sameBytes("lx"), "y": sameBytes("ly")], remote: remote)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(remote.sameContentRequests.isEmpty, "the bytes are known locally, so nothing is asked")
        #expect(remote.attachedBatches.isEmpty)
        #expect(report.alreadyMember == 1)
        #expect(report.isFullySynced)
    }

    @Test func noSameContentLookupWhenNothingCanMatch() async throws {
        let emptyAlbum = FakeRemoteOps()
        let (first, _, _, _) = makeRunner(
            contents: ["album": ["a"]], links: ["a": link("la")], remote: emptyAlbum)
        _ = try await first.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(emptyAlbum.sameContentRequests.isEmpty, "an empty album has no member to match")

        let allMembers = FakeRemoteOps()
        allMembers.children = ["la"]
        let (second, _, _, _) = makeRunner(
            contents: ["album": ["a"]], links: ["a": link("la")], remote: allMembers)
        _ = try await second.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(allMembers.sameContentRequests.isEmpty, "every photo is already a member")
    }

    @Test func stopDuringSameContentLookupAddsNothing() async throws {
        let entered = Gate()
        let release = Gate()
        let remote = FakeRemoteOps()
        remote.children = ["member"]
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("la")]
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(albums: [], contents: ["album": .present(["a"])]),
            backup: FakeBackupExecutor(),
            remoteOps: GatedSameContentRemoteOps(base: remote, entered: entered, release: release),
            linkLookup: lookup, mappingStore: makeStore())
        let sync = Task { try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1)) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func skipsProofLookupWhenEveryManifestLinkExists() async throws {
        let (runner, _, backup, _) = makeRunner(contents: ["album": ["known"]], links: ["known": link("existing")])
        _ = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 1))
        #expect(backup.proofRuns.isEmpty)
    }

    @Test(arguments: ["queue", "catalog", "admission"])
    func proofLookupFailureKeepsManifestPhotosAttachable(failure: String) async throws {
        let backup = FakeBackupExecutor()
        backup.proofError =
            failure == "catalog"
            ? UploadError.backend("catalog failed")
            : (failure == "queue" ? AlbumSyncError.mappingStoreUnavailable : AlbumSyncError.alreadyRunning)
        let (runner, remote, _, _) = makeRunner(
            contents: ["album": ["known", "missing"]], links: ["known": link("existing")], backup: backup)
        let report = try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        #expect(backup.proofRuns == [["missing"]])
        #expect(remote.childCount == 1)
        #expect(remote.attachedBatches == [["existing"]])
        #expect(report.attached == 1)
        #expect(report.unattachable == 1)
        #expect(report.problems.map { $0.source?.identifier } == ["missing"])
        #expect(report.problems.allSatisfy { $0.isRetryable })
    }

    @Test func cancelledProofCallerWithOrdinaryErrorAdmitsNoFurtherWork() async throws {
        let backup = FakeBackupExecutor()
        backup.cancelsProofCaller = true
        backup.proofError = UploadError.backend("catalog failed")
        let (runner, remote, _, _) = makeRunner(
            contents: ["album": ["known", "missing"]], links: ["known": link("existing")], backup: backup)
        let sync = Task {
            try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        }
        await #expect(throws: (any Error).self) { try await sync.value }
        #expect(remote.childCount == 0)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func transportCancellationFromProofOrSameContentNeverAttaches() async throws {
        let errors: [any Error] = [
            URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: URLError.cancelled.rawValue, message: "cancelled"),
        ]
        for route in ["proof", "same-content"] {
            for failure in errors {
                let backup = FakeBackupExecutor()
                let remote = FakeRemoteOps()
                if route == "proof" {
                    backup.proofError = failure
                } else {
                    remote.children = ["existing-member"]
                    remote.sameContentError = failure
                }
                let (runner, _, _, _) = makeRunner(
                    contents: ["album": ["known", "missing"]], links: ["known": link("existing")],
                    remote: remote, backup: backup)
                await #expect(throws: (any Error).self) {
                    try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
                }
                #expect(remote.attachedBatches.isEmpty)
                #expect(!Task.isCancelled)
            }
        }
    }

    @Test func proofLookupCancellationWithoutStopStillPropagates() async throws {
        let backup = FakeBackupExecutor()
        backup.proofError = CancellationError()
        let (runner, remote, _, _) = makeRunner(
            contents: ["album": ["known", "missing"]], links: ["known": link("existing")], backup: backup)
        await #expect(throws: CancellationError.self) {
            try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        }
        #expect(remote.childCount == 0)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func proofLookupStoppedErrorWithoutLocalStopStillPropagates() async throws {
        let backup = FakeBackupExecutor()
        backup.proofError = AlbumSyncError.stopped
        let (runner, remote, _, _) = makeRunner(
            contents: ["album": ["known", "missing"]], links: ["known": link("existing")], backup: backup)
        await #expect(throws: AlbumSyncError.stopped) {
            try await runner.sync(album: .init(id: "album", title: "Album", assetCount: 2))
        }
        #expect(remote.childCount == 0)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func stopDuringProofFailurePreventsFallbackAttachment() async throws {
        let entered = Gate()
        let release = Gate()
        let remote = FakeRemoteOps()
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(contents: ["local-1": .present(["known", "missing"])]),
            backup: GatedProofExecutor(
                entered: entered, release: release, failure: UploadError.backend("catalog failed")),
            remoteOps: remote, linkLookup: FakeLinkLookup(), mappingStore: makeStore())
        let albumToSync = album
        let sync = Task { try await runner.sync(album: albumToSync) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(remote.childCount == 0)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func stopDuringCreateSavesMappingAndRetryCreatesNoSecondAlbum() async throws {
        let entered = Gate()
        let release = Gate()
        let remote = FakeRemoteOps()
        let store = makeStore()
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("known")]
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(contents: ["local-1": .present(["a"])]),
            backup: FakeBackupExecutor(),
            remoteOps: GatedCreateRemoteOps(base: remote, entered: entered, release: release),
            linkLookup: lookup, mappingStore: store)
        let albumToSync = album
        let sync = Task { try await runner.sync(album: albumToSync) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        let mapping = try #require(store.mapping(localAlbumID: album.id))
        #expect(mapping.remoteAlbumID == remote.nextAlbumID)
        #expect(remote.createdNames.count == 1)
        #expect(remote.attachedBatches.isEmpty)
        let retry = try await runner.sync(album: album)
        #expect(retry.remoteAlbumID == mapping.remoteAlbumID)
        #expect(retry.attached == 1)
        #expect(remote.createdNames.count == 1)
    }

    @Test func stopDuringManifestLookupPreventsProofAdmission() async throws {
        let entered = Gate()
        let release = Gate()
        let backup = FakeBackupExecutor()
        backup.proofLinks = ["a": link("proven")]
        let remote = FakeRemoteOps()
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(contents: ["local-1": .present(["a"])]),
            backup: backup,
            remoteOps: remote,
            linkLookup: GatedLinkLookup(entered: entered, release: release),
            mappingStore: makeStore()
        )
        let albumToSync = album
        let sync = Task { try await runner.sync(album: albumToSync) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(backup.proofRuns.isEmpty)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func stopDuringFinalExistenceReadCannotSettleTheRun() async throws {
        let entered = Gate()
        let release = Gate()
        let remote = FakeRemoteOps()
        let source = FinalExistenceAlbumSource(remote: remote, entered: entered, release: release)
        let store = makeStore()
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("known")]
        let runner = AlbumSyncRunner(
            localSource: source, backup: FakeBackupExecutor(), remoteOps: remote,
            linkLookup: lookup, mappingStore: store)
        let progress = ProgressBox()
        await runner.setOnProgress { progress.append($0) }
        let syncing = Task {
            try await runner.sync(album: LocalAlbumSummary(id: "local-1", title: "Album", assetCount: 1))
        }
        await entered.wait()
        #expect(remote.attachedBatches == [["known"]])
        let before = store.mapping(localAlbumID: "local-1")
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await syncing.value }
        #expect(store.mapping(localAlbumID: "local-1") == before, "Stop must preserve only the earlier durable mapping")
        #expect(!progress.snapshot().contains { $0.phase == .completed })
    }

    @Test(arguments: 1...7) func stopDuringAlbumExistenceCheckPreventsNextWork(check: Int) async throws {
        let entered = Gate()
        let release = Gate()
        let local = GatedAlbumSource(check: check > 5 ? 2 : check, entered: entered, release: release)
        let resolution: AlbumSyncResolution =
            check == 6 ? .attachToExisting(remoteAlbumID: "existing") : (check == 7 ? .createNew : .automatic)
        let remote = FakeRemoteOps()
        let backup = FakeBackupExecutor()
        let store = makeStore()
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("known")]
        let runner = AlbumSyncRunner(
            localSource: local, backup: backup, remoteOps: remote, linkLookup: lookup, mappingStore: store)
        let albumToSync = album
        let sync = Task { try await runner.sync(album: albumToSync, resolution: resolution) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(remote.listCount == (check == 1 || check > 5 ? 0 : 1))
        #expect(remote.createdNames.count == (check <= 2 || check > 5 ? 0 : 1))
        #expect(backup.runs.count == (check <= 3 || check > 5 ? 0 : 1))
        #expect(remote.childCount == (check <= 4 || check > 5 ? 0 : 1))
        #expect(remote.attachedBatches.isEmpty)
        if check <= 2 || check > 5 { #expect(store.mapping(localAlbumID: album.id) == nil) }
    }

    @Test func stopDuringAlbumListPreventsNextWork() async throws {
        let entered = Gate()
        let release = Gate()
        let local = GatedAlbumSource(check: 0, entered: entered, release: release)
        let remote = FakeRemoteOps()
        let backup = FakeBackupExecutor()
        let runner = AlbumSyncRunner(
            localSource: local, backup: backup,
            remoteOps: GatedRemoteOps(base: remote, entered: entered, release: release),
            linkLookup: FakeLinkLookup(), mappingStore: makeStore())
        let albumToSync = album
        let sync = Task { try await runner.sync(album: albumToSync) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(await local.checkCount == 1)
        #expect(remote.createdNames.isEmpty)
        #expect(backup.runs.isEmpty)
    }

    @Test func stopDuringProofLookupPreventsMemberRead() async throws {
        let entered = Gate()
        let release = Gate()
        let remote = FakeRemoteOps()
        let local = GatedAlbumSource(check: 0, entered: entered, release: release)
        let runner = AlbumSyncRunner(
            localSource: local,
            backup: GatedProofExecutor(entered: entered, release: release), remoteOps: remote,
            linkLookup: FakeLinkLookup(), mappingStore: makeStore())
        let albumToSync = album
        let sync = Task { try await runner.sync(album: albumToSync) }
        await entered.wait()
        await runner.stop()
        await release.open()
        await #expect(throws: AlbumSyncError.stopped) { try await sync.value }
        #expect(await local.checkCount == 3)
        #expect(remote.childCount == 0)
        #expect(remote.attachedBatches.isEmpty)
    }

    @Test func firstSyncCreatesAlbumBacksUpAndAttaches() async throws {
        let (runner, remote, backup, store) = makeRunner(
            contents: ["local-1": ["a", "b", "c"]],
            links: ["a": link("l-a"), "b": link("l-b"), "c": link("l-c")]
        )
        let report = try await runner.sync(album: album)

        #expect(remote.createdNames == ["Urlaub"])
        #expect(backup.runs == [["a", "b", "c"]])
        #expect(remote.attachedBatches.flatMap(\.self) == ["l-a", "l-b", "l-c"])
        // Chunked by attachChunkSize = 2.
        #expect(remote.attachedBatches.map(\.count) == [2, 1])
        #expect(report.attached == 3)
        #expect(report.isFullySynced)
        let mapping = try #require(store.mapping(localAlbumID: "local-1"))
        #expect(mapping.remoteAlbumID == "remote-album-1")
        #expect(mapping.lastSyncedAt != nil)
        #expect(mapping.mode == .additive)
    }

    @Test func emptyLocalAlbumStillCreatesRemoteAlbum() async throws {
        let (runner, remote, _, store) = makeRunner(contents: ["local-1": []], links: [:])
        let report = try await runner.sync(album: LocalAlbumSummary(id: "local-1", title: "Leer", assetCount: 0))
        #expect(remote.createdNames == ["Leer"])
        #expect(remote.attachedBatches.isEmpty)
        #expect(report.isFullySynced)
        #expect(store.mapping(localAlbumID: "local-1") != nil)
    }

    @Test func missingLocalAlbumCreatesNoRemoteAlbum() async throws {
        let source = ScriptedLocalAlbumSource(contents: .missing)
        let (runner, remote, backup, _) = makeRunner(
            contents: [:],
            links: [:],
            localSource: source
        )

        await #expect(throws: AlbumSyncError.localAlbumMissing) {
            try await runner.sync(album: album)
        }
        #expect(remote.listCount == 0)
        #expect(remote.createdNames.isEmpty)
        #expect(remote.attachedBatches.isEmpty)
        #expect(backup.runs.isEmpty)
    }

    @Test func missingLocalAlbumCreatesNoMapping() async throws {
        let source = ScriptedLocalAlbumSource(contents: .missing)
        let (runner, _, _, store) = makeRunner(
            contents: [:],
            links: [:],
            localSource: source
        )

        await #expect(throws: AlbumSyncError.localAlbumMissing) {
            try await runner.sync(album: album)
        }
        #expect(store.mapping(localAlbumID: album.id) == nil)
    }

    @Test func missingLocalAlbumPrecheckDoesNoRemoteResolution() async throws {
        let source = ScriptedLocalAlbumSource(contents: .missing)
        let (runner, remote, _, _) = makeRunner(
            contents: [:],
            links: [:],
            localSource: source
        )

        await #expect(throws: AlbumSyncError.localAlbumMissing) {
            try await runner.precheck(album: album)
        }
        #expect(remote.listCount == 0)
    }

    @Test func albumDisappearingAfterScanStopsBeforeRemoteMutation() async throws {
        let source = ScriptedLocalAlbumSource(
            contents: .present([]),
            existenceResults: [true, false]
        )
        let (runner, remote, backup, store) = makeRunner(
            contents: [:],
            links: [:],
            localSource: source
        )

        await #expect(throws: AlbumSyncError.localAlbumMissing) {
            try await runner.sync(album: album)
        }
        #expect(remote.listCount == 1)
        #expect(remote.createdNames.isEmpty)
        #expect(remote.attachedBatches.isEmpty)
        #expect(backup.runs.isEmpty)
        #expect(store.mapping(localAlbumID: album.id) == nil)
    }

    @Test func retryAfterMissingAlbumReappearsSucceeds() async throws {
        let source = ScriptedLocalAlbumSource(contents: .missing)
        let (runner, remote, _, store) = makeRunner(
            contents: [:],
            links: [:],
            localSource: source
        )

        await #expect(throws: AlbumSyncError.localAlbumMissing) {
            try await runner.sync(album: album)
        }
        await source.setContents(.present([]))

        let report = try await runner.sync(album: album)
        #expect(report.totalAssets == 0)
        #expect(report.isFullySynced)
        #expect(remote.createdNames == ["Urlaub"])
        #expect(store.mapping(localAlbumID: album.id) != nil)
    }

    @Test func albumDisappearingAfterRemoteChildLookupDoesNotSettleCompletion() async throws {
        let source = ScriptedLocalAlbumSource(
            contents: .present([]),
            existenceResults: [true, true, true, true, false]
        )
        let (runner, remote, _, store) = makeRunner(
            contents: [:],
            links: [:],
            localSource: source
        )

        await #expect(throws: AlbumSyncError.localAlbumMissing) {
            try await runner.sync(album: album)
        }
        #expect(remote.attachedBatches.isEmpty)
        #expect(store.mapping(localAlbumID: album.id)?.lastSyncedAt == nil)
    }

    @Test func repeatSyncReusesMappingAndDoesNoAttachWork() async throws {
        let store = makeStore()
        let (first, remoteA, _, _) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], store: store
        )
        _ = try await first.sync(album: album)
        #expect(remoteA.createdNames == ["Urlaub"])

        // Second run: same store, remote album now contains l-a.
        let remoteB = FakeRemoteOps()
        remoteB.children = ["l-a"]
        let (second, _, backupB, _) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: remoteB, store: store
        )
        let report = try await second.sync(album: album)
        #expect(remoteB.createdNames.isEmpty)  // mapping reused, nothing created
        #expect(remoteB.attachedBatches.isEmpty)  // membership converged, no attach calls
        #expect(backupB.runs.count == 1)  // backup re-verifies (cheap preflight)
        #expect(report.alreadyMember == 1)
        #expect(report.isFullySynced)
    }

    @Test func unmappedNameTwinThrowsConflictInsteadOfGuessing() async throws {
        let remote = FakeRemoteOps()
        remote.remoteAlbums = [AlbumSyncRemoteAlbum(id: "existing-9", title: "Urlaub")]
        let (runner, _, _, store) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: remote
        )
        await #expect(
            throws: AlbumSyncError.nameConflict(existing: [AlbumSyncRemoteAlbum(id: "existing-9", title: "Urlaub")])
        ) {
            try await runner.sync(album: album)
        }
        #expect(remote.createdNames.isEmpty)
        #expect(store.mapping(localAlbumID: "local-1") == nil)
    }

    @Test func explicitUseExistingAttachesToChosenAlbumAndPersistsMapping() async throws {
        let remote = FakeRemoteOps()
        remote.remoteAlbums = [AlbumSyncRemoteAlbum(id: "existing-9", title: "Urlaub")]
        let (runner, _, _, store) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: remote
        )
        let report = try await runner.sync(album: album, resolution: .attachToExisting(remoteAlbumID: "existing-9"))
        #expect(remote.createdNames.isEmpty)
        #expect(report.remoteAlbumID == "existing-9")
        #expect(store.mapping(localAlbumID: "local-1")?.remoteAlbumID == "existing-9")
    }

    @Test func attachFailuresSurfaceAsNeedsAttentionNotSuccess() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["l-b"]
        let (runner, _, _, _) = makeRunner(
            contents: ["local-1": ["a", "b"]],
            links: ["a": link("l-a"), "b": link("l-b")],
            remote: remote
        )
        var statuses: [AlbumSyncPhase] = []
        let box = ProgressBox()
        await runner.setOnProgress { box.append($0) }
        let report = try await runner.sync(album: album)
        statuses = box.snapshot().map(\.phase)
        #expect(report.attached == 1)
        #expect(report.attachFailed == 1)
        #expect(!report.isFullySynced)
        #expect(statuses.last == .needsAttention)
    }

    @Test func assetsWithoutRemoteLinkCountAsUnattachable() async throws {
        let (runner, remote, _, _) = makeRunner(
            contents: ["local-1": ["a", "b"]],
            links: ["a": link("l-a")]  // "b" never made it into the library
        )
        let report = try await runner.sync(album: album)
        #expect(remote.attachedBatches.flatMap(\.self) == ["l-a"])
        #expect(report.unattachable == 1)
        #expect(!report.isFullySynced)
    }

    @Test func trashedRemoteCopyIsRespectedNotAttached() async throws {
        let (runner, remote, _, store) = makeRunner(
            contents: ["local-1": ["a", "b"]],
            links: ["a": link("l-a"), "b": link("l-b", trashed: true)]
        )
        let report = try await runner.sync(album: album)
        #expect(remote.attachedBatches.flatMap(\.self) == ["l-a"])
        #expect(report.trashedSkipped == 1)
        #expect(store.mapping(localAlbumID: album.id)?.lastFailedCount == 1)
        #expect(!report.isFullySynced)
        #expect(report.problems.count == 1)
        #expect(report.problems.first?.issue == .remoteDeletion)
        #expect(report.problems.first?.reason == L10n.string("backup.state_skipped_remote_deletion"))
        #expect(report.problems.first?.isRetryable == false)
        #expect(await runner.currentProgress.needsAttentionCount == 1)
        #expect(await runner.currentProgress.phase == .needsAttention)
    }

    @Test func samePhotoInSecondAlbumOnlyAttachesNoNewUpload() async throws {
        let store = makeStore()
        let (first, _, _, _) = makeRunner(
            contents: ["local-1": ["a"], "local-2": ["a"]], links: ["a": link("l-a")], store: store
        )
        _ = try await first.sync(album: album)

        let remoteB = FakeRemoteOps()
        remoteB.nextAlbumID = "remote-album-2"
        let (second, _, backupB, _) = makeRunner(
            contents: ["local-1": ["a"], "local-2": ["a"]], links: ["a": link("l-a")], remote: remoteB, store: store
        )
        let report = try await second.sync(album: LocalAlbumSummary(id: "local-2", title: "Zweites", assetCount: 1))
        #expect(remoteB.createdNames == ["Zweites"])
        #expect(remoteB.attachedBatches == [["l-a"]])
        #expect(backupB.runs == [["a"]])  // backup step re-verifies via preflight, uploads nothing
        #expect(report.attached == 1)
    }

    @Test func secondSyncWhileRunningThrowsAlreadyRunning() async throws {
        let gate = Gate()
        let backup = GatedBackupExecutor(gate: gate)
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("l-a")]
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(albums: [], contents: ["local-1": .present(["a"])]),
            backup: backup,
            remoteOps: FakeRemoteOps(),
            linkLookup: lookup,
            mappingStore: makeStore()
        )
        let albumToSync = album
        let first = Task { try await runner.sync(album: albumToSync) }
        // Deterministic: wait until the first run is parked inside the backup phase.
        while await runner.currentProgress.phase != .backingUp { await Task.yield() }
        await #expect(throws: AlbumSyncError.alreadyRunning) {
            try await runner.sync(album: albumToSync)
        }
        await gate.open()
        _ = try await first.value
    }

    @Test func photosWithoutRemoteLinkListTheirBackupReason() async throws {
        let backup = FakeBackupExecutor()
        backup.problems = [
            "b": BackupFailedItem(
                id: "queue-b", filename: "b.heic", reason: "network reason", isPermanent: false, issue: .network,
                nextAttemptAt: Date(timeIntervalSinceNow: 600), category: .automatic)
        ]
        backup.filenames = ["b": "b.heic", "c": "c.heic"]
        let (runner, _, _, store) = makeRunner(
            contents: ["local-1": ["a", "b", "c"]],
            links: ["a": link("l-a")],
            backup: backup
        )

        let report = try await runner.sync(album: album)

        #expect(report.problems.map(\.filename) == ["b.heic", "c.heic"])
        #expect(report.problems.map(\.reason) == ["network reason", L10n.string("albumsync.issue_not_backed_up")])
        // Only Sync now runs the album scratch queue again, so no item promises an automatic retry.
        #expect(report.problems.allSatisfy { $0.category == .userResolvable && $0.nextAttemptAt == nil })
        #expect(report.problems.count == store.mapping(localAlbumID: album.id)?.lastFailedCount)
    }

    @Test func attachFailuresAreListedForEachPhoto() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["l-a", "l-c"]
        let backup = FakeBackupExecutor()
        backup.filenames = ["a": "a.heic", "c": "c.heic"]
        let (runner, _, _, store) = makeRunner(
            contents: ["local-1": ["a", "b", "c"]],
            links: ["a": link("l-a"), "b": link("l-b"), "c": link("l-c")],
            remote: remote,
            backup: backup
        )

        let report = try await runner.sync(album: album)

        #expect(report.attachFailed == 2)
        #expect(report.problems.map(\.source?.identifier) == ["a", "c"])
        #expect(report.problems.map(\.filename) == ["a.heic", "c.heic"])
        #expect(report.problems.allSatisfy { $0.reason == L10n.string("albumsync.issue_attach_failed") })
        #expect(report.problems.count == store.mapping(localAlbumID: album.id)?.lastFailedCount)
    }

    @Test func laterSuccessfulSyncReportsNoProblems() async throws {
        let store = makeStore()
        let failing = FakeRemoteOps()
        failing.failAttachOf = ["l-a"]
        let (first, _, _, _) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: failing, store: store)
        let failed = try await first.sync(album: album)
        #expect(failed.problems.count == 1)

        let (second, _, _, _) = makeRunner(contents: ["local-1": ["a"]], links: ["a": link("l-a")], store: store)
        let report = try await second.sync(album: album)

        #expect(report.problems.isEmpty)
        #expect(report.isFullySynced)
    }

    @Test func unavailableMappingStorePreventsRemoteWork() async throws {
        let store = makeStore()
        store.close()
        let (runner, remote, backup, _) = makeRunner(
            contents: ["local-1": ["a"]],
            links: ["a": link("l-a")],
            store: store
        )

        await #expect(throws: AlbumSyncError.mappingStoreUnavailable) {
            try await runner.sync(album: album)
        }
        #expect(remote.createdNames.isEmpty)
        #expect(remote.attachedBatches.isEmpty)
        #expect(backup.runs.isEmpty)
    }
}

/// Suspends backup until the test opens the gate - lets tests pin "while a sync is running" states.
private actor Gate {
    private var isOpen = false
    var opened: Bool { isOpen }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private struct FinalExistenceAlbumSource: AlbumSyncLocalAlbumSource {
    let remote: FakeRemoteOps
    let entered: Gate
    let release: Gate
    func listAlbums() async throws -> [LocalAlbumSummary] { [] }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents { .present(["a"]) }
    func albumExists(albumID: String) async throws -> Bool {
        if !remote.attachedBatches.isEmpty {
            await entered.open()
            await release.wait()
        }
        return true
    }
}

private actor GatedAlbumSource: AlbumSyncLocalAlbumSource {
    let check: Int
    let entered: Gate
    let release: Gate
    private(set) var checkCount = 0
    init(check: Int, entered: Gate, release: Gate) {
        self.check = check
        self.entered = entered
        self.release = release
    }
    func listAlbums() async throws -> [LocalAlbumSummary] { [] }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents { .present(["a"]) }
    func albumExists(albumID: String) async throws -> Bool {
        checkCount += 1
        if checkCount == check {
            await entered.open()
            await release.wait()
        }
        return true
    }
}

private struct GatedRemoteOps: AlbumSyncRemoteAlbumOps {
    let base: FakeRemoteOps
    let entered: Gate
    let release: Gate
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] {
        await entered.open()
        await release.wait()
        return []
    }
    func createAlbum(name: String) async throws -> String { try await base.createAlbum(name: name) }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await base.childMainLinkIDs(albumID: albumID)
    }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        try await base.attach(photos, albumID: albumID)
    }
}

/// Holds the same-content lookup until the test releases it.
private struct GatedSameContentRemoteOps: AlbumSyncRemoteAlbumOps {
    let base: FakeRemoteOps
    let entered: Gate
    let release: Gate
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { try await base.listAlbums() }
    func createAlbum(name: String) async throws -> String { try await base.createAlbum(name: name) }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await base.childMainLinkIDs(albumID: albumID)
    }
    func activeMainLinkIDs(withSameContentAs sha1Hexes: Set<String>) async throws -> [String: Set<String>] {
        await entered.open()
        await release.wait()
        return try await base.activeMainLinkIDs(withSameContentAs: sha1Hexes)
    }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        try await base.attach(photos, albumID: albumID)
    }
}

private struct GatedProofExecutor: AlbumSyncBackupExecuting {
    let entered: Gate
    let release: Gate
    var failure: (any Error)? = nil
    func ensureBackedUp(
        localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport { AlbumSyncBackupReport() }
    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        await entered.open()
        await release.wait()
        if let failure { throw failure }
        return ["a": link("proven")]
    }
    func stop() async {}
}

private struct GatedLinkLookup: AlbumSyncRemoteLinkLookup {
    let entered: Gate
    let release: Gate
    func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink] {
        await entered.open()
        await release.wait()
        return [:]
    }
}

private struct GatedBackupExecutor: AlbumSyncBackupExecuting {
    let gate: Gate
    func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        await gate.wait()
        return AlbumSyncBackupReport(
            total: localIdentifiers.count, backedUp: localIdentifiers.count,
            failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0
        )
    }
    func stop() async {}
}

/// Order-preserving, thread-safe progress recorder for callback assertions.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AlbumSyncProgress] = []
    func append(_ p: AlbumSyncProgress) { lock.withLock { items.append(p) } }
    func snapshot() -> [AlbumSyncProgress] { lock.withLock { items } }
}

@Suite struct AlbumSyncMappingStoreTests {
    @Test(arguments: [false, true])
    func openMappingDecodeFailureStaysStickyAfterRepair(readAllMappings: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-mapping-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)
        let store = try #require(AlbumSyncMappingStore(url: url))
        defer { store.close() }
        let mapping = AlbumSyncMapping(
            localAlbumID: "kept", remoteAlbumID: "remote", title: "Mapping",
            createdAt: Date(timeIntervalSinceReferenceDate: 100))
        #expect(store.upsert(mapping))
        #expect(store.isOperational())

        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let database = try #require(handle)
        defer { sqlite3_close(database) }
        #expect(
            sqlite3_exec(
                database, "UPDATE album_sync_mapping SET mode='invalid-mode' WHERE local_album_id='kept';",
                nil, nil, nil) == SQLITE_OK)
        if readAllMappings {
            #expect(store.allMappings().isEmpty)
        } else {
            #expect(store.mapping(localAlbumID: "kept") == nil)
        }
        #expect(!store.isOperational())

        #expect(store.upsert(mapping), "a later successful SQL predicate keeps its existing result")
        #expect(store.mapping(localAlbumID: "kept") == mapping)
        #expect(store.allMappings() == [mapping])
        #expect(!store.isOperational(), "successful SQL must not reset the recorded failure")
    }

    @Test func closeMakesReadsAndWritesFailClosed() {
        let store = makeStore()
        store.close()

        #expect(!store.isOperational())
        #expect(store.mapping(localAlbumID: "L1") == nil)
        #expect(store.allMappings().isEmpty)
        #expect(!store.addSelection(AlbumSyncSelection(localAlbumID: "L1", title: "A", addedAt: Date())))
        #expect(
            !store.upsert(
                AlbumSyncMapping(
                    localAlbumID: "L1",
                    remoteAlbumID: "R1",
                    title: "A",
                    createdAt: Date()
                )))
    }

    @Test func invalidDatabaseIsNeverDeletedAndRecreated() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-corrupt-\(UUID().uuidString).sqlite")
        let original = Data("not-a-sqlite-database".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(AlbumSyncMappingStore(url: url) == nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func markerlessMappingShapeFailsClosedWithoutRepairingIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-markerless-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                db,
                "CREATE TABLE album_sync_mapping(local_album_id TEXT); "
                    + "INSERT INTO album_sync_mapping VALUES('kept');",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(db)

        #expect(AlbumSyncMappingStore(url: url) == nil)
        #expect(sqliteCount(url: url, table: "album_sync_mapping") == 1)
        #expect(sqliteCount(url: url, table: "mapping_info") == -1)
    }

    @Test func selectionRoundTripKeepsMappingOnDeselect() throws {
        let store = makeStore()
        store.addSelection(
            AlbumSyncSelection(localAlbumID: "L1", title: "Urlaub", addedAt: Date(timeIntervalSinceReferenceDate: 10)))
        store.addSelection(
            AlbumSyncSelection(localAlbumID: "L2", title: "Anna", addedAt: Date(timeIntervalSinceReferenceDate: 20)))
        #expect(store.selections().map(\.localAlbumID) == ["L2", "L1"])  // title-ordered

        // Re-adding updates the stored title (album renamed locally).
        store.addSelection(
            AlbumSyncSelection(
                localAlbumID: "L1", title: "Urlaub 2026", addedAt: Date(timeIntervalSinceReferenceDate: 30)))
        #expect(store.selections().first(where: { $0.localAlbumID == "L1" })?.title == "Urlaub 2026")

        // Deselecting removes only the selection - the album mapping survives, so re-selecting
        // later reuses the same Proton album without a conflict round.
        store.upsert(
            AlbumSyncMapping(
                localAlbumID: "L1", remoteAlbumID: "R1", title: "Urlaub 2026",
                createdAt: Date(timeIntervalSinceReferenceDate: 10)
            ))
        store.removeSelection(localAlbumID: "L1")
        #expect(store.selections().map(\.localAlbumID) == ["L2"])
        #expect(store.mapping(localAlbumID: "L1")?.remoteAlbumID == "R1")
    }

    @Test func upsertReadRemoveRoundTrip() throws {
        let store = makeStore()
        let mapping = AlbumSyncMapping(
            localAlbumID: "L1", remoteAlbumID: "R1", title: "Urlaub",
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            lastSyncedAt: Date(timeIntervalSinceReferenceDate: 2000),
            lastAttachedCount: 5, lastFailedCount: 1
        )
        store.upsert(mapping)
        let loaded = try #require(store.mapping(localAlbumID: "L1"))
        #expect(loaded == mapping)

        var updated = mapping
        updated.lastAttachedCount = 9
        store.upsert(updated)
        #expect(store.mapping(localAlbumID: "L1")?.lastAttachedCount == 9)
        #expect(store.allMappings().count == 1)

        store.removeMapping(localAlbumID: "L1")
        #expect(store.mapping(localAlbumID: "L1") == nil)
    }

    private func sqliteCount(url: URL, table: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }
}

@Suite struct AlbumSyncWaitingForWiFiTests {
    @Test func backupPhaseSaysWaitingForWiFiOnlyWhileTheBackupWaits() {
        var progress = AlbumSyncProgress()
        progress.phase = .backingUp
        #expect(progress.localizedTitle == L10n.string("albumsync.phase_backing_up"))
        progress.isWaitingForWiFi = true
        #expect(progress.localizedTitle == L10n.string("backup.phase_waiting_wifi"))
        progress.phase = .attaching
        #expect(progress.localizedTitle == L10n.string("albumsync.phase_attaching"))
    }
}

private struct GatedCreateRemoteOps: AlbumSyncRemoteAlbumOps {
    let base: FakeRemoteOps
    let entered: Gate
    let release: Gate
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { try await base.listAlbums() }
    func createAlbum(name: String) async throws -> String {
        let id = try await base.createAlbum(name: name)
        await entered.open()
        await release.wait()
        return id
    }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await base.childMainLinkIDs(albumID: albumID)
    }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        try await base.attach(photos, albumID: albumID)
    }
}

private func waitForDeletionGate(_ gate: Gate) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if await gate.opened { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private final class GatedDeletionChecker: UploadDuplicateChecking, @unchecked Sendable {
    let entered: Gate
    let release: Gate
    private let lock = NSLock()
    private var requests = 0
    private var cancelled = false
    var requestCount: Int { lock.withLock { requests } }
    var observedCancellation: Bool { lock.withLock { cancelled } }
    init(entered: Gate, release: Gate) {
        self.entered = entered
        self.release = release
    }
    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        lock.withLock { requests += 1 }
        await entered.open()
        await release.wait()
        lock.withLock { cancelled = cancelled || Task.isCancelled }
        try Task.checkCancellation()
        return .init(states: [:], complete: true)
    }
    func nameHash(forCorrectedName name: String) async throws -> String { name }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { sha1Hex }
    func hashKeyEpoch() async throws -> String { "epoch" }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] { [] }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? { nil }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] { [:] }
}
