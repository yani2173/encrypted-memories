import Foundation
import GridCore
import PhotosCore
import UploadCore

/// Upload badges of the grid. The base map changes only with membership; progress ticks replace the small
/// `progress` overlay, so a tick never copies or compares a map with one entry per pending photo.
public struct PendingUploadBadges: Sendable, Equatable {
    /// Identity of this value; hosts compare it instead of the maps.
    private let id: UUID
    package let base: [PhotoUID: GridUploadBadge]
    /// Progress steps of the few photos whose bytes move now, keyed by grid UID.
    package let progress: [PhotoUID: Int]
    /// Local photos whose content changed in Apple Photos during this session, with a growing epoch per
    /// change. The map is cumulative, so a grid that skips a presentation still sees every change and
    /// uploads the new thumbnail. Sparse: only edited photos.
    package let contentEpochs: [PhotoUID: UInt64]
    /// Proton photos that took over a pending tile this session -> that tile's local UID. Grids let the
    /// Proton photo draw the pending tile's texture, so the handover shows no upload and no fade.
    package let handovers: [PhotoUID: PhotoUID]
    /// The person paused the Apple Photos backup: its waiting and uploading photos show the pause badge.
    /// Watched Mac folders do not pause with it.
    package let isPaused: Bool

    package init(
        base: [PhotoUID: GridUploadBadge] = [:],
        progress: [PhotoUID: Int] = [:],
        contentEpochs: [PhotoUID: UInt64] = [:],
        handovers: [PhotoUID: PhotoUID] = [:],
        isPaused: Bool = false
    ) {
        id = UUID()
        self.base = base
        self.progress = progress
        self.contentEpochs = contentEpochs
        self.handovers = handovers
        self.isPaused = isPaused
    }

    /// A new value that keeps the base map and handovers.
    package func replacing(
        progress: [PhotoUID: Int]? = nil, contentEpochs: [PhotoUID: UInt64]? = nil, isPaused: Bool? = nil
    ) -> Self {
        Self(
            base: base, progress: progress ?? self.progress, contentEpochs: contentEpochs ?? self.contentEpochs,
            handovers: handovers, isPaused: isPaused ?? self.isPaused)
    }

    public static let empty = PendingUploadBadges()

    package var isEmpty: Bool { base.isEmpty }

    package subscript(uid: PhotoUID) -> GridUploadBadge? {
        guard let badge = base[uid] else { return nil }
        let shown = progress[uid].map { .uploading(step: $0) } ?? badge
        switch shown {
        case .waiting, .uploading:
            return isPaused && (handovers[uid] ?? uid).localPendingNamespace == .photoLibrary ? .paused : shown
        case .done, .attention, .notBackedUp, .paused:
            return shown
        }
    }

