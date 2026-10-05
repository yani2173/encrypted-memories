import Foundation
import Observation
import PhotosCore

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
    /// Ranks the members of each group, page by page. A group whose facts cannot be read is not in its page.
    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async
    /// Merges each group, keeping its photo. One result for each group, in order. After a cancellation, the groups
    /// without an outcome fail with `CancellationError`.
    func merge(
        _ requests: [(group: ExactDuplicateGroup, kept: PhotoUID)]
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>]
}

extension ExactDuplicateFinder: ExactDuplicateMerging {}

/// One short message after a merge that did not move every duplicate to Recently Deleted.
public enum ExactDuplicateMergeNotice: Equatable, Sendable {
    /// `count` duplicates stayed in the library. `reason` is the first of their reasons in a fixed order.
    case keptDuplicates(count: Int, reason: ExactDuplicateKeepReason)
    /// The server did not return the complete photo to keep.
    case keptPhotoUnreadable
    /// A merge failed, for example without a connection.
    case failed

    public var title: String {
        switch self {
        case .keptDuplicates(let count, _): L10n.string("duplicates.kept_title \(count)")
        case .keptPhotoUnreadable: L10n.string("duplicates.not_merged_title")
        case .failed: L10n.string("duplicates.merge_failed_title")
        }
    }

