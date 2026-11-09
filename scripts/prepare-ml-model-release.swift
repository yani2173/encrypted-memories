#!/usr/bin/env swift
import CryptoKit
import Foundation

private struct CatalogArtifact: Codable, Equatable {
    let path: String
    let url: URL
    let sha256: String
    let bytes: Int64
}

private struct CatalogQualification: Codable, Equatable {
    let artifactRevision: String
    let hardwareModel: String
    let osVersion: String
    let peakResidentBytes: Int64
    let imageP95Milliseconds: Double
    let textP95Milliseconds: Double
    let reachedSeriousThermalState: Bool
    let neuralEngineExecutionVerified: Bool
    let passed: Bool

    init(_ qualification: Qualification) {
        artifactRevision = qualification.artifactRevision
        hardwareModel = qualification.hardwareModel
        osVersion = qualification.osVersion
        peakResidentBytes = qualification.peakResidentBytes
        imageP95Milliseconds = qualification.imageP95Milliseconds
        textP95Milliseconds = qualification.textP95Milliseconds
        reachedSeriousThermalState = qualification.reachedSeriousThermalState
        neuralEngineExecutionVerified = qualification.neuralEngineExecutionVerified
        passed = qualification.gates.allPassed
    }
}

private struct CatalogModelV1: Codable, Equatable {
    let id: String
    let revision: String
    let artifacts: [CatalogArtifact]
    let qualification: CatalogQualification?
}

private struct CatalogV1: Codable, Equatable {
    let schemaVersion: Int
    let models: [CatalogModelV1]

    init(models: [CatalogModelV1]) {
        schemaVersion = 1
        self.models = models
    }
}

private struct CatalogModelV2: Codable, Equatable {
    enum Availability: String, Codable {
        case active
        case retired
    }

    struct Descriptor: Codable, Equatable {
        let identifier: String
        let version: Int
        let embeddingDimension: Int
    }

    let id: String
    let availability: Availability?
    let compatibilityKey: String
    let releaseSequence: UInt64
    let revision: String
    let descriptor: Descriptor
    let sourceRevision: String
    let licenseIdentifier: String
    let role: String
    let capabilities: [String]
    let artifacts: [CatalogArtifact]
    let qualification: CatalogQualification?

    init(
        id: String,
        availability: Availability? = nil,
        compatibilityKey: String,
        releaseSequence: UInt64,
        revision: String,
        descriptor: Descriptor,
        sourceRevision: String,
        licenseIdentifier: String,
        role: String,
        capabilities: [String],
        artifacts: [CatalogArtifact],
        qualification: CatalogQualification?
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

private struct CatalogV2: Codable, Equatable {
    let schemaVersion: Int
    let catalogSequence: UInt64
    let models: [CatalogModelV2]

    init(catalogSequence: UInt64, models: [CatalogModelV2]) {
        schemaVersion = 2
        self.catalogSequence = catalogSequence
        self.models = models
    }
}

private struct Qualification: Codable {
    struct Gates: Codable {
        let sourceCoreMLNumerics: Bool
        let tokenizerCompatibility: Bool
        let searchQuality: Bool
        let modelTokenizerPair: Bool
        let licenseAndProvenance: Bool
        let artifactSizeAndDisk: Bool
        let runtimeMacOS: Bool
        let runtimeIOSPhysical: Bool

        var allPassed: Bool {
            sourceCoreMLNumerics && tokenizerCompatibility && searchQuality
                && modelTokenizerPair && licenseAndProvenance && artifactSizeAndDisk
                && runtimeMacOS && runtimeIOSPhysical
        }
    }

    let schemaVersion: Int
    let modelID: String
    let sourceRevision: String
    let artifactRevision: String
    let converterRevision: String
    let qualificationCorpusRevision: String
    let xcodeBuild: String
    let coremltoolsVersion: String
    let hardwareModel: String
    let osVersion: String
    let peakResidentBytes: Int64
    let imageP95Milliseconds: Double
    let textP95Milliseconds: Double
    let reachedSeriousThermalState: Bool
    let neuralEngineExecutionVerified: Bool
    let gates: Gates
}

private struct ArtifactManifest: Decodable {
    struct File: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let revision: String
    let tools: [String: String]
    let files: [File]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision, tools, files
    }
}

private struct ReleaseManifest: Decodable {
    let schemaVersion: Int
    let modelID: String
    let compatibilityKey: String
    let sourceRevision: String
    let descriptorVersion: Int
    let embeddingDimension: Int
    let role: String
    let capabilities: [String]
    let licenseIdentifier: String
}

private struct ReleaseEvidence: Codable {
    struct Rights: Codable {
        let productUse: Bool
        let commercialUse: Bool
        let modification: Bool
        let formatConversion: Bool
        let redistribution: Bool
        let appStoreDistribution: Bool

        var allGranted: Bool {
            productUse && commercialUse && modification && formatConversion
                && redistribution && appStoreDistribution
        }
    }

    let schemaVersion: Int
    let modelID: String
    let sourceRevision: String
    let sourceURL: URL
    let licenseIdentifier: String
    let licenseURL: URL
    let noticeSHA256: String
    let rights: Rights
}

private struct ReleaseEvidenceBundle: Encodable {
    let schemaVersion = 1
    let models: [ReleaseEvidence]
}

private struct ReleaseProvenance: Encodable {
    struct Entry: Encodable {
        let id: String
        let availability: CatalogModelV2.Availability?
        let compatibilityKey: String
        let sourceRevision: String
        let artifactRevision: String
        let artifacts: [CatalogArtifact]
        let qualification: CatalogQualification?
    }

    let schemaVersion = 1
    let repositoryRevision: String
    let releasedAt: String
    let catalogSequence: UInt64
    let models: [Entry]
}

private struct SPDXDocument: Encodable {
    struct Package: Encodable {
        private enum CodingKeys: String, CodingKey {
            case spdxID = "SPDXID"
            case name
            case versionInfo
            case downloadLocation
            case filesAnalyzed
            case licenseConcluded
            case licenseDeclared
            case copyrightText
        }

        let spdxID: String
        let name: String
        let versionInfo: String
        let downloadLocation: String
        let filesAnalyzed = false
        let licenseConcluded: String
        let licenseDeclared: String
        let copyrightText = "NOASSERTION"
    }

    let spdxVersion = "SPDX-2.3"
    let dataLicense = "CC0-1.0"
    let spdxID = "SPDXRef-DOCUMENT"
    let name: String
    let documentNamespace: String
    let creationInfo: [String: AnyEncodable]
    let packages: [Package]

    private enum CodingKeys: String, CodingKey {
        case spdxVersion
        case dataLicense
        case spdxID = "SPDXID"
        case name
        case documentNamespace
        case creationInfo
        case packages
    }
}

private struct ReleasePairManifest: Codable {
    struct File: Codable {
        let path: String
        let sha256: String
        let bytes: Int64
    }

    struct ModelRevision: Codable {
        let id: String
        let revision: String
        let availability: CatalogModelV2.Availability?
    }

    let schemaVersion: Int
    let catalogSequence: UInt64
    let repositoryRevision: String
    let releasedAt: String
    let files: [File]
    let models: [ModelRevision]

    init(
        catalogSequence: UInt64,
        repositoryRevision: String,
        releasedAt: String,
        files: [File],
        models: [ModelRevision]
    ) {
        schemaVersion = 1
        self.catalogSequence = catalogSequence
        self.repositoryRevision = repositoryRevision
        self.releasedAt = releasedAt
        self.files = files
        self.models = models
    }
}

private struct ActivePairObject: Codable, Equatable {
    let name: String
    let path: String
    let sha256: String
    let bytes: Int64
}

private struct ActivePairPayload: Codable, Equatable {
    let schemaVersion: Int
    let pairID: String
    let catalogSequence: UInt64
    let objects: [ActivePairObject]

