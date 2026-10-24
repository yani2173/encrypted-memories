import Foundation
import PhotosCore

/// Inputs shared by every library-aware suggestion family. Calendar, locale and `now` are injected so the
/// families stay deterministic in tests and follow the user's local day boundaries at runtime.
public struct TimelineSearchDiscoveryContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    public var favoriteUIDs: Set<PhotoUID>
    /// Items that may appear in results but never as a landing preview (for example the ML sensitive gate).
    public var excludedRepresentativeUIDs: Set<PhotoUID>
    /// When supplied, only items accepted by this check may become previews. Result membership stays unchanged.
    public var allowsRepresentative: (@Sendable (PhotoUID) -> Bool)?
    /// Set when the sensitive gate should run but could not complete. Suggestions then carry no previews at
    /// all, so an unchecked photo is never shown on the landing.
    public var suppressesRepresentatives: Bool

    public init(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        favoriteUIDs: Set<PhotoUID> = [],
        excludedRepresentativeUIDs: Set<PhotoUID> = [],
        allowsRepresentative: (@Sendable (PhotoUID) -> Bool)? = nil,
        suppressesRepresentatives: Bool = false
    ) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.favoriteUIDs = favoriteUIDs
        self.excludedRepresentativeUIDs = excludedRepresentativeUIDs
        self.allowsRepresentative = allowsRepresentative
        self.suppressesRepresentatives = suppressesRepresentatives
    }
}

/// Metadata-only suggestions. Prominent rows go to `forYou`; compact media-type entries go to `chips`.
public struct TimelineSearchDiscoveryResult: Equatable, Sendable {
    public var forYou: [TimelineSearchSuggestion]
    public var chips: [TimelineSearchSuggestion]

    public init(forYou: [TimelineSearchSuggestion] = [], chips: [TimelineSearchSuggestion] = []) {
        self.forYou = forYou
        self.chips = chips
    }
}

/// Metadata rows with their matching photos, before previews are chosen. They depend only on the photos, the
/// favorites, the calendar day, and the locale of the context. A caller can build them once and choose the
/// previews for each state of the sensitive gate with `librarySuggestions(rows:context:)`.
public struct TimelineSearchLibraryRows: Sendable {
    struct Row: Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let systemImage: String
        let kind: TimelineSearchSuggestionKind
        let matches: [PhotoItem]

        func suggestion(context: TimelineSearchDiscoveryContext) -> TimelineSearchSuggestion {
            TimelineSearchSuggestion(
                id: id,
                query: title,
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                kind: kind,
                matchingUIDs: Set(matches.map(\.uid)),
                representativeUIDs: TimelineSearchDiscovery.representatives(for: matches, context: context)
            )
        }
    }

    let forYou: [Row]
    let chips: [Row]

    init(forYou: [Row] = [], chips: [Row] = []) {
        self.forYou = forYou
        self.chips = chips
    }
}

public enum TimelineSearchSeason: Int, CaseIterable, Sendable {
    case spring
    case summer
    case autumn
    case winter

    /// Meteorological seasons. December belongs to the winter of the following year, so "Winter 2025"
    /// covers December 2024 to February 2025.
    static func season(month: Int, southernHemisphere: Bool) -> TimelineSearchSeason {
        let northern: TimelineSearchSeason =
            switch month {
            case 3...5: .spring
            case 6...8: .summer
            case 9...11: .autumn
            default: .winter
            }
        guard southernHemisphere else { return northern }
        return switch northern {
        case .spring: .autumn
        case .summer: .winter
        case .autumn: .spring
        case .winter: .summer
        }
    }

    public var title: String {
        switch self {
        case .spring: L10n.string("search.season.spring")
        case .summer: L10n.string("search.season.summer")
        case .autumn: L10n.string("search.season.autumn")
        case .winter: L10n.string("search.season.winter")
        }
    }

    func placeTitle(_ place: String) -> String {
        switch self {
        case .spring: L10n.string("search.suggestion.place_spring \(place)")
        case .summer: L10n.string("search.suggestion.place_summer \(place)")
        case .autumn: L10n.string("search.suggestion.place_autumn \(place)")
        case .winter: L10n.string("search.suggestion.place_winter \(place)")
        }
    }
}

