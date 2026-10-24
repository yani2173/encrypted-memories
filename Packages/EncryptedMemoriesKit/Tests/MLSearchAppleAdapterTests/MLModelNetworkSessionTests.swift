import Foundation
import MLSearchCore
import Testing

@testable import MLSearchAppleAdapter

struct MLModelNetworkSessionTests {
    @Test func productionDownloadTransportKeepsNoURLCacheAndNoSharedStores() throws {
        try expectNoStoredResponses(URLSessionMLModelArtifactTransport().downloadConfiguration)
    }

    @Test func productionEndpointCatalogKeepsNoURLCacheAndNoSharedStores() async throws {
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: cacheDirectory,
            endpoint: .production
        )
        let configuration = await provider.sessionConfiguration
        try expectNoStoredResponses(configuration)
    }

    @Test func keyedEndpointCatalogKeepsNoURLCacheAndNoSharedStores() async throws {
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: cacheDirectory,
            endpoint: .production,
            publicKey: Data(repeating: 1, count: 32)
        )
        let configuration = await provider.sessionConfiguration
        try expectNoStoredResponses(configuration)
    }

    @Test func versionedCatalogKeepsNoURLCacheAndNoSharedStores() async throws {
        for version in [MLRemoteCatalogVersion.v1, .v2] {
            let provider = SignedRemoteMLModelCatalogProvider(
                trustedCatalog: .builtIn,
                cacheDirectory: cacheDirectory,
                version: version,
                catalogURL: SignedRemoteMLModelCatalogProvider.catalogURL,
                signatureURL: signatureURL,
                artifactBaseURL: SignedRemoteMLModelCatalogProvider.artifactBaseURL,
                publicKey: Data(repeating: 1, count: 32)
            )
            let configuration = await provider.sessionConfiguration
            try expectNoStoredResponses(configuration)
        }
    }

    @Test func explicitDownloadSessionPreservesItsConfiguration() {
        let session = customSession()
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMLModelArtifactTransport(session: session)
        expectCustomConfiguration(transport.downloadConfiguration, from: session)
    }

    @Test func explicitCatalogSessionPreservesItsConfiguration() async {
        let session = customSession()
        defer { session.invalidateAndCancel() }
        let providers = [
            SignedRemoteMLModelCatalogProvider(
                trustedCatalog: .builtIn, cacheDirectory: cacheDirectory,
                endpoint: .production, session: session
            ),
            SignedRemoteMLModelCatalogProvider(
                trustedCatalog: .builtIn, cacheDirectory: cacheDirectory,
                endpoint: .production, session: session, publicKey: Data(repeating: 1, count: 32)
            ),
            SignedRemoteMLModelCatalogProvider(
                trustedCatalog: .builtIn, cacheDirectory: cacheDirectory, version: .v2,
                session: session, catalogURL: SignedRemoteMLModelCatalogProvider.catalogURL,
                signatureURL: signatureURL,
                artifactBaseURL: SignedRemoteMLModelCatalogProvider.artifactBaseURL,
                publicKey: Data(repeating: 1, count: 32)
            ),
            SignedRemoteMLModelCatalogProvider(
                trustedCatalog: .builtIn, cacheDirectory: cacheDirectory,
                session: session, catalogURL: SignedRemoteMLModelCatalogProvider.catalogURL,
                signatureURL: signatureURL,
                artifactBaseURL: SignedRemoteMLModelCatalogProvider.artifactBaseURL,
                publicKey: Data(repeating: 1, count: 32)
            ),
        ]
        for provider in providers {
            let configuration = await provider.sessionConfiguration
            expectCustomConfiguration(configuration, from: session)
        }
    }

    private var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("model-session-\(UUID().uuidString)")
    }

    private var signatureURL: URL { URL(string: "https://models.oncloud.at/catalog-v1.sig")! }

    private func expectNoStoredResponses(_ configuration: URLSessionConfiguration) throws {
        #expect(configuration.urlCache == nil)
        let cookies = try #require(configuration.httpCookieStorage)
        #expect(cookies !== HTTPCookieStorage.shared)
        #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
    }

    private func customSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 4096, diskCapacity: 0)
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.timeoutIntervalForRequest = 17
        configuration.timeoutIntervalForResource = 43
        configuration.requestCachePolicy = .returnCacheDataDontLoad
        return URLSession(configuration: configuration)
    }

    private func expectCustomConfiguration(_ actual: URLSessionConfiguration, from session: URLSession) {
        let expected = session.configuration
        #expect(actual.urlCache === expected.urlCache)
        #expect(actual.httpCookieStorage === expected.httpCookieStorage)
        #expect(actual.timeoutIntervalForRequest == 17)
        #expect(actual.timeoutIntervalForResource == 43)
        #expect(actual.requestCachePolicy == .returnCacheDataDontLoad)
    }
}
