import Foundation

/// Framework-neutral identifiers for local image-analysis operations.
///
/// Core owns the product vocabulary while an adapter decides which operating-system or model
/// implementation satisfies it. Keeping these identifiers independent prevents Vision request
/// types and OS checks from leaking into scheduling, persistence, or presentation.
public enum MLNativeAnalysisKind: String, CaseIterable, Codable, Hashable, Sendable {
    case textRecognition
    case documentRecognition
    case barcodeDetection
    case documentSegmentation
    case imageClassification
    case animalRecognition
    case humanDetection
    case imageFeaturePrint
    case faceDetection
    case faceLandmarks
    case faceCaptureQuality
    case animalBodyPose
    case foregroundInstanceMask
    case personInstanceMask
    case personSegmentation
    case imageAesthetics
    case attentionSaliency
    case objectnessSaliency
    case lensSmudgeDetection
    case humanBodyPose
    case humanHandPose
    case humanBodyPose3D
    case contours
    case horizon
    case rectangles
    case textRectangles
    case trajectories
    /// Pairwise optical flow between an explicit source and reference image through the legacy
    /// targeted-image request. This remains distinct from stateful frame-to-frame tracking.
    case pairwiseOpticalFlow
    case opticalFlow
    case objectTracking
    case rectangleTracking
    case translationalImageRegistration
    case homographicImageRegistration
    /// iOS/macOS 27 interactive subject segmentation. It requires a user-supplied seed and
    /// downloadable Apple assets, so capability discovery exposes it without scheduling a
    /// whole-library pass.
    case iterativeSegmentation
}

/// Scheduling contract for a native capability. Runtime availability remains a separate fact:
/// an indexed request can still be unavailable on the current OS or hardware without becoming an
/// analysis failure.
public enum MLNativeAnalysisExecutionMode: String, CaseIterable, Codable, Hashable, Sendable {
    case indexed
    case onDemand
    case temporalOrPairwise
    case unsupported
}

public enum MLNativeAnalysisUnavailableReason: String, Codable, Hashable, Sendable {
    case operatingSystem
    case hardware
    case runtime
    case probeFailed
}

public enum MLNativeAnalysisAvailability: Codable, Equatable, Hashable, Sendable {
    case available
    case unavailable(MLNativeAnalysisUnavailableReason)
}

public enum MLNativeAnalysisComputeStage: String, Codable, Hashable, Sendable {
    case main
    case postProcessing
    case other
}

public enum MLNativeAnalysisComputeDevice: String, Codable, Hashable, Sendable {
    case cpu
    case gpu
    case neuralEngine
    case other
}

public struct MLNativeAnalysisComputeSupport: Codable, Equatable, Hashable, Sendable {
    public let stage: MLNativeAnalysisComputeStage
    public let devices: [MLNativeAnalysisComputeDevice]

    public init(stage: MLNativeAnalysisComputeStage, devices: [MLNativeAnalysisComputeDevice]) {
        self.stage = stage
        self.devices = devices
    }
}

/// Runtime facts about one native analysis operation.
///
/// `selectedRevision` is explicit because derived data must never silently change output space
/// after an OS update. The optional vocabulary arrays are introspection only; they do not imply
/// that a corresponding persistent index or user-visible search scope exists.
public struct MLNativeAnalysisCapability: Codable, Equatable, Hashable, Sendable {
    public let kind: MLNativeAnalysisKind
    public let implementationIdentifier: String
    public let executionMode: MLNativeAnalysisExecutionMode
    public let availability: MLNativeAnalysisAvailability
    public let selectedRevision: String?
    public let supportedRevisions: [String]
    public let supportedLanguages: [String]
    public let supportedIdentifiers: [String]
    public let supportedAnimals: [String]
    public let supportedSymbologies: [String]
    public let computeSupport: [MLNativeAnalysisComputeSupport]

