import Foundation

public struct MLNormalizedRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
            x >= 0, y >= 0, width >= 0, height >= 0,
            x + width <= 1, y + height <= 1
        else {
            throw MLAnalysisContractError.invalidNormalizedBounds
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: values.decode(Double.self, forKey: .x),
            y: values.decode(Double.self, forKey: .y),
            width: values.decode(Double.self, forKey: .width),
            height: values.decode(Double.self, forKey: .height)
        )
    }
}

public enum MLRegionSpecies: String, Codable, CaseIterable, Hashable, Sendable {
    case human
    case cat
    case dog
}

public struct MLDescriptorSpace: Codable, Equatable, Hashable, Sendable {
    public let identifier: String
    public let revision: Int
    public let dimension: Int

    public init(identifier: String, revision: Int, dimension: Int) throws {
        guard !identifier.isEmpty, revision > 0, dimension > 0 else {
            throw MLAnalysisContractError.invalidDescriptorSpace
        }
        self.identifier = identifier
        self.revision = revision
        self.dimension = dimension
    }

    private enum CodingKeys: String, CodingKey { case identifier, revision, dimension }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: values.decode(String.self, forKey: .identifier),
            revision: values.decode(Int.self, forKey: .revision),
            dimension: values.decode(Int.self, forKey: .dimension)
        )
    }

    var stableComponent: String { "\(identifier)@\(revision):\(dimension)" }
}

public enum MLAnalysisOutputDescriptor: Codable, Equatable, Hashable, Sendable {
    case semanticEmbedding(MLDescriptorSpace)
    case recognizedText
    case structuredDocument
    case barcodePayload
    case classifications
    case regions(labels: [String], species: [MLRegionSpecies], landmarkSchema: String?)
    /// Vision feature prints are opaque, revision-scoped byte vectors. Their element count and
    /// type are runtime output facts, not stable catalog metadata.
    case featurePrint
    case regionEmbedding(space: MLDescriptorSpace, species: MLRegionSpecies?)
    case qualityMetrics
    case saliency
    case mask(format: MLMaskFormat)
    case geometry

    public var embeddingDimension: Int? {
        switch self {
        case .semanticEmbedding(let space): space.dimension
        case .regionEmbedding(let space, _): space.dimension
        default: nil
        }
    }

    var stableComponent: String {
        switch self {
        case .semanticEmbedding(let space): "semantic:\(space.stableComponent)"
        case .recognizedText: "recognizedText"
        case .structuredDocument: "structuredDocument"
        case .barcodePayload: "barcodePayload"
        case .classifications: "classifications"
        case .regions(let labels, let species, let landmarks):
            "regions:\(labels.sorted().joined(separator: ",")):\(species.map(\.rawValue).sorted().joined(separator: ",")):\(landmarks ?? "-")"
        case .featurePrint: "featurePrint"
        case .regionEmbedding(let space, let species):
            "regionEmbedding:\(space.stableComponent):\(species?.rawValue ?? "any")"
        case .qualityMetrics: "qualityMetrics"
        case .saliency: "saliency"
        case .mask(let format): "mask:\(format.rawValue)"
        case .geometry: "geometry"
        }
    }
}

public enum MLMaskFormat: String, Codable, Hashable, Sendable {
    case alpha8
    case label8
}

/// Product-owned bounds for whole-library native artifacts. The Apple adapter may emit fewer
/// values, but it must never persist unbounded classifier labels, regions, landmarks, or mask
/// samples merely because a request returned them.
public struct MLNativeArtifactLimits: Codable, Equatable, Sendable {
    public let maximumClassifications: Int
    public let minimumClassificationConfidence: Float
    public let maximumRegions: Int
    public let maximumLandmarksPerRegion: Int
    public let maskSampleSide: Int

