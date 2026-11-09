@preconcurrency import CoreML
import Foundation
import MLSearchCore
import PhotosCore

public enum AppleSmartSearchRuntimeError: Error, Equatable {
    case noModelArtifact
    case unsupportedTokenizer(String)
    case unsupportedPreprocessing(String)
    /// The catalog-declared runtime contract and the resolved tokenizer disagree; the
    /// session must not start with mismatched text inputs.
    case tokenizerContractMismatch(expected: Int, actual: Int)
    case invalidStaticInputContract(String)
    case invalidOutputSchema(String)
}

/// Builds CoreML-backed Smart Search sessions for verified installations.
///
/// Owns the CoreML specifics Core must never see: locating the model artifact inside the
/// install directory, one-time compilation of `.mlpackage` artifacts, tokenizer resolution by
/// catalog identity, and the ANE-first compute policy (via `CoreMLDualEncoder`).
public struct AppleSmartSearchRuntimeProvider: MLSmartSearchRuntimeProvider {
    private let imageSource: any CoreMLImageSource
    private let runnerConfiguration: MLIndexRunner.Configuration

    public init(
        imageSource: any CoreMLImageSource,
        runnerConfiguration: MLIndexRunner.Configuration = .init()
    ) {
        self.imageSource = imageSource
        self.runnerConfiguration = runnerConfiguration
    }

    public func makeSession(
        model: MLInstalledModel,
        store: any MLIndexStore,
        shouldContinueIndexing: @escaping @Sendable () -> Bool
    ) async throws -> any MLSmartSearchSession {
        do {
            let modelURL = try await Self.loadableModelURL(
                artifactURL: model.installDirectory.appendingPathComponent(model.record.modelRootPath),
                runtimeCacheDirectory: model.runtimeCacheDirectory
            )
            let tokenizer = try Self.tokenizer(for: model.entry.tokenizerID, installDirectory: model.installDirectory)
            // The catalog entry's runtime contract is validated END TO END before activation:
            // tokenizer identity here, function/input/output names, context length, image size
            // and embedding dimension inside the encoder against the loaded artifact.
            let contract = model.entry.runtimeContract
            guard tokenizer.contextLength == contract.textContextLength else {
                throw AppleSmartSearchRuntimeError.tokenizerContractMismatch(
                    expected: contract.textContextLength,
                    actual: tokenizer.contextLength
                )
            }
            var schema = CoreMLDualEncoderSchema(contract: contract)
            schema.imageCropMode = try Self.cropMode(for: model.entry.preprocessingID)
            let encoder = try await CoreMLDualEncoder(
                modelURL: modelURL,
                descriptor: model.entry.descriptor,
                imageSource: imageSource,
                tokenizer: tokenizer,
                schema: schema
            )
            return MLSearchService(
                descriptor: model.entry.descriptor,
                store: store,
                assetEmbedder: encoder,
                textEncoder: encoder,
                scorer: AccelerateVectorScorer(),
                relevancePolicy: model.entry.relevancePolicy,
                runnerConfiguration: runnerConfiguration,
                shouldContinue: shouldContinueIndexing,
                releaseInferenceResources: { await encoder.releaseModel() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MLRuntimeFailure {
            throw failure
        } catch {
            throw AppleSmartSearchRuntimeFailureTranslator.translate(error)
        }
    }

    /// Pixel path by preprocessing identity: CLIP recipes center-crop, SigLIP recipes
    /// squash-resize. Unknown recipes refuse activation instead of guessing.
    static func cropMode(for preprocessingID: String) throws -> CoreMLImageCropMode {
        switch preprocessingID {
        case "clip-centercrop-224": return .centerCrop
        case "siglip-resize-256": return .scaleFill
        default: throw AppleSmartSearchRuntimeError.unsupportedPreprocessing(preprocessingID)
        }
    }

    /// Tokenizer resolution by catalog identity. CLIP-BPE ships bundled (small, shared by
    /// every CLIP-family entry); SentencePiece vocabularies are large and model-specific, so
    /// they live inside the verified artifact (`tokenizer.json`, hash-checked like weights).
    private static func tokenizer(for tokenizerID: String, installDirectory: URL) throws -> any MLTextTokenizer {
        switch tokenizerID {
        case "clip-bpe-77":
            return try CLIPBPETokenizer.bundledTinyCLIP()
        case "gemma-sentencepiece-64":
            return try SentencePieceBPETokenizer(
                fileURL: installDirectory.appendingPathComponent("tokenizer.json")
            )
        default:
            throw AppleSmartSearchRuntimeError.unsupportedTokenizer(tokenizerID)
        }
    }

    /// Returns a compiled model from the verified artifact root. Package output is rebuilt before
    /// each activation and stays outside the verified installation directory.
    static func loadableModelURL(
        artifactURL: URL,
        runtimeCacheDirectory: URL
    ) async throws -> URL {
        let fm = FileManager.default
        let values = try? artifactURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw AppleSmartSearchRuntimeError.noModelArtifact
        }
        switch artifactURL.pathExtension.lowercased() {
        case "mlmodelc":
            return artifactURL
        case "mlpackage":
            break
        default:
            throw AppleSmartSearchRuntimeError.noModelArtifact
        }

        try? fm.removeItem(at: runtimeCacheDirectory)
        try fm.createDirectory(at: runtimeCacheDirectory, withIntermediateDirectories: true)
        let cached = runtimeCacheDirectory.appendingPathComponent(
            artifactURL.deletingPathExtension().lastPathComponent + ".mlmodelc",
            isDirectory: true
        )
        let compiled = try await MLModel.compileModel(at: artifactURL)
        do {
            try fm.moveItem(at: compiled, to: cached)
        } catch {
            try? fm.removeItem(at: compiled)
            throw error
        }
        return cached
    }
}
