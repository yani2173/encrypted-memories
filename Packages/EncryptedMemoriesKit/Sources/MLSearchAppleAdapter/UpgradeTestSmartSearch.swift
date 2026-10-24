#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import CryptoKit
    import Foundation
    import MLSearchCore
    import PhotosCore

    /// Synthetic inference and a loopback catalog use the real installer, state store and index runner.
    enum UpgradeTestSmartSearch {
        static let payload = Data(repeating: 0xA7, count: 16_384)

        static func makeLifecycle(
            accountDirectory: URL, accountUID: String, keyPassword: String,
            assetsProvider: @escaping @Sendable () async -> MLAssetInventorySnapshot,
            databasePolicy: LibraryDatabasePolicy
        ) -> MLSmartSearchLifecycle {
            let artifact = MLModelArtifactSpec(
                relativePath: "Model.mlmodelc/weights.bin",
                sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                byteCount: Int64(payload.count))
            let entry = MLModelCatalogEntry(
                id: MLModelID("synthetic-model"), displayName: "Synthetic fixture", family: "Fixture",
                descriptor: .init(identifier: "synthetic-model", version: 1, embeddingDimension: 4),
                tokenizerID: "synthetic", preprocessingID: "synthetic", license: .mit, releaseTrack: .production,
                estimatedInstalledBytes: Int64(payload.count),
                downloadPlan: .init(
                    revision: "r1",
                    items: [.init(url: UpgradeTestProbe.endpoint.appendingPathComponent("model"), artifact: artifact)]))
            let layout = MLModelInstallLayout(
                rootDirectory: accountDirectory.appendingPathComponent(AppleSmartSearchBootstrap.rootDirectoryName))
            let cipher = CryptoKitMLVectorCipher(
                key: MLSearchKeyDerivation.localIndexKey(accountUID: accountUID, keyPassword: keyPassword),
                accountUID: accountUID)
            return MLSmartSearchLifecycle(
                dependencies: .init(
                    catalog: .init(entries: [entry]), layout: layout,
                    stateStore: FileMLSmartSearchStateStore(layout: layout),
                    installer: MLModelInstaller(layout: layout, transport: URLSessionMLModelArtifactTransport()),
                    storeProvider: SQLiteMLIndexStoreProvider(
                        url: layout.indexDatabaseURL, policy: databasePolicy, cipher: cipher),
                    runtimeProvider: UpgradeTestRuntime(), assetsProvider: assetsProvider,
                    governor: MLAlwaysPermitsIndexing(), allowsDeveloperModels: false, featureAvailability: .available))
        }
    }

    struct UpgradeTestRuntime: MLSmartSearchRuntimeProvider, MLAssetEmbedder, MLTextQueryEncoder {
        func makeSession(
            model: MLInstalledModel, store: any MLIndexStore, shouldContinueIndexing: @escaping @Sendable () -> Bool
        ) async throws -> any MLSmartSearchSession {
            let bytes = try Data(
                contentsOf: model.installDirectory.appendingPathComponent("Model.mlmodelc/weights.bin"))
            guard bytes == UpgradeTestSmartSearch.payload else { throw URLError(.cannotDecodeContentData) }
            UpgradeTestProbe.checkpoint("model.activated")
            return MLSearchService(
                descriptor: model.entry.descriptor, store: store, assetEmbedder: self, textEncoder: self,
                scorer: ReferenceDotProductScorer(), runnerConfiguration: .init(chunkSize: 2),
                shouldContinue: shouldContinueIndexing)
        }

        func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
            UpgradeTestProbe.checkpoint("index.embed")
            return .embedded([1, 0, 0, 0])
        }

        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            UpgradeTestProbe.checkpoint("query.encoded")
            return [1, 0, 0, 0]
        }
    }
#endif
