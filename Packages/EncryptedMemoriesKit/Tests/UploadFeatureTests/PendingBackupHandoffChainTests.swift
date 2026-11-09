import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class PendingBackupHandoffChainTests: XCTestCase {
    // This store sequence does not establish that the production runner can generate both late handoffs.
    func testMiddleHandoffRemainsDueAfterOriginalAndLatestTrashComplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-handoff-chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        defer { store.close() }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "handoff-chain-asset")
        let original = PhotoUID(volumeID: "vol", nodeID: "upload-A")
        let middle = PhotoUID(volumeID: "vol", nodeID: "upload-B")
        let latest = PhotoUID(volumeID: "vol", nodeID: "upload-C")

        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: original)], at: date))
        let generation = try XCTUnwrap(excluded.first).generation
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: generation, at: date))
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [key])

        for (revision, remote) in [(Int64(2), middle), (Int64(3), latest)] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: key, revision: UploadBackupRevision(rawValue: revision), remote: remote,
                        kind: .uploaded, createdAt: date.addingTimeInterval(Double(revision)))),
                .excludedRemoteNeedsTrash)
        }
        let waiting = try XCTUnwrap(store.sourceStateRead(for: key).state)
        XCTAssertEqual(waiting.remote, original, "both handoffs must preserve A's outstanding trash")
        XCTAssertTrue(waiting.needsRemoteTrash)
        XCTAssertEqual(waiting.remoteOperation, .remoteTrash)
        XCTAssertEqual(
            Set(store.handoffs(forRemoteLinkIDs: [middle.nodeID, latest.nodeID]).map(\.remote)),
            [middle, latest], "B and C must both be durable before A completes")

        let originalCompletion = date.addingTimeInterval(4)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: generation, remoteLinkID: original.nodeID, at: originalCompletion))
        let next = try XCTUnwrap(store.sourceStateRead(for: key).state)
        XCTAssertEqual(next.remote, latest, "the latest-handoff resume selects C after A")
        XCTAssertTrue(next.needsRemoteTrash)
        XCTAssertFalse(next.remoteTrashed)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [next]), [key])

        let latestCompletion = date.addingTimeInterval(5)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: generation, remoteLinkID: latest.nodeID, at: latestCompletion))

        let remaining = store.dueSourceStatesRead(by: latestCompletion)
        XCTAssertTrue(remaining.complete, "a failed read cannot prove that no trash remains due")
        XCTAssertEqual(
            remaining.states.filter { $0.key == key && $0.needsRemoteTrash }.compactMap(\.remote),
            [middle], "B must still be scheduled after A and C complete; B has never completed trash")
    }
    func testALaterRevisionCommittedBeforeAnOlderTileDeleteRemainsOwed() throws {
        let fixture = try PersistentHandoffChain(deleted: false)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 4)), .recorded)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.latest, revision: 5)), .recorded)
        XCTAssertNotNil(
            fixture.store.exclude(
                [
                    PendingExclusionRequest(
                        key: fixture.key, presentation: nil, remote: fixture.original,
                        revision: UploadBackupRevision(rawValue: 4))
                ], at: fixture.date))
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.latest, "the later commit follows the hidden earlier upload")
        XCTAssertTrue(try XCTUnwrap(fixture.state).needsRemoteTrash)
        guard fixture.state?.remote == fixture.latest else { return }
        try fixture.complete(fixture.latest)
        XCTAssertEqual(fixture.state?.remote, fixture.middle, "the exact revision remains owed too")
        try fixture.complete(fixture.middle)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
    }

    func testAnEarlierHistoricalRevisionIsNotInheritedByARevisionDelete() throws {
        let fixture = try PersistentHandoffChain(deleted: false)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 3)), .recorded)
        XCTAssertNotNil(
            fixture.store.exclude(
                [
                    PendingExclusionRequest(
                        key: fixture.key, presentation: nil, remote: fixture.original,
                        revision: UploadBackupRevision(rawValue: 4))
                ], at: fixture.date))
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.original)
        XCTAssertFalse(
            try XCTUnwrap(fixture.state).needsRemoteTrash, "a prior historical revision gains no new trash authority")
    }

    func testAnUnreadableLaterCommitRefusesTheRevisionDeleteWithoutRetiringMetadata() throws {
        let fixture = try PersistentHandoffChain(deleted: false)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.latest, revision: 5)), .recorded)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "UPDATE handoff SET kind='future-kind' WHERE revision_us=5;", nil, nil, nil), SQLITE_OK
            )
        }
        let before = fixture.state
        let metadata = try fixture.metadataRows().map { $0.0 + "=" + $0.1 }
        XCTAssertNil(
            fixture.store.exclude(
                [
                    PendingExclusionRequest(
                        key: fixture.key, presentation: nil, remote: fixture.original,
                        revision: UploadBackupRevision(rawValue: 4))
                ], at: fixture.date))
        XCTAssertEqual(fixture.state, before)
        XCTAssertEqual(try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, metadata)
    }

    func testAnUnknownLatestReadDoesNotRefuseAKnownExactCommit() throws {
        let fixture = try PersistentHandoffChain(deleted: false)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 4)), .recorded)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.latest, revision: 5)), .recorded)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "UPDATE handoff SET kind='future-kind' WHERE revision_us=5;", nil, nil, nil), SQLITE_OK
            )
        }
        let states = fixture.store.exclude(
            [
                PendingExclusionRequest(
                    key: fixture.key, presentation: nil, remote: nil, revision: UploadBackupRevision(rawValue: 4),
                    remoteUnknown: true)
            ], at: fixture.date)
        XCTAssertNotNil(states, "the exact readable commit does not make the unknown latest lookup mandatory")
        guard let deleted = states?.first else { return }
        XCTAssertEqual(deleted.remote, fixture.middle)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "UPDATE handoff SET kind='uploaded' WHERE revision_us=5;", nil, nil, nil), SQLITE_OK)
        }
        try fixture.complete(fixture.middle)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
        XCTAssertTrue(try XCTUnwrap(fixture.state).needsRemoteTrash)
    }

    func testAnUnknownHandoffDeleteKeepsItsLatestRecoveryAfterEarlierProof() throws {
        let fixture = try PersistentHandoffChain(deleted: false)
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.latest, revision: 5)), .recorded)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "UPDATE handoff SET kind='future-kind' WHERE revision_us=5;", nil, nil, nil), SQLITE_OK
            )
        }
        let states = fixture.store.exclude(
            [
                PendingExclusionRequest(
                    key: fixture.key, presentation: nil, remote: nil, revision: UploadBackupRevision(rawValue: 4),
                    remoteUnknown: true)
            ], at: fixture.date)
        XCTAssertNotNil(states, "an unreadable handoff still permits storing the exclusion without a trash target")
        guard let deleted = states?.first else { return }
        XCTAssertNil(deleted.remote)
        XCTAssertFalse(deleted.needsRemoteTrash)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "UPDATE handoff SET kind='uploaded' WHERE revision_us=5;", nil, nil, nil), SQLITE_OK)
        }
        let proven = fixture.store.trashEarlierUpload(
            fixture.original, of: fixture.key, generation: deleted.generation, at: fixture.date)
        XCTAssertEqual(proven?.remote, fixture.original)
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
        XCTAssertTrue(try XCTUnwrap(fixture.state).needsRemoteTrash)
    }

    func testLegacySavedTrashWithTheSameLatestPhotoDoesNotRearmIt() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.complete(fixture.original)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "DELETE FROM pending_info WHERE key GLOB 'pending-trash:*';", nil, nil, nil), SQLITE_OK
            )
        }
        let before = fixture.state
        XCTAssertEqual(fixture.store.resumeLaterTrash(for: fixture.key, at: fixture.date), .unchanged)
        XCTAssertEqual(fixture.state, before)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
    }

    func testAnOlderGenerationMarkerDoesNotDisableLegacyLatestRecovery() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.latest, revision: 3)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "DELETE FROM pending_info WHERE key GLOB 'pending-trash:*' AND key NOT GLOB '*:generation'; UPDATE pending_info SET value=0 WHERE key GLOB 'pending-trash:*:generation';",
                    nil, nil, nil), SQLITE_OK)
        }
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
        XCTAssertTrue(try XCTUnwrap(fixture.state).needsRemoteTrash)
    }

    func testFutureMetadataWithoutASourceCannotBeRetiredByANewDelete() throws {
        let fixture = try PersistentHandoffChain(deleted: false)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(
                    db, "INSERT INTO pending_info VALUES('\(fixture.metadataPrefix)v1:generation',9);", nil, nil, nil),
                SQLITE_OK)
        }
        let before = try fixture.metadataRows().map { $0.0 + "=" + $0.1 }
        XCTAssertNil(
            fixture.store.exclude(
                [PendingExclusionRequest(key: fixture.key, presentation: nil, remote: fixture.original)],
                at: fixture.date))
        XCTAssertNil(fixture.state)
        XCTAssertEqual(try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, before)
    }

    func testCompletedDutiesSurviveReopenWithoutCyclingBackToEarlierPhotos() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        try fixture.record(fixture.latest, revision: 3)
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
        try fixture.reopen()
        try fixture.complete(fixture.latest)
        XCTAssertEqual(fixture.state?.remote, fixture.middle)
        guard fixture.state?.remote == fixture.middle else { return }
        try fixture.complete(fixture.middle)
        try fixture.reopen()
        XCTAssertEqual(fixture.store.resumeLaterTrash(for: fixture.key, at: fixture.date), .unchanged)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
        XCTAssertTrue(try XCTUnwrap(fixture.state).remoteTrashed)
    }

    func testAReplacedHandoffOfTheSameRevisionKeepsBothTrashDuties() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        try fixture.record(fixture.latest, revision: 2)
        XCTAssertTrue(fixture.store.handoffs(forRemoteLinkIDs: [fixture.middle.nodeID]).isEmpty)
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
        try fixture.complete(fixture.latest)
        XCTAssertEqual(fixture.state?.remote, fixture.middle, "the duty survives the replaced handoff row")
    }

    func testAReceiptReplayDoesNotRearmACompletedPhoto() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.latest, revision: 3)
        try fixture.complete(fixture.original)
        try fixture.complete(fixture.latest)
        let completed = try XCTUnwrap(fixture.state)
        try fixture.record(fixture.latest, revision: 3)
        XCTAssertEqual(fixture.state, completed, "replay must not repeat a finished remote effect")
    }

    func testNewDeleteRetiresOldDutiesAndDoesNotInventHistoricalWork() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        try fixture.record(fixture.latest, revision: 3)
        let newer = try XCTUnwrap(
            fixture.store.exclude(
                [
                    PendingExclusionRequest(key: fixture.key, presentation: nil, remote: fixture.original)
                ], at: fixture.date)?.first)
        XCTAssertEqual(newer.generation, fixture.generation + 1)
        XCTAssertTrue(try fixture.metadataRows().allSatisfy { $0.0.hasSuffix(":generation") })
        try fixture.complete(fixture.original)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
        XCTAssertEqual(fixture.state?.remote, fixture.original)
        try fixture.record(fixture.middle, revision: 2)
        XCTAssertTrue(try XCTUnwrap(fixture.state).needsRemoteTrash, "a fresh handoff can owe this generation")
    }

    func testRestoreRetiresThePriorDutiesBeforeAQueueCompletionCanRemoveTheSource() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        let included = try XCTUnwrap(fixture.store.include([fixture.key], at: fixture.date)?.first)
        XCTAssertEqual(included.desired, .included)
        XCTAssertTrue(try fixture.metadataRows().isEmpty)
        XCTAssertEqual(fixture.store.resumeLaterTrash(for: fixture.key, at: fixture.date), .unchanged)
    }

    func testLegacyStateKeepsItsLatestFallbackWithoutInventingOtherHistoricalDuties() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        try fixture.record(fixture.latest, revision: 3)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "DELETE FROM pending_info WHERE key GLOB 'pending-trash:*';", nil, nil, nil),
                SQLITE_OK)
        }
        try fixture.complete(fixture.original)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
        try fixture.complete(fixture.latest)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
        XCTAssertEqual(fixture.state?.remote, fixture.latest)
    }

    func testUnknownDutyMetadataRefusesWritesAndStaysByteForByteIntact() throws {
        for invalid in ["'future-format'", "1.5", "1000", "-1"] {
            let fixture = try PersistentHandoffChain()
            try fixture.record(fixture.middle, revision: 2)
            try fixture.raw { db in
                XCTAssertEqual(
                    sqlite3_exec(
                        db, "UPDATE pending_info SET value=\(invalid) WHERE key GLOB 'pending-trash:*:owed';", nil,
                        nil, nil), SQLITE_OK)
            }
            let before = try fixture.metadataRows()
            let state = try XCTUnwrap(fixture.state)
            XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.latest, revision: 3)), .failed)
            XCTAssertNil(fixture.store.include([fixture.key], at: fixture.date))
            XCTAssertNil(
                fixture.store.exclude(
                    [PendingExclusionRequest(key: fixture.key, presentation: nil, remote: fixture.original)],
                    at: fixture.date))
            XCTAssertEqual(
                fixture.store.completeEffectResult(
                    .remoteTrash, for: fixture.key, generation: fixture.generation,
                    remoteLinkID: fixture.original.nodeID, at: fixture.date), .failed)
            XCTAssertEqual(fixture.state, state)
            XCTAssertEqual(try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, before.map { $0.0 + "=" + $0.1 })
            XCTAssertTrue(fixture.store.handoffs(forRemoteLinkIDs: [fixture.latest.nodeID]).isEmpty)
        }
    }

    func testMalformedAndFutureDutyKeysRefuseRetirementWithoutChangingMetadata() throws {
        for suffix in ["v2:generation", "v1:broken", "v1:dg==:Yg==:future", "v1:dg==::owed", "v1:@@:Yg==:owed"] {
            let fixture = try PersistentHandoffChain()
            try fixture.raw { db in
                let sql = "INSERT INTO pending_info(key,value) VALUES('\(fixture.metadataPrefix)\(suffix)',1);"
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
            let before = try fixture.metadataRows().map { $0.0 + "=" + $0.1 }
            let state = fixture.state
            XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 2)), .failed, suffix)
            XCTAssertNil(fixture.store.include([fixture.key], at: fixture.date), suffix)
            XCTAssertNil(
                fixture.store.exclude(
                    [PendingExclusionRequest(key: fixture.key, presentation: nil, remote: nil)], at: fixture.date),
                suffix)
            XCTAssertEqual(fixture.state, state)
            XCTAssertEqual(try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, before)
        }
    }

    func testMetadataOfAnotherSourceCannotRefuseThisSourcesHandoffOrRestore() throws {
        let fixture = try PersistentHandoffChain(identifier: "case-source-aa@")
        let otherPrefix =
            "pending-trash:" + Data(fixture.key.kind.rawValue.utf8).base64EncodedString() + ":"
            + Data("case-source-aaZ".utf8).base64EncodedString() + ":"
        XCTAssertNotEqual(fixture.metadataPrefix, otherPrefix)
        XCTAssertEqual(
            fixture.metadataPrefix.lowercased(), otherPrefix.lowercased(),
            "the fixture isolates case-sensitive source identity")
        try fixture.raw { db in
            let sql = "INSERT INTO pending_info(key,value) VALUES('\(otherPrefix)v2:generation',999);"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        try fixture.record(fixture.middle, revision: 2)
        XCTAssertNotNil(fixture.store.include([fixture.key], at: fixture.date))
        XCTAssertEqual(try fixture.metadataRows().count, 1, "another source's unknown record stays intact")
    }

    func testAnInterruptedDutyReadRefusesRegistrationWithoutSavingAHandoff() throws {
        let fixture = try PersistentHandoffChain()
        let before = fixture.state
        try fixture.interruptDutyRead(number: 1) {
            XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 2)), .failed)
        }
        XCTAssertEqual(fixture.state, before)
        XCTAssertTrue(fixture.store.handoffs(forRemoteLinkIDs: [fixture.middle.nodeID]).isEmpty)
        try fixture.record(fixture.middle, revision: 2)
    }

    func testPruningAfterAStoredCompletionAndFailedNextDutyReadKeepsEveryHandoff() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        try fixture.record(fixture.latest, revision: 3)
        XCTAssertTrue(
            fixture.store.acknowledgeHandoffs([1, 2, 3].map { (fixture.key, UploadBackupRevision(rawValue: $0)) }))
        try fixture.interruptDutyRead(number: 2) {
            XCTAssertEqual(
                fixture.store.completeEffectResult(
                    .remoteTrash, for: fixture.key, generation: fixture.generation,
                    remoteLinkID: fixture.original.nodeID, at: fixture.date), .laterHandoffUnreadable)
        }
        XCTAssertTrue(try XCTUnwrap(fixture.state).remoteTrashed)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
        XCTAssertTrue(fixture.store.pruneAcknowledgedHandoffs(olderThan: fixture.date.addingTimeInterval(100)))
        XCTAssertEqual(
            Set(
                fixture.store.handoffs(forRemoteLinkIDs: [fixture.middle.nodeID, fixture.latest.nodeID]).map(\.remote)),
            [fixture.middle, fixture.latest])
        XCTAssertEqual(fixture.store.resumeLaterTrash(for: fixture.key, at: fixture.date), .scheduled)
        try fixture.complete(fixture.latest)
        XCTAssertEqual(fixture.state?.remote, fixture.middle)
    }

    func testLegacyDeletesWithNewHandoffsDoNotCycleBackToACompletedLatestPhoto() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(db, "DELETE FROM pending_info WHERE key GLOB 'pending-trash:*';", nil, nil, nil), SQLITE_OK
            )
        }
        try fixture.record(fixture.middle, revision: 2)
        try fixture.record(fixture.latest, revision: 3)
        try fixture.complete(fixture.original)
        try fixture.complete(fixture.latest)
        XCTAssertEqual(fixture.state?.remote, fixture.middle)
        try fixture.complete(fixture.middle)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
        XCTAssertEqual(fixture.store.resumeLaterTrash(for: fixture.key, at: fixture.date), .unchanged)
    }

    func testOlderMetadataDoesNotGrantTrashInTheCurrentGeneration() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.raw { db in
            let suffix =
                "v1:" + Data(fixture.middle.volumeID.utf8).base64EncodedString() + ":"
                + Data(fixture.middle.nodeID.utf8).base64EncodedString() + ":owed"
            XCTAssertEqual(
                sqlite3_exec(
                    db, "INSERT INTO pending_info VALUES('\(fixture.metadataPrefix)\(suffix)',0);", nil, nil, nil),
                SQLITE_OK)
        }
        try fixture.complete(fixture.original)
        XCTAssertFalse(try XCTUnwrap(fixture.state).needsRemoteTrash)
        XCTAssertEqual(fixture.state?.remote, fixture.original)
    }

    func testAnOlderCompletionCannotWriteAReceiptIntoANewerDeleteGeneration() throws {
        let fixture = try PersistentHandoffChain()
        XCTAssertNotNil(
            fixture.store.exclude(
                [PendingExclusionRequest(key: fixture.key, presentation: nil, remote: fixture.original)],
                at: fixture.date))
        try fixture.record(fixture.original, revision: 4)
        let before = try fixture.metadataRows().map { $0.0 + "=" + $0.1 }
        XCTAssertTrue(
            fixture.store.completeEffect(
                .remoteTrash, for: fixture.key, generation: fixture.generation, remoteLinkID: fixture.original.nodeID,
                at: fixture.date))
        XCTAssertEqual(
            try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, before,
            "the old callback cannot add a receipt to the later delete")
        XCTAssertFalse(
            try XCTUnwrap(fixture.state).needsRemoteTrash,
            "a saved trash must not schedule its own UID again without a current-generation receipt")
    }

    func testNonTrashCompletionsDoNotWriteTrashReceipts() throws {
        let fixture = try PersistentHandoffChain(beginOperation: false)
        XCTAssertTrue(
            try fixture.metadataRows().allSatisfy { $0.0.hasSuffix(":generation") }, "queue sync has no trash receipt")
        let included = try XCTUnwrap(fixture.store.include([fixture.key], at: fixture.date)?.first)
        XCTAssertTrue(
            fixture.store.completeEffect(
                .remoteTrash, for: fixture.key, generation: included.generation, remoteLinkID: fixture.original.nodeID,
                at: fixture.date))
        XCTAssertTrue(try fixture.metadataRows().isEmpty, "an included source has no deletion duty")
    }

    func testNegativeSourceGenerationAndEmptyHandoffLinkAreRefused() throws {
        let fixture = try PersistentHandoffChain()
        XCTAssertEqual(
            fixture.store.recordHandoff(fixture.handoff(PhotoUID(volumeID: "", nodeID: ""), revision: 2)), .failed)
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "DELETE FROM pending_info WHERE key GLOB 'pending-trash:*'; UPDATE source_state SET generation=-1;",
                    nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 2)), .failed)
        XCTAssertTrue(fixture.store.handoffs(forRemoteLinkIDs: [fixture.middle.nodeID]).isEmpty)
    }

    func testANonCanonicalBase64KeyCannotAuthorizeTrashOrRetirement() throws {
        XCTAssertEqual(
            Data(base64Encoded: "Zh=="), Data("f".utf8),
            "the fixture reaches canonical validation after Base64 decoding")
        let fixture = try PersistentHandoffChain()
        try fixture.raw { db in
            XCTAssertEqual(
                sqlite3_exec(
                    db, "INSERT INTO pending_info VALUES('\(fixture.metadataPrefix)v1:Zh==:Yg==:owed',1);", nil, nil,
                    nil), SQLITE_OK)
        }
        XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 2)), .failed)
        XCTAssertNil(fixture.store.include([fixture.key], at: fixture.date))
    }

    func testRefusedGenerationMarkerRollsBackTheNewDelete() throws {
        let fixture = try PersistentHandoffChain()
        let before = fixture.state
        let rows = try fixture.metadataRows().map { $0.0 + "=" + $0.1 }
        try fixture.denyOnce(SQLITE_INSERT) {
            XCTAssertNil(
                fixture.store.exclude(
                    [PendingExclusionRequest(key: fixture.key, presentation: nil, remote: fixture.original)],
                    at: fixture.date))
        }
        try fixture.reopen()
        XCTAssertEqual(fixture.state, before)
        XCTAssertEqual(try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, rows)
    }

    func testRefusedDutyRegistrationRollsBackItsHandoff() throws {
        let fixture = try PersistentHandoffChain()
        let before = try XCTUnwrap(fixture.state)
        try fixture.denyOnce(SQLITE_INSERT) {
            XCTAssertEqual(fixture.store.recordHandoff(fixture.handoff(fixture.middle, revision: 2)), .failed)
        }
        try fixture.reopen()
        XCTAssertEqual(fixture.state, before)
        XCTAssertTrue(fixture.store.handoffs(forRemoteLinkIDs: [fixture.middle.nodeID]).isEmpty)
    }

    func testRefusedCompletionReceiptRollsBackTheSourceCompletion() throws {
        let fixture = try PersistentHandoffChain()
        try fixture.record(fixture.middle, revision: 2)
        let before = try XCTUnwrap(fixture.state)
        try fixture.denyOnce(SQLITE_INSERT) {
            XCTAssertEqual(
                fixture.store.completeEffectResult(
                    .remoteTrash, for: fixture.key, generation: fixture.generation,
                    remoteLinkID: fixture.original.nodeID, at: fixture.date), .failed)
        }
        try fixture.reopen()
        XCTAssertEqual(fixture.state, before)
    }

    func testRefusedRetirementRollsBackRestoreAndLaterDelete() throws {
        for restore in [true, false] {
            let fixture = try PersistentHandoffChain()
            try fixture.record(fixture.middle, revision: 2)
            let before = try XCTUnwrap(fixture.state)
            let rows = try fixture.metadataRows().map { $0.0 + "=" + $0.1 }
            try fixture.denyOnce(SQLITE_DELETE) {
                if restore {
                    XCTAssertNil(fixture.store.include([fixture.key], at: fixture.date))
                } else {
                    XCTAssertNil(
                        fixture.store.exclude(
                            [PendingExclusionRequest(key: fixture.key, presentation: nil, remote: fixture.original)],
                            at: fixture.date))
                }
            }
            try fixture.reopen()
            XCTAssertEqual(fixture.state, before)
            XCTAssertEqual(try fixture.metadataRows().map { $0.0 + "=" + $0.1 }, rows)
        }
    }
}

