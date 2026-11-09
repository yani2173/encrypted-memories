import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLAnalysisArtifactContractsTests {
    @Test func everyOutputDescriptorRoundTrips() throws {
        let semantic = try MLDescriptorSpace(identifier: "semantic", revision: 1, dimension: 768)
        let face = try MLDescriptorSpace(identifier: "face", revision: 2, dimension: 128)
        let outputs: [MLAnalysisOutputDescriptor] = [
            .semanticEmbedding(semantic),
            .recognizedText,
            .structuredDocument,
            .barcodePayload,
            .classifications,
            .regions(labels: ["human"], species: [.human], landmarkSchema: "face-5"),
            .featurePrint,
            .regionEmbedding(space: face, species: .human),
            .qualityMetrics,
            .saliency,
            .mask(format: .alpha8),
            .geometry,
        ]

        for output in outputs {
            #expect(try roundTrip(output) == output)
        }
    }

    @Test func nativeTextDocumentBarcodeAndClassificationArtifactsRoundTrip() throws {
        let bounds = try MLNormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let textContext = try context(.textRecognition)
        let documentContext = try context(.documentRecognition)
        let barcodeContext = try context(.barcodeDetection)
        let classificationContext = try context(.imageClassification)

        let text = try MLRecognizedTextArtifact(
            context: textContext,
            observations: [.init(text: "Rechnung", languages: ["de"], confidence: 0.95, bounds: bounds)]
        )
        let document = try MLStructuredDocumentArtifact(
            context: documentContext,
            languages: ["de"],
            regions: [
                .init(
                    kind: .tableCell,
                    text: "42",
                    groupIndex: 2,
                    row: 0,
                    rowSpan: 2,
                    column: 1,
                    columnSpan: 3,
                    confidence: 0.9,
                    bounds: bounds
                ),
                .init(
                    kind: .listItem,
                    text: "Eintrag",
                    groupIndex: 1,
                    itemIndex: 4,
                    marker: "•",
                    confidence: 0.8,
                    bounds: bounds
                ),
            ]
        )
        let barcode = try MLBarcodeArtifact(
            context: barcodeContext,
            observations: [.init(payload: "123", symbology: "qr", confidence: 1, bounds: bounds)]
        )
        let classifications = try MLNativeClassificationArtifact(
            context: classificationContext,
            classifications: [.init(identifier: "dog", confidence: 0.98)]
        )

        #expect(try roundTrip(text) == text)
        #expect(try roundTrip(document) == document)
        #expect(try roundTrip(barcode) == barcode)
        #expect(try roundTrip(classifications) == classifications)
    }

    @Test func nativeRegionFeatureAndQualityContractsRoundTrip() throws {
        let bounds = try MLNormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let landmark = try MLRegionLandmark(identifier: "leftEye", x: 0.25, y: 0.4)
        let region = try MLRegionDetectionArtifact(
            context: try context(.faceLandmarks),
            regions: [
                .init(label: "human", species: .human, confidence: 0.99, bounds: bounds, landmarks: [landmark])
            ]
        )
        let featureValues: [Float] = [0.1, 0.2, 0.3]
        let feature = try MLFeaturePrintArtifact(
            context: context(.imageFeaturePrint),
            elementType: .float32,
            elementCount: featureValues.count,
            data: featureValues.withUnsafeBytes { Data($0) }
        )
        let quality = try MLQualityArtifact(
            context: try context(.imageAesthetics),
            quality: 0.8,
            aesthetics: 0.7,
            saliencyBounds: bounds
        )

        #expect(try roundTrip(region) == region)
        #expect(try roundTrip(feature) == feature)
        #expect(try roundTrip(quality) == quality)
    }

    @Test func featurePrintRejectsByteCountMismatchAndWrongNativeKind() throws {
        #expect(throws: MLAnalysisContractError.invalidFeaturePrint) {
            try MLFeaturePrintArtifact(
                context: context(.imageFeaturePrint),
                elementType: .float32,
                elementCount: 2,
                data: Data(repeating: 0, count: 4)
            )
        }
        #expect(throws: MLAnalysisContractError.nativeKindMismatch) {
            try MLRecognizedTextArtifact(context: context(.barcodeDetection), observations: [])
        }
    }

    @Test func decodingReappliesValidatedArtifactInvariants() throws {
        let invalidRect = Data(#"{"x":0.9,"y":0.2,"width":0.2,"height":0.4}"#.utf8)
        #expect(throws: MLAnalysisContractError.invalidNormalizedBounds) {
            try JSONDecoder().decode(MLNormalizedRect.self, from: invalidRect)
        }

        let valid = try MLFeaturePrintArtifact(
            context: context(.imageFeaturePrint),
            elementType: .float32,
            elementCount: 1,
            data: Data(repeating: 0, count: MemoryLayout<Float>.size)
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        object["elementCount"] = 2
        let invalidFeature = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: MLAnalysisContractError.invalidFeaturePrint) {
            try JSONDecoder().decode(MLFeaturePrintArtifact.self, from: invalidFeature)
        }
    }

    @Test func modelRevisionChangeInvalidatesOnlyMatchingStageEpoch() throws {
        let output = MLAnalysisOutputDescriptor.recognizedText
        let oldOCR = try identity(stage: "ocr", revision: "revision2", output: output)
        let currentOCR = try identity(stage: "ocr", revision: "revision3", output: output)
        let unchangedBarcode = try identity(stage: "barcodes", revision: "revision1", output: .barcodePayload)
        let unrelatedPeople = try MLDerivedArtifactIdentity(
            pipelineID: .people,
            stageID: .init(rawValue: "faces"),
            producer: .model(id: .init("sface"), revision: "r1", role: .regionEmbedder),
            preprocessingRevision: "face-crop-v1",
            output: .regionEmbedding(
                space: MLDescriptorSpace(identifier: "faces", revision: 1, dimension: 128),
                species: .human
            ),
            schemaEpoch: 1
        )

        let stale = MLDerivedArtifactInvalidationPolicy.staleArtifacts(
            existing: [oldOCR, unchangedBarcode, unrelatedPeople],
            current: [currentOCR, unchangedBarcode]
        )

        #expect(stale == [oldOCR])
        #expect(oldOCR.stableNamespace != currentOCR.stableNamespace)
        #expect(unchangedBarcode.stableNamespace == unchangedBarcode.stableNamespace)
    }

    private func context(_ kind: MLNativeAnalysisKind) throws -> MLNativeResultContext {
        try MLNativeResultContext(
            providerIdentifier: "apple.vision",
            analysisKind: kind,
            requestRevision: "revision3",
            preprocessingRevision: "bounded-image-v1",
            schemaEpoch: 1
        )
    }

    private func identity(
        stage: String,
        revision: String,
        output: MLAnalysisOutputDescriptor
    ) throws -> MLDerivedArtifactIdentity {
        try MLDerivedArtifactIdentity(
            pipelineID: .nativeSearch,
            stageID: .init(rawValue: stage),
            producer: .native(
                providerIdentifier: "apple.vision",
                kind: stage == "ocr" ? .textRecognition : .barcodeDetection,
                requestRevision: revision
            ),
            preprocessingRevision: "bounded-image-v1",
            output: output,
            schemaEpoch: 1
        )
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
