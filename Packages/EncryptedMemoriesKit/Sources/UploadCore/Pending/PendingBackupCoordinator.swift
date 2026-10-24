import Foundation
import PhotosCore

/// Owns the pending grid for one account: which local photos show while they wait for backup, their upload
/// badges, deletes and restores of pending photos, and deferred favorite and album actions.
///
/// The backup queue stays the source of truth. The coordinator follows it through change notifications
/// and keeps its own model incremental, so a first backup of 60,000 photos never rebuilds or re-sorts the
/// whole list per event. A source shows only with duplicate-check evidence: with iCloud Photos on several
/// devices, a photo that another device already uploaded arrives here as a new local asset, and only the
/// check can tell. Desired states in the pending store drive every side effect through one reconciler.
public actor PendingBackupCoordinator {
    public struct Configuration: Sendable {
        /// Minimum distance between two membership publications. Each one makes hosts merge the timeline.
        public var membershipInterval: Duration
        /// Minimum distance between two progress-only publications.
        public var progressInterval: Duration
        /// How long a retired tile's state lingers after the Proton photo took over the tile.
        public var doneLinger: Duration
        /// How long the checkmark shows once a photo is backed up; the tile then shows no badge.
        public var checkmarkDuration: Duration
        /// Up to this many unchecked photos show at once, before their duplicate check. A larger scan (a first
        /// backup, or a second device of an iCloud library) shows photos only after their check, so copies of
        /// photos that are already in Proton never flood the grid.
        public var uncheckedAdmissionLimit: Int
        /// "Zuletzt gelöscht" keeps deleted pending photos as long as the Proton trash keeps photos.
        public var trashRetention: TimeInterval
        public var acknowledgedHandoffRetention: TimeInterval
        /// How long a change of the photo library waits before the excluded photos are checked again. A burst of
        /// changes, such as a large import, shares one check.
        public var libraryChangeDelay: Duration

        public init(
            membershipInterval: Duration = .seconds(1),
            progressInterval: Duration = .milliseconds(250),
            doneLinger: Duration = .seconds(2),
            checkmarkDuration: Duration = .seconds(1),
            uncheckedAdmissionLimit: Int = 64,
            trashRetention: TimeInterval = 30 * 24 * 60 * 60,
            acknowledgedHandoffRetention: TimeInterval = 7 * 24 * 60 * 60,
            libraryChangeDelay: Duration = .milliseconds(500)
        ) {
            self.membershipInterval = membershipInterval
            self.progressInterval = progressInterval
            self.doneLinger = doneLinger
            self.checkmarkDuration = checkmarkDuration
            self.uncheckedAdmissionLimit = uncheckedAdmissionLimit
            self.trashRetention = trashRetention
            self.acknowledgedHandoffRetention = acknowledgedHandoffRetention
            self.libraryChangeDelay = libraryChangeDelay
        }
    }

    public nonisolated let snapshots: AsyncStream<PendingBackupSnapshot>
    private let snapshotContinuation: AsyncStream<PendingBackupSnapshot>.Continuation

    private let store: PendingBackupManifestStore
    private let queues: [UploadSourceIdentity.Kind: any UploadBackupSyncQueueObserving]
    private let metadataProvider: any PendingSourceMetadataProviding
    private let effects: any PendingBackupEffects
    private let recorder: PendingBackupEventRecorder?
    /// The earlier uploads of edited photo-library sources. Nil when edits keep their earlier uploads.
    private let replacementJournal: (any EditReplacementJournaling)?
    /// Tells whether another local source counts an earlier upload as its backup. Nil when that is unknown.
    private let identities: (any UploadIdentityStore)?
    /// Names the related files that move to the Proton trash with a main photo. Nil when that is unknown.
    private let relations: (any UploadDuplicateChecking)?
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    // Model, all keyed by source.
    private var rows: [PendingSourceKey: UploadBackupQueueRowState] = [:]
    private var evidence: [PendingSourceKey: Set<UploadBackupRevision>] = [:]
    private var replacements: [PendingSourceKey: [UploadBackupRevision: [PhotoUID]]] = [:]
    private var handoffs: [PendingSourceKey: PendingHandoff] = [:]
    private var sourceStates: [PendingSourceKey: PendingSourceState] = [:] {
        didSet { excludedListsCache = nil }
    }
    private var savedFromApp = Set<String>()
    private var metadata: [PendingSourceKey: PendingPresentationMetadata] = [:]
    /// The revision each cached metadata entry belongs to; a new revision can change the capture time.
    private var metadataRevision: [PendingSourceKey: UploadBackupRevision] = [:]
    private var inaccessible = Set<PendingSourceKey>()
    /// Sources with a new revision whose metadata is read again. The tile keeps its current metadata until
    /// then, so it never leaves the grid for a moment (the camera finishing a photo creates a revision).
    private var staleMetadata = Set<PendingSourceKey>()
    private var liveProgress: [PendingSourceKey: (revision: UploadBackupRevision, step: Int)] = [:]
    private var retiring: [PendingSourceKey: UploadBackupRevision] = [:]
    private var actions: [PendingAction] = []
    /// The newest delete or restore of each source, see `nextActionToken(for:)`.
    private var actionTokens: [PendingSourceKey: UInt64] = [:]
    private var excludedAccessible = Set<PendingSourceKey>() {
        didSet { excludedListsCache = nil }
    }
    /// Excluded sources that Apple Photos reported gone. The catalog still lists them until a backup pass runs, which
    /// never happens while backup is paused, so a check of the excluded list must not show them again.
    private var excludedMissing = Set<PendingSourceKey>()
    /// The trash and excluded lists as last built, when they were built, and the moment the oldest trash entry
    /// leaves the trash list. Progress ticks publish several times a second; the lists change only with the two
    /// properties above or with the clock.
    private var excludedListsCache: (trash: [PendingTile], excluded: [PendingTile], builtAt: Date, validUntil: Date)?
    /// Whether unchecked photos may show now; see `Configuration.uncheckedAdmissionLimit`.
    private var admitsUnchecked = false
    /// The sources that count against `Configuration.uncheckedAdmissionLimit`, kept current from the dirty keys.
    private var uncheckedSources = Set<PendingSourceKey>()
    /// Sources whose tile showed. They keep it through a retry, a pause, or a new revision whose check has not
    /// finished, also when a large scan starts meanwhile.
    private var shownSources = Set<PendingSourceKey>()
    /// Settled revisions whose checkmark showed and ended.
    private var checkmarkShown: [PendingSourceKey: UploadBackupRevision] = [:]
    private var checkmarkEnded: [PendingSourceKey: UploadBackupRevision] = [:]
    /// Sources with an earlier revision that is backed up. Their Proton photo represents them until the
    /// duplicate check of a newer revision decides on an upload, so no tile shows beside it meanwhile.
    private var backedUpBefore = Set<PendingSourceKey>()

    // Presentation, maintained incrementally.
    private var tilesByKey: [PendingSourceKey: PendingTile] = [:]
    private var orderedTiles: [PendingTile] = []
    private var dirty = Set<PendingSourceKey>()
    private var listsDirty = true
    private var snapshot = PendingBackupSnapshot.empty
    private var membershipRevision: UInt64 = 0
    private var progressRevision: UInt64 = 0

    private var started = false
    private var closed = false
    private var tasks: [Task<Void, Never>] = []
    private var membershipPublishTask: Task<Void, Never>?
    private var progressPublishTask: Task<Void, Never>?
    private var lastMembershipPublish: ContinuousClock.Instant?
    private var reconcileRunning = false
    private var reconcileAgain = false
    private var reconcileTimer: Task<Void, Never>?
    private var actionsRunning = false
    private var actionsAgain = false
    private var actionTimer: Task<Void, Never>?
    /// The check of the excluded photos that a library change started, and whether a change arrived while it read.
    private var excludedCheckTask: Task<Void, Never>?
    private var excludedCheckReading = false
    private var excludedCheckAgain = false

    public init(
        store: PendingBackupManifestStore,
        queues: [UploadSourceIdentity.Kind: any UploadBackupSyncQueueObserving],
        metadataProvider: any PendingSourceMetadataProviding,
        effects: any PendingBackupEffects,
        recorder: PendingBackupEventRecorder?,
        replacementJournal: (any EditReplacementJournaling)? = nil,
        identities: (any UploadIdentityStore)? = nil,
        relations: (any UploadDuplicateChecking)? = nil,
        configuration: Configuration = Configuration(),
        now: @Sendable @escaping () -> Date = { Date() },
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.queues = queues
        self.metadataProvider = metadataProvider
        self.effects = effects
        self.recorder = recorder
        self.replacementJournal = replacementJournal
        self.identities = identities
        self.relations = relations
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(
            of: PendingBackupSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    public func currentSnapshot() -> PendingBackupSnapshot { snapshot }

    // MARK: - Lifecycle

    /// Loads the durable state, subscribes to the queues and the runner, publishes the first snapshot and
    /// resumes any due effect.
    public func start() async {
        guard !started, !closed else { return }
        started = true
        guard store.isOperational() else { return }
        let handoffCutoff = now().addingTimeInterval(-configuration.acknowledgedHandoffRetention)
        _ = store.pruneAcknowledgedHandoffs(olderThan: handoffCutoff)
        evidence = store.evidenceRevisions()
        for (key, revisions) in evidence {
            for revision in revisions {
                if let record = recorder?.replacementLedger.evidence(for: key, revision: revision) { remember(record) }
            }
        }
        for handoff in store.unacknowledgedHandoffs() { remember(handoff) }
        sourceStates = Dictionary(uniqueKeysWithValues: store.sourceStates().map { ($0.key, $0) })
        savedFromApp = store.savedFromAppIdentifiers()
        actions = store.actions()

        for (kind, queue) in queues {
            let (changes, continuation) = AsyncStream.makeStream(
                of: UploadBackupSyncQueueChange.self,
                bufferingPolicy: .unbounded
            )
            queue.setChangeObserver { continuation.yield($0) }
            tasks.append(
                Task { [weak self] in
                    for await change in changes {
                        await self?.handle(change, kind: kind)
                    }
                })
            for row in queue.unsettledRows() where row.source.kind == kind { absorb(row) }
        }
        learnBackedUpSources()
        learnEarlierRevisions()
        // Settled rows are not part of the unsettled read; unacknowledged handoffs still need their rows.
        reloadRows(for: Set(handoffs.keys).subtracting(rows.keys))
        if let recorder {
            tasks.append(
                Task { [weak self] in
                    for await event in recorder.events {
                        await self?.handle(event)
                    }
                })
        }
        dirty.formUnion(rows.keys)
        dirty.formUnion(handoffs.keys)
        await refreshMetadata()
        await refreshExcludedAccessibility()
        publishMembership(force: true)
        await reconcile()
        await runDueActions()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for queue in queues.values { queue.setChangeObserver(nil) }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        membershipPublishTask?.cancel()
        progressPublishTask?.cancel()
        reconcileTimer?.cancel()
        actionTimer?.cancel()
        excludedCheckTask?.cancel()
        snapshotContinuation.finish()
    }

    // MARK: - Person actions

    /// Deletes pending photos: they leave the grid and the backup, and appear in "Zuletzt gelöscht".
    /// A photo whose upload already committed goes to the Proton trash instead. Returns false when the
    /// decision could not be stored.
    @discardableResult
    public func exclude(_ uids: [PhotoUID]) async -> Bool {
        guard !closed else { return false }
        let keys = uids.compactMap(PendingSourceKey.init(localUID:))
        guard !keys.isEmpty else { return true }
        let tokens = Dictionary(keys.map { ($0, nextActionToken(for: $0)) }, uniquingKeysWith: { _, last in last })
        var requests: [PendingExclusionRequest] = []
        var earlierLinks: [PendingSourceKey: Set<String>] = [:]
        for key in keys {
            let revision = tilesByKey[key]?.revision ?? rows[key]?.revision
            var remote = handoffs[key].flatMap { $0.revision == revision ? $0.remote : nil }
            if remote == nil {
                let earlier = await hiddenEarlierUpload(of: key, before: revision)
                guard !closed else { return false }
                remote = earlier?.target
                earlierLinks[key] = earlier?.links
            }
            requests.append(
                PendingExclusionRequest(key: key, presentation: metadata[key], remote: remote, revision: revision))
        }
        // A delete or restore of the same source during a lookup is the person's later decision, and it stands.
        requests.removeAll { actionTokens[$0.key] != tokens[$0.key] }
        guard !requests.isEmpty else { return true }
        let date = now()
        guard var states = store.exclude(requests, at: date) else { return false }
        // The manifest gives up the earlier upload only after the delete is stored. When it cannot, the photo stays.
        for request in requests {
            guard let links = earlierLinks[request.key], let target = request.remote,
                let index = states.firstIndex(where: { $0.key == request.key }),
                identities?.forgetRemoteLinks(
                    links, of: UploadSourceIdentity(kind: request.key.kind, identifier: request.key.identifier))
                    != true,
                states[index].needsRemoteTrash,
                let kept = store.keepRemote(
                    target, of: request.key, generation: states[index].generation, revision: request.revision, at: date)
            else { continue }
            states[index] = kept
        }
        let excluded = requests.map(\.key)
        recorder?.replacementLedger.dropSources(requests.map { ($0.key, $0.revision) })
        for state in states { sourceStates[state.key] = state }
        dirty.formUnion(excluded)
        excludedMissing.subtract(excluded)
        excludedAccessible.formUnion(excluded.filter { metadata[$0] != nil })
        listsDirty = true
        publishMembership(force: true)
        await reconcile()
        return true
    }

    /// The earlier upload that the tile of an unfinished edit hides. Deleting the tile deletes the photo, so that
    /// upload goes to the Proton trash as the person's deletion. Only this device's own upload of the source
    /// qualifies. The handoff of an earlier revision is acknowledged and no longer in memory, so the store answers.
    /// The store prunes acknowledged handoffs after `acknowledgedHandoffRetention`, and edits usually come later;
    /// without a handoff, the journal names the earlier uploads of the source.
    ///
    /// The trash moves the photo with its related files, so none of them may be another local source's backup.
    /// The earlier photo stays when another source counts one of them as its backup, and when the identity manifest
    /// or the server cannot name them. The photo is active, because the journal superseded it and the tile hides
    /// it, so the server can answer; a failed lookup keeps the photo and never defers the delete. The lookup changes
    /// nothing: `exclude` lets the manifest forget the returned links once the delete is stored, so a return of the
    /// source to the backup does not count them as its backup.
    private func hiddenEarlierUpload(
        of key: PendingSourceKey,
        before revision: UploadBackupRevision?
    ) async -> (target: PhotoUID, links: Set<String>)? {
        guard let revision, let tile = tilesByKey[key], tile.revision == revision else { return nil }
        let hidden = Set(tile.replaces.map(\.nodeID))
        guard !hidden.isEmpty, let identities, let relations else { return nil }
        let target: PhotoUID?
        // A stored handoff of this or a later revision is the edit's own commit, whose event has not arrived yet; the
        // journal still names the earlier upload. The store trashes the commit after it.
        if let earlier = store.latestHandoffs(for: [key])[key], earlier.revision < revision {
            target = earlier.kind == .uploaded && hidden.contains(earlier.remote.nodeID) ? earlier.remote : nil
        } else {
            target = newestEarlierMain(of: key, among: tile.replaces)
        }
        guard let target,
            let related = try? await relations.relatedPhotoLinkIDs(ofMainLinkID: target.nodeID)
        else { return nil }
        // The tile can change during the lookup; only the photo that it still hides is the person's deletion.
        guard let current = tilesByKey[key], current.revision == revision,
            current.replaces.contains(where: { $0.nodeID == target.nodeID })
        else { return nil }
        let source = UploadSourceIdentity(kind: key.kind, identifier: key.identifier)
        let links = related.union([target.nodeID])
        guard !identities.isNeededElsewhere(links, by: source) else { return nil }
        return (target, links)
    }

    /// Starts a new person action for `key`. A delete that awaits a lookup drops its decision for the source when
    /// a later delete or restore of the source took a newer token meanwhile.
    private func nextActionToken(for key: PendingSourceKey) -> UInt64 {
        actionTokens[key, default: 0] &+= 1
        return actionTokens[key, default: 0]
    }

    /// The newest photo among `hidden` that the journal still names as an earlier main of the source: the backup
    /// has not trashed it, and the person has not either. A target that only the remote index found is not proven
    /// to be this source's photo.
    private func newestEarlierMain(of key: PendingSourceKey, among hidden: [PhotoUID]) -> PhotoUID? {
        guard key.kind == .photoLibraryAsset, let replacementJournal else { return nil }
        let mains = replacementJournal.entry(for: UploadSourceIdentity(kind: key.kind, identifier: key.identifier))
            .superseded
        guard let newest = hidden.last(where: { uid in mains.contains { $0.nodeID == uid.nodeID } }) else {
            return nil
        }
        return mains.last { $0.nodeID == newest.nodeID }
    }

    /// Restores deleted or excluded pending photos: they return to the backup and to the grid. A Proton
    /// photo that a delete moved to the Proton trash comes back as well.
    @discardableResult
    public func restore(_ uids: [PhotoUID]) async -> Bool {
        guard !closed else { return false }
        let keys = uids.compactMap(PendingSourceKey.init(localUID:))
        guard !keys.isEmpty else { return true }
        for key in keys { _ = nextActionToken(for: key) }
        guard let states = store.include(keys, at: now()) else { return false }
        // Only the person's return starts a new attempt; a queue reload cannot clear the block.
        for key in keys { recorder?.replacementLedger.readmit(key) }
        excludedMissing.subtract(keys)
        for state in states { sourceStates[state.key] = state }
        dirty.formUnion(keys)
        listsDirty = true
        publishMembership(force: true)
        await reconcile()
        return true
    }

    /// Restores the sources behind Proton photos that the person restored from the Proton trash, when a
    /// pending delete had moved them there.
    public func restoreSources(ofRemote uids: [PhotoUID]) async {
        let linkIDs = Set(uids.map(\.nodeID))
        // The earlier upload of a deleted edit can have no handoff left; the delete recorded it as its photo.
        let deleted = sourceStates.values.filter { state in
            state.remote.map { linkIDs.contains($0.nodeID) } == true
        }.map(\.key)
        let keys = Set(store.handoffs(forRemoteLinkIDs: Array(linkIDs)).map(\.key) + deleted)
            .filter { sourceStates[$0]?.desired == .excluded }
        guard !keys.isEmpty else { return }
        await restore(keys.map(\.localUID))
    }

    /// "Endgültig löschen" / "Papierkorb leeren": the entries leave "Zuletzt gelöscht", the photos stay
    /// excluded from backup.
    @discardableResult
    public func removeFromTrashList(_ uids: [PhotoUID]) -> Bool {
        guard !closed else { return false }
        let keys = uids.compactMap(PendingSourceKey.init(localUID:))
        guard store.unlistFromTrash(keys, at: now()) else { return false }
        reloadSourceStates(keys)
        listsDirty = true
        publishMembership(force: true)
        return true
    }

    /// Stores the desired favorite state of pending photos. The app applies it after upload.
    @discardableResult
    public func setFavorite(_ uids: [PhotoUID], favorite: Bool) async -> Bool {
        guard !closed else { return false }
        let keys = uids.compactMap(PendingSourceKey.init(localUID:))
        let date = now()
        guard keys.allSatisfy({ store.setFavoriteIntent($0, favorite: favorite, at: date) }) else { return false }
        actions = store.actions()
        listsDirty = true
        publishMembership(force: true)
        await runDueActions()
        return true
    }

    /// Adds pending photos to an album after upload.
    @discardableResult
    public func addToAlbum(_ uids: [PhotoUID], albumID: String) async -> Bool {
        guard !closed else { return false }
        let keys = uids.compactMap(PendingSourceKey.init(localUID:))
        let date = now()
        guard keys.allSatisfy({ store.addAlbumIntent($0, albumID: albumID, at: date) }) else { return false }
        actions = store.actions()
        await runDueActions()
        return true
    }

    /// The photo was saved to Apple Photos by this app from Proton; it never shows as pending.
    public func recordSavedFromApp(localIdentifier: String, remote: PhotoUID) {
        guard !closed, store.recordSavedFromApp(localIdentifier: localIdentifier, remote: remote, at: now()) else {
            return
        }
        savedFromApp.insert(localIdentifier)
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: localIdentifier)
        dirty.insert(key)
        scheduleMembershipPublish()
    }

    /// Called by the host after each timeline merge with the sources whose Proton photo is now listed.
    /// Settled sources retire after the checkmark lingered; deferred actions run for all of them.
    public func noteRemotePresence(_ keys: Set<PendingSourceKey>) async {
        guard !keys.isEmpty, !closed else { return }
        var acknowledged: [(PendingSourceKey, UploadBackupRevision)] = []
        for key in keys {
            guard let tile = tilesByKey[key], tile.isSettled, let revision = tile.revision,
                retiring[key] != revision
            else { continue }
            retiring[key] = revision
            acknowledged.append((key, revision))
        }
        if !acknowledged.isEmpty, store.acknowledgeHandoffs(acknowledged) {
            recorder?.replacementLedger.drop(acknowledged)
            let linger = configuration.doneLinger
            Task { [weak self, sleep] in
                try? await sleep(linger)
                await self?.retire(acknowledged)
            }
        }
        await runDueActions()
    }

    /// The platform found these local photos gone (deleted in Apple Photos before their upload). Their tiles
    /// leave the grid like any inaccessible source; an upload that still finishes shows as a Proton photo.
    /// Excluded photos leave the excluded list, also while backup is paused and no pass updates the catalog.
    public func noteSourcesMissing(_ uids: [PhotoUID]) {
        guard !closed else { return }
        let reported = uids.compactMap(PendingSourceKey.init(localUID:))
        let excluded = reported.filter { sourceStates[$0]?.desired == .excluded }
        if !excluded.isEmpty {
            excludedMissing.formUnion(excluded)
            if !excludedAccessible.isDisjoint(with: excluded) {
                excludedAccessible.subtract(excluded)
                listsDirty = true
                scheduleMembershipPublish()
            }
        }
        let keys = reported.filter { tilesByKey[$0] != nil }
        guard !keys.isEmpty else { return }
        recorder?.replacementLedger.dropSources(keys.map { ($0, tilesByKey[$0]?.revision ?? rows[$0]?.revision) })
        for key in keys {
            metadata[key] = nil
            metadataRevision[key] = nil
            staleMetadata.remove(key)
            inaccessible.insert(key)
            dirty.insert(key)
        }
        scheduleMembershipPublish()
    }

    /// The photo library or a watched folder changed, or the app became active. Excluded photos that no longer
    /// exist leave the excluded list. Changes during the delay share one check; changes during a check run one more.
    public func noteLibraryChanged() {
        guard started, !closed else { return }
        if excludedCheckReading { excludedCheckAgain = true }
        guard excludedCheckTask == nil else { return }
        let delay = configuration.libraryChangeDelay
        excludedCheckTask = Task { [weak self, sleep] in
            if delay > .zero { try? await sleep(delay) }
            await self?.checkExcludedAfterLibraryChange()
        }
    }

    private func checkExcludedAfterLibraryChange() async {
        guard !Task.isCancelled, !closed else { return }
        excludedCheckReading = true
        excludedCheckAgain = false
        await refreshExcludedAccessibility()
        excludedCheckReading = false
        excludedCheckTask = nil
        guard !closed else { return }
        scheduleMembershipPublish()
        if excludedCheckAgain {
            excludedCheckAgain = false
            noteLibraryChanged()
        }
    }

    // MARK: - Queue and runner events

    private func handle(_ change: UploadBackupSyncQueueChange, kind: UploadSourceIdentity.Kind) async {
        guard !closed, let queue = queues[kind] else { return }
        switch change {
        case .all:
            let previousRows = rows.filter { $0.key.kind == kind }
            for key in previousRows.keys { rows[key] = nil }
            for row in queue.unsettledRows() where row.source.kind == kind { absorb(row) }
            if kind == .photoLibraryAsset { learnBackedUpSources() }
            learnEarlierRevisions()
            let current = Set(rows.keys.filter { $0.kind == kind })
            let gone = Set(previousRows.keys).subtracting(current)
            // A row that was still active settled or left: it takes the per-source path, so its durable handoff
            // keeps the tile. Rows that had settled before only drop their state; there can be many of them.
            let wasActive = gone.filter { key in
                guard let state = previousRows[key]?.state else { return false }
                return state != .completed && state != .alreadyBackedUp
            }
            for key in gone.subtracting(wasActive) where handoffs[key] == nil { dropSourceState(key) }
            reloadRows(for: Set(handoffs.keys.filter { $0.kind == kind }).subtracting(current).union(wasActive))
            dirty.formUnion(Set(previousRows.keys).union(current))
        case .sources(let grouped), .enqueued(let grouped):
            let identifiers = grouped[kind] ?? []
            let keys = Set(identifiers.map { PendingSourceKey(kind: kind, identifier: $0) })
            reloadRows(for: keys)
            dirty.formUnion(keys)
        }
        await refreshMetadata()
        scheduleMembershipPublish()
    }

    private func handle(_ event: PendingRuntimeEvent) async {
        guard !closed else { return }
        switch event {
        case .evidence(let record):
            remember(record)
            dirty.insert(record.key)
            await refreshMetadata()
            scheduleMembershipPublish()
        case .handoff(let handoff, let outcome):
            remember(handoff)
            dirty.insert(handoff.key)
            if outcome == .excludedRemoteNeedsTrash {
                reloadSourceStates([handoff.key])
                await reconcile()
            }
            await refreshMetadata()
            scheduleMembershipPublish()
            await runDueActions()
        case .progress(let key, let revision, let step):
            if let step {
                guard liveProgress[key]?.step != step || liveProgress[key]?.revision != revision else { return }
                liveProgress[key] = (revision, step)
            } else {
                guard liveProgress.removeValue(forKey: key) != nil else { return }
            }
            scheduleProgressPublish()
        }
    }

    private func remember(_ record: PendingUploadEvidence) {
        evidence[record.key, default: []].insert(record.revision)
        if record.key.kind == .photoLibraryAsset, let replaces = record.replaces {
            replacements[record.key, default: [:]][record.revision] = replaces
        }
    }

    private func remember(_ handoff: PendingHandoff) {
        guard !handoff.acknowledged else { return }
        if let existing = handoffs[handoff.key],
            (existing.createdAt, existing.revision) > (handoff.createdAt, handoff.revision)
        {
            return
        }
        handoffs[handoff.key] = handoff
        if let record = recorder?.replacementLedger.evidence(for: handoff.key, revision: handoff.revision) {
            remember(record)
        }
    }

    private func absorb(_ row: UploadBackupQueueRowState) {
        let key = PendingSourceKey(row.source)
        // A compound has one row per source; with several revisions, the newest owns the tile.
        if let existing = rows[key], existing.revision > row.revision { return }
        rows[key] = row
        if let cached = metadataRevision[key], cached != row.revision {
            // An edit can change the capture time and the media type: read them again, and show the current
            // ones meanwhile.
            staleMetadata.insert(key)
            inaccessible.remove(key)
        }
    }

    private func reloadRows(for keys: Set<PendingSourceKey>) {
        let grouped = Dictionary(grouping: keys, by: \.kind)
        for (kind, kindKeys) in grouped {
            guard let queue = queues[kind] else { continue }
            for key in kindKeys { rows[key] = nil }
            let fetched = queue.rows(kind: kind, identifiers: Set(kindKeys.map(\.identifier)))
            for row in fetched { absorb(row) }
            for row in fetched where row.state == .completed || row.state == .alreadyBackedUp {
                let key = PendingSourceKey(row.source)
                if let newest = rows[key]?.revision, row.revision < newest { backedUpBefore.insert(key) }
            }
            rememberDurableHandoffs(for: kindKeys)
            for key in kindKeys where rows[key] == nil && handoffs[key] == nil { dropSourceState(key) }
        }
        dirty.formUnion(keys)
    }

    /// The source left the queue (local deletion or exclusion): its live state is gone too.
    private func dropSourceState(_ key: PendingSourceKey) {
        recorder?.replacementLedger.dropSources([(key, tilesByKey[key]?.revision ?? metadataRevision[key])])
        liveProgress[key] = nil
        shownSources.remove(key)
        checkmarkShown[key] = nil
        checkmarkEnded[key] = nil
        metadata[key] = nil
        metadataRevision[key] = nil
        staleMetadata.remove(key)
        inaccessible.remove(key)
        backedUpBefore.remove(key)
        replacements[key] = nil
    }

    /// One aggregate read covers queued edits without querying every source in a large library.
    private func learnBackedUpSources() {
        backedUpBefore.formUnion(
            (replacementJournal?.supersededSourceIdentifiers() ?? []).map {
                PendingSourceKey(kind: .photoLibraryAsset, identifier: $0)
            })
        guard let queue = queues[.photoLibraryAsset] else { return }
        for (identifier, revision) in queue.backedUpRevisions(kind: .photoLibraryAsset) {
            let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: identifier)
            if let newest = rows[key]?.revision, revision < newest { backedUpBefore.insert(key) }
        }
    }

    /// The unsettled read has no earlier revisions. Unchecked rows can show before their check only while few of
    /// them wait, so reading the earlier revisions of those few stays cheap.
    private func learnEarlierRevisions(of candidates: Set<PendingSourceKey>? = nil) {
        let unchecked = (candidates.map { Array($0) } ?? Array(rows.keys)).filter { key in
            rows[key].map { Self.isUnchecked($0.state) } == true && !backedUpBefore.contains(key)
        }
        guard !unchecked.isEmpty, unchecked.count <= configuration.uncheckedAdmissionLimit else { return }
        for (kind, keys) in Dictionary(grouping: unchecked, by: \.kind) {
            guard let queue = queues[kind] else { continue }
            for row in queue.rows(kind: kind, identifiers: Set(keys.map(\.identifier)))
            where row.state == .completed || row.state == .alreadyBackedUp {
                let key = PendingSourceKey(row.source)
                if let newest = rows[key]?.revision, row.revision < newest { backedUpBefore.insert(key) }
            }
        }
    }

    /// The runner writes a handoff to the store before the queue settles its row, but the coordinator hears
    /// about the queue change and the handoff event on separate streams. A settled or vanished row whose
    /// handoff event has not arrived yet would hide the tile until it does; the durable handoff keeps it.
    private func rememberDurableHandoffs(for keys: [PendingSourceKey]) {
        let settled = keys.filter { key in
            guard let row = rows[key] else { return handoffs[key] == nil }
            guard row.state == .completed || row.state == .alreadyBackedUp else { return false }
            return handoffs[key]?.revision != row.revision
        }
        guard !settled.isEmpty else { return }
        for handoff in store.latestHandoffs(for: settled).values { remember(handoff) }
    }

    private func reloadSourceStates(_ keys: [PendingSourceKey]) {
        for key in keys { sourceStates[key] = store.sourceState(for: key) }
        dirty.formUnion(keys)
    }

    /// Retires exactly the acknowledged revisions; a newer revision of the same source keeps its state.
    private func retire(_ items: [(PendingSourceKey, UploadBackupRevision)]) {
        guard !closed else { return }
        for (key, revision) in items {
            if retiring[key] == revision { retiring[key] = nil }
            if handoffs[key]?.revision == revision { handoffs[key] = nil }
            evidence[key]?.remove(revision)
            if evidence[key]?.isEmpty == true { evidence[key] = nil }
            replacements[key]?[revision] = nil
            if replacements[key]?.isEmpty == true { replacements[key] = nil }
            if liveProgress[key]?.revision == revision { liveProgress[key] = nil }
            if checkmarkShown[key] == revision { checkmarkShown[key] = nil }
            if checkmarkEnded[key] == revision { checkmarkEnded[key] = nil }
            shownSources.remove(key)
            dirty.insert(key)
        }
        _ = store.removeEvidence(items)
        scheduleMembershipPublish()
    }

    // MARK: - Tiles

    /// Pre-check states can hide a photo that already exists in Proton, so they need evidence.
    private static func needsEvidence(_ state: UploadBackupSyncQueueState) -> Bool {
        switch state {
        case .discovered, .checking, .hashing, .duplicateChecking, .failed, .paused, .blockedByDraft,
            .failedPermanent:
            true
        case .queuedForUpload, .uploading, .finalizing, .needsRemoteReconciliation, .completed, .alreadyBackedUp,
            .skippedRemoteDeletion, .sourceMissing, .dismissedFailure:
            false
        }
    }

    /// The duplicate check has not decided yet.
    private static func isUnchecked(_ state: UploadBackupSyncQueueState) -> Bool {
        switch state {
        case .discovered, .checking, .hashing, .duplicateChecking: true
        default: false
        }
    }

    /// A few new photos (a normal day's shots) show at once with an empty ring; a large scan waits for checks.
    /// Counts every unchecked photo, shown ones included, so a scan that arrives in many small steps cannot
    /// slip past the limit.
    ///
    /// Every change to a row, its evidence, its accessibility, or the person's choice marks the source dirty, so
    /// one event costs O(dirty sources), not O(queue).
    private func updateUncheckedAdmission() {
        for key in dirty {
            if countsAsUnchecked(key) {
                uncheckedSources.insert(key)
            } else {
                uncheckedSources.remove(key)
            }
        }
        assert(uncheckedSources == Set(rows.keys.filter(countsAsUnchecked)), "a changed source was not marked dirty")
        let admits = uncheckedSources.count <= configuration.uncheckedAdmissionLimit
        guard admits != admitsUnchecked else { return }
        admitsUnchecked = admits
        guard admits else { return }
        // Above the limit the earlier revisions were not read, so an edit could otherwise show beside its photo.
        let admitted = uncheckedSources.subtracting(shownSources)
        learnEarlierRevisions(of: admitted)
        dirty.formUnion(admitted)
    }

    private func countsAsUnchecked(_ key: PendingSourceKey) -> Bool {
        guard let row = rows[key] else { return false }
        return Self.isUnchecked(row.state) && evidence[key]?.contains(row.revision) != true
            && !inaccessible.contains(key) && !isHiddenByChoice(key)
    }

    /// Excluded by the person, or saved to Apple Photos from Proton by this app.
    private func isHiddenByChoice(_ key: PendingSourceKey) -> Bool {
        sourceStates[key]?.desired == .excluded
            || (key.kind == .photoLibraryAsset && savedFromApp.contains(key.identifier))
    }

    /// Whether the source can show at all, before metadata is known.
    private func isCandidate(_ key: PendingSourceKey) -> Bool {
        guard !isHiddenByChoice(key) else { return false }
        // A recovered commit can remove its queue row before the Proton photo is listed; the durable
        // handoff alone keeps the tile until then.
        guard let row = rows[key] else { return handoffs[key] != nil }
        let handoff = handoffs[key].flatMap { $0.revision == row.revision ? $0 : nil }
        if key.kind == .photoLibraryAsset, row.state == .queuedForUpload, backedUpBefore.contains(key),
            handoff == nil, evidence[key]?.contains(row.revision) != true
        {
            return false
        }
        switch row.state {
        case .completed, .alreadyBackedUp:
            guard handoff != nil else { return false }
            shownSources.insert(key)
            return true
        case .skippedRemoteDeletion, .sourceMissing, .dismissedFailure:
            return false
        default:
            if Self.needsEvidence(row.state), handoff == nil, evidence[key]?.contains(row.revision) != true,
                !shownSources.contains(key)
            {
                // The earlier Proton photo shows until the check decides on an upload: a tile beside it would
                // show the photo twice, and most rechecks upload nothing.
                guard !backedUpBefore.contains(key), earlierUploads(of: key).isEmpty else { return false }
                guard admitsUnchecked, Self.isUnchecked(row.state) else { return false }
            }
            shownSources.insert(key)
            return true
        }
    }

    private func tile(for key: PendingSourceKey) -> PendingTile? {
        guard isCandidate(key), let metadata = metadata[key] else { return nil }
        guard let row = rows[key] else {
            guard let handoff = handoffs[key] else { return nil }
            return PendingTile(
                key: key,
                item: Self.item(for: key, metadata: metadata),
                revision: handoff.revision,
                handoff: handoff.remote,
                isSettled: true,
                badge: settledBadge(key, revision: handoff.revision),
                displayName: metadata.displayName,
                replaces: replacements[key]?[handoff.revision] ?? []
            )
        }
        let handoff = handoffs[key].flatMap { $0.revision == row.revision ? $0.remote : nil }
        let settled = row.state == .completed || row.state == .alreadyBackedUp
        let replaces = replacements[key]?[row.revision] ?? (settled ? [] : earlierUploads(of: key))
        let badge: PendingUploadBadge =
            switch row.state {
            case .completed, .alreadyBackedUp: settledBadge(key, revision: row.revision)
            case .failedPermanent: .attention
            default: .waiting
            }
        return PendingTile(
            key: key,
            item: Self.item(for: key, metadata: metadata),
            revision: row.revision,
            handoff: handoff,
            isSettled: settled,
            badge: badge,
            displayName: metadata.displayName,
            replaces: replaces
        )
    }

    private func earlierUploads(of key: PendingSourceKey) -> [PhotoUID] {
        guard key.kind == .photoLibraryAsset, let replacementJournal else { return [] }
        return replacementJournal.entry(for: UploadSourceIdentity(kind: key.kind, identifier: key.identifier))
            .allSuperseded
    }

    /// The checkmark shows for `checkmarkDuration` after the backup finished, then the tile shows no badge.
    private func settledBadge(_ key: PendingSourceKey, revision: UploadBackupRevision) -> PendingUploadBadge {
        if checkmarkEnded[key] == revision { return .backedUp }
        if checkmarkShown[key] != revision {
            checkmarkShown[key] = revision
            let duration = configuration.checkmarkDuration
            Task { [weak self, sleep] in
                try? await sleep(duration)
                await self?.endCheckmark(key, revision: revision)
            }
        }
        return .done
    }

    private func endCheckmark(_ key: PendingSourceKey, revision: UploadBackupRevision) {
        guard !closed, checkmarkShown[key] == revision else { return }
        checkmarkEnded[key] = revision
        dirty.insert(key)
        scheduleMembershipPublish()
    }

    private static func item(for key: PendingSourceKey, metadata: PendingPresentationMetadata) -> PhotoItem {
        let seconds = metadata.captureTime.timeIntervalSince1970
        return PhotoItem(
            uid: key.localUID,
            captureTime: Date(timeIntervalSince1970: seconds.isFinite ? seconds.rounded(.down) : 0),
            mediaType: metadata.mediaType,
            isLivePhoto: metadata.isLivePhoto,
            durationSeconds: metadata.durationSeconds
        )
    }

    /// Fetches metadata for candidates that do not have it yet, in one batch.
    private func refreshMetadata() async {
        // Admission decides which sources need metadata at all.
        updateUncheckedAdmission()
        let missing = dirty.filter {
            (metadata[$0] == nil || staleMetadata.contains($0)) && !inaccessible.contains($0) && isCandidate($0)
        }
        guard !missing.isEmpty else { return }
        let requested = Dictionary(uniqueKeysWithValues: missing.map { ($0, currentRevision($0)) })
        let fetched = await metadataProvider.metadata(for: Array(missing))
        guard !closed else { return }
        for key in missing {
            // The source may have left or changed revision while the fetch ran; its next event refetches.
            guard metadata[key] == nil || staleMetadata.contains(key), isCandidate(key),
                currentRevision(key) == requested[key]
            else { continue }
            if let value = fetched[key] {
                metadata[key] = value
                metadataRevision[key] = requested[key] ?? nil
                staleMetadata.remove(key)
            } else if staleMetadata.remove(key) != nil {
                // The catalog does not know the new revision yet; the current metadata stays until the next
                // revision. A deleted photo leaves through `noteSourcesMissing`.
                metadataRevision[key] = requested[key] ?? nil
            } else {
                inaccessible.insert(key)
            }
        }
        // A publication during the fetch may have consumed these keys before their metadata existed.
        dirty.formUnion(missing)
    }

    private func currentRevision(_ key: PendingSourceKey) -> UploadBackupRevision? {
        rows[key]?.revision ?? handoffs[key]?.revision
    }

    private func refreshExcludedAccessibility() async {
        let excluded = sourceStates.values.filter { $0.desired == .excluded }.map(\.key)
        guard !excluded.isEmpty else {
            if !excludedAccessible.isEmpty {
                excludedAccessible = []
                listsDirty = true
            }
            return
        }
        let accessible = await metadataProvider.metadata(for: excluded)
        guard !closed else { return }
        // A photo excluded during the read keeps the answer that its exclusion stored.
        let checked = excludedAccessible.subtracting(excluded).union(accessible.keys).subtracting(excludedMissing)
        guard checked != excludedAccessible else { return }
        excludedAccessible = checked
        listsDirty = true
    }

    /// Applies dirty keys to the ordered tile list with binary search, so one event costs O(log n) plus a move.
    private func applyDirty() -> Bool {
        updateUncheckedAdmission()
        guard !dirty.isEmpty else { return false }
        var changed = false
        for key in dirty {
            let old = tilesByKey[key]
            let new = tile(for: key)
            guard old != new else { continue }
            changed = true
            if let old, let index = position(of: old) { orderedTiles.remove(at: index) }
            if let new { orderedTiles.insert(new, at: insertionIndex(for: new.item)) }
            tilesByKey[key] = new
        }
        dirty.removeAll(keepingCapacity: true)
        return changed
    }

    private func insertionIndex(for item: PhotoItem) -> Int {
        var low = 0
        var high = orderedTiles.count
        while low < high {
            let mid = (low + high) / 2
            if TimelineOrder.areInIncreasingOrder(orderedTiles[mid].item, item) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func position(of tile: PendingTile) -> Int? {
        let index = insertionIndex(for: tile.item)
        guard index < orderedTiles.count, orderedTiles[index].item.uid == tile.item.uid else { return nil }
        return index
    }

    // MARK: - Publishing

    private func scheduleMembershipPublish() {
        guard membershipPublishTask == nil, !closed else { return }
        let interval = configuration.membershipInterval
        let elapsed = lastMembershipPublish.map { ContinuousClock.now - $0 } ?? interval
        let delay = elapsed >= interval ? Duration.zero : interval - elapsed
        membershipPublishTask = Task { [weak self, sleep] in
            if delay > .zero { try? await sleep(delay) }
            await self?.membershipTimerFired()
        }
    }

    private func membershipTimerFired() {
        guard !Task.isCancelled else { return }
        membershipPublishTask = nil
        publishMembership(force: false)
    }

    private func publishMembership(force: Bool) {
        guard !closed else { return }
        let tilesChanged = applyDirty()
        guard tilesChanged || listsDirty || force else { return }
        if tilesChanged || listsDirty { membershipRevision &+= 1 }
        listsDirty = false
        lastMembershipPublish = ContinuousClock.now
        publish()
    }

    private func scheduleProgressPublish() {
        guard progressPublishTask == nil, !closed else { return }
        let interval = configuration.progressInterval
        progressPublishTask = Task { [weak self, sleep] in
            try? await sleep(interval)
            await self?.progressTimerFired()
        }
    }

    private func progressTimerFired() {
        progressPublishTask = nil
        progressRevision &+= 1
        publish()
    }

    private func publish() {
        guard store.isOperational() else {
            snapshot = .empty
            snapshotContinuation.yield(snapshot)
            return
        }
        var progress: [PhotoUID: Int] = [:]
        for (key, live) in liveProgress where tilesByKey[key]?.revision == live.revision {
            progress[key.localUID] = live.step
        }
        let lists = excludedLists()
        var favorites: [PhotoUID: Bool] = [:]
        for action in actions where action.kind == .favorite && !action.failed {
            favorites[action.key.localUID] = action.desired
        }
        snapshot = PendingBackupSnapshot(
            membershipRevision: membershipRevision,
            progressRevision: progressRevision,
            tiles: orderedTiles,
            progress: progress,
            trashTiles: lists.trash,
            excludedTiles: lists.excluded,
            favoriteIntents: favorites
        )
        snapshotContinuation.yield(snapshot)
    }

    private func excludedLists() -> (trash: [PendingTile], excluded: [PendingTile]) {
        let currentTime = now()
        // A clock set back can return an expired photo to the trash list, so only a forward clock reuses the lists.
        if let cache = excludedListsCache, cache.builtAt <= currentTime, currentTime <= cache.validUntil {
            return (cache.trash, cache.excluded)
        }
        let retentionStart = currentTime.addingTimeInterval(-configuration.trashRetention)
        var trash: [(Date, PendingTile)] = []
        var excluded: [(Date, PendingTile)] = []
        for state in sourceStates.values where state.desired == .excluded && excludedAccessible.contains(state.key) {
            guard let presentation = state.presentation else { continue }
            let tile = PendingTile(
                key: state.key,
                item: Self.item(for: state.key, metadata: presentation),
                revision: nil,
                handoff: nil,
                isSettled: false,
                badge: .waiting,
                displayName: presentation.displayName
            )
            let excludedAt = state.excludedAt ?? .distantPast
            excluded.append((excludedAt, tile))
            if state.listedInTrash, excludedAt >= retentionStart { trash.append((excludedAt, tile)) }
        }
        let newestFirst: ((Date, PendingTile), (Date, PendingTile)) -> Bool = {
            $0.0 == $1.0 ? $0.1.key < $1.1.key : $0.0 > $1.0
        }
        let lists = (
            trash: trash.sorted(by: newestFirst).map(\.1),
            excluded: excluded.sorted(by: newestFirst).map(\.1)
        )
        let validUntil =
            trash.map(\.0).min().map { $0.addingTimeInterval(configuration.trashRetention) } ?? .distantFuture
        excludedListsCache = (lists.trash, lists.excluded, currentTime, validUntil)
        return lists
    }

    // MARK: - Reconciler

    /// Performs every due effect. Runs one pass at a time; a request during a pass runs another pass.
    ///
    /// Order matters. A restore brings the Proton photo back before the source returns to the backup, so
    /// the duplicate check never mistakes the trashed photo for a deliberate remote deletion. A delete
    /// removes queue work before it trashes, so nothing uploads in between.
    private func reconcile() async {
        guard !closed else { return }
        guard !reconcileRunning else {
            reconcileAgain = true
            return
        }
        reconcileRunning = true
        defer { reconcileRunning = false }
        repeat {
            reconcileAgain = false
            await performRemote(
                .remoteRestore,
                store.dueSourceStates(by: now()).filter {
                    $0.needsRemoteRestore && $0.desired == .included && $0.remote != nil
                })
            guard !closed else { return }
            await performQueueSync(
                store.dueSourceStates(by: now()).filter {
                    $0.needsQueueSync && ($0.desired == .excluded || !$0.needsRemoteRestore)
                })
            guard !closed else { return }
            await performRemote(
                .remoteTrash,
                store.dueSourceStates(by: now()).filter {
                    $0.needsRemoteTrash && $0.desired == .excluded && $0.remote != nil
                })
            guard !closed else { return }
            // A restore can make deferred actions eligible again. Inside the loop, so a request that arrives
            // while an action awaits the network still runs another pass.
            await runDueActions()
        } while reconcileAgain && !closed
        scheduleReconcileTimer()
    }

    private func performQueueSync(_ states: [PendingSourceState]) async {
        guard !states.isEmpty else { return }
        let date = now()
        let excluded = states.filter { $0.desired == .excluded }
        for (kind, group) in Dictionary(grouping: excluded, by: \.key.kind) {
            let ok = await effects.removeFromBackup(kind: kind, identifiers: group.map(\.key.identifier))
            guard !closed else { return }
            finish(.queueSync, group, succeeded: ok, at: date)
        }
        let included = states.filter { $0.desired == .included }
        if !included.isEmpty {
            let ok = await effects.returnToBackup(included.map(\.key))
            guard !closed else { return }
            finish(.queueSync, included, succeeded: ok, at: date)
        }
    }

    private func performRemote(_ effect: PendingSourceEffect, _ states: [PendingSourceState]) async {
        guard !states.isEmpty else { return }
        let date = now()
        let volume = await effects.photosVolumeID()
        guard !closed else { return }
        guard let volume else {
            for state in states { _ = store.deferEffects(for: state.key, at: date) }
            reloadSourceStates(states.map(\.key))
            return
        }
        // Marked right before dispatch, and only while the state still wants this effect for the same
        // generation: a decision taken during the volume lookup wins. Until a confirmed completion, new
        // decisions treat the request as possibly done.
        guard let marked = store.beginRemoteOperation(effect, for: states) else { return }
        let dispatched = states.filter { marked.contains($0.key) }
        guard !dispatched.isEmpty else {
            reloadSourceStates(states.map(\.key))
            return
        }
        let uids = dispatched.compactMap { Self.normalized($0.remote, volume: volume) }
        let result: PendingBatchEffectResult =
            switch effect {
            case .remoteTrash: await effects.trashRemote(uids)
            case .remoteRestore: await effects.restoreRemote(uids)
            case .queueSync: .done
            }
        guard !closed else { return }
        // Only photos without a confirmed answer try again. A photo that can no longer be trashed or restored
        // (deleted permanently) needs no further attempt, and one unanswered photo never holds back the others.
        finish(effect, dispatched, at: date) { state in
            Self.normalized(state.remote, volume: volume).map { !result.retry.contains($0) } ?? true
        }
        // A finished trash can leave the trash of a later commit due, see `PendingBackupManifestStore.completeEffect`.
        let movedOn = dispatched.contains { dispatchedState in
            guard let state = sourceStates[dispatchedState.key] else { return false }
            return state.needsRemoteTrash && state.remoteOperation == nil
                && state.remote?.nodeID != dispatchedState.remote?.nodeID
        }
        if effect == .remoteTrash, movedOn { reconcileAgain = true }
    }

    private func finish(_ effect: PendingSourceEffect, _ states: [PendingSourceState], succeeded: Bool, at date: Date) {
        finish(effect, states, at: date) { _ in succeeded }
    }

    private func finish(
        _ effect: PendingSourceEffect,
        _ states: [PendingSourceState],
        at date: Date,
        succeeded: (PendingSourceState) -> Bool
    ) {
        for state in states {
            if succeeded(state) {
                _ = store.completeEffect(
                    effect, for: state.key, generation: state.generation, remoteLinkID: state.remote?.nodeID, at: date)
            } else {
                _ = store.deferEffects(for: state.key, at: date)
            }
        }
        reloadSourceStates(states.map(\.key))
        listsDirty = true
        scheduleMembershipPublish()
    }

    private func scheduleReconcileTimer() {
        reconcileTimer?.cancel()
        reconcileTimer = nil
        guard !closed, let next = store.nextEffectDate() else { return }
        let seconds = max(1, next.timeIntervalSince(now()))
        reconcileTimer = Task { [weak self, sleep] in
            try? await sleep(.seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    private static func normalized(_ uid: PhotoUID?, volume: String) -> PhotoUID? {
        guard let uid else { return nil }
        return uid.volumeID.isEmpty ? PhotoUID(volumeID: volume, nodeID: uid.nodeID) : uid
    }

    // MARK: - Deferred actions

    /// Applies due favorite and album actions of sources whose Proton photo exists. Independent of the
    /// grid: an action also runs after its tile retired or after a relaunch, and retries on its own timer.
    private func runDueActions() async {
        guard !closed else { return }
        guard !actionsRunning else {
            actionsAgain = true
            return
        }
        actionsRunning = true
        defer { actionsRunning = false }
        repeat {
            actionsAgain = false
            let latest = store.latestHandoffs(for: Array(Set(store.dueActions(by: now()).map(\.key))))
            // Actions of sources without a Proton photo wait for their handoff event, not for a timer.
            let due = store.dueActions(by: now()).filter { latest[$0.key] != nil && actionIsEligible($0.key) }
            guard !due.isEmpty else { break }
            let volume = await effects.photosVolumeID()
            guard !closed else { return }
            guard let volume else {
                for action in due { _ = store.retryAction(action, at: now()) }
                break
            }
            for action in due {
                guard !closed else { return }
                // A delete or restore can land during any await above; recheck right before dispatch.
                guard actionIsEligible(action.key),
                    let remote = Self.normalized(latest[action.key]?.remote, volume: volume)
                else { continue }
                let result: PendingEffectResult =
                    switch action.kind {
                    case .favorite: await effects.setFavorite(remote, favorite: action.desired)
                    case .addToAlbum: await effects.addToAlbum(remote, albumID: action.albumID)
                    }
                guard !closed else { return }
                switch result {
                case .done: _ = store.completeAction(action)
                case .retry: _ = store.retryAction(action, at: now())
                case .permanentFailure:
                    _ = store.failAction(action)
                    PhotoDiagnostics.shared.increment("pending.actionFailed")
                }
            }
            actions = store.actions()
            listsDirty = true
            scheduleMembershipPublish()
        } while actionsAgain && !closed
        scheduleActionTimer()
    }

    /// Wakes for the earliest retry among actions whose Proton photo is known. Actions still waiting for an
    /// upload never pull the timer forward; their handoff event starts them.
    /// Actions wait while the source is excluded or its Proton photo still has to come back from the trash.
    private func actionIsEligible(_ key: PendingSourceKey) -> Bool {
        guard let state = sourceStates[key] else { return true }
        return state.desired == .included && !state.needsRemoteRestore
    }

    private func scheduleActionTimer() {
        actionTimer?.cancel()
        actionTimer = nil
        guard !closed else { return }
        let pending = store.actions().filter { !$0.failed }
        guard !pending.isEmpty else { return }
        let withRemote = store.latestHandoffs(for: Array(Set(pending.map(\.key))))
        guard
            let next = pending.filter({ withRemote[$0.key] != nil && actionIsEligible($0.key) })
                .map(\.nextAttemptAt).min()
        else { return }
        let seconds = max(1, next.timeIntervalSince(now()))
        actionTimer = Task { [weak self, sleep] in
            try? await sleep(.seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.runDueActions()
        }
    }
}