    public init(
        maximumClassifications: Int = 32,
        minimumClassificationConfidence: Float = 0.01,
        maximumRegions: Int = 16,
        maximumLandmarksPerRegion: Int = 64,
        maskSampleSide: Int = 32
    ) throws {
        guard maximumClassifications > 0,
            minimumClassificationConfidence.isFinite,
            (0...1).contains(minimumClassificationConfidence),
            maximumRegions > 0,
            maximumLandmarksPerRegion > 0,
            (8...64).contains(maskSampleSide)
        else {
            throw MLAnalysisContractError.invalidArtifactLimits
        }
        self.maximumClassifications = maximumClassifications
        self.minimumClassificationConfidence = minimumClassificationConfidence
        self.maximumRegions = maximumRegions
        self.maximumLandmarksPerRegion = maximumLandmarksPerRegion
        self.maskSampleSide = maskSampleSide
    }

    private enum CodingKeys: String, CodingKey {
        case maximumClassifications, minimumClassificationConfidence, maximumRegions
        case maximumLandmarksPerRegion, maskSampleSide
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumClassifications: values.decode(Int.self, forKey: .maximumClassifications),
            minimumClassificationConfidence: values.decode(Float.self, forKey: .minimumClassificationConfidence),
            maximumRegions: values.decode(Int.self, forKey: .maximumRegions),
            maximumLandmarksPerRegion: values.decode(Int.self, forKey: .maximumLandmarksPerRegion),
            maskSampleSide: values.decode(Int.self, forKey: .maskSampleSide)
        )
    }

    public static let libraryIndexing = try! MLNativeArtifactLimits()
}

public struct MLNativeResultContext: Codable, Equatable, Hashable, Sendable {
    public let providerIdentifier: String
    public let analysisKind: MLNativeAnalysisKind
    public let requestRevision: String
    public let preprocessingRevision: String
    public let schemaEpoch: Int

    public init(
        providerIdentifier: String,
        analysisKind: MLNativeAnalysisKind,
        requestRevision: String,
        preprocessingRevision: String,
        schemaEpoch: Int
    ) throws {
        guard !providerIdentifier.isEmpty, !requestRevision.isEmpty,
            !preprocessingRevision.isEmpty, schemaEpoch > 0
        else {
            throw MLAnalysisContractError.invalidRevisionContext
        }
        self.providerIdentifier = providerIdentifier
        self.analysisKind = analysisKind
        self.requestRevision = requestRevision
        self.preprocessingRevision = preprocessingRevision
        self.schemaEpoch = schemaEpoch
    }

    private enum CodingKeys: String, CodingKey {
        case providerIdentifier, analysisKind, requestRevision, preprocessingRevision, schemaEpoch
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerIdentifier: values.decode(String.self, forKey: .providerIdentifier),
            analysisKind: values.decode(MLNativeAnalysisKind.self, forKey: .analysisKind),
            requestRevision: values.decode(String.self, forKey: .requestRevision),
            preprocessingRevision: values.decode(String.self, forKey: .preprocessingRevision),
            schemaEpoch: values.decode(Int.self, forKey: .schemaEpoch)
        )
    }
}

public struct MLTextObservation: Codable, Equatable, Sendable {
    public let text: String
    public let languages: [String]
    public let confidence: Float
    public let bounds: MLNormalizedRect

    public init(text: String, languages: [String], confidence: Float, bounds: MLNormalizedRect) {
        self.text = text
        self.languages = languages
        self.confidence = confidence
        self.bounds = bounds
    }
}

public struct MLRecognizedTextArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let observations: [MLTextObservation]

    public init(context: MLNativeResultContext, observations: [MLTextObservation]) throws {
        guard context.analysisKind == .textRecognition else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        self.context = context
        self.observations = observations
    }
}

public enum MLDocumentRegionKind: String, Codable, Hashable, Sendable {
    case paragraph
    case heading
    case listItem
    case tableCell
    case other
}

public struct MLDocumentRegion: Codable, Equatable, Sendable {
    public let kind: MLDocumentRegionKind
    public let text: String
    /// Zero-based table or list index inside the document. `nil` for free-flowing text.
    public let groupIndex: Int?
    /// Zero-based item index inside a list. `nil` for non-list regions.
    public let itemIndex: Int?
    public let row: Int?
    public let rowSpan: Int?
    public let column: Int?
    public let columnSpan: Int?
    public let marker: String?
    public let confidence: Float
    public let bounds: MLNormalizedRect

