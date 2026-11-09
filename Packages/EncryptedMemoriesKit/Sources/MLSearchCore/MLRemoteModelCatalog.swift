import Foundation

public protocol MLModelCatalogProvider: Sendable {
    func catalog() async throws -> MLModelCatalog
}

public struct StaticMLModelCatalogProvider: MLModelCatalogProvider {
    private let value: MLModelCatalog

    public init(_ value: MLModelCatalog) {
        self.value = value
    }

    public func catalog() async throws -> MLModelCatalog { value }
}

/// Small signed JSON document published beside immutable model artifacts.
/// Only distribution data is remote; runtime and licensing contracts remain app-reviewed.
public struct MLRemoteModelCatalogDocument: Sendable, Equatable, Codable {
    public static let supportedSchemaVersion = 1

    public struct Model: Sendable, Equatable, Codable {
        public let id: MLModelID
        public let revision: String
        public let artifacts: [Artifact]
        /// Optional external release evidence. Availability is defined by the trusted app contract
        /// plus the signed immutable download plan, not by this diagnostic metadata.
        public let qualification: MLModelReleaseQualification?

        public init(
            id: MLModelID,
            revision: String,
            artifacts: [Artifact],
            qualification: MLModelReleaseQualification? = nil
        ) {
            self.id = id
            self.revision = revision
            self.artifacts = artifacts
            self.qualification = qualification
        }
    }

    public struct Artifact: Sendable, Equatable, Codable {
        public let path: String
        public let url: URL
        public let sha256: String
        public let bytes: Int64

        public init(path: String, url: URL, sha256: String, bytes: Int64) {
            self.path = path
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public let schemaVersion: Int
    public let models: [Model]

    public init(schemaVersion: Int = supportedSchemaVersion, models: [Model]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }
}

/// Signed catalog used by clients that shipped the compatibility registry.
///
/// The document contains only a recipe key and bounded descriptor/distribution metadata. It does
/// not carry runtime factories, tokenizer definitions, preprocessing code, or product copy.
public struct MLRemoteModelCatalogDocumentV2: Sendable, Equatable, Codable {
    public static let supportedSchemaVersion = 2

    public enum Availability: String, Sendable, Equatable, Codable {
        case active
        case retired
    }

    public struct Descriptor: Sendable, Equatable, Codable {
        public let identifier: String
        public let version: Int
        public let embeddingDimension: Int

        public init(identifier: String, version: Int, embeddingDimension: Int) {
            self.identifier = identifier
            self.version = version
            self.embeddingDimension = embeddingDimension
        }
    }

    public struct Model: Sendable, Equatable, Codable {
        public let id: MLModelID
        /// Missing values retain the active meaning for older signed catalogs.
        public let availability: Availability?
        public let compatibilityKey: String
        public let releaseSequence: UInt64
        public let revision: String
        public let descriptor: Descriptor
        public let sourceRevision: String
        public let licenseIdentifier: String
        public let role: String
        public let capabilities: [String]
        public let artifacts: [MLRemoteModelCatalogDocument.Artifact]
        public let qualification: MLModelReleaseQualification?

        public init(
            id: MLModelID,
            availability: Availability? = nil,
            compatibilityKey: String,
            releaseSequence: UInt64,
            revision: String,
            descriptor: Descriptor,
            sourceRevision: String,
            licenseIdentifier: String,
            role: String,
            capabilities: [String],
            artifacts: [MLRemoteModelCatalogDocument.Artifact],
            qualification: MLModelReleaseQualification? = nil
        ) {
            self.id = id
            self.availability = availability
            self.compatibilityKey = compatibilityKey
            self.releaseSequence = releaseSequence
            self.revision = revision
            self.descriptor = descriptor
            self.sourceRevision = sourceRevision
            self.licenseIdentifier = licenseIdentifier
            self.role = role
            self.capabilities = capabilities
            self.artifacts = artifacts
            self.qualification = qualification
        }
    }

    public let schemaVersion: Int
    public let catalogSequence: UInt64
    public let models: [Model]

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        catalogSequence: UInt64,
        models: [Model]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogSequence = catalogSequence
        self.models = models
    }
}

public enum MLRemoteModelCatalogError: Error, Equatable {
    case unsupportedSchema(Int)
    case duplicateModel(String)
    case unknownModel(String)
    case invalidRevision(String)
    case noArtifacts(String)
    case duplicateArtifact(String)
    case unsafeArtifactPath(String)
    case invalidArtifactURL(String)
    case invalidHash(String)
    case invalidModelLayout(String)
    case missingRuntimeResource(String)
    case unknownCompatibilityRecipe(String)
    case unsafeModelID(String)
    case modelIDCollision(String)
    case invalidRole(String)
    case invalidCapability(String)
    case invalidSourceRevision(String)
    case invalidLicense(String)
    case descriptorMismatch(String)
    case artifactSizeExceeded(String)
    case recipeContractMismatch(String)
    case invalidCatalogSequence
    case invalidModelReleaseSequence(String)
}

/// Resolves untrusted distribution JSON against the app's trusted compatibility registry.
public struct MLRemoteModelCatalogResolver: Sendable {
    private let trustedCatalog: MLModelCatalog
    private let allowedBaseURL: URL
    private let compatibilityRegistry: MLModelCompatibilityRegistry