    init(pairID: String, catalogSequence: UInt64, objects: [ActivePairObject]) {
        schemaVersion = 1
        self.pairID = pairID
        self.catalogSequence = catalogSequence
        self.objects = objects
    }
}

private struct ActivePairPointer: Codable, Equatable {
    let payload: ActivePairPayload
    let signature: String
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private struct PreparedArtifact {
    let catalog: CatalogArtifact
    let source: URL
}

private struct PreparedModel {
    let v1: CatalogModelV1?
    let v2: CatalogModelV2
    let artifacts: [PreparedArtifact]
    let qualification: Qualification
    let evidence: ReleaseEvidence
    let notice: String
}

private struct ModelInput {
    let id: String
    let directory: URL
}

private struct RetiredModelsManifest: Decodable {
    let schemaVersion: Int
    let modelIDs: [String]
}

private struct Options {
    let privateKey: URL
    let output: URL
    let bucket: String
    let rcloneRemote: String
    let baseURL: URL
    let candidateRoot: URL
    let evidenceDirectory: URL
    let qualificationDirectory: URL
    let noticesDirectory: URL
    let repositoryRevision: String
    let releasedAt: String
    let catalogSequence: UInt64
    let previousCatalogV1: URL?
    let previousSignatureV1: URL?
    let previousCatalogV2: URL?
    let previousSignatureV2: URL?
    let retiredModelsManifest: URL?
    let allowUnchangedCandidate: Bool
    let allowEmptyV1: Bool
    let models: [ModelInput]
    let recipes: [String: CompatibilityRecipe]
    let strictReaders: [StrictReader]
}

private struct CompatibilityRecipe {
    let key: String
    let descriptorVersions: ClosedRange<Int>
    let embeddingDimension: Int
    let role: String
    let capabilities: Set<String>
    let requiredRuntimeResources: Set<String>
    let maximumBytes: Int64
    let maximumFileBytes: Int64
    let license: String
}

private enum CatalogChannel: String, CaseIterable {
    case production
    case preview
}

/// An app generation that rejects a whole catalog with an unknown recipe and drops retired models.
private struct StrictReader: Decodable {
    let apps: String
    let recipes: [String]
}

/// `Tools/MLModels/catalog-compatibility.json`. A package test keeps its recipes equal to the
/// app's `MLModelCompatibilityRegistry`.
private struct CompatibilityFile: Decodable {
    struct Recipe: Decodable {
        let key: String
        let minimumDescriptorVersion: Int
        let maximumDescriptorVersion: Int
        let embeddingDimension: Int
        let role: String
        let capabilities: [String]
        let requiredRuntimeResources: [String]
        let maximumBytes: Int64
        let maximumFileBytes: Int64
        let license: String
    }

    let schemaVersion: Int
    let recipes: [Recipe]
    let strictReaders: [String: [StrictReader]]
}

private let defaultCompatibilityFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Tools/MLModels/catalog-compatibility.json")

private let legacyCompatibilityKeys: [String: String] = [
    "tinyclip-vit-40m-32-text-19m": "clip-dual-encoder-v1",
    "siglip2-base-patch16-256": "siglip-dual-encoder-v1",
]

private let legacySourceRevisions: [String: String] = [
    "tinyclip-vit-40m-32-text-19m": "95ec8197b3f2fe7f747865c61ca556cf0768b2f7",
    "siglip2-base-patch16-256": "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
]

private enum ReleaseError: Error, CustomStringConvertible {
    case usage
    case invalid(String)
    case missing(URL)

