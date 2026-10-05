import CryptoKit
import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Streaming SHA-1 + persistent identity manifest: the semantics-free half of the dedupe pipeline.
final class UploadIdentityManifestTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String, _ data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func scalarInteger(at url: URL, sql: String) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle
        else {
            sqlite3_close(handle)
            throw NSError(domain: "UploadIdentityManifestTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            sqlite3_finalize(statement)
            throw NSError(domain: "UploadIdentityManifestTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "UploadIdentityManifestTests", code: 3)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testAnUpsertThatCarriesAReadLinkKeepsALinkThatChangedSinceTheRead() throws {
        let store = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        func row(
            _ identifier: String, link: String?, outcome: UploadIdentityManifestStore.Outcome?, size: Int64
        )
            -> UploadIdentityRecord
        {
            UploadIdentityRecord(
                source: .file(URL(fileURLWithPath: "/photos/\(identifier)")), filename: identifier,
                correctedName: identifier, fileSize: size, modificationDate: Date(timeIntervalSince1970: 1),
                sha1Hex: "sha1", nameHash: "nh", contentHash: "ch", hashKeyEpoch: "epoch",
                remoteVolumeID: link == nil ? nil : "vol", remoteLinkID: link, outcome: outcome?.rawValue,
                updatedAt: Date(timeIntervalSince1970: 2))
        }
        XCTAssertTrue(store.upsert(row("moved", link: "kept", outcome: .duplicateActive, size: 1)))
        XCTAssertTrue(store.upsert(row("same", link: "read", outcome: .uploaded, size: 1)))
        XCTAssertTrue(store.upsert(row("empty", link: nil, outcome: nil, size: 1)))

        XCTAssertTrue(
            store.upsert(
                row("moved", link: "read", outcome: .duplicateTrashed, size: 2), keepingRemoteLinkChangedFrom: "read"))
        XCTAssertTrue(
            store.upsert(
                row("same", link: "read", outcome: .duplicateTrashed, size: 2), keepingRemoteLinkChangedFrom: "read"))
        XCTAssertTrue(
            store.upsert(row("empty", link: "new", outcome: .uploaded, size: 2), keepingRemoteLinkChangedFrom: nil))
        XCTAssertTrue(
            store.upsert(row("fresh", link: "read", outcome: .uploaded, size: 2), keepingRemoteLinkChangedFrom: "read"))

        XCTAssertEqual(
            store.record(for: .file(URL(fileURLWithPath: "/photos/moved"))),
            row("moved", link: "kept", outcome: .duplicateActive, size: 2),
            "the moved link and its outcome stay; the other columns update")
        XCTAssertEqual(
            store.record(for: .file(URL(fileURLWithPath: "/photos/same"))),
            row("same", link: "read", outcome: .duplicateTrashed, size: 2))
        XCTAssertEqual(
            store.record(for: .file(URL(fileURLWithPath: "/photos/empty"))),
            row("empty", link: "new", outcome: .uploaded, size: 2))
        XCTAssertEqual(
            store.record(for: .file(URL(fileURLWithPath: "/photos/fresh"))),
            row("fresh", link: "read", outcome: .uploaded, size: 2), "a new row is written as given")
    }

    func testSHA1MatchesKnownVector() throws {
        // FIPS 180 test vector: SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d.
        let url = try writeFile("abc.bin", Data("abc".utf8))
        XCTAssertEqual(try UploadContentSHA1.hexDigest(ofFileAt: url), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testSHA1OfEmptyFile() throws {
        let url = try writeFile("empty.bin", Data())
        XCTAssertEqual(try UploadContentSHA1.hexDigest(ofFileAt: url), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testSHA1StreamsLargeFileAcrossChunkBoundaries() throws {
        // 5 MiB of patterned bytes with a tiny 4 KiB buffer: exercises many chunk iterations and
        // non-aligned tails. Reference digest via CryptoKit's one-shot API.
        var data = Data(capacity: 5 * 1024 * 1024 + 3)
        var byte: UInt8 = 0
        for _ in 0..<(5 * 1024 * 1024 + 3) {
            data.append(byte)
            byte = byte &+ 7
        }
        let url = try writeFile("large.bin", data)
        let expected = UploadContentSHA1.hexString(digest: Data(Insecure.SHA1.hash(data: data)))
        XCTAssertEqual(try UploadContentSHA1.hexDigest(ofFileAt: url, bufferSize: 4096), expected)
    }

    func testSHA1MissingFileThrows() {
        let url = tempDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try UploadContentSHA1.hexDigest(ofFileAt: url))
    }

    func testSHA1HonoursTaskCancellationBetweenChunks() async throws {
        var data = Data(capacity: 2 * 1024 * 1024)
        for i in 0..<(2 * 1024 * 1024) { data.append(UInt8(truncatingIfNeeded: i)) }
        let url = try writeFile("cancel.bin", data)

        let task = Task {
            try UploadContentSHA1.digest(ofFileAt: url, bufferSize: 1024)
        }
        task.cancel()
        do {
            _ = try await task.value
            // A very fast machine may finish the first chunk check before the cancel lands - but a
            // pre-cancelled task must throw on the first checkCancellation, so reaching here means
            // cancellation was ignored.
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testAccumulatorMatchesOneShotDigest() {
        let chunks = [Data("proton".utf8), Data(" ".utf8), Data("photos".utf8)]
        let accumulator = UploadSHA1Accumulator()
        for chunk in chunks { accumulator.update(chunk) }
        let whole = chunks.reduce(Data(), +)
        let expected = UploadContentSHA1.hexString(digest: Data(Insecure.SHA1.hash(data: whole)))
        XCTAssertEqual(accumulator.finalizeHexDigest(), expected)
    }

    private func makeStore() throws -> UploadIdentityManifestStore {
        try XCTUnwrap(
            UploadIdentityManifestStore(
                url: tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
            ))
    }

    private func makeRecord(
        identifier: String = "/photos/IMG_0001.HEIC",
        filename: String = "IMG_0001.HEIC",
        size: Int64 = 1234,
        mtime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UploadIdentityRecord {
        UploadIdentityRecord(
            source: UploadSourceIdentity(kind: .fileURL, identifier: identifier),
            filename: filename,
            correctedName: filename,
            fileSize: size,
            modificationDate: mtime,
            sha1Hex: "a9993e364706816aba3e25717850c26c9cd0d89d",
            nameHash: "namehash-1",
            contentHash: "contenthash-1",
            hashKeyEpoch: "epoch-1",
            remoteVolumeID: nil,
            remoteLinkID: nil,
            outcome: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func remoteIssue(
        _ linkID: String,
        generation: String,
        observedAt: Date
    ) -> UploadRemoteContentIndexIssue {
        UploadRemoteContentIndexIssue(
            remoteLinkID: linkID,
            reason: .missingContentHash,
            firstObservedAt: observedAt,
            lastObservedAt: observedAt,
            lastRepairAttemptAt: nil,
            indexGeneration: generation
        )
    }

    func testSourcesOfARemoteLinkListOnlyTrustworthyRows() throws {
        let store = try makeStore()
        var uploaded = makeRecord(identifier: "asset-a")
        uploaded.remoteLinkID = "link-shared"
        uploaded.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(uploaded)
        var duplicate = makeRecord(identifier: "asset-b")
        duplicate.remoteLinkID = "link-shared"
        duplicate.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
        store.upsert(duplicate)
        var trashed = makeRecord(identifier: "asset-c")
        trashed.remoteLinkID = "link-shared"
        trashed.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        store.upsert(trashed)

        XCTAssertEqual(
            Set(store.sources(withRemoteLinkID: "link-shared")?.map(\.identifier) ?? []), ["asset-a", "asset-b"])
        XCTAssertEqual(store.sources(withRemoteLinkID: "link-unknown")?.count, 0)
    }

    func testV105ManifestRowsReopenWithBothOwnersOfASharedLink() throws {
        let store = try makeStore()
        var uploaded = makeRecord(identifier: "asset-a")
        uploaded.source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-a")
        uploaded.remoteVolumeID = "vol"
        uploaded.remoteLinkID = "shared"
        uploaded.outcome = "uploaded"
        var duplicate = uploaded
        duplicate.source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-b")
        duplicate.outcome = "duplicateActive"
        // v1.0.5 UploadDedupePipeline.swift:569-582 and 175-192 persist these receipt outcomes.
        XCTAssertTrue(store.upsert(uploaded))
        XCTAssertTrue(store.upsert(duplicate))
        store.close()

        let reopened = try makeStore()
        defer { reopened.close() }
        XCTAssertEqual(reopened.record(for: uploaded.source), uploaded)
        XCTAssertEqual(reopened.record(for: duplicate.source), duplicate)
        XCTAssertEqual(
            Set(try XCTUnwrap(reopened.sources(withRemoteLinkID: "shared"))), [uploaded.source, duplicate.source])
    }

    func testForgettingTrashedLinksKeepsTheHashesButNoLongerProvesABackup() throws {
        let store = try makeStore()
        var trashed = makeRecord(identifier: "asset-a")
        trashed.remoteVolumeID = "vol-1"
        trashed.remoteLinkID = "link-trashed"
        trashed.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(trashed)
        var active = makeRecord(identifier: "asset-b")
        active.remoteLinkID = "link-active"
        active.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(active)
        var adopted = makeRecord(identifier: "asset-c")
        adopted.remoteLinkID = "link-trashed"
        adopted.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
        store.upsert(adopted)

        XCTAssertTrue(store.forgetRemoteLinks(["link-trashed", ""], of: trashed.source))

        let forgotten = try XCTUnwrap(store.record(for: trashed.source))
        XCTAssertNil(forgotten.remoteVolumeID)
        XCTAssertNil(forgotten.remoteLinkID)
        XCTAssertNil(forgotten.outcome)
        XCTAssertEqual(forgotten.sha1Hex, trashed.sha1Hex, "the next check must not hash the file again")
        XCTAssertEqual(
            store.sources(withRemoteLinkID: "link-trashed")?.map(\.identifier), ["asset-c"],
            "another source may count a restored photo as its backup")
        XCTAssertEqual(store.record(for: active.source)?.remoteLinkID, "link-active")
    }

    func testTrustedContentLookupFiltersOutcomesAndSurvivesReopen() throws {
        var store = try makeStore()

        var uploaded = makeRecord(identifier: "/sync1/a.heic")
        uploaded.remoteVolumeID = "vol-1"
        uploaded.remoteLinkID = "link-1"
        uploaded.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(uploaded)

        var trashed = makeRecord(identifier: "/sync1/trashed.heic")
        trashed.contentHash = "contenthash-trashed"
        trashed.remoteLinkID = "link-t"
        trashed.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        store.upsert(trashed)

        var linkless = makeRecord(identifier: "/sync1/linkless.heic")
        linkless.contentHash = "contenthash-linkless"
        linkless.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(linkless)

        XCTAssertEqual(
            store.trustedRecord(contentHash: "contenthash-1", hashKeyEpoch: "epoch-1")?.remoteLinkID, "link-1")
        XCTAssertNil(
            store.trustedRecord(contentHash: "contenthash-1", hashKeyEpoch: "epoch-2"),
            "a different hash-key epoch must never match")
        XCTAssertNil(
            store.trustedRecord(contentHash: "contenthash-trashed", hashKeyEpoch: "epoch-1"),
            "trashed outcomes are not proof of backup")
        XCTAssertNil(
            store.trustedRecord(contentHash: "contenthash-linkless", hashKeyEpoch: "epoch-1"),
            "rows without a remote link are not trustworthy")

        // Reopen: the row and the additive index survive.
        store.close()
        store = try makeStore()
        XCTAssertEqual(
            store.trustedRecord(contentHash: "contenthash-1", hashKeyEpoch: "epoch-1")?.remoteLinkID, "link-1")

        var handle: OpaquePointer?
        let path = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName).path
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA index_list('upload_identity');", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var indexNames: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) { indexNames.append(String(cString: name)) }
        }
        XCTAssertTrue(
            indexNames.contains("upload_identity_content_idx"),
            "the content lookup must be index-backed, found: \(indexNames)")
    }

    func testUpsertAndFetchRoundTrip() throws {
        let store = try makeStore()
        let record = makeRecord()
        store.upsert(record)
        let fetched = store.record(for: record.source)
        XCTAssertEqual(fetched, record)
        XCTAssertEqual(store.count(), 1)
    }

    func testMissReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(store.record(for: UploadSourceIdentity(kind: .fileURL, identifier: "/nope")))
    }

    func testUpsertOverwritesExistingRow() throws {
        let store = try makeStore()
        var record = makeRecord()
        store.upsert(record)
        record.sha1Hex = "ffffffffffffffffffffffffffffffffffffffff"
        record.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        record.remoteVolumeID = "vol1"
        record.remoteLinkID = "link1"
        store.upsert(record)
        XCTAssertEqual(store.record(for: record.source), record)
        XCTAssertEqual(store.count(), 1)
    }

    func testPersistsAcrossReopen() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let record = makeRecord()
        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            store.upsert(record)
            store.close()
        }
        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(reopened.record(for: record.source), record)
    }

    func testNewerSchemaFailsClosedAndPreservesUploadState() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            store.upsert(makeRecord())
            store.close()
        }
        // Stamp a from-the-future schema version directly.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE manifest_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertNil(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(
            try scalarInteger(at: url, sql: "SELECT value FROM manifest_info WHERE key='schema';"),
            99
        )
        XCTAssertEqual(try scalarInteger(at: url, sql: "SELECT COUNT(*) FROM upload_identity;"), 1)
    }

    func testCurrentMarkerWithWrongShapeFailsClosedWithoutDeletingFile() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE legacy_identity(value TEXT); "
                    + "CREATE TABLE manifest_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL); "
                    + "INSERT INTO manifest_info(key, value) VALUES('schema', 8);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(
            try scalarInteger(
                at: url,
                sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name='legacy_identity';"
            ),
            1
        )
    }

    func testMarkerlessExactSchemaFailsClosedWithoutDeletingIdentityRows() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        do {
            let first = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            first.upsert(makeRecord())
            XCTAssertEqual(first.count(), 1)
            first.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "DELETE FROM manifest_info WHERE key='schema';", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(try scalarInteger(at: url, sql: "SELECT COUNT(*) FROM upload_identity;"), 1)
    }

    func testSchemaSevenFailsClosedWithoutMigrationOrDataLoss() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let record = makeRecord()
        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            store.upsert(record)
            store.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let downgrade = """
            DROP TABLE remote_content_build_checkpoint;
            CREATE TABLE remote_content_build_checkpoint(
              key_epoch TEXT PRIMARY KEY,
              event_id TEXT NOT NULL,
              source_fingerprint TEXT NOT NULL,
              cursor INTEGER NOT NULL,
              total INTEGER NOT NULL,
              updated_at REAL NOT NULL
            );
            UPDATE manifest_info SET value=7 WHERE key='schema';
            """
        XCTAssertEqual(sqlite3_exec(handle, downgrade, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertNil(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(
            try scalarInteger(at: url, sql: "SELECT value FROM manifest_info WHERE key='schema';"),
            7
        )
        XCTAssertEqual(try scalarInteger(at: url, sql: "SELECT COUNT(*) FROM upload_identity;"), 1)
    }

    func testRemoteContentIndexAndCheckpointSurviveReopen() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let checkpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-100",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let records = [
            UploadRemoteContentIndexRecord(
                contentHash: "content-a",
                hashKeyEpoch: "epoch-1",
                remoteLinkID: "link-a"
            ),
            UploadRemoteContentIndexRecord(
                contentHash: "content-b",
                hashKeyEpoch: "epoch-1",
                remoteLinkID: "link-b"
            ),
        ]

        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            XCTAssertTrue(
                store.replaceRemoteContentIndex(
                    records,
                    unresolvedIssues: [],
                    hashKeyEpoch: "epoch-1",
                    checkpoint: checkpoint
                ))
            store.close()
        }

        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(
            reopened.remoteContentRecord(contentHash: "content-a", hashKeyEpoch: "epoch-1"),
            records[0]
        )
        XCTAssertEqual(reopened.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch-1"), checkpoint)
        XCTAssertNil(reopened.remoteContentRecord(contentHash: "content-a", hashKeyEpoch: "epoch-2"))
        XCTAssertNil(reopened.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch-2"))
        XCTAssertEqual(reopened.remoteContentIndexHealth(hashKeyEpoch: "epoch-1").unresolvedCount, 0)
    }

    func testInterruptedRemoteContentBuildResumesAndPublishesAtomically() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let epoch = "epoch-resume"
        let identity = UploadBackupExternalIdentity(identifier: "cloud-1", revision: .init(rawValue: 42))

        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            let start = try XCTUnwrap(
                store.beginRemoteContentIndexBuild(
                    hashKeyEpoch: epoch, eventID: "event-1", sourceFingerprint: "source-a",
                    total: 2, updatedAt: Date(timeIntervalSince1970: 1)
                ))
            XCTAssertEqual(start.cursor, 0)
            XCTAssertTrue(
                store.appendRemoteContentIndexBuild(
                    records: [.init(contentHash: "hash-1", hashKeyEpoch: epoch, remoteLinkID: "link-1")],
                    unresolvedIssues: [],
                    externalIdentities: [.init(remoteLinkID: "link-1", externalIdentity: identity)],
                    hashKeyEpoch: epoch,
                    buildID: start.buildID,
                    nextCursor: 1,
                    updatedAt: Date(timeIntervalSince1970: 2)
                ))
            XCTAssertNil(
                store.remoteContentRecord(contentHash: "hash-1", hashKeyEpoch: epoch),
                "partial staging must never become live proof")
            store.close()
        }

        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        let resumed = try XCTUnwrap(
            reopened.beginRemoteContentIndexBuild(
                hashKeyEpoch: epoch, eventID: "event-1", sourceFingerprint: "source-a",
                total: 2, updatedAt: Date(timeIntervalSince1970: 3)
            ))
        XCTAssertEqual(resumed.cursor, 1)
        XCTAssertTrue(
            reopened.appendRemoteContentIndexBuild(
                records: [.init(contentHash: "hash-2", hashKeyEpoch: epoch, remoteLinkID: "link-2")],
                unresolvedIssues: [
                    remoteIssue("link-2", generation: "event-1", observedAt: Date(timeIntervalSince1970: 4))
                ],
                externalIdentities: [],
                hashKeyEpoch: epoch,
                buildID: resumed.buildID,
                nextCursor: 2,
                updatedAt: Date(timeIntervalSince1970: 4)
            ))
        XCTAssertEqual(
            reopened.stagedRemoteExternalIdentities(hashKeyEpoch: epoch, buildID: resumed.buildID)["link-1"],
            identity
        )
        XCTAssertTrue(
            reopened.finishRemoteContentIndexBuild(
                remoteAssetRecords: [],
                hashKeyEpoch: epoch,
                buildID: resumed.buildID,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date(timeIntervalSince1970: 5))
            ))
        XCTAssertNotNil(reopened.remoteContentRecord(contentHash: "hash-1", hashKeyEpoch: epoch))
        XCTAssertNotNil(reopened.remoteContentRecord(contentHash: "hash-2", hashKeyEpoch: epoch))
        XCTAssertGreaterThan(reopened.remoteContentIndexHealth(hashKeyEpoch: epoch).unresolvedCount, 0)
        XCTAssertNil(reopened.remoteContentIndexBuildCheckpoint(hashKeyEpoch: epoch))
    }

    func testChangedRemoteBuildFrontierDiscardsPartialStaging() throws {
        let store = try makeStore()
        let epoch = "epoch-reset"
        let first = try XCTUnwrap(
            store.beginRemoteContentIndexBuild(
                hashKeyEpoch: epoch, eventID: "event-1", sourceFingerprint: "source-a",
                total: 10, updatedAt: Date()
            ))
        XCTAssertTrue(
            store.appendRemoteContentIndexBuild(
                records: [.init(contentHash: "old", hashKeyEpoch: epoch, remoteLinkID: "old-link")],
                unresolvedIssues: [], externalIdentities: [], hashKeyEpoch: epoch,
                buildID: first.buildID,
                nextCursor: 5, updatedAt: Date()
            ))
        let restarted = store.beginRemoteContentIndexBuild(
            hashKeyEpoch: epoch, eventID: "event-2", sourceFingerprint: "source-b",
            total: 3, updatedAt: Date()
        )
        XCTAssertEqual(restarted?.eventID, "event-2")
        XCTAssertEqual(restarted?.cursor, 0)
        XCTAssertTrue(
            store.stagedRemoteExternalIdentities(
                hashKeyEpoch: epoch,
                buildID: try XCTUnwrap(restarted).buildID
            ).isEmpty)
    }

    func testChangedRemoteBuildSourceAtSameEventAndCountRestartsSafely() throws {
        let store = try makeStore()
        let epoch = "epoch-source-reset"
        let first = try XCTUnwrap(
            store.beginRemoteContentIndexBuild(
                hashKeyEpoch: epoch, eventID: "event-1", sourceFingerprint: "source-a",
                total: 10, updatedAt: Date()
            ))
        XCTAssertTrue(
            store.appendRemoteContentIndexBuild(
                records: [.init(contentHash: "old", hashKeyEpoch: epoch, remoteLinkID: "old-link")],
                unresolvedIssues: [], externalIdentities: [], hashKeyEpoch: epoch,
                buildID: first.buildID,
                nextCursor: 5, updatedAt: Date()
            ))

        let restarted = store.beginRemoteContentIndexBuild(
            hashKeyEpoch: epoch, eventID: "event-1", sourceFingerprint: "source-b",
            total: 10, updatedAt: Date()
        )

        XCTAssertEqual(restarted?.sourceFingerprint, "source-b")
        XCTAssertEqual(restarted?.cursor, 0)
    }

    func testInvalidatedRemoteBuildCannotAppendOrPublishAfterReplacementStarts() throws {
        let store = try makeStore()
        let epoch = "epoch-fence"
        let first = try XCTUnwrap(
            store.beginRemoteContentIndexBuild(
                hashKeyEpoch: epoch,
                eventID: "event-old",
                sourceFingerprint: "source-old",
                total: 2,
                updatedAt: Date(timeIntervalSince1970: 1)
            ))
        XCTAssertTrue(
            store.appendRemoteContentIndexBuild(
                records: [.init(contentHash: "old-1", hashKeyEpoch: epoch, remoteLinkID: "old-link-1")],
                unresolvedIssues: [],
                externalIdentities: [],
                hashKeyEpoch: epoch,
                buildID: first.buildID,
                nextCursor: 1,
                updatedAt: Date(timeIntervalSince1970: 2)
            ))

        XCTAssertTrue(store.invalidateRemoteContentIndexBuild(hashKeyEpoch: epoch))
        let replacement = try XCTUnwrap(
            store.beginRemoteContentIndexBuild(
                hashKeyEpoch: epoch,
                eventID: "event-new",
                sourceFingerprint: "source-new",
                total: 2,
                updatedAt: Date(timeIntervalSince1970: 3)
            ))
        XCTAssertNotEqual(first.buildID, replacement.buildID)
        XCTAssertFalse(
            store.appendRemoteContentIndexBuild(
                records: [.init(contentHash: "old-2", hashKeyEpoch: epoch, remoteLinkID: "old-link-2")],
                unresolvedIssues: [],
                externalIdentities: [],
                hashKeyEpoch: epoch,
                buildID: first.buildID,
                nextCursor: 2,
                updatedAt: Date(timeIntervalSince1970: 4)
            ))
        XCTAssertFalse(
            store.finishRemoteContentIndexBuild(
                remoteAssetRecords: [],
                hashKeyEpoch: epoch,
                buildID: first.buildID,
                checkpoint: .init(eventID: "event-old", refreshedAt: Date(timeIntervalSince1970: 4))
            ))

        XCTAssertTrue(
            store.appendRemoteContentIndexBuild(
                records: [
                    .init(contentHash: "new-1", hashKeyEpoch: epoch, remoteLinkID: "new-link-1"),
                    .init(contentHash: "new-2", hashKeyEpoch: epoch, remoteLinkID: "new-link-2"),
                ],
                unresolvedIssues: [],
                externalIdentities: [],
                hashKeyEpoch: epoch,
                buildID: replacement.buildID,
                nextCursor: 2,
                updatedAt: Date(timeIntervalSince1970: 5)
            ))
        XCTAssertTrue(
            store.finishRemoteContentIndexBuild(
                remoteAssetRecords: [],
                hashKeyEpoch: epoch,
                buildID: replacement.buildID,
                checkpoint: .init(eventID: "event-new", refreshedAt: Date(timeIntervalSince1970: 6))
            ))
        XCTAssertNil(store.remoteContentRecord(contentHash: "old-1", hashKeyEpoch: epoch))
        XCTAssertNil(store.remoteContentRecord(contentHash: "old-2", hashKeyEpoch: epoch))
        XCTAssertNotNil(store.remoteContentRecord(contentHash: "new-1", hashKeyEpoch: epoch))
        XCTAssertNotNil(store.remoteContentRecord(contentHash: "new-2", hashKeyEpoch: epoch))
        XCTAssertEqual(store.remoteContentIndexCheckpoint(hashKeyEpoch: epoch)?.eventID, "event-new")
    }

    func testLiveRemoteMutationInvalidatesStagedFullBuild() throws {
        let store = try makeStore()
        let epoch = "epoch-live-fence"
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [],
                unresolvedIssues: [],
                hashKeyEpoch: epoch,
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())
            ))
        let build = try XCTUnwrap(
            store.beginRemoteContentIndexBuild(
                hashKeyEpoch: epoch,
                eventID: "event-1",
                sourceFingerprint: "source-1",
                total: 1,
                updatedAt: Date()
            ))
        let uploaded = UploadRemoteContentIndexRecord(
            contentHash: "local-upload",
            hashKeyEpoch: epoch,
            remoteLinkID: "local-link"
        )

        XCTAssertTrue(store.upsertRemoteContentRecord(uploaded))
        XCTAssertNil(store.remoteContentIndexBuildCheckpoint(hashKeyEpoch: epoch))
        XCTAssertFalse(
            store.appendRemoteContentIndexBuild(
                records: [.init(contentHash: "stale", hashKeyEpoch: epoch, remoteLinkID: "stale-link")],
                unresolvedIssues: [],
                externalIdentities: [],
                hashKeyEpoch: epoch,
                buildID: build.buildID,
                nextCursor: 1,
                updatedAt: Date()
            ))
        XCTAssertEqual(store.remoteContentRecord(contentHash: "local-upload", hashKeyEpoch: epoch), uploaded)
    }

    func testRemoteAssetProofSurvivesReopenAndRelatedEventInvalidatesWholeCompound() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let identity = UploadBackupExternalIdentity(
            identifier: "icloud-asset",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        let proof = UploadRemoteAssetIndexRecord(
            externalIdentity: identity,
            resourceCount: 2,
            remoteLinkIDs: ["primary", "paired"],
            hashKeyEpoch: "epoch-1"
        )
        let checkpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-100",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            XCTAssertTrue(
                store.replaceRemoteContentIndex(
                    [],
                    remoteAssetRecords: [proof],
                    unresolvedIssues: [],
                    hashKeyEpoch: "epoch-1",
                    checkpoint: checkpoint
                ))
            store.close()
        }

        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        XCTAssertTrue(reopened.hasRemoteAssetIndexCheckpoint(hashKeyEpoch: "epoch-1"))
        XCTAssertEqual(
            reopened.remoteAssetRecords(for: [identity], hashKeyEpoch: "epoch-1")[identity],
            proof
        )

        XCTAssertTrue(
            reopened.applyRemoteContentIndexChanges(
                upserting: [],
                upsertingRemoteAssetRecords: [],
                unresolvedIssues: [],
                removingRemoteLinkIDs: ["paired"],
                hashKeyEpoch: "epoch-1",
                expectedEventID: "event-100",
                checkpoint: UploadRemoteContentIndexCheckpoint(
                    eventID: "event-101",
                    refreshedAt: Date(timeIntervalSince1970: 1_700_000_200)
                )
            ))
        XCTAssertNil(reopened.remoteAssetRecords(for: [identity], hashKeyEpoch: "epoch-1")[identity])
    }

    func testMalformedRemoteAssetProofRollsBackWithCheckpoint() throws {
        let store = try makeStore()
        let identity = UploadBackupExternalIdentity(
            identifier: "icloud-asset",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let malformed = UploadRemoteAssetIndexRecord(
            externalIdentity: identity,
            resourceCount: 2,
            remoteLinkIDs: ["only-one-link"],
            hashKeyEpoch: "epoch-1"
        )
        XCTAssertFalse(
            store.replaceRemoteContentIndex(
                [],
                remoteAssetRecords: [malformed],
                unresolvedIssues: [],
                hashKeyEpoch: "epoch-1",
                checkpoint: UploadRemoteContentIndexCheckpoint(
                    eventID: "event-bad",
                    refreshedAt: Date()
                )
            ))
        XCTAssertFalse(store.hasRemoteAssetIndexCheckpoint(hashKeyEpoch: "epoch-1"))
        XCTAssertTrue(store.remoteAssetRecords(for: [identity], hashKeyEpoch: "epoch-1").isEmpty)
    }

    func testRemoteContentDeltaRemovesOnlyChangedLinkAndAdvancesCheckpoint() throws {
        let store = try makeStore()
        let initialCheckpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-100",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [
                    UploadRemoteContentIndexRecord(
                        contentHash: "shared-content",
                        hashKeyEpoch: "epoch-1",
                        remoteLinkID: "link-a"
                    ),
                    UploadRemoteContentIndexRecord(
                        contentHash: "shared-content",
                        hashKeyEpoch: "epoch-1",
                        remoteLinkID: "link-b"
                    ),
                ],
                unresolvedIssues: [],
                hashKeyEpoch: "epoch-1",
                checkpoint: initialCheckpoint
            ))

        let nextCheckpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-101",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let replacement = UploadRemoteContentIndexRecord(
            contentHash: "replacement-content",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "link-a"
        )
        XCTAssertTrue(
            store.applyRemoteContentIndexChanges(
                upserting: [replacement],
                unresolvedIssues: [],
                removingRemoteLinkIDs: ["link-a"],
                hashKeyEpoch: "epoch-1",
                expectedEventID: "event-100",
                checkpoint: nextCheckpoint
            ))

        XCTAssertEqual(
            store.remoteContentRecord(contentHash: "shared-content", hashKeyEpoch: "epoch-1")?.remoteLinkID,
            "link-b",
            "removing one remote link must preserve another valid copy of the same bytes"
        )
        XCTAssertEqual(
            store.remoteContentRecord(contentHash: "replacement-content", hashKeyEpoch: "epoch-1"),
            replacement
        )
        XCTAssertEqual(store.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch-1"), nextCheckpoint)
    }

    func testRemoteContentDeltaRejectsStalePredecessor() throws {
        let store = try makeStore()
        let current = UploadRemoteContentIndexCheckpoint(eventID: "event-100", refreshedAt: Date())
        let original = UploadRemoteContentIndexRecord(
            contentHash: "original",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "link-1"
        )
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [original],
                unresolvedIssues: [],
                hashKeyEpoch: "epoch-1",
                checkpoint: current
            ))

        XCTAssertFalse(
            store.applyRemoteContentIndexChanges(
                upserting: [.init(contentHash: "stale", hashKeyEpoch: "epoch-1", remoteLinkID: "link-2")],
                unresolvedIssues: [],
                removingRemoteLinkIDs: ["link-1"],
                hashKeyEpoch: "epoch-1",
                expectedEventID: "event-99",
                checkpoint: .init(eventID: "event-101", refreshedAt: Date())
            ))
        XCTAssertEqual(store.remoteContentRecord(contentHash: "original", hashKeyEpoch: "epoch-1"), original)
        XCTAssertNil(store.remoteContentRecord(contentHash: "stale", hashKeyEpoch: "epoch-1"))
        let persisted = try XCTUnwrap(store.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch-1"))
        XCTAssertEqual(persisted.eventID, current.eventID)
        XCTAssertEqual(
            persisted.refreshedAt.timeIntervalSince1970,
            current.refreshedAt.timeIntervalSince1970,
            accuracy: 0.000_001)
    }

    func testInvalidRemoteContentDeltaRollsBackRowsAndCheckpoint() throws {
        let store = try makeStore()
        let initial = UploadRemoteContentIndexRecord(
            contentHash: "content-a",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "link-a"
        )
        let initialCheckpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-100",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [initial],
                unresolvedIssues: [],
                hashKeyEpoch: "epoch-1",
                checkpoint: initialCheckpoint
            ))

        let validPrefix = UploadRemoteContentIndexRecord(
            contentHash: "content-b",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "link-b"
        )
        let invalidTail = UploadRemoteContentIndexRecord(
            contentHash: "",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "link-c"
        )
        XCTAssertFalse(
            store.applyRemoteContentIndexChanges(
                upserting: [validPrefix, invalidTail],
                unresolvedIssues: [],
                removingRemoteLinkIDs: ["link-a"],
                hashKeyEpoch: "epoch-1",
                expectedEventID: "event-100",
                checkpoint: UploadRemoteContentIndexCheckpoint(
                    eventID: "event-101",
                    refreshedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            ))

        XCTAssertEqual(
            store.remoteContentRecord(contentHash: "content-a", hashKeyEpoch: "epoch-1"),
            initial
        )
        XCTAssertNil(store.remoteContentRecord(contentHash: "content-b", hashKeyEpoch: "epoch-1"))
        XCTAssertEqual(store.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch-1"), initialCheckpoint)
    }

    func testLocalRemoteContentUpsertDoesNotMoveServerCheckpoint() throws {
        let store = try makeStore()
        let checkpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-100",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [],
                unresolvedIssues: [],
                hashKeyEpoch: "epoch-1",
                checkpoint: checkpoint
            ))

        let uploaded = UploadRemoteContentIndexRecord(
            contentHash: "new-upload",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "link-new"
        )
        XCTAssertTrue(store.upsertRemoteContentRecord(uploaded))
        XCTAssertEqual(
            store.remoteContentRecord(contentHash: "new-upload", hashKeyEpoch: "epoch-1"),
            uploaded
        )
        XCTAssertEqual(
            store.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch-1"),
            checkpoint,
            "a local upload is not proof that every remote event has been consumed"
        )
    }

    func testUnresolvedRemoteLinksPersistAndDeltaCanResolveThem() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let firstCheckpoint = UploadRemoteContentIndexCheckpoint(
            eventID: "event-100",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            XCTAssertTrue(
                store.replaceRemoteContentIndex(
                    [],
                    unresolvedIssues: [
                        remoteIssue("unresolved-link", generation: "event-100", observedAt: firstCheckpoint.refreshedAt)
                    ],
                    hashKeyEpoch: "epoch-1",
                    checkpoint: firstCheckpoint
                ))
            XCTAssertGreaterThan(store.remoteContentIndexHealth(hashKeyEpoch: "epoch-1").unresolvedCount, 0)
            store.close()
        }

        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        XCTAssertGreaterThan(reopened.remoteContentIndexHealth(hashKeyEpoch: "epoch-1").unresolvedCount, 0)
        let resolved = UploadRemoteContentIndexRecord(
            contentHash: "resolved-content",
            hashKeyEpoch: "epoch-1",
            remoteLinkID: "unresolved-link"
        )
        XCTAssertTrue(
            reopened.applyRemoteContentIndexChanges(
                upserting: [resolved],
                unresolvedIssues: [],
                removingRemoteLinkIDs: ["unresolved-link"],
                hashKeyEpoch: "epoch-1",
                expectedEventID: "event-100",
                checkpoint: UploadRemoteContentIndexCheckpoint(
                    eventID: "event-101",
                    refreshedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            ))
        XCTAssertEqual(reopened.remoteContentIndexHealth(hashKeyEpoch: "epoch-1").unresolvedCount, 0)
        XCTAssertEqual(
            reopened.remoteContentRecord(contentHash: "resolved-content", hashKeyEpoch: "epoch-1"),
            resolved
        )
    }

    func testTypedRemoteIssuePreservesFirstObservationAcrossFullRebuild() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_500)
        let initial = UploadRemoteContentIndexIssue(
            remoteLinkID: "remote-link",
            reason: .missingEncryptedAttributes,
            firstObservedAt: first,
            lastObservedAt: first,
            lastRepairAttemptAt: first,
            indexGeneration: "event-1"
        )
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [],
                unresolvedIssues: [initial],
                hashKeyEpoch: "epoch-1",
                checkpoint: .init(eventID: "event-1", refreshedAt: first)
            ))
        let build = try XCTUnwrap(
            store.beginRemoteContentIndexBuild(
                hashKeyEpoch: "epoch-1",
                eventID: "event-2",
                sourceFingerprint: "source-2",
                total: 1,
                updatedAt: later
            ))
        let observedAgain = UploadRemoteContentIndexIssue(
            remoteLinkID: "remote-link",
            reason: .decryptFailure,
            firstObservedAt: later,
            lastObservedAt: later,
            lastRepairAttemptAt: later,
            indexGeneration: "event-2"
        )
        XCTAssertTrue(
            store.appendRemoteContentIndexBuild(
                records: [],
                unresolvedIssues: [observedAgain],
                externalIdentities: [],
                hashKeyEpoch: "epoch-1",
                buildID: build.buildID,
                nextCursor: 1,
                updatedAt: later
            ))
        XCTAssertTrue(
            store.finishRemoteContentIndexBuild(
                remoteAssetRecords: [],
                hashKeyEpoch: "epoch-1",
                buildID: build.buildID,
                checkpoint: .init(eventID: "event-2", refreshedAt: later)
            ))
        store.close()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "SELECT reason,first_observed,last_observed,last_repair,generation "
                    + "FROM remote_content_unresolved WHERE key_epoch='epoch-1' AND remote_link='remote-link';",
                -1,
                &stmt,
                nil
            ), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "decryptFailure")
        XCTAssertEqual(sqlite3_column_double(stmt, 1), first.timeIntervalSince1970)
        XCTAssertEqual(sqlite3_column_double(stmt, 2), later.timeIntervalSince1970)
        XCTAssertEqual(sqlite3_column_double(stmt, 3), later.timeIntervalSince1970)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 4)), "event-2")
    }

    private func descriptor(
        identifier: String = "/photos/IMG_0001.HEIC",
        filename: String = "IMG_0001.HEIC",
        size: Int64 = 1234,
        mtime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: UploadSourceIdentity(kind: .fileURL, identifier: identifier),
            fileURL: URL(fileURLWithPath: identifier),
            filename: filename,
            fileSize: size,
            modificationDate: mtime
        )
    }

    func testRecordValidWhenNothingChanged() {
        XCTAssertTrue(makeRecord().isValid(for: descriptor()))
    }

    func testRecordInvalidWhenSizeChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(size: 1235)))
    }

    func testRecordInvalidWhenModificationDateChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(mtime: Date(timeIntervalSince1970: 1_700_000_001))))
    }

    func testRecordInvalidWhenFilenameChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(filename: "IMG_0002.HEIC")))
    }

    func testRecordInvalidWhenSourceIdentifierChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(identifier: "/photos/other.HEIC")))
    }
}
