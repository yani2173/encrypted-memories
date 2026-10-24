import CryptoKit
import Foundation
import MLSearchCore

public enum MLRemoteCatalogTransportError: Error, Equatable {
    case notHTTPS
    case invalidHost
    case httpStatus(Int)
    case responseTooLarge
    case invalidSignature
    case invalidPublicKey
    case invalidAcceptedCatalogState
    case invalidActiveCatalogPointer
    case activeCatalogObjectMismatch(String)
    case activeCatalogSequenceMismatch
    case catalogRollback(accepted: UInt64, received: UInt64)
    case catalogSequenceReuse(UInt64)
    case modelReleaseRollback(modelID: String, accepted: UInt64, received: UInt64)
    case modelReleaseSequenceReuse(modelID: String, sequence: UInt64)
}

public enum MLRemoteCatalogVersion: Sendable, Equatable {
    case v1
    case v2
}

private struct ActiveCatalogObject: Codable, Equatable {
    let name: String
    let path: String
    let sha256: String
    let bytes: Int64
}

private struct ActiveCatalogPayload: Codable, Equatable {
    let schemaVersion: Int
    let pairID: String
    let catalogSequence: UInt64
    let objects: [ActiveCatalogObject]
}

private struct ActiveCatalogPointer: Codable, Equatable {
    let payload: ActiveCatalogPayload
    let signature: String
}

