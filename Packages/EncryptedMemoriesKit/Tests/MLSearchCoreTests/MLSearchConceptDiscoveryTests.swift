import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

@Suite struct MLSearchConceptDiscoveryTests {
    private let nature = MLSearchConcept(id: "nature", prompt: "a photo of a nature landscape", systemImage: "leaf")
    private let forest = MLSearchConcept(id: "forest", prompt: "a photo of a forest with trees", systemImage: "tree")
    private let dog = MLSearchConcept(id: "dog", prompt: "a photo of a dog", systemImage: "dog")
    private let beach = MLSearchConcept(
        id: "beach", prompt: "a photo of a beach by the sea", systemImage: "beach.umbrella")

    @Test func conceptsNeedEnoughHitsAndSensitiveMatchesNeverCount() async throws {
        let beachHits = uids("b", 0..<8)
        let sensitive = Set(beachHits.prefix(4))
        let responses: [String: [PhotoUID]] = [
            nature.prompt: uids("n", 0..<10),
            dog.prompt: uids("d", 0..<3),
            beach.prompt: beachHits,
            MLSearchConceptCatalog.sensitivePrompts[0]: Array(sensitive),
        ]
        let search: MLSearchConceptDiscovery.Search = { prompt, _ in responses[prompt] ?? [] }

        let gate = try await MLSearchConceptDiscovery.sensitiveUIDs(search: search)
        let evidence = await MLSearchConceptDiscovery.evaluate(
            concepts: [nature, dog, beach],
            coveredAssetCount: 100,
            sensitiveUIDs: gate,
            search: search
        )

        #expect(gate == sensitive)
        #expect(evidence.map(\.concept.id) == ["nature"])
    }

    @Test func theSensitiveGateFailsClosedWhenAnyQueryFails() async {
        struct QueryFailure: Error {}
        await #expect(throws: QueryFailure.self) {
            _ = try await MLSearchConceptDiscovery.sensitiveUIDs { prompt, _ in
                if prompt == MLSearchConceptCatalog.sensitivePrompts[1] { throw QueryFailure() }
                return []
            }
        }
    }

    @Test func aConceptThatMostlyRepeatsAStrongerConceptIsDropped() async {
        let natureHits = uids("x", 0..<20)
        let responses: [String: [PhotoUID]] = [
            nature.prompt: natureHits,
            forest.prompt: Array(natureHits.prefix(9)) + uids("f", 0..<1),
            dog.prompt: uids("d", 0..<7),
        ]

        let evidence = await MLSearchConceptDiscovery.evaluate(
            concepts: [forest, nature, dog],
            coveredAssetCount: 100,
            sensitiveUIDs: []
        ) { prompt, _ in responses[prompt] ?? [] }

        #expect(evidence.map(\.concept.id) == ["nature", "dog"])
    }

    @Test func aFailingConceptQuerySkipsOnlyThatConcept() async {
        struct QueryFailure: Error {}
        let evidence = await MLSearchConceptDiscovery.evaluate(
            concepts: [dog, nature],
            coveredAssetCount: 10,
            sensitiveUIDs: []
        ) { prompt, _ in
            if prompt == dog.prompt { throw QueryFailure() }
            return prompt == nature.prompt ? uids("n", 0..<6) : []
        }

        #expect(evidence.map(\.concept.id) == ["nature"])
    }

    @Test func aFailedConceptDoesNotProveDiscoveryIsComplete() async {
        struct QueryFailure: Error {}
        let result = await MLSearchConceptDiscovery.evaluateWithCompletion(
            concepts: [dog, nature], coveredAssetCount: 10, sensitiveUIDs: []
        ) { prompt, _ in
            if prompt == dog.prompt { throw QueryFailure() }
            return uids("n", 0..<6)
        }
        #expect(result.evidence.map(\.concept.id) == ["nature"])
        #expect(!result.isComplete)

        let empty = await MLSearchConceptDiscovery.evaluateWithCompletion(
            concepts: [dog], coveredAssetCount: 10, sensitiveUIDs: []
        ) { _, _ in [] }
        #expect(empty.evidence.isEmpty)
        #expect(empty.isComplete)
    }

    @Test func thresholdScalesWithCoverageAndNeverDropsBelowSix() {
        #expect(MLSearchConceptDiscovery.minimumHits(coveredAssetCount: 0) == 6)
        #expect(MLSearchConceptDiscovery.minimumHits(coveredAssetCount: 1_000) == 6)
        #expect(MLSearchConceptDiscovery.minimumHits(coveredAssetCount: 50_000) == 200)
    }

    @Test(arguments: [100_000, 100_001, 150_000, Int.max])
    func largeLibrariesCanQualifyWithinTheSearchLimit(covered: Int) async {
        let hits = uids("n", 0..<400)
        let evidence = await MLSearchConceptDiscovery.evaluate(
            concepts: [nature], coveredAssetCount: covered, sensitiveUIDs: []
        ) { _, limit in Array(hits.prefix(limit)) }

        #expect(evidence.map(\.concept.id) == ["nature"])
        #expect(evidence.first?.rankedUIDs.count == 400)
    }

    @Test(arguments: [0, 5, 6, 100])
    func customLimitsKeepTheMinimumEvidenceFloor(limit: Int) async {
        let hits = uids("n", 0..<limit)
        let evidence = await MLSearchConceptDiscovery.evaluate(
            concepts: [nature], coveredAssetCount: 150_000, sensitiveUIDs: [], limit: limit
        ) { _, _ in hits }

        #expect(evidence.isEmpty == (limit < 6))
    }

    @Test func everyCuratedConceptHasAReviewedTitleAndAUniqueID() {
        let ids = MLSearchConceptCatalog.curated.map(\.id)
        #expect(Set(ids).count == ids.count)
        for concept in MLSearchConceptCatalog.curated {
            #expect(concept.title != "search.concept.\(concept.id)", "missing catalog title for \(concept.id)")
            #expect(concept.prompt.hasPrefix("a photo of"))
        }
    }

    private func uids(_ prefix: String, _ range: Range<Int>) -> [PhotoUID] {
        range.map { PhotoUID(volumeID: "v", nodeID: "\(prefix)\($0)") }
    }
}

extension MLSearchConceptDiscovery {
    /// Evaluates the curated concepts. `sensitiveUIDs` must come from a successful `sensitiveUIDs(search:)`;
    /// those items never count towards a concept. A failed concept query skips only that concept.
    fileprivate static func evaluate(
        concepts: [MLSearchConcept] = MLSearchConceptCatalog.curated,
        coveredAssetCount: Int,
        sensitiveUIDs: Set<PhotoUID>,
        limit: Int = 400,
        maximumOverlap: Double = 0.8,
        search: MLSearchConceptDiscovery.Search
    ) async -> [MLSearchConceptEvidence] {
        await evaluateWithCompletion(
            concepts: concepts, coveredAssetCount: coveredAssetCount, sensitiveUIDs: sensitiveUIDs,
            limit: limit, maximumOverlap: maximumOverlap, search: search
        ).evidence
    }
}
