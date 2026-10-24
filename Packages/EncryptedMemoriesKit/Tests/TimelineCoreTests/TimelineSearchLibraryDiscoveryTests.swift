import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineSearchLibraryDiscoveryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    // MARK: Structured result sets

    @Test func requiredUIDsNarrowAnEmptyQueryAndAndCombineWithText() {
        let a = item("a", date(2024, 5, 1), mediaType: "video/quicktime")
        let b = item("b", date(2024, 5, 2))
        let c = item("c", date(2024, 5, 3), mediaType: "video/mp4")
        let sections = [TimelineSection(id: "s", date: a.captureTime, title: "", items: [a, b, c])]

        let onlySet = TimelineSearch.filter(sections, query: "", requiredUIDs: [a.uid, b.uid])
        #expect(onlySet.flatMap(\.items).map(\.uid) == [a.uid, b.uid])

        let setAndText = TimelineSearch.filter(sections, query: "video", requiredUIDs: [a.uid, b.uid])
        #expect(setAndText.flatMap(\.items).map(\.uid) == [a.uid])

        let unfiltered = TimelineSearch.filter(sections, query: "")
        #expect(unfiltered.flatMap(\.items).count == 3)
    }

    @Test func suggestionProjectionUsesNewestFirstAndPreservesCanonicalSnapshot() {
        let older = item("older", date(2024, 5, 1))
        let newer = item("newer", date(2024, 5, 2))
        let sections = [TimelineSection(id: "s", date: older.captureTime, title: "", items: [older, newer])]
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "",
            context: TimelineSearchContext(),
            semanticMatches: nil,
            refinement: TimelineRefinement(favoritesOnly: false, mediaKinds: [.photo]),
            requiredUIDs: [older.uid, newer.uid]
        )

        let projection = TimelineSearchProjection(key: key, sections: sections)

        #expect(projection.presentationItems.map(\.uid) == [newer.uid, older.uid])
        #expect(projection.snapshot.items.map(\.uid) == [older.uid, newer.uid])
    }

    @Test func aSuggestionOwnsOnlyItsUnchangedTitle() {
        let suggestion = TimelineSearchSuggestion(
            id: "place:Klosterneuburg",
            query: "Klosterneuburg",
            title: "Klosterneuburg",
            subtitle: nil,
            systemImage: "mappin",
            kind: .place,
            matchingUIDs: [],
            representativeUIDs: []
        )

        #expect(suggestion.owns(searchText: " klosterneuburg "))
        #expect(!suggestion.owns(searchText: "Klosterneuburg Kirche"))
        #expect(!suggestion.owns(searchText: ""))
    }

    // MARK: Metadata families

    @Test func onThisDayUsesPlusMinusThreeDaysInEarlierYearsAndNeedsThreeItems() {
        let now = date(2026, 9, 21)
        let inWindow = (0..<4).map { item("y1-\($0)", date(2025, 9, 19 + $0)) }
        let outsideWindow = item("y1-out", date(2025, 9, 10))
        let tooFewTwoYearsAgo = (0..<2).map { item("y2-\($0)", date(2024, 9, 21)) }

        let discovery = context(now: now)
        let result = TimelineSearchDiscovery.onThisDayRows(
            items: sorted(inWindow + [outsideWindow] + tooFewTwoYearsAgo),
            context: discovery
        ).map { $0.suggestion(context: discovery) }

        #expect(result.map(\.id) == ["on-this-day:1"])
        #expect(result.first?.matchingUIDs == Set(inWindow.map(\.uid)))
        #expect(result.first?.representativeUIDs.count == 2)
        #expect(result.first?.kind == .onThisDay)
    }

    @Test func denseConsecutiveDaysMergeIntoOneTrip() {
        let quiet = (1...20).map { item("quiet-\($0)", date(2024, 3, $0)) }
        let dayOne = (0..<20).map { item("d1-\($0)", date(2024, 8, 3, hour: $0 % 24)) }
        let dayTwo = (0..<18).map { item("d2-\($0)", date(2024, 8, 4, hour: $0 % 24)) }

        let discovery = context(now: date(2026, 1, 1))
        let result = TimelineSearchDiscovery.tripRows(items: sorted(quiet + dayOne + dayTwo), context: discovery)
            .map { $0.suggestion(context: discovery) }

        #expect(result.count == 1)
        #expect(result.first?.matchingUIDs == Set((dayOne + dayTwo).map(\.uid)))
        #expect(result.first?.kind == .trip)
    }

    @Test func seasonsSkipTheCurrentSeasonAndCountDecemberAsNextWinter() {
        let winter =
            (0..<10).map { item("dec-\($0)", date(2024, 12, 20)) }
            + (0..<10).map { item("jan-\($0)", date(2025, 1, 10)) }
        let currentSummer = (0..<30).map { item("now-\($0)", date(2026, 7, 1)) }

        let discovery = context(now: date(2026, 7, 15))
        let result = TimelineSearchDiscovery.seasonRows(items: sorted(winter + currentSummer), context: discovery)
            .map { $0.suggestion(context: discovery) }

        #expect(result.map(\.id) == ["season:\(TimelineSearchSeason.winter.rawValue):2025"])
        #expect(result.first?.matchingUIDs == Set(winter.map(\.uid)))
        #expect(result.first?.title.hasSuffix("2024/25") == true)
    }

    @Test func mediaTypeChipsAppearOnlyWhenTheTypeDoesNotDominateTheLibrary() {
        let videos = (0..<3).map { item("v\($0)", date(2024, 1, 1 + $0), mediaType: "video/mp4") }
        let photos = (0..<7).map { item("p\($0)", date(2024, 2, 1 + $0)) }
        let mixed = [TimelineSection(id: "s", date: videos[0].captureTime, title: "", items: videos + photos)]

        let discovery = context(now: date(2026, 1, 1))
        let chips = TimelineSearchDiscovery.mediaTypeRows(items: videos + photos, sections: mixed, context: discovery)
            .map { $0.suggestion(context: discovery) }
        #expect(chips.first { $0.id == "media:\(PhotoTag.videos.rawValue)" }?.matchingUIDs == Set(videos.map(\.uid)))

        let onlyVideos = [TimelineSection(id: "s", date: videos[0].captureTime, title: "", items: videos)]
        let dominated = TimelineSearchDiscovery.mediaTypeRows(items: videos, sections: onlyVideos, context: discovery)
        #expect(!dominated.contains { $0.id == "media:\(PhotoTag.videos.rawValue)" })
    }

    @Test func rowsBuiltWithoutPreviewsGetTheSamePreviewsAsADirectBuild() {
        let now = date(2026, 9, 21)
        var items = (0..<20).map { item("y1-\($0)", date(2025, 9, 19 + $0 % 4, hour: $0)) }
        items += (0..<40).map { item("trip-\($0)", date(2024, 8, 3 + $0 / 20, hour: $0 % 20)) }
        items += (0..<12).map { item("video-\($0)", date(2023, 5, 1 + $0), mediaType: "video/mp4") }
        let sections = [TimelineSection(id: "all", date: now, title: "", items: sorted(items))]
        let favorites = Set(items.filter { $0.uid.nodeID.hasSuffix("-3") }.map(\.uid))
        let excluded = Set(items.filter { $0.uid.nodeID.hasSuffix("-5") }.map(\.uid))
        let scanned = Set(items.filter { !$0.uid.nodeID.hasSuffix("-7") }.map(\.uid))
        let gated = TimelineSearchDiscoveryContext(
            now: now, calendar: calendar, locale: Locale(identifier: "de_AT"), favoriteUIDs: favorites,
            excludedRepresentativeUIDs: excluded, allowsRepresentative: { scanned.contains($0) })
        var withoutPreviews = gated
        withoutPreviews.excludedRepresentativeUIDs = []
        withoutPreviews.allowsRepresentative = nil
        withoutPreviews.suppressesRepresentatives = true

        let rows = TimelineSearchDiscovery.libraryRows(sections: sections, context: withoutPreviews)
        let reused = TimelineSearchDiscovery.librarySuggestions(rows: rows, context: gated)
        let direct = TimelineSearchDiscovery.librarySuggestions(sections: sections, context: gated)

        #expect(!direct.forYou.isEmpty && !direct.chips.isEmpty, "fixture must produce rows and chips")
        #expect(direct.forYou.contains { !$0.representativeUIDs.isEmpty })
        #expect(reused == direct)
        #expect(
            TimelineSearchDiscovery.librarySuggestions(rows: rows, context: withoutPreviews).forYou.allSatisfy {
                $0.representativeUIDs.isEmpty
            })
    }

    // MARK: Places

    @Test func placeCandidatesMarkTheDominantCellAsHomeAndDropSparseCells() {
        let home = (0..<20).map { coordinate("h\($0)", 48.2082, 16.3738, date(2024, 1, 1 + $0 % 28)) }
        let trip = (0..<8).map { coordinate("t\($0)", 48.3064, 16.3259, date(2024, 4, 10 + $0 % 3)) }
        let sparse = (0..<2).map { coordinate("s\($0)", 41.3851, 2.1734, date(2023, 6, 1)) }
        let nullIsland = (0..<10).map { coordinate("z\($0)", 0, 0, date(2023, 6, 1)) }

        let candidates = TimelineSearchDiscovery.placeCandidates(coordinates: home + trip + sparse + nullIsland)

        #expect(candidates.count == 2)
        #expect(candidates.first?.isHome == false)
        #expect(candidates.first.map { Set($0.uids) } == Set(trip.map(\.uid)))
        #expect(candidates.last?.isHome == true)
    }

    @Test func placeSuggestionsMergeCellsWithTheSameNameAndAddTheDominantSeason() {
        let springItems = (0..<6).map { item("k\($0)", date(2024, 4, 10 + $0)) }
        let autumnItem = item("k-autumn", date(2023, 10, 1))
        let first = TimelineSearchPlaceCandidate(
            id: "a", latitude: 48.3, longitude: 16.3,
            uids: springItems.prefix(3).map(\.uid), dates: [], isHome: false)
        let second = TimelineSearchPlaceCandidate(
            id: "b", latitude: 48.31, longitude: 16.33,
            uids: springItems.suffix(3).map(\.uid) + [autumnItem.uid], dates: [], isHome: false)
        let itemsByUID = Dictionary(uniqueKeysWithValues: (springItems + [autumnItem]).map { ($0.uid, $0) })

        let result = TimelineSearchDiscovery.placeSuggestions(
            candidates: [first, second],
            names: ["a": "Klosterneuburg", "b": "Klosterneuburg"],
            itemsByUID: itemsByUID,
            context: context(now: date(2026, 9, 21))
        )

        let place = result.first { $0.kind == .place }
        let placeSeason = result.first { $0.kind == .placeSeason }
        #expect(place?.title == "Klosterneuburg")
        #expect(place?.matchingUIDs?.count == 7)
        #expect(placeSeason?.matchingUIDs == Set(springItems.map(\.uid)))
        #expect(placeSeason?.title.contains("Klosterneuburg") == true)
    }

    @Test func repeatedDefaultWithDistantGPSOnManyDaysDoesNotBecomeAPlace() {
        let coordinates = (0..<60).flatMap { offset in
            let captured = date(2024, 1, 1).addingTimeInterval(Double(offset / 2 * 7) * 86_400)
            return [
                coordinate("fixed-\(offset)", 20.123456789, 30.123456789, captured),
                coordinate("gps-\(offset)", -20 + Double(offset) * 0.0001, -30, captured),
            ]
        }
        let candidates = TimelineSearchDiscovery.placeCandidates(coordinates: coordinates)
        #expect(candidates.count == 1)
        #expect(candidates.allSatisfy { $0.uids.allSatisfy { $0.nodeID.hasPrefix("gps-") } })
    }

    // MARK: Ranking and previews

    @Test func representativesPreferAFavoriteSkipExcludedItemsAndSpreadInTime() {
        let items = (1...10).map { item("r\($0)", date(2024, 1, $0)) }
        let favorite = items[2]
        let excluded = items[9]
        let context = TimelineSearchDiscoveryContext(
            now: date(2026, 1, 1), calendar: calendar,
            favoriteUIDs: [favorite.uid], excludedRepresentativeUIDs: [excluded.uid])

        let picked = TimelineSearchDiscovery.representatives(for: items, context: context)

        #expect(picked.first == favorite.uid)
        #expect(!picked.contains(excluded.uid))
        #expect(picked.last == items[8].uid)
    }

    @Test func aFailedSensitiveGateSuppressesEveryPreview() {
        let items = (1...5).map { item("g\($0)", date(2024, 1, $0)) }
        let context = TimelineSearchDiscoveryContext(
            now: date(2026, 1, 1), calendar: calendar, suppressesRepresentatives: true)

        #expect(TimelineSearchDiscovery.representatives(for: items, context: context).isEmpty)
    }

    @Test func rankingInterleavesFamiliesCapsEachKindAndDropsDuplicateResults() {
        func suggestion(
            _ id: String, _ kind: TimelineSearchSuggestionKind, _ uids: Set<PhotoUID>
        ) -> TimelineSearchSuggestion {
            TimelineSearchSuggestion(
                id: id, query: id, title: id, subtitle: nil, systemImage: "photo",
                kind: kind, matchingUIDs: uids, representativeUIDs: [])
        }
        let shared: Set<PhotoUID> = [uid("x")]
        let concepts = [
            suggestion("c1", .concept, [uid("1")]),
            suggestion("c2", .concept, [uid("2")]),
            suggestion("c3", .concept, [uid("3")]),
        ]
        let places = [suggestion("p1", .place, shared), suggestion("p2", .placeSeason, shared)]

        let ranked = TimelineSearchDiscovery.rankForYou([concepts, places], limit: 10, perKind: 2)

        #expect(ranked.map(\.id) == ["c1", "p1", "c2"])
    }

    // MARK: Every offered suggestion works

    /// Builds a realistic multi-year library and proves, for every suggestion the metadata and place families
    /// offer, that running it returns exactly its announced result set, with at least three items, and that its
    /// previews come from that set. No family may produce a visual concept without ML.
    @Test func everyOfferedSuggestionReturnsExactlyItsAnnouncedResults() {
        let now = date(2026, 9, 21)
        var items: [PhotoItem] = []
        var coordinates: [PhotoCoordinate] = []
        for year in 2019...2026 {
            for month in 1...12 {
                for day in stride(from: 1, through: 28, by: 3) {
                    let id = "\(year)-\(month)-\(day)"
                    let captured = date(year, month, day)
                    guard captured < now else { continue }
                    let mediaType =
                        day % 10 == 1 ? "video/mp4" : (day % 13 == 0 ? "image/png" : "image/jpeg")
                    items.append(item(id, captured, mediaType: mediaType))
                    // Home near Vienna, plus spring visits near Klosterneuburg.
                    let isTrip = (3...5).contains(month) && day % 2 == 0
                    coordinates.append(
                        coordinate(id, isTrip ? 48.3064 : 48.2082, isTrip ? 16.3259 : 16.3738, captured))
                }
            }
        }
        // A dense trip, and the same days one and three years before `now`.
        items += (0..<60).map { item("trip-\($0)", date(2023, 8, 3 + $0 / 20, hour: $0 % 20)) }
        items += (0..<5).map { item("y1-\($0)", date(2025, 9, 20, hour: 8 + $0)) }
        items += (0..<4).map { item("y3-\($0)", date(2023, 9, 22, hour: 8 + $0)) }
        let favorites = Set(items.filter { $0.uid.nodeID.hasSuffix("-7") }.map(\.uid))
        let sections = [TimelineSection(id: "all", date: now, title: "", items: items)]
        let context = TimelineSearchDiscoveryContext(
            now: now, calendar: calendar, locale: Locale(identifier: "de_AT"), favoriteUIDs: favorites)

        let metadata = TimelineSearchDiscovery.librarySuggestions(sections: sections, context: context)
        let candidates = TimelineSearchDiscovery.placeCandidates(coordinates: coordinates)
        let names = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.id, $0.isHome ? "Wien" : "Klosterneuburg") })
        let places = TimelineSearchDiscovery.placeSuggestions(
            candidates: candidates,
            names: names,
            itemsByUID: Dictionary(uniqueKeysWithValues: items.map { ($0.uid, $0) }),
            context: context
        )
        let offered = metadata.forYou + metadata.chips + places

        let kinds = Set(offered.map(\.kind))
        for expected: TimelineSearchSuggestionKind in [.onThisDay, .trip, .season, .favorites, .mediaType, .place] {
            #expect(kinds.contains(expected), "fixture must exercise \(expected)")
        }
        #expect(!kinds.contains(.concept))
        for suggestion in offered {
            let announced = suggestion.matchingUIDs ?? []
            let results = TimelineSearch.filter(
                sections, query: "", context: TimelineSearchContext(favoriteUIDs: favorites),
                requiredUIDs: announced
            ).flatMap(\.items).map(\.uid)
            #expect(announced.count >= 3, "\(suggestion.id) offers fewer than three results")
            #expect(Set(results) == announced, "\(suggestion.id) does not return its announced results")
            #expect(results.count == announced.count, "\(suggestion.id) returns duplicates")
            #expect(
                Set(suggestion.representativeUIDs).isSubset(of: announced),
                "\(suggestion.id) shows a preview outside its results")
        }

        // The announced sets are also correct: each is compared with a set derived from the fixture alone.
        func announced(_ id: String) -> Set<PhotoUID>? {
            offered.first { $0.id == id }?.matchingUIDs
        }
        func localDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        #expect(announced("media:\(PhotoTag.favorites.rawValue)") == favorites)
        #expect(
            announced("media:\(PhotoTag.videos.rawValue)")
                == Set(items.filter { $0.mediaType.hasPrefix("video/") }.map(\.uid)))

        let anniversary = localDay(date(2025, 9, 21))
        let aroundAnniversary = items.filter {
            let distance = calendar.dateComponents([.day], from: anniversary, to: localDay($0.captureTime)).day
            return abs(distance ?? .max) <= 3
        }
        #expect(aroundAnniversary.contains { $0.uid == uid("y1-0") })
        #expect(announced("on-this-day:1") == Set(aroundAnniversary.map(\.uid)))

        let tripDays = Set([3, 4, 5].map { localDay(date(2023, 8, $0)) })
        let onTripDays = items.filter { tripDays.contains(localDay($0.captureTime)) }
        #expect(Set(onTripDays.map(\.uid)).isSuperset(of: (0..<60).map { uid("trip-\($0)") }))
        #expect(onTripDays.count > 60, "fixture must include base items on the trip days")
        let trips = offered.filter { $0.kind == .trip }
        #expect(trips.count == 1)
        #expect(trips.first?.matchingUIDs == Set(onTripDays.map(\.uid)))
    }

    // MARK: Fixtures

    private func context(now: Date) -> TimelineSearchDiscoveryContext {
        TimelineSearchDiscoveryContext(now: now, calendar: calendar, locale: Locale(identifier: "de_AT"))
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: id) }

    private func item(_ id: String, _ date: Date, mediaType: String = "image/jpeg") -> PhotoItem {
        PhotoItem(uid: uid(id), captureTime: date, mediaType: mediaType)
    }

    private func coordinate(_ id: String, _ latitude: Double, _ longitude: Double, _ date: Date) -> PhotoCoordinate {
        PhotoCoordinate(uid: uid(id), latitude: latitude, longitude: longitude, date: date)
    }

    private func sorted(_ items: [PhotoItem]) -> [PhotoItem] {
        items.sorted { $0.captureTime < $1.captureTime }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