    public init(
        kind: MLDocumentRegionKind,
        text: String,
        groupIndex: Int? = nil,
        itemIndex: Int? = nil,
        row: Int? = nil,
        rowSpan: Int? = nil,
        column: Int? = nil,
        columnSpan: Int? = nil,
        marker: String? = nil,
        confidence: Float,
        bounds: MLNormalizedRect
    ) {
        self.kind = kind
        self.text = text
        self.groupIndex = groupIndex
        self.itemIndex = itemIndex
        self.row = row
        self.rowSpan = rowSpan
        self.column = column
        self.columnSpan = columnSpan
        self.marker = marker
        self.confidence = confidence
        self.bounds = bounds
    }
}

public struct MLStructuredDocumentArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let languages: [String]
    public let regions: [MLDocumentRegion]

    public init(context: MLNativeResultContext, languages: [String], regions: [MLDocumentRegion]) throws {
        guard context.analysisKind == .documentRecognition else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        self.context = context
        self.languages = languages
        self.regions = regions
    }
}

public struct MLBarcodeObservation: Codable, Equatable, Sendable {
    public let payload: String
    public let symbology: String
    public let confidence: Float
    public let bounds: MLNormalizedRect

    public init(payload: String, symbology: String, confidence: Float, bounds: MLNormalizedRect) {
        self.payload = payload
        self.symbology = symbology
        self.confidence = confidence
        self.bounds = bounds
    }
}

public struct MLBarcodeArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let observations: [MLBarcodeObservation]

    public init(context: MLNativeResultContext, observations: [MLBarcodeObservation]) throws {
        guard context.analysisKind == .barcodeDetection else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        self.context = context
        self.observations = observations
    }
}

public struct MLClassificationObservation: Codable, Equatable, Sendable {
    public let identifier: String
    public let confidence: Float

    public init(identifier: String, confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

public struct MLNativeClassificationArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let classifications: [MLClassificationObservation]

    public init(context: MLNativeResultContext, classifications: [MLClassificationObservation]) throws {
        guard context.analysisKind == .imageClassification else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        self.context = context
        self.classifications = classifications
    }
}

public struct MLRegionLandmark: Codable, Equatable, Sendable {
    public let identifier: String
    public let x: Double
    public let y: Double
    public let confidence: Float

    public init(identifier: String, x: Double, y: Double, confidence: Float = 1) throws {
        guard !identifier.isEmpty, x.isFinite, y.isFinite,
            (0...1).contains(x), (0...1).contains(y), confidence.isFinite,
            (0...1).contains(confidence)
        else {
            throw MLAnalysisContractError.invalidNormalizedPoint
        }
        self.identifier = identifier
        self.x = x
        self.y = y
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey { case identifier, x, y, confidence }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: values.decode(String.self, forKey: .identifier),
            x: values.decode(Double.self, forKey: .x),
            y: values.decode(Double.self, forKey: .y),
            confidence: values.decode(Float.self, forKey: .confidence)
        )
    }
}

public struct MLDetectedRegion: Codable, Equatable, Sendable {
    public let label: String
    public let species: MLRegionSpecies?
    public let confidence: Float
    public let bounds: MLNormalizedRect
    public let landmarks: [MLRegionLandmark]
    /// Request-local compact evidence such as face capture quality, roll, yaw, pitch, pose
    /// confidence, or mask coverage. Keys are stable Core vocabulary, never framework objects.
    public let metrics: [String: Float]

    public init(
        label: String,
        species: MLRegionSpecies?,
        confidence: Float,
        bounds: MLNormalizedRect,
        landmarks: [MLRegionLandmark] = [],
        metrics: [String: Float] = [:]
    ) {
        self.label = label
        self.species = species
        self.confidence = confidence
        self.bounds = bounds
        self.landmarks = landmarks
        self.metrics = metrics
    }
}

