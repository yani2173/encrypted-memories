import Foundation
import MLSearchCore
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchFeature

/// A suggestion is offered only when it can work: visual concepts need Smart Search and visual search, and
/// no suggestion from other library content is ever shown.
@Suite struct SmartSearchDiscoveryAvailabilityTests {
    private let concept = suggestion(kind: .concept)
    private let anniversary = suggestion(kind: .onThisDay)
    private let place = suggestion(kind: .place)

    @Test func visualConceptsNeedSmartSearchAndVisualSearch() {
        let cases: [(MLSmartSearchSnapshot?, Bool)] = [
            (nil, false),
            (snapshot(enabled: false, visual: false), false),
            (snapshot(enabled: false, visual: true), false),
            (snapshot(enabled: true, visual: false), false),
            (snapshot(enabled: true, visual: true), true),
        ]
        for (state, expected) in cases {
            #expect(SmartSearchDiscoveryModel.visualConceptsAvailable(state) == expected)
            #expect(
                SmartSearchDiscoveryModel.isDisplayable(
                    concept, computedContent: Self.content(7), content: Self.content(7), snapshot: state)
                    == expected)
        }
    }

    @Test func metadataAndPlaceSuggestionsWorkWithoutAnyMachineLearning() {
        for state in [nil, snapshot(enabled: false, visual: false), snapshot(enabled: true, visual: false)] {
            for item in [anniversary, place] {
                #expect(
                    SmartSearchDiscoveryModel.isDisplayable(
                        item, computedContent: Self.content(7), content: Self.content(7), snapshot: state))
            }
        }
    }

    @Test func suggestionsFromOtherLibraryContentAreNeverShown() {
        let enabled = snapshot(enabled: true, visual: true)
        let otherFavorites = SmartSearchContentIdentity(
            timelineRevision: 7, favoriteUIDs: [PhotoUID(volumeID: "v", nodeID: "favorite")])
        for item in [concept, anniversary, place] {
            #expect(
                !SmartSearchDiscoveryModel.isDisplayable(
                    item, computedContent: Self.content(6), content: Self.content(7), snapshot: enabled))
            #expect(
                !SmartSearchDiscoveryModel.isDisplayable(
                    item, computedContent: nil, content: Self.content(7), snapshot: enabled))
            #expect(
                !SmartSearchDiscoveryModel.isDisplayable(
                    item, computedContent: otherFavorites, content: Self.content(7), snapshot: enabled))
        }
    }

    @Test func aSuggestionWithoutAResolvedResultSetIsNeverShown() {
        let unresolved = TimelineSearchSuggestion(id: "date:2024-01-01", query: "2024-01-01", title: "1 Jan 2024")
        let empty = TimelineSearchSuggestion(
            id: "empty", query: "Empty", title: "Empty", subtitle: nil, systemImage: "photo",
            kind: .trip, matchingUIDs: [], representativeUIDs: [])
        for item in [unresolved, empty] {
            #expect(
                !SmartSearchDiscoveryModel.isDisplayable(
                    item, computedContent: Self.content(1), content: Self.content(1), snapshot: nil))
        }
    }

    @MainActor @Test func anEmptyModelOffersNothing() {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        #expect(model.textSuggestions(content: Self.content(0), snapshot: nil).isEmpty)
        #expect(!model.isCurrent(content: Self.content(0)))
        #expect(!model.isSettled(content: Self.content(0)))
    }

    // MARK: Host decisions

    /// The decision a host takes for a search text. A typed title is never erased: it waits for the refresh
    /// while the suggestions are stale, and runs as text once a current refresh has no suggestion for it.
    @Test func commitDecisionTable() {
        let title = place.query
        let unresolved = TimelineSearchSuggestion(id: "date:2024-01-01", query: "2024-01-01", title: "1 Jan 2024")
        let cases: [(String, [TimelineSearchSuggestion], [TimelineSearchSuggestion], Bool, String)] = [
            (title, [place], [place], true, "structured"),
            ("  \(title.uppercased()) ", [place], [place], true, "structured"),
            // Displayable wins even when the caller does not report a settled refresh.
            (title, [place], [place], false, "structured"),
            // A typed or clicked title at a stale revision is deferred, not erased and not run as text.
            (title, [], [place], false, "defer"),
            // After a current refresh without that suggestion it is legitimately typed text.
            (title, [], [], true, "text"),
            (title, [], [place], true, "text"),
            // Text that no suggestion owns is always ordinary text.
            ("\(title) and more", [place], [place], false, "text"),
            ("", [place], [place], false, "text"),
            // A published row without a resolved result set never defers.
            ("2024-01-01", [], [unresolved], false, "text"),
        ]
        for (text, displayable, published, isCurrent, expected) in cases {
            let decision = SmartSearchDiscoveryModel.commitDecision(
                for: text, displayable: displayable, published: published, isCurrent: isCurrent, scope: .all)
            let label: String
            switch decision {
            case .structured(let suggestion):
                label = "structured"
                #expect(suggestion.id == place.id)
            case .deferUntilRefresh: label = "defer"
            case .text: label = "text"
            }
            #expect(label == expected, "\(text) displayable=\(displayable.count) current=\(isCurrent)")
        }
    }

    /// A suggestion's result set answers the broad Smart Search scope. A narrower scope, such as OCR, searches the
    /// text that the field shows, so switching the scope after choosing a suggestion changes the results.
    @Test func aNarrowerScopeSearchesTheSuggestionTitleAsText() {
        for scope in MLSearchScope.allCases where scope != .all {
            for (displayable, isCurrent) in [([place], true), ([place], false), ([], false)] {
                let decision = SmartSearchDiscoveryModel.commitDecision(
                    for: place.query, displayable: displayable, published: [place], isCurrent: isCurrent,
                    scope: scope)
                #expect(decision == .text, "\(scope) displayable=\(displayable.count) current=\(isCurrent)")
            }
        }
        #expect(
            SmartSearchDiscoveryModel.commitDecision(
                for: place.query, displayable: [place], published: [place], isCurrent: true, scope: .all)
                == .structured(place))
    }

    @Test func rebindTable() {
        let freshPlace = TimelineSearchSuggestion(
            id: place.id, query: place.query, title: place.title, subtitle: nil, systemImage: "photo",
            kind: .place, matchingUIDs: [PhotoUID(volumeID: "v", nodeID: "new")], representativeUIDs: [])

        // A fresh version with the same identifier replaces the selected one, with the new result set.
        #expect(
            SmartSearchDiscoveryModel.rebind(
                place, displayable: [anniversary, freshPlace], isCurrent: true, visualAvailable: false)
                == .keep(freshPlace))
        #expect(
            SmartSearchDiscoveryModel.rebind(
                place, displayable: [freshPlace], isCurrent: false, visualAvailable: false) == .keep(freshPlace))
        // Not current yet: the selected suggestion stays until the refresh finishes.
        #expect(
            SmartSearchDiscoveryModel.rebind(place, displayable: [], isCurrent: false, visualAvailable: true)
                == .pending)
        // A current refresh no longer contains it.
        #expect(
            SmartSearchDiscoveryModel.rebind(
                place, displayable: [anniversary], isCurrent: true, visualAvailable: true) == .drop)
        // A visual concept cannot work while visual search is unavailable, whatever is published.
        #expect(
            SmartSearchDiscoveryModel.rebind(concept, displayable: [concept], isCurrent: true, visualAvailable: false)
                == .drop)
        #expect(
            SmartSearchDiscoveryModel.rebind(concept, displayable: [], isCurrent: false, visualAvailable: false)
                == .drop)
        #expect(
            SmartSearchDiscoveryModel.rebind(concept, displayable: [concept], isCurrent: true, visualAvailable: true)
                == .keep(concept))
        #expect(
            SmartSearchDiscoveryModel.rebind(concept, displayable: [], isCurrent: false, visualAvailable: true)
                == .pending)
    }

    // MARK: Stateful refresh

    @MainActor @Test func suggestionsAreOfferedOnlyForTheContentTheyWereComputedFrom() async throws {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        let one = await refresh(model, revision: 1)
        #expect(model.isCurrent(content: one))
        #expect(model.isSettled(content: one))
        let first = try #require(model.forYou(content: one, snapshot: nil).first)
        #expect(!model.chips(content: one, snapshot: nil).isEmpty)
        #expect(model.commitDecision(for: first.query, content: one, snapshot: nil, scope: .all) == .structured(first))
        #expect(model.commitDecision(for: first.query, content: one, snapshot: nil, scope: .text) == .text)

        // The library changed and no refresh ran yet: nothing computed for revision 1 may be offered, and the
        // title waits for the refresh instead of running as text.
        let two = Self.content(2, favorites: Self.favorites())
        #expect(!model.isCurrent(content: two))
        #expect(!model.isSettled(content: two))
        #expect(model.forYou(content: two, snapshot: nil).isEmpty)
        #expect(model.chips(content: two, snapshot: nil).isEmpty)
        #expect(model.textSuggestions(content: two, snapshot: nil).isEmpty)
        #expect(model.commitDecision(for: first.query, content: two, snapshot: nil, scope: .all) == .deferUntilRefresh)
        #expect(model.commitDecision(for: "typed text", content: two, snapshot: nil, scope: .all) == .text)
        #expect(model.rebind(first, content: two, snapshot: nil) == .pending)

        let generation = model.settledGeneration
        let refreshed = await refresh(model, revision: 2)
        #expect(refreshed == two)
        #expect(model.settledGeneration > generation)
        #expect(model.isSettled(content: two))
        #expect(!model.isSettled(content: one))
        #expect(!model.forYou(content: two, snapshot: nil).isEmpty)
        #expect(model.forYou(content: one, snapshot: nil).isEmpty)
        guard case .keep(let fresh) = model.rebind(first, content: two, snapshot: nil) else {
            Issue.record("the suggestion must rebind to its current version")
            return
        }
        #expect(fresh.id == first.id)
        #expect(model.commitDecision(for: first.query, content: two, snapshot: nil, scope: .all) == .structured(fresh))
    }

    @MainActor @Test func aSuggestionThatNoLongerExistsIsDroppedAndItsTitleBecomesText() async throws {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        let one = await refresh(model, revision: 1)
        let favoritesRow = try #require(
            model.displayableSuggestions(content: one, snapshot: nil).first { $0.matchingUIDs == Self.favorites() })

        // No favorites remain, so the settled refresh has no favorites row.
        let two = await refresh(model, revision: 2, favorites: [])
        #expect(model.isSettled(content: two))
        #expect(model.rebind(favoritesRow, content: two, snapshot: nil) == .drop)
        #expect(model.commitDecision(for: favoritesRow.query, content: two, snapshot: nil, scope: .all) == .text)
    }

    @MainActor @Test func aFavoritesChangeInvalidatesThePublishedSuggestions() async throws {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        let before = await refresh(model, revision: 1)
        let favoritesRow = try #require(
            model.displayableSuggestions(content: before, snapshot: nil).first {
                $0.matchingUIDs == Self.favorites()
            })

        // Same revision and the same number of favorites, but another favorite set.
        let changed = Set(Self.items()[1..<9].map(\.uid))
        let after = Self.content(1, favorites: changed)
        #expect(after != before)
        #expect(!model.isCurrent(content: after))
        #expect(model.textSuggestions(content: after, snapshot: nil).isEmpty)
        #expect(model.rebind(favoritesRow, content: after, snapshot: nil) == .pending)

        _ = await refresh(model, revision: 1, favorites: changed)
        #expect(model.isSettled(content: after))
        #expect(model.textSuggestions(content: before, snapshot: nil).isEmpty)
        guard case .keep(let fresh) = model.rebind(favoritesRow, content: after, snapshot: nil) else {
            Issue.record("the favorites row must rebind to its current version")
            return
        }
        #expect(fresh.matchingUIDs == changed)
    }

    @MainActor @Test func aRefreshWithoutVisualConceptsStillSettles() async {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        let one = await refresh(model, revision: 1, includeVisualConcepts: false)
        #expect(model.isSettled(content: one))
        #expect(!model.textSuggestions(content: one, snapshot: nil).isEmpty)
    }

    /// A refresh clears the published rows when it starts. The last published titles survive that, so a title
    /// clicked in this window still waits for the refresh instead of running as text.
    @MainActor @Test func thePublishedTitlesSurviveTheStartOfARefresh() async throws {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        let one = await refresh(model, revision: 1)
        let first = try #require(model.forYou(content: one, snapshot: nil).first)

        // A cancelled refresh clears the rows for the new revision and stops before its first publish.
        let two = Self.content(2, favorites: Self.favorites())
        let interrupted = Task { @MainActor in _ = await refresh(model, revision: 2) }
        interrupted.cancel()
        await interrupted.value
        #expect(model.forYou.isEmpty)
        #expect(model.chips.isEmpty)
        #expect(!model.isCurrent(content: two))
        #expect(model.publishedKind(owning: first.query) == first.kind)
        #expect(model.commitDecision(for: first.query, content: two, snapshot: nil, scope: .all) == .deferUntilRefresh)
        #expect(model.commitDecision(for: "typed text", content: two, snapshot: nil, scope: .all) == .text)

        await refresh(model, revision: 2)
        guard
            case .structured(let fresh) = model.commitDecision(
                for: first.query, content: two, snapshot: nil, scope: .all)
        else {
            Issue.record("the title must resolve to its current suggestion")
            return
        }
        #expect(fresh.id == first.id)
    }

    /// Places are published after the metadata rows. At a new revision the metadata publish has no places yet,
    /// so the title of an earlier place waits for the settle instead of running as text.
    @MainActor @Test func aPlaceTitleWaitsForTheSettleAfterARevisionChange() async {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        // The name of the northern cluster suspends until the test releases it.
        let model = SmartSearchDiscoveryModel { latitude, _ in
            guard latitude > 48.25 else { return "Vienna" }
            enteredContinuation.yield()
            for await _ in release { break }
            return "Klosterneuburg"
        }
        let home = Self.items()[0..<12].map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.2082, longitude: 16.3738, date: $0.captureTime)
        }
        let north = Self.items()[12..<20].map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.3064, longitude: 16.3259, date: $0.captureTime)
        }

        let one = await refresh(model, revision: 1, coordinates: home)
        guard
            case .structured(let first) = model.commitDecision(for: "Vienna", content: one, snapshot: nil, scope: .all)
        else {
            Issue.record("the first refresh must publish the place")
            return
        }
        #expect(first.kind == .place)

        let two = Self.content(2, favorites: Self.favorites())
        let second = Task { @MainActor in _ = await refresh(model, revision: 2, coordinates: home + north) }
        for await _ in entered { break }
        // The metadata rows are published, the place stage is suspended in the resolver.
        #expect(model.isCurrent(content: two))
        #expect(!model.isSettled(content: two))
        #expect(model.publishedKind(owning: "Vienna") == .place)
        #expect(model.commitDecision(for: "Vienna", content: two, snapshot: nil, scope: .all) == .deferUntilRefresh)

        releaseContinuation.yield()
        await second.value
        #expect(model.isSettled(content: two))
        guard
            case .structured(let fresh) = model.commitDecision(for: "Vienna", content: two, snapshot: nil, scope: .all)
        else {
            Issue.record("the title must resolve to the current place")
            return
        }
        #expect(fresh.id == first.id)
        #expect(model.commitDecision(for: "Klosterneuburg", content: two, snapshot: nil, scope: .all) != .text)
    }

    @MainActor @Test func aSupersededRefreshCannotPublishOverTheCurrentLibrary() async {
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let model = SmartSearchDiscoveryModel { _, _ in
            didEnter.yield()
            for await _ in release { break }
            return "Old place"
        }
        let coordinates = Self.items().prefix(12).map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.2082, longitude: 16.3738, date: $0.captureTime)
        }
        let old = Task { @MainActor in
            await refresh(model, revision: 1, coordinates: coordinates)
        }
        for await _ in entered { break }
        let current = await refresh(model, revision: 2, favorites: [], itemCount: 24)
        let generation = model.settledGeneration
        let rows = model.forYou

        doRelease.yield()
        await old.value

        #expect(model.computedContent == current)
        #expect(model.settledContent == current)
        #expect(model.settledGeneration == generation)
        #expect(model.forYou == rows)
    }

    @MainActor @Test func failedVisualQueriesRemainRetryableAfterMetadataSettles() async {
        struct QueryFailure: Error {}
        let model = SmartSearchDiscoveryModel(refreshPolicy: .background) { _, _ in nil }
        let ready = snapshot(enabled: true, visual: true, indexing: .ready(progress()))
        await model.refresh(
            sections: [TimelineSection(id: "all", date: Self.start, title: "", items: Self.items())],
            timelineRevision: 1, favoriteUIDs: Self.favorites(), coordinates: [],
            snapshot: ready, indexedAssetCount: { 20 }, search: { _, _ in throw QueryFailure() }
        )
        #expect(model.hasComputed)
        #expect(!model.lastRefreshCompleted)
        #expect(!model.showsVisualSuggestionsPendingNote(ready))
        #expect(model.forYou.allSatisfy { $0.representativeUIDs.isEmpty })

        await model.refresh(
            sections: [TimelineSection(id: "all", date: Self.start, title: "", items: Self.items())],
            timelineRevision: 1, favoriteUIDs: Self.favorites(), coordinates: [],
            snapshot: ready, indexedAssetCount: { 20 }, search: { _, _ in [] }
        )
        #expect(model.lastRefreshCompleted)
        #expect(!model.showsVisualSuggestionsPendingNote(ready))
    }

    /// `forYou` keeps at most three rows of one kind. A valid suggestion that is ranked out of the rows is still
    /// resolved: its title commits it, and a selected one is kept after a refresh at the same content.
    @MainActor @Test func aSuggestionRankedOutOfTheRowsIsStillResolved() async throws {
        let cities: [(name: String, latitude: Double, longitude: Double)] = [
            ("Vienna", 48.2082, 16.3738), ("Graz", 47.0707, 15.4395),
            ("Salzburg", 47.8095, 13.0550), ("Innsbruck", 47.2692, 11.4041),
        ]
        let model = SmartSearchDiscoveryModel { latitude, _ in
            cities.min { abs($0.latitude - latitude) < abs($1.latitude - latitude) }?.name
        }
        // Six items for each city, all on one day, so each city is one place row without a season row.
        let items = Self.items(count: 24)
        let coordinates = items.enumerated().map { index, item in
            let city = cities[index / 6]
            return PhotoCoordinate(
                uid: item.uid, latitude: city.latitude, longitude: city.longitude, date: item.captureTime)
        }

        let one = await refresh(model, revision: 1, coordinates: coordinates, itemCount: 24)
        let rankedPlaces = model.forYou(content: one, snapshot: nil).filter { $0.kind == .place }
        #expect(rankedPlaces.count == 3)
        let rankedOut = try #require(
            cities.map(\.name).first { name in !rankedPlaces.contains { $0.query == name } })
        guard
            case .structured(let selected) = model.commitDecision(
                for: rankedOut, content: one, snapshot: nil, scope: .all)
        else {
            Issue.record("the title of a suggestion that is ranked out of the rows must commit it")
            return
        }
        #expect(selected.kind == .place)
        #expect(!model.displayableSuggestions(content: one, snapshot: nil).contains { $0.id == selected.id })
        #expect(model.resolvableSuggestions(content: Self.content(2), snapshot: nil).isEmpty)

        await refresh(model, revision: 1, coordinates: coordinates, itemCount: 24)
        #expect(model.isSettled(content: one))
        guard case .keep(let fresh) = model.rebind(selected, content: one, snapshot: nil) else {
            Issue.record("a valid suggestion that is ranked out of the rows must not be dropped")
            return
        }
        #expect(fresh.id == selected.id)
        #expect(fresh.matchingUIDs == selected.matchingUIDs)
    }

    /// A settle drops the earlier places that no current row replaces. It drops the earlier visual concepts
    /// only when it ran the visual stages or visual search is unavailable.
    @Test func mergedPublishedTable() {
        let freshPlace = TimelineSearchSuggestion(
            id: place.id, query: place.query, title: place.title, subtitle: nil, systemImage: "photo",
            kind: .place, matchingUIDs: [PhotoUID(volumeID: "v", nodeID: "new")], representativeUIDs: [])
        let previous = [anniversary, place, concept]
        func merged(_ rows: [TimelineSearchSuggestion], places: Bool, concepts: Bool) -> [TimelineSearchSuggestion] {
            SmartSearchDiscoveryModel.mergedPublished(
                rows: rows, previous: previous, keepsPlaces: places, keepsConcepts: concepts)
        }
        #expect(merged([], places: true, concepts: true) == [place, concept])
        #expect(merged([anniversary], places: true, concepts: false) == [anniversary, place])
        #expect(merged([anniversary], places: false, concepts: true) == [anniversary, concept])
        #expect(merged([], places: false, concepts: false).isEmpty)
        // A current row replaces the earlier entry with its title.
        #expect(merged([freshPlace], places: true, concepts: false) == [freshPlace])
    }

    /// A settle that skipped the visual stages says nothing about visual concepts, so a concept title is not
    /// current after it. Metadata rows are final with the first publish, places after every stage.
    @Test func isDecisiveTable() {
        let cases: [(TimelineSearchSuggestionKind, Bool, Bool, Bool, Bool)] = [
            (.favorites, true, false, false, true),
            (.favorites, false, false, false, false),
            (.place, true, false, false, false),
            (.place, true, true, false, true),
            (.placeSeason, true, false, false, false),
            (.concept, true, true, false, false),
            (.concept, true, false, true, false),
            (.concept, true, true, true, true),
        ]
        for (kind, isCurrent, isSettled, withVisual, expected) in cases {
            #expect(
                SmartSearchDiscoveryModel.isDecisive(
                    for: kind, isCurrent: isCurrent, isSettled: isSettled, settledWithVisualConcepts: withVisual)
                    == expected, "\(kind) current=\(isCurrent) settled=\(isSettled) visual=\(withVisual)")
        }
    }

    @MainActor @Test func aConceptIsNotCurrentAfterASettleThatSkippedTheVisualStages() async {
        let model = SmartSearchDiscoveryModel { _, _ in nil }
        let one = await refresh(model, revision: 1, includeVisualConcepts: false)
        #expect(model.isSettled(content: one))
        #expect(model.isDecisive(for: .favorites, content: one))
        #expect(model.isDecisive(for: .place, content: one))
        #expect(!model.isDecisive(for: .concept, content: one))
        #expect(model.rebind(concept, content: one, snapshot: snapshot(enabled: true, visual: true)) == .pending)
        #expect(model.rebind(place, content: one, snapshot: nil) == .drop)

        await refresh(model, revision: 1)
        #expect(model.isDecisive(for: .concept, content: one))
        #expect(model.rebind(concept, content: one, snapshot: snapshot(enabled: true, visual: true)) == .drop)
    }

    // MARK: Fixtures

    @MainActor @discardableResult private func refresh(
        _ model: SmartSearchDiscoveryModel,
        revision: UInt64,
        favorites: Set<PhotoUID> = Self.favorites(),
        coordinates: [PhotoCoordinate] = [],
        includeVisualConcepts: Bool = true,
        itemCount: Int = 20
    ) async -> SmartSearchContentIdentity {
        await model.refresh(
            sections: [
                TimelineSection(id: "all", date: Self.start, title: "", items: Self.items(count: itemCount))
            ],
            timelineRevision: revision,
            favoriteUIDs: favorites,
            coordinates: coordinates,
            smartSearch: nil,
            includeVisualConcepts: includeVisualConcepts
        )
        return Self.content(revision, favorites: favorites)
    }

    private static let start: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 1))
            ?? Date(timeIntervalSince1970: 1_718_413_200)
    }()

    private static func items(count: Int = 20) -> [PhotoItem] {
        (0..<count).map { index in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "item-\(index)"),
                captureTime: start.addingTimeInterval(Double(index) * 600),
                mediaType: index % 4 == 0 ? "video/mp4" : "image/jpeg")
        }
    }

    private static func favorites() -> Set<PhotoUID> {
        Set(items().prefix(8).map(\.uid))
    }

    private static func content(_ revision: UInt64, favorites: Set<PhotoUID> = []) -> SmartSearchContentIdentity {
        SmartSearchContentIdentity(timelineRevision: revision, favoriteUIDs: favorites)
    }

    private static func suggestion(kind: TimelineSearchSuggestionKind) -> TimelineSearchSuggestion {
        TimelineSearchSuggestion(
            id: "\(kind)", query: "\(kind)", title: "\(kind)", subtitle: nil, systemImage: "photo",
            kind: kind, matchingUIDs: [PhotoUID(volumeID: "v", nodeID: "\(kind)")], representativeUIDs: [])
    }

    private func progress() -> MLSmartSearchAggregateProgress {
        MLSmartSearchAggregateProgress(totalWorkUnits: 10, settledWorkUnits: 10, permanentlyUnavailableAssets: 0)
    }

    private func snapshot(
        enabled: Bool, visual: Bool, indexing: MLSmartSearchIndexingState
    ) -> MLSmartSearchSnapshot {
        let phase: MLSmartSearchPhase
        switch indexing {
        case .ready(let progress):
            phase = .ready(
                .init(total: progress.totalWorkUnits, indexed: progress.settledWorkUnits, permanentlyUnindexable: 0))
        default: phase = .disabled
        }
        return MLSmartSearchSnapshot(
            isEnabled: enabled,
            selectedModelID: visual ? MLModelID("visual-model") : nil,
            phase: phase,
            installedModelBytes: 0,
            availableModels: [],
            isSearchAvailable: enabled,
            indexingState: indexing
        )
    }

    private func snapshot(enabled: Bool, visual: Bool) -> MLSmartSearchSnapshot {
        MLSmartSearchSnapshot(
            isEnabled: enabled,
            selectedModelID: visual ? MLModelID("visual-model") : nil,
            phase: .disabled,
            installedModelBytes: 0,
            availableModels: [],
            isSearchAvailable: enabled
        )
    }
}
