import Foundation
import PhotosCore

/// Remote reads and the trash write of the duplicate merge. The backend implements it; tests use a fake.
public protocol ExactDuplicateRemote: PhotoCarryOverRemote {
    /// Moves the duplicates to the Proton trash on the path of the person's own trash, so Recently Deleted shows them.
    func trashDuplicates(_ uids: [PhotoUID]) async throws
    /// Restores photos that a merge moved to the trash, on the path of the person's own restore.
    func restoreDuplicates(_ uids: [PhotoUID]) async throws
    /// The capture dates that the device already knows, without a request. Unknown photos are left out.
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date]
    /// The sharing state and the size of each photo, from one node read for each photo. A trash ends the sharing.
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts]
}

/// What one node read tells about a photo.
public struct ExactDuplicateNodeFacts: Sendable, Equatable {
    /// The person shares the photo with other people or by a link.
    public let isShared: Bool
    /// The size of the photo's file in bytes, as its uploader stated it. Nil when the node has none.
    public let byteSize: Int64?
    /// Every album that contains the photo, shared albums included.
    public let albums: [SeriesAlbumReference]

    public init(isShared: Bool, byteSize: Int64?, albums: [SeriesAlbumReference] = []) {
        self.isShared = isShared
        self.byteSize = byteSize
        self.albums = albums
    }
}

/// Two or more main photos of the own library with the same bytes.
public struct ExactDuplicateGroup: Sendable, Equatable, Identifiable {
    public var id: String { contentHash }
    /// The keyed content hash that all members share.
    public let contentHash: String
    /// The key epoch of `contentHash`. A merge under another key reads nothing and writes nothing.
    public let hashKeyEpoch: String
    /// Active main photos, sorted by link ID.
    public let members: [PhotoUID]

    public init(contentHash: String, hashKeyEpoch: String, members: [PhotoUID]) {
        self.contentHash = contentHash
        self.hashKeyEpoch = hashKeyEpoch
        self.members = members
    }
}

/// How far the scan has read the state of the candidate photos.
public struct ExactDuplicateScanProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

/// The members of some groups in the order of the photo to keep, with the number of groups that the page covers.
/// A group whose facts could not be read is not in `members` and keeps its fallback order.
public struct ExactDuplicateRankingPage: Sendable, Equatable {
    public let members: [String: [PhotoUID]]
    public let groupCount: Int
    /// The size of one copy of each group in bytes, from the node reads of the ranking.
    public let byteSizes: [String: Int64]
    /// The shared members of each ranked group. A trash would end their sharing.
    public let shared: [String: Set<PhotoUID>]

    public init(
        members: [String: [PhotoUID]], groupCount: Int, byteSizes: [String: Int64] = [:],
        shared: [String: Set<PhotoUID>] = [:]
    ) {
        self.members = members
        self.groupCount = groupCount
        self.byteSizes = byteSizes
        self.shared = shared
    }
}

/// How much of the library the content index covered when the groups were read. Every group found is exact; an
/// incomplete index can only miss groups.
public enum ExactDuplicateCoverage: Sendable, Equatable {
    case complete
    /// Photos whose content hash could not be read are missing.
    case incomplete(unresolvedCount: Int)
    /// The index is not built yet, or the check of its state failed.
    case indexing

    public var isComplete: Bool { self == .complete }
}

public struct ExactDuplicateScan: Sendable, Equatable {
    public let groups: [ExactDuplicateGroup]
    public let coverage: ExactDuplicateCoverage
    /// The size of one copy of a group in bytes, by content hash, where the local upload manifest knows it.
    public let byteSizes: [String: Int64]

    public init(groups: [ExactDuplicateGroup], coverage: ExactDuplicateCoverage, byteSizes: [String: Int64] = [:]) {
        self.groups = groups
        self.coverage = coverage
        self.byteSizes = byteSizes
    }
}

/// Why a merge leaves a duplicate in the library.
public enum ExactDuplicateKeepReason: String, Sendable, Equatable {
    /// The server did not return the complete photo, or its bytes differ from the group.
    case unreadable
    /// A related file, such as a Live Photo video or an original, has no copy under the kept photo.
    case relatedFileWithoutTwin
    /// The replacement of an edited photo still tracks the photo.
    case pendingEditReplacement
    /// A local source counts the photo as its backup, and the manifest cannot move that row to the kept photo.
    case neededByLocalSource
    /// The person shares the photo. A trash would end that sharing.
    case shared
}

public enum ExactDuplicateSkipReason: String, Sendable, Equatable {
    /// The photo to keep is no member of the group.
    case keptNotInGroup
    /// The photos root key changed after the scan.
    case keyChanged
    /// The photo to keep left the library.
    case keptLeftLibrary
    /// Fewer than two members are still in the library.
    case noDuplicateLeft
    /// The server did not return the complete photo to keep.
    case keptUnreadable
    /// The photo to keep left the library while the merge moved the duplicates to the trash, for example by a merge
    /// on another device that kept another member. The merge restored its duplicates and moved their rows back.
    case keptLeftLibraryDuringMerge
}

