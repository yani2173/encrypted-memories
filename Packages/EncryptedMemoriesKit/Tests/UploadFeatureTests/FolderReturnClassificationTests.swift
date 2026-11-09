import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import PhotoLibraryBackupAdapter

/// Issue #1175: returning watched-folder files to the backup queue must count a file that is
/// gone as done, but a file whose attributes cannot be read must keep its queue duty. The route
/// is the real one: `PendingGridSession.restore` -> coordinator `performQueueSync` -> the
/// pending file source, whose closure calls the real batch function
/// `FolderBackupCatalog.returnToBackup` that `App/FolderBackupController` also calls.
@Suite @MainActor struct FolderReturnClassificationTests {
    @Test func aMissingFileCountsAsDoneAndEntersNoQueue() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let gone = fixture.path("Watched/vanished.heic")
        let key = try fixture.seedDuty(for: gone, displayName: "vanished.heic")

        let session = try fixture.makeSession()
        #expect(await session.restore([key.localUID]))

        #expect(fixture.store.sourceState(for: key) == nil, "a file that is gone owes no queue duty")
        #expect(try fixture.queueRowCount(for: gone) == 0, "a file that is gone must not enter the queue")
        await session.close()
        await fixture.shutdown()
    }

    @Test func anUnreadableFileKeepsItsQueueDuty() async throws {
        if geteuid() == 0 {
            try Test.cancel("the unreadable fixture locks a directory with permissions, which root ignores")
        }
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let unreadable = try fixture.makeUnreadableFile("Watched/locked/secret.heic")
        let key = try fixture.seedDuty(for: unreadable, displayName: "secret.heic")

        let session = try fixture.makeSession()
        #expect(await session.restore([key.localUID]))

        let after = fixture.store.sourceState(for: key)
        #expect(after?.desired == .included, "a file that cannot be read stays included")
        #expect(
            after?.needsQueueSync == true,
            "a file whose attributes cannot be read must not count as returned to the backup")
        #expect(try fixture.queueRowCount(for: unreadable) == 0, "an unreadable file must not enter the queue")
        await session.close()
        await fixture.shutdown()
    }

    @Test func aReadableFileIsQueuedAgain() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let readable = try fixture.makeReadableFile("Watched/photo.heic", bytes: "readable-bytes")
        let key = try fixture.seedDuty(for: readable, displayName: "photo.heic")

        let session = try fixture.makeSession()
        #expect(await session.restore([key.localUID]))

        #expect(fixture.store.sourceState(for: key) == nil, "a queued file owes no queue duty")
        #expect(try fixture.queueRowCount(for: readable) == 1, "a readable file must enter the queue")
        await session.close()
        await fixture.shutdown()
    }

    @Test func aMixedBatchQueuesReadableFilesAndKeepsTheUnreadableDuty() async throws {
        if geteuid() == 0 {
            try Test.cancel("the unreadable fixture locks a directory with permissions, which root ignores")
        }
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let readable = try fixture.makeReadableFile("Watched/photo.heic", bytes: "readable-bytes")
        let gone = fixture.path("Watched/vanished.heic")
        let unreadable = try fixture.makeUnreadableFile("Watched/locked/secret.heic")
        let readableKey = try fixture.seedDuty(for: readable, displayName: "photo.heic")
        let goneKey = try fixture.seedDuty(for: gone, displayName: "vanished.heic")
        let unreadableKey = try fixture.seedDuty(for: unreadable, displayName: "secret.heic")

        let session = try fixture.makeSession()
        #expect(await session.restore([readableKey, goneKey, unreadableKey].map(\.localUID)))

        #expect(try fixture.queueRowCount(for: readable) == 1, "a readable file in a mixed batch is queued")
        #expect(try fixture.queueRowCount(for: gone) == 0, "a gone file in a mixed batch enters no queue")
        let after = fixture.store.sourceState(for: unreadableKey)
        #expect(after?.desired == .included, "an unreadable file in a mixed batch stays included")
        #expect(
            after?.needsQueueSync == true,
            "no partial success: the unreadable member of a mixed batch keeps its queue duty")
        // Each file settles on its own result, so the unreadable file does not hold back its siblings.
        #expect(
            fixture.store.sourceState(for: readableKey) == nil,
            "a queued sibling of an unreadable file owes no queue duty")
        #expect(
            fixture.store.sourceState(for: goneKey) == nil,
            "a gone sibling of an unreadable file owes no queue duty")
        await session.close()
        await fixture.shutdown()
    }

    /// Issue #1227: while the folder backup is shut down, no watched folder is known, so a returned
    /// file can be neither read nor proven outside. Every file keeps its queue duty, even one that
    /// exists and one that is gone, and nothing enters the queue.
    @Test func whileTheWatchedFoldersAreUnknownNoReturnedFileSettles() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let readable = try fixture.makeReadableFile("Watched/photo.heic", bytes: "readable-bytes")
        let gone = fixture.path("Watched/vanished.heic")
        let elsewhere = try fixture.makeReadableFile("Elsewhere/photo.heic", bytes: "elsewhere-bytes")
        let keys = try [
            fixture.seedDuty(for: readable, displayName: "photo.heic"),
            fixture.seedDuty(for: gone, displayName: "vanished.heic"),
            fixture.seedDuty(for: elsewhere, displayName: "photo.heic"),
        ]

        let session = try fixture.makeSession(scope: .unavailable)
        #expect(await session.restore(keys.map(\.localUID)))

        for key in keys {
            let after = fixture.store.sourceState(for: key)
            #expect(after?.desired == .included, "\(key.identifier) stays included")
            #expect(
                after?.needsQueueSync == true,
                "\(key.identifier) must not count as returned while no watched folder is known")
            #expect(try fixture.queueRowCount(for: key.identifier) == 0, "\(key.identifier) enters no queue")
        }
        await session.close()
        await fixture.shutdown()
    }

    /// Issue #1227: a registered folder that needs a new bookmark is not readable, but its files are
    /// still watched. They keep their queue duty; a readable sibling is queued and a path outside
    /// every registered folder settles.
    @Test func aFolderThatNeedsANewBookmarkKeepsTheDutyOfItsFiles() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let readable = try fixture.makeReadableFile("Watched/photo.heic", bytes: "readable-bytes")
        let renewal = try fixture.makeReadableFile("Renewal/photo.heic", bytes: "renewal-bytes")
        let outside = try fixture.makeReadableFile("Elsewhere/photo.heic", bytes: "elsewhere-bytes")
        let readableKey = try fixture.seedDuty(for: readable, displayName: "photo.heic")
        let renewalKey = try fixture.seedDuty(for: renewal, displayName: "photo.heic")
        let outsideKey = try fixture.seedDuty(for: outside, displayName: "photo.heic")

        let session = try fixture.makeSession(
            scope: WatchedFolderScope(
                readable: [URL(fileURLWithPath: fixture.path("Watched"))],
                registered: [fixture.path("Watched"), fixture.path("Renewal")]))
        #expect(await session.restore([readableKey, renewalKey, outsideKey].map(\.localUID)))

        #expect(fixture.store.sourceState(for: readableKey) == nil, "a queued file owes no queue duty")
        #expect(try fixture.queueRowCount(for: readable) == 1, "a file in a readable folder is queued")
        let after = fixture.store.sourceState(for: renewalKey)
        #expect(after?.desired == .included, "a file of a folder that needs a new bookmark stays included")
        #expect(
            after?.needsQueueSync == true,
            "a file of a folder that needs a new bookmark must not count as outside the watched folders")
        #expect(try fixture.queueRowCount(for: renewal) == 0, "an unreadable folder's file enters no queue")
        #expect(fixture.store.sourceState(for: outsideKey) == nil, "a path outside every registered folder is done")
        #expect(try fixture.queueRowCount(for: outside) == 0, "a path outside the folders enters no queue")
        await session.close()
        await fixture.shutdown()
    }

    @Test func anEmptyRestoreTouchesNoFileSource() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let counter = CallCounter()
        let session = try fixture.makeSession(callCounter: counter)

        #expect(await session.restore([]))

        #expect(counter.calls == 0, "an empty restore must not call the file source")
        #expect(try fixture.queueRowCount(for: fixture.path("Watched/photo.heic")) == 0)
        await session.close()
        await fixture.shutdown()
    }

    /// A read failure that is neither missing nor permission must not count as done either.
    /// A file name longer than the filesystem allows (ENAMETOOLONG) is such a failure: no such
    /// file can exist, yet the read failure classifies as transient, not missing.
    @Test func aTransientReadFailureKeepsItsQueueDuty() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let unreachable = fixture.makeUnreachableLongPath()

        let outcome = FolderBackupCatalog.returnOutcome(for: URL(fileURLWithPath: unreachable))
        var transient = false
        if case .unreadable(.transient) = outcome { transient = true }
        #expect(transient, "an unreachable long name must classify as transient, not gone: \(outcome)")

        let key = try fixture.seedDuty(for: unreachable, displayName: "long-name.heic")
        let session = try fixture.makeSession()
        #expect(await session.restore([key.localUID]))

        let after = fixture.store.sourceState(for: key)
        #expect(after?.desired == .included, "a transient read failure stays included")
        #expect(
            after?.needsQueueSync == true,
            "a transient read failure must not count as returned to the backup")
        await session.close()
        await fixture.shutdown()
    }

    /// When the queue itself cannot be read, nothing counts as returned and every duty stays.
    @Test func aBrokenQueueKeepsTheQueueDutyOfEveryFile() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }
        let readable = try fixture.makeReadableFile("Watched/photo.heic", bytes: "readable-bytes")
        let key = try fixture.seedDuty(for: readable, displayName: "photo.heic")
        fixture.queueStore.close()

        let session = try fixture.makeSession()
        #expect(await session.restore([key.localUID]))

        let after = fixture.store.sourceState(for: key)
        #expect(after?.desired == .included, "a file that could not be enqueued stays included")
        #expect(
            after?.needsQueueSync == true,
            "a file that could not be enqueued must not count as returned to the backup")
        await session.close()
        await fixture.shutdown()
    }

    /// An empty batch is done without touching the queue, as the coordinator's empty guard keeps.
    @Test func anEmptyBatchCountsAsDoneWithoutEnqueueingAnything() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }

        let batch = await FolderBackupCatalog.returnToBackup(
            paths: [],
            scope: fixture.watchedScope,
            engine: fixture.engine)

        #expect(batch == FolderBackupCatalog.ReturnBatch(returnedPaths: [], queuedCount: 0))
        #expect(try fixture.queueRowCount(for: fixture.path("Watched/photo.heic")) == 0)
        await fixture.shutdown()
    }

    /// A path outside every registered folder cannot reach a file the person no longer shared;
    /// it needs nothing and counts as done.
    @Test func aPathOutsideTheWatchedFoldersCountsAsDone() async throws {
        var fixture = try ReturnFixture()
        defer { fixture.remove() }

        let batch = await FolderBackupCatalog.returnToBackup(
            paths: ["/outside/watched/photo.heic"],
            scope: fixture.watchedScope,
            engine: fixture.engine)

        #expect(
            batch == FolderBackupCatalog.ReturnBatch(returnedPaths: ["/outside/watched/photo.heic"], queuedCount: 0))
        #expect(try fixture.queueRowCount(for: "/outside/watched/photo.heic") == 0)
        await fixture.shutdown()
    }

    /// Issue #1227: a registered folder without a known path could hold any path, so no path that
    /// the app cannot read counts as outside.
    @Test func aRegisteredFolderWithoutAKnownPathProvesNoPathOutside() {
        let scope = WatchedFolderScope(readable: [URL(fileURLWithPath: "/Volumes/A")], registered: ["/Volumes/A", "?"])

        #expect(scope.location(ofPath: "/Volumes/B/photo.heic") == .unavailable)
        #expect(
            scope.location(ofPath: "/Volumes/A/photo.heic") == .readable(URL(fileURLWithPath: "/Volumes/A/photo.heic")))
    }

    /// Issue #1227: a folder registry that could not be read proves no path outside; a readable
    /// folder stays readable.
    @Test func anUnreadableFolderRegistryProvesNoPathOutside() {
        let scope = WatchedFolderScope(readable: [URL(fileURLWithPath: "/Volumes/A")], registered: nil)

        #expect(scope.location(ofPath: "/Volumes/B/photo.heic") == .unavailable)
        #expect(
            scope.location(ofPath: "/Volumes/A/photo.heic") == .readable(URL(fileURLWithPath: "/Volumes/A/photo.heic")))
    }

    /// Issue #1227: no saved folder list is a known empty registry, but a saved value of another
    /// type is damaged and leaves the registry unknown.
    @Test func aDamagedFolderListLeavesTheRegistryUnknown() {
        let bookmark = Data("bookmark".utf8)

        #expect(WatchedFolderScope.registeredBookmarks(storedValue: nil) == [])
        #expect(WatchedFolderScope.registeredBookmarks(storedValue: [bookmark]) == [bookmark])
        #expect(WatchedFolderScope.registeredBookmarks(storedValue: "damaged") == nil)
        #expect(WatchedFolderScope.registeredBookmarks(storedValue: [bookmark, "damaged"] as [Any]) == nil)
    }

    /// A folder root matches whole path components only: `/Volumes/A2` is not inside `/Volumes/A`.
    @Test func aSiblingFolderWithTheSamePrefixIsOutside() {
        let scope = WatchedFolderScope(readable: [], registered: ["/Volumes/A"])

        #expect(scope.location(ofPath: "/Volumes/A2/photo.heic") == .outside)
        #expect(scope.location(ofPath: "/Volumes/A/photo.heic") == .unavailable)
        #expect(scope.readableURL(forPath: "/Volumes/A/photo.heic") == nil)
    }
}

