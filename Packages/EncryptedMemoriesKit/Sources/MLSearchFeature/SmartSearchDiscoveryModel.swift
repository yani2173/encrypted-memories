import Foundation
import MLSearchCore
import Observation
import PhotosCore
import TimelineCore

/// Identity of the library content a suggestion result set depends on: the timeline revision and the favorite
/// set. Coordinates only name places, so they are not part of it.
public struct SmartSearchContentIdentity: Hashable, Sendable {
    public let timelineRevision: UInt64
    public let favoriteCount: Int
    public let favoritesHash: Int

    public init(timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>) {
        self.timelineRevision = timelineRevision
        favoriteCount = favoriteUIDs.count
        favoritesHash = favoriteUIDs.hashValue
    }
}

/// Metadata rows of the latest content. One scheduler shares it with every model it creates, so the second pass
/// of a refresh and a refresh after an interruption reuse the rows instead of reading every photo again.
@MainActor
final class SmartSearchLibraryRowsCache {
    struct Key: Equatable {
        let content: SmartSearchContentIdentity
        let day: Date
        let calendar: Calendar
        let locale: Locale

        init(content: SmartSearchContentIdentity, context: TimelineSearchDiscoveryContext) {
            self.content = content
            day = context.calendar.startOfDay(for: context.now)
            calendar = context.calendar
            locale = context.locale
        }
    }

    private var entry: (key: Key, rows: TimelineSearchLibraryRows)?
    #if DEBUG
        private(set) var buildCount = 0
    #endif

    func rows(for key: Key) -> TimelineSearchLibraryRows? {
        entry?.key == key ? entry?.rows : nil
    }

    func store(_ rows: TimelineSearchLibraryRows, for key: Key) {
        entry = (key, rows)
        #if DEBUG
            buildCount += 1
        #endif
    }

    func removeAll() {
        entry = nil
    }
}

/// What a host does with a search text that may be the title of a structured suggestion.
public enum SmartSearchSuggestionCommitDecision: Equatable {
    /// A displayable suggestion owns the text: commit its exact result set.
    case structured(TimelineSearchSuggestion)
    /// A published suggestion owns the text but the suggestions are not current: keep the text and decide again
    /// after the refresh.
    case deferUntilRefresh
    /// No suggestion owns the text: it is ordinary typed text.
    case text
}

/// What a host does with a structured suggestion that was selected earlier.
public enum SmartSearchSuggestionRebindResult: Equatable {
    /// The current version of the suggestion, with its current result set.
    case keep(TimelineSearchSuggestion)
    /// The suggestions are not current yet: keep the selected one until the refresh finishes.
    case pending
    /// The suggestion can no longer work: leave the structured search.
    case drop
}

/// Library-aware search suggestions shared by the iOS search landing and the macOS search menu.
///
/// Stages run off the main actor and check cancellation:
/// 1. The sensitive gate, when visual search can answer. It fails closed: if it cannot complete, no suggestion
///    carries a preview and no visual concept is offered.
/// 2. Metadata families (dates, trips, seasons, favorites, media types), published immediately.
/// 3. Curated visual concepts, published before network-backed place names.
/// 4. Places from the existing location index, named by the host-provided resolver.
/// Gate and concept evidence are cached per library revision and model, so a cancelled refresh (for example
/// when the user starts typing) resumes cheaply.
@MainActor
@Observable
public final class SmartSearchDiscoveryModel {
    public typealias PlaceNameResolver = @Sendable (_ latitude: Double, _ longitude: Double) async -> String?

    /// How published rows behave while a replacement refresh runs.
    public enum RefreshPolicy: Sendable {
        /// Every library, favorites or availability change recomputes them. Published sets always match the
        /// current content.
        case continuous
        /// Refresh while idle, preserving the last published rows until replacement metadata is ready.
        case background
    }

