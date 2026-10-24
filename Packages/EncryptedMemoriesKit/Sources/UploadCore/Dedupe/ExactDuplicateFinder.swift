import Foundation
import PhotosCore

/// Remote reads, related-file transfers and the trash write of the duplicate merge.
public protocol ExactDuplicateRemote: PhotoCarryOverRemote {
    /// Downloads one related file into caller-owned staging and returns its source metadata. The caller owns cleanup.
    func downloadRelatedFile(
        _ uid: PhotoUID, to destination: URL, allowsExpensiveNetwork: Bool
    ) async throws -> SeriesMemberSource
    /// Uploads staged bytes as a related file of the kept main, with the supplied integrity digest.
    /// The conformer reserves the network using `request.allowsExpensiveNetwork`.
    /// The caller must set `allowsExpensiveNetwork` explicitly. The finder uses the Use Mobile Data setting,
    /// never the request's default.
    func uploadRelatedFile(_ request: PhotoUploadRequest) async throws -> PhotoUID
    /// Moves the duplicates to the Proton trash on the path of the person's own trash, so Recently Deleted shows them.
    func trashDuplicates(_ uids: [PhotoUID]) async throws
    /// Restores photos that a merge moved to the trash, on the path of the person's own restore.
    func restoreDuplicates(_ uids: [PhotoUID]) async throws
    /// The capture dates that the device already knows, without a request. Unknown photos are left out.
    func captureDates(of uids: [PhotoUID]) async -> [PhotoUID: Date]
    /// The sharing state and the size of each photo, from one node read for each photo. A trash ends the sharing.
    func nodeFacts(of uids: [PhotoUID]) async throws -> [PhotoUID: ExactDuplicateNodeFacts]
}

/// A remote that has no related-file transfer implementation must never report a successful copy.
public enum ExactDuplicateRelatedFileTransferError: Error, Sendable, Equatable {
    case unavailable
    case copyFailed(Failure)
    case waitingForWiFi

    public enum Failure: Sendable, Equatable {
        case staging
        case destination
        case size
        case capacity
        case integrity
        case transfer
        case cleanup
    }
}

extension ExactDuplicateRemote {
    /// Fails before any file or remote operation until the backend implements related-file downloads.
    public func downloadRelatedFile(
        _ uid: PhotoUID, to destination: URL, allowsExpensiveNetwork: Bool
    ) async throws -> SeriesMemberSource {
        throw ExactDuplicateRelatedFileTransferError.unavailable
    }

    /// Fails before any file or remote operation until the backend implements related-file uploads.
    public func uploadRelatedFile(_ request: PhotoUploadRequest) async throws -> PhotoUID {
        throw ExactDuplicateRelatedFileTransferError.unavailable
    }
}

/// What one node read tells about a photo.
public struct ExactDuplicateNodeFacts: Sendable, Equatable {
    /// The person shares the photo with other people or by a link.
    public let isShared: Bool
    /// The size of the photo's file in bytes, as its uploader stated it. Nil when the node has none.
    public let byteSize: Int64?
    /// Every album that contains the photo, shared albums included.
    public let albums: [SeriesAlbumReference]
    /// The metadata of the photo that the app shows. A node without metadata has a fingerprint without values.
    public let fingerprint: ExactDuplicateFingerprint

    public init(
        isShared: Bool, byteSize: Int64?, albums: [SeriesAlbumReference] = [],
        fingerprint: ExactDuplicateFingerprint = ExactDuplicateFingerprint()
    ) {
        self.isShared = isShared
        self.byteSize = byteSize
        self.albums = albums
        self.fingerprint = fingerprint
    }
}

/// Two or more main photos of the own library with the same bytes, and after the node reads also the same metadata.
public struct ExactDuplicateGroup: Sendable, Equatable, Identifiable {
    /// The content hash, until the group splits by metadata. See `split(by:keepingIDWith:)`.
    public let id: String
    /// The keyed content hash that all members share.
    public let contentHash: String
    /// The key epoch of `contentHash`. A merge under another key reads nothing and writes nothing.
    public let hashKeyEpoch: String
    /// Active main photos, sorted by link ID.
    public let members: [PhotoUID]
    /// The metadata that every member has. Nil while the members' nodes were not read, as after a scan.
    public let fingerprint: ExactDuplicateFingerprint?