private final class PersistentHandoffChain {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "persistent-handoff-chain-\(UUID().uuidString)", isDirectory: true)
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let key: PendingSourceKey
    let original = PhotoUID(volumeID: "vol", nodeID: "upload-A")
    let middle = PhotoUID(volumeID: "vol", nodeID: "upload-B")
    let latest = PhotoUID(volumeID: "vol", nodeID: "upload-C")
    var store: PendingBackupManifestStore
    let generation: Int64
    var state: PendingSourceState? { store.sourceStateRead(for: key).state }
    var url: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    init(identifier: String = "persistent-asset", beginOperation: Bool = true, deleted: Bool = true) throws {
        key = PendingSourceKey(kind: .photoLibraryAsset, identifier: identifier)
        store = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 1), remote: original, kind: .uploaded,
                    createdAt: date.addingTimeInterval(-20))), .recorded)
        if !deleted {
            generation = 0
            return
        }
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: original)], at: date)?.first)
        generation = excluded.generation
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: generation, at: date))
        if beginOperation {
            XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [excluded]), [key])
        }
    }

    deinit {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func handoff(_ remote: PhotoUID, revision: Int64) -> PendingHandoff {
        PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: revision), remote: remote, kind: .uploaded,
            createdAt: date.addingTimeInterval(Double(revision)))
    }

    func record(_ remote: PhotoUID, revision: Int64) throws {
        XCTAssertEqual(store.recordHandoff(handoff(remote, revision: revision)), .excludedRemoteNeedsTrash)
    }

    func complete(_ remote: PhotoUID) throws {
        let state = try XCTUnwrap(self.state)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [state]), [key])
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: state.generation, remoteLinkID: remote.nodeID,
                at: date.addingTimeInterval(10)))
    }

    func reopen() throws {
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: url))
    }

    func raw(_ body: (OpaquePointer?) throws -> Void) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        try body(db)
    }

    func metadataRows() throws -> [(String, String)] {
        var rows: [(String, String)] = []
        try raw { db in
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db, "SELECT key, quote(value) FROM pending_info WHERE key GLOB 'pending-trash:*' ORDER BY key;",
                    -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    (String(cString: sqlite3_column_text(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1))))
            }
        }
        return rows
    }

    var metadataPrefix: String {
        "pending-trash:" + Data(key.kind.rawValue.utf8).base64EncodedString() + ":"
            + Data(key.identifier.utf8).base64EncodedString() + ":"
    }

    func interruptDutyRead(number: Int, body: () throws -> Void) throws {
        let connection = try XCTUnwrap(
            Mirror(reflecting: store).children.first { $0.label == "connection" }?.value as? SQLiteStoreConnection)
        let db = try XCTUnwrap(connection.database)
        let fault = PendingDutyReadFailure(db: db, number: number)
        let context = Unmanaged.passUnretained(fault).toOpaque()
        sqlite3_trace_v2(
            db, UInt32(SQLITE_TRACE_STMT),
            { _, context, statement, _ in
                guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                let fault = Unmanaged<PendingDutyReadFailure>.fromOpaque(context).takeUnretainedValue()
                sqlite3_progress_handler(fault.db, 0, nil, nil)
                if String(cString: sql).hasPrefix("SELECT key, value FROM pending_info") {
                    fault.reads += 1
                    if fault.reads == fault.number {
                        sqlite3_progress_handler(
                            fault.db, 1,
                            { context in
                                guard let context else { return 0 }
                                let fault = Unmanaged<PendingDutyReadFailure>.fromOpaque(context).takeUnretainedValue()
                                fault.fired = true
                                return 1
                            }, context)
                    }
                }
                return 0
            }, context)
        defer {
            sqlite3_trace_v2(db, 0, nil, nil)
            sqlite3_progress_handler(db, 0, nil, nil)
        }
        try body()
        XCTAssertTrue(fault.fired, "the intended duty read must be interrupted")
        XCTAssertTrue(connection.failuresAreTransient)
    }

    func denyOnce(_ operation: Int32, body: () throws -> Void) throws {
        let connection = try XCTUnwrap(
            Mirror(reflecting: store).children.first { $0.label == "connection" }?.value as? SQLiteStoreConnection)
        let db = try XCTUnwrap(connection.database)
        let failure = PendingMetadataFailure(operation)
        sqlite3_set_authorizer(
            db,
            { context, action, table, _, _, _ in
                guard let context, let table else { return SQLITE_OK }
                let failure = Unmanaged<PendingMetadataFailure>.fromOpaque(context).takeUnretainedValue()
                if !failure.fired, action == failure.operation, String(cString: table) == "pending_info" {
                    failure.fired = true
                    return SQLITE_DENY
                }
                return SQLITE_OK
            }, Unmanaged.passUnretained(failure).toOpaque())
        defer { sqlite3_set_authorizer(db, nil, nil) }
        try body()
        XCTAssertTrue(failure.fired, "the fixture must refuse the intended metadata statement")
    }
}

private final class PendingMetadataFailure {
    let operation: Int32
    var fired = false
    init(_ operation: Int32) { self.operation = operation }
}

private final class PendingDutyReadFailure {
    let db: OpaquePointer
    let number: Int
    var reads = 0
    var fired = false
    init(db: OpaquePointer, number: Int) {
        self.db = db
        self.number = number
    }
}
