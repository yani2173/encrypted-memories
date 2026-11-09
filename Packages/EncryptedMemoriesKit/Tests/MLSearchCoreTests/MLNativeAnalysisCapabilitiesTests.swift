import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLNativeAnalysisCapabilitiesTests {
    @Test func capabilitySnapshotRoundTripsWithoutFrameworkTypes() throws {
        let text = MLNativeAnalysisCapability(
            kind: .textRecognition,
            implementationIdentifier: "apple.vision.recognize-text",
            availability: .available,
            selectedRevision: "revision3",
            supportedRevisions: ["revision3"],
            supportedLanguages: ["de", "en"],
            computeSupport: [
                MLNativeAnalysisComputeSupport(stage: .main, devices: [.cpu, .neuralEngine])
            ]
        )
        let snapshot = MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "iphoneos26.5",
            capabilities: [text]
        )

        let decoded = try JSONDecoder().decode(
            MLNativeAnalysisCapabilitySnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded == snapshot)
        #expect(decoded.capability(for: .textRecognition) == text)
        #expect(decoded.availableKinds == [.textRecognition])
    }

    @Test func unavailableCapabilityKeepsTypedReason() {
        let capability = MLNativeAnalysisCapability(
            kind: .lensSmudgeDetection,
            implementationIdentifier: "apple.vision.detect-lens-smudge",
            availability: .unavailable(.hardware),
            selectedRevision: nil,
            supportedRevisions: []
        )

        #expect(!capability.isAvailable)
        #expect(capability.availability == .unavailable(.hardware))
    }

    @Test func searchScopesRequireRealSearchBackends() {
        #expect(MLSearchScopePolicy.availableScopes(for: [.semantic]) == [.all])
        #expect(MLSearchScopePolicy.availableScopes(for: [.barcodePayload]) == [.all])
        #expect(MLSearchScopePolicy.availableScopes(for: [.recognizedText]) == [.all, .text])
        #expect(MLSearchScopePolicy.availableScopes(for: [.documentText]) == [.all, .text])

        let scopes = MLSearchScopePolicy.availableScopes(
            for: [.semantic, .recognizedText, .documentText, .barcodePayload, .visualSimilarity]
        )
        #expect(scopes == [.all, .text])
    }

    @Test func nativeCapabilityAloneDoesNotExposeSearchScope() {
        let snapshot = MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "iphoneos26.5",
            capabilities: [
                MLNativeAnalysisCapability(
                    kind: .textRecognition,
                    implementationIdentifier: "apple.vision.recognize-text",
                    availability: .available,
                    selectedRevision: "revision3",
                    supportedRevisions: ["revision3"]
                )
            ]
        )

        #expect(snapshot.availableKinds.contains(.textRecognition))
        #expect(MLSearchScopePolicy.availableScopes(for: [.semantic]) == [.all])
    }

    @Test func resourcePolicyUsesCapabilitiesAndMemoryInsteadOfDeviceNames() {
        let accelerated = MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "test",
            capabilities: [
                MLNativeAnalysisCapability(
                    kind: .imageClassification,
                    implementationIdentifier: "apple.vision.classify",
                    availability: .available,
                    selectedRevision: "revision1",
                    supportedRevisions: ["revision1"],
                    computeSupport: [
                        .init(stage: .main, devices: [.cpu, .neuralEngine])
                    ]
                )
            ]
        )
        #expect(
            MLNativeAnalysisResourcePolicy.maximumConcurrentAssets(
                capabilitySnapshot: accelerated,
                physicalMemoryBytes: 4_000_000_000
            ) == 1)
        #expect(
            MLNativeAnalysisResourcePolicy.maximumConcurrentAssets(
                capabilitySnapshot: accelerated,
                physicalMemoryBytes: 8_000_000_000
            ) == 2)
        #expect(
            MLNativeAnalysisResourcePolicy.maximumConcurrentAssets(
                capabilitySnapshot: accelerated,
                physicalMemoryBytes: 16_000_000_000
            ) == 3)

        let cpuOnly = MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "test",
            capabilities: [
                MLNativeAnalysisCapability(
                    kind: .textRecognition,
                    implementationIdentifier: "apple.vision.ocr",
                    availability: .available,
                    selectedRevision: "revision1",
                    supportedRevisions: ["revision1"],
                    computeSupport: [.init(stage: .main, devices: [.cpu])]
                )
            ]
        )
        #expect(
            MLNativeAnalysisResourcePolicy.maximumConcurrentAssets(
                capabilitySnapshot: cpuOnly,
                physicalMemoryBytes: 32_000_000_000
            ) == 1)
    }
}

extension MLNativeAnalysisCapabilitySnapshot {
    var availableKinds: [MLNativeAnalysisKind] {
        capabilities.compactMap { $0.isAvailable ? $0.kind : nil }
    }
}