/// Fetches the signed distribution catalog and falls back to the last verified copy.
public actor SignedRemoteMLModelCatalogProvider: MLModelCatalogProvider {
    private struct AtomicPair {
        let pointer: ActiveCatalogPointer
        let pointerData: Data
        let catalogV1: Data
        let signatureV1: Data
        let catalogV2: Data
        let signatureV2: Data
        let pairManifest: Data
    }

    private struct ValidatedV2 {
        let resolved: MLModelCatalog
        let accepted: AcceptedCatalogState?
        let nextState: AcceptedCatalogState
        let sequence: UInt64
    }

    private struct AcceptedCatalogState: Codable, Equatable {
        struct Model: Codable, Equatable {
            let releaseSequence: UInt64
            let sha256: String
        }

        let sequence: UInt64
        let sha256: String
        let models: [String: Model]?
    }

    public static let catalogURL = URL(string: "https://models.oncloud.at/catalog-v1.json")!
    public static let artifactBaseURL = URL(string: "https://models.oncloud.at/models/")!

    private static let defaultSignatureURL = URL(string: "https://models.oncloud.at/catalog-v1.sig")!
    private static let publicKeyBase64 = "qXMyoYhp7TbPPXPAyEKDoy+kkl8He7I5RNXWgjNc5Kk="
    private static let maximumCatalogBytes = 1 << 20
    private static let acceptedStateLock = NSLock()

    private let trustedCatalog: MLModelCatalog
    private let catalogVersion: MLRemoteCatalogVersion
    private let cacheURL: URL
    private let signatureCacheURL: URL
    private let legacyCacheURL: URL
    private let legacySignatureCacheURL: URL
    private let acceptedStateURL: URL
    private let session: URLSession
    private let remoteCatalogURL: URL
    private let remoteSignatureURL: URL
    private let legacyRemoteCatalogURL: URL?
    private let legacyRemoteSignatureURL: URL?
    private let remoteArtifactBaseURL: URL
    private let publicKey: Data
    private let usesAtomicPointer: Bool
    private let pointerCacheURL: URL?
    private let releaseTrackOverride: MLModelReleaseTrack?

    public init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        endpoint: AppleSmartSearchCatalogEndpoint,
        session: URLSession = MLModelNetworkSession.shared,
        legacyCacheDirectory: URL? = nil
    ) {
        self.init(
            trustedCatalog: trustedCatalog,
            cacheDirectory: cacheDirectory,
            endpoint: endpoint,
            session: session,
            legacyCacheDirectory: legacyCacheDirectory,
            publicKey: Data(base64Encoded: Self.publicKeyBase64) ?? Data()
        )
    }

    init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        endpoint: AppleSmartSearchCatalogEndpoint,
        session: URLSession = MLModelNetworkSession.shared,
        legacyCacheDirectory: URL? = nil,
        publicKey: Data
    ) {
        self.init(
            trustedCatalog: trustedCatalog,
            cacheDirectory: cacheDirectory,
            session: session,
            catalogVersion: .v2,
            catalogURL: endpoint.activePairURL,
            signatureURL: endpoint.catalogV2SignatureURL,
            legacyCatalogURL: endpoint.channel == .production ? Self.catalogURL : nil,
            legacySignatureURL: endpoint.channel == .production ? Self.defaultSignatureURL : nil,
            legacyCacheDirectory: endpoint.channel == .production ? legacyCacheDirectory : nil,
            artifactBaseURL: endpoint.artifactBaseURL,
            publicKey: publicKey,
            releaseTrackOverride: endpoint.channel == .preview ? .developerOnly : nil
        )
    }

    init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        session: URLSession,
        catalogURL: URL,
        signatureURL: URL,
        artifactBaseURL: URL,
        publicKey: Data
    ) {
        self.init(
            trustedCatalog: trustedCatalog,
            cacheDirectory: cacheDirectory,
            session: session,
            catalogVersion: .v1,
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            legacyCatalogURL: nil,
            legacySignatureURL: nil,
            legacyCacheDirectory: nil,
            artifactBaseURL: artifactBaseURL,
            publicKey: publicKey
        )
    }

    public init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        version: MLRemoteCatalogVersion,
        session: URLSession = MLModelNetworkSession.shared,
        catalogURL: URL,
        signatureURL: URL,
        legacyCatalogURL: URL? = nil,
        legacySignatureURL: URL? = nil,
        legacyCacheDirectory: URL? = nil,
        artifactBaseURL: URL,
        publicKey: Data
    ) {
        self.init(
            trustedCatalog: trustedCatalog,
            cacheDirectory: cacheDirectory,
            session: session,
            catalogVersion: version,
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            legacyCatalogURL: legacyCatalogURL,
            legacySignatureURL: legacySignatureURL,
            legacyCacheDirectory: legacyCacheDirectory,
            artifactBaseURL: artifactBaseURL,
            publicKey: publicKey
        )
    }

    private init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        session: URLSession,
        catalogVersion: MLRemoteCatalogVersion,
        catalogURL: URL,
        signatureURL: URL,
        legacyCatalogURL: URL?,
        legacySignatureURL: URL?,
        legacyCacheDirectory: URL?,
        artifactBaseURL: URL,
        publicKey: Data,
        releaseTrackOverride: MLModelReleaseTrack? = nil
    ) {
        self.trustedCatalog = trustedCatalog
        self.catalogVersion = catalogVersion
        let versionName = catalogVersion == .v2 ? "catalog-v2" : "catalog-v1"
        self.cacheURL = cacheDirectory.appendingPathComponent(versionName + ".json")
        self.signatureCacheURL = cacheDirectory.appendingPathComponent(versionName + ".sig")
        let legacyDirectory = legacyCacheDirectory ?? cacheDirectory
        self.legacyCacheURL = legacyDirectory.appendingPathComponent("catalog-v1.json")
        self.legacySignatureCacheURL = legacyDirectory.appendingPathComponent("catalog-v1.sig")
        self.acceptedStateURL = cacheDirectory.appendingPathComponent("catalog-v2.accepted.json")
        self.session = session
        self.remoteCatalogURL = catalogURL
        self.remoteSignatureURL = signatureURL
        self.legacyRemoteCatalogURL = legacyCatalogURL
        self.legacyRemoteSignatureURL = legacySignatureURL
        self.remoteArtifactBaseURL = artifactBaseURL
        self.publicKey = publicKey
        self.releaseTrackOverride = releaseTrackOverride
        self.usesAtomicPointer =
            catalogVersion == .v2
            && catalogURL.lastPathComponent == "active-pair.json"
        if self.usesAtomicPointer {
            let pointerDirectory = cacheDirectory.appendingPathComponent("active-pair", isDirectory: true)
            self.pointerCacheURL = pointerDirectory.appendingPathComponent("active-pair.json")
        } else {
            self.pointerCacheURL = nil
        }
    }

    /// The configuration of the session that fetches signed catalogs.
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public func catalog() async throws -> MLModelCatalog {
        switch catalogVersion {
        case .v1:
            return try await fetchV1OrCached()
        case .v2:
            do {
                return try await fetchV2OrCached()
            } catch let primaryError {
                guard legacyRemoteCatalogURL != nil,
                    legacyRemoteSignatureURL != nil,
                    try acceptedCatalogState() == nil
                else { throw primaryError }
                if let fallback = try? await fetchLegacyV1OrCached() { return fallback }
                throw primaryError
            }
        }
    }

    private func fetchV1OrCached() async throws -> MLModelCatalog {
        do {
            return try await fetchV1(
                catalogURL: remoteCatalogURL,
                signatureURL: remoteSignatureURL,
                cacheURL: cacheURL,
                signatureCacheURL: signatureCacheURL
            )
        } catch let primaryError {
            guard let document = try? Data(contentsOf: cacheURL),
                let signature = try? Data(contentsOf: signatureCacheURL)
            else { throw primaryError }
            return try verifyAndResolveV1(document: document, signature: signature)
        }
    }

    private func fetchV2OrCached() async throws -> MLModelCatalog {
        if usesAtomicPointer {
            return try await fetchAtomicPairOrCached()
        }
        do {
            async let documentData = fetch(remoteCatalogURL, maximumBytes: Self.maximumCatalogBytes)
            async let signatureData = fetch(remoteSignatureURL, maximumBytes: 128)
            let (document, signature) = try await (documentData, signatureData)
            return try acceptV2(document: document, signature: signature)
        } catch let primaryError {
            guard let document = try? Data(contentsOf: cacheURL),
                let signature = try? Data(contentsOf: signatureCacheURL)
            else { throw primaryError }
            return try acceptV2(document: document, signature: signature)
        }
    }

    private func fetchAtomicPairOrCached() async throws -> MLModelCatalog {
        do {
            let pointerData = try await fetch(remoteCatalogURL, maximumBytes: 64 * 1024)
            let pair = try await fetchAtomicPair(pointerData: pointerData)
            return try acceptAtomicPair(pair)
        } catch let primaryError {
            guard let pair = try? loadCachedAtomicPair() else { throw primaryError }
            return try acceptAtomicPair(pair, cache: false)
        }
    }

    private func fetchLegacyV1OrCached() async throws -> MLModelCatalog {
        do {
            guard let catalogURL = legacyRemoteCatalogURL,
                let signatureURL = legacyRemoteSignatureURL
            else {
                throw URLError(.resourceUnavailable)
            }
            return try await fetchV1(
                catalogURL: catalogURL,
                signatureURL: signatureURL,
                cacheURL: legacyCacheURL,
                signatureCacheURL: legacySignatureCacheURL
            )
        } catch let primaryError {
            guard let document = try? Data(contentsOf: legacyCacheURL),
                let signature = try? Data(contentsOf: legacySignatureCacheURL)
            else {
                throw primaryError
            }
            return try verifyAndResolveV1(document: document, signature: signature)
        }
    }

    private func fetchAtomicPair(pointerData: Data) async throws -> AtomicPair {
        let pointer = try decodeAndValidatePointer(pointerData)
        var dataByName: [String: Data] = [:]
        for object in pointer.payload.objects {
            let url = try pointerObjectURL(object.path)
            let data = try await fetch(
                url,
                maximumBytes: object.name.hasSuffix(".sig") ? 128 : Self.maximumCatalogBytes
            )
            guard data.count == object.bytes,
                sha256(data) == object.sha256
            else {
                throw MLRemoteCatalogTransportError.activeCatalogObjectMismatch(object.name)
            }
            dataByName[object.name] = data
        }
        guard let catalogV1 = dataByName["catalog-v1.json"],
            let signatureV1 = dataByName["catalog-v1.sig"],
            let catalogV2 = dataByName["catalog-v2.json"],
            let signatureV2 = dataByName["catalog-v2.sig"],
            let pairManifest = dataByName["release-pair.json"]
        else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        guard sha256(pairManifest) == pointer.payload.pairID else {
            throw MLRemoteCatalogTransportError.activeCatalogObjectMismatch("release-pair.json")
        }
        return AtomicPair(
            pointer: pointer,
            pointerData: pointerData,
            catalogV1: catalogV1,
            signatureV1: signatureV1,
            catalogV2: catalogV2,
            signatureV2: signatureV2,
            pairManifest: pairManifest
        )
    }

    private func loadCachedAtomicPair() throws -> AtomicPair {
        guard let pointerURL = pointerCacheURL else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        let pointerData = try Data(contentsOf: pointerURL)
        let pointer = try decodeAndValidatePointer(pointerData)
        let pairDirectory = pointerURL.deletingLastPathComponent()
            .appendingPathComponent(pointer.payload.pairID, isDirectory: true)
        let catalogV1URL = pairDirectory.appendingPathComponent("catalog-v1.json")
        let signatureV1URL = pairDirectory.appendingPathComponent("catalog-v1.sig")
        let catalogV2URL = pairDirectory.appendingPathComponent("catalog-v2.json")
        let signatureV2URL = pairDirectory.appendingPathComponent("catalog-v2.sig")
        let pairManifestURL = pairDirectory.appendingPathComponent("release-pair.json")
        let values = try [
            ("catalog-v1.json", Data(contentsOf: catalogV1URL)),
            ("catalog-v1.sig", Data(contentsOf: signatureV1URL)),
            ("catalog-v2.json", Data(contentsOf: catalogV2URL)),
            ("catalog-v2.sig", Data(contentsOf: signatureV2URL)),
            ("release-pair.json", Data(contentsOf: pairManifestURL)),
        ]
        for (name, data) in values {
            guard let object = pointer.payload.objects.first(where: { $0.name == name }),
                data.count == object.bytes,
                sha256(data) == object.sha256
            else {
                throw MLRemoteCatalogTransportError.activeCatalogObjectMismatch(name)
            }
        }
        guard let catalogV1 = values.first(where: { $0.0 == "catalog-v1.json" })?.1,
            let signatureV1 = values.first(where: { $0.0 == "catalog-v1.sig" })?.1,
            let catalogV2 = values.first(where: { $0.0 == "catalog-v2.json" })?.1,
            let signatureV2 = values.first(where: { $0.0 == "catalog-v2.sig" })?.1,
            let pairManifest = values.first(where: { $0.0 == "release-pair.json" })?.1
        else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        guard sha256(pairManifest) == pointer.payload.pairID else {
            throw MLRemoteCatalogTransportError.activeCatalogObjectMismatch("release-pair.json")
        }
        return AtomicPair(
            pointer: pointer,
            pointerData: pointerData,
            catalogV1: catalogV1,
            signatureV1: signatureV1,
            catalogV2: catalogV2,
            signatureV2: signatureV2,
            pairManifest: pairManifest
        )
    }

    private func pointerObjectURL(_ path: String) throws -> URL {
        guard isSafePointerPath(path),
            let host = remoteCatalogURL.host?.lowercased(),
            remoteArtifactBaseURL.host?.lowercased() == host
        else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        let base = remoteCatalogURL.deletingLastPathComponent()
        let url = base.appendingPathComponent(path)
        guard url.scheme?.lowercased() == "https",
            url.host?.lowercased() == host,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw MLRemoteCatalogTransportError.invalidHost
        }
        return url
    }

    private func decodeAndValidatePointer(_ data: Data) throws -> ActiveCatalogPointer {
        let pointer = try JSONDecoder().decode(ActiveCatalogPointer.self, from: data)
        guard pointer.payload.schemaVersion == 1,
            pointer.payload.catalogSequence > 0,
            pointer.payload.pairID.count == 64,
            pointer.payload.pairID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            let signature = Data(base64Encoded: pointer.signature),
            signature.count == 64,
            pointer.payload.objects.count == 5
        else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        let expectedNames: Set<String> = [
            "catalog-v1.json", "catalog-v1.sig", "catalog-v2.json", "catalog-v2.sig", "release-pair.json",
        ]
        guard Set(pointer.payload.objects.map(\.name)) == expectedNames,
            pointer.payload.objects.allSatisfy({ object in
                object.bytes > 0
                    && object.sha256.count == 64
                    && object.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                    && isSafePointerPath(object.path)
                    && object.path == "catalog-history/\(pointer.payload.pairID)/\(object.name)"
            })
        else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payloadData = try? encoder.encode(pointer.payload),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
            publicKey.isValidSignature(signature, for: payloadData)
        else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        return pointer
    }

    private func isSafePointerPath(_ path: String) -> Bool {
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            path.removingPercentEncoding == path,
            !path.contains("?"),
            !path.contains("#")
        else { return false }
        return !path.split(separator: "/").contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fetchV1(
        catalogURL: URL,
        signatureURL: URL,
        cacheURL: URL,
        signatureCacheURL: URL
    ) async throws -> MLModelCatalog {
        async let documentData = fetch(catalogURL, maximumBytes: Self.maximumCatalogBytes)
        async let signatureData = fetch(signatureURL, maximumBytes: 128)
        let (document, signature) = try await (documentData, signatureData)
        let resolved = try verifyAndResolveV1(document: document, signature: signature)
        try cache(
            document: document,
            signature: signature,
            cacheURL: cacheURL,
            signatureCacheURL: signatureCacheURL
        )
        return resolved
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw MLRemoteCatalogTransportError.notHTTPS }
        let allowedHosts = [
            remoteCatalogURL.host,
            remoteSignatureURL.host,
            legacyRemoteCatalogURL?.host,
            legacyRemoteSignatureURL?.host,
        ].compactMap { $0?.lowercased() }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            throw MLRemoteCatalogTransportError.invalidHost
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        MLModelRequestIdentity.apply(to: &request)
        let (data, response) = try await session.data(
            for: request,
            delegate: MLModelNoRedirectDelegate.shared
        )
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard MLModelRequestIdentity.isExactEndpoint(http.url, expected: url) else {
            throw MLRemoteCatalogTransportError.invalidHost
        }
        guard http.statusCode == 200 else { throw MLRemoteCatalogTransportError.httpStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw MLRemoteCatalogTransportError.responseTooLarge }
        return data
    }

    private func verifySignature(_ document: Data, signature: Data) throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw MLRemoteCatalogTransportError.invalidPublicKey
        }
        guard key.isValidSignature(signature, for: document) else {
            throw MLRemoteCatalogTransportError.invalidSignature
        }
    }

    private func verifyAndResolveV1(document: Data, signature: Data) throws -> MLModelCatalog {
        try verifySignature(document, signature: signature)
        let decoded = try JSONDecoder().decode(MLRemoteModelCatalogDocument.self, from: document)
        return try MLRemoteModelCatalogResolver(
            trustedCatalog: trustedCatalog,
            allowedBaseURL: remoteArtifactBaseURL
        ).resolve(decoded)
    }

    private func acceptV2(document: Data, signature: Data) throws -> MLModelCatalog {
        Self.acceptedStateLock.lock()
        defer { Self.acceptedStateLock.unlock() }
        let validated = try validateV2(document: document, signature: signature)
        try cache(
            document: document,
            signature: signature,
            cacheURL: cacheURL,
            signatureCacheURL: signatureCacheURL
        )
        if validated.accepted != validated.nextState {
            try persistAcceptedCatalogState(validated.nextState)
        }
        return validated.resolved
    }

    private func validateV2(document: Data, signature: Data) throws -> ValidatedV2 {
        try verifySignature(document, signature: signature)
        let decoded = try JSONDecoder().decode(MLRemoteModelCatalogDocumentV2.self, from: document)
        let digest = sha256(document)
        let accepted = try acceptedCatalogState()
        if let accepted {
            guard decoded.catalogSequence >= accepted.sequence else {
                throw MLRemoteCatalogTransportError.catalogRollback(
                    accepted: accepted.sequence,
                    received: decoded.catalogSequence
                )
            }
            if decoded.catalogSequence == accepted.sequence, digest != accepted.sha256 {
                throw MLRemoteCatalogTransportError.catalogSequenceReuse(decoded.catalogSequence)
            }
        }
        var acceptedModels = accepted?.models ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for model in decoded.models {
            let modelID = model.id.rawValue
            let modelDigest = SHA256.hash(data: try encoder.encode(model))
                .map { String(format: "%02x", $0) }
                .joined()
            if let previous = acceptedModels[modelID] {
                guard model.releaseSequence >= previous.releaseSequence else {
                    throw MLRemoteCatalogTransportError.modelReleaseRollback(
                        modelID: modelID,
                        accepted: previous.releaseSequence,
                        received: model.releaseSequence
                    )
                }
                if model.releaseSequence == previous.releaseSequence,
                    modelDigest != previous.sha256
                {
                    throw MLRemoteCatalogTransportError.modelReleaseSequenceReuse(
                        modelID: modelID,
                        sequence: model.releaseSequence
                    )
                }
            }
            acceptedModels[modelID] = .init(
                releaseSequence: model.releaseSequence,
                sha256: modelDigest
            )
        }
        let resolved = try MLRemoteModelCatalogResolver(
            trustedCatalog: trustedCatalog,
            allowedBaseURL: remoteArtifactBaseURL
        ).resolve(decoded)
        let appResolved: MLModelCatalog
        if let releaseTrackOverride {
            appResolved = MLModelCatalog(
                entries: resolved.entries.map { $0.withReleaseTrack(releaseTrackOverride) }
            )
        } else {
            appResolved = resolved
        }
        let nextState = AcceptedCatalogState(
            sequence: decoded.catalogSequence,
            sha256: digest,
            models: acceptedModels
        )
        return ValidatedV2(
            resolved: appResolved,
            accepted: accepted,
            nextState: nextState,
            sequence: decoded.catalogSequence
        )
    }

    private func acceptAtomicPair(_ pair: AtomicPair, cache shouldCache: Bool = true) throws -> MLModelCatalog {
        _ = try verifyAndResolveV1(document: pair.catalogV1, signature: pair.signatureV1)
        let pointerV2 = try JSONDecoder().decode(
            MLRemoteModelCatalogDocumentV2.self,
            from: pair.catalogV2
        )
        guard pointerV2.catalogSequence == pair.pointer.payload.catalogSequence else {
            throw MLRemoteCatalogTransportError.activeCatalogSequenceMismatch
        }
        Self.acceptedStateLock.lock()
        defer { Self.acceptedStateLock.unlock() }
        let validated = try validateV2(document: pair.catalogV2, signature: pair.signatureV2)
        guard validated.sequence == pair.pointer.payload.catalogSequence else {
            throw MLRemoteCatalogTransportError.activeCatalogSequenceMismatch
        }
        if shouldCache {
            try cacheAtomicPair(pair)
        }
        if validated.accepted != validated.nextState {
            try persistAcceptedCatalogState(validated.nextState)
        }
        return validated.resolved
    }

    private func cacheAtomicPair(_ pair: AtomicPair) throws {
        guard let pointerURL = pointerCacheURL else {
            throw MLRemoteCatalogTransportError.invalidActiveCatalogPointer
        }
        let fileManager = FileManager.default
        let pairDirectory = pointerURL.deletingLastPathComponent()
            .appendingPathComponent(pair.pointer.payload.pairID, isDirectory: true)
        try fileManager.createDirectory(at: pairDirectory, withIntermediateDirectories: true)
        let catalogV1URL = pairDirectory.appendingPathComponent("catalog-v1.json")
        let signatureV1URL = pairDirectory.appendingPathComponent("catalog-v1.sig")
        let catalogV2URL = pairDirectory.appendingPathComponent("catalog-v2.json")
        let signatureV2URL = pairDirectory.appendingPathComponent("catalog-v2.sig")
        let pairManifestURL = pairDirectory.appendingPathComponent("release-pair.json")
        try pair.catalogV1.write(to: catalogV1URL, options: Self.cacheWritingOptions)
        try pair.signatureV1.write(to: signatureV1URL, options: Self.cacheWritingOptions)
        try pair.catalogV2.write(to: catalogV2URL, options: Self.cacheWritingOptions)
        try pair.signatureV2.write(to: signatureV2URL, options: Self.cacheWritingOptions)
        try pair.pairManifest.write(to: pairManifestURL, options: Self.cacheWritingOptions)
        try pair.pointerData.write(to: pointerURL, options: Self.cacheWritingOptions)
    }

    private func cache(
        document: Data,
        signature: Data,
        cacheURL: URL,
        signatureCacheURL: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: cacheURL, options: Self.cacheWritingOptions)
        try signature.write(to: signatureCacheURL, options: Self.cacheWritingOptions)
    }

    private func acceptedCatalogState() throws -> AcceptedCatalogState? {
        guard FileManager.default.fileExists(atPath: acceptedStateURL.path) else { return nil }
        guard let data = try? Data(contentsOf: acceptedStateURL),
            let state = try? JSONDecoder().decode(AcceptedCatalogState.self, from: data),
            state.sequence > 0,
            state.sha256.count == 64,
            state.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            (state.models ?? [:]).allSatisfy({ id, model in
                !id.isEmpty
                    && model.releaseSequence > 0
                    && model.sha256.count == 64
                    && model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            })
        else {
            throw MLRemoteCatalogTransportError.invalidAcceptedCatalogState
        }
        return state
    }

    private func persistAcceptedCatalogState(_ state: AcceptedCatalogState) throws {
        try FileManager.default.createDirectory(
            at: acceptedStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(
            to: acceptedStateURL,
            options: Self.cacheWritingOptions
        )
    }

    private static var cacheWritingOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUnlessOpen]
        #else
            .atomic
        #endif
    }
}