    var description: String {
        switch self {
        case .usage:
            return
                "Usage: prepare-ml-model-release.swift --private-key PATH --output DIR --bucket NAME --base-url URL --candidate-root DIR --evidence-dir DIR --qualification-dir DIR --notices-dir DIR --repository-revision SHA --released-at ISO8601 --catalog-sequence NUMBER [--model ID=DIR ...] [--retired-models FILE] [--previous-catalog-v1 FILE --previous-signature-v1 FILE [--previous-catalog-v2 FILE --previous-signature-v2 FILE]] [--rclone-remote NAME] [--channel production|preview] [--compatibility FILE] [--allow-unchanged-candidate] [--allow-empty-v1]"
        case .invalid(let reason):
            return reason
        case .missing(let url):
            return "Missing required file: \(url.path)"
        }
    }
}

private func parseOptions() throws -> Options {
    var values: [String: String] = [:]
    var models: [ModelInput] = []
    var allowUnchangedCandidate = false
    var allowEmptyV1 = false
    var index = 1
    let allowed = Set([
        "--private-key", "--output", "--bucket", "--rclone-remote", "--base-url",
        "--candidate-root", "--evidence-dir", "--qualification-dir", "--notices-dir",
        "--repository-revision", "--released-at", "--catalog-sequence",
        "--retired-models",
        "--previous-catalog-v1", "--previous-signature-v1", "--previous-catalog-v2",
        "--previous-signature-v2",
        "--allow-empty-v1", "--channel", "--compatibility",
    ])

    while index < CommandLine.arguments.count {
        let key = CommandLine.arguments[index]
        if key == "--allow-unchanged-candidate" {
            guard !allowUnchangedCandidate else { throw ReleaseError.invalid("Duplicate option: \(key)") }
            allowUnchangedCandidate = true
            index += 1
            continue
        }
        if key == "--allow-empty-v1" {
            guard !allowEmptyV1 else { throw ReleaseError.invalid("Duplicate option: \(key)") }
            allowEmptyV1 = true
            index += 1
            continue
        }
        guard index + 1 < CommandLine.arguments.count else { throw ReleaseError.usage }
        let value = CommandLine.arguments[index + 1]
        if key == "--model" {
            guard let separator = value.firstIndex(of: "=") else { throw ReleaseError.usage }
            let id = String(value[..<separator])
            let path = String(value[value.index(after: separator)...])
            guard isSafeModelID(id), !path.isEmpty else { throw ReleaseError.usage }
            models.append(ModelInput(id: id, directory: URL(fileURLWithPath: path, isDirectory: true)))
        } else {
            guard allowed.contains(key) else { throw ReleaseError.invalid("Unknown option: \(key)") }
            guard values[key] == nil else { throw ReleaseError.invalid("Duplicate option: \(key)") }
            values[key] = value
        }
        index += 2
    }

    guard let privateKey = values["--private-key"],
        let output = values["--output"],
        let bucket = values["--bucket"], !bucket.isEmpty,
        let base = values["--base-url"],
        let baseURL = URL(string: base),
        let candidateRoot = values["--candidate-root"],
        let evidenceDirectory = values["--evidence-dir"],
        let qualificationDirectory = values["--qualification-dir"],
        let noticesDirectory = values["--notices-dir"],
        let repositoryRevision = values["--repository-revision"],
        let releasedAt = values["--released-at"],
        let rawSequence = values["--catalog-sequence"],
        let catalogSequence = UInt64(rawSequence), catalogSequence > 0
    else { throw ReleaseError.usage }

    guard baseURL.scheme == "https",
        baseURL.user == nil,
        baseURL.password == nil,
        baseURL.query == nil,
        baseURL.fragment == nil,
        baseURL.absoluteString.hasSuffix("/models/")
    else {
        throw ReleaseError.invalid("--base-url must be an HTTPS URL ending in /models/")
    }
    guard isImmutableRevision(repositoryRevision) else {
        throw ReleaseError.invalid("--repository-revision must be a lowercase 40- or 64-character revision")
    }
    guard ISO8601DateFormatter().date(from: releasedAt) != nil else {
        throw ReleaseError.invalid("--released-at must be an ISO 8601 timestamp")
    }
    guard Set(models.map(\.id)).count == models.count else {
        throw ReleaseError.invalid("Every --model ID must be unique")
    }

    let candidateRootURL = URL(fileURLWithPath: candidateRoot, isDirectory: true)
    let retiredModelsManifest =
        values["--retired-models"]
        .map(URL.init(fileURLWithPath:))
        ?? (FileManager.default.fileExists(
            atPath: candidateRootURL.appendingPathComponent("retired-models.json").path
        ) ? candidateRootURL.appendingPathComponent("retired-models.json") : nil)
    guard !models.isEmpty || retiredModelsManifest != nil else {
        throw ReleaseError.usage
    }

    let hasPreviousCatalogV1 = values["--previous-catalog-v1"] != nil
    let hasPreviousSignatureV1 = values["--previous-signature-v1"] != nil
    let hasPreviousCatalogV2 = values["--previous-catalog-v2"] != nil
    let hasPreviousSignatureV2 = values["--previous-signature-v2"] != nil
    guard hasPreviousCatalogV1 == hasPreviousSignatureV1,
        hasPreviousCatalogV2 == hasPreviousSignatureV2,
        !hasPreviousCatalogV2 || hasPreviousCatalogV1
    else {
        throw ReleaseError.invalid("Previous catalogs require their matching detached signatures")
    }
    guard let channel = CatalogChannel(rawValue: values["--channel"] ?? CatalogChannel.production.rawValue) else {
        throw ReleaseError.invalid("--channel must be production or preview")
    }
    let compatibility = try loadCompatibility(
        values["--compatibility"].map(URL.init(fileURLWithPath:)) ?? defaultCompatibilityFile,
        channel: channel
    )

    return Options(
        privateKey: URL(fileURLWithPath: privateKey),
        output: URL(fileURLWithPath: output, isDirectory: true),
        bucket: bucket,
        rcloneRemote: values["--rclone-remote"] ?? "r2",
        baseURL: baseURL,
        candidateRoot: candidateRootURL,
        evidenceDirectory: URL(fileURLWithPath: evidenceDirectory, isDirectory: true),
        qualificationDirectory: URL(fileURLWithPath: qualificationDirectory, isDirectory: true),
        noticesDirectory: URL(fileURLWithPath: noticesDirectory, isDirectory: true),
        repositoryRevision: repositoryRevision,
        releasedAt: releasedAt,
        catalogSequence: catalogSequence,
        previousCatalogV1: values["--previous-catalog-v1"].map(URL.init(fileURLWithPath:)),
        previousSignatureV1: values["--previous-signature-v1"].map(URL.init(fileURLWithPath:)),
        previousCatalogV2: values["--previous-catalog-v2"].map(URL.init(fileURLWithPath:)),
        previousSignatureV2: values["--previous-signature-v2"].map(URL.init(fileURLWithPath:)),
        retiredModelsManifest: retiredModelsManifest,
        allowUnchangedCandidate: allowUnchangedCandidate,
        allowEmptyV1: allowEmptyV1,
        models: models.sorted { $0.id < $1.id },
        recipes: compatibility.recipes,
        strictReaders: compatibility.strictReaders
    )
}

private func loadCompatibility(
    _ url: URL,
    channel: CatalogChannel
) throws -> (recipes: [String: CompatibilityRecipe], strictReaders: [StrictReader]) {
    let file = try load(CompatibilityFile.self, from: url)
    guard file.schemaVersion == 1,
        Set(file.strictReaders.keys) == Set(CatalogChannel.allCases.map(\.rawValue)),
        let strictReaders = file.strictReaders[channel.rawValue]
    else {
        throw ReleaseError.invalid("The compatibility file must list strict readers for every channel")
    }
    var recipes: [String: CompatibilityRecipe] = [:]
    for recipe in file.recipes {
        guard !recipe.key.isEmpty,
            recipes[recipe.key] == nil,
            recipe.minimumDescriptorVersion >= 1,
            recipe.minimumDescriptorVersion <= recipe.maximumDescriptorVersion,
            recipe.embeddingDimension > 0,
            recipe.maximumFileBytes > 0,
            recipe.maximumFileBytes <= recipe.maximumBytes
        else {
            throw ReleaseError.invalid("The compatibility file contains an invalid recipe: \(recipe.key)")
        }
        recipes[recipe.key] = CompatibilityRecipe(
            key: recipe.key,
            descriptorVersions: recipe.minimumDescriptorVersion...recipe.maximumDescriptorVersion,
            embeddingDimension: recipe.embeddingDimension,
            role: recipe.role,
            capabilities: Set(recipe.capabilities),
            requiredRuntimeResources: Set(recipe.requiredRuntimeResources),
            maximumBytes: recipe.maximumBytes,
            maximumFileBytes: recipe.maximumFileBytes,
            license: recipe.license
        )
    }
    guard !recipes.isEmpty, strictReaders.allSatisfy({ !$0.recipes.isEmpty }) else {
        throw ReleaseError.invalid("The compatibility file must list recipes and each strict reader's recipes")
    }
    return (recipes, strictReaders)
}

/// Apps that reject an unknown recipe or drop retired models must keep every model they can
/// have selected. Such a catalog must wait until those apps no longer read the channel.
private func validateStrictReaders(
    _ readers: [StrictReader],
    previous: [String: CatalogModelV2],
    candidate: CatalogV2
) throws {
    let candidateByID = Dictionary(uniqueKeysWithValues: candidate.models.map { ($0.id, $0) })
    for reader in readers {
        let knownRecipes = Set(reader.recipes)
        if let model = candidate.models.first(where: { !knownRecipes.contains($0.compatibilityKey) }) {
            throw ReleaseError.invalid(
                "Apps \(reader.apps) reject the whole catalog: model \(model.id) uses unknown recipe \(model.compatibilityKey)"
            )
        }
        for (id, model) in previous.sorted(by: { $0.key < $1.key }) where model.availability ?? .active == .active {
            guard let next = candidateByID[id], next.availability ?? .active == .active else {
                throw ReleaseError.invalid("Apps \(reader.apps) lose model \(id) when a catalog retires or removes it")
            }
        }
    }
}

private func isSafeModelID(_ value: String) -> Bool {
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

private func isASCIILowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
    (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
}

private func isImmutableRevision(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64)
        && value.allSatisfy { $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func fileSize(_ url: URL) throws -> Int64 {
    Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    guard FileManager.default.fileExists(atPath: url.path) else { throw ReleaseError.missing(url) }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
    return data
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func isContained(_ child: URL, by root: URL) -> Bool {
    let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
}

private func validateCandidateDirectory(_ directory: URL, root: URL, label: String) throws -> URL {
    let standardized = directory.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standardized.path) else {
        throw ReleaseError.missing(standardized)
    }
    let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true,
        values.isSymbolicLink != true,
        isContained(standardized, by: root)
    else {
        throw ReleaseError.invalid("\(label) must be a regular directory inside the candidate root")
    }
    return standardized
}

private func validateCandidateFile(_ file: URL, root: URL, label: String) throws -> URL {
    let standardized = file.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standardized.path) else {
        throw ReleaseError.missing(standardized)
    }
    let values = try standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        isContained(standardized, by: root)
    else {
        throw ReleaseError.invalid("\(label) must be a regular file inside the candidate root")
    }
    return standardized
}

private func requireEmptyOutputDirectory(_ directory: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: directory.path) else { return }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw ReleaseError.invalid("The output path must be a regular directory")
    }
    guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
        throw ReleaseError.invalid("The output directory must be empty")
    }
}

private func loadRetiredModelIDs(_ options: Options) throws -> Set<String> {
    guard let manifestURL = options.retiredModelsManifest else { return [] }
    let file = try validateCandidateFile(
        manifestURL,
        root: options.candidateRoot,
        label: "Retired models manifest"
    )
    let manifest = try load(RetiredModelsManifest.self, from: file)
    guard manifest.schemaVersion == 1,
        !manifest.modelIDs.isEmpty,
        Set(manifest.modelIDs).count == manifest.modelIDs.count,
        manifest.modelIDs.allSatisfy(isSafeModelID)
    else {
        throw ReleaseError.invalid("Retired models manifest must contain unique model IDs")
    }
    return Set(manifest.modelIDs)
}

private func regularFiles(under root: URL) throws -> [(path: String, url: URL)] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    var enumerationFailure: String?
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { url, error in
                enumerationFailure = "Cannot read \(url.path): \(error)"
                return false
            }
        )
    else { throw ReleaseError.invalid("Cannot enumerate \(root.path)") }

    let prefix = root.standardizedFileURL.path + "/"
    var files: [(path: String, url: URL)] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: keys)
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            throw ReleaseError.invalid("Candidate path escaped its model directory")
        }
        let relativePath = String(path.dropFirst(prefix.count))
        guard !relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw ReleaseError.invalid("Hidden candidate paths are not allowed: \(relativePath)")
        }
        guard values.isSymbolicLink != true else {
            throw ReleaseError.invalid("Symbolic links are not allowed: \(relativePath)")
        }
        if values.isDirectory == true { continue }
        guard values.isRegularFile == true else {
            throw ReleaseError.invalid("Only regular files are allowed: \(relativePath)")
        }
        files.append((relativePath, url))
    }
    if let enumerationFailure {
        throw ReleaseError.invalid(enumerationFailure)
    }
    return files.sorted { $0.path < $1.path }
}