    public init(
        trustedCatalog: MLModelCatalog,
        allowedBaseURL: URL,
        compatibilityRegistry: MLModelCompatibilityRegistry = .builtIn
    ) {
        self.trustedCatalog = trustedCatalog
        self.allowedBaseURL = allowedBaseURL
        self.compatibilityRegistry = compatibilityRegistry
    }

    public func resolve(_ document: MLRemoteModelCatalogDocument) throws -> MLModelCatalog {
        guard document.schemaVersion == MLRemoteModelCatalogDocument.supportedSchemaVersion else {
            throw MLRemoteModelCatalogError.unsupportedSchema(document.schemaVersion)
        }

        var seenModels: Set<MLModelID> = []
        var distributions: [MLModelID: (MLModelDownloadPlan, MLModelReleaseQualification?)] = [:]
        for remote in document.models {
            guard seenModels.insert(remote.id).inserted else {
                throw MLRemoteModelCatalogError.duplicateModel(remote.id.rawValue)
            }
            guard let trusted = trustedCatalog.entry(for: remote.id),
                trusted.license.allowsRedistribution,
                trusted.license.allowsProductUse
            else {
                throw MLRemoteModelCatalogError.unknownModel(remote.id.rawValue)
            }
            guard Self.isSafeRevision(remote.revision) else {
                throw MLRemoteModelCatalogError.invalidRevision(remote.revision)
            }
            guard !remote.artifacts.isEmpty else {
                throw MLRemoteModelCatalogError.noArtifacts(remote.id.rawValue)
            }
            guard let compatibilityKey = trusted.compatibilityKey,
                let recipe = compatibilityRegistry.recipe(for: compatibilityKey),
                recipe.matches(trusted)
            else {
                throw MLRemoteModelCatalogError.unknownCompatibilityRecipe(
                    trusted.compatibilityKey ?? remote.id.rawValue
                )
            }
            let plan = try makePlan(
                id: remote.id,
                revision: remote.revision,
                artifacts: remote.artifacts,
                recipe: recipe
            )
            distributions[remote.id] = (plan, remote.qualification)
        }

        return MLModelCatalog(
            entries: trustedCatalog.entries.map { entry in
                let distribution = distributions[entry.id]
                return entry.withDistribution(
                    distribution?.0,
                    qualification: distribution?.1
                )
            })
    }

