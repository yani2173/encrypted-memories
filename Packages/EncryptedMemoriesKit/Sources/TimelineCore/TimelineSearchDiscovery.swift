import Foundation
import PhotosCore

/// A bounded, most-recent-first list shared by every native search surface.
public struct TimelineSearchHistory: Codable, Equatable, Sendable {
    public static let defaultLimit = 12

    public private(set) var queries: [String]

    public init(queries: [String] = [], limit: Int = defaultLimit) {
        self.queries = Self.normalized(queries, limit: limit)
    }

    public mutating func record(_ rawQuery: String, limit: Int = defaultLimit) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        queries.removeAll { $0.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        queries.insert(query, at: 0)
        if queries.count > max(0, limit) {
            queries.removeLast(queries.count - max(0, limit))
        }
    }

    public mutating func clear() {
        queries.removeAll(keepingCapacity: false)
    }

    private static func normalized(_ input: [String], limit: Int) -> [String] {
        var result: [String] = []
        for rawQuery in input {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            guard
                !result.contains(where: {
                    $0.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                })
            else { continue }
            result.append(query)
            if result.count == max(0, limit) { break }
        }
        return result
    }
}

public enum TimelineSearchSuggestionKind: String, Hashable, Sendable, Codable {
    case date
    case onThisDay
    case trip
    case season
    case favorites
    case mediaType
    case place
    case placeSeason
    case concept
}

/// One search suggestion. `query` is the text shown in the search field after selection.
///
/// A suggestion with `matchingUIDs` is structured: its result set was resolved when the suggestion was built
/// (for example a place, an anniversary or an ML concept) and cannot be expressed as lexical query text.
/// A suggestion without it runs `query` through the ordinary lexical and semantic search.
public struct TimelineSearchSuggestion: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let query: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let kind: TimelineSearchSuggestionKind
    public let matchingUIDs: Set<PhotoUID>?
    public let representativeUIDs: [PhotoUID]

    public var representativeUID: PhotoUID? { representativeUIDs.first }
    public var matchCount: Int? { matchingUIDs?.count }

    /// A lexical suggestion that remains useful when optional on-device ML search is unavailable.
    public init(id: String, query: String, title: String, representativeUID: PhotoUID? = nil) {
        self.init(
            id: id,
            query: query,
            title: title,
            subtitle: nil,
            systemImage: "magnifyingglass",
            kind: .date,
            matchingUIDs: nil,
            representativeUIDs: representativeUID.map { [$0] } ?? []
        )
    }

    public init(
        id: String,
        query: String,
        title: String,
        subtitle: String?,
        systemImage: String,
        kind: TimelineSearchSuggestionKind,
        matchingUIDs: Set<PhotoUID>?,
        representativeUIDs: [PhotoUID]
    ) {
        self.id = id
        self.query = query
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.kind = kind
        self.matchingUIDs = matchingUIDs
        self.representativeUIDs = representativeUIDs
    }

    /// Whether the search field text still belongs to this suggestion. Editing the text leaves the suggestion.
    public func owns(searchText: String) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// Namespace of the search suggestion builders in `TimelineSearchLibraryDiscovery.swift`.
public enum TimelineSearchDiscovery {}
