import Foundation
import PhotosCore
import SQLite3
import Testing

@testable import ProtonDriveBackend

@Suite struct TrashedSeriesRestoreJournalTests {
    static func duty(generation: UUID = UUID(), frames: [String] = ["frame"]) -> TrashedSeriesRestoreRecord {
        .init(
            generation: generation, main: PhotoUID(volumeID: "volume", nodeID: "main"), mainTrashTime: 1000,
            frames: frames.map {
                .init(uid: PhotoUID(volumeID: "volume", nodeID: $0), mainPhotoLinkID: "main", trashTime: 1001)
            }, retryAt: Date(timeIntervalSince1970: 100))
    }

    struct Directory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var database: URL { url.appendingPathComponent(TrashedSeriesRestoreJournal.fileName) }
        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    @Test func anUnresolvedDutySurvivesRealCloseAndReopen() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        let duty = Self.duty()
        try journal.record([duty])
        journal.close()
        let reopened = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        defer { reopened.close() }
        #expect(try reopened.records() == [duty])
    }

    @Test func aPartialSettlementRetainsOnlyUnresolvedFramesOnDisk() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        var duty = Self.duty(frames: ["first", "second"])
        try journal.record([duty])
        duty.frames.removeFirst()
        try journal.update(duty)
        journal.close()
        let reopened = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        defer { reopened.close() }
        #expect(try reopened.records() == [duty])
    }

    @Test func anOldGenerationCannotClearANewerDuty() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        defer { journal.close() }
        var old = Self.duty()
        try journal.record([old])
        let newer = Self.duty()
        try journal.record([newer])
        old.frames = []
        try journal.update(old)
        #expect(try journal.records() == [newer])
        try journal.update(Self.duty(generation: old.generation))
        #expect(try journal.records() == [newer], "a stale nonempty update cannot replace a newer generation")
    }

    @Test func aClosedJournalRefusesTheWrite() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        journal.close()
        #expect(throws: (any Error).self) { try journal.record([Self.duty()]) }
    }

    @Test func anUnknownSchemaIsUnavailableAndUntouched() throws {
        let directory = try Directory()
        defer { directory.remove() }
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.database.path, &db) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                db, "CREATE TABLE future_duties(proof TEXT); INSERT INTO future_duties VALUES('owed');", nil, nil, nil)
                == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: directory.database)
        let journal = TrashedSeriesRestoreJournal(url: directory.database)
        journal?.close()
        #expect(journal == nil)
        #expect(try Data(contentsOf: directory.database) == before)
    }
    @Test func anotherSchemaVersionIsUnavailableAndUntouched() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        try journal.record([Self.duty()])
        journal.close()
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.database.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE restore_info SET value=2 WHERE key='schema';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: directory.database)
        let reopened = TrashedSeriesRestoreJournal(url: directory.database)
        reopened?.close()
        #expect(reopened == nil)
        #expect(try Data(contentsOf: directory.database) == before)
    }

    @Test func anUndecodableDutyStaysUntouchedAndPreventsReplacement() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        try journal.record([Self.duty()])
        journal.close()
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.database.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE restore_duties SET payload=x'FF';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let reopened = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        #expect(throws: (any Error).self) { try reopened.records() }
        #expect(throws: (any Error).self) { try reopened.record([Self.duty()]) }
        reopened.close()
        #expect(sqlite3_open_v2(directory.database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT hex(payload) FROM restore_duties;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_text(statement, 0).map { String(cString: $0) } == "FF")
    }
    @Test func aRefusedDurabilitySettingPreventsTheWrite() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let schema = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        schema.close()
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.database.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        let journal = TrashedSeriesRestoreJournal(connection: SQLiteStoreConnection(database: handle))
        defer { journal.close() }
        sqlite3_set_authorizer(
            handle,
            { _, action, name, _, _, _ in
                if action == SQLITE_PRAGMA, name.map({ String(cString: $0) }) == "synchronous" { return SQLITE_DENY }
                return SQLITE_OK
            }, nil)
        #expect(throws: (any Error).self) { try journal.record([Self.duty()]) }
        sqlite3_set_authorizer(handle, nil, nil)
        #expect(try journal.records().isEmpty)
    }

    @Test func aRefusedCommitRollsBackAndPreservesThePreviousGeneration() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let schema = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        let old = Self.duty()
        try schema.record([old])
        schema.close()
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.database.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        let journal = TrashedSeriesRestoreJournal(connection: SQLiteStoreConnection(database: handle))
        defer { journal.close() }
        sqlite3_set_authorizer(
            handle,
            { _, action, name, _, _, _ in
                if action == SQLITE_TRANSACTION, name.map({ String(cString: $0) }) == "COMMIT" { return SQLITE_DENY }
                return SQLITE_OK
            }, nil)
        #expect(throws: (any Error).self) { try journal.record([Self.duty()]) }
        sqlite3_set_authorizer(handle, nil, nil)
        #expect(try journal.records() == [old])
    }
    @Test func aGenerationChangedDuringTheReadCannotDispatchOldFrameAuthority() async throws {
        let directory = try Directory()
        defer { directory.remove() }
        let replay = TrashedSeriesRestoreReplay(url: directory.database, policy: .conservative)
        let journal = try #require(replay.journal)
        let old = Self.duty()
        let newer = Self.duty()
        try journal.record([old])
        let calls = Calls()
        _ = try await replay.exclusive {
            await replay.resume(
                [old],
                read: { _ in
                    try journal.record([newer])
                    return [
                        old.main: RemoteLinkVisibility(isActive: true, mainPhotoLinkID: nil),
                        old.frames[0].uid: RemoteLinkVisibility(
                            isActive: false, mainPhotoLinkID: "main", trashTime: 1001),
                    ]
                }, restore: { await calls.record($0) })
        }
        #expect(await calls.photos.isEmpty)
        #expect(try journal.records() == [newer])
        await replay.shutdown()
    }

    @Test func aClosedReplayRejectsANewOperation() async throws {
        let directory = try Directory()
        defer { directory.remove() }
        let replay = TrashedSeriesRestoreReplay(url: directory.database, policy: .conservative)
        let calls = Calls()
        await replay.shutdown()
        await #expect(throws: CancellationError.self) {
            try await replay.exclusive { await calls.record([Self.duty().main]) }
        }
        #expect(await calls.photos.isEmpty)
    }

    @Test func aLaterTrashWaitsForTheInFlightFrameOperation() async throws {
        let directory = try Directory()
        defer { directory.remove() }
        let replay = TrashedSeriesRestoreReplay(url: directory.database, policy: .conservative)
        let calls = Calls()
        let latch = OperationLatch()
        let frame = Self.duty().frames[0].uid
        let main = Self.duty().main
        let first = Task {
            try await replay.exclusive {
                await latch.hold()
                await calls.record([frame])
            }
        }
        for _ in 0..<500 {
            if await latch.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = Task { try await replay.exclusive { await calls.record([main]) } }
        for _ in 0..<500 {
            if await replay.waitingOperations == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let queued = await replay.waitingOperations == 1
        await latch.release()
        try await first.value
        try await second.value
        #expect(queued, "a later trash queues behind the in-flight frame operation")
        #expect(await calls.photos == [frame, main])
        await replay.shutdown()
    }

    private actor OperationLatch {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor Calls {
        var photos: [PhotoUID] = []
        func record(_ photos: [PhotoUID]) { self.photos.append(contentsOf: photos) }
    }
    @Test func aStaleSameGenerationSnapshotCannotResurrectASettledFrame() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        defer { journal.close() }
        let old = Self.duty(frames: ["first", "second"])
        try journal.record([old])
        var partial = old
        partial.frames.removeFirst()
        try journal.update(partial)
        try journal.update(old)
        #expect(try journal.records() == [partial])
    }
    @Test func anInconsistentRowIdentityCannotAuthorizeReplacement() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let schema = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        try schema.record([Self.duty()])
        schema.close()
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.database.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE restore_duties SET generation='unknown';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        defer { journal.close() }
        #expect(throws: (any Error).self) { try journal.records() }
        #expect(throws: (any Error).self) { try journal.record([Self.duty()]) }
    }

    @Test func invalidNewProofCannotReplaceAnExistingDuty() throws {
        let directory = try Directory()
        defer { directory.remove() }
        let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
        defer { journal.close() }
        let original = Self.duty()
        try journal.record([original])
        var invalid = Self.duty()
        invalid.frames = [.init(uid: invalid.main, mainPhotoLinkID: "foreign", trashTime: 1001)]
        #expect(throws: (any Error).self) { try journal.record([invalid]) }
        #expect(try journal.records() == [original])
    }
}
