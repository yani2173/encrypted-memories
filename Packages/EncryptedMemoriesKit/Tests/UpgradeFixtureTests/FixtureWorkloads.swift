import CryptoKit
import Foundation
import MLSearchCore
import MediaByteCache
import MediaLocationCore
import PhotosCore
import UploadCore

#if UPGRADE_RECORDING
    import PhotoLibraryBackupAdapter
#else
    @testable import PhotoLibraryBackupAdapter
#endif

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

func fixtureRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw FixtureFailure(description: message) }
}

enum FixtureWorkloads {
    static let scenarios = ["backup", "model", "index", "cache", "location"]
    static let now = Date(timeIntervalSince1970: 1_720_100_000)
    static let key = SymmetricKey(data: Data(repeating: 0x53, count: 32))
    static let assets = (0..<8).map { PhotoUID(volumeID: "synthetic", nodeID: "asset-\($0)") }
    static func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func run(_ scenario: String, root: URL, recording: Bool, oracle: FixtureOracle = .init()) async throws {
        switch scenario {
        case "backup": try await backup(root, recording: recording, oracle: oracle)
        case "model", "index": try await smartSearch(root, recording: recording, index: scenario == "index")
        case "cache": try cache(root, recording: recording)
        case "location": try await location(root, recording: recording)
        default: throw FixtureFailure(description: "Unknown fixture scenario")
        }
    }