public enum ExactDuplicateMergeOutcome: Sendable, Equatable {
    case merged(kept: PhotoUID, trashed: [PhotoUID], keptDuplicates: [PhotoUID: ExactDuplicateKeepReason])
    case skipped(ExactDuplicateSkipReason)
}

/// One group that a merge takes, with the photo to keep.
public struct ExactDuplicateMergeRequest: Sendable, Equatable {
    public let group: ExactDuplicateGroup
    public let kept: PhotoUID
    /// The person chose `kept`, so the merge keeps exactly that photo. Otherwise the merge keeps a shared duplicate in
    /// place of an unshared `kept`: a trash would end the sharing of the duplicate.
    public let isKeptChosen: Bool

    public init(group: ExactDuplicateGroup, kept: PhotoUID, isKeptChosen: Bool = true) {
        self.group = group
        self.kept = kept
        self.isKeptChosen = isKeptChosen
    }
}

/// The facts that rank the members of a group for the photo to keep.
public struct ExactDuplicateKeepFacts: Sendable, Equatable {
    /// The person shares the photo with other people or by a link.
    public var isShared: Bool
    public var isInOwnAlbum: Bool
    public var isFavorite: Bool
    /// A local source of this device counts the photo as its backup.
    public var isNamedByManifest: Bool
    public var captureDate: Date?

    public init(
        isInOwnAlbum: Bool, isFavorite: Bool, isNamedByManifest: Bool, captureDate: Date?, isShared: Bool = false
    ) {
        self.isShared = isShared
        self.isInOwnAlbum = isInOwnAlbum
        self.isFavorite = isFavorite
        self.isNamedByManifest = isNamedByManifest
        self.captureDate = captureDate
    }
}

/// Finds exact duplicates in the own Proton library and merges them, like Duplicates in Apple Photos.
///
/// A group holds two or more active main photos with the same content hash in the current key epoch. The content
/// index of the backup dedupe supplies the hashes, so the scan reads no media bytes. Related files, photos of shared
/// albums, trashed photos, and drafts are never members. A merge keeps one member, gives it the favorite tag and the
/// own albums of the others, moves the rows of the upload manifest to it, and moves the others to Recently Deleted.
/// Every merge reads the server state again, so a retry after a failure repeats no write.
public struct ExactDuplicateFinder: Sendable {
    let checker: any UploadDuplicateChecking
    /// The backup's duplicate check. Its cached remote state still names the trashed duplicates after a merge.
    let resolver: any UploadIdentityResolving
    let index: any UploadRemoteContentIndexStore
    let identities: any UploadIdentityStore
    let journal: any EditReplacementJournaling
    let remote: any ExactDuplicateRemote
    let albums: any SeriesAlbumCarryOver
    /// Receives the duration and the request count of each phase, never an identifier.
    let log: @Sendable (String) -> Void
    /// The volume and the favorites that the ranking reads once and shares across its pages.
    let rankingContext = ExactDuplicateRankingContext()

    public init(
        checker: any UploadDuplicateChecking,
        resolver: any UploadIdentityResolving,
        index: any UploadRemoteContentIndexStore,
        identities: any UploadIdentityStore,
        journal: any EditReplacementJournaling,
        remote: any ExactDuplicateRemote,
        albums: any SeriesAlbumCarryOver,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.checker = checker
        self.resolver = resolver
        self.index = index
        self.identities = identities
        self.journal = journal
        self.remote = remote
        self.albums = albums
        self.log = log
    }

    /// Visibility reads that run at once. Each reads up to `UploadDedupePipeline.protonDuplicateBatchSize` links.
    static let visibilityConcurrency = 4
    /// Groups whose facts the ranking reads at once. One node read for each member gives its albums and its facts.
    /// One group at a time: a group already reads its members several at once through the SDK, so the ranking adds no
    /// more concurrent SDK node reads than one album membership read.
    static let rankingConcurrency = 1
    /// Groups in one page of the ranking.
    static let rankingPageSize = 24

    /// The groups of the current key epoch, largest first. The scan reads the index as it is: `prepareIndex` builds
    /// it, and the scan reports `.indexing` until a build has finished. The coverage comes from the local index, so a
    /// running build never holds the scan.
    public func duplicateGroups() async throws -> ExactDuplicateScan {
        try await duplicateGroups(progress: { _ in })
    }

