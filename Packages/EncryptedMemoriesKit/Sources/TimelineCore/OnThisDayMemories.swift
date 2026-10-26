import Foundation
import PhotosCore

/// The calendar day that On This Day looks back from, in the calendar that the library groups its days with.
///
/// The era is part of the identity, so calendars whose year numbers restart with each era (for example the Japanese
/// calendar) never treat two different years as the same.
public struct OnThisDayReferenceDay: Hashable, Codable, Sendable {
    public let era: Int
    public let year: Int
    public let month: Int
    public let day: Int
    public let isLeapMonth: Bool

    public init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: date)
        era = components.era ?? 1
        year = components.year ?? 0
        month = components.month ?? 1
        day = components.day ?? 1
        isLeapMonth = components.isLeapMonth ?? false
    }

    /// Same month and day, in any year. A leap month only matches a leap month, so a literal date never moves.
    func hasSameMonthAndDay(as other: OnThisDayReferenceDay) -> Bool {
        month == other.month && day == other.day && isLeapMonth == other.isLeapMonth
    }
}

/// The photos and videos of one previous year that were captured on the reference day's month and day.
public struct OnThisDayYear: Identifiable, Equatable, Sendable {
    /// Whole years between this day and the reference day; at least 1.
    public let yearsAgo: Int
    /// The calendar day of these photos in the library's calendar and time zone.
    public let day: DateInterval
    /// Every match of the day, in canonical timeline order. Nothing is collapsed or capped.
    public let items: [PhotoItem]

    public var id: Int { yearsAgo }
}

/// The memories of one reference day, newest year first ("1 year ago" before "2 years ago").
public struct OnThisDayMemories: Equatable, Sendable {
    public let referenceDay: OnThisDayReferenceDay
    public let years: [OnThisDayYear]

    public init(referenceDay: OnThisDayReferenceDay, years: [OnThisDayYear]) {
        self.referenceDay = referenceDay
        self.years = years
    }

    public var isEmpty: Bool { years.isEmpty }
    public var itemCount: Int { years.reduce(0) { $0 + $1.items.count } }

    public func year(_ yearsAgo: Int) -> OnThisDayYear? {
        years.first { $0.yearsAgo == yearsAgo }
    }

    /// Selects the photos and videos of `items` that were captured on the month and day of `reference` in an earlier
    /// year. The current year and every later date are excluded. February 29 matches only February 29.
    ///
    /// The selection reads only the capture dates of the library snapshot, with the calendar and time zone of
    /// `calendar`. It sends no request and needs no Smart Search. Items keep their library identity, so a Live Photo
    /// or a series appears exactly as the library presents it.
    public init(items: [PhotoItem], reference: Date, calendar: Calendar) {
        // Without cancellation checks, `make` cannot throw.
        self = try! Self.make(items: items, reference: reference, calendar: calendar, checkCancellation: false)
    }

    /// Builds the selection on a detached task and checks cancellation during the scan of a large library.
    public static func build(items: [PhotoItem], reference: Date, calendar: Calendar) async throws -> Self {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Self.make(items: items, reference: reference, calendar: calendar, checkCancellation: true)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct Candidate {
        let yearsAgo: Int
        let day: DateInterval
    }

    private static func make(
        items: [PhotoItem],
        reference: Date,
        calendar: Calendar,
        checkCancellation: Bool
    ) throws -> Self {
        let referenceDay = OnThisDayReferenceDay(date: reference, calendar: calendar)
        guard let earliest = items.lazy.map(\.captureTime).min() else {
            return Self(referenceDay: referenceDay, years: [])
        }
        let candidates = candidateDays(
            referenceDay: referenceDay, reference: reference, earliest: earliest, calendar: calendar)
        guard !candidates.isEmpty else { return Self(referenceDay: referenceDay, years: []) }

        // Each item is matched against the past days by date, so the scan needs no calendar arithmetic per item and
        // does not depend on the order of `items`.
        var matches = [[PhotoItem]](repeating: [], count: candidates.count)
        for (offset, item) in items.enumerated() {
            if checkCancellation, offset % 4_096 == 0 { try Task.checkCancellation() }
            if let index = candidateIndex(containing: item.captureTime, in: candidates) {
                matches[index].append(item)
            }
        }
        // Candidates are oldest first; the newest year leads.
        var years: [OnThisDayYear] = []
        for index in candidates.indices.reversed() where !matches[index].isEmpty {
            let candidate = candidates[index]
            years.append(OnThisDayYear(yearsAgo: candidate.yearsAgo, day: candidate.day, items: matches[index]))
        }
        return Self(referenceDay: referenceDay, years: years)
    }

    /// The calendar days with the reference month and day in every earlier year back to `earliest`, oldest first.
    /// A year without that day, such as a year without February 29, has no candidate.
    private static func candidateDays(
        referenceDay: OnThisDayReferenceDay,
        reference: Date,
        earliest: Date,
        calendar: Calendar
    ) -> [Candidate] {
        let referenceStart = calendar.startOfDay(for: reference)
        var candidates: [Candidate] = []
        // The bound only stops a corrupt date far in the past from looping for long; real libraries end much earlier.
        for yearsAgo in 1...maximumYearsBack {
            guard let shifted = calendar.date(byAdding: .year, value: -yearsAgo, to: referenceStart),
                let day = calendar.dateInterval(of: .day, for: shifted)
            else { break }
            guard day.end > earliest else { break }
            // Adding years moves February 29 to February 28; a literal date never matches a neighbouring day.
            guard OnThisDayReferenceDay(date: shifted, calendar: calendar).hasSameMonthAndDay(as: referenceDay)
            else { continue }
            candidates.append(Candidate(yearsAgo: yearsAgo, day: day))
        }
        return candidates.reversed()
    }

    static let maximumYearsBack = 10_000

    /// Binary search over the ascending, disjoint candidate days.
    private static func candidateIndex(containing date: Date, in candidates: [Candidate]) -> Int? {
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle].day.end <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < candidates.count, candidates[low].day.start <= date else { return nil }
        return low
    }
}

