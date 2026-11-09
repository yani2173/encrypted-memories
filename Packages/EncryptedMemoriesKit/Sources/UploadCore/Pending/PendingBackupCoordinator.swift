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
        /// First retry after a source state could not be read. Each further failed retry doubles it, up to the limit.
        public var unreadableRetryDelay: Duration
        public var unreadableRetryLimit: Duration
        /// While a full queue read is owed, queue events retry it at most once per this delay (#1004).
        public var inventoryRetryDelay: Duration

        public init(
            membershipInterval: Duration = .seconds(1),
            progressInterval: Duration = .milliseconds(250),
            doneLinger: Duration = .seconds(2),
            checkmarkDuration: Duration = .seconds(1),
            uncheckedAdmissionLimit: Int = 64,
            trashRetention: TimeInterval = 30 * 24 * 60 * 60,
            acknowledgedHandoffRetention: TimeInterval = 7 * 24 * 60 * 60,
            libraryChangeDelay: Duration = .milliseconds(500),
            unreadableRetryDelay: Duration = .seconds(60),
            unreadableRetryLimit: Duration = .seconds(30 * 60),
            inventoryRetryDelay: Duration = .seconds(2)
        ) {
            self.membershipInterval = membershipInterval
            self.progressInterval = progressInterval
            self.doneLinger = doneLinger
            self.checkmarkDuration = checkmarkDuration
            self.uncheckedAdmissionLimit = uncheckedAdmissionLimit
            self.trashRetention = trashRetention
            self.acknowledgedHandoffRetention = acknowledgedHandoffRetention
            self.libraryChangeDelay = libraryChangeDelay
            // A zero delay would retry an unreadable row without pause.
            self.unreadableRetryDelay = max(.seconds(1), unreadableRetryDelay)
            self.unreadableRetryLimit = unreadableRetryLimit
            self.inventoryRetryDelay = inventoryRetryDelay
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
    private let restoreRecheckDelays: [TimeInterval]

    // Model, all keyed by source.
    private var rows: [PendingSourceKey: UploadBackupQueueRowState] = [:]
    private var evidence: [PendingSourceKey: Set<UploadBackupRevision>] = [:]
    private var replacements: [PendingSourceKey: [UploadBackupRevision: [PhotoUID]]] = [:]
    private var handoffs: [PendingSourceKey: PendingHandoff] = [:]
    private var sourceStates: [PendingSourceKey: PendingSourceState] = [:] {
        didSet { excludedListsCache = nil }
    }
    /// Sources whose last state read failed. Their owed work waits; it never counts as "nothing owed".
    private var unreadableSourceStates = Set<PendingSourceKey>()
    /// The last load of every source state was incomplete, so cached absence alone grants no action.
    private var sourceStatesIncomplete = false
    /// The sources that incomplete load decoded. Known pending sources need this proof before running actions.
    private var loadDecodedKeys = Set<PendingSourceKey>()
    /// Keys observed with a pending state. A later keyed absence cannot hide damaged key bytes.
    private var knownSourceStateKeys = Set<PendingSourceKey>()
    /// The current reconcile pass could not read every due source state. Set before the pass awaits any effect.
    private var dueStatesIncomplete = false
    /// The sources whose state the due reads of that pass decoded. Only they may run actions until a complete read.
    private var dueDecodedKeys = Set<PendingSourceKey>()
    /// The last read of the pending actions failed or left out a row that did not decode.
    private var actionsIncomplete = false
    /// Sources of pending actions whose latest handoff could not be read. Their actions wait for the backoff.
    private var unreadableHandoffKeys = Set<PendingSourceKey>()
    /// The current retry delay while a source state cannot be read; nil when every read succeeded.
    private var unreadableRetry: Duration?
    /// Some source state could not be read by the last load, the current due reads, or a keyed read.
    private var sourceStatesDegraded: Bool {
        dueStatesIncomplete || sourceStatesIncomplete || !unreadableSourceStates.isEmpty
    }
    /// The last pass over the pending actions could not read every action or every handoff it needed.
    private var actionsDegraded: Bool { actionsIncomplete || !unreadableHandoffKeys.isEmpty }
    /// Results that must be saved before the same effect or action can be dispatched again.
    private enum PendingEffectWrite {
        case complete(PendingSourceEffect, generation: Int64, remoteLinkID: String?)
        case deferAttempt(generation: Int64)
    }

    /// The same identity that the store checks before changing or deleting an action.
    private struct PendingActionID: Hashable {
        let key: PendingSourceKey
        let kind: String
        let albumID: String
        let desired: Bool
        let createdAt: Date

        init(_ action: PendingAction) {
            key = action.key
            kind = action.kind.rawValue
            albumID = action.albumID
            desired = action.desired
            createdAt = action.createdAt
        }
    }

    private struct PendingActionWrite {
        let action: PendingAction
        let result: PendingEffectResult
    }

    private var pendingEffectWrites: [PendingSourceKey: PendingEffectWrite] = [:]
    private var pendingActionWrites: [PendingActionID: PendingActionWrite] = [:]
    /// A's completion is durable, but its latest handoff still has to establish whether B needs the trash.
    private var unreadableLaterTrashKeys = Set<PendingSourceKey>()
    private var startupLaterTrashKeys = Set<PendingSourceKey>()
    private var startupLaterTrashGenerations: [PendingSourceKey: Int64] = [:]
    private var laterTrashRecoveryTask: Task<Void, Never>?
    /// Deletes of an unfinished edit that named no earlier upload, because the handoff could not be read. The reconcile
    /// backoff reads each handoff again, see `retryEarlierUpload`. Only this session knows them: after a restart the
    /// earlier upload stays in Proton.
    private var earlierUploadRetries: [PendingSourceKey: EarlierUploadRetry] = [:]
    private struct EarlierUploadRetry {
        let revision: UploadBackupRevision
        let generation: Int64
        let hidden: [PhotoUID]
    }
    private static let laterTrashBatchSize = 100
    /// The waits after the first, second and third automatic Restore check of one source and generation.
    package static let defaultRestoreRecheckDelays: [TimeInterval] = [60, 300, 900]
    /// A rejected dispatch marker sent nothing; the next reconcile tries it again.
    private var beginFailedKeys = Set<PendingSourceKey>()
    private var writesDegraded: Bool {
        !pendingEffectWrites.isEmpty || !pendingActionWrites.isEmpty || !beginFailedKeys.isEmpty
    }

    private func effectWriteIsPending(_ key: PendingSourceKey) -> Bool {
        pendingEffectWrites[key] != nil || beginFailedKeys.contains(key)
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
    /// The excluded sources that the last check of the excluded list examined, or nil when that check saw all of them.
    /// After an incomplete load a source whose state did not decode is not cached, so the check cannot see it; the next
    /// load that decodes another excluded source checks the list again.
    private var excludedCheckExamined: Set<PendingSourceKey>?
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
    /// Kinds whose last full queue inventory failed. Their cached rows stay the last known ones, and unchecked photos
    /// wait, until the next queue event of the kind or the next library change reads the inventory again (#1004).
    private var inventoryOwed = Set<UploadSourceIdentity.Kind>()
    /// Sources whose keyed reload failed. They keep their cached row and state until a later read answers.
    private var reloadOwed = Set<PendingSourceKey>()
    /// Unchecked sources whose earlier revisions could not be read. One may be an edit of a backed-up photo, so it
    /// waits out of admission until a read answers.
    private var earlierRevisionsUnknown = Set<PendingSourceKey>()
    /// The one pending retry of an owed full read per kind. Queue events within its delay share it.
    private var inventoryRetries: [UploadSourceIdentity.Kind: Task<Void, Never>] = [:]

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
    private var restoreReturnOutcomes: [PendingSourceKey: (generation: Int64, outcome: PendingBackupReturnOutcome)] =
        [:]
    private var restoreRequests: [PendingSourceKey: Int] = [:]
    private var restoreRecheckCounts: [PendingSourceKey: (generation: Int64, remote: PhotoUID?, count: Int)] = [:]
    private var reconcileTimer: Task<Void, Never>?
    private var actionsRunning = false
    private var actionsAgain = false
    private var actionTimer: Task<Void, Never>?
    /// The check of the excluded photos that a library change started, and whether a change arrived while it read.
    private var excludedCheckTask: Task<Void, Never>?
    private var excludedCheckReading = false
    private var excludedCheckAgain = false

    package init(
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
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        restoreRecheckDelays: [TimeInterval] = PendingBackupCoordinator.defaultRestoreRecheckDelays
    ) {
        precondition(!restoreRecheckDelays.isEmpty, "Restore rechecks need at least one delay")
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
        self.restoreRecheckDelays = restoreRecheckDelays
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
        // Housekeeping only: a failed prune keeps rows longer; the SQL keeps those of unfinished work anyway.
        _ = store.pruneAcknowledgedHandoffs(olderThan: handoffCutoff)
        evidence = store.evidenceRevisions()
        for (key, revisions) in evidence {
            for revision in revisions {
                if let record = recorder?.replacementLedger.evidence(for: key, revision: revision) { remember(record) }
            }
        }
        // Display only: a handoff that cannot be read stays out of the tile memory; no owed work depends on it.
        for handoff in store.unacknowledgedHandoffs() { remember(handoff) }
        loadSourceStates()
        savedFromApp = store.savedFromAppIdentifiers()
        // The favorites shown; `runDueActions` reads the owed actions itself.
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
            for row in certifiedInventory(of: kind, from: queue) ?? [] { absorb(row) }
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
        queueLaterTrashRecovery()
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
        for retry in inventoryRetries.values { retry.cancel() }
        inventoryRetries.removeAll()
        laterTrashRecoveryTask?.cancel()
        startupLaterTrashKeys.removeAll()
        startupLaterTrashGenerations.removeAll()
        earlierUploadRetries.removeAll()
        restoreReturnOutcomes.removeAll()
        restoreRecheckCounts.removeAll()
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
        var unknownEarlier: [PendingSourceKey: (revision: UploadBackupRevision, hidden: [PhotoUID])] = [:]
        for key in keys {
            let revision = tilesByKey[key]?.revision ?? rows[key]?.revision
            var remote = handoffs[key].flatMap { $0.revision == revision ? $0.remote : nil }
            var remoteUnknown = false
            if remote == nil {
                let earlier = await hiddenEarlierUpload(of: key, before: revision)
                guard !closed else { return false }
                switch earlier {
                case .found(let target, let links):
                    remote = target
                    earlierLinks[key] = links
                case .unknown(let hidden):
                    remoteUnknown = true
                    if let revision { unknownEarlier[key] = (revision, hidden) }
                case .none: break
                }
            }
            requests.append(
                PendingExclusionRequest(
                    key: key, presentation: metadata[key], remote: remote, revision: revision,
                    remoteUnknown: remoteUnknown))
        }
        // A delete or restore of the same source during a lookup is the person's later decision, and it stands.
        requests.removeAll { actionTokens[$0.key] != tokens[$0.key] }
        guard !requests.isEmpty else { return true }
        let date = now()
        guard var states = store.exclude(requests, at: date) else { return false }
        for request in requests {
            guard let index = states.firstIndex(where: { $0.key == request.key }) else { continue }
            // Only a stored later delete ends the prior retry; a failed write leaves that deletion in force.
            earlierUploadRetries[request.key] = nil
            if let links = earlierLinks[request.key], let target = request.remote {
                states[index] = forgetEarlierUpload(
                    target, links: links, state: states[index], revision: request.revision, at: date)
            } else if let unknown = unknownEarlier[request.key], states[index].remote == nil {
                earlierUploadRetries[request.key] = EarlierUploadRetry(
                    revision: unknown.revision, generation: states[index].generation, hidden: unknown.hidden)
            }
        }
        let excluded = requests.map(\.key)
        for key in excluded { restoreRecheckCounts.removeValue(forKey: key) }
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
    ) async -> EarlierUpload {
        guard let revision, let tile = tilesByKey[key], tile.revision == revision else { return .none }
        return await earlierUpload(
            of: key, revision: revision, hidden: tile.replaces,
            handoff: { store.latestHandoffsRead(for: [key])[key] ?? .unreadable },
            stillDeleted: { target in
                // The tile can change during the lookup; only the photo that it still hides is the person's deletion.
                guard let current = tilesByKey[key], current.revision == revision else { return false }
                return current.replaces.contains(where: { $0.nodeID == target.nodeID })
            })
    }

    /// The rules of `hiddenEarlierUpload` for the photos `hidden` that the edit `revision` of `key` hides. A delete
    /// and its later retry both decide here. `stillDeleted` tells after the server lookup whether the person's
    /// deletion still covers the target.
    private func earlierUpload(
        of key: PendingSourceKey,
        revision: UploadBackupRevision,
        hidden replaces: [PhotoUID],
        handoff: () -> PendingHandoffRead,
        stillDeleted: (PhotoUID) -> Bool
    ) async -> EarlierUpload {
        let hidden = Set(replaces.map(\.nodeID))
        guard !hidden.isEmpty, let identities, let relations else { return .none }
        let target: PhotoUID?
        // A stored handoff of this or a later revision is the edit's own commit, whose event has not arrived yet; the
        // journal still names the earlier upload. The store trashes the commit after it.
        switch handoff() {
        case .unreadable:
            // The handoff could name another photo than the journal; nothing chosen on an unknown goes to the trash.
            return .unknown(replaces)
        case .readable(let earlier?) where earlier.revision < revision:
            target = earlier.kind == .uploaded && hidden.contains(earlier.remote.nodeID) ? earlier.remote : nil
        case .readable:
            target = newestEarlierMain(of: key, among: replaces)
        }
        guard let target,
            let related = try? await relations.relatedPhotoLinkIDs(ofMainLinkID: target.nodeID)
        else { return .none }
        guard stillDeleted(target) else { return .none }
        let source = UploadSourceIdentity(kind: key.kind, identifier: key.identifier)
        let links = related.union([target.nodeID])
        guard !identities.isNeededElsewhere(links, by: source) else { return .none }
        return .found(target, links)
    }

    /// The earlier upload that the delete of an edit sends to the Proton trash. `unknown`: the handoff could not be
    /// read, so the delete names no photo at all, not even one that the stored state still knows. It carries the photos
    /// that the edit hides, for the retry.
    private enum EarlierUpload {
        case found(PhotoUID, Set<String>)
        case none
        case unknown([PhotoUID])
    }

    /// The manifest gives up the earlier upload only after the delete is stored. When it cannot, the photo stays.
    private func forgetEarlierUpload(
        _ target: PhotoUID,
        links: Set<String>,
        state: PendingSourceState,
        revision: UploadBackupRevision?,
        at date: Date
    ) -> PendingSourceState {
        guard
            identities?.forgetRemoteLinks(
                links, of: UploadSourceIdentity(kind: state.key.kind, identifier: state.key.identifier)) != true,
            state.needsRemoteTrash,
            let kept = store.keepRemote(
                target, of: state.key, generation: state.generation, revision: revision, at: date)
        else { return state }
        return kept
    }

    /// Checks one captured delete after the reconcile backoff reads its handoff. Reconciliation runs due effects
    /// between these sequential server lookups. A readable handoff ends that read retry; only the same stored
    /// deletion without a photo may accept a proven earlier upload.
    private func retryEarlierUpload(
        _ key: PendingSourceKey, retry: EarlierUploadRetry, read: PendingHandoffRead
    ) async {
        guard !closed else { return }
        // A lookup for another key may have awaited while a restore and later delete registered a new retry.
        guard earlierUploadRetries[key]?.generation == retry.generation else { return }
        let current = { [self] in
            let state = sourceStates[key]
            return state?.desired == .excluded && state?.generation == retry.generation && state?.remote == nil
        }
        // A restore, a later delete or a photo for the trash ended this delete.
        guard current() else {
            earlierUploadRetries[key] = nil
            return
        }
        guard read != .unreadable else { return }
        earlierUploadRetries[key] = nil
        let earlier = await earlierUpload(
            of: key, revision: retry.revision, hidden: retry.hidden, handoff: { read },
            stillDeleted: { _ in current() })
        guard case .found(let target, let links) = earlier, !closed else { return }
        let date = now()
        guard let state = store.trashEarlierUpload(target, of: key, generation: retry.generation, at: date) else {
            // The write failed; the next backoff reads and decides again.
            earlierUploadRetries[key] = retry
            return
        }
        sourceStates[key] = state
        dirty.insert(key)
        listsDirty = true
        guard state.remote == target, state.needsRemoteTrash else { return }
        sourceStates[key] = forgetEarlierUpload(
            target, links: links, state: state, revision: retry.revision, at: date)
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
        return await restore(keys)
    }

    private func restore(_ keys: [PendingSourceKey], confirmedRemotes: [PhotoUID] = []) async -> Bool {
        guard !closed else { return false }
        guard !keys.isEmpty else { return true }
        for key in keys { _ = nextActionToken(for: key) }
        let states =
            confirmedRemotes.isEmpty
            ? store.include(keys, at: now())
            : store.includeRestoredInProton(keys, confirmedRemotes: confirmedRemotes, at: now())
        guard let states else { return false }
        for key in keys {
            startupLaterTrashKeys.remove(key)
            startupLaterTrashGenerations.removeValue(forKey: key)
            earlierUploadRetries[key] = nil
        }
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
    @discardableResult
    public func restoreSources(ofRemote uids: [PhotoUID]) async -> PendingBackupRestoreResult {
        guard !closed, !uids.isEmpty else {
            return PendingBackupRestoreResult(discoveryComplete: !closed)
        }
        let linkIDs = Set(uids.map(\.nodeID))
        guard case .complete(let handoffs) = store.handoffsRead(forRemoteLinkIDs: Array(linkIDs)) else {
            return PendingBackupRestoreResult(discoveryComplete: false)
        }
        // The earlier upload of a deleted edit can have no handoff left; the delete recorded it as its photo.
        let deleted = sourceStates.values.filter { state in
            state.remote.map { linkIDs.contains($0.nodeID) } == true
        }.map(\.key)
        let discovered = Set(handoffs.map(\.key) + deleted)
        var states: [PendingSourceState] = []
        for key in discovered {
            switch store.sourceStateRead(for: key) {
            case .unreadable:
                return PendingBackupRestoreResult(
                    outcomes: Dictionary(uniqueKeysWithValues: discovered.map { ($0, .unreadable) }))
            case .readable(nil):
                // Nothing is pending: the store deletes a row only once it is included with nothing owed.
                continue
            case .readable(let state?):
                states.append(state)
            }
        }
        let keys = Set(states.map(\.key))
        let excluded = states.filter { $0.desired == .excluded }.map(\.key)
        for key in keys { restoreRecheckCounts.removeValue(forKey: key) }
        for key in keys { restoreRequests[key, default: 0] += 1 }
        defer {
            for key in keys {
                if let count = restoreRequests[key], count > 1 {
                    restoreRequests[key] = count - 1
                } else {
                    restoreRequests.removeValue(forKey: key)
                    restoreReturnOutcomes.removeValue(forKey: key)
                }
            }
        }
        if !excluded.isEmpty {
            guard await restore(excluded, confirmedRemotes: uids) else {
                return PendingBackupRestoreResult(
                    outcomes: Dictionary(uniqueKeysWithValues: keys.map { ($0, .unreadable) }))
            }
        } else {
            await reconcile()
        }
        var result = PendingBackupRestoreResult()
        for state in states {
            let generation = state.generation + (state.desired == .excluded ? 1 : 0)
            if let returned = restoreReturnOutcomes[state.key], returned.generation == generation {
                result.outcomes[state.key] = returned.outcome
            } else if case .readable(let current?) = store.sourceStateRead(for: state.key),
                current.desired == .included, current.generation == generation
            {
                result.outcomes[state.key] = .waiting(until: current.nextAttemptAt)
            } else {
                result.outcomes[state.key] = .unreadable
            }
        }
        return result
    }

    /// "Endgültig löschen" / "Papierkorb leeren": the entries leave "Zuletzt gelöscht", the photos stay
    /// excluded from backup.
    @discardableResult
    public func removeFromTrashList(_ uids: [PhotoUID]) -> Bool {
        guard !closed else { return false }
        let keys = uids.compactMap(PendingSourceKey.init(localUID:))
        guard store.unlistFromTrash(keys, at: now()) else { return false }
        reloadSourceStates(keys)
        if !reconcileRunning, unreadableRetry == nil,
            keys.contains(where: { unreadableSourceStates.contains($0) })
        {
            // The reload failed, so the shown list keeps its stale tile until a read succeeds. Arm the
            // degraded retry, as startup recovery does (#913). A degraded wait that is already set keeps
            // its delay, as the degraded action-timer guard does: `scheduleReconcileTimer` restarts the countdown.
            scheduleReconcileTimer(advanceBackoff: false)
        }
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
        // The favorites shown; `runDueActions` reads the owed actions itself.
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
        // The favorites shown; `runDueActions` reads the owed actions itself.
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
        if retryOwedReads() { await refreshMetadata() }
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
            reloadInventory(of: kind, from: queue)
            retryOwedKeys(of: kind)
        case .sources(let grouped), .enqueued(let grouped):
            scheduleInventoryRetry(of: kind)
            let identifiers = grouped[kind] ?? []
            let keys = Set(identifiers.map { PendingSourceKey(kind: kind, identifier: $0) })
            retryOwedKeys(of: kind, with: keys)
            dirty.formUnion(keys)
        }
        await refreshMetadata()
        scheduleMembershipPublish()
    }

    /// The complete unsettled rows of a kind. A failed read answers nil and owes the inventory: a prefix or an empty
    /// answer never counts as the queue (#1004).
    private func certifiedInventory(
        of kind: UploadSourceIdentity.Kind, from queue: any UploadBackupSyncQueueObserving
    ) -> [UploadBackupQueueRowState]? {
        guard let inventory = try? queue.decisionUnsettledRows() else {
            inventoryOwed.insert(kind)
            return nil
        }
        inventoryOwed.remove(kind)
        return inventory.filter { $0.source.kind == kind }
    }

    /// Replaces the cached rows of a kind with its complete inventory. An unknown inventory changes nothing: no row
    /// counts as gone, and no source state, checkmark or replacement evidence is dropped.
    private func reloadInventory(of kind: UploadSourceIdentity.Kind, from queue: any UploadBackupSyncQueueObserving) {
        guard let inventory = certifiedInventory(of: kind, from: queue) else { return }
        let wasUnknown = earlierRevisionsUnknown.filter { $0.kind == kind }
        let previousRows = rows.filter { $0.key.kind == kind }
        for key in previousRows.keys { rows[key] = nil }
        for row in inventory { absorb(row) }
        if kind == .photoLibraryAsset { learnBackedUpSources() }
        learnEarlierRevisions()
        let current = Set(rows.keys.filter { $0.kind == kind })
        let gone = Set(previousRows.keys).subtracting(current)
        // A row that was still active settled or left: it takes the per-source path, so its durable handoff
        // keeps the tile. Rows that had settled before only drop their state; there can be many of them.
        let wasActive = gone.filter { key in
            guard let state = previousRows[key]?.state else { return false }
            return !Self.isBackedUp(state)
        }
        for key in gone.subtracting(wasActive) where handoffs[key] == nil { dropSourceState(key) }
        let reload = Set(handoffs.keys.filter { $0.kind == kind }).subtracting(current).union(wasActive)
        // A failed reload must not hide these sources, for example a photo that just settled and whose handoff event
        // has not arrived yet: their last known rows stay until a read answers.
        for key in reload { rows[key] = previousRows[key] }
        reloadRows(for: reload)
        // A restored row keeps its earlier-revision hold until a keyed read answers: the full read above dropped the
        // hold, because the source was missing from the inventory.
        earlierRevisionsUnknown.formUnion(wasUnknown.intersection(reload).intersection(reloadOwed))
        dirty.formUnion(Set(previousRows.keys).union(current))
    }

    /// Queue events retry an owed full read after `inventoryRetryDelay`, once for all events meanwhile: a read that
    /// fails again on every event would otherwise scan the queue once per event. A library change or the app becoming
    /// active still reads at once.
    private func scheduleInventoryRetry(of kind: UploadSourceIdentity.Kind) {
        guard inventoryOwed.contains(kind), inventoryRetries[kind] == nil, !closed else { return }
        let delay = configuration.inventoryRetryDelay
        inventoryRetries[kind] = Task { [weak self, sleep] in
            // The sleep suspends this task only; the coordinator handles events meanwhile.
            do { try await sleep(delay) } catch { return }
            await self?.retryInventory(of: kind)
        }
    }

    private func retryInventory(of kind: UploadSourceIdentity.Kind) async {
        inventoryRetries[kind] = nil
        guard !closed, inventoryOwed.contains(kind), let queue = queues[kind] else { return }
        reloadInventory(of: kind, from: queue)
        retryOwedKeys(of: kind)
        await refreshMetadata()
        scheduleMembershipPublish()
    }

    /// Reads the owed keyed rows and earlier revisions of a kind again, together with `keys`.
    private func retryOwedKeys(of kind: UploadSourceIdentity.Kind, with keys: Set<PendingSourceKey> = []) {
        let owed = keys.union(reloadOwed.filter { $0.kind == kind })
        if !owed.isEmpty { reloadRows(for: owed) }
        retryEarlierRevisions(of: kind)
    }

    /// Reads the unknown earlier revisions of a kind in turns of at most the admission limit, in a fixed order, all
    /// within this retry: `learnEarlierRevisions` reads nothing for a larger set. More unknown keys than the limit
    /// happen when unknown photos leave the admission count (their upload evidence arrives) and a later admission adds
    /// new unknown ones. A turn whose read fails is read again one source at a time, so one source whose read keeps
    /// failing holds only itself.
    private func retryEarlierRevisions(of kind: UploadSourceIdentity.Kind) {
        let unknown = earlierRevisionsUnknown.filter { $0.kind == kind }.sorted()
        let turn = max(1, configuration.uncheckedAdmissionLimit)
        for start in stride(from: 0, to: unknown.count, by: turn) {
            let keys = Set(unknown[start..<min(start + turn, unknown.count)])
            learnEarlierRevisions(of: keys)
            let failed = keys.intersection(earlierRevisionsUnknown)
            guard failed.count > 1 else { continue }
            for key in failed.sorted() { learnEarlierRevisions(of: [key]) }
        }
    }

    /// A library change or the app becoming active reads every owed inventory and keyed row again, so an unknown read
    /// does not wait for a queue change. Answers whether anything was owed.
    private func retryOwedReads() -> Bool {
        guard !inventoryOwed.isEmpty || !reloadOwed.isEmpty || !earlierRevisionsUnknown.isEmpty else { return false }
        for (kind, queue) in queues {
            if inventoryOwed.contains(kind) { reloadInventory(of: kind, from: queue) }
            retryOwedKeys(of: kind)
        }
        return true
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

    /// The queue settled the row with a backup: uploaded now or found already backed up. A row that the queue skipped
    /// as deleted remotely is not backed up.
    private static func isBackedUp(_ state: UploadBackupSyncQueueState) -> Bool {
        state == .completed || state == .alreadyBackedUp
    }

    /// Notes each source that `fetched` shows backed up at an earlier revision than its current row.
    private func noteBackedUpBefore(_ fetched: [UploadBackupQueueRowState]) {
        for row in fetched where Self.isBackedUp(row.state) {
            let key = PendingSourceKey(row.source)
            if let newest = rows[key]?.revision, row.revision < newest { backedUpBefore.insert(key) }
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
            // An unknown answer is not an absent row: the cached row and its state stay until a later read answers.
            guard let fetched = try? queue.decisionRows(kind: kind, identifiers: Set(kindKeys.map(\.identifier))) else {
                reloadOwed.formUnion(kindKeys)
                continue
            }
            reloadOwed.subtract(kindKeys)
            for key in kindKeys { rows[key] = nil }
            for row in fetched { absorb(row) }
            noteBackedUpBefore(fetched)
            // The keyed read returned every revision of these sources.
            earlierRevisionsUnknown.subtract(kindKeys)
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
        // A source that is no longer unchecked, or is known to be backed up before, needs no earlier read. This only
        // bounds the set: a stale key is never read, because the candidates are filtered to unchecked rows first.
        // Mutation row M24 (#1004) survives by design: removing this line has no output or I/O effect.
        earlierRevisionsUnknown.subtract((candidates ?? earlierRevisionsUnknown).subtracting(unchecked))
        guard !unchecked.isEmpty, unchecked.count <= configuration.uncheckedAdmissionLimit else { return }
        for (kind, keys) in Dictionary(grouping: unchecked, by: \.kind) {
            guard let queue = queues[kind] else { continue }
            guard let fetched = try? queue.decisionRows(kind: kind, identifiers: Set(keys.map(\.identifier))) else {
                earlierRevisionsUnknown.formUnion(keys)
                continue
            }
            let answered = earlierRevisionsUnknown.intersection(keys)
            earlierRevisionsUnknown.subtract(answered)
            dirty.formUnion(answered)
            noteBackedUpBefore(fetched)
        }
    }

    /// The runner writes a handoff to the store before the queue settles its row, but the coordinator hears
    /// about the queue change and the handoff event on separate streams. A settled or vanished row whose
    /// handoff event has not arrived yet would hide the tile until it does; the durable handoff keeps it.
    private func rememberDurableHandoffs(for keys: [PendingSourceKey]) {
        let settled = keys.filter { key in
            guard let row = rows[key] else { return handoffs[key] == nil }
            guard Self.isBackedUp(row.state) else { return false }
            return handoffs[key]?.revision != row.revision
        }
        guard !settled.isEmpty else { return }
        // Display only: an unreadable handoff stays out of the tile memory; no owed work depends on it.
        for handoff in store.latestHandoffs(for: settled).values { remember(handoff) }
    }

    private func loadSourceStates() {
        let read = store.sourceStatesRead()
        let decoded = Dictionary(uniqueKeysWithValues: read.states.map { ($0.key, $0) })
        if read.complete {
            sourceStates = decoded
            knownSourceStateKeys = Set(decoded.keys)
            loadDecodedKeys = []
        } else {
            // A source missing from an incomplete list keeps its last known state for timing and restores, but that
            // state may be stale, so known pending sources need this load to decode them before running actions.
            sourceStates.merge(decoded) { _, current in current }
            knownSourceStateKeys.formUnion(decoded.keys)
            loadDecodedKeys = Set(decoded.keys)
        }
        sourceStatesIncomplete = !read.complete
        if let examined = excludedCheckExamined,
            read.states.contains(where: { $0.desired == .excluded && !examined.contains($0.key) })
        {
            noteLibraryChanged()
        }
    }

    private func reloadSourceStates(_ keys: [PendingSourceKey]) {
        for key in keys {
            switch store.sourceStateRead(for: key) {
            case .readable(let state):
                if state != nil || sourceStates[key] != nil { knownSourceStateKeys.insert(key) }
                sourceStates[key] = state
                unreadableSourceStates.remove(key)
                if state?.desired != .excluded {
                    startupLaterTrashKeys.remove(key)
                    startupLaterTrashGenerations.removeValue(forKey: key)
                }
            case .unreadable:
                // The last known state stays; the source waits until a read succeeds.
                unreadableSourceStates.insert(key)
            }
        }
        dirty.formUnion(keys)
    }

    /// Reloads the keys and publishes the shown lists when a source that was unreadable reads again.
    private func reloadSourceStatesPublishingHeals(_ keys: [PendingSourceKey]) {
        let degradedBefore = unreadableSourceStates
        reloadSourceStates(keys)
        if degradedBefore.contains(where: { !unreadableSourceStates.contains($0) }) {
            // A recovered read can change the shown lists: the stale trash tile of a failed
            // `removeFromTrashList` reload (issue #913) leaves only when this publish runs, so
            // the repair does not wait for the next membership event. Same pattern as `finish`.
            listsDirty = true
            scheduleMembershipPublish()
        }
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
        // An unknown inventory may hold many more unchecked photos than the known rows (#1004).
        let admits = inventoryOwed.isEmpty && uncheckedSources.count <= configuration.uncheckedAdmissionLimit
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
    /// Display only: a source whose state cannot be read shows by its last known state.
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
                guard admitsUnchecked, Self.isUnchecked(row.state), !earlierRevisionsUnknown.contains(key) else {
                    return false
                }
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
        let settled = Self.isBackedUp(row.state)
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
        let answer = await metadataProvider.metadataAnswer(for: Array(missing))
        let fetched = answer.metadata
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
            } else if answer.unknown.contains(key) {
                // A failed read proves nothing: the source keeps its current metadata and its next event reads again.
                continue
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
        excludedCheckExamined = sourceStatesIncomplete ? Set(excluded) : nil
        guard !excluded.isEmpty else {
            if !excludedAccessible.isEmpty {
                excludedAccessible = []
                listsDirty = true
            }
            return
        }
        let answer = await metadataProvider.metadataAnswer(for: excluded)
        guard !closed else { return }
        // A photo excluded during the read keeps the answer that its exclusion stored. A photo whose read failed keeps
        // its earlier answer (#1004).
        let checked = excludedAccessible.subtracting(excluded).union(answer.metadata.keys)
            .union(excludedAccessible.intersection(answer.unknown)).subtracting(excludedMissing)
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
    private func reconcile(retryLaterTrash: Bool = true, retryEarlierUploads retryEarlier: Bool = false) async {
        guard !closed else { return }
        guard store.isOperational() else {
            // No cached decision grants work while the whole store is unknown. Its future dates cannot shorten the
            // existing unreadable backoff either; keyed reads recover these sources after the connection recovers.
            sourceStatesIncomplete = true
            loadDecodedKeys.removeAll()
            dueStatesIncomplete = true
            dueDecodedKeys.removeAll()
            unreadableSourceStates.formUnion(sourceStates.keys)
            scheduleReconcileTimer()
            return
        }
        guard !reconcileRunning else {
            reconcileAgain = true
            return
        }
        reconcileRunning = true
        defer { reconcileRunning = false }
        if sourceStatesIncomplete {
            loadSourceStates()
            queueLaterTrashRecovery()
        }
        if !unreadableSourceStates.isEmpty {
            reloadSourceStatesPublishingHeals(Array(unreadableSourceStates))
        }
        let laterTrashKeys = retryLaterTrash ? Array(unreadableLaterTrashKeys) : []
        retryPendingWrites()
        let earlierRetries = retryEarlier ? Array(earlierUploadRetries) : []
        let earlierReads =
            earlierRetries.isEmpty ? [:] : store.latestHandoffsRead(for: earlierRetries.map(\.key))
        var earlierIterator = earlierRetries.makeIterator()
        for offset in stride(from: 0, to: laterTrashKeys.count, by: Self.laterTrashBatchSize) {
            guard !closed else { return }
            let batch = Array(laterTrashKeys[offset..<min(offset + Self.laterTrashBatchSize, laterTrashKeys.count)])
            resumeLaterTrash(batch)
            await Task.yield()
        }
        guard !closed else { return }
        repeat {
            reconcileAgain = false
            var incomplete = false
            var decoded = Set<PendingSourceKey>()
            func due() -> [PendingSourceState] {
                let read = store.dueSourceStatesRead(by: now())
                if !read.complete { incomplete = true }
                decoded.formUnion(read.states.map(\.key))
                knownSourceStateKeys.formUnion(read.states.map(\.key))
                // Published before the effects of this pass await, so an action that runs meanwhile never uses the
                // permission of an earlier pass.
                dueStatesIncomplete = incomplete
                dueDecodedKeys = decoded
                return read.states.filter { !restoreRecheckIsPaused($0) }
            }
            let restoring = due().filter {
                $0.needsRemoteRestore && $0.desired == .included && $0.remote != nil
            }
            await performRemote(.remoteRestore, restoring)
            guard !closed else { return }
            await performQueueSync(
                due().filter {
                    $0.needsQueueSync && ($0.desired == .excluded || !$0.needsRemoteRestore)
                }, afterRestoring: Set(restoring.map(\.key)))
            guard !closed else { return }
            await performRemote(
                .remoteTrash,
                due().filter {
                    $0.needsRemoteTrash && $0.desired == .excluded && $0.remote != nil
                })
            guard !closed else { return }
            // A restore can make deferred actions eligible again. Inside the loop, so a request that arrives
            // while an action awaits the network still runs another pass.
            await runDueActions()
            while let (key, retry) = earlierIterator.next() {
                let read = earlierReads[key] ?? .unreadable
                await retryEarlierUpload(key, retry: retry, read: read)
                // Unreadable entries need no network lookup and keep waiting for the next backoff.
                if read != .unreadable {
                    // Every lookup yields to due effects, including a restore requested while it awaited.
                    reconcileAgain = true
                    break
                }
            }
        } while reconcileAgain && !closed
        scheduleReconcileTimer(advanceBackoff: retryLaterTrash)
    }

    /// Startup already loaded the source states. Reuse those keys after the first publication, and re-read each
    /// current decision in the store before writing. Incomplete loads add their repaired rows on a later pass.
    private func queueLaterTrashRecovery() {
        guard !closed else { return }
        // At most one remembered generation per current excluded source. Unknown keys retry independently below;
        // this cache only stops an incomplete load from continually refilling its own startup queue.
        startupLaterTrashGenerations = startupLaterTrashGenerations.filter {
            sourceStates[$0.key]?.desired == .excluded
        }
        for state in sourceStates.values where state.desired == .excluded && state.remoteTrashed {
            guard startupLaterTrashGenerations[state.key] != state.generation else { continue }
            startupLaterTrashGenerations[state.key] = state.generation
            startupLaterTrashKeys.insert(state.key)
        }
        guard laterTrashRecoveryTask == nil, !startupLaterTrashKeys.isEmpty else { return }
        laterTrashRecoveryTask = Task { [weak self] in await self?.recoverLaterTrash() }
    }

    private func recoverLaterTrash() async {
        defer { laterTrashRecoveryTask = nil }
        while !closed, !Task.isCancelled, !startupLaterTrashKeys.isEmpty {
            let keys = Array(startupLaterTrashKeys.prefix(Self.laterTrashBatchSize))
            startupLaterTrashKeys.subtract(keys)
            if resumeLaterTrash(keys) {
                // These keys were just read. Do not retry their failure again in this same recovery pass.
                await reconcile(retryLaterTrash: false)
            }
            await Task.yield()
        }
    }

    @discardableResult
    private func resumeLaterTrash(_ keys: [PendingSourceKey]) -> Bool {
        var needsReconcile = false
        for key in keys {
            switch store.resumeLaterTrash(for: key, at: now()) {
            case .unreadable:
                unreadableLaterTrashKeys.insert(key)
                needsReconcile = true
            case .scheduled:
                unreadableLaterTrashKeys.remove(key)
                needsReconcile = true
            case .unchanged: unreadableLaterTrashKeys.remove(key)
            }
        }
        reloadSourceStatesPublishingHeals(keys)
        return needsReconcile
    }

    private func performQueueSync(
        _ states: [PendingSourceState], afterRestoring restoredKeys: Set<PendingSourceKey>
    ) async {
        let states = states.filter { !effectWriteIsPending($0.key) }
        guard !states.isEmpty else { return }
        let date = now()
        let excluded = states.filter { $0.desired == .excluded }
        for (kind, group) in Dictionary(grouping: excluded, by: \.key.kind) {
            let ok = await effects.removeFromBackup(kind: kind, identifiers: group.map(\.key.identifier))
            guard !closed else { return }
            finish(.queueSync, group, succeeded: ok, at: date)
        }
        // Each kind returns on its own, so a missing or failing adapter of one kind keeps only its own duty. Within
        // a kind each source settles on its own result, so one unreadable file does not hold back the others.
        let included = states.filter { $0.desired == .included && $0.remote == nil }
        for (_, group) in Dictionary(grouping: included, by: \.key.kind) {
            let returned = await effects.returnToBackup(group.map(\.key))
            guard !closed else { return }
            finish(.queueSync, group, at: date) { returned.contains($0.key) }
        }
        for state in states where state.desired == .included && state.remote != nil {
            let previous = restoreRecheckCounts[state.key]
            let count =
                previous?.generation == state.generation && previous?.remote == state.remote
                ? (previous?.count ?? 0) + 1 : 1
            restoreRecheckCounts[state.key] = (state.generation, state.remote, count)
            let delay = restoreRecheckDelays[min(count - 1, restoreRecheckDelays.count - 1)]
            // A late trash gets its first compensation at once and waits a minute after a refused one. A failed
            // read waits on the same schedule as an incomplete compound, so an offline device does not use up its
            // three checks within minutes. After the third check the source waits for a new launch or Restore.
            let compensated = restoredKeys.contains(state.key)
            func retryNotBefore(_ outcome: PendingBackupReturnOutcome) -> Date? {
                guard outcome == .remoteTrashed else { return now().addingTimeInterval(delay) }
                return compensated ? now().addingTimeInterval(60) : nil
            }
            // An edit of the source can replace the restored photo after its upload, also while a read runs: that trash
            // is the replacement, not a late trash, and the newer version is the backup. The journal names the photo
            // before the replacement trashes it, so a read that sees this trash also sees the journal entry.
            let before = await restoredPhotoOutcome(state)
            guard !closed else { return }
            if before == .remoteTrashed, replacedByEdit(state) {
                finishRestoredReturn(state, outcome: .completed, retryNotBefore: nil)
                continue
            }
            if let before, before != .completed {
                finishRestoredReturn(state, outcome: before, retryNotBefore: retryNotBefore(before))
                continue
            }
            let outcomes = await effects.returnToBackup([state])
            guard !closed else { return }
            var outcome = outcomes[state.key] ?? .unreadable
            if case .waiting(let until) = outcome {
                outcome = .waiting(until: max(until, now().addingTimeInterval(delay)))
            }
            if outcome == .completed, let checked = await restoredPhotoOutcome(state) {
                outcome = checked == .remoteTrashed && replacedByEdit(state) ? .completed : checked
            }
            guard !closed else { return }
            finishRestoredReturn(state, outcome: outcome, retryNotBefore: retryNotBefore(outcome))
        }
    }

    /// True when the edit replacement retired the restored photo, or intends to and may have trashed it already.
    private func replacedByEdit(_ state: PendingSourceState) -> Bool {
        guard state.key.kind == .photoLibraryAsset, let remote = state.remote, let replacementJournal else {
            return false
        }
        let entry = replacementJournal.entry(
            for: UploadSourceIdentity(kind: state.key.kind, identifier: state.key.identifier))
        return entry.retired.contains(remote.nodeID) || entry.retireIntent?[remote.nodeID] != nil
    }

    /// With a backend reader, neither an omitted link nor a legacy inferred State can settle a restore.
    /// Other effect implementations must supply their own verified typed outcome.
    private func restoredPhotoOutcome(_ state: PendingSourceState) async -> PendingBackupReturnOutcome? {
        guard let relations, let remote = state.remote else { return nil }
        do {
            let read = try await relations.linkVisibility(of: [remote.nodeID])
            guard let visibility = read[remote.nodeID], visibility.hasExplicitPhotoState else { return .unreadable }
            if visibility.isActiveMain { return .completed }
            return visibility.trashTime != nil ? .remoteTrashed : .unreadable
        } catch { return .unreadable }
    }

    private func finishRestoredReturn(
        _ state: PendingSourceState, outcome: PendingBackupReturnOutcome, retryNotBefore: Date?
    ) {
        guard store.finishRestoreRecheck(state, outcome: outcome, at: now(), retryNotBefore: retryNotBefore) else {
            beginFailedKeys.insert(state.key)
            return
        }
        if restoreRequests[state.key] != nil {
            let current = store.sourceStateRead(for: state.key)
            let stillMatches: Bool
            switch current {
            case .readable(nil): stillMatches = outcome == .completed
            case .readable(let row?): stillMatches = row.generation == state.generation && row.remote == state.remote
            case .unreadable: stillMatches = false
            }
            restoreReturnOutcomes[state.key] = (state.generation, stillMatches ? outcome : .unreadable)
        }
        if outcome == .remoteTrashed { reconcileAgain = true }
        reloadSourceStates([state.key])
        if !unreadableSourceStates.contains(state.key), sourceStates[state.key] == nil {
            restoreRecheckCounts.removeValue(forKey: state.key)
        }
        listsDirty = true
        scheduleMembershipPublish()
    }

    private func performRemote(_ effect: PendingSourceEffect, _ states: [PendingSourceState]) async {
        let states = states.filter { !effectWriteIsPending($0.key) }
        guard !states.isEmpty else { return }
        let date = now()
        let volume = await effects.photosVolumeID()
        guard !closed else { return }
        guard let volume else {
            for state in states { writeEffect(.deferAttempt(generation: state.generation), for: state.key, at: date) }
            reloadSourceStates(states.map(\.key))
            return
        }
        // Marked right before dispatch, and only while the state still wants this effect for the same
        // generation: a decision taken during the volume lookup wins. Until a confirmed completion, new
        // decisions treat the request as possibly done.
        guard let marked = store.beginRemoteOperation(effect, for: states) else {
            beginFailedKeys.formUnion(states.map(\.key))
            return
        }
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
        // A finished trash can leave the trash of a later commit due, see
        // `PendingBackupManifestStore.completeEffectResult`.
        // A source whose state cannot be read now is retried by the backoff timer of `scheduleReconcileTimer`.
        let movedOn = dispatched.contains { dispatchedState in
            // A last known state can be older than the effect; only a fresh read shows that the trash moved on.
            guard !unreadableSourceStates.contains(dispatchedState.key), let state = sourceStates[dispatchedState.key]
            else { return false }
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
                writeEffect(
                    .complete(effect, generation: state.generation, remoteLinkID: state.remote?.nodeID),
                    for: state.key, at: date)
            } else {
                writeEffect(.deferAttempt(generation: state.generation), for: state.key, at: date)
            }
        }
        reloadSourceStates(states.map(\.key))
        listsDirty = true
        scheduleMembershipPublish()
    }

    /// Retries result persistence before reading due work. No remote operation runs here.
    private func retryPendingWrites() {
        beginFailedKeys.removeAll()
        let effects = pendingEffectWrites
        let actionWrites = pendingActionWrites
        for (key, write) in effects { writeEffect(write, for: key, at: now()) }
        for write in actionWrites.values {
            writeAction(write.action, result: write.result, at: now())
        }
        reloadSourceStates(Array(Set(effects.keys).union(actionWrites.keys.map(\.key))))
        if !actionWrites.isEmpty {
            actions = store.actions()
            listsDirty = true
            scheduleMembershipPublish()
        }
    }

    private func writeEffect(_ write: PendingEffectWrite, for key: PendingSourceKey, at date: Date) {
        let saved: Bool
        switch write {
        case .complete(let effect, let generation, let remoteLinkID):
            let result = store.completeEffectResult(
                effect, for: key, generation: generation, remoteLinkID: remoteLinkID, at: date)
            saved = result != .failed
            if result == .laterHandoffUnreadable {
                unreadableLaterTrashKeys.insert(key)
            } else if saved, effect == .remoteTrash {
                unreadableLaterTrashKeys.remove(key)
            }
        case .deferAttempt(let generation):
            saved = store.deferEffects(for: key, at: date, generation: generation)
        }
        if saved {
            pendingEffectWrites.removeValue(forKey: key)
        } else {
            pendingEffectWrites[key] = write
        }
    }

    private func writeAction(_ action: PendingAction, result: PendingEffectResult, at date: Date) {
        let saved: Bool
        switch result {
        case .done: saved = store.completeAction(action)
        case .retry: saved = store.retryAction(action, at: date)
        case .permanentFailure: saved = store.failAction(action)
        }
        let id = PendingActionID(action)
        if saved {
            pendingActionWrites.removeValue(forKey: id)
        } else {
            pendingActionWrites[id] = PendingActionWrite(action: action, result: result)
        }
    }

    private func scheduleReconcileTimer(advanceBackoff: Bool = true) {
        reconcileTimer?.cancel()
        reconcileTimer = nil
        guard !closed else { return }
        let delay: Duration
        if sourceStatesDegraded || actionsDegraded || writesDegraded || !unreadableLaterTrashKeys.isEmpty
            || !earlierUploadRetries.isEmpty
        {
            // An unreadable row or an unsaved result stays due, so its stored date would retry it every second.
            let limit = configuration.unreadableRetryLimit
            let next =
                advanceBackoff
                ? unreadableRetry.map { $0 > limit / 2 ? limit : $0 * 2 } ?? configuration.unreadableRetryDelay
                : unreadableRetry ?? configuration.unreadableRetryDelay
            // At least one second, whatever the configuration says, so a zero or negative limit never spins.
            let backoff = max(.seconds(1), min(next, limit))
            unreadableRetry = backoff
            // Readable sources keep their own retry time; only the unreadable part waits for the backoff.
            if let readable = readableNextEffectDate() {
                delay = min(backoff, .seconds(max(1, readable.timeIntervalSince(now()))))
            } else {
                delay = backoff
            }
        } else {
            unreadableRetry = nil
            let next =
                restoreRecheckCounts.isEmpty ? store.nextEffectDate() : readableNextEffectDate(includingDue: true)
            guard let next else { return }
            delay = .seconds(max(1, next.timeIntervalSince(now())))
        }
        reconcileTimer = Task { [weak self, sleep] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.reconcile(retryEarlierUploads: true)
        }
    }

    /// The next future retry of a readable source with an owed effect, from the last known states.
    /// A source whose result write stayed unsaved keeps its real stored date, so a due source never
    /// spins the timer: only future dates qualify. Keys with a pending effect write are hidden,
    /// because the pending write will replace or remove the cached date. Keys with a pending
    /// action write remain visible: the action row is separate, so the stored date stays meaningful.
    private func readableNextEffectDate(includingDue: Bool = false) -> Date? {
        let current = now()
        let hiddenKeys: Set<PendingSourceKey>
        if includingDue {
            hiddenKeys =
                Set(pendingEffectWrites.keys).union(pendingActionWrites.keys.map(\.key)).union(beginFailedKeys)
        } else {
            hiddenKeys = Set(pendingEffectWrites.keys)
        }
        return sourceStates.values.filter { state in
            !unreadableSourceStates.contains(state.key) && !hiddenKeys.contains(state.key)
                && !restoreRecheckIsPaused(state)
                && (state.needsQueueSync || state.needsRemoteTrash || state.needsRemoteRestore)
                && (includingDue || state.nextAttemptAt > current)
        }.map(\.nextAttemptAt).min()
    }

    private func restoreRecheckIsPaused(_ state: PendingSourceState) -> Bool {
        guard state.desired == .included, state.needsQueueSync,
            let checked = restoreRecheckCounts[state.key], checked.generation == state.generation,
            checked.remote == state.remote
        else { return false }
        return checked.count >= 3
    }

    private static func normalized(_ uid: PhotoUID?, volume: String) -> PhotoUID? {
        uid?.inVolume(volume)
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
        // What the dispatch reads of this call could not read. The scheduling read at the end keeps it, so a good
        // scheduling read never hides a failed dispatch read.
        var dispatchIncomplete = false
        var dispatchUnreadable = Set<PendingSourceKey>()
        repeat {
            actionsAgain = false
            // One read per pass, so the handoffs belong to exactly the actions that run.
            let read = store.dueActionsRead(by: now())
            if !read.complete { dispatchIncomplete = true }
            let handoffs = store.latestHandoffsRead(for: Array(Set(read.actions.map(\.key))))
            dispatchUnreadable.formUnion(handoffs.filter { $0.value == .unreadable }.keys)
            let latest = handoffs.compactMapValues(\.handoff)
            // Actions of sources without a Proton photo wait for their handoff event, not for a timer. An unreadable
            // handoff or an incomplete read is retried through the reconcile backoff, see `scheduleActionTimer`.
            let due = read.actions.filter {
                latest[$0.key] != nil && actionIsEligible($0.key)
                    && pendingActionWrites[PendingActionID($0)] == nil
            }
            guard !due.isEmpty else { break }
            let volume = await effects.photosVolumeID()
            guard !closed else { return }
            guard let volume else {
                for action in due { writeAction(action, result: .retry, at: now()) }
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
                writeAction(action, result: result, at: now())
                if result == .permanentFailure {
                    PhotoDiagnostics.shared.increment("pending.actionFailed")
                }
            }
            // The favorites shown; the next pass reads the owed actions itself.
            actions = store.actions()
            listsDirty = true
            scheduleMembershipPublish()
        } while actionsAgain && !closed
        scheduleActionTimer(dispatchIncomplete: dispatchIncomplete, dispatchUnreadable: dispatchUnreadable)
    }

    /// Wakes for the earliest retry among actions whose Proton photo is known. Actions still waiting for an
    /// upload never pull the timer forward; their handoff event starts them.
    /// Actions wait while the source is excluded or its Proton photo still has to come back from the trash.
    private func actionIsEligible(_ key: PendingSourceKey) -> Bool {
        // An unreadable state is no "not excluded": the action waits for a successful read.
        guard !unreadableSourceStates.contains(key) else { return false }
        // A photo never seen with a pending state can prove its own absence despite another damaged row.
        // Known pending keys keep the inventory guards: a damaged key can also make a keyed read look absent.
        if sourceStatesIncomplete || dueStatesIncomplete,
            sourceStates[key] == nil, !knownSourceStateKeys.contains(key)
        {
            guard store.isOperational() else { return false }
            guard case .readable(nil) = store.sourceStateRead(for: key) else { return false }
            return true
        }
        // An incomplete due read may have left out this source's current state.
        guard !dueStatesIncomplete || dueDecodedKeys.contains(key) else { return false }
        // After an incomplete load, a last known state of a source that this load did not decode may be stale.
        guard !sourceStatesIncomplete || loadDecodedKeys.contains(key) else { return false }
        // A known pending source can disappear from a keyed read when its key no longer decodes. Its absence
        // counts only while no load and no due read of the current states is incomplete.
        guard let state = sourceStates[key] else { return !sourceStatesIncomplete && !dueStatesIncomplete }
        return state.desired == .included && !state.needsRemoteRestore
    }

    private func scheduleActionTimer(
        dispatchIncomplete: Bool = false, dispatchUnreadable: Set<PendingSourceKey> = []
    ) {
        actionTimer?.cancel()
        actionTimer = nil
        guard !closed else { return }
        let read = store.actionsRead()
        let pending = read.actions.filter {
            !$0.failed && pendingActionWrites[PendingActionID($0)] == nil
        }
        let handoffs = store.latestHandoffsRead(for: Array(Set(pending.map(\.key))))
        // A pass is clean only when its dispatch reads and this scheduling read both read everything.
        actionsIncomplete = dispatchIncomplete || !read.complete
        unreadableHandoffKeys = dispatchUnreadable.union(handoffs.filter { $0.value == .unreadable }.keys)
        // Owed actions that cannot be read, or whose Proton photo cannot be read, wait for the reconcile backoff. A
        // reconcile schedules it itself when it ends; a degraded wait that is already set keeps its delay.
        if !reconcileRunning {
            if actionsDegraded || writesDegraded, unreadableRetry == nil {
                scheduleReconcileTimer()
            } else if !actionsDegraded, !sourceStatesDegraded, !writesDegraded, earlierUploadRetries.isEmpty,
                unreadableRetry != nil
            {
                // Every read is clean again outside a reconcile: the episode ends, and a new failure starts over.
                scheduleReconcileTimer()
            }
        }
        guard !pending.isEmpty else { return }
        let withRemote = handoffs.compactMapValues(\.handoff)
        let current = now()
        // While a pass could not read everything, an overdue action that it could not run waits for the backoff;
        // only a future retry time pulls this timer forward.
        guard
            let next = pending.filter({
                withRemote[$0.key] != nil && actionIsEligible($0.key)
                    && (!actionsDegraded || $0.nextAttemptAt > current)
            })
            .map(\.nextAttemptAt).min()
        else { return }
        let seconds = max(1, next.timeIntervalSince(current))
        actionTimer = Task { [weak self, sleep] in
            try? await sleep(.seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.runDueActions()
        }
    }
}
