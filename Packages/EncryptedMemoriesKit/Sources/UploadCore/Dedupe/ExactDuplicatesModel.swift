import Foundation
import Observation
import PhotosCore
import Synchronization

/// Publication ownership shared with synchronous task cancellation handlers.
final class ExactDuplicateRankingPublication: Sendable {
    private struct Owners {
        var worker: UUID?
        var merge: UUID?
    }

    private let owners = Mutex(Owners())

    var worker: UUID? {
        get { owners.withLock { $0.worker } }
        set { owners.withLock { $0.worker = newValue } }
    }

    var merge: UUID? {
        get { owners.withLock { $0.merge } }
        set { owners.withLock { $0.merge = newValue } }
    }

    func owns(_ token: UUID) -> Bool {
        owners.withLock { $0.worker == token || $0.merge == token }
    }

    func revoke(_ token: UUID?) {
        guard let token else { return }
        owners.withLock {
            if $0.worker == token { $0.worker = nil }
            if $0.merge == token { $0.merge = nil }
        }
    }

    func cancel(_ task: Task<Void, Never>?, token: UUID?) {
        revoke(token)
        task?.cancel()
    }
}

/// The reads and the merge that the Duplicates screens need. `ExactDuplicateFinder` serves the signed-in account;
/// tests and the offline UI-test account supply their own.
public protocol ExactDuplicateMerging: Sendable {
    /// The groups, read from the content index. Reports how many candidate photos the visibility read covered.
    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan
    /// Builds the content index when none exists, or brings it up to date, and reports the progress of the build.
    /// True when the index changed.
    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool
    /// The members of each group in an order that needs no request.
    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]]
    /// The capture dates of `members` that the device already knows, without a request. Unknown photos are left out.
    func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date]
    /// Ranks the members of each group, page by page. A group whose facts cannot be read is not in its page.
    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async
    /// Merges each group, keeping its photo. One result for each group, in order. After a cancellation, the groups
    /// without an outcome fail with `CancellationError`.
    func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>]
    /// `merge(_:)` for one batch of `run`, which shares its listings across the batches.
    func merge(
        _ requests: [ExactDuplicateMergeRequest], in run: ExactDuplicateMergeRun
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>]
    /// Checks the merges that an earlier failure or the end of the process left open, and restores a copy of a group
    /// that has none in the library. Reads nothing from the server while no merge is open.
    func resolvePendingMerges() async
    /// Checks the open merges and answers whether none is left. False while the journal cannot be read or a merge still
    /// waits for its check: emptying Recently Deleted then could delete the last copy of a group for good.
    func confirmNoPendingMerges() async -> Bool
    /// Runs `body`, which empties Recently Deleted, while no merge runs, and holds new merges until it ends.
    func excludingMerges(_ body: () async throws -> Void) async throws
}

extension ExactDuplicateFinder: ExactDuplicateMerging {}

extension ExactDuplicateMerging {
    /// Without a local timeline, no date is known.
    public func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] { [:] }

    /// Mergers without a merge journal leave no merge open.
    public func resolvePendingMerges() async {}

    /// Mergers without a merge journal leave no merge open.
    public func confirmNoPendingMerges() async -> Bool { true }

    /// Mergers without a merge journal leave no trashed copy to an open merge.
    public func excludingMerges(_ body: () async throws -> Void) async throws { try await body() }

    /// Mergers without shared listings merge each batch on its own.
    public func merge(
        _ requests: [ExactDuplicateMergeRequest], in run: ExactDuplicateMergeRun
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        await merge(requests)
    }
}

/// A fact of one copy that the screens show as a small badge, in the order of the ranking.
public enum ExactDuplicateBadge: CaseIterable, Equatable, Sendable {
    case shared
    /// In one of the person's own albums.
    case album
    case favorite
    /// A local source of this device counts the copy as its backup. Only information: it never decides which copy
    /// stays, because another device backs up other copies.
    case backedUpHere

    /// The spoken name of the badge.
    public var title: String {
        switch self {
        case .shared: L10n.string("duplicates.badge_shared")
        case .album: L10n.string("duplicates.badge_album")
        case .favorite: L10n.string("duplicates.badge_favorite")
        case .backedUpHere: L10n.string("duplicates.badge_backed_up_here")
        }
    }

    func applies(to facts: ExactDuplicateKeepFacts) -> Bool {
        switch self {
        case .shared: facts.isShared
        case .album: facts.isInOwnAlbum
        case .favorite: facts.isFavorite
        case .backedUpHere: facts.isNamedByManifest
        }
    }

    /// The fact ranks the copy to keep, so it can be the reason why a copy stays.
    var ranksKeep: Bool { self != .backedUpHere }
}

/// Why the copy that a merge keeps stays instead of another copy.
public enum ExactDuplicateStayReason: Equatable, Sendable {
    /// The kept copy has this fact and another copy has not.
    case badge(ExactDuplicateBadge)
    /// No other copy is older, and another copy is newer.
    case oldest
    /// No fact sets the kept copy apart.
    case identical

    public var text: String {
        switch self {
        case .badge(.shared): L10n.string("duplicates.stays_shared")
        case .badge(.album): L10n.string("duplicates.stays_album")
        case .badge(.favorite): L10n.string("duplicates.stays_favorite")
        case .oldest: L10n.string("duplicates.stays_oldest")
        // "Backed up here" never ranks, so it is never the reason.
        case .identical, .badge(.backedUpHere): L10n.string("duplicates.stays_any")
        }
    }
}

/// One short message after a merge that did not move every duplicate to Recently Deleted.
public enum ExactDuplicateMergeNotice: Equatable, Sendable {
    /// `count` duplicates stayed in the library. `reason` is the first of their reasons in a fixed order.
    case keptDuplicates(count: Int, reason: ExactDuplicateKeepReason)
    /// The server did not return the complete photo to keep.
    case keptPhotoUnreadable
    /// A merge failed, for example without a connection.
    case failed
    /// Merge All stopped, because the person stopped it or a whole batch failed. `merged` of `total` groups merged.
    case stopped(merged: Int, total: Int)

    public var title: String {
        switch self {
        case .keptDuplicates(let count, _): L10n.string("duplicates.kept_title \(count)")
        case .keptPhotoUnreadable: L10n.string("duplicates.not_merged_title")
        case .failed: L10n.string("duplicates.merge_failed_title")
        case .stopped(let merged, let total):
            L10n.string("duplicates.merge_stopped \(merged.formatted()) \(total.formatted())")
        }
    }

    /// Empty when the title says everything.
    public var message: String {
        switch self {
        case .keptDuplicates(_, .relatedFileWithoutTwin): L10n.string("duplicates.kept_reason_related_file")
        case .keptDuplicates(_, .pendingEditReplacement): L10n.string("duplicates.kept_reason_pending_edit")
        case .keptDuplicates(_, .neededByLocalSource): L10n.string("duplicates.kept_reason_needed_here")
        case .keptDuplicates(_, .shared): L10n.string("duplicates.kept_reason_shared")
        case .keptDuplicates(_, .unreadable): L10n.string("duplicates.kept_reason_unreadable")
        case .keptDuplicates(_, .differentDetails): L10n.string("duplicates.kept_reason_different_details")
        case .keptPhotoUnreadable: L10n.string("duplicates.kept_photo_unreadable")
        case .failed: L10n.string("duplicates.merge_failed_message")
        case .stopped: ""
        }
    }
}

