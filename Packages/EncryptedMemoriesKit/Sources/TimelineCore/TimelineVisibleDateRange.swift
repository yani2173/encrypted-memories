import CoreGraphics
import Foundation
import GridCore
import PhotosCore

/// The capture dates of the photos on screen. The grid shows them in its top leading corner, as Apple Photos
/// does, so a person who scrolls through the library always sees where they are.
public struct TimelineVisibleDateRange: Equatable, Sendable {
    public enum Granularity: Equatable, Sendable {
        case day
        case month
    }

    /// A wider range names months only: a day label of a dense overview would be long and change on every row.
    public static let maximumDaySpan = 31

    public let earliest: Date
    public let latest: Date

    public init(earliest: Date, latest: Date) {
        self.earliest = min(earliest, latest)
        self.latest = max(earliest, latest)
    }

    /// The range of the visible items. Indices outside `items` are ignored. A search projection orders by
    /// relevance, so the range uses the earliest and latest date, not the first and last visible item.
    public init?(items: [PhotoItem], visibleIndices: some Sequence<Int>) {
        var earliest: Date?
        var latest: Date?
        for index in visibleIndices where items.indices.contains(index) {
            let time = items[index].captureTime
            if earliest.map({ time < $0 }) ?? true { earliest = time }
            if latest.map({ time > $0 }) ?? true { latest = time }
        }
        guard let earliest, let latest else { return nil }
        self.init(earliest: earliest, latest: latest)
    }

    /// The range of the slots that reach into the usable area between `visibleTop` (below a translucent top bar)
    /// and `visibleBottom` (above a bottom bar), in content coordinates. Photos fully under a bar do not count.
    public init?(items: [PhotoItem], slots: [GridSlot], visibleTop: CGFloat, visibleBottom: CGFloat) {
        self.init(
            items: items,
            visibleIndices: slots.lazy
                .filter { $0.slotRect.maxY > visibleTop && $0.slotRect.minY < visibleBottom }
                .map(\.index))
    }

    public func granularity(calendar: Calendar) -> Granularity {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: earliest), to: calendar.startOfDay(for: latest)
        ).day ?? 0
        return days > Self.maximumDaySpan ? .month : .day
    }
}

/// Formats a `TimelineVisibleDateRange` for the grid label, for example "25 Oct 2026" or "Oct 24 – 25, 2026".
/// Keep one per grid: formatter construction is expensive, and the label updates while the person scrolls.
public final class TimelineVisibleDateRangeFormatter {
    private let calendar: Calendar
    private let dayFormatter: DateIntervalFormatter
    private let monthFormatter: DateIntervalFormatter

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        dayFormatter = Self.makeFormatter(template: "d MMM yyyy", calendar: calendar, locale: locale)
        monthFormatter = Self.makeFormatter(template: "MMM yyyy", calendar: calendar, locale: locale)
    }

    public func string(for range: TimelineVisibleDateRange) -> String {
        let formatter = range.granularity(calendar: calendar) == .day ? dayFormatter : monthFormatter
        return formatter.string(from: range.earliest, to: range.latest)
    }

    private static func makeFormatter(template: String, calendar: Calendar, locale: Locale) -> DateIntervalFormatter {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = template
        return formatter
    }
}