    static func backup(_ root: URL, recording: Bool, oracle: FixtureOracle) async throws {
        let data = try directory(root, "Account")
        let library = FixtureLibrary(directory: try directory(root, "Exports"), generation: oracle.generation)
        let remote = FixtureBackend(links: oracle.remote, oracleURL: oracle.externalURL, generation: oracle.generation)
        let queue = try requireStore(
            UploadBackupSyncQueueManifestStore(
                url: data.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)), "queue")
        let state = try requireStore(
            UploadBackupStateManifestStore(
                url: data.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)), "backup state")
        let identities = try requireStore(
            UploadIdentityManifestStore(url: data.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)),
            "identity manifest")
        let catalog = try requireStore(
            PhotoLibraryCatalogManifestStore(
                url: data.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)), "catalog")
        defer {
            queue.close()
            state.close()
            identities.close()
            catalog.close()
        }
        let preflight = UploadBackupPreflightIndex(store: state, now: { now })
        // The oracle comes from an unopened copy of the historical disk, before current store initialization.
        for row in oracle.complete {
            let source = UploadSourceIdentity(
                kind: .photoLibraryAsset, identifier: row.identifier, resource: .init(rawValue: row.resource))
            let snapshot = UploadBackupAssetSnapshot(
                source: source, revision: .init(rawValue: row.revision), resourceCount: row.resourceCount)
            let complete = state.lookupBatch([snapshot]).map { $0.succeeded && $0.directRecord?.isComplete == true }
            try fixtureRequire(complete == [true], "Backed-up revision lost while opening: \(row.identifier)")
        }
        let pipeline = UploadDedupePipeline(store: identities, checker: remote, now: { now })
        let engine = UploadBackupSyncEngine(
            preflight: preflight, queue: queue, remoteProofResolver: pipeline, now: { now })
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: library, now: { now })
        #if !UPGRADE_RECORDING
            try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
                catalogStore: catalog, queueStore: queue, engine: engine)
            try await sync.reconcileMissingSources(engine: engine)
            try await sync.reconcileLateRendersOnce(engine: engine)
            try await sync.runPass(
                engine: engine,
                changes: .init(
                    changedIdentifiers: [],
                    // The synthetic PhotoKit boundary has no persisted change token.
                    // prepareChanges() uses this same full-scan fallback when its token is absent.
                    deletedIdentifiers: [], requiresFullRescan: true), commitChanges: {})
        #else
            _ = try await sync.run(engine: engine)
        #endif
        if !recording {
            for candidate in library.allCandidates
            where oracle.complete.contains(where: {
                $0.identifier == candidate.snapshot.source.identifier
                    && $0.resource == candidate.snapshot.source.resource.rawValue
                    && $0.revision == candidate.snapshot.revision.rawValue
            }) {
                try fixtureRequire(
                    state.lookupBatch([candidate.snapshot]).allSatisfy {
                        $0.succeeded && $0.directRecord?.isComplete == true
                    }, "A backed-up current revision was reopened by the first scan")
            }
            let rows = UploadBackupSyncQueueState.allCases.flatMap {
                queue.entries(in: $0, updatedBefore: now.addingTimeInterval(1000), limit: 1000)
            }
            try fixtureRequire(queue.isOperational(), "Backup queue failed during enumeration")
            let keys = rows.map { "\($0.source.identifier)|\($0.source.resource.rawValue)|\($0.revision.rawValue)" }
            try fixtureRequire(Set(keys).count == keys.count, "Duplicate photo revision in queue")
            for row in rows
            where !row.state.isTerminalSuccess
                && !oracle.queueKeys.contains(
                    "\(row.source.identifier)|\(row.source.resource.rawValue)|\(row.revision.rawValue)")
            {
                try fixtureRequire(
                    !oracle.complete.contains {
                        $0.identifier == row.source.identifier && $0.resource == row.source.resource.rawValue
                            && $0.revision == row.revision.rawValue
                    }, "Queue grew by a backed-up revision")
            }
        }
        let runner = BackupSyncRunner(
            queue: queue, preflight: preflight, resolver: library, identityResolver: pipeline, uploader: remote,
            configuration: .init(
                staleActiveGrace: 0, retry: .init(baseDelay: 0.01, maxDelay: 0.02, maxAttempts: 4),
                throttle: .init(baseConcurrency: 1)), now: { now.addingTimeInterval(recording ? 100 : 1000) })
        if recording { remote.failNext = true }
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        _ = await runner.makeRetryableWorkEligibleNow()
        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        if recording {
            library.generation = 2
            try remote.publish(generation: 2)
            _ = try await sync.run(engine: engine)
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
            library.generation = 3
            try remote.publish(generation: 3)
            _ = try await sync.run(engine: engine)
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
        } else {
            let summary = queue.summary()
            try fixtureRequire(await runner.isQueueOperational(), "Backup queue failed during recovery")
            try fixtureRequire(
                summary.waiting + summary.active + summary.failed + summary.blocked == 0, "Backup queue did not recover"
            )
            try fixtureRequire(remote.duplicateUploads == 0, "A remote commit was uploaded twice after restart")
            for candidate in library.allCandidates {
                try fixtureRequire(
                    state.lookupBatch([candidate.snapshot]).allSatisfy {
                        $0.succeeded && $0.directRecord?.isComplete == true
                    },
                    "An available synthetic photo did not become backed up: \(candidate.snapshot.source.identifier), revision \(candidate.snapshot.revision.rawValue), lookup \(state.lookupBatch([candidate.snapshot]))"
                )
            }
        }
    }

    static func requireStore<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw FixtureFailure(description: "Fatal store open: \(name)") }
        return value
    }

    static let payload = Data(repeating: 0xA7, count: 16_384)
    static let modelEntry: MLModelCatalogEntry = {
        let artifact = MLModelArtifactSpec(
            relativePath: "Model.mlmodelc/weights.bin",
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(payload.count))
        return MLModelCatalogEntry(
            id: MLModelID("synthetic-model"), displayName: "Synthetic fixture", family: "Fixture",
            descriptor: .init(identifier: "synthetic-model", version: 1, embeddingDimension: 4),
            tokenizerID: "synthetic", preprocessingID: "synthetic", license: .mit, releaseTrack: .production,
            estimatedInstalledBytes: Int64(payload.count),
            downloadPlan: .init(
                revision: "r1",
                items: [.init(url: URL(string: "https://example.test/weights.bin")!, artifact: artifact)]))
    }()

    static func smartSearch(_ root: URL, recording: Bool, index: Bool) async throws {
        let layout = MLModelInstallLayout(rootDirectory: try directory(root, "SmartSearch"))
        struct RecordedIntent: Decodable { let isEnabled: Bool }
        let expectedEnabled: Bool
        if !recording, FileManager.default.fileExists(atPath: layout.stateFileURL.path) {
            expectedEnabled = try JSONDecoder().decode(
                RecordedIntent.self, from: Data(contentsOf: layout.stateFileURL)
            ).isEnabled
        } else {
            expectedEnabled = false
        }
        let transport = FixtureTransport(interruptFirst: recording)
        let installer = MLModelInstaller(layout: layout, transport: transport, availableCapacity: { _ in .max })
        let provider = FixtureRuntime()
        let stores = SQLiteMLIndexStoreProvider(url: layout.indexDatabaseURL, cipher: FixtureVectorCipher())
        #if !UPGRADE_RECORDING
            // Inspect the actual store before lifecycle tasks can repair an empty WAL header concurrently.
            _ = try requireStore(stores.openStore(), "semantic index")
            defer { stores.closeStore() }
        #endif
        let state = FileMLSmartSearchStateStore(layout: layout)
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: MLModelCatalog(entries: [modelEntry]), layout: layout, stateStore: state, installer: installer,
                storeProvider: stores, runtimeProvider: provider,
                assetsProvider: { .authoritative(index ? assets : []) }, governor: MLAlwaysPermitsIndexing(),
                allowsDeveloperModels: false), configuration: .init(indexRetryDelay: .milliseconds(10)))
        await lifecycle.start()
        if recording {
            await lifecycle.enable(with: modelEntry.id)
            await lifecycle.retry()
        } else {
            let startup = await lifecycle.currentSnapshot()
            try fixtureRequire(startup.isEnabled == expectedEnabled, "Smart Search lost its recorded enable intent")
            // Only a kill before persisted enable intent needs the next explicit user action.
            if !expectedEnabled { await lifecycle.enable(with: modelEntry.id) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var ready = false
        var terminalFailure: String?
        while ContinuousClock.now < deadline {
            let snapshot = await lifecycle.currentSnapshot()
            if case .ready(let coverage) = snapshot.phase, coverage.isComplete {
                ready = true
                break
            }
            if case .failed(let failure) = snapshot.phase {
                terminalFailure = "\(failure.kind): \(failure.debugDescription)"
                if !recording || failure.kind == .storage { break }
                await lifecycle.retry()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        await lifecycle.shutdown()
        try fixtureRequire(
            ready, terminalFailure ?? "Smart Search did not recover within its bounded work budget")
        if index { try await nativeIndex(layout) }
        try fixtureRequire(provider.invalidLoads == 0, "Partial model reached the runtime")
        try fixtureRequire(
            provider.embeddings <= assets.count, "Index recovery repeated more than one bounded inventory")
        try fixtureRequire(
            installer.installedRecord(for: modelEntry, revision: "r1") != nil, "Verified installation unavailable")
    }

    static func nativeIndex(_ layout: MLModelInstallLayout) async throws {
        let store = try requireStore(
            SQLiteMLDerivedPipelineStore(url: layout.derivedIndexDatabaseURL, cipher: FixtureDerivedCipher()),
            "native index")
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "synthetic",
            capabilitySnapshot: .init(
                providerIdentifier: "synthetic.vision", sdkIdentifier: "synthetic",
                capabilities: [
                    .init(
                        kind: .textRecognition, implementationIdentifier: "synthetic.ocr", availability: .available,
                        selectedRevision: "r1", supportedRevisions: ["r1"])
                ]))
        let executor = FixtureNativeExecutor()
        let runtime = MLNativeSearchRuntime(
            configuration: configuration, store: store, executor: executor, runnerConfiguration: .init(chunkSize: 2))
        let revisions = try assets.map { try MLPipelineAssetRevision(uid: $0, sourceRevision: "r1") }
        let result = await runtime.index(assets: revisions, shouldContinue: { true })
        try fixtureRequire(result.reason == .drained, "Native indexing did not resume")
        let found = await runtime.search("synthetic", scope: .text, limit: 20)
        try fixtureRequire(Set(found) == Set(assets), "Native index lost searchable assets")
        try fixtureRequire(executor.calls <= assets.count, "Native recovery repeated more than one inventory")
        await runtime.shutdown()
        store.close()
    }

    static let cacheBytes = Data((0..<131_072).map { UInt8($0 % 251) })
    static func cache(_ root: URL, recording: Bool) throws {
        let directory = try directory(root, "Caches")
        for namespace in ["thumbnails", "previews"] {
            let cache = ThumbnailCache(namespace: namespace, rootDirectory: directory)
            cache.configure(accountUID: "synthetic", key: key)
            for uid in assets.prefix(2) {
                let expected = uid.nodeID == "asset-0" ? Data(cacheBytes.prefix(1024)) : cacheBytes
                if recording { cache.storeToDisk(expected, for: uid) }
                if let bytes = cache.diskData(for: uid) {
                    try fixtureRequire(bytes == expected, "Partial cache bytes were returned")
                } else if !recording {
                    try fixtureRequire(
                        !FileManager.default.fileExists(atPath: cache.diskURL(for: uid).path),
                        "Unreadable cache file was not discarded")
                }
            }
        }
    }

    static func location(_ root: URL, recording: Bool) async throws {
        let store = PhotoLocationStore(directory: try directory(root, "Locations"))
        store.configure(accountUID: "synthetic", key: key)
        let snapshot = store.loadSnapshot()
        let index = await PhotoLocationIndex()
        await index.replaceAll(snapshot)
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 1, saveEvery: 1)
        await crawl.start(
            uids: assets, captureDates: [:],
            location: { uid in
                if recording && uid.nodeID == "asset-7" { return .failed(category: "synthetic-retry") }
                return uid.nodeID == "asset-0" ? .found(latitude: 0.25, longitude: 0.5) : .noLocation
            }, index: index, store: store)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await index.scanProgress.phase == .completed { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await crawl.cancel()
        if !recording {
            try fixtureRequire(
                store.loadSnapshot().coordinates.count + store.loadSnapshot().noLocationUIDs.count == assets.count,
                "Location crawl did not resume")
        }
    }
}

struct FixtureOracle: Codable, Sendable {
    struct Complete: Codable, Sendable {
        var identifier: String
        var resource: String
        var revision: Int64
        var resourceCount: Int
    }
    struct Link: Codable, Sendable {
        var id: String
        var name: String
        var hash: String
        var mainID: String? = nil
    }
    var generation = 1
    var remote: [Link] = []
    var complete: [Complete] = []
    var queueKeys: Set<String> = []
    var unreadableStores: [String]? = nil
    var queueStates: [String]? = nil
    var externalURL: URL? = nil
    enum CodingKeys: String, CodingKey { case generation, remote, complete, queueKeys, unreadableStores, queueStates }
}

final class FixtureLibrary: UploadBackupAssetCatalog, PhotoLibraryAssetEnumerator, BackupResourceResolving,
    @unchecked Sendable
{
    let directory: URL
    var generation: Int
    init(directory: URL, generation: Int) {
        self.directory = directory
        self.generation = generation
    }
    func info(_ id: Int) -> PhotoBackupAssetInfo {
        let edited = id == 0 && generation == 2
        var info = PhotoBackupAssetInfo(
            localIdentifier: "asset-\(id)", creationDate: FixtureWorkloads.now.addingTimeInterval(-1000),
            modificationDate: FixtureWorkloads.now.addingTimeInterval(Double(generation)), pixelWidth: 10,
            pixelHeight: 10, durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "Synthetic-\(id).HEIC", mimeType: "image/heic")]
                + (edited ? [.init(role: .fullSizePhoto, originalFilename: "Render.JPG", mimeType: "image/jpeg")] : []))
        #if !UPGRADE_RECORDING
            info.hasAdjustments = edited
            info.adjustmentTimestamp = edited ? FixtureWorkloads.now.addingTimeInterval(-100) : nil
        #endif
        return info
    }
    var allCandidates: [UploadBackupAssetCandidate] {
        (0..<4).compactMap { PhotoBackupAssetPlanner.candidate(for: info($0)) }
    }
    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        AsyncThrowingStream { c in
            allCandidates.forEach { c.yield($0) }
            c.finish()
        }
    }
    func infoChunks(
        identifiers: [String]?, startOffset: Int, chunkSize: Int
    ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        let rows = (0..<4).map(info).filter { identifiers?.contains($0.localIdentifier) ?? true }.dropFirst(startOffset)
        return AsyncThrowingStream { c in
            c.yield(Array(rows))
            c.finish()
        }
    }
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard let id = Int(entry.source.identifier.dropFirst(6)), (0..<4).contains(id),
            let candidate = PhotoBackupAssetPlanner.candidate(for: info(id)),
            let plan = PhotoBackupAssetPlanner.exportPlan(for: info(id))
        else { return nil }
        func descriptor(_ item: PhotoBackupExportPlan.Item) throws -> UploadResourceDescriptor {
            let bytes = Data("synthetic-\(id)-\(item.role == .fullSizePhoto ? 2 : 1)".utf8)
            let url = directory.appendingPathComponent("asset-\(id)-\(item.role.rawValue)")
            try bytes.write(to: url)
            return UploadResourceDescriptor(
                source: .init(
                    kind: .photoLibraryAsset, identifier: entry.source.identifier, resource: item.sourceResource),
                fileURL: url, filename: item.uploadFilename, fileSize: Int64(bytes.count),
                modificationDate: FixtureWorkloads.now.addingTimeInterval(-1000),
                precomputedSHA1Digest: Data(Insecure.SHA1.hash(data: bytes)))
        }
        let secondaries = try plan.secondaries.map {
            BackupSecondaryResource(descriptor: try descriptor($0), mediaType: $0.mimeType ?? "image/heic")
        }
        return BackupResolvedResource(
            candidate: candidate, descriptor: try descriptor(plan.primary),
            mediaType: plan.primary.mimeType ?? "image/heic",
            captureDate: FixtureWorkloads.now.addingTimeInterval(-1000), secondaries: secondaries)
    }
}

