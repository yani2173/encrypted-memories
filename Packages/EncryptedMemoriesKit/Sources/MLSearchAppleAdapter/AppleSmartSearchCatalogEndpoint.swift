import Foundation

/// Catalog channel selected by the Apple composition layer.
public enum AppleSmartSearchCatalogChannel: String, Sendable, Equatable {
    case production
    case preview
}

public enum AppleSmartSearchCatalogEndpointError: Error, Equatable {
    case invalidPreviewBaseURL
}

/// Validated catalog and artifact URLs for one Smart Search channel.
public struct AppleSmartSearchCatalogEndpoint: Sendable, Equatable {
    public static let previewEnvironmentKey = "ENCRYPTED_MEMORIES_ML_PREVIEW_BASE_URL"

    public let channel: AppleSmartSearchCatalogChannel
    /// Directory URL containing model ID and revision directories.
    public let artifactBaseURL: URL

    public var catalogRootURL: URL { artifactBaseURL.deletingLastPathComponent() }
    public var activePairURL: URL { catalogRootURL.appendingPathComponent("active-pair.json") }
    public var catalogV2SignatureURL: URL { catalogRootURL.appendingPathComponent("catalog-v2.sig") }

    public var smartSearchRootDirectoryName: String {
        switch channel {
        case .production:
            return AppleSmartSearchBootstrap.rootDirectoryName
        case .preview:
            return "SmartSearch-MLPreview"
        }
    }

    public var catalogCacheDirectoryName: String {
        switch channel {
        case .production:
            return "MLModelCatalog"
        case .preview:
            return "MLModelCatalog-MLPreview"
        }
    }

    /// The production endpoint remains the existing public model directory.
    public static let production = Self(
        uncheckedChannel: .production,
        artifactBaseURL: SignedRemoteMLModelCatalogProvider.artifactBaseURL
    )

    /// Creates a preview endpoint after validating its complete directory URL.
    public init(previewBaseURL: URL) throws {
        guard Self.isValidPreviewBaseURL(previewBaseURL) else {
            throw AppleSmartSearchCatalogEndpointError.invalidPreviewBaseURL
        }
        self.init(uncheckedChannel: .preview, artifactBaseURL: previewBaseURL)
    }

    /// Creates an endpoint for a known channel. Production uses the fixed endpoint above.
    public init(channel: AppleSmartSearchCatalogChannel, artifactBaseURL: URL) throws {
        switch channel {
        case .production:
            guard artifactBaseURL == Self.production.artifactBaseURL else {
                throw AppleSmartSearchCatalogEndpointError.invalidPreviewBaseURL
            }
        case .preview:
            guard Self.isValidPreviewBaseURL(artifactBaseURL) else {
                throw AppleSmartSearchCatalogEndpointError.invalidPreviewBaseURL
            }
        }
        self.init(uncheckedChannel: channel, artifactBaseURL: artifactBaseURL)
    }

    /// Resolves the Debug-only launch environment. Invalid values use production composition.
    public static func debugEndpoint(environment: [String: String]) -> Self {
        guard let rawValue = environment[previewEnvironmentKey],
            !rawValue.isEmpty,
            let previewURL = URL(string: rawValue),
            let endpoint = try? Self(previewBaseURL: previewURL)
        else {
            return .production
        }
        return endpoint
    }

    private init(uncheckedChannel channel: AppleSmartSearchCatalogChannel, artifactBaseURL: URL) {
        self.channel = channel
        self.artifactBaseURL = artifactBaseURL
    }

    private static func isValidPreviewBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.hasSuffix("/models/"),
            url.absoluteString.hasSuffix("/models/")
        else {
            return false
        }
        return true
    }
}
