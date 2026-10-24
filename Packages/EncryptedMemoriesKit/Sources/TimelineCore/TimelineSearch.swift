import Foundation
import PhotosCore

public struct TimelineSearchContext: Hashable, Sendable {
    public var activeFilter: PhotoFilter?
    public var favoriteUIDs: Set<PhotoUID>
    /// The decrypted file names of the library; a text query also matches the name of a photo.
    public var photoNames: PhotoNameIndex?

    public init(activeFilter: PhotoFilter? = nil, favoriteUIDs: Set<PhotoUID> = [], photoNames: PhotoNameIndex? = nil) {
        self.activeFilter = activeFilter
        self.favoriteUIDs = favoriteUIDs
        self.photoNames = photoNames
    }
}

/// Independent library refinements use AND semantics across groups and OR semantics within the
/// media-kind group. An empty selection means the whole library.
public struct TimelineRefinement: Hashable, Sendable {
    public enum MediaKind: Hashable, Sendable {
        case photo
        case video
    }

    public var favoritesOnly: Bool
    public var mediaKinds: Set<MediaKind>

    public init(
        favoritesOnly: Bool = false,
        mediaKinds: Set<MediaKind> = []
    ) {
        self.favoritesOnly = favoritesOnly
        self.mediaKinds = mediaKinds
    }

    public static let all = TimelineRefinement()

    /// Selection identity, not result equivalence. Selecting both media kinds remains visible in the UI even
    /// though it currently includes every item, matching the stacked-filter interaction contract.
    public var isActive: Bool {
        favoritesOnly || !mediaKinds.isEmpty
    }

    public func includes(_ item: PhotoItem, favoriteUIDs: Set<PhotoUID>) -> Bool {
        if favoritesOnly, !favoriteUIDs.contains(item.uid) {
            return false
        }

        guard !mediaKinds.isEmpty else { return true }
        let kind: MediaKind = item.isVideo ? .video : .photo
        return mediaKinds.contains(kind)
    }
}

public enum TimelineSearch {
    /// Filter sections by the lexical/smart-token query, optionally widened by Smart Search:
    /// `semanticMatches` are UIDs the on-device semantic engine ranked for the same query, so a
    /// photo matches when either the text query or the semantic engine says it does. Timeline
    /// order is preserved (results stay date-organized, not score-ordered).
    ///
    /// `requiredUIDs` is the resolved result set of a structured suggestion. It narrows with AND semantics:
    /// an item must be in the set and, when a query exists, also match the query.
    public static func filter(
        _ sections: [TimelineSection], query rawQuery: String,
        context: TimelineSearchContext = TimelineSearchContext(),
        semanticMatches: Set<PhotoUID>? = nil,
        refinement: TimelineRefinement = .all,
        requiredUIDs: Set<PhotoUID>? = nil
    ) -> [TimelineSection] {
        let query = TimelineSearchQuery(rawQuery)
        guard !query.isEmpty || refinement.isActive || requiredUIDs != nil else { return sections }

        var filteredSections: [TimelineSection] = []
        filteredSections.reserveCapacity(sections.count)
        for section in sections {
            guard !Task.isCancelled else { return [] }
            var items: [PhotoItem] = []
            items.reserveCapacity(section.items.count)
            for item in section.items {
                guard !Task.isCancelled else { return [] }
                if let requiredUIDs, !requiredUIDs.contains(item.uid) { continue }
                let matchesQuery =
                    query.isEmpty
                    || query.matches(item: item, in: section, context: context)
                    || (semanticMatches?.contains(item.uid) ?? false)
                if matchesQuery && refinement.includes(item, favoriteUIDs: context.favoriteUIDs) {
                    items.append(item)
                }
            }
            guard !items.isEmpty else { continue }
            filteredSections.append(
                TimelineSection(
                    id: section.id,
                    date: section.date,
                    title: section.title,
                    items: items
                ))
        }
        return filteredSections
    }
}

public struct TimelineSearchQuery: Equatable, Sendable {
    private enum Term: Equatable, Sendable {
        case text(String)
        /// A kind word such as `film` or `raw`; the typed token also matches a file name that contains it.
        case smart(SmartKind, token: String)
    }

    private enum SmartKind: Equatable, Sendable {
        case favorites
        case videos
        case screenshots
        case selfies
        case raw

        var photoTag: PhotoTag {
            switch self {
            case .favorites: .favorites
            case .videos: .videos
            case .screenshots: .screenshots
            case .selfies: .selfies
            case .raw: .raw
            }
        }
    }

    private let terms: [Term]
    /// Every token as typed, smart tokens included; a file name match compares these with the name.
    private let tokens: [String]

    public init(_ raw: String) {
        tokens = Self.tokens(from: raw)
        terms = tokens.map { token in
            if let smart = Self.smartKind(for: token) {
                .smart(smart, token: token)
            } else {
                .text(token)
            }
        }
    }

    public var isEmpty: Bool { terms.isEmpty }

    func matches(item: PhotoItem, in section: TimelineSection, context: TimelineSearchContext) -> Bool {
        var haystack = Self.searchText(for: item, in: section)
        let name = context.photoNames?.normalizedName(of: item.uid)
        if let name { haystack += " " + name }
        return terms.allSatisfy { term in
            switch term {
            case .text(let token):
                haystack.contains(token)
            case .smart(let smart, let token):
                Self.matches(smart, item: item, section: section, haystack: haystack, context: context)
                    || name?.contains(token) == true
            }
        }
    }