final class FixtureBackend: PhotoUploading, UploadDuplicateChecking, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private var links: [FixtureOracle.Link]
    private let oracleURL: URL?
    var generation: Int
    var failNext = false
    private(set) var duplicateUploads = 0
    init(links: [FixtureOracle.Link], oracleURL: URL?, generation: Int) {
        self.links = links
        self.oracleURL = oracleURL
        self.generation = generation
    }
    func publish(generation: Int) throws {
        self.generation = generation
        if let oracleURL {
            try JSONEncoder().encode(FixtureOracle(generation: generation, remote: links)).write(
                to: oracleURL)
        }
    }
    func nameHash(forCorrectedName name: String) async throws -> String { name }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { sha1Hex }
    func hashKeyEpoch() async throws -> String { "synthetic-epoch" }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock { links.filter { nameHashes.contains($0.name) }.map(duplicate) }
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        lock.withLock { links.first { $0.hash == contentHash }.map(duplicate) }
    }
    func duplicate(_ link: FixtureOracle.Link) -> RemotePhotoDuplicate {
        .init(nameHash: link.name, contentHash: link.hash, linkState: .active, linkID: link.id)
    }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        lock.withLock { Set(links.filter { $0.mainID == mainLinkID }.map(\.id)) }
    }
    func findDuplicates(contentHash: String, limit: Int) async throws -> [RemotePhotoDuplicate] {
        lock.withLock { links.filter { $0.hash == contentHash }.prefix(limit).map(duplicate) }
    }
    #if !UPGRADE_RECORDING || UPGRADE_HISTORICAL_LINK_VISIBILITY
        func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
            lock.withLock {
                Dictionary(
                    uniqueKeysWithValues: links.filter { linkIDs.contains($0.id) }.map {
                        ($0.id, .init(isActive: true, mainPhotoLinkID: $0.mainID, trashTime: nil))
                    })
            }
        }
    #endif
    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        if failNext {
            failNext = false
            throw URLError(.networkConnectionLost)
        }
        onProgress(.init(phase: .uploading, fraction: 0.5))
        let bytes = try Data(contentsOf: request.fileURL)
        let hash = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let link = lock.withLock {
            if links.contains(where: { $0.hash == hash && $0.mainID == request.mainPhotoUID?.nodeID }) {
                duplicateUploads += 1
            }
            let link = FixtureOracle.Link(
                id: "remote-\(links.count)", name: request.name, hash: hash, mainID: request.mainPhotoUID?.nodeID)
            links.append(link)
            return link
        }
        // Persist the external server commit before the local runner can settle its queue row.
        try publish(generation: generation)
        onProgress(.init(phase: .uploading, fraction: 1))
        return PhotoUID(volumeID: "synthetic", nodeID: link.id)
    }
    func cancel(token: UUID) async {}
}