    /// `duplicateGroups()` that reports how many candidate photos the visibility read has covered.
    public func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan {
        let start = ContinuousClock.now
        let epoch = try await checker.hashKeyEpoch()
        let coverage = coverage(hashKeyEpoch: epoch)
        // Known related files, such as Live Photo videos and originals, never are members.
        guard let candidates = index.remoteContentDuplicateGroups(hashKeyEpoch: epoch) else {
            throw UploadError.backend("Upload identity manifest could not be read")
        }
        guard !candidates.isEmpty else { return ExactDuplicateScan(groups: [], coverage: coverage) }
        let volumeID = try await remote.ownPhotosVolumeID()
        let links = Set(candidates.values.joined()).sorted()
        let (visibility, requests) = try await visibility(of: links, progress: progress)
        log(
            "[Duplicates] scan candidates=\(candidates.count) links=\(links.count) visibilityRequests=\(requests) "
                + "duration=\(start.duration(to: .now))")
        let groups = candidates.compactMap { contentHash, links -> ExactDuplicateGroup? in
            let members = links.filter { visibility[$0]?.isActiveMain == true }.sorted()
            guard members.count > 1 else { return nil }
            return ExactDuplicateGroup(
                contentHash: contentHash, hashKeyEpoch: epoch,
                members: members.map { PhotoUID(volumeID: volumeID, nodeID: $0) })
        }
        let sorted = groups.sorted {
            $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.contentHash < $1.contentHash
        }
        rankingContext.scope(sorted.flatMap(\.members))
        // The copies hold the same bytes, so a manifest row of any copy gives the size of all of them.
        let sizes = (index.remoteContentDuplicateSizes(hashKeyEpoch: epoch) ?? [:]).filter { candidates[$0.key] != nil }
        return ExactDuplicateScan(groups: sorted, coverage: coverage, byteSizes: sizes)
    }

    /// Reads the visibility of `links` in batches, `visibilityConcurrency` at once. Returns the request count too.
    private func visibility(
        of links: [String], progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ([String: RemoteLinkVisibility], Int) {
        let size = UploadDedupePipeline.protonDuplicateBatchSize
        let batches = stride(from: 0, to: links.count, by: size).map { Array(links[$0..<min($0 + size, links.count)]) }
        await progress(ExactDuplicateScanProgress(completed: 0, total: links.count))
        let checker = checker
        return try await withThrowingTaskGroup(of: [String: RemoteLinkVisibility].self) { group in
            var next = 0
            var completed = 0
            var visibility: [String: RemoteLinkVisibility] = [:]
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { try await checker.linkVisibility(of: batch) }
            }
            for _ in 0..<min(Self.visibilityConcurrency, batches.count) { addNext() }
            while let read = try await group.next() {
                visibility.merge(read) { _, new in new }
                completed += 1
                await progress(
                    ExactDuplicateScanProgress(
                        completed: min(completed * size, links.count), total: links.count))
                addNext()
            }
            return (visibility, batches.count)
        }
    }

    /// Builds the content index when none exists, or brings it up to date, with the build of the backup. While the
    /// backup builds the index, this waits for that build and reports its progress; it never starts a second one.
    /// True when the index changed, so a new scan can find other groups. The build runs through the backup's resolver,
    /// so the sign-out waits for it like for a backup build.
    public func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool {
        let epoch = try await checker.hashKeyEpoch()
        let before = (index.remoteContentIndexCheckpoint(hashKeyEpoch: epoch)?.eventID, indexHealth(epoch))
        try await resolver.prepareRemoteIndex(progress: progress)
        let after = (index.remoteContentIndexCheckpoint(hashKeyEpoch: epoch)?.eventID, indexHealth(epoch))
        return before != after
    }

    private func indexHealth(_ epoch: String) -> UploadRemoteContentIndexHealth {
        index.remoteContentIndexHealth(hashKeyEpoch: epoch)
    }

    private func coverage(hashKeyEpoch epoch: String) -> ExactDuplicateCoverage {
        guard index.remoteContentIndexCheckpoint(hashKeyEpoch: epoch) != nil else { return .indexing }
        switch indexHealth(epoch) {
        case .complete: return .complete
        case .degraded(_, let unresolved): return .incomplete(unresolvedCount: unresolved)
        case .unavailable: return .indexing
        }
    }