/// The shared state of the Duplicates screens on iOS, iPadOS, and macOS: the groups, the photo to keep in each
/// group, and the merges. The platform views only render it and forward taps.
///
/// A load shows the groups as soon as the scan returns, in an order that needs no request. The ranking then reads the
/// facts of the groups page by page, and the content index builds or refreshes at the same time.
@MainActor
@Observable
public final class ExactDuplicatesModel {
    /// One group as the screens show it.
    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String { scanGroup.id }
        public internal(set) var scanGroup: ExactDuplicateGroup
        /// The members, the photo that the ranking keeps first.
        public internal(set) var members: [PhotoUID]
        /// The photo that a merge keeps. The ranking chooses it until the person taps another member.
        public internal(set) var kept: PhotoUID
        /// Why the last merge of this group left duplicates in the library. Nil before a merge.
        public internal(set) var keptReason: ExactDuplicateKeepReason?
        /// False while `members` holds the fallback order, before the ranking read the facts of the group.
        public internal(set) var isRanked = false
        /// The person tapped the photo to keep, so the ranking no longer changes it.
        public internal(set) var isKeptChosen = false
        /// The size of one copy in bytes. Nil until the manifest or a node read of the ranking knows it.
        public internal(set) var byteSize: Int64?
        /// The members that the person shares, as the ranking read them. Empty before the ranking.
        public internal(set) var sharedMembers: Set<PhotoUID> = []
        /// The facts of each member, as the ranking read them. Empty before the ranking.
        public internal(set) var memberFacts: [PhotoUID: ExactDuplicateKeepFacts] = [:]
        /// The size of a member in bytes where its own node states one. Copies of other bytes can differ in size.
        public internal(set) var memberByteSizes: [PhotoUID: Int64] = [:]
        /// The capture dates that the device knows, without a request.
        public internal(set) var captureDates: [PhotoUID: Date] = [:]
        /// The photos that a merge moves to Recently Deleted.
        public var duplicateCount: Int { members.count - 1 }

        /// The size of `member` in bytes: its own size, else the size of one copy. Nil while unknown.
        public func byteSize(of member: PhotoUID) -> Int64? { memberByteSizes[member] ?? byteSize }

        /// The space that the merge frees: the sizes of every member except the kept one. Nil while one is unknown.
        public var freedBytes: Int64? {
            var total: Int64 = 0
            for member in members where member != kept {
                guard let size = byteSize(of: member) else { return nil }
                total += size
            }
            return total
        }

        /// The short text of `freedBytes`, for example "Merge frees 4.2 MB". Nil while the size is unknown.
        public var freedText: String? {
            freedBytes.map { L10n.string("duplicates.group_frees \(ExactDuplicatesModel.byteText($0))") }
        }

        /// The short text of `keptReason`, for example below the group.
        public var keptReasonMessage: String? {
            keptReason.map { ExactDuplicateMergeNotice.keptDuplicates(count: duplicateCount, reason: $0).message }
        }

        /// The badges of `member`, in the order of the ranking. Empty before the ranking read its facts.
        public func badges(of member: PhotoUID) -> [ExactDuplicateBadge] {
            guard let facts = memberFacts[member] else { return [] }
            return ExactDuplicateBadge.allCases.filter { $0.applies(to: facts) }
        }

        /// Why the kept member stays: the first fact in the order of the ranking that it has and another member
        /// has not, then the oldest capture date. Nil before the ranking read the facts of the kept member.
        public var stayReason: ExactDuplicateStayReason? {
            guard isRanked, let keptFacts = memberFacts[kept] else { return nil }
            let others = members.filter { $0 != kept }.map { memberFacts[$0] }
            for badge in ExactDuplicateBadge.allCases where badge.ranksKeep && badge.applies(to: keptFacts) {
                if others.contains(where: { other in !(other.map { badge.applies(to: $0) } ?? false) }) {
                    return .badge(badge)
                }
            }
            if let date = keptFacts.captureDate {
                let dates = others.compactMap { $0?.captureDate }
                if !dates.contains(where: { $0 < date }), dates.contains(where: { $0 > date }) { return .oldest }
            }
            return .identical
        }

        /// One line below the group: why the kept member stays and what the merge frees. Before the ranking only
        /// the freed space; nil while neither is known.
        public var footerText: String? {
            let parts = [stayReason?.text, freedText].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The capture day of the group in the system's numeric date format, or the first and the last day joined
        /// when the members differ. Nil while no date is known.
        public var dateText: String? {
            let days = Set(members.compactMap { captureDates[$0] }.map { Calendar.current.startOfDay(for: $0) })
            guard let first = days.min(), let last = days.max() else { return nil }
            let text = { (day: Date) in day.formatted(date: .numeric, time: .omitted) }
            return first == last ? text(first) : L10n.string("duplicates.dates \(text(first)) \(text(last))")
        }

        /// The title above the group: its date, else its number of copies.
        public var title: String { dateText ?? L10n.string("duplicates.group_title \(members.count)") }

        /// The title of the action that keeps `member`: "Keep This Copy", or "Kept" when a merge keeps it already.
        public func keepTitle(for member: PhotoUID) -> String {
            kept == member ? L10n.string("duplicates.kept") : L10n.string("duplicates.keep_this_copy")
        }

        /// The spoken label of `member`: its position, whether it is kept, its badges, and its size.
        public func accessibilityLabel(of member: PhotoUID) -> String {
            guard let position = members.firstIndex(of: member) else { return "" }
            var parts = [L10n.string("duplicates.member_label \(position + 1) \(members.count)")]
            if member == kept { parts.append(L10n.string("duplicates.member_kept")) }
            parts += badges(of: member).map(\.title)
            if let size = byteSize(of: member) { parts.append(ExactDuplicatesModel.byteText(size)) }
            return parts.joined(separator: ", ")
        }

        /// Drops the photos that a merge moved to Recently Deleted. False when fewer than two members remain.
        mutating func remove(_ trashed: [PhotoUID], keptReason reason: ExactDuplicateKeepReason?) -> Bool {
            let remaining = members.filter { !trashed.contains($0) }
            guard remaining.count > 1 else { return false }
            members = remaining
            scanGroup = scanGroup.keeping(remaining)
            if !remaining.contains(kept) { kept = remaining[0] }
            keptReason = reason
            return true
        }

        /// The parts of this group whose members have equal metadata, two or more, as `ExactDuplicateGroup.split`
        /// forms them. The part with the photo shown as kept comes first and keeps the ID and the person's choice.
        /// Every other part keeps its first member until the ranking orders it.
        func parts(by fingerprints: [PhotoUID: ExactDuplicateFingerprint], avoiding taken: Set<String>) -> [Group] {
            let split = scanGroup.split(by: fingerprints, keepingIDWith: kept, avoiding: taken)
            return (split.filter { $0.id == id } + split.filter { $0.id != id }).map { part in
                var group = self
                group.scanGroup = part
                // Mostly every copy has the same metadata, and the group stays whole.
                guard part.members.count < members.count else { return group }
                let current = Set(part.members)
                group.members = members.filter(current.contains)
                group.sharedMembers = sharedMembers.intersection(current)
                group.memberFacts = memberFacts.filter { current.contains($0.key) }
                group.memberByteSizes = memberByteSizes.filter { current.contains($0.key) }
                group.captureDates = captureDates.filter { current.contains($0.key) }
                if part.id != id { group.keptReason = nil }
                if !current.contains(kept) {
                    group.kept = group.members[0]
                    group.isKeptChosen = false
                }
                return group
            }
        }

        /// Takes the ranked order. The photo to keep follows it unless the person chose one.
        mutating func rank(
            _ order: [PhotoUID], shared: Set<PhotoUID>, facts: [PhotoUID: ExactDuplicateKeepFacts] = [:],
            sizes: [PhotoUID: Int64] = [:]
        ) {
            let current = Set(members)
            let ranked = order.filter(current.contains)
            members = ranked + members.filter { !ranked.contains($0) }
            sharedMembers = shared.intersection(current)
            memberFacts = facts.filter { current.contains($0.key) }
            memberByteSizes.merge(sizes.filter { current.contains($0.key) }) { _, new in new }
            for (member, fact) in memberFacts {
                if let date = fact.captureDate { captureDates[member] = date }
            }
            isRanked = true
            guard !isKeptChosen else { return }
            kept = members[0]
        }
    }

    public enum Content: Equatable, Sendable {
        case loading
        case failed(String)
        case noDuplicates
        /// No group yet, and the content index still builds.
        case stillChecking
        case groups
    }