public struct MLRegionDetectionArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let regions: [MLDetectedRegion]

    public init(context: MLNativeResultContext, regions: [MLDetectedRegion]) throws {
        let limits = MLNativeArtifactLimits.libraryIndexing
        guard Self.supportedKinds.contains(context.analysisKind),
            regions.count <= limits.maximumRegions,
            regions.allSatisfy({ region in
                !region.label.isEmpty
                    && region.confidence.isFinite
                    && (0...1).contains(region.confidence)
                    && region.landmarks.count <= limits.maximumLandmarksPerRegion
                    && region.metrics.values.allSatisfy(\.isFinite)
            })
        else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        self.context = context
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey { case context, regions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            context: values.decode(MLNativeResultContext.self, forKey: .context),
            regions: values.decode([MLDetectedRegion].self, forKey: .regions)
        )
    }

    private static let supportedKinds: Set<MLNativeAnalysisKind> = [
        .animalRecognition, .humanDetection, .faceDetection, .faceLandmarks,
        .animalBodyPose, .humanBodyPose, .humanHandPose, .humanBodyPose3D,
    ]
}

public enum MLFeaturePrintElementType: String, Codable, Equatable, Sendable {
    case float16
    case float32
    case double
    case unknown
}

public struct MLFeaturePrintArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let elementType: MLFeaturePrintElementType
    public let elementCount: Int
    public let data: Data

    public init(
        context: MLNativeResultContext,
        elementType: MLFeaturePrintElementType,
        elementCount: Int,
        data: Data
    ) throws {
        guard context.analysisKind == .imageFeaturePrint else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        let bytesPerElement: Int? =
            switch elementType {
            case .float16: 2
            case .float32: 4
            case .double: 8
            case .unknown: nil
            }
        let expectedByteCount = bytesPerElement.map { elementCount.multipliedReportingOverflow(by: $0) }
        guard elementCount > 0, !data.isEmpty,
            expectedByteCount?.overflow != true,
            expectedByteCount.map({ data.count == $0.partialValue }) ?? true
        else {
            throw MLAnalysisContractError.invalidFeaturePrint
        }
        self.context = context
        self.elementType = elementType
        self.elementCount = elementCount
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case context, elementType, elementCount, data }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            context: values.decode(MLNativeResultContext.self, forKey: .context),
            elementType: values.decode(MLFeaturePrintElementType.self, forKey: .elementType),
            elementCount: values.decode(Int.self, forKey: .elementCount),
            data: values.decode(Data.self, forKey: .data)
        )
    }
}

public struct MLQualityArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let quality: Float?
    public let aesthetics: Float?
    public let saliencyBounds: MLNormalizedRect?
    public let metrics: [String: Float]

    public init(
        context: MLNativeResultContext,
        quality: Float? = nil,
        aesthetics: Float? = nil,
        saliencyBounds: MLNormalizedRect? = nil,
        metrics: [String: Float] = [:]
    ) throws {
        guard
            [.faceCaptureQuality, .imageAesthetics, .lensSmudgeDetection]
                .contains(context.analysisKind)
        else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        guard [quality, aesthetics].compactMap({ $0 }).allSatisfy({ $0.isFinite }),
            metrics.values.allSatisfy({ $0.isFinite })
        else {
            throw MLAnalysisContractError.invalidQualityMetric
        }
        self.context = context
        self.quality = quality
        self.aesthetics = aesthetics
        self.saliencyBounds = saliencyBounds
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case context, quality, aesthetics, saliencyBounds, metrics
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            context: values.decode(MLNativeResultContext.self, forKey: .context),
            quality: values.decodeIfPresent(Float.self, forKey: .quality),
            aesthetics: values.decodeIfPresent(Float.self, forKey: .aesthetics),
            saliencyBounds: values.decodeIfPresent(MLNormalizedRect.self, forKey: .saliencyBounds),
            metrics: values.decode([String: Float].self, forKey: .metrics)
        )
    }
}