/// Drives the real batch function of the package (`FolderBackupCatalog.returnToBackup`) with the
/// real `WatchedFolderScope`. The host only supplies the folder lists; no host code is mirrored here.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func add() { lock.withLock { _calls += 1 } }
}

private struct FileMetadata: PendingSourceMetadataProviding {
    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        Dictionary(
            uniqueKeysWithValues: keys.map {
                (
                    $0,
                    PendingPresentationMetadata(
                        captureTime: Date(timeIntervalSince1970: 1_700_000_000), mediaType: "image/heic",
                        displayName: "photo.heic")
                )
            })
    }
}

private struct NoRemoteEffects: PendingRemoteEffects {
    func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}

@MainActor
private struct ReturnFixture {
    let suite = "folder-return-classification-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: String
    let store: PendingBackupManifestStore
    let controller: PhotoLibraryBackupController
    let queueStore: UploadBackupSyncQueueManifestStore
    let stateStore: UploadBackupStateManifestStore
    let engine: UploadBackupSyncEngine
    private var lockedDirectory: String?

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory.path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory.path + "/Watched"), withIntermediateDirectories: true)
        store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil,
            uploader: MockUploader(),
            pendingStore: store,
            requiresPendingStore: true)
        queueStore = try #require(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("files.sqlite")))
        stateStore = try #require(
            UploadBackupStateManifestStore(
                url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)))
        engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: stateStore), queue: queueStore)
    }

    /// The standardized path of one watched file; the same string is the source key's identifier.
    func path(_ relativePath: String) -> String { root + "/" + relativePath }

    func makeReadableFile(_ relativePath: String, bytes: String) throws -> String {
        let path = self.path(relativePath)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
        return path
    }

    /// Attribute reads of this file fail with Cocoa 257 (POSIX EACCES) for the current user.
    mutating func makeUnreadableFile(_ relativePath: String) throws -> String {
        let path = try makeReadableFile(relativePath, bytes: "unreadable-bytes")
        let container = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: container)
        lockedDirectory = container
        return path
    }

    /// Attribute reads of this path fail with Cocoa 258 (POSIX ENAMETOOLONG) for the current
    /// user: neither missing nor permission denied. No file with such a name can exist.
    func makeUnreachableLongPath() -> String {
        path("Watched/\(String(repeating: "a", count: 300)).heic")
    }

    /// Seeds one excluded file source whose queue-sync duty is owed, as `store.include` on restore sees it.
    func seedDuty(for path: String, displayName: String) throws -> PendingSourceKey {
        let key = PendingSourceKey(kind: .fileURL, identifier: path)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let excluded = try #require(
            store.exclude(
                [
                    .init(
                        key: key,
                        presentation: .init(captureTime: date, mediaType: "image/heic", displayName: displayName),
                        remote: nil, revision: .init(rawValue: 1))
                ], at: date))
        for state in excluded {
            #expect(store.completeEffect(.queueSync, for: state.key, generation: state.generation, at: date))
        }
        return key
    }

    /// The watched folders of most tests: `Watched` is registered and readable.
    var watchedScope: WatchedFolderScope {
        WatchedFolderScope(readable: [URL(fileURLWithPath: path("Watched"))], registered: [path("Watched")])
    }

    func makeSession(callCounter: CallCounter? = nil, scope: WatchedFolderScope? = nil) throws -> PendingGridSession {
        let engine = self.engine
        let scope = scope ?? watchedScope
        let counter = callCounter
        let files = PendingFileSource(
            queue: queueStore,
            metadata: FileMetadata(),
            removeFromBackup: { _ in true },
            returnToBackup: { paths in
                counter?.add()
                return await FolderBackupCatalog.returnToBackup(
                    paths: paths,
                    scope: scope,
                    engine: engine
                ).returnedPaths
            })
        return try #require(
            PendingGridSession(store: store, photoBackup: controller, remote: NoRemoteEffects(), files: files))
    }

    /// The queue states that mean a row is still work the queue can run: freshly discovered or
    /// enqueued, in flight, or awaiting reconciliation. Every other state already settled and
    /// proves nothing about a restore.
    private static let runnablePendingStates: Set<UploadBackupSyncQueueState> = [
        .discovered, .checking, .hashing, .duplicateChecking,
        .queuedForUpload, .uploading, .finalizing, .needsRemoteReconciliation,
    ]

    /// Counts the queue rows of one file, and only rows that are runnable pending work. A row
    /// that already settled (backed up, a permanent failure, a dismissed failure) fails the test:
    /// it would satisfy a count without proving the file is queued.
    func queueRowCount(for path: String) throws -> Int {
        let rows = try queueStore.decisionRows(kind: .fileURL, identifiers: [path])
        for row in rows {
            #expect(
                Self.runnablePendingStates.contains(row.state),
                "queue row is not runnable pending work: \(row.state)")
        }
        return rows.count
    }

    func shutdown() async {
        await controller.shutdown()
        store.close()
        queueStore.close()
        stateStore.close()
    }

    mutating func remove() {
        if let lockedDirectory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDirectory)
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: root))
    }
}
