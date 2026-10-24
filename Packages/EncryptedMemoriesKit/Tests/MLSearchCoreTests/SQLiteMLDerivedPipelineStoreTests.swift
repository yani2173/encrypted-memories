import Foundation
import PhotosCore
import SQLite3
import Testing

@testable import MLSearchCore

@Suite struct SQLiteMLDerivedPipelineStoreTests {
    @Test func outputAndTokenIndexRemainPrivateAndResumeAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        let cipher = TestDerivedCipher(key: 0x5a)
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account-a", artifacts: [artifact])
        let uid = PhotoUID(volumeID: "volume", nodeID: "1")
        let asset = try MLPipelineAssetRevision(uid: uid, sourceRevision: "source-v1")

        var store: SQLiteMLDerivedPipelineStore? = try openStore(url: url, cipher: cipher)
        #expect(store?.enqueue([asset], for: key) == true)
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data("Secret Receipt 42".utf8),
                            normalizedSearchTokens: ["secret", "receipt", "42"]
                        )))
            }
        }
        let outcome = await MLIndexRunner.runDerivedPass(
            key: key,
            store: try #require(store),
            executor: executor
        )
        #expect(outcome.progress.completed == 1)
        #expect(store?.search(normalizedTokens: ["receipt", "42"], in: key, limit: 10).map(\.uid) == [uid])
        #expect(
            store?.output(for: uid, artifact: artifact, accountIdentifier: "account-a")?.payload
                == Data("Secret Receipt 42".utf8))
        store?.close()
        store = nil

        let files = [url, URL(fileURLWithPath: url.path + "-wal")]
        let persisted = files.compactMap { try? Data(contentsOf: $0) }.reduce(into: Data()) { $0.append($1) }
        #expect(!persisted.contains(Data("Secret Receipt 42".utf8)))
        #expect(!persisted.contains(Data("receipt".utf8)))

        store = try openStore(url: url, cipher: cipher)
        #expect(try store?.progress(for: key).completed == 1)
        #expect(try store?.nextWorkBatch(for: key, limit: 8, now: .now).isEmpty == true)
        #expect(store?.search(normalizedTokens: ["secret"], in: key, limit: 10).map(\.uid) == [uid])
    }

    /// Another connection holds the file exclusively longer than the busy timeout. The derived index is never
    /// deleted for that, and it opens again with its progress once the lock is gone.
    @Test func aFileThatAnotherConnectionHoldsIsKeptAndOpensAgainWithItsProgress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        let cipher = TestDerivedCipher(key: 0x5a)
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account-a", artifacts: [artifact])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "1"), sourceRevision: "source-v1")
        let first = try openStore(url: url, cipher: cipher)
        #expect(first.enqueue([asset], for: key))
        first.close()
        var blocker: OpaquePointer?
        #expect(sqlite3_open(url.path, &blocker) == SQLITE_OK)
        #expect(sqlite3_exec(blocker, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

        let noWait = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        let busy = SQLiteMLDerivedPipelineStore(url: url, policy: noWait, cipher: cipher)
        busy?.close()
        #expect(sqlite3_exec(blocker, "COMMIT;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(blocker)

        #expect(busy == nil, "the store is unavailable while the lock lasts")
        #expect(FileManager.default.fileExists(atPath: url.path), "the index is not deleted")
        let reopened = try openStore(url: url, cipher: cipher)
        defer { reopened.close() }
        #expect(try reopened.progress(for: key).total == 1)
    }

    @Test func sourceRevisionInvalidatesPayloadAndPostingsBeforeReindex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x33)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let uid = PhotoUID(volumeID: "volume", nodeID: "1")
        let first = try MLPipelineAssetRevision(uid: uid, sourceRevision: "source-v1")
        #expect(store.enqueue([first], for: key))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data("old".utf8),
                            normalizedSearchTokens: ["old"]
                        )))
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)
        #expect(store.search(normalizedTokens: ["old"], in: key, limit: 10).count == 1)

        let changed = try MLPipelineAssetRevision(uid: uid, sourceRevision: "source-v2")
        #expect(store.enqueue([changed], for: key))
        #expect(try store.progress(for: key).pending == 1)
        #expect(store.output(for: uid, artifact: artifact, accountIdentifier: "account") == nil)
        #expect(store.search(normalizedTokens: ["old"], in: key, limit: 10).isEmpty)
    }

    @Test func requestRevisionChangeReclaimsOnlyTheObsoleteArtifactNamespace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x34)
        )
        let oldOCR = try makeArtifact(stage: "ocr", revision: "revision2")
        let currentBarcode = try makeArtifact(stage: "barcode", revision: "revision1")
        let oldKey = try makeKey(account: "account", artifacts: [oldOCR, currentBarcode])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "1"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: oldKey))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data($0.artifact.stageID.rawValue.utf8),
                            normalizedSearchTokens: [$0.artifact.stageID.rawValue]
                        ))
                )
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: oldKey, store: store, executor: executor)

        let newOCR = try makeArtifact(stage: "ocr", revision: "revision3")
        let currentKey = try makeKey(account: "account", artifacts: [newOCR, currentBarcode])
        #expect(store.enqueue([asset], for: currentKey))

        #expect(store.output(for: asset.uid, artifact: oldOCR, accountIdentifier: "account") == nil)
        #expect(
            store.output(for: asset.uid, artifact: currentBarcode, accountIdentifier: "account")?.payload
                == Data("barcode".utf8)
        )
        let progress = try store.progress(for: currentKey)
        #expect(progress.total == 2)
        #expect(progress.completed == 1)
        #expect(progress.pending == 1)
    }

    @Test func temporarilyUnavailableStageKeepsCompletedWorkForReuse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x35)
        )
        let ocr = try makeArtifact(stage: "ocr", revision: "revision3")
        let barcode = try makeArtifact(stage: "barcode", revision: "revision4")
        let completeKey = try makeKey(account: "account", artifacts: [ocr, barcode])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "1"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: completeKey))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data($0.artifact.stageID.rawValue.utf8),
                            normalizedSearchTokens: [$0.artifact.stageID.rawValue]
                        ))
                )
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: completeKey, store: store, executor: executor)

        let temporarilyReducedKey = try makeKey(account: "account", artifacts: [ocr])
        #expect(store.enqueue([asset], for: temporarilyReducedKey))
        #expect(store.output(for: asset.uid, artifact: barcode, accountIdentifier: "account") != nil)

        #expect(store.enqueue([asset], for: completeKey))
        #expect(try store.nextWorkBatch(for: completeKey, limit: 8, now: .now).isEmpty)
        #expect(try store.progress(for: completeKey).completed == 2)
    }

    @Test func accountAndArtifactPurgeStayIsolated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x21)
        )
        let ocr = try makeArtifact(stage: "ocr", revision: "revision3")
        let barcode = try makeArtifact(stage: "barcode", revision: "revision1")
        let firstKey = try makeKey(account: "first", artifacts: [ocr, barcode])
        let secondKey = try makeKey(account: "second", artifacts: [ocr])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "1"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: firstKey))
        #expect(store.enqueue([asset], for: secondKey))

        store.purge(artifact: ocr, accountIdentifier: "first")
        #expect(try store.progress(for: firstKey).total == 1)
        #expect(try store.progress(for: secondKey).total == 1)
        store.purge(pipelineID: .nativeSearch, accountIdentifier: "second")
        #expect(try store.progress(for: secondKey).total == 0)
        #expect(try store.progress(for: firstKey).total == 1)
    }

    @Test func reconcileRemovesOnlyMissingAssetsAndTheirTokenPostings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x44)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let retained = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "retained"),
            sourceRevision: "retained-v1"
        )
        let deleted = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "deleted"),
            sourceRevision: "deleted-v1"
        )
        #expect(store.enqueue([retained, deleted], for: key))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data("shared word".utf8),
                            normalizedSearchTokens: ["shared", "word"]
                        )))
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)
        #expect(store.search(normalizedTokens: ["shared"], in: key, limit: 10).count == 2)

        #expect(store.reconcile(liveUIDs: [retained.uid], for: key))
        #expect(try store.progress(for: key).total == 1)
        #expect(store.search(normalizedTokens: ["shared"], in: key, limit: 10).map(\.uid) == [retained.uid])
        #expect(store.output(for: deleted.uid, artifact: artifact, accountIdentifier: "account") == nil)
    }

    @Test func multiArtifactSearchRequiresEveryDistinctQueryToken() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x45)
        )
        let ocr = try makeArtifact(stage: "ocr", revision: "revision3")
        let document = try makeArtifact(stage: "document", revision: "revision1")
        let barcode = try makeArtifact(stage: "barcode", revision: "revision4")
        let key = try makeKey(account: "account", artifacts: [ocr, document, barcode])
        #expect(key.artifacts.count == 3)
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "1"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: key))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map { item in
                let tokens =
                    item.artifact == ocr
                    ? ["shared", "invoice"]
                    : ["shared", "qr42"]
                return .init(
                    workItem: item,
                    outcome: .completed(.init(payload: Data(), normalizedSearchTokens: tokens))
                )
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)

        #expect(store.search(normalizedTokens: ["invoice", "qr42"], in: key, limit: 10).map(\.uid) == [asset.uid])
        #expect(store.search(normalizedTokens: ["shared", "missing"], in: key, limit: 10).isEmpty)
    }

    @Test func normalizedSchemaKeepsLargePendingQueueBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        let ocr = try makeArtifact(stage: "ocr", revision: "revision3")
        let document = try makeArtifact(stage: "document", revision: "revision1")
        let barcode = try makeArtifact(stage: "barcode", revision: "revision4")
        let key = try makeKey(account: "account", artifacts: [ocr, document, barcode])
        #expect(key.artifacts.count == 3)
        let assets = try (0..<10_000).map { index in
            try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "volume", nodeID: "node-\(index)"),
                sourceRevision: "source-v1:volume:node-\(index)"
            )
        }

        var store: SQLiteMLDerivedPipelineStore? = try openStore(
            url: url,
            cipher: TestDerivedCipher(key: 0x63)
        )
        #expect(store?.enqueue(assets, for: key) == true)
        #expect(try store?.progress(for: makeKey(account: "account", artifacts: [ocr])).total == 10_000)
        #expect(try store?.progress(for: makeKey(account: "account", artifacts: [document])).total == 10_000)
        #expect(try store?.progress(for: makeKey(account: "account", artifacts: [barcode])).total == 10_000)
        #expect(try store?.progress(for: key).total == 30_000)
        store?.close()
        store = nil

        let persistedBytes = [url, URL(fileURLWithPath: url.path + "-wal")]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
            .reduce(Int64(0)) { $0 + $1.int64Value }
        #expect(persistedBytes < 12 * 1_024 * 1_024)
    }

    @Test func denseWorkSelectionIsAccountScopedAndKeepsDeterministicAssetGroups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x75)
        )
        let artifacts: Set<MLDerivedArtifactIdentity> = [
            try makeArtifact(stage: "ocr", revision: "revision3"),
            try makeArtifact(stage: "document", revision: "revision1"),
            try makeArtifact(stage: "barcode", revision: "revision4"),
        ]
        let firstKey = try makeKey(account: "first-account", artifacts: artifacts)
        let secondKey = try makeKey(account: "second-account", artifacts: artifacts)
        let firstAssets = try (0..<512).map { index in
            try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "first-volume", nodeID: String(format: "node-%04d", index)),
                sourceRevision: "first-revision-\(index)"
            )
        }
        let secondAssets = try (0..<512).map { index in
            try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "second-volume", nodeID: String(format: "node-%04d", index)),
                sourceRevision: "second-revision-\(index)"
            )
        }

        // Give the other account the lower global asset IDs. Account-keyed indexes must still
        // return the requested account without scanning or mixing those earlier rows.
        #expect(store.enqueue(secondAssets, for: secondKey))
        #expect(store.enqueue(firstAssets, for: firstKey))

        let batch = try store.nextWorkBatch(for: firstKey, limit: 9, now: .now)
        #expect(batch.count == 9)
        #expect(batch.allSatisfy { $0.asset.uid.volumeID == "first-volume" })
        #expect(
            batch.map(\.asset.uid.nodeID) == Array(repeating: "node-0000", count: 3)
                + Array(repeating: "node-0001", count: 3)
                + Array(repeating: "node-0002", count: 3))
        #expect(Set(batch.prefix(3).map(\.artifact)) == artifacts)
    }

    @Test func configuredSizeLimitTruncatesTheSingleCanonicalWAL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        let policy = LibraryDatabasePolicy(
            mmapBytes: 0,
            cacheSizeKiB: 2_048,
            busyTimeoutMs: 3_000,
            journalSizeLimitBytes: 0,
            walCheckpointRowThreshold: .max
        )
        let store = try openStore(
            url: url,
            policy: policy,
            cipher: TestDerivedCipher(key: 0x74)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let assets = try (0..<128).map {
            try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "volume", nodeID: "node-\($0)"),
                sourceRevision: "source-\($0)"
            )
        }

        #expect(store.enqueue(assets, for: key))
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let walBytes =
            (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        #expect(walBytes == 0)
        #expect(try store.progress(for: key).total == assets.count)
    }

    @Test func materializedProgressTracksEveryStateTransitionWithoutRescanningWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x65)
        )
        let ocr = try makeArtifact(stage: "ocr", revision: "revision3")
        let barcode = try makeArtifact(stage: "barcode", revision: "revision1")
        let key = try makeKey(account: "account", artifacts: [ocr, barcode])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "node"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: key))
        #expect(try store.progress(for: key).pending == 2)

        let work = try store.nextWorkBatch(for: key, limit: 2, now: .now)
        #expect(work.count == 2)
        let first = try #require(work.first { $0.artifact == ocr })
        let second = try #require(work.first { $0.artifact == barcode })
        #expect(
            store.commit(
                [
                    .init(workItem: first, outcome: .completedEmpty),
                    .init(
                        workItem: second,
                        outcome: .retryableFailure(reason: .analysisFailed, retryAfter: .distantFuture)),
                ], for: key, now: .now))
        var progress = try store.progress(for: key)
        #expect(progress.completed == 1)
        #expect(progress.retryPending == 1)

        #expect(
            store.commit(
                [
                    .init(workItem: second, outcome: .permanentInputFailure(reason: .sourceCorrupt))
                ], for: key, now: .now))
        progress = try store.progress(for: key)
        #expect(progress.total == 2)
        #expect(progress.completed == 1)
        #expect(progress.retryPending == 0)
        #expect(progress.permanentFailure == 1)
        #expect(progress.unavailableAssets == 1)
    }

    @Test func nextWorkBatchMergesPendingAndDueRetriesIntoDeterministicAssetGroups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x66)
        )
        let ocr = try makeArtifact(stage: "ocr", revision: "revision3")
        let barcode = try makeArtifact(stage: "barcode", revision: "revision1")
        let key = try makeKey(account: "account", artifacts: [ocr, barcode])
        let firstAsset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "first"), sourceRevision: "source-v1"
        )
        let secondAsset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "second"), sourceRevision: "source-v1"
        )
        #expect(store.enqueue([firstAsset, secondAsset], for: key))

        let initial = try store.nextWorkBatch(for: key, limit: 4, now: .now)
        let retry = try #require(initial.first { $0.asset.uid == firstAsset.uid })
        #expect(
            store.commit(
                [
                    .init(
                        workItem: retry, outcome: .retryableFailure(reason: .analysisFailed, retryAfter: .distantPast))
                ], for: key, now: .now))

        let work = try store.nextWorkBatch(for: key, limit: 4, now: .now)
        #expect(work.count == 4)
        #expect(work[0].asset.uid == firstAsset.uid)
        #expect(work[0].artifact == retry.artifact)
        #expect(work[1].asset.uid == firstAsset.uid)
        #expect(work[2].asset.uid == secondAsset.uid)
        #expect(work[3].asset.uid == secondAsset.uid)
    }

    @Test func deferredSourceDoesNotBlockLaterSQLiteWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x67)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let first = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "first"), sourceRevision: "source-v1"
        )
        let second = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "second"), sourceRevision: "source-v1"
        )
        #expect(store.enqueue([first, second], for: key))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: plan.asset.uid == first.uid
                        ? .deferred(reason: .sourceNotResident, retryAfter: nil)
                        : .completedEmpty
                )
            }
        }
        let clock = Date(timeIntervalSince1970: 100)
        let firstPass = await MLIndexRunner.runDerivedPass(
            key: key, store: store, executor: executor,
            configuration: .init(chunkSize: 1, retryDelay: 120), maximumAnalysisPlans: 1,
            now: { clock }
        )
        #expect(firstPass.reason == .workQuantumCompleted)
        #expect(try store.nextWorkBatch(for: key, limit: 1, now: clock).first?.asset.uid == second.uid)

        let secondPass = await MLIndexRunner.runDerivedPass(
            key: key, store: store, executor: executor,
            configuration: .init(chunkSize: 1, retryDelay: 120), maximumAnalysisPlans: 1,
            now: { clock }
        )
        #expect(secondPass.progress.completed == 1)
    }

    @Test func retrySelectionIsBoundedByDueTimeBeforeAssetGrouping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x76)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let assets = try (0..<3).map { index in
            try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "volume", nodeID: "node-\(index)"),
                sourceRevision: "source-v1"
            )
        }
        #expect(store.enqueue(assets, for: key))
        let initial = try store.nextWorkBatch(for: key, limit: 3, now: .now)
        #expect(initial.count == 3)
        let base = Date(timeIntervalSince1970: 10_000)
        let retryDates = [
            base.addingTimeInterval(-10),
            base.addingTimeInterval(-20),
            base.addingTimeInterval(-30),
        ]
        #expect(
            store.commit(
                zip(initial, retryDates).map { work, retryAt in
                    MLPipelineStageResult(
                        workItem: work,
                        outcome: .retryableFailure(reason: .analysisFailed, retryAfter: retryAt)
                    )
                },
                for: key,
                now: base
            )
        )

        let next = try store.nextWorkBatch(for: key, limit: 1, now: base)
        #expect(next.map(\.asset.uid) == [assets[2].uid])
    }

    @Test func obsoleteDerivedSchemaIsRebuiltWithoutTouchingOtherMLState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(
            sqlite3_exec(raw, "CREATE TABLE obsolete_marker(value INTEGER); PRAGMA user_version=1;", nil, nil, nil)
                == SQLITE_OK)
        sqlite3_close(raw)

        let store = try openStore(url: url, cipher: TestDerivedCipher(key: 0x64))
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "node"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: key))
        #expect(try store.progress(for: key).total == 1)
    }

    @Test func currentMarkerWithWrongShapeResetsTheDerivedPipeline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                raw,
                "CREATE TABLE legacy_work(value TEXT); PRAGMA user_version=7;",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(raw)

        let store = try openStore(url: url, cipher: TestDerivedCipher(key: 0x65))
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        #expect(try store.progress(for: key).total == 0)
        store.close()

        raw = nil
        #expect(sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(
                raw,
                "SELECT COUNT(*) FROM sqlite_schema WHERE name='legacy_work';",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
        sqlite3_finalize(statement)
        sqlite3_close(raw)
    }

    @Test func markerlessExactSchemaResetsInsteadOfAdoptingDerivedWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        let cipher = TestDerivedCipher(key: 0x66)
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "cached"),
            sourceRevision: "source-v1"
        )
        let first = try openStore(url: url, cipher: cipher)
        #expect(first.enqueue([asset], for: key))
        #expect(try first.progress(for: key).total == 1)
        first.close()

        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "PRAGMA user_version=0;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let rebuilt = try openStore(url: url, cipher: cipher)
        #expect(try rebuilt.progress(for: key).total == 0)
        rebuilt.close()
    }

    @Test func previousSchemaResetsInsteadOfMigratingRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName)
        let cipher = TestDerivedCipher(key: 0x72)
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let first = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "first"), sourceRevision: "source-v1")
        let second = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "second"), sourceRevision: "source-v1")

        var store: SQLiteMLDerivedPipelineStore? = try openStore(url: url, cipher: cipher)
        #expect(store?.enqueue([first, second], for: key) == true)
        let openedStore = try #require(store)
        let work = try openedStore.nextWorkBatch(for: key, limit: 2, now: .now)
        #expect(
            store?.commit(
                [
                    .init(workItem: work[0], outcome: .completedEmpty),
                    .init(workItem: work[1], outcome: .permanentInputFailure(reason: .retryLimitReached)),
                ], for: key, now: .now) == true)
        store?.close()
        store = nil

        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "PRAGMA user_version=6;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        store = try openStore(url: url, cipher: cipher)
        let reopenedStore = try #require(store)
        let progress = try reopenedStore.progress(for: key)
        #expect(progress.completed == 0)
        #expect(progress.pending == 0)
        #expect(progress.permanentFailure == 0)
        #expect(progress.total == 0)
        #expect(try store?.nextWorkBatch(for: key, limit: 2, now: .now).isEmpty == true)
    }

    @Test func emptyResultsCompleteAndTerminalFailuresAreGroupedByAsset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x73)
        )
        let first = try makeArtifact(stage: "first", revision: "revision1")
        let second = try makeArtifact(stage: "second", revision: "revision1")
        let third = try makeArtifact(stage: "third", revision: "revision1")
        let key = try makeKey(account: "account", artifacts: [first, second, third])
        let emptyAsset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "empty"),
            sourceRevision: "empty-v1"
        )
        let failedAsset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "failed"),
            sourceRevision: "failed-v1"
        )
        #expect(store.enqueue([emptyAsset, failedAsset], for: key))
        let executor = SQLiteRecordingExecutor { plan in
            plan.workItems.map {
                MLPipelineStageResult(
                    workItem: $0,
                    outcome: plan.asset.uid == emptyAsset.uid
                        ? .completedEmpty
                        : .permanentInputFailure(reason: .sourceCorrupt)
                )
            }
        }

        let outcome = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)

        #expect(outcome.reason == .drained)
        #expect(outcome.progress.completed == 3)
        #expect(outcome.progress.permanentFailure == 3)
        #expect(outcome.progress.unavailableAssets == 1)
        #expect(outcome.progress.unavailableAssetReasons == [.sourceCorrupt: 1])
        #expect(store.output(for: emptyAsset.uid, artifact: first, accountIdentifier: "account") == nil)
    }

    @Test func closedStoreReportsStorageFailureInsteadOfAnEmptyDrainedQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x77)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "account", artifacts: [artifact])
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "pending"),
            sourceRevision: "source-v1"
        )
        #expect(store.enqueue([asset], for: key))
        store.close()

        #expect(throws: MLDerivedPipelineStoreError.storageUnavailable) {
            _ = try store.progress(for: key)
        }
        #expect(throws: MLDerivedPipelineStoreError.storageUnavailable) {
            _ = try store.nextWorkBatch(for: key, limit: 1, now: .now)
        }
        #expect(throws: MLDerivedPipelineStoreError.storageUnavailable) {
            _ = try store.unavailableAssetUIDs(for: key)
        }

        let outcome = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: SQLiteRecordingExecutor { _ in [] }
        )
        #expect(outcome.reason == .storageFailure)
    }

    @Test func unavailableAssetsAreEmptyForAValidMissingAccount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMLDerivedPipelineStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try openStore(
            url: root.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
            cipher: TestDerivedCipher(key: 0x78)
        )
        let artifact = try makeArtifact(stage: "ocr", revision: "revision3")
        let key = try makeKey(account: "missing-account", artifacts: [artifact])

        #expect(try store.unavailableAssetUIDs(for: key).isEmpty)
    }

    private func makeArtifact(stage: String, revision: String) throws -> MLDerivedArtifactIdentity {
        let kind: MLNativeAnalysisKind =
            switch stage {
            case "document": .documentRecognition
            case "barcode": .barcodeDetection
            default: .textRecognition
            }
        let output: MLAnalysisOutputDescriptor =
            switch kind {
            case .documentRecognition: .structuredDocument
            case .barcodeDetection: .barcodePayload
            default: .recognizedText
            }
        return try MLDerivedArtifactIdentity(
            pipelineID: .nativeSearch,
            stageID: .init(rawValue: stage),
            producer: .native(
                providerIdentifier: "apple.vision",
                kind: kind,
                requestRevision: revision
            ),
            preprocessingRevision: "bounded-image-v1",
            output: output,
            schemaEpoch: 1
        )
    }

    private func makeKey(
        account: String,
        artifacts: Set<MLDerivedArtifactIdentity>
    ) throws -> MLPipelineExecutionKey {
        try MLPipelineExecutionKey(
            accountIdentifier: account,
            pipelineID: .nativeSearch,
            schemaVersion: 1,
            artifacts: artifacts
        )
    }

    private func openStore(
        url: URL,
        policy: LibraryDatabasePolicy = .conservative,
        cipher: any MLDerivedDataCipher
    ) throws -> SQLiteMLDerivedPipelineStore {
        guard let store = SQLiteMLDerivedPipelineStore(url: url, policy: policy, cipher: cipher) else {
            throw SQLiteDerivedStoreTestError.openFailed
        }
        return store
    }
}