/// What the On This Day area can say about the reference day.
///
/// An incomplete inventory may already show the matches it has, but it never claims that a day has no memories.
public enum OnThisDayAvailability: Equatable, Sendable {
    /// The library could not be loaded and has nothing to show.
    case unavailable
    /// The selection is not known yet, or the inventory is incomplete and has no match so far.
    case loading
    /// Matches from an incomplete inventory. More can follow when the inventory completes.
    case partial(OnThisDayMemories)
    /// Matches from the complete inventory.
    case ready(OnThisDayMemories)
    /// The complete inventory has no photo or video from this day in an earlier year.
    case empty

    /// - Parameters:
    ///   - memories: The current selection, or nil while it is not built for the current library and day.
    ///   - authority: The completeness of the inventory that `memories` was built from.
    ///   - loadFailed: The library reported a load failure.
    public static func resolve(
        memories: OnThisDayMemories?,
        authority: SourceInventoryAuthority,
        loadFailed: Bool
    ) -> Self {
        guard let memories else { return loadFailed ? .unavailable : .loading }
        if authority == .authoritative, !loadFailed {
            return memories.isEmpty ? .empty : .ready(memories)
        }
        if !memories.isEmpty { return .partial(memories) }
        return loadFailed ? .unavailable : .loading
    }

    public var memories: OnThisDayMemories? {
        switch self {
        case .partial(let memories), .ready(let memories): memories
        case .unavailable, .loading, .empty: nil
        }
    }

    /// Whether the calendar control shows its quiet badge: only for complete memories of the day that the person has
    /// not opened yet, or when more memories arrived since. Nothing shows while the library loads.
    public func showsUnseenBadge(seen: OnThisDaySeenRecord?) -> Bool {
        guard case .ready(let memories) = self else { return false }
        guard let seen, seen.referenceDay == memories.referenceDay else { return true }
        return memories.itemCount > seen.itemCount
    }
}

/// The memories of a day that the person has opened. It holds no photo identity: only the day and how many
/// memories it had, so the badge returns when more arrive.
public struct OnThisDaySeenRecord: Codable, Equatable, Sendable {
    public let referenceDay: OnThisDayReferenceDay
    public let itemCount: Int

    public init(memories: OnThisDayMemories) {
        referenceDay = memories.referenceDay
        itemCount = memories.itemCount
    }
}

/// Keeps the seen record of the signed-in account. Sign-out removes it with the other account data.
public struct OnThisDaySeenStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OnThisDaySeenRecord? {
        guard let data = defaults.data(forKey: AppSettingsKey.onThisDaySeen) else { return nil }
        return try? JSONDecoder().decode(OnThisDaySeenRecord.self, from: data)
    }

    public func save(_ record: OnThisDaySeenRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: AppSettingsKey.onThisDaySeen)
    }

    public func clear() {
        defaults.removeObject(forKey: AppSettingsKey.onThisDaySeen)
    }
}

/// Which year and which card of each stack the person is looking at.
///
/// Year navigation and card browsing are separate: moving to another card never changes the year, and the position
/// follows the photo's identity, so a library change does not replace the photo that the person is looking at.
public struct OnThisDayBrowser: Equatable, Sendable {
    /// The year in focus, by `yearsAgo`.
    public private(set) var focusedYear: Int?
    private var currentUIDs: [Int: PhotoUID] = [:]
    private var currentIndices: [Int: Int] = [:]

    public init() {}

    /// The card shown on top of a year's stack.
    public func currentIndex(in year: OnThisDayYear) -> Int {
        if let uid = currentUIDs[year.yearsAgo], let index = year.items.firstIndex(where: { $0.uid == uid }) {
            return index
        }
        return min(currentIndices[year.yearsAgo] ?? 0, max(0, year.items.count - 1))
    }

    public func currentItem(in year: OnThisDayYear) -> PhotoItem? {
        year.items.isEmpty ? nil : year.items[currentIndex(in: year)]
    }

    public mutating func focus(_ year: OnThisDayYear) {
        focusedYear = year.yearsAgo
    }

    /// Moves to the next (`by: 1`) or previous (`by: -1`) card of a year's stack, without wrapping around.
    public mutating func move(in year: OnThisDayYear, by offset: Int) {
        guard !year.items.isEmpty else { return }
        let index = min(max(currentIndex(in: year) + offset, 0), year.items.count - 1)
        select(index: index, in: year)
    }

    public mutating func select(index: Int, in year: OnThisDayYear) {
        guard year.items.indices.contains(index) else { return }
        focusedYear = year.yearsAgo
        currentUIDs[year.yearsAgo] = year.items[index].uid
        currentIndices[year.yearsAgo] = index
    }

    /// Follows a new selection. A card whose photo is still there stays on top. A removed photo is replaced by the
    /// photo that took its place, and a removed year loses its position and its focus.
    public mutating func reconcile(with memories: OnThisDayMemories) {
        var uids: [Int: PhotoUID] = [:]
        var indices: [Int: Int] = [:]
        for year in memories.years where currentIndices[year.yearsAgo] != nil {
            let index = currentIndex(in: year)
            uids[year.yearsAgo] = year.items[index].uid
            indices[year.yearsAgo] = index
        }
        currentUIDs = uids
        currentIndices = indices
        if let focusedYear, memories.year(focusedYear) == nil { self.focusedYear = nil }
    }
}
