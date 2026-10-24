import Foundation
import Observation
import PhotosCore
import Testing
import UploadCore

@testable import PhotoLibraryBackupAdapter

@Suite @MainActor struct PendingGridConnectionTests {
    @Test func aStoreWithoutASessionStaysForTheTeardown() async throws {
        let fixture = try Fixture(pendingStoreInController: false)
        defer { fixture.remove() }
        let connection = PendingGridConnection()

        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }

        #expect(started.session == nil, "a controller without a pending recorder cannot start a session")
        #expect(connection.session == nil)
        let retired = connection.retire()
        #expect(retired.session == nil)
        #expect(retired.store === fixture.store, "the teardown still closes the opened store")
        #expect(connection.retire().store == nil, "a retired store is handed out once")
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func withoutAStoreNoSessionIsBuilt() {
        let connection = PendingGridConnection()
        var built = false

        let started = connection.start(store: nil) { _ in
            built = true
            return nil
        }

        #expect(started.session == nil)
        #expect(!built)
        #expect(connection.retire().store == nil)
    }

    @Test func onlyChangedFavoriteIntentsRaiseTheRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let session = try #require(started.session)
        #expect(connection.session === session)
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID

        #expect(await session.setFavorite([uid], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 1 }, "a new intent refreshes favorite displays")
        #expect(await eventually { session.pendingSnapshot.favoriteIntents == [uid: true] })

        // The same intent publishes another snapshot with unchanged intents.
        let published = session.pendingSnapshot.membershipRevision
        #expect(await session.setFavorite([uid], favorite: true))
        #expect(await eventually { session.pendingSnapshot.membershipRevision != published })
        #expect(connection.favoriteRevision == 1, "unchanged intents do not refresh favorite displays")

        #expect(await session.setFavorite([uid], favorite: false))
        #expect(await eventually { connection.favoriteRevision == 2 })

        let retired = connection.retire()
        #expect(retired.session === session)
        #expect(retired.store === fixture.store)
        #expect(connection.session == nil)
        #expect(connection.favoriteRevision == 3, "retiring refreshes favorite displays")
        await session.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func retiringForgetsTheFavoriteIntentsOfTheEarlierSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        let startedFirst = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let first = try #require(startedFirst.session)
        #expect(await first.setFavorite([uid], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 1 })
        _ = connection.retire()
        await first.close()
        #expect(connection.favoriteRevision == 2)

        // The next session reads the same stored intent; it is new for the connection.
        let startedSecond = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let second = try #require(startedSecond.session)
        #expect(await second.setFavorite([uid], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 3 })
        _ = connection.retire()
        await second.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func albumAddsReachOnlyALiveSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let installed = HandlerBox()
        var prepared: PendingGridSession?
        var session = connection.start(
            store: fixture.store,
            makeSession: {
                PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
            },
            albumAdds: { await installed.set($0) },
            prepare: { prepared = $0 }
        ).session
        #expect(session != nil)
        #expect(prepared === session, "the host prepares the session it shows")
        prepared = nil
        weak var released = session
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-album").localUID

        #expect(await eventually { await installed.handler != nil }, "the albums learn where pending adds go")
        let handler = try #require(await installed.handler)
        #expect(await handler([uid], "album"), "the live session records the album add")

        _ = connection.retire()
        await session?.close()
        session = nil
        #expect(await eventually { released == nil }, "the album bridge does not keep the session alive")
        #expect(await handler([uid], "album") == false, "a released session records nothing")
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func theHostPreparesTheSessionBeforeItStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        var startedBeforePrepare: Bool?

