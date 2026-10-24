import CoreML
import Foundation
import MLSearchCore
import MediaFeedCore
import PhotosCore

/// Single composition point for the Smart Search stack on Apple platforms.
///
/// macOS and iOS/iPadOS call this with their session/feed and get the one universal lifecycle
/// actor back; every policy (catalog, layout, verification, encryption, scheduling gate) is
/// assembled here exactly once.
public enum AppleSmartSearchBootstrap {
    /// Directory name of the Smart Search root inside an account's data directory. Everything
    /// Smart Search persists lives under it; purge deletes it recursively.
    public static let rootDirectoryName = "SmartSearch"

    public static func smartSearchRoot(
        accountDirectory: URL,
        endpoint: AppleSmartSearchCatalogEndpoint = .production
    ) -> URL {
        accountDirectory.appendingPathComponent(endpoint.smartSearchRootDirectoryName, isDirectory: true)
    }

    public static func catalogCacheDirectory(
        accountDirectory: URL,
        endpoint: AppleSmartSearchCatalogEndpoint = .production
    ) -> URL {
        accountDirectory.appendingPathComponent(endpoint.catalogCacheDirectoryName, isDirectory: true)
    }

    private static var indexingCapacityProfile: MLIndexingCapacityProfile {
        #if os(macOS)
            .sustained
        #else
            .constrained
        #endif
    }

    /// Capability probe for Smart Search on Apple platforms. The feature ships with Apple Vision
    /// (no model download required); the optional semantic model runs on CPU/GPU/Neural Engine.
    public static func featureAvailability(
        tier: AppProductTier = .free,
        policy: AppFeaturePolicy = .production
    ) -> AppFeatureAvailability {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested { return .available }
        #endif
        let hasNeuralEngine = MLComputeDevice.allComputeDevices.contains { device in
            if case .neuralEngine = device { return true }
            return false
        }
        let capabilities = AppDeviceCapabilities(
            available: hasNeuralEngine ? [.neuralEngine] : [],
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        return policy.availability(of: .smartSearch, device: capabilities, tier: tier)
    }

    public static func makeLifecycle(
        accountDirectory: URL,
        accountUID: String,
        keyPassword: String,
        feed: ThumbnailFeedCore,
        assetsProvider: @escaping @Sendable () async -> MLAssetInventorySnapshot,
        allowsDeveloperModels: Bool,
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true },
        databasePolicy: LibraryDatabasePolicy = .conservative,
        catalog: MLModelCatalog = .builtIn,
        runnerConfiguration: MLIndexRunner.Configuration = .init(),
        catalogEndpoint: AppleSmartSearchCatalogEndpoint = .production
    ) -> MLSmartSearchLifecycle {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                return UpgradeTestSmartSearch.makeLifecycle(
                    accountDirectory: accountDirectory, accountUID: accountUID, keyPassword: keyPassword,
                    assetsProvider: assetsProvider, databasePolicy: databasePolicy)
            }
        #endif
        #if DEBUG
            let selectedCatalogEndpoint = catalogEndpoint
        #else
            let selectedCatalogEndpoint = AppleSmartSearchCatalogEndpoint.production
        #endif
        let layout = MLModelInstallLayout(
            rootDirectory: smartSearchRoot(accountDirectory: accountDirectory, endpoint: selectedCatalogEndpoint)
        )
        let workGate = AppleSmartSearchWorkGate(feed: feed, hostPermitsIndexing: hostPermitsIndexing)
        let cipher = CryptoKitMLVectorCipher(
            key: MLSearchKeyDerivation.localIndexKey(accountUID: accountUID, keyPassword: keyPassword),
            accountUID: accountUID
        )
        let derivedCipher = CryptoKitMLDerivedDataCipher(
            keys: MLSearchKeyDerivation.localDerivedDataKeys(
                accountUID: accountUID,
                keyPassword: keyPassword
            )
        )
        let imageSource = CachedThumbnailMLImageSource(feed: feed)
        let nativeSearchFactory: @Sendable () async -> (any MLNativeSearchServing)? = {
            let capabilitySnapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()
            var nativeRunnerConfiguration = runnerConfiguration
            nativeRunnerConfiguration.maximumConcurrentDerivedAssets =
                MLNativeAnalysisResourcePolicy.maximumConcurrentAssets(
                    capabilitySnapshot: capabilitySnapshot,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
                )
            guard
                let configuration = try? MLNativeSearchConfiguration(
                    accountIdentifier: accountUID,
                    capabilitySnapshot: capabilitySnapshot
                ),
                let store = SQLiteMLDerivedPipelineStore(
                    url: layout.derivedIndexDatabaseURL,
                    policy: databasePolicy,
                    cipher: derivedCipher
                )
            else { return nil }
            return MLNativeSearchRuntime(
                configuration: configuration,
                store: store,
                executor: AppleVisionPipelineExecutor(imageSource: imageSource),
                runnerConfiguration: nativeRunnerConfiguration
            )
        }
        let catalogProvider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: catalog,
            cacheDirectory: catalogCacheDirectory(
                accountDirectory: accountDirectory,
                endpoint: selectedCatalogEndpoint
            ),
            endpoint: selectedCatalogEndpoint,
            // Keep the replay floor when the user purges derived Smart Search data.
            legacyCacheDirectory: selectedCatalogEndpoint.channel == .production ? layout.rootDirectory : nil
        )
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: catalog,
                catalogProvider: catalogProvider,
                layout: layout,
                stateStore: FileMLSmartSearchStateStore(layout: layout),
                installer: MLModelInstaller(layout: layout, transport: URLSessionMLModelArtifactTransport()),
                storeProvider: SQLiteMLIndexStoreProvider(
                    url: layout.indexDatabaseURL, policy: databasePolicy, cipher: cipher),
                runtimeProvider: AppleSmartSearchRuntimeProvider(
                    imageSource: imageSource,
                    runnerConfiguration: runnerConfiguration
                ),
                assetsProvider: assetsProvider,
                nativeSearchFactory: nativeSearchFactory,
                advertisedNativeSearchBackends: [.recognizedText, .documentText],
                governor: MLClosureIndexingGovernor({ workGate.permitsIndexing() }),
                allowsDeveloperModels: allowsDeveloperModels,
                featureAvailability: featureAvailability(),
                indexingCapacityProfile: indexingCapacityProfile,
                releaseDerivedResources: { await imageSource.releaseMemory() },
                suggestionCache: MLSearchSuggestionCache(
                    layout: layout, accountIdentifier: accountUID, cipher: derivedCipher)
            ),
            initiallyAllowsIndexingExecution: !CoreMLComputePolicy.requiresCPUOnly
        )
        workGate.setIndexingWake { [weak lifecycle] in
            Task { await lifecycle?.noteConditionsChanged() }
        }
        return lifecycle
    }
}
