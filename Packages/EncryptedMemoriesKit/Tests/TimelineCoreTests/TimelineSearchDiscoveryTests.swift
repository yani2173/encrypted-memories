import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineSearchDiscoveryTests {
    @Test func historyTrimsDeduplicatesAndMovesARepeatedQueryToTheFront() {
        var history = TimelineSearchHistory(queries: [" Pizza ", "Baum", "pizza", ""])

        #expect(history.queries == ["Pizza", "Baum"])

        history.record("  baum  ")
        #expect(history.queries == ["baum", "Pizza"])
    }

    @Test func isoDayQueryMatchesTheCaptureDayOfAnItemInANeutralSection() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = item("first", date: date(2026, 3, 23, calendar: calendar))
        let second = item("second", date: date(2025, 12, 1, calendar: calendar))

        let filtered = TimelineSearch.filter(
            [TimelineSection(id: "all", date: second.captureTime, title: "", items: [second, first])],
            query: "2026-03-23"
        )
        #expect(filtered.flatMap(\.items).map(\.uid) == [first.uid])
    }

    private func item(_ id: String, date: Date) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: id), captureTime: date, mediaType: "image/jpeg")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
