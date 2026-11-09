import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

#if os(macOS)
    import Darwin
#endif

#if os(macOS)
    final class PendingStoreMigrationTests: XCTestCase {
        private var directory: URL!

        override func setUpWithError() throws {
            let parent =
                ProcessInfo.processInfo.environment["PENDING_MIGRATION_CRASH_PATH"]
                .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? FileManager.default.temporaryDirectory
            directory = parent.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            try FileManager.default.removeItem(at: directory)
        }

        private func fixture(_ release: String) throws -> URL {
            let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            let folder = directory.appendingPathComponent("\(release)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let extraction = Process()
            extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            extraction.arguments = [
                "-xzf", root.appendingPathComponent("\(release)/pending-operation-v1.tar.gz").path, "-C", folder.path,
            ]
            try extraction.run()
            extraction.waitUntilExit()
            XCTAssertEqual(extraction.terminationStatus, 0)
            return folder.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        }

        private func withDatabase<T>(
            _ url: URL, readOnly: Bool = false, _ body: (OpaquePointer) throws -> T
        ) throws -> T {
            var db: OpaquePointer?
            XCTAssertEqual(
                sqlite3_open_v2(
                    url.path, &db, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
                SQLITE_OK)
            let handle = try XCTUnwrap(db)
            defer { sqlite3_close(handle) }
            return try body(handle)
        }

        private func execute(_ db: OpaquePointer, _ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }

        private func text(_ db: OpaquePointer, _ sql: String) throws -> String {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            return String(cString: try XCTUnwrap(sqlite3_column_text(stmt, 0)))
        }

        /// Includes every stored byte and SQLite value type, including the hidden remote_op marker.
        private func rows(_ db: OpaquePointer, _ table: String, excludingSchema: Bool = false) throws -> [[String]] {
            let condition = excludingSchema ? " WHERE key!='schema'" : ""
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(db, "SELECT * FROM \(table)\(condition) ORDER BY rowid;", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            var result: [[String]] = []
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                var values: [String] = []
                for index in 0..<sqlite3_column_count(stmt) {
                    let type = sqlite3_column_type(stmt, index)
                    let bytes = sqlite3_column_blob(stmt, index)
                    let count = Int(sqlite3_column_bytes(stmt, index))
                    let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
                    values.append("\(type):\(data.base64EncodedString())")
                }
                result.append(values)
                step = sqlite3_step(stmt)
            }
            XCTAssertEqual(step, SQLITE_DONE)
            return result
        }

        private func legacyRows(_ url: URL) throws -> [String: [[String]]] {
            try withDatabase(url, readOnly: true) { db in
                var result: [String: [[String]]] = [:]
                for table in [
                    "pending_info", "source_state", "upload_evidence", "handoff", "pending_action", "saved_from_app",
                    "sqlite_stat1",
                ] {
                    result[table] = try rows(db, table, excludingSchema: table == "pending_info")
                }
                return result
            }
        }

        func testBothReleasedPendingStoresMigrateEveryRowAndKeepTheirUnknownOperationOwner() throws {
            for release in ["v1.0.5", "v1.1.0"] {
                let url = try fixture(release)
                try withDatabase(url) { db in
                    XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), "1")
                    XCTAssertEqual(try text(db, "SELECT remote_op FROM source_state;"), "remoteTrash")
                    execute(db, "INSERT INTO pending_info VALUES('preserved', 17);")
                }
                let before = try legacyRows(url)
                for table in [
                    "source_state", "upload_evidence", "handoff", "pending_action", "saved_from_app", "sqlite_stat1",
                ] {
                    XCTAssertFalse(try XCTUnwrap(before[table]).isEmpty, "\(release) \(table)")
                }

                let store = try XCTUnwrap(PendingBackupManifestStore(url: url), release)
                XCTAssertTrue(store.isOperational())
                XCTAssertEqual(
                    try legacyRows(url), before, "every legacy row survives before close-time optimization: \(release)")
                store.close()
                try withDatabase(url) { db in
                    XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), "2")
                    XCTAssertEqual(
                        try text(db, "SELECT count(*) FROM remote_operation;"), "0",
                        "a legacy target must not be guessed")
                }
                let reopened = try XCTUnwrap(PendingBackupManifestStore(url: url))
                defer { reopened.close() }
                let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "released-asset")
                let old = try XCTUnwrap(reopened.sourceState(for: key))
                XCTAssertEqual(old.remoteOperation, .remoteTrash)
                let second = PhotoUID(volumeID: "photos", nodeID: "newer-main")
                XCTAssertNotNil(
                    reopened.exclude(
                        [PendingExclusionRequest(key: key, presentation: nil, remote: second)], at: old.updatedAt))
                XCTAssertNotEqual(
                    reopened.completeEffectResult(
                        .remoteTrash, for: key, generation: old.generation, remoteLinkID: "released-main",
                        at: old.updatedAt),
                    .failed)
                let current = try XCTUnwrap(reopened.sourceState(for: key))
                XCTAssertNil(current.remoteOperation, "legacy unknown ownership keeps the previous contract")
                XCTAssertEqual(current.remote, second)
                XCTAssertTrue(current.needsRemoteTrash)
            }
        }

        func testUnknownFutureAndDamagedLegacySchemasStayUntouchedAndUnavailable() throws {
            let changes = [
                "UPDATE pending_info SET value=42 WHERE key='schema';",
                "UPDATE pending_info SET value='1unknown' WHERE key='schema';",
                "UPDATE pending_info SET value=1.5 WHERE key='schema';",
                "DELETE FROM pending_info WHERE key='schema';",
                "ALTER TABLE source_state ADD COLUMN future TEXT;",
                "CREATE TABLE future(value);",
                "CREATE TABLE sqliteX(value);",
                "CREATE TABLE temporary_id(id INTEGER PRIMARY KEY AUTOINCREMENT); DROP TABLE temporary_id;",
                "CREATE INDEX future ON source_state(source_id);",
                "CREATE VIEW future AS SELECT * FROM source_state;",
                "CREATE TRIGGER future AFTER INSERT ON saved_from_app BEGIN SELECT 1; END;",
                "DROP TABLE upload_evidence;",
            ]
            for sql in changes {
                let url = try fixture("v1.0.5")
                try withDatabase(url) { execute($0, sql) }
                let bytes = try Data(contentsOf: url)

                let refused = PendingBackupManifestStore(url: url)

                XCTAssertNil(refused, sql)
                refused?.close()
                XCTAssertEqual(try Data(contentsOf: url), bytes, sql)
            }
            let damaged = directory.appendingPathComponent("damaged.sqlite")
            let bytes = Data("not a SQLite database".utf8)
            try bytes.write(to: damaged)
            XCTAssertNil(PendingBackupManifestStore(url: damaged))
            XCTAssertEqual(try Data(contentsOf: damaged), bytes)
        }

        func testANewPendingStoreUsesVersionTwo() throws {
            let url = directory.appendingPathComponent("new.sqlite")
            let store = try XCTUnwrap(PendingBackupManifestStore(url: url))
            store.close()
            try withDatabase(url) { db in
                XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), "2")
            }
        }

        func testSQLiteOwnedObjectsAloneAreNotAnEmptyPendingDatabase() throws {
            let url = directory.appendingPathComponent("internal-only.sqlite")
            try withDatabase(url) { db in
                execute(db, "CREATE TABLE temporary_id(id INTEGER PRIMARY KEY AUTOINCREMENT); DROP TABLE temporary_id;")
            }
            let before = try Data(contentsOf: url)
            let store = PendingBackupManifestStore(url: url)
            XCTAssertNil(store)
            store?.close()
            XCTAssertEqual(try Data(contentsOf: url), before)
        }

        func testAnUnknownOptimizerSchemaRemainsUntouched() throws {
            let url = try fixture("v1.0.5")
            let original = Data("CREATE TABLE sqlite_stat1(tbl,idx,stat)".utf8)
            let replacement = Data("CREATE TABLE sqlite_stat1(tbl,idx,xtra)".utf8)
            XCTAssertEqual(original.count, replacement.count)
            var bytes = try Data(contentsOf: url)
            let range = try XCTUnwrap(bytes.range(of: original))
            bytes.replaceSubrange(range, with: replacement)
            try bytes.write(to: url)
            try withDatabase(url, readOnly: true) { db in
                XCTAssertEqual(
                    try text(db, "SELECT sql FROM sqlite_schema WHERE name='sqlite_stat1';"),
                    String(decoding: replacement, as: UTF8.self))
            }
            let refused = PendingBackupManifestStore(url: url)
            XCTAssertNil(refused)
            refused?.close()
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }

        func testStrictEmptyClassificationIsOptInAndKeepsReadFailuresUnavailable() throws {
            let url = directory.appendingPathComponent("classifier.sqlite")
            try withDatabase(url) { db in
                execute(db, "CREATE TABLE temporary_id(id INTEGER PRIMARY KEY AUTOINCREMENT); DROP TABLE temporary_id;")
                XCTAssertEqual(SQLiteStoreSchemaGate.state(of: db), .empty)
                XCTAssertEqual(SQLiteStoreSchemaGate.state(of: db, strictEmptySchema: true), .populated)
                sqlite3_set_authorizer(
                    db, { _, action, _, _, _, _ in action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK }, nil)
                XCTAssertEqual(SQLiteStoreSchemaGate.state(of: db), .unavailable)
                XCTAssertEqual(SQLiteStoreSchemaGate.state(of: db, strictEmptySchema: true), .unavailable)
                sqlite3_set_authorizer(db, nil, nil)
                XCTAssertEqual(SQLiteStoreSchemaGate.state(of: db, strictEmptySchema: true), .populated)
                XCTAssertFalse(
                    SQLiteStoreSchemaGate.initializeCurrentSchema(
                        db, schemaSQL: "CREATE TABLE marker(value);", strictEmptySchema: true, stamp: { true }))
                XCTAssertEqual(try text(db, "SELECT count(*) FROM sqlite_schema WHERE name='marker';"), "0")
            }
        }

        func testBothGateModesKeepAnAcceptedSchemaAndItsOptimizerRows() throws {
            let url = directory.appendingPathComponent("accepted.sqlite")
            let schema = "CREATE TABLE marker(value INTEGER); CREATE INDEX marker_idx ON marker(value);"
            let first = try XCTUnwrap(
                SQLiteStoreSchemaGate.openCurrentStore(
                    at: url, schemaSQL: schema, policy: .conservative, verifyVersion: { _ in true },
                    stampVersion: { _ in true }))
            execute(first, "INSERT INTO marker VALUES(7); ANALYZE;")
            let before = try rows(first, "sqlite_stat1")
            XCTAssertFalse(before.isEmpty)
            sqlite3_close(first)
            for strict in [false, true] {
                let handle = try XCTUnwrap(
                    SQLiteStoreSchemaGate.openCurrentStore(
                        at: url, schemaSQL: schema, policy: .conservative, strictEmptySchema: strict,
                        verifyVersion: { _ in true },
                        stampVersion: { _ in
                            XCTFail("an accepted schema must not be initialized again")
                            return false
                        }))
                XCTAssertEqual(try text(handle, "SELECT value FROM marker;"), "7")
                XCTAssertEqual(try rows(handle, "sqlite_stat1"), before)
                sqlite3_close(handle)
            }
        }

        private final class InventoryReadFault {
            var reading = false
            var interrupted = false
            let database: OpaquePointer
            init(_ database: OpaquePointer) { self.database = database }
        }

        func testInventoryReadFailuresNeverAdmitAnUnknownSchema() throws {
            for step in [false, true] {
                let url = try fixture("v1.0.5")
                try withDatabase(url) { db in
                    let fault = InventoryReadFault(db)
                    let context = Unmanaged.passRetained(fault)
                    defer {
                        sqlite3_set_authorizer(db, nil, nil)
                        sqlite3_progress_handler(db, 0, nil, nil)
                        sqlite3_trace_v2(db, 0, nil, nil)
                        context.release()
                    }
                    if step {
                        sqlite3_trace_v2(
                            db, UInt32(SQLITE_TRACE_STMT),
                            { _, context, statement, _ in
                                guard let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                                Unmanaged<InventoryReadFault>.fromOpaque(context!).takeUnretainedValue().reading =
                                    String(cString: sql).hasPrefix("SELECT COUNT(*) =")
                                return 0
                            }, context.toOpaque())
                        sqlite3_progress_handler(
                            db, 1,
                            { context in
                                let fault = Unmanaged<InventoryReadFault>.fromOpaque(context!).takeUnretainedValue()
                                guard fault.reading, !fault.interrupted else { return 0 }
                                fault.interrupted = true
                                sqlite3_progress_handler(fault.database, 0, nil, nil)
                                return 1
                            }, context.toOpaque())
                    } else {
                        sqlite3_set_authorizer(
                            db, { _, action, _, _, _, _ in action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK }, nil)
                    }
                    XCTAssertFalse(PendingBackupManifestStore.hasSupportedObjectInventory(db, version: 1))
                    if step { XCTAssertTrue(fault.interrupted) }
                    sqlite3_set_authorizer(db, nil, nil)
                    sqlite3_trace_v2(db, 0, nil, nil)
                    sqlite3_progress_handler(db, 0, nil, nil)
                    XCTAssertTrue(PendingBackupManifestStore.hasSupportedObjectInventory(db, version: 1))
                }
            }
        }

        private final class MigrationRefusal {
            let point: String
            var versionWrites = 0
            init(_ point: String) { self.point = point }
        }

        func testARefusedMigrationRollsBackTheTableAndVersionTogether() throws {
            for refused in ["create", "ignored-create", "version", "commit"] {
                let url = try fixture("v1.0.5")
                let before = try legacyRows(url)
                try withDatabase(url) { db in
                    let fault = MigrationRefusal(refused)
                    let context = Unmanaged.passRetained(fault)
                    defer {
                        sqlite3_set_authorizer(db, nil, nil)
                        context.release()
                    }
                    sqlite3_set_authorizer(
                        db,
                        { context, action, name, _, _, _ in
                            let fault = Unmanaged<MigrationRefusal>.fromOpaque(context!).takeUnretainedValue()
                            let refused = fault.point
                            let value = name.map { String(cString: $0) }
                            if action == SQLITE_INSERT, value == "pending_info" { fault.versionWrites += 1 }
                            if refused == "create", action == SQLITE_CREATE_TABLE, value == "remote_operation" {
                                return SQLITE_DENY
                            }
                            if refused == "ignored-create", action == SQLITE_CREATE_TABLE, value == "remote_operation" {
                                return SQLITE_IGNORE
                            }
                            if refused == "version", action == SQLITE_INSERT, value == "pending_info" {
                                return SQLITE_DENY
                            }
                            if refused == "commit", action == SQLITE_TRANSACTION, value == "COMMIT" {
                                return SQLITE_DENY
                            }
                            return SQLITE_OK
                        }, context.toOpaque())

                    XCTAssertFalse(PendingBackupManifestStore.migrateLegacyStore(db), refused)
                    if refused == "create" { XCTAssertEqual(fault.versionWrites, 0) }

                    sqlite3_set_authorizer(db, nil, nil)
                    XCTAssertNotEqual(sqlite3_get_autocommit(db), 0, refused)
                    XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), "1", refused)
                    XCTAssertEqual(
                        try text(db, "SELECT count(*) FROM sqlite_schema WHERE name='remote_operation';"), "0", refused)
                }
                XCTAssertEqual(try legacyRows(url), before)
                let reopened = try XCTUnwrap(PendingBackupManifestStore(url: url))
                reopened.close()
            }
        }

        func testTheLockedMigrationRecheckRefusesChangedVersionsAndSchemas() throws {
            for sql in [
                "UPDATE pending_info SET value=42;", "CREATE TABLE future(value);",
                "ALTER TABLE source_state ADD COLUMN future TEXT;",
            ] {
                let url = try fixture("v1.1.0")
                try withDatabase(url) { db in
                    execute(db, sql)
                    let before = try text(db, "SELECT value FROM pending_info WHERE key='schema';")
                    let writes = NSMutableArray()
                    let context = Unmanaged.passRetained(writes)
                    defer {
                        sqlite3_set_authorizer(db, nil, nil)
                        context.release()
                    }
                    sqlite3_set_authorizer(
                        db,
                        { context, action, _, _, _, _ in
                            if action == SQLITE_CREATE_TABLE || action == SQLITE_INSERT {
                                Unmanaged<NSMutableArray>.fromOpaque(context!).takeUnretainedValue().add(action)
                            }
                            return SQLITE_OK
                        }, context.toOpaque())
                    XCTAssertFalse(PendingBackupManifestStore.migrateLegacyStore(db))
                    XCTAssertEqual(writes.count, 0, "an unsupported file must receive no migration writes")
                    sqlite3_set_authorizer(db, nil, nil)
                    XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), before)
                    XCTAssertEqual(
                        try text(db, "SELECT count(*) FROM sqlite_schema WHERE name='remote_operation';"), "0")
                }
            }
        }

        func testAFailedMigrationCannotExposeALegacyHandleAsTheCurrentStore() throws {
            let url = try fixture("v1.0.5")
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            let handle = try XCTUnwrap(db)
            sqlite3_set_authorizer(
                handle,
                { _, action, name, _, _, _ in
                    action == SQLITE_INSERT && name.map { String(cString: $0) } == "pending_info"
                        ? SQLITE_DENY : SQLITE_OK
                }, nil)

            let opened = PendingBackupManifestStore.openMigratedLegacyStore(handle)

            XCTAssertNil(opened)
            if let opened { sqlite3_close(opened) }
            try withDatabase(url) { db in
                XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), "1")
                XCTAssertEqual(try text(db, "SELECT count(*) FROM sqlite_schema WHERE name='remote_operation';"), "0")
            }
        }

        func testMigrationRefusesAnOpenTransactionAndARefusedDurabilitySetting() throws {
            for fault in ["open", "durability", "begin"] {
                let url = try fixture("v1.0.5")
                try withDatabase(url) { db in
                    if fault == "open" { execute(db, "BEGIN IMMEDIATE;") }
                    let context = Unmanaged.passRetained(fault as NSString)
                    defer {
                        sqlite3_set_authorizer(db, nil, nil)
                        if sqlite3_get_autocommit(db) == 0 { execute(db, "ROLLBACK;") }
                        context.release()
                    }
                    sqlite3_set_authorizer(
                        db,
                        { context, action, name, _, _, _ in
                            let fault = Unmanaged<NSString>.fromOpaque(context!).takeUnretainedValue() as String
                            let value = name.map { String(cString: $0) }
                            if fault == "durability", action == SQLITE_PRAGMA, value == "synchronous" {
                                return SQLITE_DENY
                            }
                            if fault == "begin", action == SQLITE_TRANSACTION, value == "BEGIN" { return SQLITE_DENY }
                            return SQLITE_OK
                        }, context.toOpaque())
                    XCTAssertFalse(PendingBackupManifestStore.migrateLegacyStore(db), fault)
                    sqlite3_set_authorizer(db, nil, nil)
                    XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), "1")
                    XCTAssertEqual(
                        try text(db, "SELECT count(*) FROM sqlite_schema WHERE name='remote_operation';"), "0")
                }
            }
        }

        /// Runs only in the subprocess selected by the crash test below.
        func testMigrationCrashChild() throws {
            guard let path = ProcessInfo.processInfo.environment["PENDING_MIGRATION_CRASH_PATH"],
                let point = ProcessInfo.processInfo.environment["PENDING_MIGRATION_CRASH_POINT"]
            else { return }
            try withDatabase(URL(fileURLWithPath: path)) { db in
                let context = Unmanaged.passRetained(point as NSString)
                defer {
                    sqlite3_trace_v2(db, 0, nil, nil)
                    context.release()
                }
                sqlite3_trace_v2(
                    db, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE),
                    { event, context, statement, _ in
                        let point = Unmanaged<NSString>.fromOpaque(context!).takeUnretainedValue() as String
                        guard let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                        let text = String(cString: sql)
                        if point == "before-version", event == UInt32(SQLITE_TRACE_STMT),
                            text.hasPrefix("INSERT INTO pending_info")
                        {
                            kill(getpid(), SIGKILL)
                        }
                        if point == "after-commit", event == UInt32(SQLITE_TRACE_PROFILE), text == "COMMIT;" {
                            kill(getpid(), SIGKILL)
                        }
                        return 0
                    }, context.toOpaque())
                _ = PendingBackupManifestStore.migrateLegacyStore(db)
                XCTFail("the child did not reach its production migration crash point")
            }
        }

        func testACrashBetweenTableAndVersionLeavesUsableV1AndACommittedMigrationLeavesCompleteV2() throws {
            for point in ["before-version", "after-commit"] {
                let url = try fixture("v1.1.0")
                let before = try legacyRows(url)
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                child.arguments = [
                    "xctest", "-XCTest", "UpgradeFixtureTests.PendingStoreMigrationTests/testMigrationCrashChild",
                    Bundle(for: Self.self).bundlePath,
                ]
                child.environment = ProcessInfo.processInfo.environment.merging([
                    "PENDING_MIGRATION_CRASH_PATH": url.path, "PENDING_MIGRATION_CRASH_POINT": point,
                ]) { _, new in new }
                let done = DispatchSemaphore(value: 0)
                child.terminationHandler = { _ in done.signal() }
                try child.run()
                guard done.wait(timeout: .now() + 20) == .success else {
                    child.terminate()
                    XCTFail("migration child did not finish")
                    return
                }
                XCTAssertEqual(child.terminationReason, .uncaughtSignal)
                XCTAssertEqual(child.terminationStatus, SIGKILL)

                try withDatabase(url, readOnly: true) { db in
                    let version = point == "before-version" ? "1" : "2"
                    XCTAssertEqual(try text(db, "SELECT value FROM pending_info WHERE key='schema';"), version)
                    XCTAssertEqual(
                        try text(db, "SELECT count(*) FROM sqlite_schema WHERE name='remote_operation';"),
                        version == "1" ? "0" : "1")
                }
                XCTAssertEqual(try legacyRows(url), before)
                let reopened = try XCTUnwrap(PendingBackupManifestStore(url: url))
                XCTAssertTrue(reopened.isOperational())
                XCTAssertEqual(
                    reopened.sourceState(for: PendingSourceKey(kind: .photoLibraryAsset, identifier: "released-asset"))?
                        .remoteOperation, .remoteTrash)
                reopened.close()
            }
        }
    }
#endif