    /// Whether every token of the query appears in the file name of `uid`, as a prefix or a substring.
    public func matchesName(of uid: PhotoUID, in names: PhotoNameIndex) -> Bool {
        guard !tokens.isEmpty, let name = names.normalizedName(of: uid) else { return false }
        return tokens.allSatisfy { name.contains($0) }
    }

    /// Whether a query reads as a file name, so that name hits lead the result. It holds when the trimmed query has
    /// no white space, contains a digit, `_` or `.`, and is not a plain date or number of the date search: a day or
    /// month (one or two digits), a year from 1900 to 2099, `2019-05`, `2019-05-01`, `1.5.2019` or `01.05.2019`.
    ///
    /// `IMG_33`, `3350`, `.HEIC` and `DSC01234` read as names; `sunset`, `paris 2019`, `IMG 3350` and `2019` do not.
    public static func looksLikeFileName(_ raw: String) -> Bool {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        guard query.rangeOfCharacter(from: fileNameMarks) != nil else { return false }
        return !isDateQuery(query)
    }

    private static let fileNameMarks = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "_."))

    private static func isDateQuery(_ query: String) -> Bool {
        func isNumber(_ part: Substring, digits: ClosedRange<Int>) -> Bool {
            digits.contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
        func isYear(_ part: Substring) -> Bool {
            isNumber(part, digits: 4...4) && (part.hasPrefix("19") || part.hasPrefix("20"))
        }
        let whole = Substring(query)
        if isNumber(whole, digits: 1...2) || isYear(whole) { return true }
        let dashed = whole.split(separator: "-", omittingEmptySubsequences: false)
        if (2...3).contains(dashed.count), isYear(dashed[0]),
            dashed.dropFirst().allSatisfy({ isNumber($0, digits: 1...2) })
        {
            return true
        }
        let dotted = whole.split(separator: ".", omittingEmptySubsequences: false)
        return dotted.count == 3 && isNumber(dotted[0], digits: 1...2) && isNumber(dotted[1], digits: 1...2)
            && isYear(dotted[2])
    }

    private static func matches(
        _ smart: SmartKind, item: PhotoItem, section: TimelineSection,
        haystack: String, context: TimelineSearchContext
    ) -> Bool {
        if item.tags.contains(smart.photoTag) { return true }
        if case .tag(let activeTag) = context.activeFilter, activeTag == smart.photoTag { return true }

        switch smart {
        case .favorites:
            return context.favoriteUIDs.contains(item.uid)
        case .videos:
            return item.isVideo
        case .raw:
            return isRawMediaType(item.mediaType)
        case .screenshots:
            return haystack.contains("screenshot") || haystack.contains("bildschirmfoto")
                || item.mediaType == "image/png"
        case .selfies:
            return haystack.contains("selfie")
        }
    }

    private static func smartKind(for token: String) -> SmartKind? {
        switch token {
        case "favorite", "favorites", "favourite", "favourites", "favorit", "favoriten", "heart", "herz":
            .favorites
        case "video", "videos", "film", "filme", "movie", "movies":
            .videos
        case "screenshot", "screenshots", "bildschirmfoto", "bildschirmfotos":
            .screenshots
        case "selfie", "selfies", "selbstportrait", "selbstportraits", "selbstportrat", "selbstportrats":
            .selfies
        case "raw", "dng":
            .raw
        default:
            nil
        }
    }

    private static func searchText(for item: PhotoItem, in section: TimelineSection) -> String {
        var fields: [String] = [
            item.uid.nodeID,
            item.uid.volumeID,
            item.mediaType,
            item.isVideo ? "video videos film filme movie movies" : "photo foto image bild",
            item.isLivePhoto ? "live photo livephoto" : "",
            section.id,
            section.title,
        ]

        fields.append(contentsOf: dateFields(for: item.captureTime))
        if gregorianUTC.isDate(item.captureTime, inSameDayAs: section.date) == false {
            fields.append(contentsOf: dateFields(for: section.date))
        }
        fields.append(contentsOf: item.tags.map(\.title))

        return normalize(fields.joined(separator: " "))
    }

    private static func dateFields(for date: Date) -> [String] {
        let components = gregorianUTC.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return [] }

        let monthIndex = max(0, min(11, month - 1))
        let twoMonth = twoDigits(month)
        let twoDay = twoDigits(day)

        return [
            "\(year)",
            "\(month)", twoMonth,
            "\(day)", twoDay,
            "\(year)-\(twoMonth)-\(twoDay)",
            "\(day).\(month).\(year)",
            "\(twoDay).\(twoMonth).\(year)",
            monthNamesEN[monthIndex],
            String(monthNamesEN[monthIndex].prefix(3)),
            monthNamesDE[monthIndex],
            String(monthNamesDE[monthIndex].prefix(3)),
        ]
    }

    private static func isRawMediaType(_ mediaType: String) -> Bool {
        let value = normalize(mediaType)
        return value.contains("raw")
            || value.contains("dng")
            || value.contains("x-adobe-dng")
            || value.contains("x-canon-cr2")
            || value.contains("x-canon-cr3")
            || value.contains("x-nikon-nef")
            || value.contains("x-sony-arw")
            || value.contains("x-panasonic-rw2")
            || value.contains("x-fuji-raf")
    }

    private static func tokens(from raw: String) -> [String] {
        normalize(raw)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ text: String) -> String {
        SearchTextNormalization.normalize(text)
    }

    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static let monthNamesEN = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private static let monthNamesDE = [
        "januar", "februar", "maerz", "april", "mai", "juni",
        "juli", "august", "september", "oktober", "november", "dezember",
    ]

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
