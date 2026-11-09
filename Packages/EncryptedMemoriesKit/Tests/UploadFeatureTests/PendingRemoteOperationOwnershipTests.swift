import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class PendingRemoteOperationOwnershipTests: XCTestCase {
    private var directory: URL!
    private var store: PendingBackupManifestStore!
    private let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "operation-owner")
    private let first = PhotoUID(volumeID: "photos", nodeID: "first")
    private let second = PhotoUID(volumeID: "photos", nodeID: "second")
    private let date = Date(timeIntervalSince1970: 1_750_000_000)
    private var url: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try XCTUnwrap(PendingBackupManifestStore(url: url))
    }

    override func tearDownWithError() throws {
        store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func exclude(_ remote: PhotoUID) throws -> PendingSourceState {
        try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date)?.first)
    }

    private func reopen() throws {
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: url))
    }

    private final class BindingRefusal {
        let action: Int32
        var hit = false
        init(_ action: Int32) { self.action = action }
    }

    private func connection() throws -> SQLiteStoreConnection {
        try XCTUnwrap(
            Mirror(reflecting: store!).children.first { $0.label == "connection" }?.value as? SQLiteStoreConnection)
    }

    func testQueueCompletionKeepsItsIndependentRemoteOperationBinding() throws {
        let excluded = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [excluded]), [key])
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: excluded.generation, at: date))
        let current = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertFalse(current.needsQueueSync)
        XCTAssertEqual(current.remoteOperation, .remoteTrash)
        let connection = try connection()
        connection.withLock {
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(connection.database, "SELECT count(*) FROM remote_operation;", -1, &stmt, nil),
                SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        }
    }

    func testOlderTargetCompletionClearsItsOwnOperationAndKeepsTheNewTargetOwed() throws {
        let old = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [old]), [key])
        _ = try exclude(second)
        try reopen()

        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: old.generation, remoteLinkID: first.nodeID, at: date))

        let current = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertNil(current.remoteOperation)
        XCTAssertEqual(current.remote, second)
        XCTAssertTrue(current.needsRemoteTrash)
        XCTAssertFalse(current.remoteTrashed)
    }

    func testOlderTargetCompletionKeepsTheNewTargetsInFlightOperationAfterReopen() throws {
        let old = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [old]), [key])
        _ = store.include([key], at: date)
        let newer = try exclude(second)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [newer]), [key])
        try reopen()
        let before = try XCTUnwrap(store.sourceState(for: key))

        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: old.generation, remoteLinkID: first.nodeID, at: date))

        XCTAssertEqual(
            store.sourceState(for: key), before, "an old acknowledgement cannot clear the newer in-flight trash")
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: newer.generation, remoteLinkID: second.nodeID, at: date))
        XCTAssertNil(store.sourceState(for: key)?.remoteOperation)
        XCTAssertTrue(try XCTUnwrap(store.sourceState(for: key)).remoteTrashed)
    }

    func testOlderGenerationCompletionKeepsANewerOperationForTheSamePhoto() throws {
        let old = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [old]), [key])
        _ = store.include([key], at: date)
        let newer = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [newer]), [key])
        try reopen()
        let before = try XCTUnwrap(store.sourceState(for: key))

        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: old.generation, remoteLinkID: first.nodeID, at: date))

        XCTAssertEqual(store.sourceState(for: key), before)
    }

    func testWrongPhotoCompletionCannotClearAnOperationInTheSameGeneration() throws {
        let current = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [current]), [key])
        let before = try XCTUnwrap(store.sourceState(for: key))

        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: current.generation, remoteLinkID: second.nodeID, at: date))

        XCTAssertEqual(store.sourceState(for: key), before)
    }

    func testWrongEffectCompletionCannotClearAnOperationForTheSamePhotoAndGeneration() throws {
        let current = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [current]), [key])
        let before = try XCTUnwrap(store.sourceState(for: key))

        XCTAssertTrue(
            store.completeEffect(
                .remoteRestore, for: key, generation: current.generation, remoteLinkID: first.nodeID, at: date))

        XCTAssertEqual(store.sourceState(for: key), before)
    }

    func testRefusedOperationBindingRollsBackTheDispatchMarker() throws {
        let current = try exclude(first)
        let connection = try connection()
        connection.withLock {
            sqlite3_set_authorizer(
                connection.database,
                { _, action, name, _, _, _ in
                    action == SQLITE_INSERT && name.map { String(cString: $0) } == "remote_operation"
                        ? SQLITE_DENY : SQLITE_OK
                }, nil)
        }
        defer { connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) } }

        XCTAssertNil(store.beginRemoteOperation(.remoteTrash, for: [current]))

        XCTAssertNil(store.sourceState(for: key)?.remoteOperation, "an unbound operation must never be dispatched")
    }

    func testUnreadableOrMalformedBindingNeverAuthorizesACompletion() throws {
        for assignment in [
            "effect='future'", "effect='queueSync'", "effect=CAST(X'72656d6f746554726173680078' AS TEXT)",
            "remote_volume_id=CAST(X'ff' AS TEXT)", "remote_link_id=CAST(X'66697273740078' AS TEXT)",
            "generation='unknown'",
        ] {
            let current = try exclude(first)
            XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [current]), [key])
            let before = try XCTUnwrap(store.sourceState(for: key))
            let connection = try connection()
            connection.withLock {
                XCTAssertEqual(
                    sqlite3_exec(connection.database, "UPDATE remote_operation SET \(assignment);", nil, nil, nil),
                    SQLITE_OK)
            }

            XCTAssertFalse(
                store.completeEffect(
                    .remoteTrash, for: key, generation: current.generation, remoteLinkID: first.nodeID, at: date),
                assignment)

            XCTAssertEqual(store.sourceState(for: key), before, assignment)
        }
    }

    func testARefusedBindingReadOrDeleteRollsBackCompletion() throws {
        for action in [SQLITE_READ, SQLITE_DELETE] {
            let current = try exclude(first)
            XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [current]), [key])
            let before = try XCTUnwrap(store.sourceState(for: key))
            let connection = try connection()
            let fault = BindingRefusal(action)
            let context = Unmanaged.passRetained(fault)
            defer { context.release() }
            connection.withLock {
                sqlite3_set_authorizer(
                    connection.database,
                    { context, action, name, _, _, _ in
                        let fault = Unmanaged<BindingRefusal>.fromOpaque(context!).takeUnretainedValue()
                        if !fault.hit, action == fault.action, name.map({ String(cString: $0) }) == "remote_operation" {
                            fault.hit = true
                            return SQLITE_DENY
                        }
                        return SQLITE_OK
                    }, context.toOpaque())
            }
            let result = store.completeEffect(
                .remoteTrash, for: key, generation: current.generation, remoteLinkID: first.nodeID, at: date)
            connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) }

            XCTAssertTrue(fault.hit)
            XCTAssertFalse(result)
            XCTAssertEqual(store.sourceState(for: key), before)
            try reopen()
        }
    }

    private final class BindingStepFault {
        let database: OpaquePointer
        var readingBinding = false
        var interrupted = false
        init(_ database: OpaquePointer) { self.database = database }
    }

    func testAnInterruptedBindingStepCannotBecomeLegacyAbsence() throws {
        let current = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [current]), [key])
        let before = try XCTUnwrap(store.sourceState(for: key))
        let connection = try connection()
        let fault = BindingStepFault(try XCTUnwrap(connection.database))
        let context = Unmanaged.passRetained(fault)
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    Unmanaged<BindingStepFault>.fromOpaque(context).takeUnretainedValue().readingBinding =
                        String(cString: sql).hasPrefix("SELECT effect,")
                    return 0
                }, context.toOpaque())
            sqlite3_progress_handler(
                connection.database, 1,
                { context in
                    let fault = Unmanaged<BindingStepFault>.fromOpaque(context!).takeUnretainedValue()
                    guard fault.readingBinding, !fault.interrupted else { return 0 }
                    fault.interrupted = true
                    sqlite3_progress_handler(fault.database, 0, nil, nil)
                    return 1
                }, context.toOpaque())
        }
        defer {
            connection.withLock {
                sqlite3_trace_v2(connection.database, 0, nil, nil)
                sqlite3_progress_handler(connection.database, 0, nil, nil)
            }
            context.release()
        }
        XCTAssertFalse(
            store.completeEffect(
                .remoteTrash, for: key, generation: current.generation, remoteLinkID: first.nodeID, at: date))
        XCTAssertTrue(fault.interrupted, "the binding SELECT itself must be interrupted")
        XCTAssertEqual(store.sourceState(for: key), before)
    }

    func testARefusedBindingDeleteRollsBackAConfirmedRestoreRecheck() throws {
        let excluded = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [excluded]), [key])
        let included = try XCTUnwrap(store.include([key], at: date)?.first)
        let connection = try connection()
        connection.withLock {
            sqlite3_set_authorizer(
                connection.database,
                { _, action, name, _, _, _ in
                    action == SQLITE_DELETE && name.map { String(cString: $0) } == "remote_operation"
                        ? SQLITE_DENY : SQLITE_OK
                }, nil)
        }
        let result = store.finishRestoreRecheck(included, outcome: .completed, at: date)
        connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) }
        XCTAssertFalse(result)
        XCTAssertEqual(store.sourceState(for: key), included)
    }

    func testAConfirmedRestoreRecheckClearsTheOperationBindingWithItsMarker() throws {
        let excluded = try exclude(first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [excluded]), [key])
        let included = try XCTUnwrap(store.include([key], at: date)?.first)

        XCTAssertTrue(store.finishRestoreRecheck(included, outcome: .completed, at: date))

        XCTAssertNil(store.sourceState(for: key)?.remoteOperation)
        let connection = try connection()
        connection.withLock {
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(connection.database, "SELECT count(*) FROM remote_operation;", -1, &stmt, nil),
                SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(stmt, 0), 0)
        }
    }
}