    /// Resolve a v2 document against the finite app-shipped compatibility registry.
    public func resolve(_ document: MLRemoteModelCatalogDocumentV2) throws -> MLModelCatalog {
        guard document.schemaVersion == MLRemoteModelCatalogDocumentV2.supportedSchemaVersion else {
            throw MLRemoteModelCatalogError.unsupportedSchema(document.schemaVersion)
        }
        guard document.catalogSequence > 0 else {
            throw MLRemoteModelCatalogError.invalidCatalogSequence
        }

        var seenModels: Set<MLModelID> = []
        var resolvedEntries: [MLModelCatalogEntry] = []
        for remote in document.models {
            guard seenModels.insert(remote.id).inserted else {
                throw MLRemoteModelCatalogError.duplicateModel(remote.id.rawValue)
            }
            guard Self.isSafeModelID(remote.id.rawValue) else {
                throw MLRemoteModelCatalogError.unsafeModelID(remote.id.rawValue)
            }
            guard !remote.compatibilityKey.isEmpty else {
                throw MLRemoteModelCatalogError.unknownCompatibilityRecipe(remote.compatibilityKey)
            }
            // A model family from a newer app release. Skipping it keeps this catalog, and with it every
            // later update of the known models; rejecting the whole document would freeze this app.
            guard let recipe = compatibilityRegistry.recipe(for: remote.compatibilityKey) else { continue }
            guard remote.releaseSequence > 0 else {
                throw MLRemoteModelCatalogError.invalidModelReleaseSequence(remote.id.rawValue)
            }
            guard Self.isSafeRevision(remote.revision) else {
                throw MLRemoteModelCatalogError.invalidRevision(remote.revision)
            }
            guard Self.isImmutableSourceRevision(remote.sourceRevision) else {
                throw MLRemoteModelCatalogError.invalidSourceRevision(remote.id.rawValue)
            }
            guard remote.licenseIdentifier == recipe.license.identifier else {
                throw MLRemoteModelCatalogError.invalidLicense(remote.id.rawValue)
            }
            guard let role = MLModelRole(rawValue: remote.role), role == recipe.role else {
                throw MLRemoteModelCatalogError.invalidRole(remote.id.rawValue)
            }
            var capabilities: Set<MLModelCapability> = []
            for rawCapability in remote.capabilities {
                guard let capability = MLModelCapability(rawValue: rawCapability) else {
                    throw MLRemoteModelCatalogError.invalidCapability(rawCapability)
                }
                guard capabilities.insert(capability).inserted else {
                    throw MLRemoteModelCatalogError.invalidCapability(rawCapability)
                }
            }
            guard capabilities == recipe.capabilities else {
                throw MLRemoteModelCatalogError.invalidCapability(remote.id.rawValue)
            }
            let descriptor = MLModelDescriptor(
                identifier: remote.descriptor.identifier,
                version: remote.descriptor.version,
                embeddingDimension: remote.descriptor.embeddingDimension
            )
            guard remote.descriptor.identifier == remote.id.rawValue,
                recipe.accepts(descriptor: descriptor)
            else {
                throw MLRemoteModelCatalogError.descriptorMismatch(remote.id.rawValue)
            }

            let trusted = trustedCatalog.entry(for: remote.id)
            if let trusted {
                guard trusted.compatibilityKey == remote.compatibilityKey else {
                    throw MLRemoteModelCatalogError.modelIDCollision(remote.id.rawValue)
                }
                guard recipe.matches(trusted) else {
                    throw MLRemoteModelCatalogError.recipeContractMismatch(remote.id.rawValue)
                }
            }

            guard !remote.artifacts.isEmpty else {
                throw MLRemoteModelCatalogError.noArtifacts(remote.id.rawValue)
            }
            let plan = try makePlan(
                id: remote.id,
                revision: remote.revision,
                artifacts: remote.artifacts,
                recipe: recipe
            )
            // A retired model stays in the catalog, so a person who uses it keeps search; it is never offered anew.
            resolvedEntries.append(
                MLModelCatalogEntry(
                    id: remote.id,
                    compatibilityKey: remote.compatibilityKey,
                    displayName: trusted?.displayName ?? recipe.family,
                    family: recipe.family,
                    role: recipe.role,
                    capabilities: recipe.capabilities,
                    sourceRevision: remote.sourceRevision,
                    descriptor: descriptor,
                    tokenizerID: recipe.tokenizerID,
                    preprocessingID: recipe.preprocessingID,
                    runtimeContract: recipe.runtimeContract,
                    relevancePolicy: recipe.relevancePolicy,
                    runtimeResourcePaths: recipe.runtimeResourcePaths,
                    license: recipe.license,
                    releaseTrack: recipe.releaseTrack,
                    localizedMetadata: recipe.localizedMetadata,
                    estimatedInstalledBytes: recipe.estimatedInstalledBytes,
                    downloadPlan: plan,
                    releaseQualification: remote.qualification,
                    isRetired: remote.availability == .retired
                ))
        }

        let resolvedIDs = Set(resolvedEntries.map(\.id))
        let legacyEntries = trustedCatalog.entries.filter { !resolvedIDs.contains($0.id) }
        return MLModelCatalog(entries: legacyEntries + resolvedEntries)
    }

