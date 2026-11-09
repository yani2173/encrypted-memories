import Foundation
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchFeature

/// Which saved rows may come back for a library that changed since they were computed.
@Suite struct SmartSearchProvisionalRowsTests {
    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: id) }

    private func row(
        _ id: String, kind: TimelineSearchSuggestionKind, matching: Set<PhotoUID>? = nil,
        representatives: [PhotoUID] = []
    ) -> TimelineSearchSuggestion {
        TimelineSearchSuggestion(
            id: id, query: id, title: id, subtitle: nil, systemImage: "photo", kind: kind,
            matchingUIDs: matching, representativeUIDs: representatives)
    }

    private func snapshot(_ rows: [TimelineSearchSuggestion]) -> SmartSearchDiscoveryModel.PersistedSnapshot {
        SmartSearchDiscoveryModel.PersistedSnapshot(
            candidates: rows, forYouIDs: rows.map(\.id), chipIDs: [], showsSmartSearchHint: false,
            visualAvailability: true, visualCompletedWhenReady: true, placeNames: ["a": "b"], placeNamesLocale: "x")
    }

    @Test func aRowThatStillDescribesTheLibraryStays() throws {
        let library: Set = [uid("1"), uid("2"), uid("3")]
        let concept = row("dog", kind: .concept, matching: [uid("1"), uid("2")], representatives: [uid("1")])
        let result = try #require(snapshot([concept]).provisional(library: library, favorites: []))
        #expect(result.candidates == [concept])
    }

    @Test func aRowThatNamesARemovedPhotoGoesAway() throws {
        let library: Set = [uid("1")]
        let representativeGone = row("a", kind: .concept, matching: [uid("1")], representatives: [uid("2")])
        let matchGone = row("b", kind: .concept, matching: [uid("1"), uid("2")], representatives: [uid("1")])
        let lexicalGone = row("c", kind: .date, representatives: [uid("2")])
        let kept = row("d", kind: .date, representatives: [uid("1")])
        let result = try #require(
            snapshot([representativeGone, matchGone, lexicalGone, kept]).provisional(library: library, favorites: []))
        #expect(result.candidates == [kept])
    }

    @Test func rowsThatDependOnTheDayOrThePlacePolicyNeverReturn() throws {
        let library: Set = [uid("1")]
        let kept = row("date", kind: .date, representatives: [uid("1")])
        let rows = [
            kept,
            row("today", kind: .onThisDay, matching: [uid("1")], representatives: [uid("1")]),
            row("place", kind: .place, matching: [uid("1")], representatives: [uid("1")]),
            row("season", kind: .placeSeason, matching: [uid("1")], representatives: [uid("1")]),
        ]
        let result = try #require(snapshot(rows).provisional(library: library, favorites: []))
        #expect(result.candidates == [kept])
    }

    @Test func aFavoritesRowNeedsEveryPhotoToBeAFavoriteStill() throws {
        let library: Set = [uid("1"), uid("2")]
        let favorites = row("fav", kind: .favorites, matching: [uid("1"), uid("2")], representatives: [uid("1")])
        #expect(snapshot([favorites]).provisional(library: library, favorites: [uid("1")]) == nil)
        let result = try #require(snapshot([favorites]).provisional(library: library, favorites: library))
        #expect(result.candidates == [favorites])
    }

    @Test func nothingRestoresWhenOnlyChipsSurvive() {
        let library: Set = [uid("1")]
        let chip = row("chip", kind: .mediaType, representatives: [uid("1")])
        let gone = row("gone", kind: .date, representatives: [uid("9")])
        let saved = SmartSearchDiscoveryModel.PersistedSnapshot(
            candidates: [chip, gone], forYouIDs: ["gone"], chipIDs: ["chip"], showsSmartSearchHint: false,
            visualAvailability: true, visualCompletedWhenReady: true, placeNames: [:], placeNamesLocale: "x")
        #expect(saved.provisional(library: library, favorites: []) == nil)
    }

    @Test func nothingRestoresWhenNoRowSurvives() {
        let gone = row("a", kind: .concept, matching: [uid("9")], representatives: [uid("9")])
        #expect(snapshot([gone]).provisional(library: [uid("1")], favorites: []) == nil)
    }
}