    public var message: String {
        switch self {
        case .keptDuplicates(_, .relatedFileWithoutTwin): L10n.string("duplicates.kept_reason_related_file")
        case .keptDuplicates(_, .pendingEditReplacement): L10n.string("duplicates.kept_reason_pending_edit")
        case .keptDuplicates(_, .neededByLocalSource): L10n.string("duplicates.kept_reason_needed_here")
        case .keptDuplicates(_, .shared): L10n.string("duplicates.kept_reason_shared")
        case .keptDuplicates(_, .unreadable): L10n.string("duplicates.kept_reason_unreadable")
        case .keptPhotoUnreadable: L10n.string("duplicates.kept_photo_unreadable")
        case .failed: L10n.string("duplicates.merge_failed_message")
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
        /// The photos that a merge moves to Recently Deleted.
        public var duplicateCount: Int { members.count - 1 }

        /// The space that the merge frees: the copies hold the same bytes, so one size for each duplicate.
        public var freedBytes: Int64? { byteSize.map { $0 * Int64(duplicateCount) } }

        /// The short text of `freedBytes`, for example "Frees 4.2 MB". Nil while the size is unknown.
        public var freedText: String? {
            freedBytes.map { L10n.string("duplicates.group_frees \(ExactDuplicatesModel.byteText($0))") }
        }

        /// The short text of `keptReason`, for example below the group.
        public var keptReasonMessage: String? {
            keptReason.map { ExactDuplicateMergeNotice.keptDuplicates(count: duplicateCount, reason: $0).message }
        }

        /// Drops the photos that a merge moved to Recently Deleted. False when fewer than two members remain.
        mutating func remove(_ trashed: [PhotoUID], keptReason reason: ExactDuplicateKeepReason?) -> Bool {
            let remaining = members.filter { !trashed.contains($0) }
            guard remaining.count > 1 else { return false }
            members = remaining
            scanGroup = ExactDuplicateGroup(
                contentHash: scanGroup.contentHash, hashKeyEpoch: scanGroup.hashKeyEpoch,
                members: scanGroup.members.filter { !trashed.contains($0) })
            if !remaining.contains(kept) { kept = remaining[0] }
            keptReason = reason
            return true
        }

        /// Takes the ranked order. The photo to keep follows it unless the person chose one. With `keepsShown`, the
        /// photo that the screen already shows as kept stays, unless another member is shared and it is not: a merge
        /// keeps every shared member, so the shared one is kept and shown.
        mutating func rank(_ order: [PhotoUID], shared: Set<PhotoUID>, keepsShown: Bool) {
            let current = Set(members)
            let ranked = order.filter(current.contains)
            members = ranked + members.filter { !ranked.contains($0) }
            sharedMembers = shared.intersection(current)
            isRanked = true
            guard !isKeptChosen else { return }
            if !keepsShown {
                kept = members[0]
            } else if !sharedMembers.contains(kept), let firstShared = members.first(where: sharedMembers.contains) {
                kept = firstShared
            }
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

    public private(set) var groups: [Group] = []
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
    private var phase = Phase.idle
    /// The last build failed, or it finished without an index.
    private var buildFailed = false
    /// The service stopped the last build, for example for a full refresh. The check restarts, after a merge at once.
    @ObservationIgnored private var checkInterrupted = false
    /// The check restarted after an interruption in this load. A further interruption waits for a merge or a load.
    @ObservationIgnored private var restartedAfterInterruption = false
    /// The build finished during a merge with a changed index; the screen reads the groups again after the merge.
    @ObservationIgnored private var rescanAfterMerge = false
    private var scannedDuplicateCount: Int?
    private var loadGeneration = 0
    /// The one build of this model. A load while it runs waits for it, and a closed screen leaves it running: the
    /// backup uses the same build, and the build resumes from its checkpoint.
    @ObservationIgnored private var indexBuild: Task<Bool, any Error>?
    /// The ranking of the last load. A new load cancels it.
    @ObservationIgnored private var ranking: Task<Void, Never>?
    /// The groups that wait for the ranking, in the order the screen showed them.
    @ObservationIgnored private var rankingQueue: [String] = []
    /// The groups that the ranking of this load has read or queued. A failed group waits for the next load or a merge.
    @ObservationIgnored private var rankingRequested: Set<String> = []
    /// Identifies the running scroll ranking. A merge shows its own progress, so it never owns this ranking.
    @ObservationIgnored private var rankingWorkerToken: UUID?
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
        switch phase {
        case .idle, .loading: groups.isEmpty ? .loading : .groups
        case .failed: groups.isEmpty ? .failed(L10n.string("duplicates.load_failed")) : .groups
        case .loaded:
            if !groups.isEmpty {
                .groups
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

    /// The line of a running ranking, for example "40 of 1,545 groups". Nil while no ranking runs.
    public var rankingLine: ProgressLine? {
        guard let rankingProgress, rankingProgress.total > 0 else { return nil }
        let completed = rankingProgress.completed.formatted()
        let total = rankingProgress.total.formatted()
        return ProgressLine(
            title: L10n.string("duplicates.ranking_title"),
            detail: L10n.string("duplicates.ranking_progress \(completed) \(total)"),
            fraction: Double(rankingProgress.completed) / Double(rankingProgress.total))
    }

    /// The note while the library is still being checked and groups are shown. Nil once the check finished.
    public var stillCheckingNote: String? {
        phase == .loaded && !isComplete && isBuilding ? L10n.string("duplicates.still_checking") : nil
    }

    /// One line after a finished check that could not read some photos. A retry cannot read them, so it has none.
    public var uncheckedNote: String? {
        guard phase == .loaded, !isBuilding, case .incomplete(let count) = coverage, count > 0 else { return nil }
        return L10n.string("duplicates.unchecked \(count)")
    }

    /// The check stopped without an index while groups are shown. A retry can finish it.
    public var checkFailedNote: String? {
        guard phase == .loaded, !isBuilding, buildFailed, case .indexing = coverage else { return nil }
        return L10n.string("duplicates.check_failed")
    }

    /// The space that merging every group shown frees, counting the groups whose size is known. It grows while the
    /// check finds groups and while sizes become known.
    public var totalFreedBytes: Int64 { groups.reduce(0) { $0 + ($1.freedBytes ?? 0) } }

    /// The short text of `totalFreedBytes`. Nil while no size is known.
    public var totalFreedText: String? {
        let total = totalFreedBytes
        return total > 0 ? L10n.string("duplicates.total_frees \(Self.byteText(total))") : nil
    }

    /// One line below the total: merged duplicates wait in Recently Deleted, so the space is free only after that.
    /// Nil without a total.
    public var totalFreedNote: String? {
        totalFreedText == nil ? nil : L10n.string("duplicates.freed_when_emptied")
    }

    /// The system's file byte format, for example "4.2 MB".
    nonisolated static func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// The groups in one page of the ranking. The screen ranks the page that it shows and the page after it.
    nonisolated static let rankingPageSize = 24

    /// The number of groups found, for example "1,545 Groups". Nil without a group.
    public var groupCountText: String? {
        groups.isEmpty ? nil : L10n.string("duplicates.group_count \(groups.count)")
    }

    /// The photos that Merge All moves to Recently Deleted.
    public var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicateCount } }

    /// The count for the Duplicates entry. Nil until a scan has finished.
    public var knownDuplicateCount: Int? {
        phase == .loaded ? duplicateCount : scannedDuplicateCount
    }

    public var canMerge: Bool { !isMerging && phase != .loading && !groups.isEmpty }

    public var mergeAllTitle: String { L10n.string("duplicates.merge_all_title \(duplicateCount)") }
    public var mergeAllMessage: String { L10n.string("duplicates.merge_all_message \(duplicateCount)") }

    /// Reads the groups and shows them, then ranks the first two pages and builds the content index or brings it up
    /// to date, both at once. Reads the groups again when the index changed. A choice of the person and the ranking of
    /// a group with the same members stay, so a screen that opens again reads nothing for them.
    public func load() async {
        guard !isMerging else { return }
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        restartedAfterInterruption = false
        checkInterrupted = false
        rescanAfterMerge = false
        stopRanking()
        guard await scan(generation: generation) else { return }
        async let ranked: Void = rank(around: 0)
        async let built: Void = buildAndRescan(generation: generation)
        _ = await (ranked, built)
    }

    /// The screen shows the group. Ranks its page and the page after it, unless they are ranked.
    public func groupAppeared(_ groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        _ = requestRanking(around: index)
    }

    /// Reads the groups and shows them in the fallback order. A group with the same members keeps its ranking and the
    /// choice of the person. False when the read failed or a newer load replaced this one.
    private func scan(generation: Int) async -> Bool {
        let report: @Sendable (ExactDuplicateScanProgress) async -> Void = { [weak self] progress in
            await self?.showScan(progress, generation: generation)
        }
        defer { if generation == loadGeneration { scanProgress = nil } }
        do {
            let scan = try await finder.duplicateGroups(progress: report)
            let fallback = await finder.fallbackMembers(of: scan.groups)
            guard generation == loadGeneration, !isMerging else { return false }
            let earlier = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups = scan.groups.map { group in
                if let same = earlier[group.id], Set(same.members) == Set(group.members) {
                    var kept = same
                    kept.scanGroup = group
                    kept.byteSize = scan.byteSizes[group.id] ?? same.byteSize
                    return kept
                }
                let members = fallback[group.id] ?? group.members
                let choice = earlier[group.id].flatMap { $0.isKeptChosen && members.contains($0.kept) ? $0.kept : nil }
                var shown = Group(scanGroup: group, members: members, kept: choice ?? members[0])
                shown.isKeptChosen = choice != nil
                shown.byteSize = scan.byteSizes[group.id] ?? earlier[group.id]?.byteSize
                return shown
            }
            coverage = scan.coverage
            phase = .loaded
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            phase = .failed
            return false
        }
    }

    private func showScan(_ progress: ExactDuplicateScanProgress, generation: Int) {
        guard generation == loadGeneration, phase == .loading else { return }
        scanProgress = progress
    }

    /// Ranks the page of the group at `index` and the page after it, and waits for that ranking.
    private func rank(around index: Int) async {
        guard let task = requestRanking(around: index) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Queues the unranked groups of two pages from the page of `index`. Returns the ranking that reads them.
    private func requestRanking(around index: Int) -> Task<Void, Never>? {
        let size = Self.rankingPageSize
        let start = index / size * size
        let wanted = groups[start..<min(start + 2 * size, groups.count)]
            .filter { !$0.isRanked && !rankingRequested.contains($0.id) }.map(\.id)
        guard !wanted.isEmpty else { return ranking }
        rankingRequested.formUnion(wanted)
        rankingQueue += wanted
        if let ranking {
            if rankingToken == rankingWorkerToken, let progress = rankingProgress {
                rankingProgress = ExactDuplicateScanProgress(
                    completed: progress.completed, total: progress.total + wanted.count)
            }
            return ranking
        }
        let token = UUID()
        rankingWorkerToken = token
        // During a merge its own progress row stays; the scroll ranking runs without one.
        if !isMerging {
            rankingToken = token
            rankingProgress = ExactDuplicateScanProgress(completed: 0, total: wanted.count)
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
        guard rankingWorkerToken == token else { return }
        if Task.isCancelled {
            // A closed screen stops the ranking. Groups that it did not rank can be requested again.
            let ranked = Set(groups.filter(\.isRanked).map(\.id))
            rankingRequested.formIntersection(ranked)
        }
        ranking = nil
        rankingQueue = []
        rankingWorkerToken = nil
        if rankingToken == token { rankingProgress = nil }
    }

    /// Stops the ranking. A group that it did not read can be requested again.
    private func stopRanking() {
        ranking?.cancel()
        ranking = nil
        rankingQueue = []
        rankingRequested = []
        rankingWorkerToken = nil
        rankingToken = UUID()
        rankingProgress = nil
    }

    /// Takes the ranked order and the size of each group in `page`. Only the ranking of `token` counts its progress.
    /// `keepsShown` keeps the photo that the screen shows as kept, as a merge does.
    private func apply(_ page: ExactDuplicateRankingPage, token: UUID?, keepsShown: Bool = false) {
        if let token, token == rankingToken, let progress = rankingProgress {
            rankingProgress = ExactDuplicateScanProgress(
                completed: min(progress.completed + page.groupCount, progress.total), total: progress.total)
        }
        for (id, order) in page.members {
            guard let index = groups.firstIndex(where: { $0.id == id }) else { continue }
            groups[index].rank(order, shared: page.shared[id] ?? [], keepsShown: keepsShown)
        }
        for (id, size) in page.byteSizes {
            guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].byteSize == nil else { continue }
            groups[index].byteSize = size
        }
    }

    private func buildAndRescan(generation: Int) async {
        let changed: Bool
        do {
            changed = try await buildIndex()
            buildFailed = false
            checkInterrupted = false
        } catch is CancellationError where !Task.isCancelled {
            // The service stopped the build; nothing failed. The check starts again: after a merge, or now once.
            guard generation == loadGeneration else { return }
            checkInterrupted = true
            if !isMerging, !restartedAfterInterruption {
                restartedAfterInterruption = true
                await buildAndRescan(generation: generation)
            }
            return
        } catch {
            guard generation == loadGeneration else { return }
            buildFailed = true
            // The groups already shown stay. Without them, the person can try again.
            if !isMerging, groups.isEmpty, !isComplete { phase = .failed }
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

    /// Counts the duplicates for the entry without ranking them, once, before the screen has loaded.
    public func loadCountIfNeeded() async {
        guard phase == .idle, scannedDuplicateCount == nil else { return }
        guard let scan = try? await finder.duplicateGroups(progress: { _ in }), phase == .idle else { return }
        scannedDuplicateCount = scan.groups.reduce(0) { $0 + $1.members.count - 1 }
    }

    /// Keeps `uid` instead of the ranked photo when the group is merged.
    public func keep(_ uid: PhotoUID, inGroup groupID: String) {
        guard !isMerging, let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].members.contains(uid)
        else { return }
        groups[index].kept = uid
        groups[index].isKeptChosen = true
    }

    /// Merges one group and keeps exactly the photo that the screen shows as kept.
    public func merge(groupID: String) async {
        guard canMerge, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isKeptChosen = true
        await merge([groups[index]])
    }

    public func mergeAll() async {
        guard canMerge else { return }
        await merge(groups)
    }

    public func dismissNotice() {
        notice = nil
    }

    private func merge(_ requested: [Group]) async {
        isMerging = true
        notice = nil
        // Merge All reads the groups that nobody scrolled to page by page, with progress. The photo that the screen
        // shows as kept stays, unless only another member is shared.
        let unranked = requested.filter { !$0.isRanked && !$0.isKeptChosen }.map(\.scanGroup)
        if !unranked.isEmpty {
            let token = UUID()
            rankingToken = token
            rankingProgress = ExactDuplicateScanProgress(completed: 0, total: unranked.count)
            let apply: @Sendable (ExactDuplicateRankingPage) async -> Void = { [weak self] page in
                await self?.apply(page, token: token, keepsShown: true)
            }
            await finder.rankMembers(of: unranked, ranked: apply)
            if rankingToken == token { rankingProgress = nil }
        }
        let selected = requested.compactMap { request in groups.first { $0.id == request.id } }
        var trashed: [PhotoUID] = []
        var kept: [PhotoUID: ExactDuplicateKeepReason] = [:]
        var keptPhotoUnreadable = false
        var failed = false
        var stale = false
        let results = await finder.merge(selected.map { ($0.scanGroup, $0.kept) })
        for (group, result) in zip(selected, results) {
            do {
                switch try result.get() {
                case .merged(_, let moved, let keptDuplicates):
                    trashed += moved
                    kept.merge(keptDuplicates) { first, _ in first }
                    // A group with a duplicate left keeps its reason, so the person can keep another photo instead.
                    if let index = groups.firstIndex(where: { $0.id == group.id }),
                        !groups[index].remove(moved, keptReason: Self.firstReason(in: keptDuplicates.values))
                    {
                        groups.remove(at: index)
                    }
                case .skipped(.keptUnreadable):
                    keptPhotoUnreadable = true
                case .skipped:
                    // The library changed since the scan; a new scan shows what is left.
                    stale = true
                }
            } catch is CancellationError {
                break
            } catch {
                failed = true
            }
        }
        if !trashed.isEmpty { await didTrash(trashed) }
        isMerging = false
        notice = Self.notice(kept: kept, keptPhotoUnreadable: keptPhotoUnreadable, failed: failed)
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
            .relatedFileWithoutTwin, .pendingEditReplacement, .neededByLocalSource, .shared, .unreadable,
        ]
        return order.first(where: reasons.contains)
    }
}
