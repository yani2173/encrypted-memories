import Foundation
import PhotosCore

/// One curated, library-independent search concept. `prompt` is model-facing English because the compact
/// visual model understands English only; the multilingual model uses the same prompt, so calibration is shared.
public struct MLSearchConcept: Identifiable, Hashable, Sendable {
    public let id: String
    public let prompt: String
    public let systemImage: String

    public init(id: String, prompt: String, systemImage: String) {
        self.id = id
        self.prompt = prompt
        self.systemImage = systemImage
    }

    /// Display titles come only from the reviewed catalog keys `search.concept.<id>`, never from library data.
    public var title: String { L10n.string(dynamicKey: "search.concept.\(id)") }
}

/// The allow-list of concepts that may become suggestions. It is a compiled constant on purpose: no code
/// path turns library content into a concept title, so sensitive content can never be proposed by name.
public enum MLSearchConceptCatalog {
    /// Complete internal batch contract. These model-facing strings are never suggestion titles.
    public static var suggestionPrompts: [String] { sensitivePrompts + curated.map(\.prompt) }

    public static let curated: [MLSearchConcept] = [
        .init(id: "people", prompt: "a photo of people", systemImage: "person.2"),
        .init(id: "dog", prompt: "a photo of a dog", systemImage: "dog"),
        .init(id: "cat", prompt: "a photo of a cat", systemImage: "cat"),
        .init(id: "bird", prompt: "a photo of a bird", systemImage: "bird"),
        .init(id: "nature", prompt: "a photo of a nature landscape", systemImage: "leaf"),
        .init(id: "mountains", prompt: "a photo of mountains", systemImage: "mountain.2"),
        .init(id: "beach", prompt: "a photo of a beach by the sea", systemImage: "beach.umbrella"),
        .init(id: "water", prompt: "a photo of a lake or a river", systemImage: "water.waves"),
        .init(id: "forest", prompt: "a photo of a forest with trees", systemImage: "tree"),
        .init(id: "flowers", prompt: "a photo of flowers", systemImage: "camera.macro"),
        .init(id: "snow", prompt: "a photo of snow in winter", systemImage: "snowflake"),
        .init(id: "sunset", prompt: "a photo of a sunset sky", systemImage: "sunset"),
        .init(id: "night", prompt: "a photo of a city at night", systemImage: "moon.stars"),
        .init(id: "city", prompt: "a photo of city streets and buildings", systemImage: "building.2"),
        .init(
            id: "architecture", prompt: "a photo of a historic building or a church", systemImage: "building.columns"),
        .init(id: "food", prompt: "a photo of a plate of food", systemImage: "fork.knife"),
        .init(id: "drinks", prompt: "a photo of coffee or drinks on a table", systemImage: "cup.and.saucer"),
        .init(id: "birthday", prompt: "a photo of a birthday cake with candles", systemImage: "birthday.cake"),
        .init(id: "christmas", prompt: "a photo of a christmas tree", systemImage: "gift"),
        .init(id: "concert", prompt: "a photo of a concert stage with lights", systemImage: "music.mic"),
        .init(id: "sports", prompt: "a photo of people doing sports", systemImage: "figure.run"),
        .init(id: "hiking", prompt: "a photo of hiking on a trail", systemImage: "figure.hiking"),
        .init(id: "bicycle", prompt: "a photo of a bicycle", systemImage: "bicycle"),
        .init(id: "car", prompt: "a photo of a car", systemImage: "car"),
        .init(id: "train", prompt: "a photo of a train or a railway station", systemImage: "tram"),
        .init(id: "airplane", prompt: "a photo of an airplane or an airport", systemImage: "airplane"),
        .init(id: "boat", prompt: "a photo of a boat on the water", systemImage: "sailboat"),
        .init(id: "art", prompt: "a photo of a painting in a museum", systemImage: "paintpalette"),
        .init(id: "garden", prompt: "a photo of a garden", systemImage: "camera.macro.circle"),
        .init(id: "documents", prompt: "a photo of a paper document or a receipt", systemImage: "doc.text"),
    ]