/// A geographic group of photos that is worth naming. The app resolves a city name for `center` and passes it
/// back to `placeSuggestions`; Core never sends coordinates anywhere itself.
public struct TimelineSearchPlaceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let uids: [PhotoUID]
    public let dates: [Date]
    public let isHome: Bool

    public init(id: String, latitude: Double, longitude: Double, uids: [PhotoUID], dates: [Date], isHome: Bool) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.uids = uids
        self.dates = dates
        self.isHome = isHome
    }
}

extension TimelineSearchDiscovery {
    /// Minimum number of matching items for any suggestion row. Two previews need two distinct items.
    static let minimumRowMatches = 3

    // MARK: Metadata families

    /// Builds the metadata families that work without on-device ML: anniversaries, dense seasons, trips,
    /// favorites and media types. Every suggestion carries its exact matching UID set.
    public static func librarySuggestions(
        sections: [TimelineSection],
        context: TimelineSearchDiscoveryContext
    ) -> TimelineSearchDiscoveryResult {
        librarySuggestions(rows: libraryRows(sections: sections, context: context), context: context)
    }

    /// The metadata families of `librarySuggestions(sections:context:)` without previews. This is the expensive
    /// part: it reads every photo. Empty when the task is cancelled.
    public static func libraryRows(
        sections: [TimelineSection],
        context: TimelineSearchDiscoveryContext
    ) -> TimelineSearchLibraryRows {
        var items: [PhotoItem] = []
        items.reserveCapacity(sections.reduce(0) { $0 + $1.items.count })
        for section in sections {
            guard !Task.isCancelled else { return TimelineSearchLibraryRows() }
            items.append(contentsOf: section.items)
        }
        guard !items.isEmpty else { return TimelineSearchLibraryRows() }
        items.sort { $0.captureTime < $1.captureTime }

        var forYou: [TimelineSearchLibraryRows.Row] = []
        forYou.append(contentsOf: onThisDayRows(items: items, context: context))
        guard !Task.isCancelled else { return TimelineSearchLibraryRows() }
        forYou.append(contentsOf: tripRows(items: items, context: context))
        guard !Task.isCancelled else { return TimelineSearchLibraryRows() }
        forYou.append(contentsOf: seasonRows(items: items, context: context))
        if let favorites = favoritesYearRow(items: items, context: context) {
            forYou.append(favorites)
        }
        guard !Task.isCancelled else { return TimelineSearchLibraryRows() }
        return TimelineSearchLibraryRows(
            forYou: forYou,
            chips: mediaTypeRows(items: items, sections: sections, context: context)
        )
    }

    /// Adds the previews that `context` allows to rows from `libraryRows(sections:context:)`.
    public static func librarySuggestions(
        rows: TimelineSearchLibraryRows,
        context: TimelineSearchDiscoveryContext
    ) -> TimelineSearchDiscoveryResult {
        TimelineSearchDiscoveryResult(
            forYou: rows.forYou.map { $0.suggestion(context: context) },
            chips: rows.chips.map { $0.suggestion(context: context) }
        )
    }