    /// Raw published rows. Hosts display `forYou(content:snapshot:)` and `chips(content:snapshot:)`, which
    /// re-check availability against the current state at render time.
    public private(set) var forYou: [TimelineSearchSuggestion] = []
    public private(set) var chips: [TimelineSearchSuggestion] = []
    public private(set) var hasComputed = false
    /// Library content the published suggestions were computed from.
    public private(set) var computedContent: SmartSearchContentIdentity?
    /// Library content of the last refresh that ran every stage to its end. Rows are published stage by stage,
    /// so only a settled refresh proves that a suggestion no longer exists.
    public private(set) var settledContent: SmartSearchContentIdentity?
    /// The settled content that an invalidation withdrew. Only a metadata-only pass restores it.
    @ObservationIgnored private var settledBeforeInvalidation: SmartSearchContentIdentity?
    /// Increases each time a refresh settles. Hosts re-check a selected suggestion when it changes.
    public private(set) var settledGeneration = 0
    /// Visual search availability the settled refresh ran with; nil when it skipped the visual stages.
    @ObservationIgnored private var settledVisualAvailability: Bool?
    /// Resolved suggestions of the last publish. Never displayed and never run: only their titles and kinds
    /// are read, to recognize a suggestion title while a refresh has cleared the published rows. Earlier places
    /// and visual concepts stay in it until a settle proves that they are gone.
    @ObservationIgnored private var lastPublished: [TimelineSearchSuggestion] = []
    /// Every resolved suggestion of the last publish: the ranked rows first, then the ones that the row limits
    /// of `forYou` left out. Never displayed; a selected or typed suggestion is resolved against it, so a valid
    /// suggestion that is ranked out of the rows is still found. Observed, so hosts follow each publish.
    private var candidates: [TimelineSearchSuggestion] = []
    /// No on-device analysis is enabled, so only metadata suggestions exist.
    public private(set) var showsSmartSearchHint = false

    @ObservationIgnored private let placeName: PlaceNameResolver
    @ObservationIgnored private let refreshPolicy: RefreshPolicy
    @ObservationIgnored private let libraryRows: SmartSearchLibraryRowsCache
    /// Whether this model computed visual concepts with a finished visual index.
    private var visualConceptsCompletedWhenReady = false
    /// Only the current refresh may publish after an asynchronous boundary.
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private(set) var lastRefreshCompleted = false
    @ObservationIgnored private(set) var lastRefreshWaitsForPlaces = false
    @ObservationIgnored private var metadata = TimelineSearchDiscoveryResult()
    @ObservationIgnored private var places: [TimelineSearchSuggestion] = []
    @ObservationIgnored private var concepts: [TimelineSearchSuggestion] = []
    @ObservationIgnored private var placeNames: [String: String] = [:]
    @ObservationIgnored private var gateKey: String?
    @ObservationIgnored private var sensitiveUIDs: Set<PhotoUID> = []
    @ObservationIgnored private var conceptKey: String?
    @ObservationIgnored private var conceptEvidence: [MLSearchConceptEvidence] = []

    #if DEBUG
        var metadataDidRunForTesting: (() -> Void)?
        var clusteringDidRunForTesting: (() -> Void)?
    #endif

    public convenience init(refreshPolicy: RefreshPolicy = .continuous, placeName: @escaping PlaceNameResolver) {
        self.init(refreshPolicy: refreshPolicy, placeName: placeName, libraryRows: SmartSearchLibraryRowsCache())
    }

    init(
        refreshPolicy: RefreshPolicy, placeName: @escaping PlaceNameResolver, libraryRows: SmartSearchLibraryRowsCache
    ) {
        self.refreshPolicy = refreshPolicy
        self.placeName = placeName
        self.libraryRows = libraryRows
    }

    struct PersistedSnapshot: Codable, Sendable {
        let candidates: [TimelineSearchSuggestion]
        let forYouIDs: [String]
        let chipIDs: [String]
        let showsSmartSearchHint: Bool
        let visualAvailability: Bool?
        let visualCompletedWhenReady: Bool
        let placeNames: [String: String]
        let placeNamesLocale: String
    }

    func persistedSnapshot() -> PersistedSnapshot? {
        guard lastRefreshCompleted else { return nil }
        return PersistedSnapshot(
            candidates: candidates, forYouIDs: forYou.map(\.id), chipIDs: chips.map(\.id),
            showsSmartSearchHint: showsSmartSearchHint, visualAvailability: settledVisualAvailability,
            visualCompletedWhenReady: visualConceptsCompletedWhenReady,
            placeNames: placeNames, placeNamesLocale: Self.placeNamesLocale)
    }

