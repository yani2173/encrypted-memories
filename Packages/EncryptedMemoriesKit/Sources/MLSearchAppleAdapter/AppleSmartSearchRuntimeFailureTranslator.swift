@preconcurrency import CoreML
import Foundation
import MLSearchCore

/// Translates Apple runtime errors into the Core-owned Smart Search taxonomy.
///
/// This boundary is intentionally conservative. A CoreML code is classified as retryable only
/// when the local SDK header documents a network or cancellation condition. Other framework
/// errors remain unknown and therefore retain Core's safe retryable fallback.
public enum AppleSmartSearchRuntimeFailureTranslator {
    public static func translate(_ error: Error) -> MLRuntimeFailure {
        if let failure = error as? MLRuntimeFailure {
            return failure
        }
        if error is CancellationError {
            return failure(category: .unknown, error: error)
        }
        if let error = error as? AppleSmartSearchRuntimeError {
            switch error {
            case .noModelArtifact:
                return failure(category: .missingModel, error: error)
            case .unsupportedTokenizer, .unsupportedPreprocessing:
                return failure(category: .incompatibleModel, error: error)
            case .tokenizerContractMismatch:
                return failure(category: .invalidStaticInputContract, error: error)
            case .invalidStaticInputContract:
                return failure(category: .invalidStaticInputContract, error: error)
            case .invalidOutputSchema:
                return failure(category: .invalidOutputSchema, error: error)
            }
        }
        if let error = error as? CoreMLDualEncoderError {
            switch error {
            case .descriptorMismatch:
                return failure(category: .incompatibleModel, error: error)
            case .invalidStaticInputContract:
                return failure(category: .invalidStaticInputContract, error: error)
            case .invalidOutputSchema, .invalidEmbedding:
                return failure(category: .invalidOutputSchema, error: error)
            }
        }
        if let urlError = error as? URLError {
            return failure(category: .network, error: urlError)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return failure(category: .network, error: nsError)
        }
        if nsError.domain == NSPOSIXErrorDomain,
            Self.isBoundedTemporaryPOSIXCode(nsError.code)
        {
            return failure(category: .temporaryResource, error: nsError)
        }
        if Self.isCoreMLDomain(nsError.domain),
            let category = Self.coreMLCategory(for: nsError.code)
        {
            return failure(category: category, error: nsError)
        }

        // Foundation frequently wraps a network, POSIX, or CoreML error. Preserve a typed
        // underlying disposition without classifying an unrelated outer NSError by its text.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let translated = translate(underlying)
            if translated.category != .unknown || translated.disposition != .unknown {
                return translated
            }
        }
        return failure(category: .unknown, error: error)
    }

    private static func failure(category: MLRuntimeFailureCategory, error: Error) -> MLRuntimeFailure {
        MLRuntimeFailure(category: category, debugDescription: String(describing: error))
    }

    private static func isCoreMLDomain(_ domain: String) -> Bool {
        // MLModelErrorDomain is exported by CoreML. The literal keeps this check testable without
        // requiring a framework symbol in callers that construct NSError fixtures themselves.
        domain == "com.apple.CoreML" || domain == "MLModelErrorDomain"
    }

    private static func isBoundedTemporaryPOSIXCode(_ code: Int) -> Bool {
        guard let code = Int32(exactly: code) else { return false }
        switch POSIXErrorCode(rawValue: code) {
        case .EAGAIN, .EBUSY, .EDQUOT, .ENOMEM, .ENOSPC:
            return true
        default:
            return false
        }
    }

    private static func coreMLCategory(for code: Int) -> MLRuntimeFailureCategory? {
        // Values and descriptions are from Xcode 26.6:
        // CoreML.framework/Headers/MLModelError.h.
        switch code {
        case 1:  // MLModelErrorFeatureType: client supplied the wrong input feature type.
            return .invalidStaticInputContract
        case 4, 5:  // MLModelErrorCustomLayer / MLModelErrorCustomModel.
            return .incompatibleModel
        case 7:  // MLModelErrorParameters: unsupported model parameter requested by the client.
            return .invalidStaticInputContract
        case 8, 10:
            // MLModelErrorModelDecryptionKeyFetch and MLModelErrorModelCollection document
            // network/key-server connectability failures.
            return .network
        case 11:
            // MLModelErrorPredictionCancelled is an explicitly documented cancellation state.
            return .retryableRuntimeState
        default:
            // Generic, I/O, decryption, update, and unknown codes are ambiguous here.
            return nil
        }
    }
}