    /// "One year ago", "3 years ago": the same local calendar day plus or minus three days in earlier years.
    static func onThisDayRows(
        items: [PhotoItem],
        context: TimelineSearchDiscoveryContext,
        limit: Int = 2
    ) -> [TimelineSearchLibraryRows.Row] {
        let calendar = context.calendar
        guard let earliest = items.first?.captureTime else { return [] }
        var result: [TimelineSearchLibraryRows.Row] = []
        for yearsAgo in 1...30 {
            guard result.count < limit,
                let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: context.now)
            else { break }
            let anchorDay = calendar.startOfDay(for: anchor)
            guard let start = calendar.date(byAdding: .day, value: -3, to: anchorDay),
                let end = calendar.date(byAdding: .day, value: 4, to: anchorDay)
            else { continue }
            if end < earliest { break }
            let matches = itemsCaptured(in: start..<end, sortedItems: items)
            guard matches.count >= minimumRowMatches else { continue }
            let title = L10n.string("search.suggestion.years_ago \(yearsAgo)")
            result.append(
                row(
                    id: "on-this-day:\(yearsAgo)",
                    title: title,
                    subtitle: subtitle(date: anchorDay, count: matches.count, context: context),
                    systemImage: "clock.arrow.circlepath",
                    kind: .onThisDay,
                    matches: matches
                ))
        }
        return result
    }

    /// Unusually dense runs of days. A trip is at least `minimumDayCount` items on a day, merged with
    /// adjacent dense days, and needs `minimumTripCount` items in total.
    static func tripRows(
        items: [PhotoItem],
        context: TimelineSearchDiscoveryContext,
        limit: Int = 2,
        minimumDayCount: Int = 15,
        minimumTripCount: Int = 25
    ) -> [TimelineSearchLibraryRows.Row] {
        let calendar = context.calendar
        var itemsByDay: [Date: [PhotoItem]] = [:]
        for item in items {
            itemsByDay[calendar.startOfDay(for: item.captureTime), default: []].append(item)
        }
        guard itemsByDay.count > 1 else { return [] }
        let counts = itemsByDay.values.map { Double($0.count) }
        let mean = counts.reduce(0, +) / Double(counts.count)
        let variance = counts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(counts.count)
        let threshold = max(Double(minimumDayCount), mean + 2 * variance.squareRoot())
        let denseDays = itemsByDay.keys.filter { Double(itemsByDay[$0]?.count ?? 0) >= threshold }.sorted()

        var runs: [[Date]] = []
        for day in denseDays {
            if let previous = runs.last?.last,
                let next = calendar.date(byAdding: .day, value: 1, to: previous),
                calendar.isDate(next, inSameDayAs: day)
            {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }

        let intervalFormatter = DateIntervalFormatter()
        intervalFormatter.calendar = calendar
        intervalFormatter.locale = context.locale
        intervalFormatter.timeZone = calendar.timeZone
        intervalFormatter.dateStyle = .medium
        intervalFormatter.timeStyle = .none
        let dayFormatter = dateFormatter(context: context)

        let trips: [(days: [Date], matches: [PhotoItem])] = runs.compactMap { days in
            let matches = days.flatMap { itemsByDay[$0] ?? [] }
            return matches.count >= minimumTripCount ? (days, matches) : nil
        }
        // Newest trips first: they are the most likely to be searched again.
        return trips.sorted { $0.days[0] > $1.days[0] }.prefix(limit).map { trip in
            let first = trip.days[0]
            let last = trip.days[trip.days.count - 1]
            let title =
                trip.days.count == 1
                ? dayFormatter.string(from: first)
                : intervalFormatter.string(from: first, to: last)
            return row(
                id: "trip:\(Int(first.timeIntervalSince1970))",
                title: title,
                subtitle: countText(trip.matches.count),
                systemImage: "suitcase",
                kind: .trip,
                matches: trip.matches
            )
        }
    }

    /// The densest past seasons, for example "Summer 2024". The current season is skipped because the
    /// newest photos are already at the top of the library.
    static func seasonRows(
        items: [PhotoItem],
        context: TimelineSearchDiscoveryContext,
        limit: Int = 2,
        minimumCount: Int = 20
    ) -> [TimelineSearchLibraryRows.Row] {
        let calendar = context.calendar
        struct SeasonKey: Hashable {
            let season: TimelineSearchSeason
            let year: Int
        }
        func key(for date: Date) -> SeasonKey {
            let components = calendar.dateComponents([.year, .month], from: date)
            let month = components.month ?? 1
            let year = (components.year ?? 0) + (month == 12 ? 1 : 0)
            return SeasonKey(season: .season(month: month, southernHemisphere: false), year: year)
        }
        var groups: [SeasonKey: [PhotoItem]] = [:]
        for item in items {
            groups[key(for: item.captureTime), default: []].append(item)
        }
        groups.removeValue(forKey: key(for: context.now))
        let ranked = groups.filter { $0.value.count >= minimumCount }
            .sorted { lhs, rhs in
                lhs.value.count == rhs.value.count
                    ? lhs.key.year > rhs.key.year
                    : lhs.value.count > rhs.value.count
            }
        return ranked.prefix(limit).map { group in
            let yearLabel =
                group.key.season == .winter
                ? "\(group.key.year - 1)/\(String(format: "%02d", group.key.year % 100))"
                : "\(group.key.year)"
            return row(
                id: "season:\(group.key.season.rawValue):\(group.key.year)",
                title: "\(group.key.season.title) \(yearLabel)",
                subtitle: countText(group.value.count),
                systemImage: seasonSymbol(group.key.season),
                kind: .season,
                matches: group.value
            )
        }
    }

    /// "Favorites from 2025" for the most recent year that has enough favorites.
    static func favoritesYearRow(
        items: [PhotoItem],
        context: TimelineSearchDiscoveryContext,
        minimumCount: Int = 6
    ) -> TimelineSearchLibraryRows.Row? {
        guard !context.favoriteUIDs.isEmpty else { return nil }
        var byYear: [Int: [PhotoItem]] = [:]
        for item in items where context.favoriteUIDs.contains(item.uid) {
            byYear[context.calendar.component(.year, from: item.captureTime), default: []].append(item)
        }
        guard let year = byYear.keys.sorted(by: >).first(where: { (byYear[$0]?.count ?? 0) >= minimumCount }),
            let matches = byYear[year]
        else { return nil }
        return row(
            id: "favorites:\(year)",
            title: L10n.string("search.suggestion.favorites_year \(String(year))"),
            subtitle: countText(matches.count),
            systemImage: "heart",
            kind: .favorites,
            matches: matches
        )
    }

    /// Media-type shortcuts. A type is shown only when it exists and does not dominate the library, because a
    /// filter that matches almost everything carries no information.
    static func mediaTypeRows(
        items: [PhotoItem],
        sections: [TimelineSection],
        context: TimelineSearchDiscoveryContext
    ) -> [TimelineSearchLibraryRows.Row] {
        let searchContext = TimelineSearchContext(favoriteUIDs: context.favoriteUIDs)
        let lexical: [(PhotoTag, String, String)] = [
            (.favorites, "favorites", "heart"),
            (.videos, "videos", "video"),
            (.screenshots, "screenshots", "camera.viewfinder"),
            (.selfies, "selfies", "person.crop.square"),
            (.raw, "raw", "r.square"),
        ]
        var result: [TimelineSearchLibraryRows.Row] = []
        for (tag, token, symbol) in lexical {
            guard !Task.isCancelled else { return [] }
            let matches = TimelineSearch.filter(sections, query: token, context: searchContext).flatMap(\.items)
            if let chip = mediaChip(tag: tag, symbol: symbol, matches: matches, total: items.count) {
                result.append(chip)
            }
        }
        let tagged: [(PhotoTag, String, (PhotoItem) -> Bool)] = [
            (.livePhotos, "livephoto", { $0.isLivePhoto || $0.tags.contains(.livePhotos) }),
            (.panoramas, "pano", { $0.tags.contains(.panoramas) }),
            (.portraits, "person.and.background.dotted", { $0.tags.contains(.portraits) }),
            (.bursts, "square.stack.3d.down.right", { $0.isBurstCandidate }),
        ]
        for (tag, symbol, predicate) in tagged {
            let matches = items.filter(predicate)
            if let chip = mediaChip(tag: tag, symbol: symbol, matches: matches, total: items.count) {
                result.append(chip)
            }
        }
        return result
    }

    private static func mediaChip(
        tag: PhotoTag,
        symbol: String,
        matches: [PhotoItem],
        total: Int
    ) -> TimelineSearchLibraryRows.Row? {
        guard matches.count >= minimumRowMatches, Double(matches.count) <= Double(total) * 0.6 else { return nil }
        return row(
            id: "media:\(tag.rawValue)",
            title: tag.title,
            subtitle: countText(matches.count),
            systemImage: symbol,
            kind: .mediaType,
            matches: matches
        )
    }

    // MARK: Places

    /// Groups geotagged items into roughly 5 km cells and returns the most relevant candidates to name.
    /// The largest cell is marked as home when it holds more than 35 % of all geotagged items.
    public static func placeCandidates(
        coordinates: [PhotoCoordinate],
        limit: Int = 10,
        minimumCount: Int = 6,
        evidence: PhotoPlaceEvidence? = nil
    ) -> [TimelineSearchPlaceCandidate] {
        let coordinates = evidence?.coordinates ?? coordinates
        guard !coordinates.isEmpty else { return [] }
        var cells: [PhotoPlaceEvidence.Cell: [PhotoCoordinate]] = [:]
        let excluded = (evidence ?? PhotoPlaceEvidence(coordinates: coordinates)).excludedPositions()
        for coordinate in coordinates {
            guard !Task.isCancelled else { return [] }
            guard PhotoPlaceEvidence.isValid(coordinate), !excluded.contains(PhotoExactPosition(coordinate)) else {
                continue
            }
            let cell = PhotoPlaceEvidence.Cell(coordinate)
            cells[cell, default: []].append(coordinate)
        }
        let geotaggedCount = cells.values.reduce(0) { $0 + $1.count }
        let largest = cells.max { $0.value.count < $1.value.count }?.key
        let candidates: [TimelineSearchPlaceCandidate] = cells.compactMap { cell, members in
            guard members.count >= minimumCount else { return nil }
            let latitude = members.reduce(0) { $0 + $1.latitude } / Double(members.count)
            let longitude = members.reduce(0) { $0 + $1.longitude } / Double(members.count)
            let sorted = members.sorted { $0.date < $1.date }
            return TimelineSearchPlaceCandidate(
                id: "\(cell.latitude):\(cell.longitude)",
                latitude: latitude,
                longitude: longitude,
                uids: sorted.map(\.uid),
                dates: sorted.map(\.date),
                isHome: cell == largest && Double(members.count) > Double(geotaggedCount) * 0.35
            )
        }
        // Favor places visited on several days; home stays available but ranks last.
        return
            candidates
            .sorted { lhs, rhs in
                if lhs.isHome != rhs.isHome { return !lhs.isHome }
                return lhs.uids.count > rhs.uids.count
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Turns named place candidates into suggestions. Cells that resolve to the same name are merged, so a city
    /// spread over several cells becomes one row. A place with a dominant season also gets
    /// "Klosterneuburg in spring".
    public static func placeSuggestions(
        candidates: [TimelineSearchPlaceCandidate],
        names: [String: String],
        itemsByUID: [PhotoUID: PhotoItem],
        context: TimelineSearchDiscoveryContext,
        limit: Int = 3
    ) -> [TimelineSearchSuggestion] {
        var merged: [String: (uids: [PhotoUID], isHome: Bool, latitude: Double)] = [:]
        var order: [String] = []
        for candidate in candidates {
            guard let rawName = names[candidate.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawName.isEmpty
            else { continue }
            if merged[rawName] == nil { order.append(rawName) }
            var entry = merged[rawName] ?? ([], true, candidate.latitude)
            entry.uids.append(contentsOf: candidate.uids)
            entry.isHome = entry.isHome && candidate.isHome
            merged[rawName] = entry
        }

        var result: [TimelineSearchSuggestion] = []
        for name in order {
            guard let entry = merged[name] else { continue }
            let matches = entry.uids.compactMap { itemsByUID[$0] }.sorted { $0.captureTime < $1.captureTime }
            guard matches.count >= minimumRowMatches else { continue }
            let distinctDays = Set(matches.map { context.calendar.startOfDay(for: $0.captureTime) }).count
            let southern = entry.latitude < 0
            var bySeason: [TimelineSearchSeason: [PhotoItem]] = [:]
            for item in matches {
                let month = context.calendar.component(.month, from: item.captureTime)
                bySeason[.season(month: month, southernHemisphere: southern), default: []].append(item)
            }
            if !entry.isHome,
                let dominant = bySeason.max(by: { $0.value.count < $1.value.count }),
                dominant.value.count >= minimumRowMatches,
                Double(dominant.value.count) >= Double(matches.count) * 0.4,
                bySeason.count > 1 || distinctDays > 1
            {
                result.append(
                    suggestion(
                        id: "place-season:\(name):\(dominant.key.rawValue)",
                        title: dominant.key.placeTitle(name),
                        subtitle: countText(dominant.value.count),
                        systemImage: seasonSymbol(dominant.key),
                        kind: .placeSeason,
                        matches: dominant.value,
                        context: context
                    ))
            }
            result.append(
                suggestion(
                    id: "place:\(name)",
                    title: name,
                    subtitle: countText(matches.count),
                    systemImage: entry.isHome ? "house" : "mappin.and.ellipse",
                    kind: .place,
                    matches: matches,
                    context: context
                ))
            if result.count >= limit * 2 { break }
        }
        return result
    }

    // MARK: Ranking and previews

    /// Interleaves families so the landing stays varied, keeps at most `perKind` rows of one kind and drops
    /// duplicate result sets.
    public static func rankForYou(
        _ groups: [[TimelineSearchSuggestion]],
        limit: Int = 8,
        perKind: Int = 2
    ) -> [TimelineSearchSuggestion] {
        var result: [TimelineSearchSuggestion] = []
        var countByKind: [TimelineSearchSuggestionKind: Int] = [:]
        var seenIDs = Set<String>()
        var seenMatchSets = Set<Set<PhotoUID>>()
        let depth = groups.map(\.count).max() ?? 0
        for index in 0..<depth {
            for group in groups where index < group.count {
                let candidate = group[index]
                guard result.count < limit,
                    countByKind[candidate.kind, default: 0] < perKind,
                    seenIDs.insert(candidate.id).inserted
                else { continue }
                if let matches = candidate.matchingUIDs {
                    guard seenMatchSets.insert(matches).inserted else { continue }
                }
                countByKind[candidate.kind, default: 0] += 1
                result.append(candidate)
            }
        }
        return result
    }

    /// Chooses up to `count` previews: a favorite first when one exists, then items far apart in time so two
    /// thumbnails of the same burst do not repeat the same picture.
    public static func representatives(
        for matches: [PhotoItem],
        count: Int = 2,
        context: TimelineSearchDiscoveryContext
    ) -> [PhotoUID] {
        guard !context.suppressesRepresentatives else { return [] }
        let eligible = matches.filter {
            !context.excludedRepresentativeUIDs.contains($0.uid)
                && (context.allowsRepresentative?($0.uid) ?? true)
        }
        .sorted { $0.captureTime < $1.captureTime }
        guard !eligible.isEmpty, count > 0 else { return [] }
        let first =
            eligible.last(where: { context.favoriteUIDs.contains($0.uid) })
            ?? eligible[eligible.count / 2]
        var picked = [first]
        while picked.count < min(count, eligible.count) {
            let next = eligible.filter { candidate in !picked.contains { $0.uid == candidate.uid } }
                .max { lhs, rhs in
                    minimumDistance(lhs, to: picked) < minimumDistance(rhs, to: picked)
                }
            guard let next else { break }
            picked.append(next)
        }
        return picked.map(\.uid)
    }

    private static func minimumDistance(_ item: PhotoItem, to picked: [PhotoItem]) -> TimeInterval {
        picked.map { abs($0.captureTime.timeIntervalSince(item.captureTime)) }.min() ?? 0
    }

    // MARK: Helpers

    static func suggestion(
        id: String,
        title: String,
        subtitle: String?,
        systemImage: String,
        kind: TimelineSearchSuggestionKind,
        matches: [PhotoItem],
        context: TimelineSearchDiscoveryContext
    ) -> TimelineSearchSuggestion {
        row(id: id, title: title, subtitle: subtitle, systemImage: systemImage, kind: kind, matches: matches)
            .suggestion(context: context)
    }

    static func row(
        id: String,
        title: String,
        subtitle: String?,
        systemImage: String,
        kind: TimelineSearchSuggestionKind,
        matches: [PhotoItem]
    ) -> TimelineSearchLibraryRows.Row {
        TimelineSearchLibraryRows.Row(
            id: id, title: title, subtitle: subtitle, systemImage: systemImage, kind: kind, matches: matches)
    }

    public static func countText(_ count: Int) -> String {
        L10n.string("search.suggestion.count \(count)")
    }

    private static func subtitle(date: Date, count: Int, context: TimelineSearchDiscoveryContext) -> String {
        "\(dateFormatter(context: context).string(from: date)) · \(countText(count))"
    }

    private static func dateFormatter(context: TimelineSearchDiscoveryContext) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = context.calendar
        formatter.locale = context.locale
        formatter.timeZone = context.calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private static func seasonSymbol(_ season: TimelineSearchSeason) -> String {
        switch season {
        case .spring: "camera.macro"
        case .summer: "sun.max"
        case .autumn: "leaf"
        case .winter: "snowflake"
        }
    }

    /// Binary search over items sorted by capture time.
    private static func itemsCaptured(in range: Range<Date>, sortedItems: [PhotoItem]) -> [PhotoItem] {
        var low = 0
        var high = sortedItems.count
        while low < high {
            let mid = (low + high) / 2
            if sortedItems[mid].captureTime < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var result: [PhotoItem] = []
        var index = low
        while index < sortedItems.count, sortedItems[index].captureTime < range.upperBound {
            result.append(sortedItems[index])
            index += 1
        }
        return result
    }
}