    public init(
        contentHash: String, hashKeyEpoch: String, members: [PhotoUID],
        fingerprint: ExactDuplicateFingerprint? = nil, id: String? = nil
    ) {
        self.id = id ?? contentHash
        self.contentHash = contentHash
        self.hashKeyEpoch = hashKeyEpoch
        self.members = members
        self.fingerprint = fingerprint
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

/// The members of some groups in the order of the photo to keep, with the number of groups that the page covers. Every
/// dictionary is keyed by group ID. A group whose facts could not be read is not in `members` and keeps its fallback
/// order.
public struct ExactDuplicateRankingPage: Sendable, Equatable {
    public let members: [String: [PhotoUID]]
    public let groupCount: Int
    /// The size of one copy of each group in bytes, from the node reads of the ranking.
    public let byteSizes: [String: Int64]
    /// The shared members of each ranked group. A trash would end their sharing.
    public let shared: [String: Set<PhotoUID>]
    /// The facts of each member of each ranked group, as the ranking read them for the order.
    public let facts: [String: [PhotoUID: ExactDuplicateKeepFacts]]
    /// The size of each member of each ranked group in bytes, where its node states one.
    public let memberByteSizes: [String: [PhotoUID: Int64]]
    /// The metadata of each member of each ranked group. Only members with equal metadata are duplicates; a member
    /// without an entry is no duplicate.
    public let fingerprints: [String: [PhotoUID: ExactDuplicateFingerprint]]

    public init(
        members: [String: [PhotoUID]], groupCount: Int, byteSizes: [String: Int64] = [:],
        shared: [String: Set<PhotoUID>] = [:], facts: [String: [PhotoUID: ExactDuplicateKeepFacts]] = [:],
        memberByteSizes: [String: [PhotoUID: Int64]] = [:],
        fingerprints: [String: [PhotoUID: ExactDuplicateFingerprint]] = [:]
    ) {
        self.members = members
        self.groupCount = groupCount
        self.byteSizes = byteSizes
        self.shared = shared
        self.facts = facts
        self.memberByteSizes = memberByteSizes
        self.fingerprints = fingerprints
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
    /// The metadata of the photo, such as its date or place, differ from the kept photo, so it is no duplicate.
    case differentDetails
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
    /// The metadata of the photo to keep changed since the screen read them.
    case keptDetailsChanged
    /// The screen preselected the photo to keep, and another copy ranks first by the server facts of now, for example
    /// after a favorite was set on another device.
    case preselectionChanged
}

/// One group to merge and the photo to keep.
public struct ExactDuplicateMergeRequest: Sendable {
    public let group: ExactDuplicateGroup
    public let kept: PhotoUID
    /// The person chose `kept`. Otherwise the screen preselected it by `ExactDuplicateFinder.keepOrder`, and the merge
    /// keeps it only while it still ranks first.
    public let isKeptChosen: Bool

    public init(group: ExactDuplicateGroup, kept: PhotoUID, isKeptChosen: Bool) {
        self.group = group
        self.kept = kept
        self.isKeptChosen = isKeptChosen
    }
}

public enum ExactDuplicateMergeOutcome: Sendable, Equatable {
    case merged(kept: PhotoUID, trashed: [PhotoUID], keptDuplicates: [PhotoUID: ExactDuplicateKeepReason])
    case skipped(ExactDuplicateSkipReason)
}

/// The facts that rank the members of a group for the photo to keep.
public struct ExactDuplicateKeepFacts: Sendable, Equatable {
    /// The person shares the photo with other people or by a link.
    public var isShared: Bool
    public var isInOwnAlbum: Bool
    public var isFavorite: Bool
    /// A local source of this device counts the photo as its backup. Only information: another device counts other
    /// copies, so this fact never ranks.
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

/// Finds exact duplicates in the own Proton library and merges them.
///
/// A group holds two or more active main photos with the same content hash in the current key epoch. The content
/// index of the backup dedupe supplies the hashes, so the scan reads no media bytes. The node reads of the ranking add
/// the metadata of each member (`ExactDuplicateFingerprint`); only members with equal metadata stay one group. Related files, photos of shared
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
    /// The merges whose trash ran and whose kept photo was not confirmed yet.
    let mergeJournal: any ExactDuplicateMergeJournaling
    let remote: any ExactDuplicateRemote
    let albums: any SeriesAlbumCarryOver
    /// Receives the duration and the request count of each phase, never an identifier.
    let log: @Sendable (String) -> Void
    /// The volume and the favorites that the ranking reads once and shares across its pages.
    let rankingContext = ExactDuplicateRankingContext()
    /// The merges of this finder between their record and the check of their kept photo.
    let mergesInFlight = ExactDuplicateMergesInFlight()
    /// The checks of the pending merges, one at a time.
    let pendingChecks = ExactDuplicateTurns()
    /// The merges and the emptyings of Recently Deleted, one at a time.
    let mergeTurns = ExactDuplicateTurns()

    public init(
        checker: any UploadDuplicateChecking,
        resolver: any UploadIdentityResolving,
        index: any UploadRemoteContentIndexStore,
        identities: any UploadIdentityStore,
        journal: any EditReplacementJournaling,
        mergeJournal: any ExactDuplicateMergeJournaling,
        remote: any ExactDuplicateRemote,
        albums: any SeriesAlbumCarryOver,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.checker = checker
        self.resolver = resolver
        self.index = index
        self.identities = identities
        self.journal = journal
        self.mergeJournal = mergeJournal
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
    /// running build never holds the scan. A merge that waits for the check of its kept photo is checked first.
    public func duplicateGroups() async throws -> ExactDuplicateScan {
        try await duplicateGroups(progress: { _ in })
    }

    /// `duplicateGroups()` that reports how many candidate photos the visibility read has covered.
    public func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan {
        await resolvePendingMerges()
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
        let report: @Sendable (Int) async -> Void = { completed in
            await progress(
                ExactDuplicateScanProgress(completed: min(completed * size, links.count), total: links.count))
        }
        let reads = try await BoundedConcurrency.throwingMap(
            batches, limit: Self.visibilityConcurrency, progress: report
        ) {
            try await checker.linkVisibility(of: $0)
        }
        let visibility = reads.reduce(into: [String: RemoteLinkVisibility]()) { $0.merge($1) { _, new in new } }
        return (visibility, batches.count)
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
            groups.map { ($0.id, Self.keepOrder($0.members, facts: facts)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The capture dates of `members` that the device already knows, without a request. Unknown photos are left out.
    public func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] {
        await remote.captureDates(of: members)
    }

    /// The members of each group by group ID, the photo to keep first. A group whose facts could not be read is left
    /// out, so it keeps its fallback order.
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
            var pageFacts: [String: [PhotoUID: ExactDuplicateKeepFacts]] = [:]
            var memberSizes: [String: [PhotoUID: Int64]] = [:]
            var fingerprints: [String: [PhotoUID: ExactDuplicateFingerprint]] = [:]
            for group in page {
                guard let read = facts[group.id] else {
                    failed += 1
                    continue
                }
                let shared = Set(group.members.filter { read[$0]?.isShared == true })
                if !shared.isEmpty { sharedMembers[group.id] = shared }
                if let size = group.members.lazy.compactMap({ read[$0]?.byteSize }).first(where: { $0 > 0 }) {
                    sizes[group.id] = size
                }
                let known = group.members.compactMap { member in
                    read[member]?.byteSize.flatMap { $0 > 0 ? (member, $0) : nil }
                }
                if !known.isEmpty {
                    memberSizes[group.id] = Dictionary(known, uniquingKeysWith: { first, _ in first })
                }
                fingerprints[group.id] = read.mapValues(\.fingerprint)
                var memberFacts: [PhotoUID: ExactDuplicateKeepFacts] = [:]
                for member in group.members {
                    memberFacts[member] = Self.keepFacts(
                        of: member, node: read[member], ownVolumeID: context.volumeID, favorites: context.favorites,
                        knownDate: dates[member], isNamedByManifest: !(owners?[member.nodeID] ?? []).isEmpty)
                }
                order[group.id] = Self.keepOrder(group.members, facts: memberFacts)
                pageFacts[group.id] = memberFacts
            }
            guard !Task.isCancelled else { return }
            await ranked(
                ExactDuplicateRankingPage(
                    members: order, groupCount: page.count, byteSizes: sizes, shared: sharedMembers,
                    facts: pageFacts, memberByteSizes: memberSizes, fingerprints: fingerprints))
        }
        log(
            "[Duplicates] ranking groups=\(groups.count) members=\(members.count) failedGroups=\(failed) "
                + "nodeReads=\(members.count) "
                + "duration=\(start.duration(to: .now))")
    }

    private typealias GroupFacts = [PhotoUID: ExactDuplicateNodeFacts]

    /// The node facts of the members of each group by group ID, albums and metadata included, `rankingConcurrency`
    /// groups at once: one node read for each member. A group whose read failed, or missed a member, is missing.
    private func groupFacts(of groups: [ExactDuplicateGroup]) async -> [String: GroupFacts] {
        let remote = remote
        let reads = await BoundedConcurrency.map(groups, limit: Self.rankingConcurrency) { group in
            try? await remote.nodeFacts(of: group.members)
        }
        var facts: [String: GroupFacts] = [:]
        for (group, read) in zip(groups, reads) {
            if let read = read ?? nil, group.members.allSatisfy({ read[$0] != nil }) { facts[group.id] = read }
        }
        return facts
    }

    /// The facts that rank `member`, from its node read and the favorites. The capture time of the node counts, so
    /// every device reads the same date; `knownDate`, the date that this device knows, serves only a node without one.
    static func keepFacts(
        of member: PhotoUID, node: ExactDuplicateNodeFacts?, ownVolumeID: String, favorites: Set<PhotoUID>,
        knownDate: Date?, isNamedByManifest: Bool = false
    ) -> ExactDuplicateKeepFacts {
        ExactDuplicateKeepFacts(
            isInOwnAlbum: (node?.albums ?? []).contains { $0.volumeID == ownVolumeID },
            isFavorite: favorites.contains(member), isNamedByManifest: isNamedByManifest,
            captureDate: node?.fingerprint.captureTime ?? knownDate, isShared: node?.isShared == true)
    }

    /// Ranks the photo to keep first: a shared photo, a photo in an own album, a favorite, the earliest capture date,
    /// and then the smallest link ID. A missing fact ranks last. Every device reads these facts the same from the
    /// server, so every device ranks the same copy first. Whether this device backed a copy up does not count.
    public static func keepOrder(_ members: [PhotoUID], facts: [PhotoUID: ExactDuplicateKeepFacts]) -> [PhotoUID] {
        members.sorted { lhs, rhs in
            let left = facts[lhs]
            let right = facts[rhs]
            for (l, r) in [
                (left?.isShared, right?.isShared), (left?.isInOwnAlbum, right?.isInOwnAlbum),
                (left?.isFavorite, right?.isFavorite),
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

    /// Attempts of the read of `kept` after the trash. When every attempt fails, the merge stays in `mergeJournal`,
    /// and the next scan or merge reads `kept` again.
    static let keptReadAttempts = 3
    /// The wait between two attempts of that read.
    var keptReadRetryDelay: Duration = .milliseconds(500)

    /// Keeps `kept` and moves the other members of `group` to Recently Deleted.
    ///
    /// The merge reads every member again and leaves a member whose trash could lose data: a photo whose metadata
    /// differ from `kept`, a related file without a copy under `kept`, a photo that the edit replacement still tracks,
    /// or a photo that a local source needs and whose manifest row cannot move. The favorite tag and the own albums move to `kept` first, then the manifest
    /// rows, and then the trash. A crash after any step leaves the next step to a retry: the carried state reads as
    /// done, moved rows name `kept`, and trashed members are no members anymore. When `kept` left the library during
    /// the trash, the merge restores the duplicates, so one copy always stays. A merge records its trash in
    /// `mergeJournal` first: after a failed trash, a failed read, or the end of the process, the next scan or merge
    /// reads `kept` again.
    /// With `isKeptChosen` false, `kept` is a preselection: the merge keeps it only while it ranks first.
    public func merge(
        _ group: ExactDuplicateGroup, keeping kept: PhotoUID, isKeptChosen: Bool = true
    ) async throws -> ExactDuplicateMergeOutcome {
        try await merge([ExactDuplicateMergeRequest(group: group, kept: kept, isKeptChosen: isKeptChosen)])[0].get()
    }

    /// Merges each group like `merge(_:keeping:)`, with one manifest scan, one favorites listing, one album listing,
    /// and one trash for all groups.
    public func merge(
        _ requests: [ExactDuplicateMergeRequest]
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        await merge(requests, in: ExactDuplicateMergeRun(members: requests.flatMap(\.group.members)))
    }

    /// Merges each group like `merge(_:keeping:)`, with one manifest scan and one trash for all groups. The favorites
    /// listing and the album listing come from `run`, which reads each once for all its batches.
    ///
    /// Every group reads its server state first. The local checks, the carry-over, and the row moves follow, group by
    /// group, and then one trash takes the duplicates of every group. Each group holds its outcome or its error; a
    /// failed trash fails every group that it should have taken. After a cancellation, no further group writes, and
    /// every group without an outcome fails with `CancellationError`.
    ///
    /// A preselected photo to keep is ranked again with the favorites of the run: the ranking of the screen can predate
    /// a favorite set since. A failed listing fails every group. The carry-over also takes the favorite tags that the
    /// compound reads of the group show, so a favorite set elsewhere during the run moves to the kept photo.
    ///
    /// A merge waits while Recently Deleted is emptied (`excludingMerges(_:)`), and the emptying waits for a running
    /// merge.
    public func merge(
        _ requests: [ExactDuplicateMergeRequest], in run: ExactDuplicateMergeRun
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        do {
            return try await mergeTurns.runOrThrow { await mergeInTurn(requests, in: run) }
        } catch {
            return requests.map { _ in .failure(error) }
        }
    }

    /// Runs `body`, which empties Recently Deleted, while no merge of this finder runs, and holds new merges until it
    /// ends. A merge that trashed its copies between the check of the open merges and the emptying would lose them for
    /// good. Throws `CancellationError` without running `body` when the task is cancelled while it waits, also when the
    /// cancellation arrives as the turn passes to it: a cancelled emptying deletes nothing.
    public func excludingMerges(_ body: () async throws -> Void) async throws {
        try await mergeTurns.runOrThrow {
            try Task.checkCancellation()
            try await body()
        }
    }

    private func mergeInTurn(
        _ requests: [ExactDuplicateMergeRequest], in run: ExactDuplicateMergeRun
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        await resolvePendingMerges()
        var results = [Result<ExactDuplicateMergeOutcome, any Error>?](repeating: nil, count: requests.count)
        var favorites: Set<PhotoUID> = []
        let preselected = requests.filter { !$0.isKeptChosen }.flatMap(\.group.members)
        if !preselected.isEmpty, !Task.isCancelled {
            do {
                favorites = try await run.favorites(among: preselected, remote: remote)
            } catch {
                return requests.map { _ in .failure(error) }
            }
        }
        var plans: [(index: Int, plan: PlannedMerge)] = []
        for (index, request) in requests.enumerated() where !Task.isCancelled {
            do {
                switch try await plan(
                    request.group, keeping: request.kept, rankingFavorites: request.isKeptChosen ? nil : favorites)
                {
                case .skipped(let reason):
                    results[index] = .success(.skipped(reason))
                    // The screen ranks the group again and must not take the favorites that it holds.
                    if reason == .preselectionChanged { rankingContext.invalidate() }
                case .planned(let plan): plans.append((index, plan))
                }
            } catch {
                results[index] = .failure(error)
            }
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
                    let written = writes.flatMap { $0.plan.trashable + [$0.plan.kept] }
                    // The compound reads are fresh: they show a favorite that another device set during the run. The
                    // run takes them before it answers.
                    let tagged = Set(writes.flatMap(\.plan.taggedFavorites))
                    run.noteFavorites(tagged)
                    rankingContext.noteFavorites(tagged)
                    // A kept photo counts as favorite only by its fresh tag: the listing can predate a favorite
                    // removed elsewhere, and the carry-over then must still tag it.
                    let kept = Set(writes.map(\.plan.kept))
                    let favorites = try await run.favorites(among: written, remote: remote).subtracting(kept)
                        .union(tagged.intersection(kept))
                    // One album listing serves the run: an own album whose cover leaves gets the kept photo.
                    let covers = try await run.covers(albums: albums)
                    await write(writes, favorites: favorites, covers: covers, run: run, into: &results)
                } catch {
                    for (index, _) in writes { results[index] = .failure(error) }
                }
            }
        }
        return results.map { $0 ?? .failure(CancellationError()) }
    }

    /// A group whose server state allows a merge, with the members that a trash could take.
    private struct PlannedMerge {
        let kept: PhotoUID
        let contentHash: String
        let epoch: String
        let volumeID: String
        var candidates: [(member: PhotoUID, links: Set<String>, moves: [UploadRemoteLinkMove])] = []
        var keptDuplicates: [PhotoUID: ExactDuplicateKeepReason] = [:]
        /// The members that the trash takes, and the rows that move with them. `decide` fills both.
        var trashable: [PhotoUID] = []
        var moves: [UploadRemoteLinkMove] = []
        /// The trashable members with their moves, as `mergeJournal` records them.
        var members: [ExactDuplicateMergeIntent.Member] = []
        /// The kept photo and the candidates whose compound read shows Proton's favorite tag.
        var taggedFavorites: [PhotoUID] = []

        func intent(trashedAt: Int64, successors: [String]?) -> ExactDuplicateMergeIntent {
            ExactDuplicateMergeIntent(
                volumeID: volumeID, kept: kept.nodeID, contentHash: contentHash, hashKeyEpoch: epoch, members: members,
                trashedAt: trashedAt, successors: successors)
        }
    }

    private enum MergePlan {
        case skipped(ExactDuplicateSkipReason)
        case planned(PlannedMerge)
    }

    /// Reads the server state of the group again: the key, the members in the library, and each compound. With
    /// `rankingFavorites`, `kept` is a preselection, and the active members are ranked again with these favorites.
    private func plan(
        _ group: ExactDuplicateGroup, keeping kept: PhotoUID, rankingFavorites: Set<PhotoUID>?
    ) async throws -> MergePlan {
        guard group.members.contains(kept) else { return .skipped(.keptNotInGroup) }
        let epoch = try await checker.hashKeyEpoch()
        guard epoch == group.hashKeyEpoch else { return .skipped(.keyChanged) }
        let visibility = try await checker.linkVisibility(batching: group.members.map(\.nodeID))
        let active = group.members.filter { visibility[$0.nodeID]?.isActiveMain == true }
        guard active.contains(kept) else { return .skipped(.keptLeftLibrary) }
        guard active.count > 1 else { return .skipped(.noDuplicateLeft) }
        let volumeID = try await remote.ownPhotosVolumeID()
        guard var keptCompound = try await checker.compound(ofMainLink: kept.nodeID),
            keptCompound.main.contentHash == group.contentHash
        else { return .skipped(.keptUnreadable) }

        var kept = kept
        var plan = PlannedMerge(kept: kept, contentHash: group.contentHash, epoch: epoch, volumeID: volumeID)
        var compounds: [PhotoUID: UploadRemoteCompound?] = [:]
        // One node read for each member of this group gives the metadata and the sharing state.
        let facts = try await remote.nodeFacts(of: active)
        // The screen offered the group for the metadata that it read. When the kept photo has other metadata now, the
        // screen reads the group again.
        guard let keptFingerprint = facts[kept]?.fingerprint else { return .skipped(.keptUnreadable) }
        if let shown = group.fingerprint, shown != keptFingerprint { return .skipped(.keptDetailsChanged) }
        // Every device ranks the same server facts, so every device that keeps the preselection keeps the same copy.
        // When another copy ranks first now, the screen reads the group again.
        if let listed = rankingFavorites {
            // The favorites of a run can predate a favorite that another device set or removed since. The compound
            // reads are fresh, so their favorite tags rank. Only a member without a compound ranks by the listing.
            for member in active where member != kept {
                try Task.checkCancellation()
                compounds[member] = try await checker.compound(ofMainLink: member.nodeID)
            }
            let fresh = compounds.merging([kept: keptCompound]) { first, _ in first }
            let favorites = Set(
                active.filter { member in
                    guard let compound = fresh[member] ?? nil else { return listed.contains(member) }
                    return compound.tags.contains(PhotoTag.favorites.rawValue)
                })
            // The node states the capture time of a photo. Only a node without one needs the date that this device
            // knows.
            let undated = active.filter { facts[$0]?.fingerprint.captureTime == nil }
            let dates = undated.isEmpty ? [:] : await remote.captureDates(of: undated)
            let ranking = Dictionary(
                uniqueKeysWithValues: active.map {
                    (
                        $0,
                        Self.keepFacts(
                            of: $0, node: facts[$0], ownVolumeID: volumeID, favorites: favorites, knownDate: dates[$0])
                    )
                })
            guard Self.keepOrder(active, facts: ranking).first == kept else { return .skipped(.preselectionChanged) }
            // Require every active compound to be readable with the group hash before considering a swap.
            // The comparable set below separately filters sharing and metadata.
            let allReadable = active.allSatisfy { member in
                guard let compound = fresh[member] ?? nil else { return false }
                return compound.main.contentHash == group.contentHash
            }
            if allReadable {
                let comparable = active.filter { member in
                    facts[member]?.fingerprint == keptFingerprint && facts[member]?.isShared == false
                }
                let covers = { (candidate: PhotoUID) -> Bool in
                    guard let compound = fresh[candidate] ?? nil else { return false }
                    return comparable.allSatisfy { member in
                        guard member != candidate else { return true }
                        guard let other = fresh[member] ?? nil else { return false }
                        return UploadRemoteReplacementSafety.relatedTwins(of: other, under: compound) != nil
                    }
                }
                if comparable.contains(kept) {
                    // Always choose the first covering copy by server facts, even when the preselection covers
                    // everyone. A device date can have picked that preselection when the server capture time is nil.
                    let serverRanking = Dictionary(
                        uniqueKeysWithValues: comparable.map {
                            (
                                $0,
                                Self.keepFacts(
                                    of: $0, node: facts[$0], ownVolumeID: volumeID,
                                    favorites: favorites, knownDate: nil)
                            )
                        })
                    if let covering = Self.keepOrder(comparable.filter(covers), facts: serverRanking).first,
                        covering != kept, let compound = fresh[covering] ?? nil
                    {
                        compounds = fresh
                        kept = covering
                        keptCompound = compound
                        plan = PlannedMerge(
                            kept: kept, contentHash: group.contentHash, epoch: epoch, volumeID: volumeID)
                    }
                }
            }
        }
        if keptCompound.tags.contains(PhotoTag.favorites.rawValue) { plan.taggedFavorites.append(kept) }
        // A trash ends the sharing of a photo, so a shared duplicate stays.
        let shared = Set(facts.filter(\.value.isShared).keys)
        for member in active where member != kept {
            try Task.checkCancellation()
            // A copy with other metadata, such as another date or place, is no duplicate: its trash would lose them.
            guard let fingerprint = facts[member]?.fingerprint, fingerprint == keptFingerprint else {
                plan.keptDuplicates[member] = .differentDetails
                continue
            }
            guard !shared.contains(member) else {
                plan.keptDuplicates[member] = .shared
                continue
            }
            let read: UploadRemoteCompound?
            if let cached = compounds[member] {
                read = cached
            } else {
                read = try await checker.compound(ofMainLink: member.nodeID)
            }
            if read == nil {
                let current = try await checker.linkVisibility(batching: group.members.map(\.nodeID))
                if let currentKept = current[kept.nodeID], currentKept.hasExplicitPhotoState,
                    currentKept.isActiveMain,
                    group.members.filter({ $0 != kept }).allSatisfy({ other in
                        guard let state = current[other.nodeID], state.hasExplicitPhotoState else { return false }
                        return !state.isActive
                    })
                {
                    return .skipped(.noDuplicateLeft)
                }
            }
            guard let compound = read, compound.main.contentHash == group.contentHash else {
                plan.keptDuplicates[member] = .unreadable
                continue
            }
            // The trash takes the related files along. Each needs a copy under the kept photo.
            guard let twins = UploadRemoteReplacementSafety.relatedTwins(of: compound, under: keptCompound) else {
                plan.keptDuplicates[member] = .relatedFileWithoutTwin
                continue
            }
            let memberMoves =
                [UploadRemoteLinkMove(from: member.nodeID, to: kept.nodeID, contentHash: group.contentHash)]
                + compound.related.compactMap { file in
                    twins[file.linkID].map {
                        UploadRemoteLinkMove(from: file.linkID, to: $0.linkID, contentHash: file.contentHash)
                    }
                }
            plan.candidates.append((member, Set([member.nodeID] + compound.related.map(\.linkID)), memberMoves))
            if compound.tags.contains(PhotoTag.favorites.rawValue) { plan.taggedFavorites.append(member) }
        }
        return .planned(plan)
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
                guard let record = identities.record(for: row), record.provesUpload, record.remoteLinkID == linkID,
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
            plan.members.append(.init(link: candidate.member.nodeID, moves: candidate.moves))
        }
    }

    /// Carries the favorite tag, the own albums, and the album covers over and moves the rows, group by group. One
    /// trash then takes the duplicates of every group, and the backup drops its cached remote state once. `favorites`
    /// holds the favorites among the trashed and the kept photos; `covers` holds the cover link of each own album. The
    /// favorite tags and the covers that the carry-over writes update `run` and the ranking context. A group whose
    /// carry-over or row move fails takes no part in the trash.
    /// A failed trash fails every group that took part: their rows already name `kept`, which holds the same bytes,
    /// so a retry finds them moved and writes them no second time. A failed trash can still have moved photos, so
    /// every group reads its kept photo after the trash, also after a failure.
    private func write(
        _ writes: [(index: Int, plan: PlannedMerge)], favorites: Set<PhotoUID>, covers: [String: String],
        run: ExactDuplicateMergeRun, into results: inout [Result<ExactDuplicateMergeOutcome, any Error>?]
    ) async {
        // The trash needs its record, so the merge writes nothing while the journal cannot take one.
        switch mergeJournal.prepareForWrites() {
        case .ready: break
        case .replacedUnreadable: log("[Duplicates] the unreadable merge journal moved aside; a new one starts")
        case .unavailable:
            let error = UploadError.backend("Duplicate merge journal could not be updated")
            for (index, _) in writes { results[index] = .failure(error) }
            return
        }
        var trashing: [(index: Int, plan: PlannedMerge)] = []
        for (index, plan) in writes where !Task.isCancelled {
            // The carry-over tags the kept photo as favorite when a trashed duplicate is one.
            let marksFavorite = !favorites.contains(plan.kept) && plan.trashable.contains(where: favorites.contains)
            do {
                // The albums of the duplicates are read fresh: a cached read can predate an album added since.
                try await remote.carryOver(
                    from: plan.trashable, to: plan.kept, ownVolumeID: plan.volumeID,
                    albums: CurrentAlbumCarryOver(base: albums), favorites: favorites)
                if marksFavorite {
                    run.noteFavorites([plan.kept])
                    rankingContext.noteFavorites([plan.kept])
                }
                // The carry-over added the kept photo to these albums. A retry finds the kept photo as their cover.
                let trashedLinks = Set(plan.trashable.map(\.nodeID))
                for (albumID, cover) in covers.sorted(by: { $0.key < $1.key }) where trashedLinks.contains(cover) {
                    try Task.checkCancellation()
                    try await albums.setCover(plan.kept, ofOwnAlbum: albumID)
                    run.noteCover(plan.kept.nodeID, ofOwnAlbum: albumID)
                }
                // The rows move before the trash: the kept photo holds the same bytes, and after the trash only the
                // trashed links would name the related files that a retry has to move.
                guard identities.rebindRemoteLinks(plan.moves, hashKeyEpoch: plan.epoch) else {
                    throw UploadError.backend("Upload identity manifest could not be updated")
                }
                trashing.append((index, plan))
            } catch {
                // A failed carry-over can have tagged the kept photo, so the next read of the favorites tells.
                if marksFavorite {
                    run.forgetFavorites()
                    rankingContext.invalidate()
                }
                results[index] = .failure(error)
            }
        }
        guard !trashing.isEmpty, !Task.isCancelled else { return }
        // The edits that replaced a kept photo before the trash, so the check counts only a later edit.
        var known: [[String]?] = []
        for (_, plan) in trashing { known.append(await successors(of: plan.kept.nodeID)) }
        guard !Task.isCancelled else { return }
        // The record survives a failed answer and the end of the process, so a later scan or merge restores a copy of
        // a group whose kept photo left the library during the trash.
        let trashedAt = Int64(Date().timeIntervalSince1970)
        let intents = zip(trashing, known).map { $0.plan.intent(trashedAt: trashedAt, successors: $1) }
        mergesInFlight.insert(intents)
        defer { mergesInFlight.remove(intents) }
        guard mergeJournal.record(intents) else {
            let error = UploadError.backend("Duplicate merge journal could not be updated")
            for (index, _) in trashing { results[index] = .failure(error) }
            return
        }
        var trashError: (any Error)?
        do {
            try await remote.trashDuplicates(trashing.flatMap(\.plan.trashable))
        } catch {
            // A failed trash can still have moved some photos.
            trashError = error
        }
        // The backup's cached remote state names the trashed links as active backups. A running library check keeps
        // going: the trash is a later event, which the refresh after the check applies.
        await resolver.remoteMainsChangedHere()
        var restored = false
        let checks: [String: Result<MergeResolution, any Error>]
        do {
            checks = try await resolve(intents, restored: &restored, stopAtFirstFailure: false)
        } catch {
            for (index, _) in trashing { results[index] = .failure(trashError ?? error) }
            return
        }
        for ((index, plan), intent) in zip(trashing, intents) {
            switch checks[intent.key] ?? .failure(CancellationError()) {
            case .success(.restored):
                results[index] = .success(.skipped(.keptLeftLibraryDuringMerge))
            case .success(.kept(let duplicatesLeft)):
                // Devices that merge the same group trash the same links. The trash of a device that comes second can
                // fail for links that are in the trash already, while the group holds its outcome.
                let merged = ExactDuplicateMergeOutcome.merged(
                    kept: plan.kept, trashed: plan.trashable, keptDuplicates: plan.keptDuplicates)
                results[index] = trashError.flatMap { duplicatesLeft ? .failure($0) : nil } ?? .success(merged)
            case .success(.gone):
                results[index] = .failure(
                    trashError ?? UploadError.backend("No copy of the merged duplicates is on the server"))
            case .failure(let error):
                results[index] = .failure(trashError ?? error)
            }
        }
        if restored { await resolver.remoteMainsChangedHere() }
    }

    /// Runs `resolvePendingMerges()` and answers true only when the journal is readable and holds no merge afterwards.
    /// A journal file that does not decode is moved aside, so a later answer can be true.
    public func confirmNoPendingMerges() async -> Bool {
        await resolvePendingMerges()
        return mergeJournal.confirmsNoOpenMerge()
    }

    /// Checks the merges that a failed trash, a failed read, or the end of the process left in `mergeJournal`, with one
    /// read of all their links. A failed read or a connection failure ends the check, so an offline scan waits for one
    /// read and its retries; the merges then stay for the next scan or merge. Any other failure of one merge leaves the
    /// checks of the next merges running. Without a pending merge, nothing is read from the server, so the apps call it
    /// at launch: a group whose copies both left the library comes back before the person opens Duplicates. A check
    /// that starts while another one runs waits for it and then reads the journal again.
    public func resolvePendingMerges() async {
        await pendingChecks.run { await resolvePendingMergesInTurn() }
    }

    private func resolvePendingMergesInTurn() async {
        guard let pending = mergeJournal.pendingMerges() else {
            log("[Duplicates] the merge journal cannot be read")
            return
        }
        let waiting = pending.filter { !mergesInFlight.contains($0) }
        guard !waiting.isEmpty else { return }
        var restored = false
        do {
            let checks = try await resolve(waiting, restored: &restored, stopAtFirstFailure: true)
            if checks.values.contains(where: { (try? $0.get()) == nil }) {
                log("[Duplicates] a merge waits for the check of its kept photo")
            }
        } catch {
            log("[Duplicates] \(waiting.count) merges wait for the check of their kept photos")
        }
        if restored { await resolver.remoteMainsChangedHere() }
    }

    /// What the check of the kept photo after the trash found.
    private enum MergeResolution {
        /// The kept photo is in the library, the person trashed it long after the merge, or its edit replaced it. The
        /// merge stands.
        /// `duplicatesLeft` is true while a member that the trash should take is still in the library.
        case kept(duplicatesLeft: Bool)
        /// The kept photo left the library during the merge. The duplicates are back, and their rows moved back.
        case restored
        /// The server knows none of the links of the merge anymore. Nothing is left to restore.
        case gone
    }

    /// A trash of the kept photo this many server seconds after the trash of the merge is a later deletion, for
    /// example by the person, and no part of a merge on another device. The merge leaves it in the trash.
    static let concurrentTrashWindow: Int64 = 3600
    /// The same window when only the device clock dates the trash of the merge, because the server no longer knows
    /// the trashed duplicates. A device clock can be off by hours, and a too-short window would leave the last copy in
    /// the trash. The cost: when the person deletes the kept photo on purpose within this window after the merge, and
    /// the duplicates left the trash already, the kept photo comes back.
    static let deviceClockTrashWindow: Int64 = 24 * 3600

    /// True when the check of the pending merges cannot go on: the connection failed, or the check was cancelled. Each
    /// later merge would wait for the same reads. Any other failure belongs to one merge.
    static func endsPendingChecks(_ error: any Error) -> Bool {
        if error is CancellationError || error is URLError || BackupSyncRunner.isTransientNetwork(error) {
            return true
        }
        switch error as? UploadError {
        case .retryableBackend, .transport, .cancelled: return true
        default: return false
        }
    }

    /// Checks `intents` with one read of all their links, and removes the finished ones from `mergeJournal` with one
    /// write. Returns the check of each intent by key; an intent without a check did not run. Throws when the read
    /// fails, and every intent stays. `stopAtFirstFailure` ends the checks after the first one that throws for a
    /// reason in `endsPendingChecks`.
    private func resolve(
        _ intents: [ExactDuplicateMergeIntent], restored: inout Bool, stopAtFirstFailure: Bool
    ) async throws -> [String: Result<MergeResolution, any Error>] {
        let links = Set(intents.flatMap { [$0.kept] + $0.members.map(\.link) }).sorted()
        let visibility = try await readAfterTrash(links)
        var checks: [String: Result<MergeResolution, any Error>] = [:]
        var finished: [ExactDuplicateMergeIntent] = []
        for intent in intents where !Task.isCancelled {
            do {
                checks[intent.key] = .success(try await resolve(intent, visibility: visibility, restored: &restored))
                finished.append(intent)
            } catch {
                checks[intent.key] = .failure(error)
                if stopAtFirstFailure, Self.endsPendingChecks(error) { break }
            }
        }
        if !finished.isEmpty, !mergeJournal.clear(finished) {
            log("[Duplicates] the merge journal could not be updated; the next scan checks the merges again")
        }
        return checks
    }

    /// Checks the kept photo of `intent` in `visibility`, which was read after the trash. When the kept photo left the
    /// library meanwhile, and no edit replaced it, restores the duplicates that are not in the library and moves their
    /// rows back. When none of them comes back, restores the kept photo. `restored` turns true once a restore was
    /// needed. Throws while no read confirms an active copy.
    /// The person can delete the kept photo for good on its own while the duplicates are still in the trash. The server
    /// then no longer knows the kept photo, and that looks like a trash of another merge at the same moment, so the
    /// duplicates come back.
    private func resolve(
        _ intent: ExactDuplicateMergeIntent, visibility read: [String: RemoteLinkVisibility], restored: inout Bool
    ) async throws -> MergeResolution {
        let kept = intent.kept
        let trashed = intent.members.map(\.link)
        var visibility = read
        guard ([kept] + trashed).contains(where: { visibility[$0] != nil }) else {
            log("[Duplicates] every photo of a merge left the server; its check ends")
            return .gone
        }
        // A merge on another device can keep another member and trash `kept` at the same moment. Each device reads
        // `kept` after its own trash, so at least one of them sees the other trash and restores its duplicates.
        if visibility[kept]?.isActiveMain == true
            || isLaterDeletion(of: kept, in: visibility, after: trashed, trashedAt: intent.trashedAt)
        {
            return .kept(duplicatesLeft: trashed.contains { visibility[$0]?.isActive == true })
        }
        // An edit on another device can move `kept` to the trash within the window. Its edit then stands for the
        // group, and a restored duplicate would show the unedited photo next to it.
        if try await isReplacedByEdit(intent) {
            log("[Duplicates] an edit replaced the kept photo of a merge; the duplicates stay in the trash")
            return .kept(duplicatesLeft: trashed.contains { visibility[$0]?.isActive == true })
        }
        restored = true
        try await restore(trashed.filter { visibility[$0]?.isActiveMain != true }, volumeID: intent.volumeID)
        visibility = try await readAfterTrash([kept] + trashed)
        let active = Set(trashed.filter { visibility[$0]?.isActiveMain == true })
        guard !active.isEmpty else {
            // No duplicate came back, for example after its deletion from the trash: the kept photo is the last copy.
            try await restore([kept], volumeID: intent.volumeID)
            guard try await readAfterTrash([kept])[kept]?.isActiveMain == true else {
                throw UploadError.backend("No copy of the merged duplicates is in the library")
            }
            return .kept(duplicatesLeft: false)
        }
        // The rows move back to the restored duplicates. Rows that named `kept` before the merge move to the first
        // active one: it holds the same bytes and stays in the library.
        let members =
            intent.members.filter { active.contains($0.link) } + intent.members.filter { !active.contains($0.link) }
        let movesBack = members.flatMap(\.moves).map {
            UploadRemoteLinkMove(from: $0.to, to: $0.from, contentHash: $0.contentHash)
        }
        guard identities.rebindRemoteLinks(movesBack, hashKeyEpoch: intent.hashKeyEpoch) else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
        return .restored
    }

    /// True when the server trashed `kept` more than `concurrentTrashWindow` after the latest trash time of the members
    /// in the trash, or more than `deviceClockTrashWindow` after `trashedAt` when no member is in the trash. A member in
    /// the library can carry the time of an earlier trash, so it dates nothing. Without both times, the merge cannot
    /// tell and restores a copy.
    private func isLaterDeletion(
        of kept: String, in visibility: [String: RemoteLinkVisibility], after trashed: [String], trashedAt: Int64?
    ) -> Bool {
        guard let keptTrash = visibility[kept]?.trashTime else { return false }
        let memberTrash = trashed.compactMap { visibility[$0].flatMap { $0.isActive ? nil : $0.trashTime } }.max()
        if let memberTrash { return keptTrash > memberTrash + Self.concurrentTrashWindow }
        guard let trashedAt else { return false }
        return keptTrash > trashedAt + Self.deviceClockTrashWindow
    }

    /// The active main photos whose lineage names `kept` as replaced. Nil when the read failed or the lineage index is
    /// incomplete: an edit that it misses now would count as a later edit at the check.
    private func successors(of kept: String) async -> [String]? {
        do {
            let read = try await checker.replacingMainLinkIDs(ofReplacedLink: kept)
            guard read.complete else { return nil }
            return read.links.sorted()
        } catch {
            log("[Duplicates] the lineage read before a merge failed; its check restores a copy")
            return nil
        }
    }

    /// True when an active main photo outside the group replaced the kept photo of `intent` by its lineage after the
    /// trash was recorded, as the edit of the photo or the undo of one, and holds a twin of every file that the trash
    /// took, such as the original under an edit. Then no file of the group is lost when the duplicates stay in the
    /// trash. Only a positive read proves the edit: an edit known before the trash, an intent without that read, a
    /// failed read, or a replacement without these files restores a copy as before. An incomplete lineage index can
    /// only miss a replacement, and the reads of the state and of the files confirm each one that it names. A failed
    /// connection throws, so the merge waits for the next check.
    private func isReplacedByEdit(_ intent: ExactDuplicateMergeIntent) async throws -> Bool {
        guard let known = intent.successors else { return false }
        let excluded = Set([intent.kept] + intent.members.map(\.link) + known)
        do {
            let successors = try await checker.replacingMainLinkIDs(ofReplacedLink: intent.kept).links
                .subtracting(excluded).sorted()
            guard !successors.isEmpty else { return false }
            let visibility = try await checker.linkVisibility(batching: successors)
            for link in successors where visibility[link]?.isActiveMain == true {
                guard let compound = try await checker.compound(ofMainLink: link) else { continue }
                if Self.holdsEveryFile(of: intent.members, contentHash: intent.contentHash, in: compound) {
                    return true
                }
            }
        } catch let error where !Self.endsPendingChecks(error) {
            log("[Duplicates] the edit check of a kept photo failed; the merge restores a copy")
        }
        return false
    }

    /// True when `compound` holds a twin of the main file and of each related file of every member, as their moves
    /// name them. Two files of one member never share one twin.
    private static func holdsEveryFile(
        of members: [ExactDuplicateMergeIntent.Member], contentHash: String, in compound: UploadRemoteCompound
    ) -> Bool {
        let files = [compound.main] + compound.related
        return members.allSatisfy { member in
            let related = member.moves.filter { $0.from != member.link }.map(\.contentHash)
            var used: Set<String> = []
            return ([contentHash] + related).allSatisfy { hash in
                guard let twin = files.first(where: { $0.contentHash == hash && !used.contains($0.linkID) }) else {
                    return false
                }
                used.insert(twin.linkID)
                return true
            }
        }
    }

    /// Restores `links`. Its answer decides nothing: a restore can apply before its answer fails, and the server's
    /// answer for a link that is in the library already is unverified. The next read decides.
    private func restore(_ links: [String], volumeID: String) async throws {
        guard !links.isEmpty else { return }
        do {
            try await remote.restoreDuplicates(links.map { PhotoUID(volumeID: volumeID, nodeID: $0) })
        } catch let error where !(error is CancellationError) {
            log("[Duplicates] a restore failed; the next read decides")
        }
    }

    /// Reads `links` after the trash, up to `keptReadAttempts` times. Throws the last error when every read fails.
    private func readAfterTrash(_ links: [String]) async throws -> [String: RemoteLinkVisibility] {
        var attempt = 1
        while true {
            do {
                return try await checker.linkVisibility(batching: links)
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

/// The keys of the merges between their record and the check of their kept photo. A check of the pending merges
/// skips them, so it never removes the record of a trash that is still running.
final class ExactDuplicateMergesInFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func insert(_ intents: [ExactDuplicateMergeIntent]) {
        lock.withLock { keys.formUnion(intents.map(\.key)) }
    }

    func remove(_ intents: [ExactDuplicateMergeIntent]) {
        lock.withLock { keys.subtract(intents.map(\.key)) }
    }

    func contains(_ intent: ExactDuplicateMergeIntent) -> Bool {
        lock.withLock { keys.contains(intent.key) }
    }
}

/// Runs the work of one finder one at a time, in the order of its start. Two checks of the pending merges that ran
/// together could both find a kept photo in the trash and both restore its duplicates and move their rows back. An
/// emptying of Recently Deleted next to a merge could delete the copies that the merge trashed before their check.
final class ExactDuplicateTurns: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// The callers that wait for their turn.
    var waiting: Int { lock.withLock { waiters.count } }
    /// Runs as the turn passes to a waiter, before the waiter resumes. Tests use it to cancel the waiter in that moment.
    var onHandOver: (@Sendable () -> Void)? {
        get { lock.withLock { handOver } }
        set { lock.withLock { handOver = newValue } }
    }
    private var handOver: (@Sendable () -> Void)?

    /// Runs `check` once no earlier caller runs. A task that is cancelled while it waits leaves the queue and runs no
    /// check. A cancellation that arrives as the turn passes to it can still start the check, which then stops before
    /// its first merge.
    func run(_ check: () async -> Void) async {
        guard await enter() else { return }
        await check()
        leave()
    }

    /// Runs `body` like `run(_:)`. Throws `CancellationError` without running it when the task is cancelled while it
    /// waits. A cancellation that arrives as the turn passes to it can still run `body`.
    func runOrThrow<T>(_ body: () async throws -> T) async throws -> T {
        guard await enter() else { throw CancellationError() }
        defer { leave() }
        return try await body()
    }

    private func enter() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let admitted = lock.withLock { () -> Bool? in
                    guard !Task.isCancelled else { return false }
                    guard isRunning else {
                        isRunning = true
                        return true
                    }
                    waiters.append((id, continuation))
                    return nil
                }
                if let admitted { continuation.resume(returning: admitted) }
            }
        } onCancel: {
            lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }?.resume(returning: false)
        }
    }

    /// Hands the turn to the next waiting caller.
    private func leave() {
        let next = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard !waiters.isEmpty else {
                isRunning = false
                return nil
            }
            return waiters.removeFirst().continuation
        }
        if next != nil { onHandOver?() }
        next?.resume(returning: true)
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

    /// Adds favorites that a fresh read or a write of a merge shows, so the next page needs no new listing.
    func noteFavorites(_ uids: Set<PhotoUID>) {
        guard !uids.isEmpty else { return }
        lock.withLock { cached?.favorites.formUnion(uids) }
    }
}

/// The favorites and the album covers of one run of merges, such as Merge All, read once and shared by its batches.
/// The run updates both with the writes of its merges: the favorite tag that a carry-over gives a kept photo, and the
/// covers that move to a kept photo. Another device can change them during the run, so a merge also takes the favorite
/// tags of its fresh compound reads and never loses a favorite set elsewhere.
public final class ExactDuplicateMergeRun: @unchecked Sendable {
    private let lock = NSLock()
    private let members: Set<PhotoUID>
    private var favorites: (covered: Set<PhotoUID>, uids: Set<PhotoUID>)?
    private var covers: [String: String]?

    /// `members` holds the members of every group that the run can merge. One favorites listing covers them all.
    public init(members: [PhotoUID]) {
        self.members = Set(members)
    }

    /// The favorites among `uids`. The first call reads them for every member of the run.
    func favorites(among uids: [PhotoUID], remote: any ExactDuplicateRemote) async throws -> Set<PhotoUID> {
        if let cached = lock.withLock({ favorites }), cached.covered.isSuperset(of: uids) {
            return cached.uids.intersection(uids)
        }
        let covered = members.union(uids)
        let read = try await remote.favoriteUIDs(among: Array(covered))
        lock.withLock { favorites = (covered, read) }
        return read.intersection(uids)
    }

    /// The cover link of each own album that has one, by album ID. The first call reads them.
    func covers(albums: any SeriesAlbumCarryOver) async throws -> [String: String] {
        if let covers = lock.withLock({ covers }) { return covers }
        let read = try await albums.ownAlbumCovers()
        lock.withLock { covers = read }
        return read
    }

    func noteFavorites(_ uids: Set<PhotoUID>) {
        guard !uids.isEmpty else { return }
        lock.withLock { favorites?.uids.formUnion(uids) }
    }

    /// The next call of `favorites(among:remote:)` reads them again.
    func forgetFavorites() {
        lock.withLock { favorites = nil }
    }

    func noteCover(_ link: String, ofOwnAlbum albumID: String) {
        lock.withLock { covers?[albumID] = link }
    }
}