public struct MLSaliencyArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let confidence: Float
    public let coverageFraction: Float
    public let salientRegions: [MLDetectedRegion]

    public init(
        context: MLNativeResultContext,
        confidence: Float,
        coverageFraction: Float,
        salientRegions: [MLDetectedRegion]
    ) throws {
        guard context.analysisKind == .attentionSaliency || context.analysisKind == .objectnessSaliency else {
            throw MLAnalysisContractError.nativeKindMismatch
        }
        guard confidence.isFinite, coverageFraction.isFinite,
            (0...1).contains(confidence), (0...1).contains(coverageFraction),
            salientRegions.count <= MLNativeArtifactLimits.libraryIndexing.maximumRegions
        else {
            throw MLAnalysisContractError.invalidQualityMetric
        }
        self.context = context
        self.confidence = confidence
        self.coverageFraction = coverageFraction
        self.salientRegions = salientRegions
    }

    private enum CodingKeys: String, CodingKey {
        case context, confidence, coverageFraction, salientRegions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            context: values.decode(MLNativeResultContext.self, forKey: .context),
            confidence: values.decode(Float.self, forKey: .confidence),
            coverageFraction: values.decode(Float.self, forKey: .coverageFraction),
            salientRegions: values.decode([MLDetectedRegion].self, forKey: .salientRegions)
        )
    }
}

/// Compact substitute for a full-resolution mask. Whole-library analysis keeps reusable instance
/// geometry and coverage while on-demand consumers regenerate the pixel mask when needed.
public struct MLMaskSummaryArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let format: MLMaskFormat
    public let instanceCount: Int
    public let coverageFraction: Float
    public let regions: [MLDetectedRegion]

    public init(
        context: MLNativeResultContext,
        format: MLMaskFormat,
        instanceCount: Int,
        coverageFraction: Float,
        regions: [MLDetectedRegion]
    ) throws {
        guard
            [.foregroundInstanceMask, .personInstanceMask, .personSegmentation]
                .contains(context.analysisKind),
            instanceCount >= 0,
            coverageFraction.isFinite,
            (0...1).contains(coverageFraction),
            regions.count <= MLNativeArtifactLimits.libraryIndexing.maximumRegions
        else {
            throw MLAnalysisContractError.invalidMaskDescriptor
        }
        self.context = context
        self.format = format
        self.instanceCount = instanceCount
        self.coverageFraction = coverageFraction
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey {
        case context, format, instanceCount, coverageFraction, regions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            context: values.decode(MLNativeResultContext.self, forKey: .context),
            format: values.decode(MLMaskFormat.self, forKey: .format),
            instanceCount: values.decode(Int.self, forKey: .instanceCount),
            coverageFraction: values.decode(Float.self, forKey: .coverageFraction),
            regions: values.decode([MLDetectedRegion].self, forKey: .regions)
        )
    }
}

public struct MLGeometryArtifact: Codable, Equatable, Sendable {
    public let context: MLNativeResultContext
    public let regions: [MLDetectedRegion]
    public let pointCount: Int
    public let metrics: [String: Float]

    public init(
        context: MLNativeResultContext,
        regions: [MLDetectedRegion] = [],
        pointCount: Int = 0,
        metrics: [String: Float] = [:]
    ) throws {
        guard
            [.documentSegmentation, .contours, .horizon, .rectangles, .textRectangles]
                .contains(context.analysisKind),
            pointCount >= 0,
            regions.count <= MLNativeArtifactLimits.libraryIndexing.maximumRegions,
            metrics.values.allSatisfy({ $0.isFinite })
        else {
            throw MLAnalysisContractError.invalidGeometry
        }
        self.context = context
        self.regions = regions
        self.pointCount = pointCount
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey { case context, regions, pointCount, metrics }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            context: values.decode(MLNativeResultContext.self, forKey: .context),
            regions: values.decode([MLDetectedRegion].self, forKey: .regions),
            pointCount: values.decode(Int.self, forKey: .pointCount),
            metrics: values.decode([String: Float].self, forKey: .metrics)
        )
    }
}

