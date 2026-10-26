import CoreGraphics
import Foundation
import GridCore
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineVisibleDateRangeTests {
    @Test func rangeUsesTheEarliestAndLatestVisibleDateInAnyOrder() {
        let items = [
            item("a", date: date(2026, 10, 25, 9)),
            item("b", date: date(2026, 10, 24, 18)),
            item("c", date: date(2026, 10, 26, 7)),
        ]

        let range = TimelineVisibleDateRange(items: items, visibleIndices: [0, 1])

        #expect(range == TimelineVisibleDateRange(earliest: date(2026, 10, 24, 18), latest: date(2026, 10, 25, 9)))
    }

    @Test func rangeIgnoresIndicesOutsideTheItemsAndIsNilWithoutVisibleItems() {
        let items = [item("a", date: date(2026, 10, 25, 9))]

        #expect(TimelineVisibleDateRange(items: items, visibleIndices: [0, 5])?.latest == date(2026, 10, 25, 9))
        #expect(TimelineVisibleDateRange(items: items, visibleIndices: [3]) == nil)
        #expect(TimelineVisibleDateRange(items: items, visibleIndices: []) == nil)
    }

    @Test func slotsHiddenBehindTheBarsDoNotCount() {
        let items = [
            item("under-top-bar", date: date(2026, 9, 1, 12)),
            item("visible", date: date(2026, 10, 25, 12)),
            item("under-bottom-bar", date: date(2026, 11, 30, 12)),
        ]
        let slots = [slot(0, y: 0), slot(1, y: 100), slot(2, y: 200)]

        let range = TimelineVisibleDateRange(items: items, slots: slots, visibleTop: 90, visibleBottom: 195)

        #expect(range == TimelineVisibleDateRange(earliest: date(2026, 10, 25, 12), latest: date(2026, 10, 25, 12)))
    }

    @Test func aPartlyVisibleSlotCounts() {
        let items = [item("a", date: date(2026, 10, 24, 12)), item("b", date: date(2026, 10, 25, 12))]
        let slots = [slot(0, y: 0), slot(1, y: 100)]

        let range = TimelineVisibleDateRange(items: items, slots: slots, visibleTop: 79, visibleBottom: 300)

        #expect(range?.earliest == date(2026, 10, 24, 12))
    }

    @Test func aRangeOfUpToAMonthNamesDaysAndAWiderRangeNamesMonths() {
        let month = TimelineVisibleDateRange(earliest: date(2026, 9, 24, 23), latest: date(2026, 10, 25, 0))
        let wider = TimelineVisibleDateRange(earliest: date(2026, 9, 24, 12), latest: date(2026, 10, 26, 12))

        #expect(month.granularity(calendar: Self.calendar) == .day)
        #expect(wider.granularity(calendar: Self.calendar) == .month)
    }

    @Test func oneDayFormatsAsASingleDate() {
        let formatter = TimelineVisibleDateRangeFormatter(calendar: Self.calendar, locale: Locale(identifier: "en_GB"))
        let range = TimelineVisibleDateRange(earliest: date(2026, 10, 25, 8), latest: date(2026, 10, 25, 20))

        let text = formatter.string(for: range)

        #expect(text == singleDay(date(2026, 10, 25, 8), locale: Locale(identifier: "en_GB")))
        #expect(text.contains("25"))
        #expect(text.contains("Oct"))
        #expect(text.contains("2026"))
    }

    @Test func severalDaysNameBothDaysOnce() {
        let formatter = TimelineVisibleDateRangeFormatter(calendar: Self.calendar, locale: Locale(identifier: "en_US"))
        let range = TimelineVisibleDateRange(earliest: date(2026, 10, 24, 8), latest: date(2026, 10, 25, 20))

        let text = formatter.string(for: range)

        #expect(text.contains("24"))
        #expect(text.contains("25"))
        #expect(text.components(separatedBy: "2026").count == 2)
        #expect(text.components(separatedBy: "Oct").count == 2)
    }

    @Test func aWideRangeNamesMonthsWithoutDays() {
        let formatter = TimelineVisibleDateRangeFormatter(calendar: Self.calendar, locale: Locale(identifier: "en_US"))
        let range = TimelineVisibleDateRange(earliest: date(2025, 11, 17, 8), latest: date(2026, 2, 13, 20))

        let text = formatter.string(for: range)

        #expect(text.contains("Nov"))
        #expect(text.contains("Feb"))
        #expect(text.contains("2025"))
        #expect(!text.contains("17"))
        #expect(!text.contains("13"))
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        return calendar
    }

    private func singleDay(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return formatter.string(from: date)
    }

    private func item(_ id: String, date: Date) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "volume", nodeID: id), captureTime: date, mediaType: "image/jpeg")
    }

    private func slot(_ index: Int, y: CGFloat) -> GridSlot {
        let rect = CGRect(x: 0, y: y, width: 80, height: 80)
        return GridSlot(
            index: index, section: 0, item: index, column: 0, row: index, slotRect: rect, viewportRect: rect)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