    /// How far the library check has come while the content index builds.
    public enum CheckProgress: Equatable, Sendable {
        /// The build reads the library and knows no total yet.
        case indeterminate
        case counted(completed: Int, total: Int)
    }

    /// One titled progress line: a short title, a count line when the total is known, and the completed fraction.
    public struct ProgressLine: Equatable, Sendable {
        public let title: String
        public let detail: String?
        /// Nil while the total is unknown.
        public let fraction: Double?
    }

    private enum Phase: Equatable {
        case idle, loading, loaded
        case failed
    }

    /// The groups shown. Each write publishes one change to the screens, so work that changes many groups, such as a
    /// ranked page or a merge, changes a copy and writes it back once.
    public private(set) var groups: [Group] {
        get {
            access(keyPath: \.groups)
            return groupStorage
        }
        set {
            withMutation(keyPath: \.groups) { groupStorage = newValue }
            groupChanges &+= 1
        }
    }
    @ObservationIgnored private var groupStorage: [Group] = []
    /// How many changes `groups` published. Tests read it.
    @ObservationIgnored private(set) var groupChanges = 0
    /// The final checked groups that the screen can present as duplicates. Failed candidates remain hidden.
    public var visibleGroups: [Group] {
        isCheckingGroups || hasInvalidatedGroups ? [] : groups.filter(\.isRanked)
    }
    /// The screen waits for its scan and metadata check.
    public private(set) var isCheckingGroups = false
    public var checkingGroupsLine: ProgressLine {
        rankingLine ?? ProgressLine(title: L10n.string("duplicates.ranking_title"), detail: nil, fraction: nil)
    }
    /// How much of the library the content index covered at the last scan.
    public private(set) var coverage = ExactDuplicateCoverage.complete
    public private(set) var isMerging = false
    /// The progress of the content index build. Nil while no build runs.
    public private(set) var checkProgress: CheckProgress?
    /// The visibility read of the scan while the screen loads. Nil outside a scan.
    public private(set) var scanProgress: ExactDuplicateScanProgress?
    /// The groups that the ranking has covered, of all groups that it ranks. Nil while no ranking runs.
    public private(set) var rankingProgress: ExactDuplicateScanProgress?
    /// The message of the last merge, until the person dismisses it.
    public private(set) var notice: ExactDuplicateMergeNotice?
    /// The groups that Merge All handled in its batches, of all groups that it merges. Nil outside Merge All and while
    /// Merge All still ranks.
    public private(set) var mergeAllProgress: ExactDuplicateScanProgress?
    /// Merge All runs, from its ranking to its last batch.
    public private(set) var isMergingAll = false
    /// The person stopped Merge All. The running batch finishes first.
    public private(set) var isStoppingMergeAll = false
    /// Account retirement permanently prevents a queued action from starting another merge.
    private var isRetired = false
    /// A merge waits for the facts of groups that nobody scrolled to. Its progress counts that run's groups;
    /// the screen ranking shows the checked groups of the whole list.
    private var isRankingForMerge = false
    /// Merge All starts no further batch until `resumeMerging()`, for example while the app is in the background.
    @ObservationIgnored private var isMergePaused = false
    /// Merge All waits here while it is paused.
    @ObservationIgnored private var mergeResumers: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// A batch of a merge is with the finder.
    @ObservationIgnored private var isMergeBatchRunning = false
    /// They wait until the running batch finished.
    @ObservationIgnored private var batchWaiters: [CheckedContinuation<Void, Never>] = []
    /// The ranking that Merge All waits for. Stop and a pause cancel it.
    @ObservationIgnored private var mergeRanking: Task<Void, Never>?
    /// Identifies the merge ranking that still owns page publication.
    private var mergeRankingToken: UUID? {
        get { rankingPublication.merge }
        set { rankingPublication.merge = newValue }
    }
    /// A pause cancelled the ranking of Merge All; it ranks the remaining groups after the pause.
    @ObservationIgnored private var mergeRankingInterrupted = false
    /// The groups whose photo to keep a running merge already read. A ranking that lands meanwhile never moves their
    /// checkmark, so the screen shows the photo that the merge keeps.
    @ObservationIgnored private var mergingGroupIDs: Set<String> = []
    private var phase = Phase.idle
    /// A merge invalidated displayed metadata; only a successful scan makes its groups current again.
    private var hasInvalidatedGroups = false
    /// The last build failed, or it finished without an index.
    private var buildFailed = false
    /// The service stopped the last build, for example for a full refresh. The check restarts, after a merge at once.
    @ObservationIgnored private var checkInterrupted = false
    /// The check restarted after an interruption in this load. Outside a merge, another interruption offers Retry.
    @ObservationIgnored private var restartedAfterInterruption = false
    /// The build finished during a merge with a changed index; the screen reads the groups again after the merge.
    @ObservationIgnored private var rescanAfterMerge = false
    private var loadGeneration = 0
    /// The one build of this model. A load while it runs waits for it, and a closed screen leaves it running: the
    /// backup uses the same build, and the build resumes from its checkpoint.
    @ObservationIgnored private var indexBuild: Task<Bool, any Error>?
    /// A screen check requests every candidate once; closing the screen stops it.
    @ObservationIgnored private var checksAllGroups = false
    @ObservationIgnored private var hasOpenedScreen = false
    private var rankingFailed = false
    private var rankingFraction = 0.0
    /// The ranking of the last load. A new load cancels it.
    @ObservationIgnored private var ranking: Task<Void, Never>?
    /// The groups that wait for the ranking, in the order the screen showed them.
    @ObservationIgnored private var rankingQueue: [String] = []
    /// The metadata of each copy that a ranking read. A screen that opens again splits its groups at once by them.
    /// A merge that finds other metadata drops those of its group.
    @ObservationIgnored private var knownFingerprints: [PhotoUID: ExactDuplicateFingerprint] = [:]
    /// The groups that the ranking of this load has read or queued. A failed group waits for the next load or a merge.
    @ObservationIgnored private var rankingRequested: Set<String> = []
    /// The groups that the screen showed since the last pause, until the pause after them ranks their pages.
    @ObservationIgnored private var appearedGroupIDs: Set<String> = []
    /// Counts the groups shown, so the pause restarts while the screen keeps showing groups.
    @ObservationIgnored private var appearances = 0
    /// Waits for the pause after the last group shown. One at a time.
    @ObservationIgnored private var appearanceFollower: Task<Void, Never>?
    /// Identifies the running scroll ranking. A merge shows its own progress, so it never owns this ranking.
    private var rankingWorkerToken: UUID? {
        get { rankingPublication.worker }
        set { rankingPublication.worker = newValue }
    }
    @ObservationIgnored private let rankingPublication = ExactDuplicateRankingPublication()
    /// Cleanup ownership lasts until the cancelled worker is joined or replaced.
    @ObservationIgnored private var rankingTaskToken: UUID?
    /// Identifies the ranking whose progress the screen shows.
    @ObservationIgnored private var rankingToken = UUID()
    @ObservationIgnored private let finder: any ExactDuplicateMerging
    /// Called with the photos that a merge moved to Recently Deleted, so the library stops showing them.
    @ObservationIgnored private let didTrash: @MainActor ([PhotoUID]) async -> Void

    public init(
        finder: any ExactDuplicateMerging, didTrash: @escaping @MainActor ([PhotoUID]) async -> Void = { _ in }
    ) {
        self.finder = finder
        self.didTrash = didTrash
    }

    /// False while the content index misses photos, so more duplicates can appear later.
    public var isComplete: Bool { coverage.isComplete }

    private var isBuilding: Bool { checkProgress != nil }

    public var content: Content {
        if isCheckingGroups { return .groups }
        return switch phase {
        case .idle, .loading: groups.isEmpty ? .loading : .groups
        case .failed: groups.isEmpty ? .failed(L10n.string("duplicates.load_failed")) : .groups
        case .loaded:
            if !groups.isEmpty {
                .groups
            } else if buildFailed, !isBuilding, !isMerging, !isComplete {
                .failed(L10n.string("duplicates.load_failed"))
            } else if case .indexing = coverage {
                .stillChecking
            } else if !isComplete, isBuilding {
                .stillChecking
            } else {
                // A finished check never waits: photos that could not be read get one line instead.
                .noDuplicates
            }
        }
    }