private func validateHTTPSURL(_ url: URL, label: String) throws {
    guard url.scheme == "https",
        url.host != nil,
        url.user == nil,
        url.password == nil,
        url.fragment == nil
    else {
        throw ReleaseError.invalid("\(label) must be a public HTTPS URL")
    }
}

private func isSafeCatalogRevision(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
        && value.allSatisfy {
            ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "-" || $0 == "_"
        }
}

private func isSafeArtifactPath(_ path: String) -> Bool {
    guard !path.isEmpty,
        !path.hasPrefix("/"),
        !path.contains("\\"),
        !path.contains("\0")
    else { return false }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains {
        $0.isEmpty || $0 == "." || $0 == ".."
    }
}

private func isAllowedArtifactURL(_ url: URL, baseURL: URL, expectedPath: String) -> Bool {
    guard url.scheme?.lowercased() == "https",
        url.host?.lowercased() == baseURL.host?.lowercased(),
        url.port == baseURL.port,
        url.user == nil,
        url.password == nil,
        url.query == nil,
        url.fragment == nil
    else { return false }
    let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
    return url.path == basePath + expectedPath
}

private func deriveV2Model(
    from legacy: CatalogModelV1,
    baseURL: URL,
    recipes: [String: CompatibilityRecipe]
) throws -> CatalogModelV2 {
    guard let compatibilityKey = legacyCompatibilityKeys[legacy.id],
        let sourceRevision = legacySourceRevisions[legacy.id],
        let recipe = recipes[compatibilityKey]
    else {
        throw ReleaseError.invalid(
            "V1-only migration cannot derive V2 metadata for \(legacy.id); provide a verified V2 catalog"
        )
    }
    guard isSafeModelID(legacy.id),
        isSafeCatalogRevision(legacy.revision),
        !legacy.artifacts.isEmpty,
        legacy.artifacts.count == Set(legacy.artifacts.map(\.path)).count
    else {
        throw ReleaseError.invalid("V1-only migration has invalid artifacts for \(legacy.id)")
    }
    if let qualification = legacy.qualification,
        qualification.artifactRevision != legacy.revision
    {
        throw ReleaseError.invalid("V1-only migration has stale qualification for \(legacy.id)")
    }

    var roots: Set<String> = []
    var paths: Set<String> = []
    var totalBytes: Int64 = 0
    for artifact in legacy.artifacts {
        guard isSafeArtifactPath(artifact.path),
            isAllowedArtifactURL(
                artifact.url,
                baseURL: baseURL,
                expectedPath: "\(legacy.id)/\(legacy.revision)/\(artifact.path)"
            ),
            artifact.sha256.count == 64,
            artifact.sha256.allSatisfy({ $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" }),
            artifact.bytes > 0,
            artifact.bytes <= recipe.maximumFileBytes
        else {
            throw ReleaseError.invalid("V1-only migration cannot safely reuse artifact metadata for \(legacy.id)")
        }
        let firstComponent = artifact.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if firstComponent.lowercased().hasSuffix(".mlmodelc")
            || firstComponent.lowercased().hasSuffix(".mlpackage")
        {
            roots.insert(firstComponent)
        }
        paths.insert(artifact.path)
        totalBytes += artifact.bytes
    }
    guard roots.count == 1,
        let modelRoot = roots.first,
        paths.contains(where: { $0.hasPrefix(modelRoot + "/") }),
        recipe.requiredRuntimeResources.isSubset(of: paths),
        paths.allSatisfy({ path in
            path == modelRoot || path.hasPrefix(modelRoot + "/")
                || recipe.requiredRuntimeResources.contains(path)
        }),
        totalBytes <= recipe.maximumBytes
    else {
        throw ReleaseError.invalid("V1-only migration cannot derive a complete download plan for \(legacy.id)")
    }

    return CatalogModelV2(
        id: legacy.id,
        availability: .active,
        compatibilityKey: compatibilityKey,
        releaseSequence: 1,
        revision: legacy.revision,
        descriptor: .init(
            identifier: legacy.id,
            version: 1,
            embeddingDimension: recipe.embeddingDimension
        ),
        sourceRevision: sourceRevision,
        licenseIdentifier: recipe.license,
        role: recipe.role,
        capabilities: recipe.capabilities.sorted(),
        artifacts: legacy.artifacts,
        qualification: legacy.qualification
    )
}

private func loadVerifiedCatalog<T: Decodable>(
    _ type: T.Type,
    catalogURL: URL,
    signatureURL: URL,
    publicKey: Curve25519.Signing.PublicKey
) throws -> T {
    let data = try Data(contentsOf: catalogURL)
    let signature = try Data(contentsOf: signatureURL)
    guard signature.count == 64, publicKey.isValidSignature(signature, for: data) else {
        throw ReleaseError.invalid("Previous catalog signature verification failed: \(catalogURL.lastPathComponent)")
    }
    return try JSONDecoder().decode(type, from: data)
}

private func prepareModel(input: ModelInput, options: Options) throws -> PreparedModel {
    let root = try validateCandidateDirectory(input.directory, root: options.candidateRoot, label: "Model directory")
    let releaseManifestURL = try validateCandidateFile(
        root.appendingPathComponent("release-manifest.json"),
        root: options.candidateRoot,
        label: "Release manifest"
    )
    let manifest = try load(ReleaseManifest.self, from: releaseManifestURL)
    guard manifest.schemaVersion == 1,
        manifest.modelID == input.id,
        let recipe = options.recipes[manifest.compatibilityKey],
        recipe.descriptorVersions.contains(manifest.descriptorVersion),
        manifest.embeddingDimension == recipe.embeddingDimension,
        manifest.role == recipe.role,
        Set(manifest.capabilities) == recipe.capabilities,
        manifest.licenseIdentifier == recipe.license,
        isImmutableRevision(manifest.sourceRevision)
    else {
        throw ReleaseError.invalid("Release manifest is outside a shipped compatibility recipe for \(input.id)")
    }
    if let expectedKey = legacyCompatibilityKeys[input.id], expectedKey != recipe.key {
        throw ReleaseError.invalid("Legacy model \(input.id) cannot change compatibility recipe")
    }

    let noticeURL = try validateCandidateFile(
        options.noticesDirectory.appendingPathComponent("\(input.id).txt"),
        root: options.candidateRoot,
        label: "Model license"
    )
    guard let notice = try? String(contentsOf: noticeURL, encoding: .utf8),
        !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw ReleaseError.invalid("A non-empty model license file is required for \(input.id)")
    }
    let evidenceURL = try validateCandidateFile(
        options.evidenceDirectory.appendingPathComponent("\(input.id).json"),
        root: options.candidateRoot,
        label: "Release evidence"
    )
    let evidence = try load(ReleaseEvidence.self, from: evidenceURL)
    try validateHTTPSURL(evidence.sourceURL, label: "sourceURL")
    try validateHTTPSURL(evidence.licenseURL, label: "licenseURL")
    let noticeHash = try sha256(noticeURL)
    guard evidence.schemaVersion == 1,
        evidence.modelID == input.id,
        evidence.sourceRevision == manifest.sourceRevision,
        evidence.licenseIdentifier == recipe.license,
        evidence.noticeSHA256 == noticeHash,
        evidence.rights.allGranted
    else {
        throw ReleaseError.invalid("Release approval failed for \(input.id)")
    }

    let artifactManifestURL = try validateCandidateFile(
        root.appendingPathComponent("artifact-manifest.json"),
        root: options.candidateRoot,
        label: "Artifact manifest"
    )
    let artifactManifest = try load(ArtifactManifest.self, from: artifactManifestURL)
    guard artifactManifest.schemaVersion == 1,
        artifactManifest.revision == manifest.sourceRevision
    else {
        throw ReleaseError.invalid("Artifact manifest revision mismatch for \(input.id)")
    }

    let files = try regularFiles(under: root).filter {
        $0.path != "artifact-manifest.json" && $0.path != "release-manifest.json"
    }
    guard !files.isEmpty else {
        throw ReleaseError.invalid("Model \(input.id) has no runtime artifacts")
    }
    let rows = try files.map { file -> (path: String, source: URL, hash: String, bytes: Int64) in
        let bytes = try fileSize(file.url)
        guard bytes > 0, bytes <= recipe.maximumFileBytes else {
            throw ReleaseError.invalid("Artifact file size exceeds the recipe limit: \(file.path)")
        }
        return (file.path, file.url, try sha256(file.url), bytes)
    }
    let totalBytes = rows.reduce(Int64(0)) { $0 + $1.bytes }
    guard totalBytes <= recipe.maximumBytes else {
        throw ReleaseError.invalid("Artifact size exceeds the recipe limit for \(input.id)")
    }

    let roots = Set(
        rows.compactMap { row -> String? in
            let first = row.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let lowercased = first.lowercased()
            return lowercased.hasSuffix(".mlmodelc") || lowercased.hasSuffix(".mlpackage") ? first : nil
        })
    guard roots.count == 1, let modelRoot = roots.first else {
        throw ReleaseError.invalid("Exactly one .mlmodelc or .mlpackage root is required for \(input.id)")
    }
    let paths = Set(rows.map(\.path))
    guard paths.contains(where: { $0.hasPrefix(modelRoot + "/") }),
        recipe.requiredRuntimeResources.isSubset(of: paths),
        paths.allSatisfy({ path in
            path == modelRoot || path.hasPrefix(modelRoot + "/")
                || recipe.requiredRuntimeResources.contains(path)
        })
    else {
        throw ReleaseError.invalid("Runtime artifact layout failed for \(input.id)")
    }

    guard Set(artifactManifest.files.map(\.path)).count == artifactManifest.files.count else {
        throw ReleaseError.invalid("Artifact manifest contains duplicate paths for \(input.id)")
    }
    let manifestRows = Dictionary(
        uniqueKeysWithValues: artifactManifest.files.map { ($0.path, ($0.sha256, $0.bytes)) }
    )
    guard manifestRows.count == rows.count,
        rows.allSatisfy({ manifestRows[$0.path]?.0 == $0.hash && manifestRows[$0.path]?.1 == $0.bytes })
    else {
        throw ReleaseError.invalid("Artifact manifest hash/size mismatch for \(input.id)")
    }

    let fingerprint =
        ([
            "modelID:\(manifest.modelID)",
            "compatibilityKey:\(manifest.compatibilityKey)",
            "sourceRevision:\(manifest.sourceRevision)",
            "descriptorVersion:\(manifest.descriptorVersion)",
            "embeddingDimension:\(manifest.embeddingDimension)",
            "role:\(manifest.role)",
            "capabilities:\(manifest.capabilities.sorted().joined(separator: ","))",
            "licenseIdentifier:\(manifest.licenseIdentifier)",
        ] + rows.map { "\($0.path):\($0.hash):\($0.bytes)" }).joined(separator: "\n")
    let revision =
        "r1-"
        + SHA256.hash(data: Data(fingerprint.utf8)).prefix(8)
        .map { String(format: "%02x", $0) }.joined()
    let qualificationURL = try validateCandidateFile(
        options.qualificationDirectory.appendingPathComponent("\(input.id).json"),
        root: options.candidateRoot,
        label: "Qualification report"
    )
    let qualification = try load(Qualification.self, from: qualificationURL)
    guard qualification.schemaVersion == 1,
        qualification.modelID == input.id,
        qualification.sourceRevision == manifest.sourceRevision,
        qualification.artifactRevision == revision,
        isImmutableRevision(qualification.converterRevision),
        isImmutableRevision(qualification.qualificationCorpusRevision),
        qualification.gates.allPassed,
        qualification.neuralEngineExecutionVerified,
        !qualification.reachedSeriousThermalState,
        qualification.peakResidentBytes > 0,
        qualification.imageP95Milliseconds > 0,
        qualification.textP95Milliseconds > 0,
        !qualification.hardwareModel.isEmpty,
        !qualification.osVersion.isEmpty,
        !qualification.xcodeBuild.isEmpty,
        artifactManifest.tools["coremltools"] == qualification.coremltoolsVersion
    else {
        throw ReleaseError.invalid("Qualification gate failed or is stale for \(input.id) \(revision)")
    }

    let prefix = "\(input.id)/\(revision)/"
    let artifacts = rows.map { row in
        PreparedArtifact(
            catalog: CatalogArtifact(
                path: row.path,
                url: options.baseURL.appendingPathComponent(prefix + row.path),
                sha256: row.hash,
                bytes: row.bytes
            ),
            source: row.source
        )
    }
    let catalogQualification = CatalogQualification(qualification)
    let v1 =
        legacyCompatibilityKeys[input.id] == nil
        ? nil
        : CatalogModelV1(
            id: input.id,
            revision: revision,
            artifacts: artifacts.map(\.catalog),
            qualification: catalogQualification
        )
    let v2 = CatalogModelV2(
        id: input.id,
        availability: .active,
        compatibilityKey: recipe.key,
        releaseSequence: 1,
        revision: revision,
        descriptor: .init(
            identifier: input.id,
            version: manifest.descriptorVersion,
            embeddingDimension: recipe.embeddingDimension
        ),
        sourceRevision: manifest.sourceRevision,
        licenseIdentifier: recipe.license,
        role: recipe.role,
        capabilities: recipe.capabilities.sorted(),
        artifacts: artifacts.map(\.catalog),
        qualification: catalogQualification
    )
    return PreparedModel(
        v1: v1,
        v2: v2,
        artifacts: artifacts,
        qualification: qualification,
        evidence: evidence,
        notice: notice
    )
}

private func validatePreviousCatalogs(
    v1: CatalogV1,
    v2: CatalogV2,
    nextSequence: UInt64,
    baseURL: URL,
    recipes: [String: CompatibilityRecipe]
) throws {
    guard v1.schemaVersion == 1,
        v2.schemaVersion == 2,
        v2.catalogSequence > 0,
        v2.catalogSequence < UInt64.max,
        nextSequence == v2.catalogSequence + 1,
        v2.models.allSatisfy({ $0.releaseSequence > 0 })
    else {
        throw ReleaseError.invalid("Previous catalogs are invalid or the next sequence is not monotonic")
    }
    try validateCatalogPair(v1: v1, v2: v2, baseURL: baseURL, recipes: recipes)
}

private func validateCatalogPair(
    v1: CatalogV1,
    v2: CatalogV2,
    baseURL: URL,
    recipes: [String: CompatibilityRecipe]
) throws {
    guard v1.schemaVersion == 1,
        v2.schemaVersion == 2,
        Set(v1.models.map(\.id)).count == v1.models.count,
        Set(v2.models.map(\.id)).count == v2.models.count
    else {
        throw ReleaseError.invalid("Catalog pair contains duplicate or unsupported model IDs")
    }
    for model in v2.models {
        try validateV2Model(model, baseURL: baseURL, recipes: recipes)
    }
    let v2ByID = Dictionary(uniqueKeysWithValues: v2.models.map { ($0.id, $0) })
    for legacy in v1.models {
        guard let current = v2ByID[legacy.id] else {
            throw ReleaseError.invalid("Catalog pair is missing V2 metadata for legacy model \(legacy.id)")
        }
        guard current.availability ?? .active == .active else {
            throw ReleaseError.invalid("Catalog pair maps legacy model \(legacy.id) to a retired V2 model")
        }
        guard legacy.revision == current.revision,
            legacy.artifacts == current.artifacts,
            legacy.qualification == current.qualification
        else {
            throw ReleaseError.invalid("Catalog pair diverges for legacy model \(legacy.id)")
        }
    }
}

private func validateV2Model(
    _ model: CatalogModelV2,
    baseURL: URL,
    recipes: [String: CompatibilityRecipe]
) throws {
    guard isSafeModelID(model.id),
        let recipe = recipes[model.compatibilityKey],
        model.releaseSequence > 0,
        isSafeCatalogRevision(model.revision),
        isImmutableRevision(model.sourceRevision),
        model.licenseIdentifier == recipe.license,
        model.role == recipe.role,
        Set(model.capabilities) == recipe.capabilities,
        model.descriptor.identifier == model.id,
        recipe.descriptorVersions.contains(model.descriptor.version),
        model.descriptor.embeddingDimension == recipe.embeddingDimension,
        !model.artifacts.isEmpty,
        model.artifacts.count == Set(model.artifacts.map(\.path)).count
    else {
        throw ReleaseError.invalid("V2 model metadata is outside a shipped compatibility recipe: \(model.id)")
    }
    if let qualification = model.qualification,
        qualification.artifactRevision != model.revision
    {
        throw ReleaseError.invalid("V2 model qualification is stale: \(model.id)")
    }

    var roots: Set<String> = []
    var paths: Set<String> = []
    var totalBytes: Int64 = 0
    for artifact in model.artifacts {
        guard isSafeArtifactPath(artifact.path),
            isAllowedArtifactURL(
                artifact.url,
                baseURL: baseURL,
                expectedPath: "\(model.id)/\(model.revision)/\(artifact.path)"
            ),
            artifact.sha256.count == 64,
            artifact.sha256.allSatisfy({ $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" }),
            artifact.bytes > 0,
            artifact.bytes <= recipe.maximumFileBytes
        else {
            throw ReleaseError.invalid("V2 model artifact metadata is invalid: \(model.id)")
        }
        let firstComponent = artifact.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if firstComponent.lowercased().hasSuffix(".mlmodelc")
            || firstComponent.lowercased().hasSuffix(".mlpackage")
        {
            roots.insert(firstComponent)
        }
        paths.insert(artifact.path)
        totalBytes += artifact.bytes
    }
    guard roots.count == 1,
        let modelRoot = roots.first,
        paths.contains(where: { $0.hasPrefix(modelRoot + "/") }),
        recipe.requiredRuntimeResources.isSubset(of: paths),
        paths.allSatisfy({ path in
            path == modelRoot || path.hasPrefix(modelRoot + "/")
                || recipe.requiredRuntimeResources.contains(path)
        }),
        totalBytes <= recipe.maximumBytes
    else {
        throw ReleaseError.invalid("V2 model artifact layout is invalid: \(model.id)")
    }
}

private func hasSameReleaseContent(_ lhs: CatalogModelV2, _ rhs: CatalogModelV2) -> Bool {
    lhs.id == rhs.id
        && lhs.compatibilityKey == rhs.compatibilityKey
        && lhs.revision == rhs.revision
        && lhs.descriptor == rhs.descriptor
        && lhs.sourceRevision == rhs.sourceRevision
        && lhs.licenseIdentifier == rhs.licenseIdentifier
        && lhs.role == rhs.role
        && lhs.capabilities == rhs.capabilities
        && lhs.artifacts == rhs.artifacts
        && lhs.qualification == rhs.qualification
}

private func nextModelReleaseSequence(
    candidate: CatalogModelV2,
    previous: CatalogModelV2?,
    allowUnchanged: Bool
) throws -> UInt64 {
    guard let previous else {
        guard candidate.descriptor.version == 1 else {
            throw ReleaseError.invalid("A new model must start at descriptor version 1: \(candidate.id)")
        }
        return 1
    }
    guard previous.releaseSequence < UInt64.max else {
        throw ReleaseError.invalid("Model release sequence overflow for \(candidate.id)")
    }
    guard candidate.compatibilityKey == previous.compatibilityKey else {
        throw ReleaseError.invalid("An existing model cannot change compatibility recipe: \(candidate.id)")
    }
    if hasSameReleaseContent(candidate, previous) {
        if previous.availability ?? .active == .retired,
            candidate.availability ?? .active == .active
        {
            return previous.releaseSequence + 1
        }
        guard allowUnchanged else {
            throw ReleaseError.invalid("The candidate does not change model \(candidate.id)")
        }
        return previous.releaseSequence + 1
    }

    let artifactChanged =
        candidate.revision != previous.revision
        || candidate.artifacts != previous.artifacts
        || candidate.sourceRevision != previous.sourceRevision
    if artifactChanged {
        guard previous.descriptor.version < 65_535,
            candidate.descriptor.version == previous.descriptor.version + 1
        else {
            throw ReleaseError.invalid(
                "A model artifact update must increment descriptorVersion by one: \(candidate.id)"
            )
        }
    } else if candidate.descriptor != previous.descriptor {
        throw ReleaseError.invalid(
            "Descriptor metadata cannot change without a new model artifact revision: \(candidate.id)"
        )
    }
    return previous.releaseSequence + 1
}

private func fileDigest(_ url: URL, path: String) throws -> ReleasePairManifest.File {
    ReleasePairManifest.File(path: path, sha256: try sha256(url), bytes: try fileSize(url))
}

private func uploadScript(
    options: Options,
    prepared: [PreparedModel],
    historyFiles: [(url: URL, path: String)],
    metadataFiles: [(url: URL, path: String)],
    pairID: String,
    catalogV1URL: URL,
    signatureV1URL: URL,
    catalogV2URL: URL,
    signatureV2URL: URL,
    pairManifestURL: URL,
    pointerURL: URL
) throws -> String {
    // The signer body is shared with scripts/rollback-ml-model-release.sh; the generated script embeds it.
    let r2RequestBody = try String(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("r2_request.py"),
        encoding: .utf8)
    let r2RequestFunction = """
        r2_request() {
          local method=$1 key=$2 file=${3:-} immutable=${4:-0} maximum_bytes=${5:-0}
          python3 - "$method" "$bucket" "$key" "$file" "$immutable" "$maximum_bytes" <<'PY'
        \(r2RequestBody)PY
        }
        """
    var lines = [
        "#!/bin/zsh",
        "set -euo pipefail",
        "command -v python3 >/dev/null || { echo 'python3 is required for signed R2 requests' >&2; exit 1; }",
        ": \"${R2_ENDPOINT:?R2_ENDPOINT is required}\"",
        ": \"${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}\"",
        ": \"${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}\"",
        "release_tmp=$(mktemp -d)",
        "trap 'rm -rf \"$release_tmp\"' EXIT",
        "bucket=\(shellQuote(options.bucket))",
        r2RequestFunction,
        "upload_immutable() {",
        "  local source=$1 key=$2 expected_hash=$3 expected_bytes=$4 verify actual_hash actual_bytes",
        "  verify=\"$release_tmp/verify-${expected_hash}-${RANDOM}\"",
        "  if r2_request PUT \"$key\" \"$source\" 1; then",
        "    :",
        "  elif [[ $? == 42 ]]; then",
        "    echo \"Conditional PutObject found existing $key; verifying its bytes\" >&2",
        "    r2_request GET \"$key\" \"$verify\" 0 \"$expected_bytes\" || { echo \"Immutable object is unavailable: $key\" >&2; exit 1; }",
        "  else",
        "    echo \"Conditional PutObject failed for $key\" >&2",
        "    exit 1",
        "  fi",
        "  if [[ ! -f \"$verify\" ]]; then",
        "    r2_request GET \"$key\" \"$verify\" 0 \"$expected_bytes\"",
        "  fi",
        "  actual_hash=$(shasum -a 256 \"$verify\" | awk '{print $1}')",
        "  actual_bytes=$(stat -f %z \"$verify\")",
        "  [[ \"$actual_hash\" == \"$expected_hash\" && \"$actual_bytes\" == \"$expected_bytes\" ]] || { echo \"Immutable object mismatch: $key\" >&2; exit 1; }",
        "}",
        "publish_catalog_mirror() {",
        "  local name=$1 source=$2 expected_hash=$3 expected_bytes=$4 verify actual_hash actual_bytes",
        "  verify=\"$release_tmp/mirror-$name\"",
        "  r2_request PUT \"$name\" \"$source\" 0",
        "  r2_request GET \"$name\" \"$verify\" 0 \"$expected_bytes\"",
        "  actual_hash=$(shasum -a 256 \"$verify\" | awk '{print $1}')",
        "  actual_bytes=$(stat -f %z \"$verify\")",
        "  [[ \"$actual_hash\" == \"$expected_hash\" && \"$actual_bytes\" == \"$expected_bytes\" ]] || { echo \"Catalog mirror mismatch: $name\" >&2; exit 1; }",
        "}",
        "publish_pointer() {",
        "  local source=$1",
        "  r2_request PUT active-pair.json \"$source\" 0",
        "}",
        "",
    ]

    for model in prepared {
        for artifact in model.artifacts {
            let key = "models/\(model.v2.id)/\(model.v2.revision)/\(artifact.catalog.path)"
            lines.append(
                "upload_immutable \(shellQuote(artifact.source.path)) \(shellQuote(key)) "
                    + "\(shellQuote(artifact.catalog.sha256)) \(artifact.catalog.bytes)"
            )
        }
    }
    for file in historyFiles {
        let digest = try fileDigest(file.url, path: file.path)
        lines.append(
            "upload_immutable \(shellQuote(file.url.path)) "
                + "\(shellQuote("catalog-history/\(pairID)/\(file.path)")) "
                + "\(shellQuote(digest.sha256)) \(digest.bytes)"
        )
    }
    for file in metadataFiles {
        let digest = try fileDigest(file.url, path: file.path)
        lines.append(
            "upload_immutable \(shellQuote(file.url.path)) "
                + "\(shellQuote("model-releases/\(pairID)/\(file.path)")) "
                + "\(shellQuote(digest.sha256)) \(digest.bytes)"
        )
    }

    for (url, name) in [
        (signatureV1URL, "catalog-v1.sig"),
        (catalogV1URL, "catalog-v1.json"),
        (signatureV2URL, "catalog-v2.sig"),
        (catalogV2URL, "catalog-v2.json"),
    ] {
        let digest = try fileDigest(url, path: name)
        lines.append(
            "publish_catalog_mirror \(shellQuote(name)) \(shellQuote(url.path)) "
                + "\(shellQuote(digest.sha256)) \(digest.bytes)"
        )
    }

    lines.append("publish_pointer \(shellQuote(pointerURL.path))")
    lines.append(
        "echo \(shellQuote("Published immutable catalog pair \(pairID); active-pair.json is the only mutable activation object"))"
    )
    return lines.joined(separator: "\n") + "\n"
}

do {
    let options = try parseOptions()
    let fileManager = FileManager.default
    try requireEmptyOutputDirectory(options.output)
    _ = try validateCandidateDirectory(options.candidateRoot, root: options.candidateRoot, label: "Candidate root")
    _ = try validateCandidateDirectory(
        options.evidenceDirectory, root: options.candidateRoot, label: "Evidence directory")
    _ = try validateCandidateDirectory(
        options.qualificationDirectory, root: options.candidateRoot, label: "Qualification directory")
    _ = try validateCandidateDirectory(
        options.noticesDirectory, root: options.candidateRoot, label: "Notices directory")

    let keyData = try Data(contentsOf: options.privateKey)
    guard keyData.count == 32,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else {
        throw ReleaseError.invalid("The signing key must contain exactly 32 raw Ed25519 bytes")
    }

    var previousV1: CatalogV1?
    var previousV2: CatalogV2?
    let retiredModelIDs = try loadRetiredModelIDs(options)
    let candidateModelIDs = Set(options.models.map(\.id))
    guard candidateModelIDs.isDisjoint(with: retiredModelIDs) else {
        throw ReleaseError.invalid("A model cannot be updated and retired in the same release")
    }
    if let catalogV1URL = options.previousCatalogV1,
        let signatureV1URL = options.previousSignatureV1
    {
        previousV1 = try loadVerifiedCatalog(
            CatalogV1.self,
            catalogURL: catalogV1URL,
            signatureURL: signatureV1URL,
            publicKey: key.publicKey
        )
    }
    if let catalogV2URL = options.previousCatalogV2,
        let signatureV2URL = options.previousSignatureV2
    {
        previousV2 = try loadVerifiedCatalog(
            CatalogV2.self,
            catalogURL: catalogV2URL,
            signatureURL: signatureV2URL,
            publicKey: key.publicKey
        )
    }
    if let previousV1, let previousV2 {
        try validatePreviousCatalogs(
            v1: previousV1,
            v2: previousV2,
            nextSequence: options.catalogSequence,
            baseURL: options.baseURL,
            recipes: options.recipes
        )
    } else if let previousV1 {
        guard options.catalogSequence == 1 else {
            throw ReleaseError.invalid("A V1-only migration must create catalog sequence 1")
        }
        guard previousV1.schemaVersion == 1 else {
            throw ReleaseError.invalid("The verified previous catalog-v1 has an unsupported schema")
        }
        guard Set(previousV1.models.map(\.id)).count == previousV1.models.count else {
            throw ReleaseError.invalid("The verified previous catalog-v1 contains duplicate model IDs")
        }
    } else if options.catalogSequence != 1 {
        throw ReleaseError.invalid("The initial catalog sequence must be 1")
    }

    let prepared = try options.models.map { try prepareModel(input: $0, options: options) }
    var v1ByID = Dictionary(uniqueKeysWithValues: (previousV1?.models ?? []).map { ($0.id, $0) })
    var v2ByID = Dictionary(uniqueKeysWithValues: (previousV2?.models ?? []).map { ($0.id, $0) })
    if previousV2 == nil, let previousV1 {
        for legacy in previousV1.models {
            let derived = try deriveV2Model(from: legacy, baseURL: options.baseURL, recipes: options.recipes)
            v2ByID[derived.id] = derived
        }
    }
    let previousModels = v2ByID
    for model in prepared {
        if let v1 = model.v1 { v1ByID[v1.id] = v1 }
        let releaseSequence = try nextModelReleaseSequence(
            candidate: model.v2,
            previous: v2ByID[model.v2.id],
            allowUnchanged: options.allowUnchangedCandidate
        )
        v2ByID[model.v2.id] = CatalogModelV2(
            id: model.v2.id,
            availability: .active,
            compatibilityKey: model.v2.compatibilityKey,
            releaseSequence: releaseSequence,
            revision: model.v2.revision,
            descriptor: model.v2.descriptor,
            sourceRevision: model.v2.sourceRevision,
            licenseIdentifier: model.v2.licenseIdentifier,
            role: model.v2.role,
            capabilities: model.v2.capabilities,
            artifacts: model.v2.artifacts,
            qualification: model.v2.qualification
        )
    }
    for id in retiredModelIDs.sorted() {
        guard let previous = v2ByID[id] else {
            throw ReleaseError.invalid("Unknown retirement ID: \(id)")
        }
        guard previous.availability ?? .active == .active else {
            throw ReleaseError.invalid("Model is already retired: \(id)")
        }
        guard previous.releaseSequence < UInt64.max else {
            throw ReleaseError.invalid("Model release sequence overflow for \(id)")
        }
        v2ByID[id] = CatalogModelV2(
            id: previous.id,
            availability: .retired,
            compatibilityKey: previous.compatibilityKey,
            releaseSequence: previous.releaseSequence + 1,
            revision: previous.revision,
            descriptor: previous.descriptor,
            sourceRevision: previous.sourceRevision,
            licenseIdentifier: previous.licenseIdentifier,
            role: previous.role,
            capabilities: previous.capabilities,
            artifacts: previous.artifacts,
            qualification: previous.qualification
        )
        v1ByID.removeValue(forKey: id)
    }
    guard !v1ByID.isEmpty || options.allowEmptyV1 else {
        if retiredModelIDs.isEmpty {
            throw ReleaseError.invalid("The initial release must include a legacy catalog-v1 model")
        }
        throw ReleaseError.invalid("Retirement would remove the final V1 model")
    }
    let catalogV1 = CatalogV1(models: v1ByID.values.sorted { $0.id < $1.id })
    let catalogV2 = CatalogV2(
        catalogSequence: options.catalogSequence,
        models: v2ByID.values.sorted { $0.id < $1.id }
    )
    try validateStrictReaders(options.strictReaders, previous: previousModels, candidate: catalogV2)
    try validateCatalogPair(v1: catalogV1, v2: catalogV2, baseURL: options.baseURL, recipes: options.recipes)
    try fileManager.createDirectory(at: options.output, withIntermediateDirectories: true)
    let catalogV1URL = options.output.appendingPathComponent("catalog-v1.json")
    let catalogV1Data = try writeJSON(catalogV1, to: catalogV1URL)
    let signatureV1URL = options.output.appendingPathComponent("catalog-v1.sig")
    try key.signature(for: catalogV1Data).write(to: signatureV1URL, options: .atomic)

    let catalogV2URL = options.output.appendingPathComponent("catalog-v2.json")
    let catalogV2Data = try writeJSON(catalogV2, to: catalogV2URL)
    let signatureV2URL = options.output.appendingPathComponent("catalog-v2.sig")
    try key.signature(for: catalogV2Data).write(to: signatureV2URL, options: .atomic)

    guard try JSONDecoder().decode(CatalogV1.self, from: catalogV1Data) == catalogV1,
        try JSONDecoder().decode(CatalogV2.self, from: catalogV2Data) == catalogV2,
        key.publicKey.isValidSignature(try Data(contentsOf: signatureV1URL), for: catalogV1Data),
        key.publicKey.isValidSignature(try Data(contentsOf: signatureV2URL), for: catalogV2Data)
    else {
        throw ReleaseError.invalid("Generated catalogs failed round-trip verification")
    }

    let pairFiles = [
        try fileDigest(catalogV1URL, path: "catalog-v1.json"),
        try fileDigest(signatureV1URL, path: "catalog-v1.sig"),
        try fileDigest(catalogV2URL, path: "catalog-v2.json"),
        try fileDigest(signatureV2URL, path: "catalog-v2.sig"),
    ].sorted { $0.path < $1.path }
    let pairManifest = ReleasePairManifest(
        catalogSequence: options.catalogSequence,
        repositoryRevision: options.repositoryRevision,
        releasedAt: options.releasedAt,
        files: pairFiles,
        models: catalogV2.models.map {
            .init(id: $0.id, revision: $0.revision, availability: $0.availability)
        }
    )
    let pairManifestURL = options.output.appendingPathComponent("release-pair.json")
    let pairManifestData = try writeJSON(pairManifest, to: pairManifestURL)
    let pairID = sha256(pairManifestData)
    try (pairID + "\n").write(
        to: options.output.appendingPathComponent("release-pair.sha256"),
        atomically: true,
        encoding: .utf8
    )

    let pointerObjects =
        pairFiles.map { file in
            ActivePairObject(
                name: file.path,
                path: "catalog-history/\(pairID)/\(file.path)",
                sha256: file.sha256,
                bytes: file.bytes
            )
        } + [
            ActivePairObject(
                name: "release-pair.json",
                path: "catalog-history/\(pairID)/release-pair.json",
                sha256: pairID,
                bytes: try fileSize(pairManifestURL)
            )
        ]
    let pointerPayload = ActivePairPayload(
        pairID: pairID,
        catalogSequence: options.catalogSequence,
        objects: pointerObjects
    )
    let pointerPayloadData = try canonicalJSON(pointerPayload)
    let pointerSignature = try key.signature(for: pointerPayloadData).base64EncodedString()
    let pointerURL = options.output.appendingPathComponent("active-pair.json")
    let pointerData = try writeJSON(
        ActivePairPointer(payload: pointerPayload, signature: pointerSignature),
        to: pointerURL
    )
    guard let pointerSignatureData = Data(base64Encoded: pointerSignature),
        key.publicKey.isValidSignature(pointerSignatureData, for: pointerPayloadData),
        try JSONDecoder().decode(ActivePairPointer.self, from: pointerData).payload == pointerPayload
    else {
        throw ReleaseError.invalid("Generated active catalog pointer failed verification")
    }

    let provenance = ReleaseProvenance(
        repositoryRevision: options.repositoryRevision,
        releasedAt: options.releasedAt,
        catalogSequence: options.catalogSequence,
        models: catalogV2.models.map {
            ReleaseProvenance.Entry(
                id: $0.id,
                availability: $0.availability,
                compatibilityKey: $0.compatibilityKey,
                sourceRevision: $0.sourceRevision,
                artifactRevision: $0.revision,
                artifacts: $0.artifacts,
                qualification: $0.qualification
            )
        }
    )
    let provenanceURL = options.output.appendingPathComponent("provenance-v1.json")
    _ = try writeJSON(provenance, to: provenanceURL)

    let evidenceBundle = ReleaseEvidenceBundle(models: prepared.map(\.evidence).sorted { $0.modelID < $1.modelID })
    let evidenceURL = options.output.appendingPathComponent("release-evidence-v1.json")
    _ = try writeJSON(evidenceBundle, to: evidenceURL)

    let noticesURL = options.output.appendingPathComponent("MODEL-LICENSES.txt")
    let notices =
        prepared
        .sorted { $0.v2.id < $1.v2.id }
        .map { "=== \($0.v2.id) \($0.v2.revision) ===\n\($0.notice.trimmingCharacters(in: .whitespacesAndNewlines))" }
        .joined(separator: "\n\n") + "\n"
    try notices.write(to: noticesURL, atomically: true, encoding: .utf8)

    let catalogRootURL = options.baseURL.deletingLastPathComponent()
    let sbom = SPDXDocument(
        name: "Encrypted Memories ML \(pairID.prefix(16))",
        documentNamespace:
            catalogRootURL
            .appendingPathComponent("model-releases/\(pairID)/sbom.spdx.json")
            .absoluteString,
        creationInfo: [
            "created": AnyEncodable(options.releasedAt),
            "creators": AnyEncodable(["Tool: Encrypted Memories prepare-ml-model-release.swift"]),
        ],
        packages: catalogV2.models.map { model in
            SPDXDocument.Package(
                spdxID: "SPDXRef-\(model.id)",
                name: model.id,
                versionInfo: model.revision,
                downloadLocation: options.baseURL
                    .appendingPathComponent("\(model.id)/\(model.revision)/")
                    .absoluteString,
                licenseConcluded: model.licenseIdentifier,
                licenseDeclared: model.licenseIdentifier
            )
        }
    )
    let sbomURL = options.output.appendingPathComponent("sbom.spdx.json")
    _ = try writeJSON(sbom, to: sbomURL)

    let historyFiles = [
        (catalogV1URL, "catalog-v1.json"),
        (signatureV1URL, "catalog-v1.sig"),
        (catalogV2URL, "catalog-v2.json"),
        (signatureV2URL, "catalog-v2.sig"),
        (pairManifestURL, "release-pair.json"),
    ]
    let metadataFiles = [
        (provenanceURL, "provenance-v1.json"),
        (evidenceURL, "release-evidence-v1.json"),
        (noticesURL, "MODEL-LICENSES.txt"),
        (sbomURL, "sbom.spdx.json"),
        (pairManifestURL, "release-pair.json"),
    ]
    let publishURL = options.output.appendingPathComponent("publish-r2.sh")
    let script = try uploadScript(
        options: options,
        prepared: prepared,
        historyFiles: historyFiles,
        metadataFiles: metadataFiles,
        pairID: pairID,
        catalogV1URL: catalogV1URL,
        signatureV1URL: signatureV1URL,
        catalogV2URL: catalogV2URL,
        signatureV2URL: signatureV2URL,
        pairManifestURL: pairManifestURL,
        pointerURL: pointerURL
    )
    try script.write(to: publishURL, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publishURL.path)

    print("Prepared \(prepared.count) compatible model update(s)")
    if !retiredModelIDs.isEmpty {
        print("Retired \(retiredModelIDs.count) model(s)")
    }
    print("Catalog sequence: \(options.catalogSequence)")
    print("Catalog pair: \(pairID)")
    print("Publication script: \(publishURL.path)")
    print("No remote state was changed")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