    private func makePlan(
        id: MLModelID,
        revision: String,
        artifacts: [MLRemoteModelCatalogDocument.Artifact],
        recipe: MLModelCompatibilityRecipe
    ) throws -> MLModelDownloadPlan {
        var seenPaths: Set<String> = []
        var modelRoots: Set<String> = []
        var items: [MLModelDownloadPlan.Item] = []
        for artifact in artifacts {
            guard seenPaths.insert(artifact.path).inserted else {
                throw MLRemoteModelCatalogError.duplicateArtifact(artifact.path)
            }
            guard MLModelInstallLayout.isSafeRelativePath(artifact.path) else {
                throw MLRemoteModelCatalogError.unsafeArtifactPath(artifact.path)
            }
            guard isAllowedArtifactURL(artifact.url) else {
                throw MLRemoteModelCatalogError.invalidArtifactURL(artifact.url.absoluteString)
            }
            let hash = artifact.sha256
            guard hash.count == 64,
                hash.allSatisfy({ $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" })
            else {
                throw MLRemoteModelCatalogError.invalidHash(artifact.path)
            }
            guard artifact.bytes > 0,
                artifact.bytes <= recipe.maximumArtifactFileBytes
            else {
                throw MLRemoteModelCatalogError.artifactSizeExceeded(artifact.path)
            }
            let firstComponent = artifact.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if firstComponent.lowercased().hasSuffix(".mlmodelc")
                || firstComponent.lowercased().hasSuffix(".mlpackage")
            {
                modelRoots.insert(firstComponent)
            }
            items.append(
                .init(
                    url: artifact.url,
                    artifact: .init(relativePath: artifact.path, sha256: hash, byteCount: artifact.bytes)
                ))
        }
        guard modelRoots.count == 1 else {
            throw MLRemoteModelCatalogError.invalidModelLayout(id.rawValue)
        }
        let modelRoot = modelRoots.first!
        guard seenPaths.contains(where: { $0.hasPrefix(modelRoot + "/") }) else {
            throw MLRemoteModelCatalogError.invalidModelLayout(id.rawValue)
        }
        let permittedSidecars = Set(recipe.runtimeResourcePaths)
        guard
            seenPaths.allSatisfy({ path in
                path == modelRoot || path.hasPrefix(modelRoot + "/") || permittedSidecars.contains(path)
            })
        else {
            throw MLRemoteModelCatalogError.invalidModelLayout(id.rawValue)
        }
        for resource in recipe.runtimeResourcePaths where !seenPaths.contains(resource) {
            throw MLRemoteModelCatalogError.missingRuntimeResource(resource)
        }
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.artifact.byteCount }
        guard totalBytes <= recipe.maximumArtifactBytes else {
            throw MLRemoteModelCatalogError.artifactSizeExceeded(id.rawValue)
        }
        return MLModelDownloadPlan(
            revision: revision, items: items.sorted { $0.artifact.relativePath < $1.artifact.relativePath })
    }

    private func isAllowedArtifactURL(_ url: URL) -> Bool {
        guard allowedBaseURL.scheme?.lowercased() == "https",
            allowedBaseURL.user == nil,
            allowedBaseURL.password == nil,
            allowedBaseURL.query == nil,
            allowedBaseURL.fragment == nil,
            url.scheme?.lowercased() == "https",
            url.host?.lowercased() == allowedBaseURL.host?.lowercased(),
            url.port == allowedBaseURL.port,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else { return false }
        let basePath = allowedBaseURL.path.hasSuffix("/") ? allowedBaseURL.path : allowedBaseURL.path + "/"
        return url.path.hasPrefix(basePath)
    }

    private static func isSafeModelID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
            isASCIILowercaseLetterOrDigit(bytes[0]),
            isASCIILowercaseLetterOrDigit(bytes[bytes.count - 1])
        else {
            return false
        }
        var previousSeparator = false
        for byte in bytes {
            guard isASCIILowercaseLetterOrDigit(byte) || byte == 0x2D else {
                return false
            }
            if byte == 0x2D {
                guard !previousSeparator else { return false }
                previousSeparator = true
            } else {
                previousSeparator = false
            }
        }
        return true
    }

    private static func isASCIILowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }

    private static func isSafeRevision(_ revision: String) -> Bool {
        guard !revision.isEmpty, revision.count <= 128 else { return false }
        return revision.utf8.allSatisfy { byte in
            byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
                || byte >= Character("A").asciiValue! && byte <= Character("Z").asciiValue!
                || byte >= Character("a").asciiValue! && byte <= Character("z").asciiValue!
                || byte == Character("-").asciiValue!
                || byte == Character("_").asciiValue!
        }
    }

    private static func isImmutableSourceRevision(_ revision: String) -> Bool {
        (revision.count == 40 || revision.count == 64)
            && revision.allSatisfy { character in
                character >= "0" && character <= "9" || character >= "a" && character <= "f"
            }
    }
}

private extension MLModelCompatibilityRecipe {
    func matches(_ entry: MLModelCatalogEntry) -> Bool {
        key == entry.compatibilityKey
            && family == entry.family
            && role == entry.role
            && capabilities == entry.capabilities
            && tokenizerID == entry.tokenizerID
            && preprocessingID == entry.preprocessingID
            && runtimeContract == entry.runtimeContract
            && embeddingDimension == entry.descriptor.embeddingDimension
            && descriptorVersionRange.contains(entry.descriptor.version)
            && runtimeResourcePaths == entry.runtimeResourcePaths
            && license == entry.license
            && relevancePolicy == entry.relevancePolicy
            && localizedMetadata == entry.localizedMetadata
            && estimatedInstalledBytes == entry.estimatedInstalledBytes
            && releaseTrack == entry.releaseTrack
    }
}