    /// The spoken backup state of `uid`, when VoiceOver should hear one.
    package func accessibilityDescription(for uid: PhotoUID) -> String? {
        self[uid] == .paused ? L10n.string("a11y.upload_badge.paused") : nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Follows `PendingUploadBadges.handovers` for one grid and reports each handover once.
package struct PendingHandoverTracker {
    private var applied = Set<PhotoUID>()

    package init() {}

    package mutating func newHandovers(in handovers: [PhotoUID: PhotoUID]) -> [(local: PhotoUID, remote: PhotoUID)] {
        if applied.count > handovers.count { applied.formIntersection(handovers.keys) }
        var result: [(local: PhotoUID, remote: PhotoUID)] = []
        for (remote, local) in handovers where applied.insert(remote).inserted { result.append((local, remote)) }
        return result
    }
}

/// Follows `PendingUploadBadges.contentEpochs` for one grid and reports the photos whose resident texture
/// shows old content.
package struct PendingContentEpochTracker {
    private var applied: [PhotoUID: UInt64] = [:]

    package init() {}

    package mutating func changes(in epochs: [PhotoUID: UInt64]) -> [PhotoUID] {
        var changed: [PhotoUID] = []
        for (uid, epoch) in epochs where applied[uid].map({ epoch > $0 }) ?? true {
            changed.append(uid)
            applied[uid] = epoch
        }
        if applied.count > epochs.count { applied = applied.filter { epochs[$0.key] != nil } }
        return changed
    }
}

/// The whole-library timeline as the grid shows it: Proton photos plus local photos that the backup has not
/// uploaded yet. Hosts on iOS, iPadOS and macOS keep their canonical Proton snapshot for every remote-only
/// consumer and show this presentation in the grid and viewer.
public struct PendingTimelinePresentation: Sendable {
    /// Changes with every publication, including badge-only updates.
    public let revision: UInt64
    /// Changes only when the item list changes; grids rebuild content only for this one.
    public let membershipRevision: UInt64
    /// Grid order. Photos that replaced a pending tile keep that tile's position for the session.
    public let snapshot: TimelineSnapshot
    /// Local pending photos in the presentation; the thumbnail feed may load exactly these from the device.
    public let localUIDs: Set<PhotoUID>
    /// Desired favorite states of pending photos, shown before the upload applies them.
    public let favoriteIntents: [PhotoUID: Bool]
    /// Upload badges for the grid; opaque outside the package.
    public let uploadBadges: PendingUploadBadges
    /// True when no pending photo shows; hosts can then use their canonical snapshot directly.
    public let isCanonical: Bool
    /// Earlier photo -> the photo that shows in its place: an edited photo -> the tile of its edit, and the tile
    /// of an edit -> the Proton photo that took it over. An open viewer follows these steps.
    public let replacements: [PhotoUID: PhotoUID]

    public var items: [PhotoItem] { snapshot.items }

    package init(
        revision: UInt64,
        membershipRevision: UInt64,
        snapshot: TimelineSnapshot,
        localUIDs: Set<PhotoUID>,
        favoriteIntents: [PhotoUID: Bool],
        uploadBadges: PendingUploadBadges,
        isCanonical: Bool,
        replacements: [PhotoUID: PhotoUID] = [:]
    ) {
        self.revision = revision
        self.membershipRevision = membershipRevision
        self.snapshot = snapshot
        self.localUIDs = localUIDs
        self.favoriteIntents = favoriteIntents
        self.uploadBadges = uploadBadges
        self.isCanonical = isCanonical
        self.replacements = replacements
    }

    public static let empty = PendingTimelinePresentation(
        revision: 0,
        membershipRevision: 0,
        snapshot: TimelineSnapshot(),
        localUIDs: [],
        favoriteIntents: [:],
        uploadBadges: .empty,
        isCanonical: true
    )
}

/// Merges pending backup tiles into the Proton timeline, shared by all platforms.
///
/// Membership changes (a photo appears, uploads, or hands over) rebuild the presentation off the main actor
/// in O(n + m) without a sort. Progress changes only replace the small badge map. When a Proton photo takes
/// over from a pending tile, it inherits the tile's sort key for the rest of the session: `TimelineOrder`
/// breaks ties within one second by volume and node ID, which both change at the handoff, so without the
/// anchor a photo could move by one position in front of the person.
///
/// An edit of a backed-up photo replaces that earlier Proton photo. Its tile, and later its Proton photo, take
/// the earlier photo's place, and the earlier photo is hidden while its replacement shows. Once the backup moved
/// the earlier photo to the trash, it stays hidden until the Proton listing drops it, so a listing that lags
/// behind the trash cannot show it again. A photo that the person restores in this app shows at once
/// (`showRestored`). A restore on another device cannot be told apart from a lagging listing, so such a photo
/// shows after `trashedHideLimit` at the latest. Every hidden photo is derived in each merge.
@MainActor
public final class PendingTimelinePresenter {
    /// A new presentation; the host installs it in its grid and viewer.
    public var onChange: ((PendingTimelinePresentation) -> Void)?
    /// Sources whose Proton photo is listed now. The host forwards them to the pending coordinator.
    public var onRemotePresence: ((Set<PendingSourceKey>) -> Void)?
    /// Local photos the feed may load, and decoded images to hand to the Proton photos that replaced them.
    /// `revised` photos changed content in Apple Photos; their decoded images are out of date.
    public var onFeedUpdate:
        (
            (
                _ localUIDs: Set<PhotoUID>, _ adoptions: [(local: PhotoUID, remote: PhotoUID)],
                _ revised: [PhotoUID]
            ) -> Void
        )?

    private var remote = TimelineSnapshot()
    private var pending = PendingBackupSnapshot.empty
    private var isEnabled = false
    package private(set) var isBackupPaused = false
    private var hasPendingInput = false
    /// Session anchors: Proton photo -> the sort key and the UID of the pending tile it replaced.
    private var anchors: [PhotoUID: Anchor] = [:]
    /// The sort key that the tile of an edit took from its earlier Proton photo, fixed while the tile shows.
    private var tileKeys: [PendingSourceKey: PhotoItem] = [:]
    /// Earlier Proton photos that the backup moved to the trash, with the moment the grid first hid them as
    /// trashed, until the listing no longer returns them.
    private var trashedEarlier: [PhotoUID: Date] = [:]
    /// Proton photos that the person restored in this session, with the tile revisions that replaced them then.
    /// Those no longer hide them; a later edit that replaces them again does.
    private var restored: [PhotoUID: Set<Replacement>] = [:]
    private var waitingForTile: [Replacement: Date] = [:]
    private var tileWaitTask: Task<Void, Never>?
    /// The tile wait was already over when it started, so its rebuild follows without a timer.
    private var tileWaitIsDue = false
    package nonisolated static let tileWaitLimit: TimeInterval = 5
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let replacementLookup: (@Sendable () -> [PendingReplacementHandoff])?
    /// The longest time a trashed earlier photo stays hidden while the listing still returns it.
    package nonisolated static let trashedHideLimit: TimeInterval = 300
    /// The last content revision of each pending tile shown in this session.
    private var tileRevisions: [PhotoUID: UploadBackupRevision] = [:]
    private var contentEpochs: [PhotoUID: UInt64] = [:]
    private var contentEpoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var membershipRevision: UInt64 = 0
    private var computeTask: Task<Void, Never>?
    private var computeGeneration: UInt64 = 0
    private var presentation = PendingTimelinePresentation.empty
    private var lastMembershipRevision: UInt64?
    private let supportSources: SupportDiagnosticsSources

    public convenience init(replacementLookup: (@Sendable () -> [PendingReplacementHandoff])? = nil) {
        self.init(now: { Date() }, replacementLookup: replacementLookup)
    }

    package init(
        now: @escaping @Sendable () -> Date,
        replacementLookup: (@Sendable () -> [PendingReplacementHandoff])? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        supportSources: SupportDiagnosticsSources = .shared
    ) {
        self.now = now
        self.sleep = sleep
        self.replacementLookup = replacementLookup
        self.supportSources = supportSources
    }

    public var current: PendingTimelinePresentation { presentation }

    /// Tests: returns when no merge runs and no tile wait that is already over still has to rebuild. A tile
    /// wait that is not over yet does not count. Gives up after `rounds` merges, so a rebuild that never stops
    /// shows up in the caller's checks instead of hanging the test.
    package func waitUntilIdle(rounds: Int = 64) async {
        for _ in 0..<rounds {
            if let task = computeTask {
                await task.value
                // A merge that ended without applying leaves its task; nothing else will clear it.
                guard computeTask != task else { return }
            } else if tileWaitIsDue, let task = tileWaitTask {
                await task.value
                guard computeTask != nil || tileWaitTask != task else { return }
            } else {
                return
            }
        }
    }

    /// The canonical Proton timeline of the whole-library route.
    public func setRemote(_ snapshot: TimelineSnapshot) {
        guard snapshot != remote else { return }
        remote = snapshot
        rebuild()
    }

    /// The latest pending snapshot. `enabled` is false while backup is off or unavailable: then no local
    /// photo shows and the feed forgets every local image.
    public func setPending(_ snapshot: PendingBackupSnapshot, enabled: Bool) {
        let membershipChanged =
            enabled != isEnabled || snapshot.membershipRevision != pending.membershipRevision
            || lastMembershipRevision == nil || !hasPendingInput
        hasPendingInput = true
        pending = snapshot
        isEnabled = enabled
        if membershipChanged {
            rebuild()
        } else {
            refreshBadges()
        }
    }

    /// The person paused or resumed the Apple Photos backup. Only the badges change; the tiles stay.
    public func setBackupPaused(_ paused: Bool) {
        guard paused != isBackupPaused else { return }
        isBackupPaused = paused
        // Without badges, the next merge carries the flag.
        guard !presentation.uploadBadges.isEmpty else { return }
        publish(presentation.uploadBadges.replacing(isPaused: paused))
    }

    /// Ends the session: pending tiles and anchors belong to one account.
    public func reset() {
        computeTask?.cancel()
        computeTask = nil
        computeGeneration &+= 1
        remote = TimelineSnapshot()
        pending = .empty
        isEnabled = false
        isBackupPaused = false
        hasPendingInput = false
        anchors.removeAll()
        tileKeys.removeAll()
        trashedEarlier.removeAll()
        waitingForTile.removeAll()
        tileWaitTask?.cancel()
        tileWaitTask = nil
        tileWaitIsDue = false
        restored.removeAll()
        tileRevisions.removeAll()
        contentEpochs.removeAll()
        lastMembershipRevision = nil
        revision &+= 1
        membershipRevision &+= 1
        presentation = PendingTimelinePresentation(
            revision: revision, membershipRevision: membershipRevision, snapshot: TimelineSnapshot(), localUIDs: [],
            favoriteIntents: [:], uploadBadges: .empty, isCanonical: true)
        onFeedUpdate?([], [], [])
        onChange?(presentation)
    }

    // MARK: - Membership

    private func rebuild() {
        computeGeneration &+= 1
        let generation = computeGeneration
        // Only `apply` replaces the shown snapshot, and it accepts only this generation. The merge can
        // therefore compare with this snapshot off the main actor.
        let input = MergeInput(
            remote: remote,
            pending: isEnabled ? pending : .empty,
            anchors: anchors,
            tileKeys: tileKeys,
            trashedEarlier: trashedEarlier,
            waitingForTile: waitingForTile,
            restored: restored,
            now: now(),
            revisions: tileRevisions,
            shown: presentation.snapshot,
            replacementLookup: !hasPendingInput || isEnabled ? replacementLookup : nil
        )
        lastMembershipRevision = pending.membershipRevision
        computeTask?.cancel()
        computeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = Self.merge(input), !Task.isCancelled else { return }
            await self?.apply(result, generation: generation)
        }
    }

    /// Counts only: the support report never sees which photos the grid shows or hides.
    private func publishSupportCounts(_ result: MergeResult) {
        let listed = remote.items.count
        let shownRemote = result.snapshot.items.count - result.localUIDs.count
        let tiles = pending.tiles.count
        let anchored = anchors.count
        let trashed = trashedEarlier.count
        let waiting = waitingForTile.count
        let time = now()
        supportSources.publishPendingGrid { grid in
            grid.merges += 1
            grid.lastMergeAt = time
            grid.pendingTiles = tiles
            grid.localPhotosShown = result.localUIDs.count
            grid.remotePhotosListed = listed
            grid.remotePhotosHidden = max(0, listed - shownRemote)
            grid.anchoredPhotos = anchored
            grid.trashedEarlierPhotosHidden = trashed
            grid.photosWaitingForTheirTile = waiting
        }
    }

    private func apply(_ result: MergeResult, generation: UInt64) {
        guard generation == computeGeneration else { return }
        computeTask = nil
        for (remoteUID, anchor) in result.newAnchors { anchors[remoteUID] = anchor }
        // Anchors of Proton photos that the listing dropped are no longer needed. A hidden photo keeps its anchor:
        // a second edit takes the place where the photo showed.
        if !anchors.isEmpty {
            anchors = anchors.filter { remote.index(of: $0.key) != nil }
        }
        tileKeys = result.tileKeys
        trashedEarlier = result.trashedEarlier
        waitingForTile = result.waitingForTile
        tileWaitTask?.cancel()
        tileWaitTask = nil
        tileWaitIsDue = false
        if let deadline = result.heldTileDeadlines.min() {
            let remaining = max(0, deadline.timeIntervalSince(now()))
            tileWaitIsDue = remaining == 0
            tileWaitTask = Task { [weak self, sleep] in
                try? await sleep(.seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.rebuild()
            }
        }
        // Kept for the session: a tile that shows again after an edit must not reuse the image of its last showing.
        tileRevisions.merge(result.revisions) { $1 }
        // A revised photo keeps its current image; `noteContentRefreshed` bumps its epoch once the new
        // image is loaded, so the tile never shows black in between.
        if !contentEpochs.isEmpty { contentEpochs = contentEpochs.filter { result.localUIDs.contains($0.key) } }
        revision &+= 1
        if result.snapshotChanged { membershipRevision &+= 1 }
        let shown = isEnabled ? pending : .empty
        presentation = PendingTimelinePresentation(
            revision: revision,
            membershipRevision: membershipRevision,
            snapshot: result.snapshot,
            localUIDs: result.localUIDs,
            favoriteIntents: shown.favoriteIntents.filter { result.localUIDs.contains($0.key) },
            uploadBadges: PendingUploadBadges(
                base: result.baseBadges, progress: Self.progress(of: shown, gridUIDs: result.presentLocal),
                contentEpochs: contentEpochs, handovers: anchors.mapValues(\.tile), isPaused: isBackupPaused),
            isCanonical: result.localUIDs.isEmpty && anchors.isEmpty && !result.hidesRemote,
            replacements: Self.viewerReplacements(result.replacedBy, anchors: anchors, shown: result.snapshot)
        )
        publishSupportCounts(result)
        onFeedUpdate?(result.localUIDs, result.adoptions, result.revised)
        if !result.presentKeys.isEmpty { onRemotePresence?(result.presentKeys) }
        presentLocal = result.presentLocal
        onChange?(presentation)
    }

    /// Replaced photos -> their replacements, plus the tile of each edit -> the Proton photo that took it over.
    /// A plain upload is left out: its Proton photo continues the same picture, so a viewer keeps the pending page.
    private static func viewerReplacements(
        _ replacedBy: [PhotoUID: PhotoUID], anchors: [PhotoUID: Anchor], shown: TimelineSnapshot
    ) -> [PhotoUID: PhotoUID] {
        var result = replacedBy
        for (remote, anchor) in anchors where anchor.key.uid != anchor.tile {
            // A second edit anchors a newer Proton photo to the same tile; the one that shows wins.
            if result[anchor.tile] == nil || shown.index(of: remote) != nil { result[anchor.tile] = remote }
        }
        return result
    }

    /// The person restored these Proton photos from the trash: they show at once, even while the listing lags.
    public func showRestored(_ uids: [PhotoUID]) {
        let photosVolume = remote.items.first?.uid.volumeID
        let ledgerRecords = replacementLookup?() ?? []
        var changed = false
        for uid in Set(uids) {
            let replacements = pending.tiles.lazy
                .filter { tile in
                    tile.replaces.contains { Self.resolve($0, photosVolume: photosVolume) == uid }
                        || ledgerRecords.contains { record in
                            record.evidence.key == tile.key
                                && tile.revision.map({ record.evidence.revision < $0 }) == true
                                && Self.resolve(record.remote, photosVolume: photosVolume) == uid
                        }
                }
                .map(Replacement.init)
            let ledgerReplacements = ledgerRecords.filter {
                $0.evidence.replaces?.contains { Self.resolve($0, photosVolume: photosVolume) == uid } == true
            }.map { Replacement(key: $0.evidence.key, revision: $0.evidence.revision) }
            let exempt = restored[uid, default: []].union(replacements).union(ledgerReplacements)
            guard exempt != restored[uid] || trashedEarlier[uid] != nil else { continue }
            restored[uid] = exempt
            trashedEarlier[uid] = nil
            changed = true
        }
        if changed { rebuild() }
    }

    /// The feed holds new images for these revised photos; grids upload them in place of the old textures.
    public func noteContentRefreshed(_ uids: [PhotoUID]) {
        let shown = uids.filter { presentation.localUIDs.contains($0) }
        guard !shown.isEmpty else { return }
        for uid in shown {
            contentEpoch &+= 1
            contentEpochs[uid] = contentEpoch
        }
        publish(presentation.uploadBadges.replacing(contentEpochs: contentEpochs))
    }

    /// Local UIDs of tiles whose Proton photo is listed -> that photo, from the last merge.
    private var presentLocal: [PhotoUID: PhotoUID] = [:]

    /// A progress tick: O(uploads in flight), never O(pending photos).
    private func refreshBadges() {
        let progress = Self.progress(of: isEnabled ? pending : .empty, gridUIDs: presentLocal)
        guard progress != presentation.uploadBadges.progress else { return }
        publish(presentation.uploadBadges.replacing(progress: progress))
    }

    /// Publishes new badges with the same tiles.
    private func publish(_ badges: PendingUploadBadges) {
        revision &+= 1
        presentation = PendingTimelinePresentation(
            revision: revision,
            membershipRevision: membershipRevision,
            snapshot: presentation.snapshot,
            localUIDs: presentation.localUIDs,
            favoriteIntents: presentation.favoriteIntents,
            uploadBadges: badges,
            isCanonical: presentation.isCanonical,
            replacements: presentation.replacements
        )
        onChange?(presentation)
    }

    // MARK: - Pure merge (off main)

    /// Where a Proton photo that took over a pending tile sorts, and which tile's texture it continues.
    private struct Anchor: Sendable, Equatable {
        let key: PhotoItem
        let tile: PhotoUID
    }

    private struct MergeInput: Sendable {
        let remote: TimelineSnapshot
        let pending: PendingBackupSnapshot
        let anchors: [PhotoUID: Anchor]
        let tileKeys: [PendingSourceKey: PhotoItem]
        let trashedEarlier: [PhotoUID: Date]
        let waitingForTile: [Replacement: Date]
        let restored: [PhotoUID: Set<Replacement>]
        let now: Date
        let revisions: [PhotoUID: UploadBackupRevision]
        /// The snapshot that the grid shows now.
        let shown: TimelineSnapshot
        let replacementLookup: (@Sendable () -> [PendingReplacementHandoff])?
    }

    private struct MergeResult: Sendable {
        /// `shown` itself when the order did not change, so its index is reused.
        let snapshot: TimelineSnapshot
        let snapshotChanged: Bool
        let localUIDs: Set<PhotoUID>
        let presentKeys: Set<PendingSourceKey>
        let newAnchors: [PhotoUID: Anchor]
        let tileKeys: [PendingSourceKey: PhotoItem]
        let trashedEarlier: [PhotoUID: Date]
        let waitingForTile: [Replacement: Date]
        /// Deadlines of holds actually used by this merge, including ones that expire before apply.
        let heldTileDeadlines: [Date]
        /// Some Proton photos are hidden, so the presentation differs from the canonical snapshot.
        let hidesRemote: Bool
        let adoptions: [(local: PhotoUID, remote: PhotoUID)]
        let baseBadges: [PhotoUID: GridUploadBadge]
        let presentLocal: [PhotoUID: PhotoUID]
        let revisions: [PhotoUID: UploadBackupRevision]
        /// Visible local photos whose content revision changed since the last merge.
        let revised: [PhotoUID]
        /// Each replaced Proton photo -> the photo that shows in its place.
        let replacedBy: [PhotoUID: PhotoUID]
    }

    /// Nil when a newer merge cancelled this one.
    private nonisolated static func merge(_ input: MergeInput) -> MergeResult? {
        let remoteItems = input.remote.items
        // Owned photos share one volume; link-only handoffs resolve to it.
        let photosVolume = remoteItems.first?.uid.volumeID
        // The recorder captures both facts before announcing the remote commit. This lookup never reads a store
        // or awaits pending metadata, and runs once per coalesced merge.
        let ledgerRecords = input.replacementLookup?() ?? []
        let records = Dictionary(grouping: ledgerRecords, by: \.evidence.key)
        let tiles = input.pending.tiles.compactMap { tile -> PendingTile? in
            guard let record = records[tile.key]?.max(by: { $0.evidence.revision < $1.evidence.revision }),
                let revision = tile.revision, record.evidence.revision >= revision
            else { return tile }
            if record.evidence.revision > revision {
                // Remote input also supersedes a stale snapshot of an older tile of this source.
                if let remoteUID = resolve(record.remote, photosVolume: photosVolume),
                    input.remote.index(of: remoteUID) != nil
                {
                    return nil
                }
                return tile
            }
            return PendingTile(
                key: tile.key, item: tile.item, revision: tile.revision, handoff: record.remote,
                isSettled: tile.isSettled, badge: tile.badge, displayName: tile.displayName,
                replaces: record.evidence.replaces ?? [])
        }
        let replacements = replacements(
            in: input, tiles: tiles, ledgerRecords: ledgerRecords, photosVolume: photosVolume)
        var anchors = input.anchors
        var newAnchors: [PhotoUID: Anchor] = [:]
        var present: [PhotoUID: PendingTile] = [:]
        var presentKeys = Set<PendingSourceKey>()
        var adoptions: [(local: PhotoUID, remote: PhotoUID)] = []
        var visible: [PhotoItem] = []
        // Tiles of edits, at the place of their earlier photo.
        var placed: [(key: PhotoItem, item: PhotoItem)] = []
        visible.reserveCapacity(input.pending.tiles.count)
        for tile in tiles {
            let key = replacements.tileKeys[tile.key] ?? tile.item
            guard let handoff = tile.handoff,
                let remoteUID = resolve(handoff, photosVolume: photosVolume),
                input.remote.index(of: remoteUID) != nil
            else {
                if key == tile.item { visible.append(tile.item) } else { placed.append((key, tile.item)) }
                continue
            }
            // The Proton photo is listed: it takes over the tile, in the tile's position.
            present[remoteUID] = tile
            presentKeys.insert(tile.key)
            if anchors[remoteUID] == nil {
                let anchor = Anchor(key: key, tile: tile.item.uid)
                anchors[remoteUID] = anchor
                newAnchors[remoteUID] = anchor
                adoptions.append((tile.item.uid, remoteUID))
            }
        }
        // After the bounded metadata wait, a committed edit takes its earlier main's place.
        for record in ledgerRecords {
            guard let remoteUID = resolve(record.remote, photosVolume: photosVolume),
                input.remote.index(of: remoteUID) != nil, anchors[remoteUID] == nil,
                !replacements.hidden.contains(remoteUID), let key = replacements.tileKeys[record.evidence.key]
            else { continue }
            let anchor = Anchor(key: key, tile: record.evidence.key.localUID)
            anchors[remoteUID] = anchor
            newAnchors[remoteUID] = anchor
        }
        let localUIDs = Set(visible.map(\.uid)).union(placed.map(\.item.uid))
        var revisions: [PhotoUID: UploadBackupRevision] = [:]
        var revised: [PhotoUID] = []
        for tile in tiles where localUIDs.contains(tile.item.uid) {
            guard let revision = tile.revision else { continue }
            revisions[tile.item.uid] = revision
            if let previous = input.revisions[tile.item.uid], previous != revision { revised.append(tile.item.uid) }
        }
        let presentLocal = Dictionary(uniqueKeysWithValues: present.map { ($0.value.item.uid, $0.key) })
        let baseBadges = badges(for: input.pending, gridUIDs: presentLocal)
        let hidden = replacements.hidden
        guard !visible.isEmpty || !placed.isEmpty || !anchors.isEmpty || !hidden.isEmpty else {
            let changed = input.remote != input.shown
            return MergeResult(
                snapshot: changed ? input.remote : input.shown, snapshotChanged: changed, localUIDs: [],
                presentKeys: presentKeys, newAnchors: newAnchors, tileKeys: replacements.tileKeys,
                trashedEarlier: replacements.trashedEarlier, waitingForTile: replacements.waitingForTile,
                heldTileDeadlines: replacements.heldTileDeadlines, hidesRemote: false, adoptions: adoptions,
                baseBadges: baseBadges, presentLocal: presentLocal, revisions: revisions, revised: revised,
                replacedBy: replacements.replacedBy)
        }
        guard !Task.isCancelled else { return nil }

        // Three streams sorted by one presentation key; a linear merge keeps their total order.
        var anchored: [(key: PhotoItem, item: PhotoItem)] = placed
        anchored.append(contentsOf: replacements.heldEarlier.map { (input.anchors[$0.uid]?.key ?? $0, $0) })
        var canonical: [PhotoItem] = []
        canonical.reserveCapacity(remoteItems.count)
        for (index, item) in remoteItems.enumerated() {
            if index % cancellationStride == 0, Task.isCancelled { return nil }
            if hidden.contains(item.uid) { continue }
            if let anchor = anchors[item.uid] {
                anchored.append((anchor.key, item))
            } else {
                canonical.append(item)
            }
        }
        anchored.sort { TimelineOrder.areInIncreasingOrder($0.key, $1.key) }

        var merged: [PhotoItem] = []
        merged.reserveCapacity(canonical.count + visible.count + anchored.count)
        var c = 0
        var v = 0
        var a = 0
        while c < canonical.count || v < visible.count || a < anchored.count {
            if merged.count % cancellationStride == 0, Task.isCancelled { return nil }
            var bestKey: PhotoItem?
            var source = 0
            if c < canonical.count {
                bestKey = canonical[c]
                source = 0
            }
            if v < visible.count, bestKey.map({ TimelineOrder.areInIncreasingOrder(visible[v], $0) }) ?? true {
                bestKey = visible[v]
                source = 1
            }
            if a < anchored.count,
                bestKey.map({ TimelineOrder.areInIncreasingOrder(anchored[a].key, $0) }) ?? true
            {
                source = 2
            }
            switch source {
            case 0:
                merged.append(canonical[c])
                c += 1
            case 1:
                merged.append(visible[v])
                v += 1
            default:
                merged.append(anchored[a].item)
                a += 1
            }
        }
        guard !Task.isCancelled else { return nil }
        // A badge change keeps the order; reuse the shown snapshot instead of building a new index.
        let changed = merged != input.shown.items
        return MergeResult(
            snapshot: changed ? TimelineSnapshot(trustingOrderOf: merged) : input.shown,
            snapshotChanged: changed,
            localUIDs: localUIDs,
            presentKeys: presentKeys,
            newAnchors: newAnchors,
            tileKeys: replacements.tileKeys,
            trashedEarlier: replacements.trashedEarlier,
            waitingForTile: replacements.waitingForTile,
            heldTileDeadlines: replacements.heldTileDeadlines,
            hidesRemote: !hidden.isEmpty,
            adoptions: adoptions,
            baseBadges: baseBadges,
            presentLocal: presentLocal,
            revisions: revisions,
            revised: revised,
            replacedBy: replacements.replacedBy
        )
    }

    /// One revision of the tile of an edit, which replaces earlier photos.
    private struct Replacement: Hashable, Sendable {
        let key: PendingSourceKey
        let revision: UploadBackupRevision?

        init(_ tile: PendingTile) {
            self.init(key: tile.key, revision: tile.revision)
        }

        init(key: PendingSourceKey, revision: UploadBackupRevision?) {
            self.key = key
            self.revision = revision
        }
    }

    /// The Proton photos that edits replace in this merge, and the places their tiles take.
    private struct Replacements {
        /// Listed Proton photos to hide.
        var hidden = Set<PhotoUID>()
        /// Sort keys of tiles that stand in for an earlier photo.
        var tileKeys: [PendingSourceKey: PhotoItem] = [:]
        /// Trashed earlier photos that the listing still returns, with the moment they were first hidden.
        var trashedEarlier: [PhotoUID: Date] = [:]
        var waitingForTile: [Replacement: Date] = [:]
        var heldEarlier: [PhotoItem] = []
        var heldTileDeadlines: [Date] = []
        /// Each replaced Proton photo -> the photo that shows in its place.
        var replacedBy: [PhotoUID: PhotoUID] = [:]
    }

    private nonisolated static func replacements(
        in input: MergeInput, tiles: [PendingTile], ledgerRecords: [PendingReplacementHandoff], photosVolume: String?
    ) -> Replacements {
        var result = Replacements()
        func noteTrashed(_ uid: PhotoUID) {
            let since = input.trashedEarlier[uid] ?? input.now
            result.trashedEarlier[uid] = since
            if input.now.timeIntervalSince(since) < trashedHideLimit { result.hidden.insert(uid) }
        }
        for uid in input.trashedEarlier.keys where input.remote.index(of: uid) != nil { noteTrashed(uid) }
        func note(
            _ replacement: Replacement, current: PhotoUID?, replacing: PhotoUID, earlier: [PhotoUID], settled: Bool
        ) {
            let earlier = earlier.compactMap { resolve($0, photosVolume: photosVolume) }.filter { $0 != current }
            let listed = earlier.compactMap { input.remote.index(of: $0).map { input.remote.items[$0] } }
            let replaced = listed.lazy.map(\.uid).filter { input.restored[$0]?.contains(replacement) != true }
            if settled { replaced.forEach(noteTrashed) } else { result.hidden.formUnion(replaced) }
            // The evidence, not the listing, decides: a viewer still shows an earlier photo that the listing dropped.
            for uid in earlier where uid != replacing && input.restored[uid]?.contains(replacement) != true {
                if result.replacedBy[uid] == nil { result.replacedBy[uid] = replacing }
            }
            if let key = input.tileKeys[replacement.key] ?? result.tileKeys[replacement.key]
                ?? listed.map({ input.anchors[$0.uid]?.key ?? $0 }).min(by: TimelineOrder.areInIncreasingOrder)
            {
                result.tileKeys[replacement.key] = key
            }
        }
        for tile in tiles {
            note(
                Replacement(tile), current: tile.handoff.flatMap { resolve($0, photosVolume: photosVolume) },
                replacing: tile.item.uid, earlier: tile.replaces, settled: tile.isSettled)
        }
        let represented = Set(tiles.map(Replacement.init))
        let tilesByKey = Dictionary(tiles.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, records) in Dictionary(grouping: ledgerRecords, by: \.evidence.key) {
            let records = records.sorted { $0.evidence.revision > $1.evidence.revision }
            let tile = tilesByKey[key]
            // Resolve a visible representative before hiding any link in this source's chain.
            let record = records.first {
                resolve($0.remote, photosVolume: photosVolume).map { input.remote.index(of: $0) != nil } == true
            }
            guard tile != nil || record != nil else { continue }
            if let tile,
                record.map({ record in tile.revision.map { $0 >= record.evidence.revision } ?? false }) ?? true
            {
                let current = tile.handoff.flatMap { resolve($0, photosVolume: photosVolume) } ?? tile.item.uid
                let listedHandoff = tile.handoff.flatMap { resolve($0, photosVolume: photosVolume) }
                    .flatMap { input.remote.index(of: $0) }
                if listedHandoff == nil {
                    for record in records where tile.revision.map({ record.evidence.revision < $0 }) == true {
                        if let remote = resolve(record.remote, photosVolume: photosVolume),
                            input.restored[remote]?.contains(Replacement(tile)) != true
                        {
                            if input.remote.index(of: remote) != nil { result.hidden.insert(remote) }
                            result.replacedBy[remote] = tile.item.uid
                        }
                    }
                }
                for record in records where tile.revision.map({ record.evidence.revision <= $0 }) == true {
                    let replacement = Replacement(key: key, revision: record.evidence.revision)
                    guard !represented.contains(replacement) else { continue }
                    // Only settled records keep their ancestors hidden after acknowledgment.
                    note(
                        replacement, current: current, replacing: tile.item.uid,
                        earlier: record.evidence.replaces ?? [], settled: record.settled)
                }
                continue
            }
            guard let record, let current = resolve(record.remote, photosVolume: photosVolume) else { continue }
            let replacement = Replacement(key: key, revision: record.evidence.revision)
            let ancestors = records.filter { $0.evidence.revision <= record.evidence.revision }
            let earlier = ancestors.flatMap { ancestor in
                let replacement = Replacement(key: key, revision: ancestor.evidence.revision)
                return (ancestor.evidence.replaces ?? []).compactMap { resolve($0, photosVolume: photosVolume) }
                    .filter { $0 != current && input.restored[$0]?.contains(replacement) != true }
            }
            // The newest listed ancestor supplies the image while metadata for the committed edit is late.
            let olderRemotes = records.filter { $0.evidence.revision < record.evidence.revision }
                .compactMap { resolve($0.remote, photosVolume: photosVolume) }
            let listed = (olderRemotes + earlier).compactMap { uid in
                input.remote.index(of: uid).map { input.remote.items[$0] }
                    ?? input.shown.index(of: uid).map { input.shown.items[$0] }
            }.filter { !result.hidden.contains($0.uid) }
            let since = input.waitingForTile[replacement] ?? input.now
            var representative = current
            if let item = listed.first {
                result.waitingForTile[replacement] = since
                if input.now.timeIntervalSince(since) < tileWaitLimit {
                    result.heldTileDeadlines.append(since.addingTimeInterval(tileWaitLimit))
                    result.hidden.insert(current)
                    result.hidden.remove(item.uid)
                    representative = item.uid
                    if input.remote.index(of: item.uid) == nil { result.heldEarlier.append(item) }
                }
                result.tileKeys[key] = input.tileKeys[key] ?? input.anchors[item.uid]?.key ?? item
            }
            for ancestor in ancestors {
                note(
                    Replacement(key: key, revision: ancestor.evidence.revision), current: representative,
                    replacing: representative, earlier: ancestor.evidence.replaces ?? [], settled: ancestor.settled)
            }
        }
        return result
    }

    /// A merge checks for cancellation once per this many photos.
    private nonisolated static let cancellationStride = 4096

    private nonisolated static func resolve(_ handoff: PhotoUID, photosVolume: String?) -> PhotoUID? {
        guard handoff.volumeID.isEmpty else { return handoff }
        return photosVolume.map { PhotoUID(volumeID: $0, nodeID: handoff.nodeID) }
    }

    /// Badges of visible pending tiles, and of Proton photos that took over from a tile that is still
    /// uploading (a Live Photo video) or shows its checkmark. Progress stays out; see `progress(of:gridUIDs:)`.
    private nonisolated static func badges(
        for snapshot: PendingBackupSnapshot,
        gridUIDs: [PhotoUID: PhotoUID]
    ) -> [PhotoUID: GridUploadBadge] {
        var badges: [PhotoUID: GridUploadBadge] = [:]
        badges.reserveCapacity(snapshot.tiles.count)
        for tile in snapshot.tiles {
            guard let badge = gridBadge(tile.badge) else { continue }
            badges[gridUIDs[tile.item.uid] ?? tile.item.uid] = badge
        }
        return badges
    }

    /// Progress steps keyed by grid UID. O(uploads in flight).
    private nonisolated static func progress(
        of snapshot: PendingBackupSnapshot,
        gridUIDs: [PhotoUID: PhotoUID]
    ) -> [PhotoUID: Int] {
        var progress: [PhotoUID: Int] = [:]
        for (local, step) in snapshot.progress { progress[gridUIDs[local] ?? local] = step }
        return progress
    }

    /// Nil once the checkmark has shown: a backed-up photo looks like any other photo.
    private nonisolated static func gridBadge(_ badge: PendingUploadBadge) -> GridUploadBadge? {
        switch badge {
        case .waiting: .waiting
        case .uploading(let step): .uploading(step: step)
        case .attention: .attention
        case .done: .done
        case .backedUp: nil
        }
    }
}