    /// The text of `.noDuplicates` and `.stillChecking`.
    public var emptyStateCopy: PhotoFilterEmptyStateCopy {
        switch content {
        case .stillChecking:
            PhotoFilterEmptyStateCopy(
                title: L10n.string("duplicates.checking_title"), description: L10n.string("duplicates.checking_wait"),
                systemImage: "hourglass")
        case .noDuplicates where uncheckedNote != nil:
            PhotoFilterEmptyStateCopy(
                title: PhotoFilter.duplicates.emptyStateCopy.title, description: uncheckedNote ?? "",
                systemImage: PhotoFilter.duplicates.emptyStateCopy.systemImage)
        default:
            PhotoFilter.duplicates.emptyStateCopy
        }
    }

    /// The title of `.loading`.
    public var loadingTitle: String { L10n.string("duplicates.loading") }

    /// The line of `.loading`: the visibility read of the scan, counted when its total is known.
    public var loadingLine: ProgressLine {
        guard let scanProgress, scanProgress.total > 0 else {
            return ProgressLine(title: loadingTitle, detail: nil, fraction: nil)
        }
        return ProgressLine(
            title: loadingTitle,
            detail: Self.photoCount(scanProgress.completed, of: scanProgress.total),
            fraction: Double(scanProgress.completed) / Double(scanProgress.total))
    }

    /// The counted progress of the library check, for example "1,234 of 15,000 photos". Nil without a total.
    public var checkProgressText: String? {
        guard case .counted(let completed, let total) = checkProgress else { return nil }
        return Self.photoCount(completed, of: total)
    }

    /// The line of a running library check. Nil while no build runs, and for a quick refresh of a complete index.
    public var checkLine: ProgressLine? {
        switch checkProgress {
        case .counted(let completed, let total):
            ProgressLine(
                title: L10n.string("duplicates.checking_title"), detail: checkProgressText,
                fraction: Double(completed) / Double(total))
        case .indeterminate where !isComplete:
            ProgressLine(title: L10n.string("duplicates.checking_title"), detail: nil, fraction: nil)
        case .indeterminate, nil:
            nil
        }
    }

    /// The progress of an active metadata check, including the ranking that a merge waits for.
    public var rankingLine: ProgressLine? {
        guard isRankingForMerge || (!hasInvalidatedGroups && !hasCheckedGroups), let rankingProgress else { return nil }
        let progress = rankingProgress
        guard progress.total > 0 else { return nil }
        let current = Double(progress.completed) / Double(progress.total)
        let fraction = isRankingForMerge ? current : max(rankingFraction, current)
        let detail = fraction.formatted(.percent.precision(.fractionLength(0)))
        return ProgressLine(title: L10n.string("duplicates.ranking_title"), detail: detail, fraction: fraction)
    }

    /// The checked groups while the remaining pages wait for scrolling or Merge All. Nil during active ranking.
    public var metadataCheckNote: String? {
        guard phase == .loaded, !hasInvalidatedGroups, !rankingFailed, !groups.isEmpty, !hasCheckedGroups,
            rankingProgress == nil
        else {
            return nil
        }
        return L10n.string(
            "duplicates.groups_checked \(groups.filter(\.isRanked).count.formatted()) \(groups.count.formatted())")
    }

    /// The line of Merge All, for example "320 of 1,404 groups". Nil outside Merge All and while it still ranks.
    public var mergeAllLine: ProgressLine? {
        guard let mergeAllProgress, mergeAllProgress.total > 0 else { return nil }
        let completed = mergeAllProgress.completed.formatted()
        let total = mergeAllProgress.total.formatted()
        return ProgressLine(
            title: L10n.string("duplicates.merging_title"),
            detail: L10n.string("duplicates.ranking_progress \(completed) \(total)"),
            fraction: Double(mergeAllProgress.completed) / Double(mergeAllProgress.total))
    }

    /// The person can stop Merge All: it runs and was not stopped yet.
    public var canStopMergeAll: Bool { isMergingAll && !isStoppingMergeAll }

    /// The note while the library is still being checked and groups are shown. Nil once the check finished.
    public var stillCheckingNote: String? {
        phase == .loaded && !isComplete && isBuilding ? L10n.string("duplicates.still_checking") : nil
    }

    /// One line after a finished check that could not read some photos. A retry cannot read them, so it has none.
    public var uncheckedNote: String? {
        guard phase == .loaded, !isBuilding, case .incomplete(let count) = coverage, count > 0 else { return nil }
        return L10n.string("duplicates.unchecked \(count)")
    }

    /// A scan, metadata read, or index build failed while groups are retained. A retry can finish the check.
    public var checkFailedNote: String? {
        guard !isMerging else { return nil }
        if phase == .failed, !groups.isEmpty { return L10n.string("duplicates.load_failed") }
        guard phase == .loaded, !isBuilding else { return nil }
        if rankingFailed { return L10n.string("duplicates.check_failed") }
        guard buildFailed, !isComplete else { return nil }
        return L10n.string("duplicates.check_failed")
    }

    /// The space that merging every group shown frees, counting the groups whose size is known. It grows while the
    /// check finds groups and while sizes become known.
    public var totalFreedBytes: Int64 { visibleGroups.reduce(0) { $0 + ($1.freedBytes ?? 0) } }

    /// The short text of `totalFreedBytes`. Merged duplicates wait in Recently Deleted, so the line says that the
    /// space is free only after that. Nil while no size is known.
    public var totalFreedText: String? {
        let total = totalFreedBytes
        return total > 0 ? L10n.string("duplicates.total_frees \(Self.byteText(total))") : nil
    }

    /// The system's file byte format, for example "4.2 MB".
    nonisolated public static func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// The groups in one page of the ranking. The screen ranks the page that it shows and the page after it.
    nonisolated static let rankingPageSize = 24
    /// The pause after the last group shown before its pages rank. The macOS list shows every section at once.
    nonisolated static let appearancePause: Duration = .milliseconds(150)
    /// The pages that wait for the ranking at most. Older pages that the screen scrolled past wait for their next
    /// appearance.
    nonisolated static let maximumQueuedPages = 4
    /// The groups that Merge All hands to the finder at once. The screen shows the outcome of each batch before the
    /// next one starts, and Stop waits for the running batch only.
    nonisolated static let mergeBatchSize = 25

    /// Every copy of every group shown, kept copies included.
    public var copyCount: Int { groups.reduce(0) { $0 + $1.members.count } }

    /// The number of copies shown, for example "14 identical copies". Nil until every group is checked and current,
    /// or while no groups remain.
    public var copyCountText: String? {
        hasCheckedGroups ? L10n.string("duplicates.copy_count \(copyCount)") : nil
    }

    /// The title and the text of the explanation beside `copyCountText`.
    public var infoTitle: String { L10n.string("duplicates.info_title") }
    public var infoMessage: String { L10n.string("duplicates.info_message") }