    /// The members of each group in an order that needs no request: the earliest capture date that the device knows,
    /// then the smallest link ID. The screens show it until the ranking has read the facts of the group.
    public func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        let dates = await remote.captureDates(of: groups.flatMap(\.members))
        var facts: [PhotoUID: ExactDuplicateKeepFacts] = [:]
        for (uid, date) in dates {
            facts[uid] = ExactDuplicateKeepFacts(
                isInOwnAlbum: false, isFavorite: false, isNamedByManifest: false, captureDate: date)
        }
        return Dictionary(
            groups.map { ($0.contentHash, Self.keepOrder($0.members, facts: facts)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The members of each group by content hash, the photo to keep first. A group whose facts could not be read is
    /// left out, so it keeps its fallback order.
    public func rankedMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        let collected = RankingCollector()
        await rankMembers(of: groups) { await collected.add($0.members) }
        return await collected.members
    }

    /// Ranks the members of each group, page by page, and hands each page to `ranked`. One favorites listing, one
    /// local date read, and one manifest scan serve all groups; each group reads the albums and the sharing state of
    /// its own members, `rankingConcurrency` groups at once. A failed read leaves only its group in the fallback
    /// order. Stops after a cancellation.
    public func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async {
        guard !groups.isEmpty else { return }
        let start = ContinuousClock.now
        let members = groups.flatMap(\.members)
        let context: (volumeID: String, favorites: Set<PhotoUID>)
        do {
            context = try await rankingContext.value(for: members, remote: remote)
        } catch {
            log("[Duplicates] ranking without favorites; every group keeps its fallback order")
            await ranked(ExactDuplicateRankingPage(members: [:], groupCount: groups.count))
            return
        }
        let dates = await remote.captureDates(of: members)
        let owners = identities.sources(withRemoteLinkIDs: Set(members.map(\.nodeID)))
        var failed = 0
        for pageStart in stride(from: 0, to: groups.count, by: Self.rankingPageSize) {
            guard !Task.isCancelled else { return }
            let page = Array(groups[pageStart..<min(pageStart + Self.rankingPageSize, groups.count)])
            let facts = await groupFacts(of: page)
            var order: [String: [PhotoUID]] = [:]
            var sizes: [String: Int64] = [:]
            var sharedMembers: [String: Set<PhotoUID>] = [:]
            for group in page {
                guard let read = facts[group.contentHash] else {
                    failed += 1
                    continue
                }
                let shared = Set(group.members.filter { read[$0]?.isShared == true })
                if !shared.isEmpty { sharedMembers[group.contentHash] = shared }
                if let size = group.members.lazy.compactMap({ read[$0]?.byteSize }).first(where: { $0 > 0 }) {
                    sizes[group.contentHash] = size
                }
                var memberFacts: [PhotoUID: ExactDuplicateKeepFacts] = [:]
                for member in group.members {
                    memberFacts[member] = ExactDuplicateKeepFacts(
                        isInOwnAlbum: (read[member]?.albums ?? []).contains { $0.volumeID == context.volumeID },
                        isFavorite: context.favorites.contains(member),
                        isNamedByManifest: !(owners?[member.nodeID] ?? []).isEmpty,
                        captureDate: dates[member], isShared: shared.contains(member))
                }
                order[group.contentHash] = Self.keepOrder(group.members, facts: memberFacts)
            }
            guard !Task.isCancelled else { return }
            await ranked(
                ExactDuplicateRankingPage(
                    members: order, groupCount: page.count, byteSizes: sizes, shared: sharedMembers))
        }
        log(
            "[Duplicates] ranking groups=\(groups.count) members=\(members.count) failedGroups=\(failed) "
                + "nodeReads=\(members.count) "
                + "duration=\(start.duration(to: .now))")
    }

    private typealias GroupFacts = [PhotoUID: ExactDuplicateNodeFacts]

    /// The node facts of the members of each group, albums included, `rankingConcurrency` groups at once: one node
    /// read for each member. A group whose read failed is missing.
    private func groupFacts(of groups: [ExactDuplicateGroup]) async -> [String: GroupFacts] {
        let remote = remote
        return await withTaskGroup(of: (String, GroupFacts?).self) { taskGroup in
            var next = 0
            var facts: [String: GroupFacts] = [:]
            func addNext() {
                guard next < groups.count else { return }
                let group = groups[next]
                next += 1
                taskGroup.addTask {
                    do {
                        return (group.contentHash, try await remote.nodeFacts(of: group.members))
                    } catch {
                        return (group.contentHash, nil)
                    }
                }
            }
            for _ in 0..<min(Self.rankingConcurrency, groups.count) { addNext() }
            while let (contentHash, read) = await taskGroup.next() {
                facts[contentHash] = read
                addNext()
            }
            return facts
        }
    }

    /// Ranks the photo to keep first: a shared photo, a photo in an own album, a favorite, a photo that a local source
    /// of this device counts as its backup, the earliest capture date, and then the smallest link ID. A missing fact
    /// ranks last.
    public static func keepOrder(_ members: [PhotoUID], facts: [PhotoUID: ExactDuplicateKeepFacts]) -> [PhotoUID] {
        members.sorted { lhs, rhs in
            let left = facts[lhs]
            let right = facts[rhs]
            for (l, r) in [
                (left?.isShared, right?.isShared), (left?.isInOwnAlbum, right?.isInOwnAlbum),
                (left?.isFavorite, right?.isFavorite),
                (left?.isNamedByManifest, right?.isNamedByManifest),
            ] where (l ?? false) != (r ?? false) {
                return l ?? false
            }
            switch (left?.captureDate, right?.captureDate) {
            case (let l?, let r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.nodeID < rhs.nodeID
            }
        }
    }

    /// Attempts of the read of the kept photos after the trash. A failed read leaves the restore unreachable when
    /// another device trashed a kept photo meanwhile, and a later retry finds every copy in Recently Deleted.
    static let keptReadAttempts = 3
    /// The wait between two attempts of that read.
    var keptReadRetryDelay: Duration = .milliseconds(500)
    /// Groups whose node read fails in a row before the merge takes that failure for every group that is left, for
    /// example without a connection, instead of reading each of them.
    static let nodeReadFailureLimit = 3

    /// Keeps `kept` and moves the other members of `group` to Recently Deleted.
    ///
    /// The merge reads every member again and leaves a member whose trash could lose data: a related file without a
    /// copy under `kept`, a photo that the edit replacement still tracks, or a photo that a local source needs and
    /// whose manifest row cannot move. The favorite tag and the own albums move to `kept` first, then the manifest
    /// rows, and then the trash. A crash after any step leaves the next step to a retry: the carried state reads as
    /// done, moved rows name `kept`, and trashed members are no members anymore. When `kept` left the library during
    /// the trash, the merge restores the duplicates, so one copy always stays.
    public func merge(_ group: ExactDuplicateGroup, keeping kept: PhotoUID) async throws -> ExactDuplicateMergeOutcome {
        try await merge([ExactDuplicateMergeRequest(group: group, kept: kept)])[0].get()
    }

    /// Merges each group like `merge(_:keeping:)`. Every read and every write serves all groups at once: one read of
    /// the members in the library, the compounds in metadata requests of many photos, one node read of all
    /// duplicates, one manifest scan, one favorites listing, one favorite write, one add for each own album, one row
    /// move, one trash, and one read of the kept photos after the trash. A request whose photo to keep the person did
    /// not choose keeps a shared duplicate in place of an unshared photo.
    ///
    /// Each group holds its outcome or its error. A failed read of the library fails every group, a node that cannot
    /// be read fails only its own group, and a failed write fails the groups that it covers. A failed trash fails
    /// every group that it should have taken. After a cancellation, no further group writes, and every group without
    /// an outcome fails with `CancellationError`.
    public func merge(
        _ requests: [ExactDuplicateMergeRequest]
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        let start = ContinuousClock.now
        var results = [Result<ExactDuplicateMergeOutcome, any Error>?](repeating: nil, count: requests.count)
        var plans: [(index: Int, plan: PlannedMerge)] = []
        do {
            plans = try await plan(requests, into: &results)
        } catch {
            for index in results.indices where results[index] == nil { results[index] = .failure(error) }
        }
        if !Task.isCancelled, !plans.isEmpty {
            // One manifest scan serves every member. A store that cannot tell keeps every duplicate.
            let owners = identities.sources(
                withRemoteLinkIDs: Set(plans.flatMap { $0.plan.candidates.flatMap(\.links) }))
            for position in plans.indices {
                decide(&plans[position].plan, owners: owners)
                let plan = plans[position].plan
                if plan.trashable.isEmpty {
                    results[plans[position].index] = .success(
                        .merged(kept: plan.kept, trashed: [], keptDuplicates: plan.keptDuplicates))
                }
            }
            let writes = plans.filter { !$0.plan.trashable.isEmpty }
            if !writes.isEmpty {
                do {
                    let favorites = try await remote.favoriteUIDs(
                        among: writes.flatMap { $0.plan.trashable + [$0.plan.kept] })
                    // One album listing serves every group: an own album whose cover leaves gets the kept photo.
                    let covers = try await albums.ownAlbumCovers()
                    await write(writes, favorites: favorites, covers: covers, into: &results)
                } catch {
                    for (index, _) in writes { results[index] = .failure(error) }
                }
            }
        }
        var trashed = 0
        var failed = 0
        for result in results {
            switch result {
            case .success(.merged(_, let moved, _))?: trashed += moved.count
            case .failure?, nil: failed += 1
            case .success?: break
            }
        }
        log(
            "[Duplicates] merge groups=\(requests.count) trashed=\(trashed) failedGroups=\(failed) "
                + "duration=\(start.duration(to: .now))")
        return results.map { $0 ?? .failure(CancellationError()) }
    }

    /// A group whose server state allows a merge, with the members that a trash could take.
    private struct PlannedMerge {
        let kept: PhotoUID
        let contentHash: String
        let epoch: String
        let volumeID: String
        var candidates: [(member: PhotoUID, links: Set<String>, moves: [UploadRemoteLinkMove])] = []
        /// The albums of each candidate, from the node read of the plan.
        var albums: [PhotoUID: [SeriesAlbumReference]] = [:]
        var keptDuplicates: [PhotoUID: ExactDuplicateKeepReason] = [:]
        /// The members that the trash takes, and the rows that move with them. `decide` fills both.
        var trashable: [PhotoUID] = []
        var moves: [UploadRemoteLinkMove] = []
    }

    private typealias NodeFactsRead = Result<GroupFacts, any Error>

    /// Reads the server state of every group at once: the key, the members in the library, the compound of each
    /// member, and the sharing state and the albums of each duplicate. A group whose state allows no merge holds its
    /// outcome in `results`, and so does a group whose node read failed. A failed read of the library throws.
    private func plan(
        _ requests: [ExactDuplicateMergeRequest], into results: inout [Result<ExactDuplicateMergeOutcome, any Error>?]
    ) async throws -> [(index: Int, plan: PlannedMerge)] {
        var open: [Int] = []
        for (index, request) in requests.enumerated() {
            guard request.group.members.contains(request.kept) else {
                results[index] = .success(.skipped(.keptNotInGroup))
                continue
            }
            open.append(index)
        }
        guard !open.isEmpty else { return [] }
        let epoch = try await checker.hashKeyEpoch()
        var current: [Int] = []
        for index in open {
            guard requests[index].group.hashKeyEpoch == epoch else {
                results[index] = .success(.skipped(.keyChanged))
                continue
            }
            current.append(index)
        }
        guard !current.isEmpty else { return [] }
        let links = Set(current.flatMap { requests[$0].group.members.map(\.nodeID) }).sorted()
        let (visibility, _) = try await visibility(of: links, progress: { _ in })
        var active: [Int: [PhotoUID]] = [:]
        for index in current {
            let request = requests[index]
            let members = request.group.members.filter { visibility[$0.nodeID]?.isActiveMain == true }
            if !members.contains(request.kept) {
                results[index] = .success(.skipped(.keptLeftLibrary))
            } else if members.count < 2 {
                results[index] = .success(.skipped(.noDuplicateLeft))
            } else {
                active[index] = members
            }
        }
        guard !active.isEmpty else { return [] }
        let volumeID = try await remote.ownPhotosVolumeID()
        var kept: [Int: PhotoUID] = [:]
        var duplicates: [Int: [PhotoUID]] = [:]
        for (index, members) in active {
            kept[index] = requests[index].kept
            duplicates[index] = members.filter { $0 != requests[index].kept }
        }
        // The compounds come from the metadata endpoints and the nodes from the SDK, so the two reads overlap.
        let mainLinks = Set(active.values.joined().map(\.nodeID)).sorted()
        async let compoundRead = checker.compounds(ofMainLinks: mainLinks)
        var facts = await nodeFacts(of: duplicates)
        let compounds = try await compoundRead

        // A group whose photo to keep the person did not choose keeps a shared duplicate in place of an unshared
        // photo: a trash would end the sharing of the duplicate. Only these groups read the node of that photo.
        var sharedInstead: [Int: PhotoUID] = [:]
        for (index, result) in facts where !requests[index].isKeptChosen {
            guard case .success(let read) = result,
                let shared = duplicates[index]?.first(where: { read[$0]?.isShared == true })
            else { continue }
            sharedInstead[index] = shared
        }
        if !sharedInstead.isEmpty,
            let keptFacts = try? await remote.nodeFacts(of: sharedInstead.keys.compactMap { kept[$0] })
        {
            for (index, shared) in sharedInstead {
                guard let photo = kept[index], let fact = keptFacts[photo], !fact.isShared,
                    case .success(var read)? = facts[index]
                else { continue }
                read[photo] = fact
                facts[index] = .success(read)
                kept[index] = shared
                duplicates[index] = active[index]?.filter { $0 != shared }
            }
        }

        var plans: [(index: Int, plan: PlannedMerge)] = []
        for index in active.keys.sorted() {
            try Task.checkCancellation()
            let contentHash = requests[index].group.contentHash
            guard let keptPhoto = kept[index], let keptCompound = compounds[keptPhoto.nodeID],
                keptCompound.main.contentHash == contentHash
            else {
                results[index] = .success(.skipped(.keptUnreadable))
                continue
            }
            let read: [PhotoUID: ExactDuplicateNodeFacts]
            switch facts[index] {
            case .success(let value)?:
                read = value
            case .failure(let error)?:
                results[index] = .failure(error)
                continue
            case nil:
                read = [:]
            }
            var plan = PlannedMerge(kept: keptPhoto, contentHash: contentHash, epoch: epoch, volumeID: volumeID)
            for member in duplicates[index] ?? [] {
                // A node that the read did not return proves nothing, so the duplicate stays.
                guard let fact = read[member] else {
                    plan.keptDuplicates[member] = .unreadable
                    continue
                }
                // A trash ends the sharing of a photo, so a shared duplicate stays.
                guard !fact.isShared else {
                    plan.keptDuplicates[member] = .shared
                    continue
                }
                guard let compound = compounds[member.nodeID], compound.main.contentHash == contentHash else {
                    plan.keptDuplicates[member] = .unreadable
                    continue
                }
                // The trash takes the related files along. Each needs a copy under the kept photo.
                guard let twins = UploadRemoteReplacementSafety.relatedTwins(of: compound, under: keptCompound) else {
                    plan.keptDuplicates[member] = .relatedFileWithoutTwin
                    continue
                }
                let memberMoves =
                    [UploadRemoteLinkMove(from: member.nodeID, to: keptPhoto.nodeID, contentHash: contentHash)]
                    + compound.related.compactMap { file in
                        twins[file.linkID].map {
                            UploadRemoteLinkMove(from: file.linkID, to: $0.linkID, contentHash: file.contentHash)
                        }
                    }
                plan.candidates.append((member, Set([member.nodeID] + compound.related.map(\.linkID)), memberMoves))
                plan.albums[member] = fact.albums
            }
            plans.append((index, plan))
        }
        return plans
    }

    /// The node facts of the duplicates of each group, with one read for all of them. When that read fails, each group
    /// reads its own duplicates, so a node that cannot be read fails only its own group.
    private func nodeFacts(of duplicates: [Int: [PhotoUID]]) async -> [Int: NodeFactsRead] {
        do {
            let read = try await remote.nodeFacts(of: Array(Set(duplicates.values.joined())))
            return duplicates.mapValues { _ in .success(read) }
        } catch {
            var facts: [Int: NodeFactsRead] = [:]
            var lastError: any Error = error
            var failuresInARow = 0
            for (index, members) in duplicates.sorted(by: { $0.key < $1.key }) {
                if Task.isCancelled { lastError = CancellationError() }
                guard failuresInARow < Self.nodeReadFailureLimit, !Task.isCancelled else {
                    facts[index] = .failure(lastError)
                    continue
                }
                do {
                    facts[index] = .success(try await remote.nodeFacts(of: members))
                    failuresInARow = 0
                } catch {
                    facts[index] = .failure(error)
                    lastError = error
                    failuresInARow += 1
                }
            }
            return facts
        }
    }

    /// The local checks, right before the writes: a member that the edit replacement tracks, or that a local source
    /// needs and whose row cannot move, stays.
    private func decide(_ plan: inout PlannedMerge, owners: [String: [UploadSourceIdentity]]?) {
        for candidate in plan.candidates {
            guard !journal.namesAnyLink(candidate.links) else {
                plan.keptDuplicates[candidate.member] = .pendingEditReplacement
                continue
            }
            let isCovered = { [epoch = plan.epoch] (row: UploadSourceIdentity, linkID: String) -> Bool in
                guard let record = identities.record(for: row), record.remoteLinkID == linkID,
                    record.hashKeyEpoch == epoch
                else { return false }
                return candidate.moves.contains { $0.from == linkID && $0.contentHash == record.contentHash }
            }
            guard !identities.isNeededElsewhere(candidate.links, except: isCovered, sources: { owners?[$0] }) else {
                plan.keptDuplicates[candidate.member] = .neededByLocalSource
                continue
            }
            plan.trashable.append(candidate.member)
            plan.moves += candidate.moves
        }
    }

    /// Carries the favorite tag, the own albums, and the album covers over and moves the rows of every group at once:
    /// one favorite write for every kept photo whose duplicates carry the tag, one add for each own album, and one row
    /// move. The node read of the plan gave the albums of the duplicates right before. One trash then takes the
    /// duplicates of every group, and the backup drops its cached remote state once. `favorites` holds the favorites
    /// among the trashed and the kept photos; `covers` holds the cover link of each own album. A failed write fails the
    /// groups that it covers, and they take no part in the trash.
    /// A failed trash fails every group that took part: their rows already name `kept`, which holds the same bytes,
    /// so a retry finds them moved and writes them no second time. Known gap: after a failed or cancelled trash, no
    /// group reads its kept photo again, so a merge on another device that trashed that kept photo at the same moment
    /// is not undone here.
    private func write(
        _ writes: [(index: Int, plan: PlannedMerge)], favorites: Set<PhotoUID>, covers: [String: String],
        into results: inout [Result<ExactDuplicateMergeOutcome, any Error>?]
    ) async {
        var failed: Set<Int> = []
        let tagged = writes.filter {
            PhotoCarryOverRule.takesFavorite($0.plan.kept, from: $0.plan.trashable, favorites: favorites)
        }
        if !tagged.isEmpty, !Task.isCancelled {
            do {
                try await remote.markFavorite(tagged.map(\.plan.kept))
            } catch {
                for (index, _) in tagged {
                    results[index] = .failure(error)
                    failed.insert(index)
                }
            }
        }
        // Every album gets the add: a cached membership of a kept photo can be stale, and an existing membership
        // counts as success, so a retry adds nothing twice.
        var albumAdds: [String: [(index: Int, kept: PhotoUID)]] = [:]
        for (index, plan) in writes where !failed.contains(index) {
            let albumIDs = PhotoCarryOverRule.ownAlbumIDs(
                of: plan.trashable, in: plan.albums, ownVolumeID: plan.volumeID)
            for albumID in albumIDs { albumAdds[albumID, default: []].append((index, plan.kept)) }
        }
        for (albumID, members) in albumAdds.sorted(by: { $0.key < $1.key }) {
            let adding = members.filter { !failed.contains($0.index) }
            guard !adding.isEmpty, !Task.isCancelled else { continue }
            do {
                try await albums.addPhotos(adding.map(\.kept), toOwnAlbum: albumID)
            } catch {
                for (index, _) in adding {
                    results[index] = .failure(error)
                    failed.insert(index)
                }
            }
        }
        // The add made each kept photo a member of these albums. A retry finds the kept photo as their cover.
        for (index, plan) in writes where !failed.contains(index) && !Task.isCancelled {
            let trashedLinks = Set(plan.trashable.map(\.nodeID))
            do {
                for (albumID, cover) in covers.sorted(by: { $0.key < $1.key }) where trashedLinks.contains(cover) {
                    try Task.checkCancellation()
                    try await albums.setCover(plan.kept, ofOwnAlbum: albumID)
                }
            } catch {
                results[index] = .failure(error)
                failed.insert(index)
            }
        }
        let trashing = writes.filter { !failed.contains($0.index) }
        guard !trashing.isEmpty, !Task.isCancelled else { return }
        // The rows move before the trash: the kept photos hold the same bytes, and after the trash only the trashed
        // links would name the related files that a retry has to move. One transaction moves the rows of every group.
        guard identities.rebindRemoteLinks(trashing.flatMap(\.plan.moves), hashKeyEpoch: trashing[0].plan.epoch) else {
            let error = UploadError.backend("Upload identity manifest could not be updated")
            for (index, _) in trashing { results[index] = .failure(error) }
            return
        }
        do {
            try await remote.trashDuplicates(trashing.flatMap(\.plan.trashable))
        } catch {
            // A failed trash can still have moved some photos.
            await resolver.remoteMainsChangedHere()
            for (index, _) in trashing { results[index] = .failure(error) }
            return
        }
        // The backup's cached remote state names the trashed links as active backups. A running library check keeps
        // going: the trash is a later event, which the refresh after the check applies.
        await resolver.remoteMainsChangedHere()
        // The carry-over can have tagged a kept photo as favorite.
        rankingContext.invalidate()
        // A merge on another device can keep another member and trash `kept` at the same moment. Each device reads
        // `kept` after its own trash, so at least one of them sees the other trash and restores its duplicates.
        let keptVisibility: [String: RemoteLinkVisibility]
        do {
            keptVisibility = try await visibilityAfterTrash(of: trashing.map(\.plan.kept.nodeID))
        } catch {
            for (index, _) in trashing { results[index] = .failure(error) }
            return
        }
        var restored = false
        for (index, plan) in trashing {
            guard keptVisibility[plan.kept.nodeID]?.isActiveMain != true else {
                results[index] = .success(
                    .merged(kept: plan.kept, trashed: plan.trashable, keptDuplicates: plan.keptDuplicates))
                continue
            }
            restored = true
            do {
                results[index] = .success(try await restore(plan))
            } catch {
                results[index] = .failure(error)
            }
        }
        if restored { await resolver.remoteMainsChangedHere() }
    }

    /// Restores the duplicates of a group whose kept photo left the library during the trash, and moves their rows
    /// back. Rows that named `kept` before the merge move to the first of them: it holds the same bytes and stays in
    /// the library.
    private func restore(_ plan: PlannedMerge) async throws -> ExactDuplicateMergeOutcome {
        try await remote.restoreDuplicates(plan.trashable)
        let movesBack = plan.moves.map { UploadRemoteLinkMove(from: $0.to, to: $0.from, contentHash: $0.contentHash) }
        guard identities.rebindRemoteLinks(movesBack, hashKeyEpoch: plan.epoch) else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
        return .skipped(.keptLeftLibraryDuringMerge)
    }

    /// Reads the kept photos after the trash, up to `keptReadAttempts` times. Throws the last error when every read
    /// fails.
    private func visibilityAfterTrash(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        var attempt = 1
        while true {
            do {
                return try await checker.linkVisibility(batching: linkIDs)
            } catch let error where !(error is CancellationError) && attempt < Self.keptReadAttempts {
                attempt += 1
                try await Task.sleep(for: keptReadRetryDelay)
            }
        }
    }
}

/// Collects the pages of a ranking.
private actor RankingCollector {
    private(set) var members: [String: [PhotoUID]] = [:]

    func add(_ page: [String: [PhotoUID]]) {
        members.merge(page) { _, new in new }
    }
}

/// The own volume and the favorites for the ranking, read once and shared by the pages of a screen session. The read
/// covers every member of the last scan, so one favorites listing serves each page that the person scrolls to. A
/// merge drops it, and it expires after `lifetime`.
final class ExactDuplicateRankingContext: @unchecked Sendable {
    static let lifetime: TimeInterval = 300
    private let lock = NSLock()
    private var members: Set<PhotoUID> = []
    private var cached: (volumeID: String, favorites: Set<PhotoUID>, covered: Set<PhotoUID>, readAt: Date)?

    /// The members that the next read covers.
    func scope(_ scanned: [PhotoUID]) {
        lock.withLock { members = Set(scanned) }
    }

    func value(
        for requested: [PhotoUID], remote: any ExactDuplicateRemote
    ) async throws -> (volumeID: String, favorites: Set<PhotoUID>) {
        let (cached, scope) = lock.withLock { (cached, members) }
        if let cached, Date().timeIntervalSince(cached.readAt) < Self.lifetime,
            cached.covered.isSuperset(of: requested)
        {
            return (cached.volumeID, cached.favorites)
        }
        let covered = scope.union(requested)
        let volumeID = try await remote.ownPhotosVolumeID()
        let favorites = try await remote.favoriteUIDs(among: Array(covered))
        lock.withLock { self.cached = (volumeID, favorites, covered, Date()) }
        return (volumeID, favorites)
    }

    func invalidate() {
        lock.withLock { cached = nil }
    }
}