        let started = connection.start(
            store: fixture.store,
            makeSession: { PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects()) },
            prepare: { _ in startedBeforePrepare = fixture.controller.onLibraryChange != nil }
        )

        #expect(startedBeforePrepare == false, "the presentation is attached before the first snapshot")
        #expect(fixture.controller.onLibraryChange != nil, "the session started after the host prepared it")
        _ = connection.retire()
        await started.session?.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func screensThatReadTheConnectionAreToldAboutEveryChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let changes = ChangeCounter()
        func observe() {
            withObservationTracking {
                _ = connection.session
                _ = connection.trash
                _ = connection.excludedTiles
                _ = connection.favoriteRevision
            } onChange: {
                changes.count += 1
            }
        }

        observe()
        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let session = try #require(started.session)
        #expect(changes.count == 1, "showing the pending grid reaches the screen")

        observe()
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        #expect(await session.setFavorite([uid], favorite: true))
        #expect(await eventually { changes.count == 2 }, "a new favorite intent reaches the screen")

        observe()
        _ = connection.retire()
        #expect(changes.count == 3, "retiring the pending grid reaches the screen")
        await session.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func theTrashAndExcludedListsFollowTheSessionUntilRetired() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileQueue = try #require(
            UploadBackupSyncQueueManifestStore(url: fixture.directory.appendingPathComponent("file-queue.sqlite")))
        let path = fixture.directory.appendingPathComponent("watched/photo.heic").path
        let source = UploadSourceIdentity(kind: .fileURL, identifier: path)
        #expect(
            fileQueue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source, revision: UploadBackupRevision(rawValue: 1), originalFilename: "photo.heic",
                    state: .queuedForUpload, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))))
        let files = PendingFileSource(
            queue: fileQueue, metadata: AllFilesMetadata(), removeFromBackup: { _ in true },
            returnToBackup: { _ in true })
        let connection = PendingGridConnection()
        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects(), files: files)
        }
        let session = try #require(started.session)
        let uid = PendingSourceKey(kind: .fileURL, identifier: path).localUID
        #expect(await eventually { session.pendingSnapshot.tiles.contains { $0.item.uid == uid } })

        #expect(await session.delete([uid]))
        #expect(await eventually { !connection.trash.localUIDs.isEmpty }, "a deleted file shows in Recently Deleted")
        #expect(connection.trash.localUIDs == session.trash.localUIDs)
        #expect(connection.excludedTiles.map(\.item.uid) == [uid], "the Backup settings list shows the deleted file")

        _ = connection.retire()
        #expect(connection.trash.isEmpty)
        #expect(connection.excludedTiles.isEmpty)
        await session.close()
        await fixture.controller.shutdown()
        fixture.store.close()
        fileQueue.close()
    }

    // MARK: - A replaced or retired session

    /// A second fixture opens its own store and controller beside the first.
    private func start(
        _ connection: PendingGridConnection, _ fixture: Fixture, files: PendingFileSource? = nil
    ) -> PendingGridStart {
        connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects(), files: files)
        }
    }

    @Test func aFirstStartReplacesNothingAndLeavesTheRevisionAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()

        let started = start(connection, fixture)

        #expect(started.replaced.isEmpty, "nothing was live")
        #expect(connection.favoriteRevision == 0, "a first start refreshes no favorite display")
        _ = connection.retire()
        await started.session?.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func aSecondStartHandsBackTheEarlierSessionAndStore() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let connection = PendingGridConnection()
        let startedFirst = start(connection, first)
        let earlier = try #require(startedFirst.session)

        let startedSecond = start(connection, second)

        let later = try #require(startedSecond.session)
        #expect(later !== earlier)
        #expect(connection.session === later, "the connection shows the new session")
        #expect(startedSecond.replaced.session === earlier, "the earlier session comes back to be closed")
        #expect(startedSecond.replaced.store === first.store, "the earlier store comes back to be closed")
        #expect(first.store.isOperational(), "nothing closes it for the caller")
        #expect(connection.retire().store === second.store, "the new store is the one the connection keeps")

        await startedSecond.replaced.close(whileStoreOpen: { await first.controller.shutdown() })
        #expect(!first.store.isOperational(), "closing the pair closes the earlier store")
        #expect(second.store.isOperational(), "the new store stays open")
        await later.close()
        await second.controller.shutdown()
        second.store.close()
    }

    @Test func aStoreThatNoSessionUsedComesBackWithTheNextStart() async throws {
        let first = try Fixture(pendingStoreInController: false)
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let connection = PendingGridConnection()
        let startedFirst = start(connection, first)
        #expect(startedFirst.session == nil, "no session can start without a pending recorder")

        let startedSecond = start(connection, second)

        #expect(startedSecond.replaced.session == nil)
        #expect(startedSecond.replaced.store === first.store, "the kept store is not dropped open")
        await startedSecond.replaced.close()
        #expect(!first.store.isOperational())
        _ = connection.retire()
        await startedSecond.session?.close()
        await first.controller.shutdown()
        await second.controller.shutdown()
        second.store.close()
    }

    @Test func theSameStoreStartedAgainStaysTheLiveStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let startedFirst = start(connection, fixture)
        let earlier = try #require(startedFirst.session)

        let startedAgain = start(connection, fixture)

        #expect(startedAgain.replaced.session === earlier, "the earlier session still comes back")
        #expect(startedAgain.replaced.store == nil, "the live store is not handed back to be closed")
        var earlierClosed = false
        // The last step of a session's close publishes its lists.
        earlier.onListsChange = { earlierClosed = true }
        await startedAgain.replaced.close()
        #expect(earlierClosed, "closing what came back closes the earlier session")
        #expect(fixture.store.isOperational(), "closing what came back leaves the live store open")
        #expect(connection.retire().store === fixture.store)
        await startedAgain.session?.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func aStartThatBuildsNoSessionStillHandsBackTheEarlierPair() async throws {
        let first = try Fixture()
        let second = try Fixture(pendingStoreInController: false)
        defer {
            first.remove()
            second.remove()
        }
        let connection = PendingGridConnection()
        let earlier = try #require(start(connection, first).session)

        let started = start(connection, second)

        #expect(started.session == nil, "the second controller has no pending recorder, so no session starts")
        #expect(connection.session == nil)
        #expect(started.replaced.session === earlier, "the earlier session comes back to be closed")
        #expect(started.replaced.store === first.store, "the earlier store comes back to be closed")
        #expect(connection.favoriteRevision == 1, "the start retired the earlier pair, as retire() does")
        #expect(first.store.isOperational(), "nothing closes it for the caller")
        #expect(connection.retire().store === second.store, "the connection keeps the new store for the teardown")

        await started.replaced.close(whileStoreOpen: { await first.controller.shutdown() })
        #expect(!first.store.isOperational())
        #expect(second.store.isOperational(), "the new store stays open")
        await second.controller.shutdown()
        second.store.close()
    }

    @Test func aStoreThatNoSessionUsedStaysTheLiveStoreWhenTheSameStoreIsStartedAgain() async throws {
        let fixture = try Fixture(pendingStoreInController: false)
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        #expect(start(connection, fixture).session == nil)

        let startedAgain = start(connection, fixture)

        #expect(startedAgain.session == nil)
        #expect(startedAgain.replaced.isEmpty, "the same store is not handed back, so nothing comes back")
        #expect(fixture.store.isOperational())
        #expect(connection.retire().store === fixture.store, "the connection still keeps the store for the teardown")
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func aStartWithoutAStoreStillHandsBackTheEarlierPairAndKeepsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let earlier = try #require(start(connection, fixture).session)

        let started = connection.start(store: nil) { _ in
            Issue.record("no session is built without a store")
            return nil
        }

        #expect(started.session == nil)
        #expect(connection.session == nil)
        #expect(started.replaced.session === earlier, "the earlier session comes back to be closed")
        #expect(started.replaced.store === fixture.store, "the earlier store comes back to be closed")
        #expect(fixture.store.isOperational(), "nothing closes it for the caller")
        let retired = connection.retire()
        #expect(retired.session == nil && retired.store == nil, "the connection keeps neither session nor store")

        await started.replaced.close(whileStoreOpen: { await fixture.controller.shutdown() })
        #expect(!fixture.store.isOperational())
    }

    @Test func aRetiredPairClosesTheFolderBackupThenTheSessionThenThePhotoBackupThenTheStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let started = start(connection, fixture)
        let session = try #require(started.session)
        let retired = connection.retire()
        var events: [String] = []
        // The last step of a session's close that a test can observe is the publication of its lists. After it, the
        // close only waits for the update of the thumbnail feed, and `ThumbnailFeedCore` has setters but no getter.
        session.onListsChange = { events.append("session closed") }
        var storeOpenBefore: Bool?
        var storeOpenBetween: Bool?

        await retired.close(
            beforeSession: {
                events.append("folder backup")
                storeOpenBefore = fixture.store.isOperational()
            },
            whileStoreOpen: {
                events.append("photo backup")
                storeOpenBetween = fixture.store.isOperational()
            })

        // The account teardown shuts the folder backup down in an earlier stage than the photo backup, and the
        // session closes inside the photo backup stage, before the photo backup.
        #expect(
            events == ["folder backup", "session closed", "photo backup"],
            "the folder backup shuts down first, the session closes next, the photo backup follows")
        #expect(storeOpenBefore == true, "the store is open while the folder backup shuts down")
        #expect(storeOpenBetween == true, "the store is still open while the photo backup shuts down")
        #expect(!fixture.store.isOperational(), "the store closes last")
        await fixture.controller.shutdown()
    }

    @Test func anEmptyPairClosesNothingAndRunsNothing() async {
        var ran = false

        await RetiredPendingGrid.none.close(beforeSession: { ran = true }, whileStoreOpen: { ran = true })

        #expect(!ran, "an empty pair is not an owner")
    }

    /// Two watched files in a queue beside `fixture`'s store, so that a session lists files that it can delete.
    private func watchedFiles(
        in fixture: Fixture
    ) throws -> (files: PendingFileSource, uids: [PhotoUID], queue: UploadBackupSyncQueueManifestStore) {
        let queue = try #require(
            UploadBackupSyncQueueManifestStore(url: fixture.directory.appendingPathComponent("file-queue.sqlite")))
        let base = fixture.directory.appendingPathComponent("watched")
        var uids: [PhotoUID] = []
        for name in ["one.heic", "two.heic"] {
            let source = UploadSourceIdentity(kind: .fileURL, identifier: base.appendingPathComponent(name).path)
            #expect(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source, revision: UploadBackupRevision(rawValue: 1), originalFilename: name,
                        state: .queuedForUpload, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))))
            uids.append(PendingSourceKey(kind: .fileURL, identifier: source.identifier).localUID)
        }
        let files = PendingFileSource(
            queue: queue, metadata: AllFilesMetadata(), removeFromBackup: { _ in true }, returnToBackup: { _ in true })
        return (files, uids, queue)
    }

    @Test func aReplacedSessionCannotChangeTheConnection() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let watched = try watchedFiles(in: first)
        defer { watched.queue.close() }
        let connection = PendingGridConnection()
        let earlier = try #require(start(connection, first, files: watched.files).session)
        let listed = {
            watched.uids.allSatisfy { uid in earlier.pendingSnapshot.tiles.contains { $0.item.uid == uid } }
        }
        #expect(await eventually { listed() })
        let startedSecond = start(connection, second)
        let later = try #require(startedSecond.session)
        #expect(connection.session === later)
        let revision = connection.favoriteRevision

        // The replaced session still works until the caller closes it. Its changes reach its own callbacks only.
        #expect(await earlier.delete([watched.uids[0]]))
        #expect(await eventually { earlier.trash.localUIDs == Set([watched.uids[0]]) })
        #expect(connection.trash.isEmpty, "a replaced session does not fill the lists of the connection")
        #expect(connection.excludedTiles.isEmpty)
        let favorite = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        #expect(await earlier.setFavorite([favorite], favorite: true))
        #expect(await eventually { earlier.pendingSnapshot.favoriteIntents == [favorite: true] })
        #expect(connection.favoriteRevision == revision, "a replaced session does not refresh favorite displays")
        #expect(connection.session === later, "the new session stays the one that the connection shows")

        await startedSecond.replaced.close(whileStoreOpen: { await first.controller.shutdown() })
        _ = connection.retire()
        await later.close()
        await second.controller.shutdown()
        second.store.close()
    }

    @Test func aReplacingStartHasTheEffectsOfRetire() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let watched = try watchedFiles(in: fixture)
        defer { watched.queue.close() }
        let connection = PendingGridConnection()
        let earlier = try #require(start(connection, fixture, files: watched.files).session)
        let listed = {
            watched.uids.allSatisfy { uid in earlier.pendingSnapshot.tiles.contains { $0.item.uid == uid } }
        }
        #expect(await eventually { listed() })
        #expect(await earlier.delete([watched.uids[0]]))
        #expect(await eventually { connection.trash.localUIDs == Set([watched.uids[0]]) })
        let favorite = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        #expect(await earlier.setFavorite([favorite], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 1 })

        let startedSecond = start(connection, fixture, files: watched.files)

        // Nothing has run since the start returned, so these values are the effects of the retire inside it.
        #expect(connection.trash.isEmpty, "the lists of the replaced session leave with it")
        #expect(connection.excludedTiles.isEmpty)
        #expect(connection.favoriteRevision == 2, "a replacing start refreshes favorite displays, as retire() does")
        let later = try #require(startedSecond.session)
        // The favorite intent is stored. A session that starts after the retire reports it as new.
        #expect(await later.setFavorite([favorite], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 3 }, "the replaced session's intents are forgotten")

        await startedSecond.replaced.close()
        _ = connection.retire()
        await later.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    /// Each host builds one photo backup controller per start. A session hooks the library change of its own
    /// controller, and its close unhooks that controller only.
    @Test func aReplacedSessionUnhooksOnlyItsOwnController() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let connection = PendingGridConnection()
        let startedFirst = start(connection, first)
        #expect(first.controller.onLibraryChange != nil, "the session hooks the library change of its controller")
        let startedSecond = start(connection, second)
        let later = try #require(startedSecond.session)
        #expect(second.controller.onLibraryChange != nil)

        await startedSecond.replaced.close(whileStoreOpen: { await first.controller.shutdown() })

        #expect(first.controller.onLibraryChange == nil, "the replaced session unhooks its own controller")
        #expect(second.controller.onLibraryChange != nil, "the controller of the new session keeps its hook")
        #expect(startedFirst.session != nil)
        _ = connection.retire()
        await later.close()
        await second.controller.shutdown()
        second.store.close()
    }

    @Test func thePresentationHandlerWritesOnlyWhileTheConnectionShowsTheSession() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let connection = PendingGridConnection()
        let earlier = try #require(start(connection, first).session)
        var applied: [String] = []
        let earlierHandler = connection.presentationHandler(for: earlier) { _ in applied.append("earlier") }

        earlierHandler(.empty)
        #expect(applied == ["earlier"], "the session that the connection shows publishes")

        let startedSecond = start(connection, second)
        let later = try #require(startedSecond.session)
        let laterHandler = connection.presentationHandler(for: later) { _ in applied.append("later") }
        earlierHandler(.empty)
        #expect(applied == ["earlier"], "a replaced session does not publish while another session is shown")
        laterHandler(.empty)
        #expect(applied == ["earlier", "later"], "the new session publishes")

        _ = connection.retire()
        laterHandler(.empty)
        earlierHandler(.empty)
        #expect(applied == ["earlier", "later"], "a retired session does not publish, and neither does a replaced one")

        await startedSecond.replaced.close(whileStoreOpen: { await first.controller.shutdown() })
        await later.close()
        await second.controller.shutdown()
        second.store.close()
    }

    /// The close of a session publishes through its presenter. The handler lets that publication through only while
    /// the connection shows the session.
    @Test func theCloseOfARetiredSessionPublishesNothingThroughTheHandler() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let session = try #require(start(connection, fixture).session)
        var applied = 0
        session.presenter.onChange = connection.presentationHandler(for: session) { _ in applied += 1 }

        session.presenter.reset()
        #expect(applied == 1, "a publication of the session that the connection shows reaches the host")

        let retired = connection.retire()
        await session.close()
        #expect(applied == 1, "the publication in the close of a retired session does not reach the host")
        await fixture.controller.shutdown()
        retired.store?.close()
    }

    /// The handler outlives neither the connection nor the session that it names: a host that keeps the callback
    /// does not keep them alive.
    @Test func thePresentationHandlerKeepsNeitherTheConnectionNorTheSessionAlive() throws {
        let fixture = try Fixture()
        defer {
            fixture.store.close()
            fixture.remove()
        }
        var connection: PendingGridConnection? = PendingGridConnection()
        var session: PendingGridSession? = PendingGridSession(
            store: fixture.store, photoBackup: fixture.controller, remote: NoRemoteEffects())
        weak var weakConnection = connection
        weak var weakSession = session
        let handler = try #require(connection).presentationHandler(for: try #require(session)) { _ in }

        connection = nil
        session = nil

        #expect(weakConnection == nil, "the handler holds the connection weakly")
        #expect(weakSession == nil, "the handler holds the session weakly")
        handler(.empty)
    }

    @Test func aRetiredSessionCannotChangeTheConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let watched = try watchedFiles(in: fixture)
        defer { watched.queue.close() }
        let uids = watched.uids
        let connection = PendingGridConnection()
        let started = start(connection, fixture, files: watched.files)
        let session = try #require(started.session)
        let shown = { uids.allSatisfy { uid in session.pendingSnapshot.tiles.contains { $0.item.uid == uid } } }
        #expect(await eventually { shown() })
        #expect(await session.delete([uids[0]]))
        #expect(await eventually { connection.trash.localUIDs == Set([uids[0]]) })
        _ = connection.retire()
        #expect(connection.trash.isEmpty)
        let revision = connection.favoriteRevision

        // The retired session still works until it is closed: its next change reaches its own callbacks.
        #expect(await session.delete([uids[1]]))
        #expect(await eventually { session.trash.localUIDs.count == 2 }, "the retired session lists both files")
        #expect(connection.trash.isEmpty, "a retired session does not fill the lists of the connection")
        #expect(connection.excludedTiles.isEmpty)
        let favorite = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        #expect(await session.setFavorite([favorite], favorite: true))
        #expect(await eventually { session.pendingSnapshot.favoriteIntents == [favorite: true] })
        #expect(connection.favoriteRevision == revision, "a retired session does not refresh favorite displays")
        #expect(connection.session == nil)
        await session.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    /// A deadline, not a number of tries: a loaded machine slows the session's snapshot stream, not the result.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private final class ChangeCounter: @unchecked Sendable {
    var count = 0
}

private actor HandlerBox {
    private(set) var handler: (@Sendable ([PhotoUID], String) async -> Bool)?
    func set(_ handler: @escaping @Sendable ([PhotoUID], String) async -> Bool) { self.handler = handler }
}

@MainActor
private struct Fixture {
    let suite = "pending-grid-connection-\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let store: PendingBackupManifestStore
    let controller: PhotoLibraryBackupController

    init(pendingStoreInController: Bool = true) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil,
            uploader: MockUploader(),
            pendingStore: pendingStoreInController ? store : nil,
            requiresPendingStore: pendingStoreInController
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct AllFilesMetadata: PendingSourceMetadataProviding {
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
