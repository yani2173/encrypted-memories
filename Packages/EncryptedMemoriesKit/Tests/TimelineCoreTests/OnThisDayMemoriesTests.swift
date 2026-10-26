import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct OnThisDayMemoriesTests {
    @Test func earlierYearsOfTheSameDayMatchNewestYearFirstInLibraryOrder() {
        let morning = item("morning", date: date(2025, 10, 26, 8))
        let evening = item("evening", date: date(2025, 10, 26, 20))
        let older = item("older", date: date(2023, 10, 26, 12))
        let items = [
            older,
            item("day-before", date: date(2025, 10, 25, 23, 59)),
            evening,
            morning,
            item("day-after", date: date(2025, 10, 27, 0)),
            item("this-year", date: date(2026, 10, 26, 7)),
            item("next-year", date: date(2027, 10, 26, 7)),
        ]

        let memories = OnThisDayMemories(items: items, reference: date(2026, 10, 26, 10), calendar: Self.utc)

        #expect(memories.years.map(\.yearsAgo) == [1, 3])
        #expect(memories.years[0].items == [evening, morning], "the library order is kept")
        #expect(memories.years[0].day == Self.utc.dateInterval(of: .day, for: date(2025, 10, 26)))
        #expect(memories.years[1].items == [older])
        #expect(memories.itemCount == 3)
    }

    @Test func aDayWithoutEarlierMatchesHasNoYears() {
        let reference = date(2026, 10, 26, 10)

        #expect(OnThisDayMemories(items: [], reference: reference, calendar: Self.utc).isEmpty)
        #expect(
            OnThisDayMemories(
                items: [item("other", date: date(2025, 3, 1)), item("today", date: date(2026, 10, 26, 9))],
                reference: reference, calendar: Self.utc
            ).isEmpty)
    }

    @Test func februaryTwentyNinthMatchesOnlyItself() {
        let leap = item("leap", date: date(2024, 2, 29, 12))
        let lastOfFebruary = item("last-of-february", date: date(2024, 2, 28, 12))
        let marchFirst = item("march-first", date: date(2025, 3, 1, 12))
        let items = [lastOfFebruary, leap, marchFirst]

        let leapReference = OnThisDayMemories(items: items, reference: date(2028, 2, 29, 9), calendar: Self.utc)
        #expect(leapReference.years.map(\.yearsAgo) == [4])
        #expect(leapReference.years[0].items == [leap])

        let februaryReference = OnThisDayMemories(items: items, reference: date(2027, 2, 28, 9), calendar: Self.utc)
        #expect(februaryReference.years.map(\.yearsAgo) == [3])
        #expect(februaryReference.years[0].items == [lastOfFebruary])

        let marchReference = OnThisDayMemories(items: items, reference: date(2027, 3, 1, 9), calendar: Self.utc)
        #expect(marchReference.years.map(\.yearsAgo) == [2])
        #expect(marchReference.years[0].items == [marchFirst])
    }

    @Test func theDayFollowsTheCalendarTimeZone() {
        // 05:00 UTC on 27 October is still 26 October in Los Angeles.
        let lateEvening = item("late-evening", date: date(2025, 10, 27, 5))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let local = OnThisDayMemories(items: [lateEvening], reference: date(2026, 10, 26, 19), calendar: losAngeles)
        let utc = OnThisDayMemories(items: [lateEvening], reference: date(2026, 10, 26, 19), calendar: Self.utc)

        #expect(local.years.map(\.yearsAgo) == [1])
        #expect(utc.isEmpty)
    }

    @Test func eraRelativeYearsAreNotTheSameYear() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(secondsFromGMT: 0)!
        // The reference is Reiwa 8. Heisei 8 has the same year number in another era.
        let heiseiEight = item("heisei-8", date: date(1996, 5, 1, 12))
        let heiseiThirty = item("heisei-30", date: date(2018, 5, 1, 12))
        let reiwaOne = item("reiwa-1", date: date(2019, 5, 1, 12))

        let memories = OnThisDayMemories(
            items: [heiseiEight, heiseiThirty, reiwaOne], reference: date(2026, 5, 1, 12), calendar: japanese)

        #expect(memories.years.map(\.yearsAgo) == [7, 8, 30])
        #expect(memories.years.map(\.items) == [[reiwaOne], [heiseiThirty], [heiseiEight]])
    }

    @Test func videosLivePhotosAndSeriesKeepTheirLibraryIdentity() {
        let video = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "video"), captureTime: date(2025, 10, 26, 9),
            mediaType: "video/quicktime", durationSeconds: 12)
        let livePhoto = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "live"), captureTime: date(2025, 10, 26, 10),
            mediaType: "image/heic", isLivePhoto: true, relatedVideoID: "live-video")
        let series = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "series"), captureTime: date(2025, 10, 26, 11),
            mediaType: "image/jpeg", burstMemberIDs: ["series", "frame"])

        let memories = OnThisDayMemories(
            items: [video, livePhoto, series], reference: date(2026, 10, 26, 12), calendar: Self.utc)

        #expect(memories.years.single.items == [video, livePhoto, series])
    }

    @Test func theDetachedBuildMatchesTheSynchronousSelection() async throws {
        let items = (0..<10_000).map { index in
            item("item-\(index)", date: date(2000 + index % 26, 10, 25 + index % 3, index % 24))
        }
        let reference = date(2026, 10, 26, 12)

        let built = try await OnThisDayMemories.build(items: items, reference: reference, calendar: Self.utc)

        #expect(built == OnThisDayMemories(items: items, reference: reference, calendar: Self.utc))
        #expect(built.years.count == 26)
    }

    @Test func aCancelledBuildThrows() async {
        let items = [item("a", date: date(2025, 10, 26))]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OnThisDayMemories.build(items: items, reference: date(2026, 10, 26), calendar: Self.utc)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func anIncompleteInventoryNeverClaimsAnEmptyDay() {
        let memories = OnThisDayMemories(
            items: [item("a", date: date(2025, 10, 26))], reference: date(2026, 10, 26), calendar: Self.utc)
        let none = OnThisDayMemories(items: [], reference: date(2026, 10, 26), calendar: Self.utc)

        #expect(OnThisDayAvailability.resolve(memories: nil, authority: .hydrating, loadFailed: false) == .loading)
        #expect(OnThisDayAvailability.resolve(memories: nil, authority: .hydrating, loadFailed: true) == .unavailable)
        #expect(OnThisDayAvailability.resolve(memories: none, authority: .hydrating, loadFailed: false) == .loading)
        #expect(OnThisDayAvailability.resolve(memories: none, authority: .cached, loadFailed: false) == .loading)
        #expect(OnThisDayAvailability.resolve(memories: none, authority: .cached, loadFailed: true) == .unavailable)
        #expect(
            OnThisDayAvailability.resolve(memories: memories, authority: .cached, loadFailed: false)
                == .partial(memories))
        #expect(
            OnThisDayAvailability.resolve(memories: memories, authority: .authoritative, loadFailed: true)
                == .partial(memories), "a failed refresh cannot prove the day complete")
        #expect(
            OnThisDayAvailability.resolve(memories: memories, authority: .authoritative, loadFailed: false)
                == .ready(memories))
        #expect(OnThisDayAvailability.resolve(memories: none, authority: .authoritative, loadFailed: false) == .empty)
    }

    @Test func theBadgeShowsUnopenedOrNewMemoriesOfACompleteDayOnly() {
        let first = item("first", date: date(2025, 10, 26))
        let second = item("second", date: date(2024, 10, 26))
        let today = OnThisDayMemories(items: [first], reference: date(2026, 10, 26), calendar: Self.utc)
        let more = OnThisDayMemories(items: [first, second], reference: date(2026, 10, 26), calendar: Self.utc)
        let tomorrow = OnThisDayMemories(
            items: [item("next", date: date(2025, 10, 27))], reference: date(2026, 10, 27), calendar: Self.utc)
        let seen = OnThisDaySeenRecord(memories: today)

        #expect(OnThisDayAvailability.ready(today).showsUnseenBadge(seen: nil))
        #expect(!OnThisDayAvailability.ready(today).showsUnseenBadge(seen: seen))
        #expect(OnThisDayAvailability.ready(more).showsUnseenBadge(seen: seen), "new memories arrived")
        #expect(OnThisDayAvailability.ready(tomorrow).showsUnseenBadge(seen: seen), "another day")
        #expect(!OnThisDayAvailability.partial(today).showsUnseenBadge(seen: nil), "nothing shows while loading")
        #expect(!OnThisDayAvailability.loading.showsUnseenBadge(seen: nil))
        #expect(!OnThisDayAvailability.empty.showsUnseenBadge(seen: nil))
    }

    @Test func theSeenRecordSurvivesARelaunchAndSignOutRemovesIt() throws {
        let suite = "OnThisDayMemoriesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memories = OnThisDayMemories(
            items: [item("a", date: date(2025, 10, 26))], reference: date(2026, 10, 26), calendar: Self.utc)
        let record = OnThisDaySeenRecord(memories: memories)

        OnThisDaySeenStore(defaults: defaults).save(record)
        #expect(OnThisDaySeenStore(defaults: defaults).load() == record)

        OnThisDaySeenStore(defaults: defaults).clear()
        #expect(OnThisDaySeenStore(defaults: defaults).load() == nil)
    }

    @Test func browsingAStackChangesNeitherTheYearNorOtherStacks() throws {
        let memories = OnThisDayMemories(
            items: [
                item("a1", date: date(2025, 10, 26, 1)), item("a2", date: date(2025, 10, 26, 2)),
                item("a3", date: date(2025, 10, 26, 3)), item("b1", date: date(2024, 10, 26, 1)),
            ],
            reference: date(2026, 10, 26, 12), calendar: Self.utc)
        let lastYear = try #require(memories.year(1))
        let twoYearsAgo = try #require(memories.year(2))
        var browser = OnThisDayBrowser()

        #expect(browser.currentItem(in: lastYear)?.uid.nodeID == "a1")
        browser.move(in: lastYear, by: -1)
        #expect(browser.currentIndex(in: lastYear) == 0, "browsing does not wrap around")
        browser.move(in: lastYear, by: 1)
        browser.move(in: lastYear, by: 1)
        browser.move(in: lastYear, by: 1)
        #expect(browser.currentItem(in: lastYear)?.uid.nodeID == "a3")
        #expect(browser.currentIndex(in: twoYearsAgo) == 0)
        #expect(browser.focusedYear == 1)

        browser.focus(twoYearsAgo)
        #expect(browser.focusedYear == 2)
        #expect(browser.currentItem(in: lastYear)?.uid.nodeID == "a3")
    }

    @Test func aLibraryChangeKeepsTheCardOnTopAndAppliesRemovals() throws {
        let a1 = item("a1", date: date(2025, 10, 26, 1))
        let a2 = item("a2", date: date(2025, 10, 26, 2))
        let a3 = item("a3", date: date(2025, 10, 26, 3))
        let b1 = item("b1", date: date(2024, 10, 26, 1))
        let reference = date(2026, 10, 26, 12)
        let before = OnThisDayMemories(items: [a1, a2, a3, b1], reference: reference, calendar: Self.utc)
        let lastYear = try #require(before.year(1))
        let twoYearsAgo = try #require(before.year(2))
        var browser = OnThisDayBrowser()
        browser.select(index: 1, in: lastYear)
        browser.focus(twoYearsAgo)

        // A new earlier photo arrives: the card on top stays a2.
        let a0 = item("a0", date: date(2025, 10, 26, 0))
        let inserted = OnThisDayMemories(items: [a0, a1, a2, a3, b1], reference: reference, calendar: Self.utc)
        browser.reconcile(with: inserted)
        let insertedYear = try #require(inserted.year(1))
        #expect(browser.currentItem(in: insertedYear) == a2)
        #expect(browser.focusedYear == 2)

        // The photo on top is deleted: the photo that took its place shows, and the year without photos loses focus.
        let removed = OnThisDayMemories(items: [a0, a1, a3], reference: reference, calendar: Self.utc)
        browser.reconcile(with: removed)
        let removedYear = try #require(removed.year(1))
        #expect(browser.currentItem(in: removedYear) == a3)
        #expect(browser.focusedYear == nil)

        // The last photo of the stack goes: the position clamps to the new end.
        let shorter = OnThisDayMemories(items: [a0], reference: reference, calendar: Self.utc)
        browser.reconcile(with: shorter)
        let shorterYear = try #require(shorter.year(1))
        #expect(browser.currentItem(in: shorterYear) == a0)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func item(_ id: String, date: Date) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "volume", nodeID: id), captureTime: date, mediaType: "image/jpeg")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Self.utc.date(from: components)!
    }
}

private extension Collection {
    var single: Element {
        precondition(count == 1)
        return first!
    }
}