    private static var placeNamesLocale: String {
        Locale.current.identifier + "|" + Locale.preferredLanguages.joined(separator: "|")
    }

    func reusePlaceNames(from previous: SmartSearchDiscoveryModel) {
        placeNames = previous.placeNames
    }

    /// Retain only still-valid finished rows while resource gates defer their replacement.
    /// No new representative can enter through this path; changed rows wait for the normal safety gate.
    func invalidateRows(affectedUIDs: Set<PhotoUID>, favoritesChanged: Bool, locationsChanged: Bool) {
        let previousCount = candidates.count
        candidates.removeAll { row in
            (row.matchingUIDs.map { !$0.isDisjoint(with: affectedUIDs) } ?? false)
                || (favoritesChanged && row.kind == .favorites)
                || (locationsChanged && (row.kind == .place || row.kind == .placeSeason))
        }
        guard candidates.count != previousCount else { return }
        let validIDs = Set(candidates.map(\.id))
        forYou.removeAll { !validIDs.contains($0.id) }
        chips.removeAll { !validIDs.contains($0.id) }
        lastRefreshCompleted = false
        // Hiding a row does not prove that its suggestion is gone. Selections wait for the replacement refresh.
        if let settledContent { settledBeforeInvalidation = settledContent }
        settledContent = nil
        settledGeneration &+= 1
    }

    /// A metadata-only pass keeps the remaining rows and never replaces invalidated ones. Make them final again,
    /// so a selection whose row was removed stops waiting.
    func settleRetainedRows() {
        guard settledContent == nil, let settled = settledBeforeInvalidation else { return }
        settledContent = settled
        settledBeforeInvalidation = nil
        settledGeneration &+= 1
    }

    func restorePlaceNames(from snapshot: PersistedSnapshot) {
        placeNames = snapshot.placeNamesLocale == Self.placeNamesLocale ? snapshot.placeNames : [:]
    }