public enum MLArtifactProducerIdentity: Codable, Equatable, Hashable, Sendable {
    case model(id: MLModelID, revision: String, role: MLModelRole)
    case native(providerIdentifier: String, kind: MLNativeAnalysisKind, requestRevision: String)

    var stableComponent: String {
        switch self {
        case .model(let id, let revision, let role):
            "model:\(id.rawValue):\(revision):\(role.rawValue)"
        case .native(let provider, let kind, let revision):
            "native:\(provider):\(kind.rawValue):\(revision)"
        }
    }
}

public struct MLDerivedArtifactIdentity: Codable, Equatable, Hashable, Sendable {
    public let pipelineID: MLPipelineID
    public let stageID: MLStageID
    public let producer: MLArtifactProducerIdentity
    public let preprocessingRevision: String
    public let output: MLAnalysisOutputDescriptor
    public let schemaEpoch: Int

    public init(
        pipelineID: MLPipelineID,
        stageID: MLStageID,
        producer: MLArtifactProducerIdentity,
        preprocessingRevision: String,
        output: MLAnalysisOutputDescriptor,
        schemaEpoch: Int
    ) throws {
        guard !preprocessingRevision.isEmpty, schemaEpoch > 0 else {
            throw MLAnalysisContractError.invalidRevisionContext
        }
        self.pipelineID = pipelineID
        self.stageID = stageID
        self.producer = producer
        self.preprocessingRevision = preprocessingRevision
        self.output = output
        self.schemaEpoch = schemaEpoch
    }

    private enum CodingKeys: String, CodingKey {
        case pipelineID, stageID, producer, preprocessingRevision, output, schemaEpoch
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pipelineID: values.decode(MLPipelineID.self, forKey: .pipelineID),
            stageID: values.decode(MLStageID.self, forKey: .stageID),
            producer: values.decode(MLArtifactProducerIdentity.self, forKey: .producer),
            preprocessingRevision: values.decode(String.self, forKey: .preprocessingRevision),
            output: values.decode(MLAnalysisOutputDescriptor.self, forKey: .output),
            schemaEpoch: values.decode(Int.self, forKey: .schemaEpoch)
        )
    }

    public var stableNamespace: String {
        [
            "ml-artifact-v1",
            pipelineID.rawValue,
            stageID.rawValue,
            producer.stableComponent,
            preprocessingRevision,
            output.stableComponent,
            String(schemaEpoch),
        ].map(Self.lengthPrefixed).joined(separator: "|")
    }

    /// Prefix shared by every revision of one pipeline stage. Persistent stores use this to
    /// retire superseded revisions without treating a temporarily unavailable optional stage as
    /// removed.
    var stableStageNamespacePrefix: String {
        [
            "ml-artifact-v1",
            pipelineID.rawValue,
            stageID.rawValue,
        ].map(Self.lengthPrefixed).joined(separator: "|") + "|"
    }

    public func belongsToSameStage(as other: MLDerivedArtifactIdentity) -> Bool {
        pipelineID == other.pipelineID && stageID == other.stageID
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

public enum MLDerivedArtifactInvalidationPolicy {
    /// Retires an old epoch only when a current identity exists for the same pipeline stage.
    /// Unrelated pipelines and temporarily unavailable optional stages are left untouched.
    public static func staleArtifacts(
        existing: Set<MLDerivedArtifactIdentity>,
        current: Set<MLDerivedArtifactIdentity>
    ) -> Set<MLDerivedArtifactIdentity> {
        existing.filter { old in
            current.contains { new in old.belongsToSameStage(as: new) && old != new }
        }
    }
}

public enum MLAnalysisContractError: Error, Equatable {
    case invalidNormalizedBounds
    case invalidNormalizedPoint
    case invalidDescriptorSpace
    case invalidRevisionContext
    case invalidMaskDescriptor
    case invalidFeaturePrint
    case invalidGeometry
    case invalidQualityMetric
    case invalidArtifactLimits
    case nativeKindMismatch
    case dimensionMismatch(expected: Int, actual: Int)
}