    /// Internal, never displayed and never offered as a suggestion. Matches only keep items out of landing
    /// previews and out of concept counts; they stay searchable in the user's own results.
    static let sensitivePrompts = [
        "a photo of a naked person",
        "a photo of a person in underwear",
        "an explicit adult photo",
    ]
}

public struct MLSearchConceptEvidence: Equatable, Sendable {
    public let concept: MLSearchConcept
    /// Best match first; sensitive items are removed.
    public let rankedUIDs: [PhotoUID]

    public init(concept: MLSearchConcept, rankedUIDs: [PhotoUID]) {
        self.concept = concept
        self.rankedUIDs = rankedUIDs
    }
}

/// Finds the curated concepts that are actually present in this library.
///
/// Each prompt runs through the model-calibrated semantic search, so the existing relevance policy already
/// drops weak matches. A concept qualifies only with enough hits for the indexed coverage, and a concept
/// whose hits mostly repeat a stronger concept is dropped, so "Forest" does not duplicate "Nature".
public enum MLSearchConceptDiscovery {
    public typealias Search = @Sendable (_ prompt: String, _ limit: Int) async throws -> [PhotoUID]

    /// Six matches are always required. A retrieval limit below six cannot qualify any concept.
    public static func minimumHits(coveredAssetCount: Int, limit: Int = 400) -> Int {
        // Search returns at most `limit` matches. Keep qualification attainable even for
        // very large libraries, without increasing the amount of work per query.
        max(6, min(max(0, limit), Int((Double(coveredAssetCount) * 0.004).rounded(.up))))
    }

    /// Runs every internal sensitive prompt. The gate fails closed: any failed or cancelled query throws, and
    /// callers must then show no previews and no concept suggestions.
    public static func sensitiveUIDs(limit: Int = 400, search: Search) async throws -> Set<PhotoUID> {
        var sensitive = Set<PhotoUID>()
        for prompt in MLSearchConceptCatalog.sensitivePrompts {
            try Task.checkCancellation()
            sensitive.formUnion(try await search(prompt, limit))
        }
        try Task.checkCancellation()
        return sensitive
    }

    public struct Evaluation: Sendable {
        public let evidence: [MLSearchConceptEvidence]
        /// Empty successful results are complete; failed or cancelled queries are not.
        public let isComplete: Bool
    }

    public static func evaluateWithCompletion(
        concepts: [MLSearchConcept] = MLSearchConceptCatalog.curated,
        coveredAssetCount: Int,
        sensitiveUIDs: Set<PhotoUID>,
        limit: Int = 400,
        maximumOverlap: Double = 0.8,
        search: Search
    ) async -> Evaluation {
        guard limit >= 6 else { return Evaluation(evidence: [], isComplete: true) }
        var isComplete = true
        let threshold = minimumHits(coveredAssetCount: coveredAssetCount, limit: limit)
        var candidates: [MLSearchConceptEvidence] = []
        for concept in concepts {
            guard !Task.isCancelled else { return Evaluation(evidence: [], isComplete: false) }
            let uids: [PhotoUID]
            do {
                uids = try await search(concept.prompt, limit)
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    PhotoDiagnostics.shared.increment("ml.suggestions.conceptQueryFailed")
                }
                isComplete = false
                continue
            }
            let ranked = uids.filter { !sensitiveUIDs.contains($0) }
            if ranked.count >= threshold {
                candidates.append(MLSearchConceptEvidence(concept: concept, rankedUIDs: ranked))
            }
        }
        guard !Task.isCancelled else { return Evaluation(evidence: [], isComplete: false) }

        var accepted: [MLSearchConceptEvidence] = []
        var acceptedSets: [Set<PhotoUID>] = []
        for candidate in candidates.sorted(by: { $0.rankedUIDs.count > $1.rankedUIDs.count }) {
            let hits = Set(candidate.rankedUIDs)
            let repeatsStrongerConcept = acceptedSets.contains { stronger in
                Double(hits.intersection(stronger).count) >= Double(hits.count) * maximumOverlap
            }
            guard !repeatsStrongerConcept else { continue }
            accepted.append(candidate)
            acceptedSets.append(hits)
        }
        return Evaluation(evidence: accepted, isComplete: isComplete)
    }
}