    func restore(
        _ snapshot: PersistedSnapshot, content: SmartSearchContentIdentity,
        isExactContent: Bool
    ) {
        var seen = Set<String>()
        candidates = snapshot.candidates.filter {
            seen.insert($0.id).inserted && $0.matchingUIDs?.isEmpty == false
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        forYou = snapshot.forYouIDs.compactMap { byID[$0] }
        chips = snapshot.chipIDs.compactMap { byID[$0] }
        lastPublished = candidates
        restorePlaceNames(from: snapshot)
        showsSmartSearchHint = snapshot.showsSmartSearchHint
        computedContent = content
        hasComputed = true
        settledContent = isExactContent ? content : nil
        settledBeforeInvalidation = nil
        settledVisualAvailability = isExactContent ? snapshot.visualAvailability : nil
        visualConceptsCompletedWhenReady = isExactContent && snapshot.visualCompletedWhenReady
        lastRefreshCompleted = isExactContent
        settledGeneration &+= 1
    }

    /// Whether the visual index can answer for the whole library.
    public nonisolated static func visualIndexReady(_ snapshot: MLSmartSearchSnapshot?) -> Bool {
        snapshot?.isVisualIndexComplete == true
    }

    /// Whether to show the short note that suggestions for photo content appear after the indexing. It is read at
    /// render time, so it follows Smart Search and its model at once without a refresh.
    public func showsVisualSuggestionsPendingNote(_ snapshot: MLSmartSearchSnapshot?) -> Bool {
        guard Self.visualConceptsAvailable(snapshot) else { return false }
        // Restored completed suggestions do not become pending while runtime coverage hydrates.
        return !visualConceptsCompletedWhenReady && !Self.visualIndexReady(snapshot)
    }

    /// Background refreshes keep the last published rows visible until their replacement is ready.
    private func effective(_ content: SmartSearchContentIdentity) -> SmartSearchContentIdentity {
        guard refreshPolicy != .continuous, hasComputed, let computedContent else { return content }
        return computedContent
    }

    /// Visual concept suggestions need Smart Search with a selected model.
    public nonisolated static func visualConceptsAvailable(_ snapshot: MLSmartSearchSnapshot?) -> Bool {
        snapshot?.isEnabled == true && snapshot?.selectedModelID != nil
    }

    /// Whether a published suggestion may be shown for the current state. A suggestion from other library
    /// content is never shown, and a visual concept is never shown while visual search is unavailable.
    public nonisolated static func isDisplayable(
        _ suggestion: TimelineSearchSuggestion,
        computedContent: SmartSearchContentIdentity?,
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> Bool {
        guard computedContent == content, let matches = suggestion.matchingUIDs, !matches.isEmpty
        else { return false }
        return suggestion.kind != .concept || visualConceptsAvailable(snapshot)
    }

    /// What to do with a search text. The title of a suggestion is run as ordinary text only after a current
    /// refresh has confirmed that no suggestion owns it; text the user typed is never erased.
    public nonisolated static func commitDecision(
        for text: String,
        displayable: [TimelineSearchSuggestion],
        published: [TimelineSearchSuggestion],
        isCurrent: Bool
    ) -> SmartSearchSuggestionCommitDecision {
        if let suggestion = displayable.first(where: { $0.owns(searchText: text) }) {
            return .structured(suggestion)
        }
        if !isCurrent, published.contains(where: { $0.matchingUIDs != nil && $0.owns(searchText: text) }) {
            return .deferUntilRefresh
        }
        return .text
    }

    /// What to do with a suggestion that was selected earlier, after the library or the search availability
    /// changed. While the suggestions are not current the host keeps the selected result set; the grid
    /// intersects it with the current items.
    public nonisolated static func rebind(
        _ active: TimelineSearchSuggestion,
        displayable: [TimelineSearchSuggestion],
        isCurrent: Bool,
        visualAvailable: Bool
    ) -> SmartSearchSuggestionRebindResult {
        if active.kind == .concept, !visualAvailable { return .drop }
        if let fresh = displayable.first(where: { $0.id == active.id }) { return .keep(fresh) }
        return isCurrent ? .drop : .pending
    }

    /// Whether the published rows are final for a suggestion of this kind. Metadata rows are final with the
    /// first publish, places only after every stage, and visual concepts only after a settled refresh that ran
    /// the visual stages.
    public nonisolated static func isDecisive(
        for kind: TimelineSearchSuggestionKind,
        isCurrent: Bool,
        isSettled: Bool,
        settledWithVisualConcepts: Bool
    ) -> Bool {
        switch kind {
        case .concept: return isSettled && settledWithVisualConcepts
        case .place, .placeSeason: return isSettled
        default: return isCurrent
        }
    }

    /// `isDecisive` for the published state of this model.
    public func isDecisive(for kind: TimelineSearchSuggestionKind, content: SmartSearchContentIdentity) -> Bool {
        let effectiveContent = effective(content)
        return Self.isDecisive(
            for: kind,
            isCurrent: isCurrent(content: effectiveContent),
            isSettled: isSettled(content: effectiveContent),
            settledWithVisualConcepts: settledVisualAvailability != nil
        )
    }

    /// Kind of the last published suggestion that owns the text. It survives the start of a refresh.
    public func publishedKind(owning text: String) -> TimelineSearchSuggestionKind? {
        lastPublished.first { $0.owns(searchText: text) }?.kind
    }

    /// Whether rows for this content are published. Later stages can still add places and visual concepts.
    public func isCurrent(content: SmartSearchContentIdentity) -> Bool {
        hasComputed && computedContent == effective(content)
    }

    /// Whether a refresh for this content ran every stage to its end.
    public func isSettled(content: SmartSearchContentIdentity) -> Bool {
        settledContent == effective(content)
    }

    public func forYou(
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> [TimelineSearchSuggestion] {
        let effectiveContent = effective(content)
        return forYou.filter {
            Self.isDisplayable($0, computedContent: computedContent, content: effectiveContent, snapshot: snapshot)
        }
    }

    public func chips(
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> [TimelineSearchSuggestion] {
        let effectiveContent = effective(content)
        return chips.filter {
            Self.isDisplayable($0, computedContent: computedContent, content: effectiveContent, snapshot: snapshot)
        }
    }

    /// A short text list for menu-style hosts: the most specific rows first, then media types.
    public func textSuggestions(
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?,
        limit: Int = 8
    ) -> [TimelineSearchSuggestion] {
        let rows = forYou(content: content, snapshot: snapshot) + chips(content: content, snapshot: snapshot)
        return Array(rows.prefix(limit))
    }

    /// Every displayable suggestion, without the menu limit.
    public func displayableSuggestions(
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> [TimelineSearchSuggestion] {
        textSuggestions(content: content, snapshot: snapshot, limit: .max)
    }

    /// Every suggestion that can work for the current state, including the ones that the row limits left out.
    /// Hosts resolve a selected, recent or typed suggestion against it and never display it.
    public func resolvableSuggestions(
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> [TimelineSearchSuggestion] {
        let effectiveContent = effective(content)
        return candidates.filter {
            Self.isDisplayable($0, computedContent: computedContent, content: effectiveContent, snapshot: snapshot)
        }
    }

    /// `commitDecision` for the published state of this model.
    public func commitDecision(
        for text: String,
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> SmartSearchSuggestionCommitDecision {
        // A visual concept cannot work while visual search is unavailable, so its title is ordinary text at once.
        let isCurrent = publishedKind(owning: text).map { kind in
            (kind == .concept && !Self.visualConceptsAvailable(snapshot)) || isDecisive(for: kind, content: content)
        }
        return Self.commitDecision(
            for: text,
            displayable: resolvableSuggestions(content: content, snapshot: snapshot),
            published: lastPublished,
            isCurrent: isCurrent ?? true
        )
    }

    /// `rebind` for the published state of this model.
    public func rebind(
        _ active: TimelineSearchSuggestion,
        content: SmartSearchContentIdentity,
        snapshot: MLSmartSearchSnapshot?
    ) -> SmartSearchSuggestionRebindResult {
        Self.rebind(
            active,
            displayable: resolvableSuggestions(content: content, snapshot: snapshot),
            // A settle that skipped the visual stages does not prove that a visual concept is gone.
            isCurrent: active.kind == .concept
                ? isDecisive(for: .concept, content: content) : isSettled(content: content),
            visualAvailable: Self.visualConceptsAvailable(snapshot)
        )
    }

    /// Identity of every input that can change the suggestions. Hosts restart `refresh` when it changes.
    public static func revisionKey(
        timelineRevision: UInt64,
        favoriteCount: Int,
        coordinateCount: Int,
        snapshot: MLSmartSearchSnapshot?,
        now: Date = Date()
    ) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        return [
            "\(timelineRevision)",
            "\(favoriteCount)",
            "\(coordinateCount / 250)",
            "\(snapshot?.isEnabled == true)",
            snapshot?.selectedModelID.map { "\($0)" } ?? "-",
            indexingBucket(snapshot),
            "\(day)",
        ].joined(separator: "|")
    }

    /// Coarse indexing progress: evidence is recomputed at most once per 10 % of coverage gained.
    private static func indexingBucket(_ snapshot: MLSmartSearchSnapshot?) -> String {
        switch snapshot?.indexingState {
        case .indexing(let progress), .waiting(let progress):
            "i\(Int((progress.fraction ?? 0) * 10))"
        case .ready: "r"
        default: "-"
        }
    }

    public func refresh(
        sections: [TimelineSection],
        timelineRevision: UInt64,
        favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate],
        smartSearch: MLSmartSearchController?,
        includeVisualConcepts: Bool = true
    ) async {
        let lifecycle = smartSearch?.lifecycleActor
        let search: MLSearchConceptDiscovery.Search?
        if let lifecycle {
            search = { prompt, limit in
                try await lifecycle.search(prompt, limit: limit, intent: .automatic).results.map(\.uid)
            }
        } else {
            search = nil
        }
        await refresh(
            sections: sections, timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs,
            coordinates: coordinates, snapshot: smartSearch?.snapshot,
            indexedAssetCount: { await lifecycle?.semanticIndexedAssetCount() ?? 0 },
            search: search, includeVisualConcepts: includeVisualConcepts
        )
    }

    func refresh(
        sections: [TimelineSection],
        timelineRevision: UInt64,
        favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate],
        snapshot: MLSmartSearchSnapshot?,
        indexedAssetCount: @Sendable () async -> Int,
        search: MLSearchConceptDiscovery.Search?,
        includeVisualConcepts: Bool = true,
        metadataOnly: Bool = false,
        allowsRepresentative: (@Sendable (PhotoUID) -> Bool)? = nil,
        previewsDidPublish: (@MainActor () -> Void)? = nil,
        locationEvidence: PhotoPlaceEvidence? = nil
    ) async {
        let visualAvailable = Self.visualConceptsAvailable(snapshot)
        let content = SmartSearchContentIdentity(timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs)
        showsSmartSearchHint = snapshot?.isEnabled != true
        lastRefreshCompleted = false
        lastRefreshWaitsForPlaces = false
        settledBeforeInvalidation = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let refreshIndexingReady = Self.visualIndexReady(snapshot)
        let keepsRows = refreshPolicy != .continuous && hasComputed
        if keepsRows {
            // The next publish replaces the rows at once; nothing is cleared, so no placeholder appears.
        } else if computedContent?.timelineRevision != timelineRevision {
            // Result sets from another library revision may reference removed items; never reuse them.
            metadata = TimelineSearchDiscoveryResult()
            places = []
            clearVisualEvidence()
            forYou = []
            chips = []
            candidates = []
            hasComputed = false
        } else if computedContent != content {
            // Only the favorites changed. Places and visual concepts do not depend on them and are kept.
            metadata = TimelineSearchDiscoveryResult()
            forYou = []
            chips = []
            candidates = []
            hasComputed = false
        }
        if settledContent != content || (includeVisualConcepts && settledVisualAvailability != visualAvailable) {
            settledContent = nil
            settledVisualAvailability = nil
        }
        if refreshPolicy == .background, visualAvailable, !includeVisualConcepts {
            settledVisualAvailability = nil
        }
        if !visualAvailable {
            clearVisualEvidence()
        }

        // Stage 1: the sensitive gate must finish before any preview is chosen.
        var covered = 0
        var gatePassed = !visualAvailable
        if Self.visualConceptsAvailable(snapshot), let search {
            covered = await indexedAssetCount()
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if covered == 0 {
                clearVisualEvidence()
            } else {
                gatePassed = true
                let key = evidenceKey(timelineRevision: timelineRevision, snapshot: snapshot)
                if gateKey != key, !includeVisualConcepts {
                    // The gate needs inference, which this refresh skips. Fail closed: no previews.
                    gatePassed = false
                } else if gateKey != key {
                    do {
                        let sensitive = try await MLSearchConceptDiscovery.sensitiveUIDs(search: search)
                        guard !Task.isCancelled, generation == refreshGeneration else { return }
                        sensitiveUIDs = sensitive
                        gateKey = key
                    } catch {
                        guard !Task.isCancelled, generation == refreshGeneration else { return }
                        PhotoDiagnostics.shared.increment("ml.suggestions.sensitiveGateFailed")
                        gatePassed = false
                        clearVisualEvidence()
                    }
                }
            }
        }
        if !gatePassed {
            clearVisualEvidence()
            places = []
        }
        let context = TimelineSearchDiscoveryContext(
            favoriteUIDs: favoriteUIDs,
            excludedRepresentativeUIDs: sensitiveUIDs,
            allowsRepresentative: visualAvailable ? allowsRepresentative : nil,
            suppressesRepresentatives: !gatePassed
        )

        // Stage 2: metadata. It needs no network and no further ML. Building the rows reads every photo; the
        // previews depend on the gate only, so every pass for the same content reuses the rows.
        let rowsKey = SmartSearchLibraryRowsCache.Key(content: content, context: context)
        let rows: TimelineSearchLibraryRows
        if let cached = libraryRows.rows(for: rowsKey) {
            rows = cached
        } else {
            rows = await Self.background {
                TimelineSearchDiscovery.libraryRows(sections: sections, context: context)
            }
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            libraryRows.store(rows, for: rowsKey)
        }
        let newMetadata = await Self.background {
            TimelineSearchDiscovery.librarySuggestions(rows: rows, context: context)
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        if computedContent != content {
            places = []
            concepts = []
        }
        #if DEBUG
            metadataDidRunForTesting?()
        #endif
        metadata = newMetadata
        publish(content: content)
        previewsDidPublish?()

        // The scheduler's first publication must not wait for network-backed place names before its gate.
        if metadataOnly {
            settle(
                content: content, visualAvailable: visualAvailable, ranVisualStages: false,
                indexingReady: refreshIndexingReady)
            return
        }

        // Prepare the local lookup once for concepts and places.
        let itemsByUID: [PhotoUID: PhotoItem] = await Self.background {
            var index: [PhotoUID: PhotoItem] = [:]
            for section in sections {
                guard !Task.isCancelled else { return [:] }
                for item in section.items { index[item.uid] = item }
            }
            return index
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        // Stage 3: publish checked visual concepts before any network-backed place names.
        var visualStagesComplete = gatePassed
        if includeVisualConcepts {
            if gatePassed, covered > 0, let search {
                let key = evidenceKey(timelineRevision: timelineRevision, snapshot: snapshot)
                if conceptKey != key {
                    let sensitive = sensitiveUIDs
                    let evaluation = await MLSearchConceptDiscovery.evaluateWithCompletion(
                        coveredAssetCount: covered,
                        sensitiveUIDs: sensitive,
                        search: search
                    )
                    guard !Task.isCancelled, generation == refreshGeneration else { return }
                    conceptEvidence = evaluation.evidence
                    visualStagesComplete = evaluation.isComplete
                    conceptKey = evaluation.isComplete ? key : nil
                }
                let evidence = conceptEvidence
                let newConcepts = await Self.background {
                    evidence.map { entry in
                        let matches = entry.rankedUIDs.compactMap { itemsByUID[$0] }
                        // The best-ranked matches make the most convincing previews.
                        let previews = TimelineSearchDiscovery.representatives(
                            for: Array(matches.prefix(12)),
                            context: context
                        )
                        return TimelineSearchSuggestion(
                            id: "concept:\(entry.concept.id)",
                            query: entry.concept.title,
                            title: entry.concept.title,
                            subtitle: TimelineSearchDiscovery.countText(matches.count),
                            systemImage: entry.concept.systemImage,
                            kind: .concept,
                            matchingUIDs: Set(matches.map(\.uid)),
                            representativeUIDs: previews
                        )
                    }
                }
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                concepts = newConcepts
                publish(content: content)
                previewsDidPublish?()
            } else {
                concepts = []
                conceptEvidence = []
                conceptKey = nil
                publish(content: content)
            }
        }

        // Stage 4: only centroids of photo clusters are named.
        if let locationEvidence, !(await locationEvidence.waitForWarming()) {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            lastRefreshWaitsForPlaces = true
            return
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        #if DEBUG
            clusteringDidRunForTesting?()
        #endif
        let candidates = await Self.background {
            TimelineSearchDiscovery.placeCandidates(coordinates: coordinates, evidence: locationEvidence)
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        for candidate in candidates where placeNames[candidate.id] == nil {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if let name = await placeName(candidate.latitude, candidate.longitude) {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                placeNames[candidate.id] = name
            }
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        let names = placeNames
        let newPlaces = await Self.background {
            TimelineSearchDiscovery.placeSuggestions(
                candidates: candidates,
                names: names,
                itemsByUID: itemsByUID,
                context: context
            )
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        places = newPlaces
        publish(content: content)
        settle(
            content: content, visualAvailable: visualAvailable,
            ranVisualStages: includeVisualConcepts && visualStagesComplete, indexingReady: refreshIndexingReady
        )
    }

    /// A cancelled host also cancels its utility worker. Results still require the refresh generation check.
    nonisolated static func background<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Marks the refresh as complete. A refresh that skipped the visual stages keeps the availability of an
    /// earlier complete refresh for the same content.
    private func settle(
        content: SmartSearchContentIdentity, visualAvailable: Bool, ranVisualStages: Bool, indexingReady: Bool
    ) {
        lastRefreshCompleted = !visualAvailable || ranVisualStages
        if ranVisualStages {
            settledVisualAvailability = visualAvailable
            if visualAvailable && indexingReady {
                visualConceptsCompletedWhenReady = true
            }
        }
        // Every stage ran, so an earlier place that is not published now is gone. An earlier visual concept
        // stays only while a later refresh can still find it.
        lastPublished = Self.mergedPublished(
            rows: candidates,
            previous: lastPublished,
            keepsPlaces: false,
            keepsConcepts: visualAvailable && !ranVisualStages
        )
        settledContent = content
        settledGeneration &+= 1
    }

    private func evidenceKey(timelineRevision: UInt64, snapshot: MLSmartSearchSnapshot?) -> String {
        Self.visualEvidenceKey(timelineRevision: timelineRevision, snapshot: snapshot)
    }

    static func visualEvidenceKey(
        timelineRevision: UInt64, snapshot: MLSmartSearchSnapshot?, indexingKey: String? = nil
    ) -> String {
        let selected = snapshot?.availableModels.first { $0.id == snapshot?.selectedModelID }
        return [
            "\(timelineRevision)",
            snapshot?.selectedModelID.map { "\($0)" } ?? "-",
            selected.map { "\($0.descriptor.displayName)|\($0.downloadPlan?.revision ?? "local")" } ?? "-",
            indexingKey ?? indexingBucket(snapshot),
        ].joined(separator: "|")
    }

    /// Drops the sensitive gate and every visual concept, so none can be shown or reused.
    private func clearVisualEvidence() {
        sensitiveUIDs = []
        gateKey = nil
        concepts = []
        conceptEvidence = []
        conceptKey = nil
        forYou.removeAll { $0.kind == .concept }
        candidates.removeAll { $0.kind == .concept }
    }

    private func publish(content: SmartSearchContentIdentity) {
        // Concepts lead when they exist: they are the most library-specific signal. Places and anniversaries
        // follow, then trips, seasons and favorites.
        let byKind = Dictionary(grouping: metadata.forYou, by: \.kind)
        forYou = TimelineSearchDiscovery.rankForYou(
            [
                concepts,
                places,
                byKind[.onThisDay] ?? [],
                byKind[.trip] ?? [],
                byKind[.season] ?? [],
                byKind[.favorites] ?? [],
            ],
            limit: 10,
            perKind: 3
        )
        chips = metadata.chips
        var seenIDs = Set<String>()
        candidates = (forYou + chips + concepts + places + metadata.forYou).filter {
            $0.matchingUIDs != nil && seenIDs.insert($0.id).inserted
        }
        // Places and visual concepts come from later stages, so a publish before the settle does not prove
        // that an earlier one is gone. `settle` drops them.
        lastPublished = Self.mergedPublished(
            rows: candidates, previous: lastPublished, keepsPlaces: true, keepsConcepts: true)
        computedContent = content
        hasComputed = true
    }

    /// The resolved rows of a publish, followed by the earlier place and concept entries that no new row
    /// replaces. An entry is replaced by a row with its identifier or its title.
    nonisolated static func mergedPublished(
        rows: [TimelineSearchSuggestion],
        previous: [TimelineSearchSuggestion],
        keepsPlaces: Bool,
        keepsConcepts: Bool
    ) -> [TimelineSearchSuggestion] {
        let resolved = rows.filter { $0.matchingUIDs != nil }
        let carried = previous.filter { old in
            let isKept: Bool
            switch old.kind {
            case .place, .placeSeason: isKept = keepsPlaces
            case .concept: isKept = keepsConcepts
            default: isKept = false
            }
            return isKept
                && !resolved.contains {
                    $0.id == old.id || $0.owns(searchText: old.query) || $0.owns(searchText: old.title)
                }
        }
        return resolved + carried
    }
}
