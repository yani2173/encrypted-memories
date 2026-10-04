import Foundation
import Observation
import PhotosCore

/// The reads and the merge that the Duplicates screens need. `ExactDuplicateFinder` serves the signed-in account;
/// tests and the offline UI-test account supply their own.
public protocol ExactDuplicateMerging: Sendable {
    func duplicateGroups() async throws -> ExactDuplicateScan
    func rankedMembers(of groups: [ExactDuplicateGroup]) async throws -> [String: [PhotoUID]]
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
        case .keptDuplicates(_, .unreadable): L10n.string("duplicates.kept_reason_unreadable")
        case .keptPhotoUnreadable: L10n.string("duplicates.kept_photo_unreadable")
        case .failed: L10n.string("duplicates.merge_failed_message")
        }
    }
}

/// The shared state of the Duplicates screens on iOS, iPadOS, and macOS: the groups, the photo to keep in each
/// group, and the merges. The platform views only render it and forward taps.
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
        /// The photos that a merge moves to Recently Deleted.
        public var duplicateCount: Int { members.count - 1 }

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
    }

    public enum Content: Equatable, Sendable {
        case loading
        case failed(String)
        case noDuplicates
        /// No group yet, and the content index still misses photos.
        case stillChecking
        case groups
    }

    private enum Phase: Equatable {
        case idle, loading, loaded
        case failed
    }

    public private(set) var groups: [Group] = []
    /// False while the content index misses photos, so more duplicates can appear later.
    public private(set) var isComplete = true
    public private(set) var isMerging = false
    /// The message of the last merge, until the person dismisses it.
    public private(set) var notice: ExactDuplicateMergeNotice?
    private var phase = Phase.idle
    private var scannedDuplicateCount: Int?
    private var loadGeneration = 0
    @ObservationIgnored private let finder: any ExactDuplicateMerging
    /// Called with the photos that a merge moved to Recently Deleted, so the library stops showing them.
    @ObservationIgnored private let didTrash: @MainActor ([PhotoUID]) async -> Void

    public init(
        finder: any ExactDuplicateMerging, didTrash: @escaping @MainActor ([PhotoUID]) async -> Void = { _ in }
    ) {
        self.finder = finder
        self.didTrash = didTrash
    }

    public var content: Content {
        switch phase {
        case .idle, .loading: groups.isEmpty ? .loading : .groups
        case .failed: groups.isEmpty ? .failed(L10n.string("duplicates.load_failed")) : .groups
        case .loaded:
            if !groups.isEmpty { .groups } else if isComplete { .noDuplicates } else { .stillChecking }
        }
    }

    /// The text of `.noDuplicates` and `.stillChecking`.
    public var emptyStateCopy: PhotoFilterEmptyStateCopy {
        guard content == .stillChecking else { return PhotoFilter.duplicates.emptyStateCopy }
        return PhotoFilterEmptyStateCopy(
            title: L10n.string("duplicates.checking_title"), description: L10n.string("duplicates.still_checking"),
            systemImage: "hourglass")
    }

    /// The note while the library is still being checked. Nil once every photo was checked.
    public var stillCheckingNote: String? {
        phase == .loaded && !isComplete ? L10n.string("duplicates.still_checking") : nil
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

    /// Reads the groups and ranks their members. A choice of the person stays while its photo is still a member.
    public func load() async {
        guard !isMerging else { return }
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        do {
            let scan = try await finder.duplicateGroups()
            let ranked = try await finder.rankedMembers(of: scan.groups)
            guard generation == loadGeneration else { return }
            let earlier = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups = scan.groups.map { group in
                let members = ranked[group.id] ?? group.members
                let choice = earlier[group.id].flatMap { members.contains($0.kept) ? $0.kept : nil }
                // The reason of the last merge stays while the group still has the same members.
                let reason = earlier[group.id].flatMap { Set($0.members) == Set(members) ? $0.keptReason : nil }
                return Group(scanGroup: group, members: members, kept: choice ?? members[0], keptReason: reason)
            }
            isComplete = scan.coverage.isComplete
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed
        }
    }

    /// Counts the duplicates for the entry without ranking them, once, before the screen has loaded.
    public func loadCountIfNeeded() async {
        guard phase == .idle, scannedDuplicateCount == nil else { return }
        guard let scan = try? await finder.duplicateGroups(), phase == .idle else { return }
        scannedDuplicateCount = scan.groups.reduce(0) { $0 + $1.members.count - 1 }
    }

    /// Keeps `uid` instead of the ranked photo when the group is merged.
    public func keep(_ uid: PhotoUID, inGroup groupID: String) {
        guard !isMerging, let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].members.contains(uid)
        else { return }
        groups[index].kept = uid
    }

    public func merge(groupID: String) async {
        guard canMerge, let group = groups.first(where: { $0.id == groupID }) else { return }
        await merge([group])
    }

    public func mergeAll() async {
        guard canMerge else { return }
        await merge(groups)
    }

    public func dismissNotice() {
        notice = nil
    }

    private func merge(_ selected: [Group]) async {
        isMerging = true
        notice = nil
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
        if stale { await load() }
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
            .relatedFileWithoutTwin, .pendingEditReplacement, .neededByLocalSource, .unreadable,
        ]
        return order.first(where: reasons.contains)
    }
}