    public init(
        kind: MLNativeAnalysisKind,
        implementationIdentifier: String,
        executionMode: MLNativeAnalysisExecutionMode = .indexed,
        availability: MLNativeAnalysisAvailability,
        selectedRevision: String?,
        supportedRevisions: [String],
        supportedLanguages: [String] = [],
        supportedIdentifiers: [String] = [],
        supportedAnimals: [String] = [],
        supportedSymbologies: [String] = [],
        computeSupport: [MLNativeAnalysisComputeSupport] = []
    ) {
        self.kind = kind
        self.implementationIdentifier = implementationIdentifier
        self.executionMode = executionMode
        self.availability = availability
        self.selectedRevision = selectedRevision
        self.supportedRevisions = supportedRevisions
        self.supportedLanguages = supportedLanguages
        self.supportedIdentifiers = supportedIdentifiers
        self.supportedAnimals = supportedAnimals
        self.supportedSymbologies = supportedSymbologies
        self.computeSupport = computeSupport
    }

    public var isAvailable: Bool { availability == .available }
}

/// One immutable result of adapter capability discovery.
public struct MLNativeAnalysisCapabilitySnapshot: Codable, Equatable, Sendable {
    public let providerIdentifier: String
    public let sdkIdentifier: String
    public let capabilities: [MLNativeAnalysisCapability]

    public init(
        providerIdentifier: String,
        sdkIdentifier: String,
        capabilities: [MLNativeAnalysisCapability]
    ) {
        self.providerIdentifier = providerIdentifier
        self.sdkIdentifier = sdkIdentifier
        self.capabilities = capabilities
    }

    public func capability(for kind: MLNativeAnalysisKind) -> MLNativeAnalysisCapability? {
        capabilities.first { $0.kind == kind }
    }
}

public protocol MLNativeAnalysisCapabilityProvider: Sendable {
    func capabilitySnapshot() async -> MLNativeAnalysisCapabilitySnapshot
}

/// Capability- and memory-based concurrency budget for whole-library native analysis.
///
/// Vision selects the concrete compute device for each request stage. Core therefore limits
/// decoded assets in flight instead of creating competing CPU/GPU/ANE queues whose actual device
/// use the framework may change between request revisions.
public enum MLNativeAnalysisResourcePolicy {
    public static func maximumConcurrentAssets(
        capabilitySnapshot: MLNativeAnalysisCapabilitySnapshot,
        physicalMemoryBytes: UInt64
    ) -> Int {
        let indexed = capabilitySnapshot.capabilities.filter {
            $0.isAvailable && $0.executionMode == .indexed
        }
        let hasAcceleratedStage = indexed.contains { capability in
            capability.computeSupport.contains { support in
                support.devices.contains(.neuralEngine) || support.devices.contains(.gpu)
            }
        }
        guard hasAcceleratedStage else { return 1 }

        switch physicalMemoryBytes {
        case ..<6_000_000_000:
            return 1
        case ..<12_000_000_000:
            return 2
        default:
            return 3
        }
    }
}

/// Searchable data providers are deliberately separate from device capability. A request being
/// available does not mean its encrypted index has been built or can answer a query.
public enum MLSearchBackend: String, Codable, Hashable, Sendable {
    case semantic
    case recognizedText
    case documentText
    case barcodePayload
    case visualSimilarity
}

public enum MLSearchScope: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case semantic
    case text
    case documents
    case barcodes
    case similar
}

public enum MLSearchScopePolicy {
    public static func availableScopes(for backends: Set<MLSearchBackend>) -> [MLSearchScope] {
        guard !backends.isEmpty else { return [] }

        // Keep the product UI deliberately broad: Smart Search combines every available local
        // backend, while OCR narrows results to human-readable text found in images and structured
        // documents. The finer-grained cases remain typed query contracts for diagnostics and
        // future product work, but exposing every pipeline as a search control would leak the
        // implementation into the shared macOS/iOS experience.
        let ocrBackends: Set<MLSearchBackend> = [.recognizedText, .documentText]
        return backends.isDisjoint(with: ocrBackends) ? [.all] : [.all, .text]
    }
}