final class FixtureTransport: MLModelArtifactTransport, @unchecked Sendable {
    var interruptFirst: Bool
    init(interruptFirst: Bool) { self.interruptFirst = interruptFirst }
    func download(
        from url: URL, to destination: URL, expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws {
        try fixtureRequire(url.host == "example.test", "Unexpected fixture transport URL")
        // Model-server double streams chunks. Production installer verifies every completed artifact.
        try Data().write(to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for offset in stride(from: 0, to: FixtureWorkloads.payload.count, by: 4096) {
            try handle.write(contentsOf: FixtureWorkloads.payload[offset..<offset + 4096])
            await progress(Int64(offset + 4096), expectedByteCount)
            if interruptFirst {
                interruptFirst = false
                throw URLError(.networkConnectionLost)
            }
        }
    }
}

final class FixtureRuntime: MLSmartSearchRuntimeProvider, MLAssetEmbedder, MLTextQueryEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invalidLoads = 0
    private(set) var embeddings = 0
    func makeSession(
        model: MLInstalledModel, store: any MLIndexStore, shouldContinueIndexing: @escaping @Sendable () -> Bool
    ) async throws -> any MLSmartSearchSession {
        let bytes = try Data(contentsOf: model.installDirectory.appendingPathComponent("Model.mlmodelc/weights.bin"))
        if bytes != FixtureWorkloads.payload {
            lock.withLock { invalidLoads += 1 }
            throw FixtureFailure(description: "Partial model activated")
        }
        return MLSearchService(
            descriptor: model.entry.descriptor, store: store, assetEmbedder: self, textEncoder: self,
            scorer: ReferenceDotProductScorer(), runnerConfiguration: .init(chunkSize: 2),
            shouldContinue: shouldContinueIndexing)
    }
    func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
        lock.withLock { embeddings += 1 }
        return .embedded([1, 0, 0, 0])
    }
    func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> { [1, 0, 0, 0] }
}

struct FixtureVectorCipher: MLVectorCipher {
    func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
        try AES.GCM.seal(plaintext, using: FixtureWorkloads.key).combined!
    }
    func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: FixtureWorkloads.key)
    }
    func sealedByteCount(forPlaintextByteCount count: Int) -> Int? { count + 28 }
}

final class FixtureNativeExecutor: MLDerivedPipelineExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        lock.withLock { count += plan.workItems.count }
        return plan.workItems.map {
            .init(
                workItem: $0,
                outcome: .completed(
                    .init(
                        payload: Data("synthetic fixture text".utf8), normalizedSearchTokens: ["synthetic", "fixture"]))
            )
        }
    }
}

struct FixtureDerivedCipher: MLDerivedDataCipher {
    func seal(_ plaintext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        try AES.GCM.seal(plaintext, using: FixtureWorkloads.key).combined!
    }
    func open(_ ciphertext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: FixtureWorkloads.key)
    }
    func tokenDigest(normalizedToken: String, accountIdentifier: String, artifactNamespace: String) throws -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: Data("\(accountIdentifier)|\(artifactNamespace)|\(normalizedToken)".utf8),
                using: FixtureWorkloads.key))
    }
}