private enum SQLiteDerivedStoreTestError: Error {
    case openFailed
}

private actor SQLiteRecordingExecutor: MLDerivedPipelineExecutor {
    private let handler: @Sendable (MLAssetAnalysisPlan) -> [MLPipelineStageResult]

    init(handler: @escaping @Sendable (MLAssetAnalysisPlan) -> [MLPipelineStageResult]) {
        self.handler = handler
    }

    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        handler(plan)
    }
}

private struct TestDerivedCipher: MLDerivedDataCipher {
    let key: UInt8

    func seal(_ plaintext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        contextTag(context) + Data(plaintext.reversed().map { $0 ^ key })
    }

    func open(_ ciphertext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        let tag = contextTag(context)
        guard ciphertext.starts(with: tag) else { throw TestDerivedCipherError.wrongContext }
        return Data(ciphertext.dropFirst(tag.count).map { $0 ^ key }.reversed())
    }

    func tokenDigest(
        normalizedToken: String,
        accountIdentifier: String,
        artifactNamespace: String
    ) throws -> Data {
        digest(Data("\(accountIdentifier)|\(artifactNamespace)|\(normalizedToken)".utf8))
    }

    private func contextTag(_ context: MLDerivedDataCipherContext) -> Data {
        digest(
            Data(
                "\(context.accountIdentifier)|\(context.artifactNamespace)|\(context.uid.volumeID)|\(context.uid.nodeID)"
                    .utf8))
    }

    private func digest(_ data: Data) -> Data {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte) ^ UInt64(key)
            hash &*= 0x100_0000_01b3
        }
        return withUnsafeBytes(of: hash.littleEndian) { Data($0) }
    }
}

private enum TestDerivedCipherError: Error {
    case wrongContext
}