    /// The photos that Merge All moves to Recently Deleted.
    public var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicateCount } }

    private var hasCheckedGroups: Bool {
        !hasInvalidatedGroups && !groups.isEmpty && groups.allSatisfy(\.isRanked)
    }

    /// The count for the Duplicates entry. Nil until every remaining group passed the metadata check, or if empty.
    public var knownDuplicateCount: Int? {
        hasCheckedGroups ? duplicateCount : nil
    }

    public var canMerge: Bool {
        !isRetired && !isMerging && !isCheckingGroups && !hasInvalidatedGroups && phase != .loading && !groups.isEmpty
    }

    public var mergeAllTitle: String {
        hasCheckedGroups
            ? L10n.string("duplicates.merge_all_title \(copyCount)")
            : L10n.string("duplicates.merge_all_title_unchecked")
    }
    public var mergeAllMessage: String {
        hasCheckedGroups
            ? L10n.string("duplicates.merge_all_message \(duplicateCount)")
            : L10n.string("duplicates.merge_all_message_unchecked")
    }
    /// The short confirming button of the Merge All dialog; the title carries the count.
    public var mergeAllConfirmTitle: String { mergeTitle }

    /// The group with `id`. Nil after a merge removed it.
    public func group(withID id: String) -> Group? { groups.first { $0.id == id } }

    // MARK: - The viewer of a group

    /// The group that holds `member` now. A group can split while the viewer shows one of its photos, so every action
    /// of the viewer finds the group of the photo on screen when the person taps it.
    public func group(containing member: PhotoUID) -> Group? {
        groups.first { $0.members.contains(member) }
    }

    /// The title of the action that keeps `member`: "Keep This Copy", or "Kept" when a merge keeps it already.
    public func keepTitle(for member: PhotoUID) -> String {
        group(containing: member)?.keepTitle(for: member) ?? L10n.string("duplicates.keep_this_copy")
    }

    /// The symbol of the action that keeps `member`: a filled checkmark once a merge keeps it.
    public func keepSymbol(for member: PhotoUID) -> String {
        group(containing: member)?.kept == member ? "checkmark.circle.fill" : "checkmark.circle"
    }

    /// The person can keep `member` instead: it is in a group, not kept yet, and no merge runs.
    public func canKeep(_ member: PhotoUID) -> Bool {
        guard !isMerging, let group = group(containing: member) else { return false }
        return group.kept != member
    }

    /// Keeps `member` instead of the photo shown as kept in its group.
    public func keep(_ member: PhotoUID) {
        guard let groupID = group(containing: member)?.id else { return }
        keep(member, inGroup: groupID)
    }

    /// The title and the symbol of the action that merges a group.
    public var mergeTitle: String { L10n.string("duplicates.merge") }
    public var mergeSymbol: String { "arrow.triangle.merge" }

    /// The group of `member` can be merged now: the photo is still in a group, and no merge or load runs.
    public func canMerge(containing member: PhotoUID) -> Bool {
        canMerge && group(containing: member) != nil
    }

    /// Merges the group that holds `member` now, with the photo shown as kept.
    public func merge(containing member: PhotoUID) async {
        guard let groupID = group(containing: member)?.id else { return }
        await merge(groupID: groupID)
    }

    /// The photos to show in the viewer when the person opens `member`: the members of its group that `item` finds,
    /// in the order of the group, and the position of `member` among them. Nil while `item` does not find `member`,
    /// for example right after launch before the library shows it.
    public func viewerItems(
        opening member: PhotoUID, inGroup groupID: String, item: (PhotoUID) -> PhotoItem?
    ) -> (items: [PhotoItem], index: Int)? {
        guard let members = group(withID: groupID)?.members, members.contains(member) else { return nil }
        let items = members.compactMap(item)
        guard let index = items.firstIndex(where: { $0.uid == member }) else { return nil }
        return (items, index)
    }

    /// The person moved photos to Recently Deleted elsewhere, for example in the viewer. They leave their groups at
    /// once; a group with fewer than two copies left leaves the list, and a trashed checked copy hands the checkmark
    /// to the next copy.
    public func didTrashElsewhere(_ uids: [PhotoUID]) {
        let trashed = Set(uids)
        guard groups.contains(where: { group in group.members.contains(where: trashed.contains) }) else { return }
        var updated = groups
        for index in updated.indices.reversed() where updated[index].members.contains(where: trashed.contains) {
            let reason = updated[index].keptReason
            let keptLeft = trashed.contains(updated[index].kept)
            if !updated[index].remove(Array(trashed), keptReason: reason) {
                updated.remove(at: index)
            } else if keptLeft {
                // The chosen photo is gone; the next copy is kept until the person chooses again.
                updated[index].isKeptChosen = false
            }
        }
        groups = updated
    }

    /// Reads the groups, then ranks the first two pages, or every page for an open screen, and brings the content
    /// index up to date at the same time. Reads the groups again when the index changed. A choice of the person and
    /// the ranking of a group with the same members stay, so a screen that opens again reads nothing for them.
    public func load(checkAllGroups: Bool = false) async {
        guard !isRetired else { return }
        if checkAllGroups {
            checksAllGroups = true
            hasOpenedScreen = true
        }
        guard !isMerging else { return }
        rankingFailed = false
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration, ranking == nil { isCheckingGroups = false } }
        phase = .loading
        restartedAfterInterruption = false
        checkInterrupted = false
        rescanAfterMerge = false
        stopRanking()
        isCheckingGroups = checksAllGroups
        guard await scan(generation: generation) else { return }
        async let ranked: Void = rank(around: 0)
        async let built: Void = buildAndRescan(generation: generation)
        _ = await (ranked, built)
    }

    /// The screen shows the group. After a short pause without another group shown, ranks the pages of the first and
    /// of the last group shown since the last pause, each with the page after it, unless they are ranked. A list that
    /// shows many sections at once, as on macOS, ranks around those two only.
    public func groupAppeared(_ groupID: String) {
        appearedGroupIDs.insert(groupID)
        appearances &+= 1
        guard appearanceFollower == nil else { return }
        appearanceFollower = Task { [weak self] in await self?.followAppearances() }
    }

    private func followAppearances() async {
        var seen: Int?
        while seen != appearances {
            seen = appearances
            try? await Task.sleep(for: Self.appearancePause)
            // A load stopped this follower and may have started the next one.
            if Task.isCancelled { return }
        }
        appearanceFollower = nil
        let shown = groups.indices.filter { appearedGroupIDs.contains(groups[$0].id) }
        appearedGroupIDs = []
        guard let first = shown.first, let last = shown.last else { return }
        _ = requestRanking(around: [first, last])
    }

    /// The screen went away. Stops its metadata check and appearance follower; a merge keeps running.
    public func screenDisappeared() {
        checksAllGroups = false
        isCheckingGroups = false
        stopFollowingAppearances()
        rankingPublication.cancel(ranking, token: rankingWorkerToken)
    }

    private func stopFollowingAppearances() {
        appearanceFollower?.cancel()
        appearanceFollower = nil
        appearedGroupIDs = []
    }

    /// Reads the groups and shows them in the fallback order. A group with the same members keeps its ranking and the
    /// choice of the person. False when the read failed or a newer load replaced this one.
    private func scan(generation: Int) async -> Bool {
        let report: @Sendable (ExactDuplicateScanProgress) async -> Void = { [weak self] progress in
            await self?.showScan(progress, generation: generation)
        }
        var published = false
        defer {
            if generation == loadGeneration {
                scanProgress = nil
                if !published, ranking == nil { isCheckingGroups = false }
            }
        }
        do {
            let scan = try await finder.duplicateGroups(progress: report)
            let fallback = await finder.fallbackMembers(of: scan.groups)
            let dates = await finder.captureDates(of: scan.groups.flatMap(\.members))
            guard generation == loadGeneration, !isMerging else { return false }
            let earlier = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let earlierByHash = Dictionary(grouping: groups, by: \.scanGroup.contentHash)
            var shown: [Group] = []
            shown.reserveCapacity(scan.groups.count)
            var usedIDs: Set<String> = []
            for scanned in scan.groups {
                let order = fallback[scanned.id] ?? scanned.members
                for part in knownParts(of: scanned, earlier: earlier, avoiding: usedIDs) {
                    let groupDates = Dictionary(
                        part.members.compactMap { member in dates[member].map { (member, $0) } },
                        uniquingKeysWith: { first, _ in first })
                    let size = scan.byteSizes[part.contentHash]
                    // A group keeps its ranking and the person's choice while its members and metadata stay, also when
                    // another part of its bytes took its place meanwhile, for example after that part merged.
                    let isSame = { (earlier: Group) in
                        Set(earlier.members) == Set(part.members) && earlier.scanGroup.fingerprint == part.fingerprint
                    }
                    let same =
                        earlier[part.id].flatMap { isSame($0) ? $0 : nil }
                        ?? earlierByHash[part.contentHash]?.first(where: isSame)
                    let group = Self.unique(part, preferring: same?.id ?? part.id, used: &usedIDs)
                    if let same {
                        var kept = same
                        kept.scanGroup = group
                        kept.byteSize = size ?? same.byteSize
                        kept.captureDates.merge(groupDates) { _, new in new }
                        shown.append(kept)
                        continue
                    }
                    let members =
                        group.members.count == order.count ? order : order.filter(Set(group.members).contains)
                    let choice = earlier[group.id].flatMap {
                        $0.isKeptChosen && members.contains($0.kept) ? $0.kept : nil
                    }
                    var new = Group(scanGroup: group, members: members, kept: choice ?? members[0])
                    new.isKeptChosen = choice != nil
                    new.byteSize = size ?? earlier[group.id]?.byteSize
                    new.captureDates = groupDates
                    shown.append(new)
                }
            }
            groups = shown
            // A hash whose members changed needs another verdict, even if it was checked before this rescan.
            rankingRequested.formIntersection(Set(rankingQueue).union(shown.filter(\.isRanked).map(\.id)))
            hasInvalidatedGroups = false
            coverage = scan.coverage
            phase = .loaded
            // A background rescan keeps the checked list until it actually finds candidates that need checking.
            isCheckingGroups = checksAllGroups && (ranking != nil || shown.contains { !$0.isRanked })
            published = true
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            isCheckingGroups = checksAllGroups && ranking != nil
            phase = .failed
            return false
        }
    }

    /// The parts of a scanned group by the metadata that a ranking read already, so a screen that opens again reads
    /// nothing for them. The whole group while the metadata of a member are unknown.
    private func knownParts(
        of scanned: ExactDuplicateGroup, earlier: [String: Group], avoiding used: Set<String>
    ) -> [ExactDuplicateGroup] {
        guard !knownFingerprints.isEmpty, scanned.members.allSatisfy({ knownFingerprints[$0] != nil }) else {
            return [scanned]
        }
        return scanned.split(by: knownFingerprints, keepingIDWith: earlier[scanned.id]?.kept, avoiding: used)
    }

    /// `group` under `preferred`, else under its own ID, else under an ID from its first member, whichever no group in
    /// `used` has. Adds the ID to `used`.
    private static func unique(
        _ group: ExactDuplicateGroup, preferring preferred: String, used: inout Set<String>
    ) -> ExactDuplicateGroup {
        let id = [preferred, group.id].first { !used.contains($0) } ?? "\(group.id)#\(group.members[0].nodeID)"
        used.insert(id)
        return id == group.id ? group : group.withID(id)
    }

    private func showScan(_ progress: ExactDuplicateScanProgress, generation: Int) {
        guard generation == loadGeneration, phase == .loading else { return }
        scanProgress = progress
    }

    /// Ranks the page of the group at `index` and the page after it, and waits for that ranking.
    private func rank(around index: Int) async {
        guard let task = requestRanking(around: [index]) else { return }
        let publication = rankingPublication
        let token = rankingWorkerToken
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            publication.cancel(task, token: token)
        }
    }

    /// Queues the unranked groups of two pages from the page of each of `indices`. Returns the ranking that reads them.
    private func requestRanking(around indices: [Int]) -> Task<Void, Never>? {
        guard !isRetired, !hasOpenedScreen || checksAllGroups else { return nil }
        let size = Self.rankingPageSize
        // The screen checks every page without needing an unchecked row to appear. The existing worker still
        // reads one page at a time, with the finder's unchanged concurrency.
        let pages = checksAllGroups ? Array(stride(from: 0, to: groups.count, by: 2 * size)) : indices
        var wanted: [String] = []
        var wantedIDs: Set<String> = []
        for index in pages {
            let start = index / size * size
            for group in groups[start..<min(start + 2 * size, groups.count)]
            where !group.isRanked && !rankingRequested.contains(group.id) && wantedIDs.insert(group.id).inserted {
                wanted.append(group.id)
            }
        }
        guard !wanted.isEmpty else {
            if ranking == nil { isCheckingGroups = false }
            return ranking
        }
        rankingRequested.formUnion(wanted)
        rankingQueue += wanted
        // The oldest queued groups give way, never those of this request; the screen requests them again when it
        // shows them again.
        let kept = checksAllGroups ? rankingQueue.count : max(Self.maximumQueuedPages * size, wanted.count)
        let dropped = rankingQueue.prefix(max(0, rankingQueue.count - kept))
        rankingRequested.subtract(dropped)
        rankingQueue.removeFirst(dropped.count)
        if let ranking {
            if rankingToken == rankingWorkerToken, let progress = rankingProgress {
                rankingProgress = ExactDuplicateScanProgress(
                    completed: progress.completed, total: progress.total + wanted.count - dropped.count)
            }
            return ranking
        }
        let token = UUID()
        rankingWorkerToken = token
        rankingTaskToken = token
        // During a merge its own progress row stays; the scroll ranking runs without one.
        if !isMerging {
            rankingToken = token
            // Freeze the workload before splitting or dropping groups. Each attempted candidate counts once,
            // including unreadable candidates; disappearing groups cannot move progress backwards.
            let checked = checksAllGroups ? groups.filter(\.isRanked).count : 0
            rankingFraction = 0
            rankingProgress = ExactDuplicateScanProgress(completed: checked, total: checked + wanted.count)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainRankingQueue(token: token)
        }
        ranking = task
        return task
    }

    /// Ranks the queued groups page by page until the queue is empty or the ranking is cancelled.
    private func drainRankingQueue(token: UUID) async {
        let finder = finder
        while !Task.isCancelled, !rankingQueue.isEmpty {
            let ids = Array(rankingQueue.prefix(Self.rankingPageSize))
            rankingQueue.removeFirst(ids.count)
            let page = ids.compactMap { id in groups.first { $0.id == id && !$0.isRanked }?.scanGroup }
            if page.count < ids.count {
                apply(ExactDuplicateRankingPage(members: [:], groupCount: ids.count - page.count), token: token)
            }
            guard !page.isEmpty else { continue }
            let apply: @Sendable (ExactDuplicateRankingPage) async -> Void = { [weak self] ranked in
                await self?.apply(ranked, token: token)
            }
            await finder.rankMembers(of: page, ranked: apply)
        }
        guard rankingTaskToken == token else { return }
        if Task.isCancelled {
            // A closed screen stops the ranking. Groups that it did not rank can be requested again.
            let ranked = Set(groups.filter(\.isRanked).map(\.id))
            rankingRequested.formIntersection(ranked)
        }
        if !Task.isCancelled {
            rankingFailed = groups.contains { !$0.isRanked && rankingRequested.contains($0.id) }
        }
        ranking = nil
        rankingQueue = []
        rankingWorkerToken = nil
        rankingTaskToken = nil
        isCheckingGroups = false
        if rankingToken == token { rankingProgress = nil }
    }

    /// Stops the ranking. A group that it did not read can be requested again.
    private func stopRanking() {
        isCheckingGroups = false
        stopFollowingAppearances()
        rankingPublication.cancel(ranking, token: rankingWorkerToken)
        ranking = nil
        rankingQueue = []
        rankingRequested = []
        rankingWorkerToken = nil
        rankingTaskToken = nil
        rankingToken = UUID()
        rankingProgress = nil
    }

    /// Takes the ranked order, the size, and the metadata of each group in `page`. Only copies with equal metadata
    /// stay one group: a group splits in place, and leaves when no two copies match. The part with the photo shown
    /// as kept keeps the group's ID and the person's choice. Only active rankings can publish a page.
    private func apply(_ page: ExactDuplicateRankingPage, token: UUID) {
        guard rankingPublication.owns(token) else { return }
        if token == rankingToken || token == mergeRankingToken, let progress = rankingProgress {
            rankingProgress = ExactDuplicateScanProgress(
                completed: min(progress.completed + page.groupCount, progress.total), total: progress.total)
            if !isRankingForMerge, progress.total > 0 {
                // An index rescan can add work to this worker; hold its displayed percentage until it catches up.
                rankingFraction = max(
                    rankingFraction,
                    Double(min(progress.completed + page.groupCount, progress.total)) / Double(progress.total))
            }
        }
        // The whole page is one change of the screen, not one change for each of its groups.
        var updated = groups
        let positions = Self.positions(of: updated)
        var changed = false
        // The sizes first, so the parts of a split group take them.
        for (id, size) in page.byteSizes {
            guard let index = positions[id], updated[index].byteSize == nil else { continue }
            updated[index].byteSize = size
            changed = true
        }
        var replacements: [Int: [Group]] = [:]
        var usedIDs = Set(positions.keys)
        for (id, order) in page.members {
            // Without the metadata of its copies, the group stays whole and unranked, so no merge takes it.
            guard let index = positions[id], let fingerprints = page.fingerprints[id] else { continue }
            let shownKept = updated[index].kept
            knownFingerprints.merge(fingerprints) { _, new in new }
            var parts = updated[index].parts(by: fingerprints, avoiding: usedIDs)
            usedIDs.formUnion(parts.map(\.id))
            for position in parts.indices {
                let showsKept = parts[position].kept == shownKept
                parts[position].rank(
                    order, shared: page.shared[id] ?? [], facts: page.facts[id] ?? [:],
                    sizes: page.memberByteSizes[id] ?? [:])
                if showsKept, mergingGroupIDs.contains(parts[position].id) { parts[position].kept = shownKept }
            }
            replacements[index] = parts
            changed = true
        }
        if !replacements.isEmpty { updated = updated.indices.flatMap { replacements[$0] ?? [updated[$0]] } }
        if changed { groups = updated }
    }

    /// The position of each group by its ID.
    private static func positions(of groups: [Group]) -> [String: Int] {
        Dictionary(groups.indices.map { (groups[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func buildAndRescan(generation: Int) async {
        guard !isRetired, generation == loadGeneration else { return }
        let changed: Bool
        do {
            changed = try await buildIndex()
            buildFailed = false
            checkInterrupted = false
        } catch is CancellationError where !Task.isCancelled {
            // The service stopped the build. Restart once now, or after the active merge.
            guard generation == loadGeneration else { return }
            checkInterrupted = true
            if !isMerging, !restartedAfterInterruption {
                restartedAfterInterruption = true
                await buildAndRescan(generation: generation)
            } else if !isMerging {
                failBuild()
            }
            return
        } catch {
            guard generation == loadGeneration else { return }
            failBuild()
            return
        }
        guard generation == loadGeneration else { return }
        if changed {
            guard !isMerging, await scan(generation: generation) else {
                // A merge holds the list; the groups are read again after it.
                if isMerging { rescanAfterMerge = true }
                return
            }
            await rank(around: 0)
        } else if isMerging {
            return
        } else if case .indexing = coverage {
            // The build finished and left no index: waiting longer cannot help, a retry can.
            buildFailed = true
            if groups.isEmpty { phase = .failed }
        }
    }

    private func failBuild() {
        buildFailed = true
        // Retain shown groups; outside a merge, an empty unfinished library offers Retry instead of waiting.
        if !isMerging, groups.isEmpty, !isComplete { phase = .failed }
    }

    /// Runs the build of the content index, or waits for the build that already runs.
    private func buildIndex() async throws -> Bool {
        if let indexBuild { return try await indexBuild.value }
        let finder = finder
        let report: @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { [weak self] progress in
            await self?.show(progress)
        }
        let build = Task { try await finder.prepareIndex(progress: report) }
        indexBuild = build
        checkProgress = .indeterminate
        defer {
            indexBuild = nil
            checkProgress = nil
        }
        return try await build.value
    }

    private func show(_ progress: UploadRemoteIndexPreparationProgress) {
        guard indexBuild != nil, progress.phase != .ready else { return }
        if let total = progress.total, total > 0 {
            checkProgress = .counted(completed: min(progress.completed, total), total: total)
        } else {
            checkProgress = .indeterminate
        }
    }

    private static func photoCount(_ completed: Int, of total: Int) -> String {
        L10n.string("duplicates.checking_progress \(completed.formatted()) \(total.formatted())")
    }

    /// Entry counts come from the checked screen state. An unchecked entry scan cannot supply a displayable count.
    public func loadCountIfNeeded() async {}

    /// Keeps `uid` instead of the ranked photo when the group is merged.
    public func keep(_ uid: PhotoUID, inGroup groupID: String) {
        guard !isMerging, let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].members.contains(uid)
        else { return }
        var group = groups[index]
        group.kept = uid
        group.isKeptChosen = true
        groups[index] = group
    }

    /// Merges one group and keeps the photo that the screen shows as kept, or, in a group that is not ranked yet,
    /// the copy that the rule ranks first. A photo that the screen preselected stays a preselection for the finder,
    /// which keeps it only while it still ranks first.
    public func merge(groupID: String) async {
        guard canMerge, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        await merge([groups[index]], all: false)
    }

    /// Merges every group shown, batch by batch, with progress. The screen shows the outcome of each batch before the
    /// next one starts. The run stops after the running batch when the person stops it, and after a batch in which no
    /// group merged, for example without a connection. A run does not survive the app: it never resumes after a quit.
    public func mergeAll() async {
        guard canMerge else { return }
        await merge(groups, all: true)
    }

    /// Ends this account's ownership. A running batch finishes; no queued action can start another merge.
    func retire() {
        isRetired = true
        // Invalidate suspended reads without cancelling the joined index build.
        loadGeneration += 1
        rescanAfterMerge = false
        stopRanking()
        rankingPublication.cancel(mergeRanking, token: mergeRankingToken)
        stopMergeAll()
    }

    /// Stops Merge All. The running batch finishes; a running ranking stops, and then nothing merges. The groups that
    /// did not merge stay.
    public func stopMergeAll() {
        guard canStopMergeAll else { return }
        isStoppingMergeAll = true
        rankingPublication.cancel(mergeRanking, token: mergeRankingToken)
        // A paused run wakes up to stop.
        wakeMergeResumers()
    }

    /// Merge All starts no further batch until `resumeMerging()`, and its ranking stops until then. The pause applies at
    /// once, so a `resumeMerging()` that follows always wins.
    public func pauseMerging() {
        guard isMergingAll else { return }
        isMergePaused = true
        if let mergeRanking {
            mergeRankingInterrupted = true
            rankingPublication.cancel(mergeRanking, token: mergeRankingToken)
        }
    }

    /// Returns when no batch of a merge and no stopped ranking runs any more, so the platform can hold the app awake
    /// until then.
    public func runningMergeWorkEnded() async {
        if let mergeRanking { await mergeRanking.value }
        while isMergeBatchRunning {
            await withCheckedContinuation { batchWaiters.append($0) }
        }
    }

    /// Continues a paused Merge All.
    public func resumeMerging() {
        isMergePaused = false
        wakeMergeResumers()
    }

    private func wakeMergeResumers() {
        let resumers = mergeResumers.values
        mergeResumers = [:]
        resumers.forEach { $0.resume() }
    }

    private func waitWhileMergePaused() async {
        while isMergePaused, !isStoppingMergeAll, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    mergeResumers[id] = continuation
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    // Removal makes cancellation, resume and stop retire this waiter only once.
                    self?.mergeResumers.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    /// Merges `requested`. Every group reads the metadata of its copies first, because only copies with equal
    /// metadata merge. With `all`, every part of a requested group merges; otherwise a group that split or changed
    /// its kept photo meanwhile stays, so the person sees it first. A group whose metadata could not be read stays,
    /// and the merge reports a failure. A group that was not ranked and whose photo the person did not choose follows
    /// its ranking. With `all`, the groups merge in batches with progress, and the run can stop.
    private func merge(_ requested: [Group], all: Bool) async {
        isMerging = true
        isMergingAll = all
        notice = nil
        // The groups that nobody scrolled to rank page by page, with progress. The merge keeps the copy that the rule
        // ranks first in such a group, as every device does: the person saw no preselection there, only the order
        // that needs no request. A photo that the person chose stays.
        let unranked = requested.filter { !$0.isRanked }.map(\.scanGroup)
        if !unranked.isEmpty {
            let token = UUID()
            rankingToken = token
            rankingProgress = ExactDuplicateScanProgress(completed: 0, total: unranked.count)
            isRankingForMerge = true
            await rankForMerge(unranked)
            isRankingForMerge = false
            if rankingToken == token { rankingProgress = nil }
        }
        let requestedHashes = Set(requested.map(\.scanGroup.contentHash))
        let requestedByID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = groups.filter { group in
            if all { return requestedHashes.contains(group.scanGroup.contentHash) }
            guard let request = requestedByID[group.id] else { return false }
            let followsRanking = !request.isRanked && !request.isKeptChosen
            return Set(request.members) == Set(group.members) && (followsRanking || request.kept == group.kept)
        }
        // Never a group whose metadata are unknown.
        let selected = candidates.filter { $0.isRanked && $0.scanGroup.fingerprint != nil }
        mergingGroupIDs = Set(selected.map(\.id))
        var kept: [PhotoUID: ExactDuplicateKeepReason] = [:]
        var keptPhotoUnreadable = false
        var failed = selected.count < candidates.count
        var stale = false
        var stopped = false
        var mergedGroups = 0
        var handled = 0
        if all { mergeAllProgress = ExactDuplicateScanProgress(completed: 0, total: selected.count) }
        // One favorites listing and one album listing serve every batch.
        let run = ExactDuplicateMergeRun(members: selected.flatMap(\.scanGroup.members))
        while handled < selected.count {
            if all {
                await waitWhileMergePaused()
                // A stop during the ranking merges nothing.
                if isStoppingMergeAll || Task.isCancelled {
                    stopped = true
                    break
                }
            }
            if isRetired {
                stopped = true
                break
            }
            let batch = selected[handled..<min(handled + Self.mergeBatchSize, selected.count)]
            handled += batch.count
            isMergeBatchRunning = true
            let results = await finder.merge(
                batch.map {
                    ExactDuplicateMergeRequest(
                        group: $0.scanGroup, kept: $0.kept, isKeptChosen: $0.isKeptChosen)
                }, in: run)
            isMergeBatchRunning = false
            let waiters = batchWaiters
            batchWaiters = []
            waiters.forEach { $0.resume() }
            // The outcome of every group of the batch is one change of the screen.
            var updated = groups
            var trashed: [PhotoUID] = []
            for (group, result) in zip(batch, results) {
                do {
                    switch try result.get() {
                    case .merged(let keptPhoto, let moved, let keptDuplicates):
                        mergedGroups += 1
                        trashed += moved
                        kept.merge(keptDuplicates) { first, _ in first }
                        if keptDuplicates.values.contains(.differentDetails) {
                            // The metadata changed since the ranking read them; a new scan reads them again.
                            forgetFingerprints(of: group)
                            stale = true
                        }
                        // A group with a duplicate left keeps its reason, so the person can keep another photo instead.
                        if let index = updated.firstIndex(where: { $0.id == group.id }) {
                            if updated[index].remove(moved, keptReason: Self.firstReason(in: keptDuplicates.values)) {
                                if updated[index].members.contains(keptPhoto) { updated[index].kept = keptPhoto }
                            } else {
                                updated.remove(at: index)
                            }
                        }
                    case .skipped(.keptUnreadable):
                        keptPhotoUnreadable = true
                    case .skipped:
                        // The library changed since the scan; a new scan shows what is left.
                        forgetFingerprints(of: group)
                        stale = true
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failed = true
                }
            }
            if updated != groups { groups = updated }
            if !trashed.isEmpty { await didTrash(trashed) }
            guard all else { continue }
            mergeAllProgress = ExactDuplicateScanProgress(completed: handled, total: selected.count)
            // No group of the batch merged, for example without a connection: the next batch would fail, too.
            if !results.isEmpty, !results.contains(where: { (try? $0.get()) != nil }), handled < selected.count {
                stopped = true
                break
            }
        }
        // A stop before the ranking reported a page leaves no group to merge, and the run still ends as stopped.
        if all, isStoppingMergeAll || Task.isCancelled, mergedGroups < candidates.count { stopped = true }
        mergingGroupIDs = []
        isMerging = false
        isMergingAll = false
        isStoppingMergeAll = false
        isMergePaused = false
        mergeAllProgress = nil
        wakeMergeResumers()
        notice =
            stopped
            ? .stopped(merged: mergedGroups, total: candidates.count)
            : Self.notice(kept: kept, keptPhotoUnreadable: keptPhotoUnreadable, failed: failed)
        guard !isRetired else { return }
        if stale {
            await load()
            return
        }
        let generation = loadGeneration
        if rescanAfterMerge {
            rescanAfterMerge = false
            if await scan(generation: generation) { await rank(around: 0) }
        }
        if checkInterrupted, !isComplete, indexBuild == nil {
            // The check was stopped while the merge ran. It starts again and shows its progress.
            checkInterrupted = false
            Task { await self.buildAndRescan(generation: generation) }
        }
    }

    /// Ranks `unranked` for a merge. A pause cancels the ranking; after the pause, the groups that it did not rank
    /// rank again. A stop ends it.
    private func rankForMerge(_ unranked: [ExactDuplicateGroup]) async {
        let finder = finder
        let publication = rankingPublication
        var pending = unranked
        while !pending.isEmpty {
            await waitWhileMergePaused()
            if isStoppingMergeAll || Task.isCancelled { return }
            mergeRankingInterrupted = false
            let page = pending
            let token = UUID()
            let apply: @Sendable (ExactDuplicateRankingPage) async -> Void = { [weak self] page in
                await self?.apply(page, token: token)
            }
            let task = Task { await finder.rankMembers(of: page, ranked: apply) }
            mergeRankingToken = token
            mergeRanking = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                publication.cancel(task, token: token)
            }
            mergeRanking = nil
            publication.revoke(token)
            // Only a pause ranks again; a group whose facts cannot be read stays unranked.
            guard mergeRankingInterrupted, !isStoppingMergeAll, !Task.isCancelled else { return }
            let unrankedIDs = Set(groups.filter { !$0.isRanked }.map(\.id))
            pending = pending.filter { unrankedIDs.contains($0.id) }
        }
    }

    /// A scroll page that read the metadata before the merge can still publish while the merge reports its trash, before
    /// the reload stops the ranking. Its publication ends first, so no old metadata come back. The worker keeps running;
    /// its pages no longer publish until the reload stops it, or until it ends on its own.
    private func forgetFingerprints(of group: Group) {
        rankingPublication.revoke(rankingWorkerToken)
        hasInvalidatedGroups = true
        for member in group.scanGroup.members { knownFingerprints[member] = nil }
    }

    /// One reason only: a failure first, then the unreadable photo to keep, then the kept duplicates.
    private static func notice(
        kept: [PhotoUID: ExactDuplicateKeepReason], keptPhotoUnreadable: Bool, failed: Bool
    ) -> ExactDuplicateMergeNotice? {
        if failed { return .failed }
        if keptPhotoUnreadable { return .keptPhotoUnreadable }
        guard let reason = firstReason(in: kept.values) else { return nil }
        return .keptDuplicates(count: kept.count, reason: reason)
    }

    /// The first of `reasons` in a fixed order. Nil when `reasons` is empty.
    private static func firstReason(
        in reasons: some Collection<ExactDuplicateKeepReason>
    ) -> ExactDuplicateKeepReason? {
        let order: [ExactDuplicateKeepReason] = [
            .differentDetails, .relatedFileWithoutTwin, .pendingEditReplacement, .neededByLocalSource, .shared,
            .unreadable,
        ]
        return order.first(where: reasons.contains)
    }
}
