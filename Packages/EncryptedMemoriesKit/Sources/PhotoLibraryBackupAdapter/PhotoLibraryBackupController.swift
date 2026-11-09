import Foundation
import Observation
import PhotosCore
import UploadCore

#if canImport(Darwin)
    import Darwin
#endif

enum BackupCatalogReplayPolicy {
    enum Action: Equatable {
        case skip
        case markCompleted
        case replay
    }

    static func action(
        state: UploadBackupCatalogReplayState,
        queueCount: Int,
        catalogCount: Int
    ) -> Action {
        if state == .completed { return .skip }
        if state == .inProgress { return catalogCount > 0 ? .replay : .markCompleted }
        if queueCount > 0 || catalogCount == 0 { return .markCompleted }
        return .replay
    }
}

private actor InstantWorkCompletion {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private struct InstantWorkItem: Sendable {
    let task: Task<Void, Never>
    let completion: InstantWorkCompletion
}

private struct StartedBackupRun: Sendable {
    let runID: String
    let task: Task<Void, Never>
}

/// How the scan of a refresh window ended.
public enum BackgroundRefreshScanEnd: Equatable, Sendable {
    /// The scan ran to its end.
    case scanned
    /// Another pass runs, waits to start, or holds the lock; it scans too.
    case notNeeded
    /// The pass of a long background window took the lock over; it scans and uploads.
    case yielded
    /// No scan could start: the local state, the lock, the photo access, a shutdown, or a stop still in progress.
    case couldNotStart
    /// The scan was stopped, for example at the end of the window; the next pass continues from what it saved.
    case stopped
    /// The scan failed.
    case failed
}

/// How a refresh scan ended, kept by the scan's task for its window.
@MainActor
private final class RefreshScanResult {
    var end = BackgroundRefreshScanEnd.stopped
    /// A long background window took the lock over.
    var yielded = false
    /// The scan could not start because another run holds the lock.
    var lockWasBusy = false
}

/// How the pass of a background window ended.
public enum BackgroundCatchUpEnd: Equatable, Sendable {
    /// The pass ran, a pass of the app ran instead, or there was nothing to start.
    case done
    /// The pass waited for the first network path, and the window ended before a path came.
    case noNetworkPath
}

/// Coordinates shared Photo Library backup behavior across Apple platforms.
///
/// Consent contract: backup never enables itself. `enableBackup()` is the only entry point that
/// requests photo access, and it must be called from an explicit user action. Once enabled, the
/// controller may resume interrupted work on launch.
@MainActor
@Observable
public final class PhotoLibraryBackupController {
    public struct Configuration {
        /// Per-account directory holding the backup stores (sign-out purge covers it wholesale).
        public var accountDataDirectory: URL
        public var databasePolicy: LibraryDatabasePolicy

        var makeChangeMonitor: (URL) -> PhotoLibraryChangeMonitor = { PhotoLibraryChangeMonitor(tokenURL: $0) }
        /// The device log of passes and background windows; tests record it.
        var backgroundLog: BackgroundWorkLog = .system
        var currentAccessState: () -> PhotoBackupAccessState = PhotoLibraryAuthorization.currentState
        var changeSleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        /// How often a pass renews its execution lock. The lease lets a crashed owner go after 120 s.
        var heartbeatInterval: TimeInterval = 30
        var bulkResourceResolver: (any BackupResourceResolving)?
        var bulkResourceCoordinator: LibraryResourceCoordinator?

        public var defaults: UserDefaults
        public var runtimeSignals: BackupRuntimeSignalSource
        /// How long a pass waits for the first network path before it starts anyway. The Apple path monitor reports
        /// a first path soon after launch; this bound keeps a missing report from holding the backup silently.
        public var firstNetworkPathWait: Duration

        public init(
            accountDataDirectory: URL,
            databasePolicy: LibraryDatabasePolicy,
            defaults: UserDefaults = .standard,
            runtimeSignals: BackupRuntimeSignalSource = .apple,
            firstNetworkPathWait: Duration = .seconds(10)
        ) {
            self.accountDataDirectory = accountDataDirectory
            self.databasePolicy = databasePolicy
            self.defaults = defaults
            self.runtimeSignals = runtimeSignals
            self.firstNetworkPathWait = firstNetworkPathWait
        }
    }

    private static let enabledDefaultsKey = "photoBackup.enabled.v1"
    private static let userPausedDefaultsKey = "photoBackup.userPaused.v1"
    static let queueDatabaseFileName = "photo-backup-sync-queue-v1.sqlite"
    static let stateDatabaseFileName = "photo-backup-state-v1.sqlite"
    static let catalogDatabaseFileName = "photo-library-catalog-v1.sqlite"
    static let lockDatabaseFileName = "backup-execution-lock-v1.sqlite"

    /// Lease used when reaping abandoned locks before a start; matches the lock store default so a
    /// crashed/expired owner is recoverable while a healthy owner (heartbeat every 30s) never is.
    private static let lockLease: TimeInterval = BackupExecutionLockManifestStore.defaultLeaseInterval
    private static let liveChangeDebounceNanoseconds: UInt64 = 750_000_000
    static let instantWorkRetirementTimeout: Duration = .milliseconds(250)

    public private(set) var accessState: PhotoBackupAccessState
    public private(set) var isEnabled: Bool
    /// Durable user "pause": no passes run and no auto-resume fires until the user resumes. Distinct
    /// from a policy pause (thermal/battery, transient) and from `isEnabled` (the whole feature off).
    public private(set) var isUserPaused: Bool
    public private(set) var status = BackupStatus() {
        didSet {
            let waits = status.phase == .waitingForWiFi
            if waits != isWaitingForWiFi { isWaitingForWiFi = waits }
        }
    }
    /// The backup waits because mobile data is off for backups. Changes only with that state, so observers of the
    /// grid badges do not follow every progress tick.
    public private(set) var isWaitingForWiFi = false
    public private(set) var isSyncing = false {
        didSet {
            guard isSyncing != oldValue else { return }
            for wake in passStateWakes.values { Task { await wake.signal() } }
        }
    }
    /// Open problem lists, woken when a pass starts or ends.
    @ObservationIgnored private var passStateWakes: [UUID: BackupWorkWake] = [:]
    public private(set) var lastMessage: String?
    /// Exact Core-derived eligibility time for the next automatic attempt. Platform schedulers may
    /// request an OS window around this date but never invent their own retry cadence.
    public private(set) var nextAutomaticAttemptAt: Date?
    /// Latest catalog scan tally for diagnostics. It is not upload progress and is not shown in the backup
    /// status row.
    public private(set) var lastCatalogProgress: PhotoLibraryCatalogProgress?
    /// The Proton index that a first scan builds before its first queue row: it lists every photo already in
    /// Proton and decrypts its metadata, which can take minutes. Nil when no such build runs.
    public private(set) var scanIndexPreparation: UploadRemoteIndexPreparationProgress?
    /// Bumps only when durable queue truth records newly uploaded media bytes. UI hosts observe this
    /// to refresh their library immediately; duplicate matches do not cause needless timeline loads.
    public private(set) var uploadedLibraryMutationRevision: UInt64 = 0

    /// False when the dedupe manifest, backup stores, or execution lock could not open - backup
    /// then refuses to run rather than risking duplicate uploads or multiple drainers.
    public var isAvailable: Bool {
        runner != nil
            && lockStore != nil
            && queueStore?.isOperational() == true
            && catalogStore?.isOperational() == true
            && pendingStoreIsReady
    }

    /// Without readable exclusions a photo that the person excluded or deleted could upload.
    private var pendingStoreIsReady: Bool {
        requiresPendingStore ? pendingStore?.isOperational() == true : pendingStore?.isOperational() != false
    }

    /// Identity of the currently active orchestration pass. Platform expiration handlers use this
    /// value to cancel only the run whose ownership they received, never a later replacement run.
    public var activeExecutionRunID: String? { activeRunID }

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    /// Builds the Proton index on behalf of a first scan, so the scan can show its progress.
    private let remoteIndexPreparer: (any UploadIdentityResolving)?
    private var scanIndexFollower: Task<Void, Never>?
    /// Durable runner events for the pending grid. Nil without a pending store.
    public let pendingRecorder: PendingBackupEventRecorder?
    /// The earlier uploads of edited photos, so the pending grid shows an edit in place of its earlier photo.
    public let pendingReplacementJournal: (any EditReplacementJournaling)?
    /// The identity manifest of the edit replacement, so a delete never trashes a photo that another source needs.
    public let pendingIdentities: (any UploadIdentityStore)?
    /// The server lookup of related files, so a delete never trashes a related file that another source needs.
    public let pendingRelations: (any UploadDuplicateChecking)?
    private let pendingStore: PendingBackupManifestStore?
    private let requiresPendingStore: Bool
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private let catalogStore: PhotoLibraryCatalogManifestStore?
    private let lockStore: BackupExecutionLockManifestStore?
    private let statusProjector: BackupStatusProjector?
    private let statusProjectionGeneration = UUID()
    private var statusProjectionRevision: UInt64 = 0
    private var lastAppliedStatusProjectionRevision: UInt64 = 0
    private let tempStore: BackupTempFileStore
    private let bulkResourceResolver: any BackupResourceResolving
    private let bulkResourceCoordinator: LibraryResourceCoordinator
    private var bulkPolicyPaused = false
    private var bulkPreparationMessage: String?
    private var bulkCompletionTask: Task<Void, Never>?
    private var changeSubscription: PhotoLibraryChangeMonitor.Subscription?
    private let monitor: PhotoLibraryChangeMonitor
    private let currentAccessState: () -> PhotoBackupAccessState
    private let changeSleep: @Sendable (UInt64) async throws -> Void
    private let defaults: UserDefaults
    private let runtimeSignals: BackupRuntimeSignalSource
    private let retryPolicy: BackupRetryPolicy
    private var statusSetupTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
    /// Targeted enqueue fired by the change observer while a pass is running. A photo added mid-backup
    /// enters the durable queue and is drained by the current pass.
    private var instantEnqueueTask: Task<Void, Never>?
    /// Every detached catalog sync spawned by `enqueueRecentChangesIntoRunningPass` for the active
    /// pass. The handles remain owned until the pass releases its lock, or until a retained retirement
    /// task joins them after the bounded expiration wait.
    private var instantWorkItems: [InstantWorkItem] = []
    private var instantWorkRetirementTask: Task<Void, Never>?
    private var instantWorkRetirementRunID: String?
    /// Blocks new passes and targeted work while a bounded expiration wait has handed writers to the
    /// retained retirement task. `isSyncing` remains true until that task releases the run lock.
    private var isRetiringInstantWork = false
    private var heartbeatTask: Task<Void, Never>?
    /// One retained runner stop per active run. The handle remains owned until the run has passed
    /// the stop barrier, so repeated expiration and shutdown requests join the same operation.
    private var runnerStopTask: Task<Void, Never>?
    private var runnerStopRunID: String?
    /// Periodically asks the off-main projector for durable queue truth while a pass runs. The task
    /// never reads SQLite itself and hands only an immutable projection back to this main-actor model.
    private var statusRefreshTask: Task<Void, Never>?
    /// One date-driven wake for the earliest eligible queue item. Replaces the old fixed 45-second
    /// poll, which repeatedly started empty runs for draft-blocked rows.
    private var autoResumeTask: Task<Void, Never>?
    /// Follows the shared runtime network signal, so a backup that waits for Wi-Fi resumes on Wi-Fi or Ethernet.
    private var networkObservationTask: Task<Void, Never>?
    /// Tells the pending grid that the catalog took in changes of the photo library, or that the app became active,
    /// so the excluded list shows only photos that still exist. Set by `PendingGridSession`.
    @ObservationIgnored var onLibraryChange: (@MainActor () -> Void)?
    /// The runner ended the current pass waiting for Wi-Fi. Reset when a pass starts.
    private var passWaitedForWiFi = false
    private var passPausedByPolicy = false
    /// A manual Wi-Fi retry stays pending until the resumed pass gets past its policy pause.
    private var manualWiFiRetryPending = false
    /// The active run is a background window's pass that carries the person's pending Wi-Fi retry.
    private var activeRunCarriesManualRetry = false
    /// The owner of a foreground or explicit pass that did not start because no network path had arrived yet. The
    /// first path, the setting, or the end of `firstNetworkPathWait` starts it. An explicit action outranks an
    /// automatic foreground start.
    private var deferredStartOwner: BackupExecutionOwner?
    /// The owner of a deferred background window pass. It runs only inside its window, and only when no foreground or
    /// explicit pass is deferred, because a window must never own or stop such a run.
    private var deferredBackgroundOwner: BackupExecutionOwner?
    /// Background windows that wait for their deferred pass, so that the OS task ends only when that pass ends.
    private var deferredStartWaiters: [UUID: CheckedContinuation<StartedBackupRun?, Never>] = [:]
    /// The admission of each waiting window. It runs while the window's run starts, before the run is reported active,
    /// because a waiting window resumes only later and another callback of the app can run before that.
    private var deferredStartAdmissions: [UUID: @MainActor (String) -> Void] = [:]
    /// Background windows that hold a run they took over. Each wait ends with that run or with its window.
    private var adoptedRunWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The last `startSync` call deferred its pass to the first network path.
    private var lastStartWasDeferred = false
    private let backgroundLog: BackgroundWorkLog
    /// The device log's view of the active run: when it started, its counts then, and when its stop was requested.
    private var runStartedAt = ContinuousClock.now
    /// The counts at the start of the active run; nil before the first status projection, which gives no baseline.
    private var progressAtRunStart: BackupSyncProgress?
    private var hasStatusProjection = false
    private var runnerStopRequestedAt: ContinuousClock.Instant?
    private var lastProgressLogAt: ContinuousClock.Instant?
    /// The queue states that each snapshot counts, also without rows. Other states appear when they have rows.
    nonisolated private static let loggedQueueStates: Set<UploadBackupSyncQueueState> = [
        .discovered, .checking, .hashing, .duplicateChecking, .needsRemoteReconciliation, .queuedForUpload, .uploading,
        .finalizing,
    ]
    /// The result of the active run when it only scans, for a refresh window.
    private var activeRefreshScan: RefreshScanResult?
    private let firstNetworkPathWait: Duration
    private let heartbeatInterval: TimeInterval
    private var firstNetworkPathWaitTask: Task<Void, Never>?
    /// The wait for the first path ended without a path. Passes then run, and uploads still wait for Wi-Fi.
    private var firstNetworkPathWaitEnded = false
    private var consecutiveNoProgressRuns = 0
    private var backedUpAtRunStart = 0
    private var lastObservedUploadedCount: Int?
    private var activeRunID: String?
    /// The owner that started the active run. A background window may take over only an automatic foreground pass.
    private var activeRunOwner: BackupExecutionOwner?
    private var pendingSyncAfterStop = false
    private var isShuttingDown = false
    private var isScanning = false
    /// Previously failed items receive one fresh attempt on the first pass of each app launch.
    /// Permanently invalid items are not retried on every pass.
    private var didAutoRetryFailedThisLaunch = false
    private var lastProjectedProgress = BackupSyncProgress()
    private var executionOpportunityIssue: BackupExecutionOpportunityIssue?
    private let identityResolver: (any UploadIdentityResolving)?
    private var restoredRechecks: [PendingSourceKey: UploadRestoredCompoundContext] = [:]
    private var admittedRestoreRechecks = Set<PendingSourceKey>()

    #if DEBUG
        private var runnerStopOperationForTesting: (@Sendable () async -> Void)?
        /// Replaces the scan and the drain of a started pass. Package tests have no photo library access, and on a
        /// machine without an authorization record a real scan waits for an answer that never comes.
        private var passBodyForTesting: (@Sendable () async -> Void)?
        /// Replaces only the PhotoKit scan of a started pass; the runner still drains the queue.
        private var scanBodyForTesting: (@Sendable () async throws -> Void)?
        /// Replaces the real sleep of the wait for the first network path, so a test decides when the wait ends.
        private var firstNetworkPathSleepForTesting: (@Sendable (Duration) async -> Void)?
        /// Holds the resume at launch until the test releases it, so a test decides whether it comes before a window.
        private var launchResumeGateForTesting: (@Sendable () async -> Void)?
        /// The resume at launch returned.
        internal private(set) var launchResumeEndedForTesting = false
        /// Ended passes whose completion (status projection and the next wake) still runs.
        private var completingSyncRuns = 0
        private var syncRunCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    /// Platform hook: invoked with `true` when a backup pass is actively running (so the host app may
    /// keep the display awake / request background time) and `false` the moment backup goes idle,
    /// paused, or finished. The controller stays UIKit-agnostic; the iOS app injects a closure that
    /// toggles `UIApplication.shared.isIdleTimerDisabled`, macOS leaves the default no-op. Called at
    /// every `isSyncing` transition so the timer never pins the screen after backup ends.
    public var idleTimerHook: ((Bool) -> Void)?

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)? = nil,
        editReplacement: EditedPhotoReplacement? = nil,
        pendingStore: PendingBackupManifestStore? = nil,
        requiresPendingStore: Bool = false,
        replacementJournal: (any EditReplacementJournaling)? = nil
    ) {
        self.identityResolver = identityResolver
        currentAccessState = configuration.currentAccessState
        changeSleep = configuration.changeSleep
        let directory = configuration.accountDataDirectory
        let journal = editReplacement?.journal ?? replacementJournal
        let pendingRecorder = pendingStore.map {
            PendingBackupEventRecorder(
                store: $0, replacementLedger: .shared(accountDataDirectory: directory),
                replacementJournal: journal)
        }
        self.pendingRecorder = pendingRecorder
        pendingReplacementJournal = journal
        pendingIdentities = editReplacement?.identities
        pendingRelations = editReplacement?.relations
        self.pendingStore = pendingStore
        self.requiresPendingStore = requiresPendingStore
        defaults = configuration.defaults
        let runtimeSignals = configuration.runtimeSignals
        self.runtimeSignals = runtimeSignals
        bulkPolicyPaused = BackupThrottlePolicy().maxConcurrentItems(for: runtimeSignals.current()) == 0
        bulkResourceCoordinator = configuration.bulkResourceCoordinator ?? .shared
        firstNetworkPathWait = configuration.firstNetworkPathWait
        backgroundLog = configuration.backgroundLog
        heartbeatInterval = configuration.heartbeatInterval
        let retryPolicy = BackupRetryPolicy()
        self.retryPolicy = retryPolicy
        accessState = currentAccessState()
        isEnabled = configuration.defaults.bool(forKey: Self.enabledDefaultsKey)
        isUserPaused = configuration.defaults.bool(forKey: Self.userPausedDefaultsKey)
        tempStore = BackupTempFileStore(
            directory: directory.appendingPathComponent("photo-backup-temp", isDirectory: true))
        monitor = configuration.makeChangeMonitor(directory.appendingPathComponent("photo-backup-change-token.v1"))

        let queueStore = UploadBackupSyncQueueManifestStore(
            url: directory.appendingPathComponent(Self.queueDatabaseFileName),
            policy: configuration.databasePolicy
        )
        let stateStore = UploadBackupStateManifestStore(
            url: directory.appendingPathComponent(Self.stateDatabaseFileName),
            policy: configuration.databasePolicy
        )
        self.queueStore = queueStore
        self.stateStore = stateStore
        statusProjector = queueStore.map {
            BackupStatusProjector(queue: $0)
        }
        // Catalog + lock are independent of the upload composition: they open even before an
        // identity resolver exists, so inventory/ownership survive a partial account bring-up.
        let catalogStore = PhotoLibraryCatalogManifestStore(
            url: directory.appendingPathComponent(Self.catalogDatabaseFileName),
            policy: configuration.databasePolicy
        )
        self.catalogStore = catalogStore
        bulkResourceResolver =
            configuration.bulkResourceResolver
            ?? PhotoLibraryResourceResolver(
                tempStore: tempStore,
                cloudIdentifierProvider: { catalogStore?.cachedCloudIdentifier(for: $0) })
        lockStore = BackupExecutionLockManifestStore(
            url: directory.appendingPathComponent(Self.lockDatabaseFileName),
            policy: configuration.databasePolicy,
            leaseInterval: Self.lockLease
        )

        remoteIndexPreparer = identityResolver
        if let queueStore, let stateStore, let catalogStore, let identityResolver {
            let preflight = UploadBackupPreflightIndex(store: stateStore)
            engine = UploadBackupSyncEngine(
                preflight: preflight,
                queue: queueStore,
                remoteProofResolver: identityResolver,
                exclusions: pendingStore
            )
            runner = BackupSyncRunner(
                queue: queueStore,
                preflight: preflight,
                resolver: PhotoLibraryResourceResolver(
                    tempStore: tempStore,
                    cloudIdentifierProvider: { catalogStore.cachedCloudIdentifier(for: $0) }
                ),
                identityResolver: identityResolver,
                uploader: uploader,
                tagAdder: tagAdder,
                editReplacement: editReplacement,
                configuration: .init(retry: retryPolicy, leavesOutMissingLivePhotoVideos: true),
                throttleInputs: runtimeSignals.current,
                runtimeChanges: runtimeSignals.updates,
                markSourceUnavailable: { source in
                    guard PhotoLibraryResourceResolver.photosNoLongerLists(source.identifier) else { return false }
                    return catalogStore.recordUnavailableSource(source, at: Date())
                },
                events: pendingRecorder
            )
        } else {
            engine = nil
            runner = nil
        }

        tempStore.sweep()
        if let statusProjector {
            let generation = statusProjectionGeneration
            let initialContext = projectionContext
            statusSetupTask = Task {
                await statusProjector.start(
                    generation: generation,
                    revision: 0,
                    context: initialContext
                ) { @MainActor [weak self] projection in
                    self?.applyStatusProjection(projection)
                }
                if let runner {
                    await runner.setOnProgress { snapshot in
                        statusProjector.submit(snapshot, generation: generation)
                    }
                }
            }
        }
        if isEnabled {
            startObservingChanges()
            Task { @MainActor [weak self] in
                await self?.statusSetupTask?.value
                #if DEBUG
                    if let gate = self?.launchResumeGateForTesting { await gate() }
                #endif
                self?.resumeEnabledBackupAfterLaunch()
                #if DEBUG
                    self?.launchResumeEndedForTesting = true
                #endif
            }
        } else {
            reportNoIndexBuild()
        }
        startObservingNetwork()
    }

    // MARK: - Pending grid

    /// The backup queue as the pending grid observes it.
    public var pendingQueue: (any UploadBackupSyncQueueObserving)? { queueStore }

    /// Pending-tile metadata from the catalog.
    public var pendingMetadataProvider: PhotoLibraryPendingMetadataProvider? {
        catalogStore.map(PhotoLibraryPendingMetadataProvider.init(catalog:))
    }

    /// Removes excluded photos from queued and in-flight work, like a deletion in Apple Photos.
    public func removeFromBackup(identifiers: [String]) async -> Bool {
        guard let runner, queueStore?.isOperational() == true else { return false }
        for identifier in identifiers {
            let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: identifier)
            if let context = restoredRechecks.removeValue(forKey: key) {
                await identityResolver?.endRestoredCompound(context)
            }
            admittedRestoreRechecks.remove(key)
        }
        _ = await runner.removeSources(kind: .photoLibraryAsset, identifiers: identifiers)
        return queueStore?.holdsNoRows(kind: .photoLibraryAsset, identifiers: identifiers) == true
    }

    /// Enqueues restored photos again from the catalog, without PhotoKit, and starts a pass when backup
    /// is on. Photos no longer in the library need nothing and count as done.
    public func returnToBackup(identifiers: [String]) async -> Bool {
        guard let engine, let catalogStore, catalogStore.isOperational() else { return false }
        guard let entries = catalogStore.presentEntries(for: identifiers) else { return false }
        let candidates = entries.values.compactMap {
            PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: $0))
        }
        guard catalogStore.isOperational() else { return false }
        // The restore is the person's answer for an edit whose earlier upload a delete moved to the trash. When
        // that upload left the trash for good, the edit must not ask whether the photo was deleted elsewhere.
        // Without the record the person is asked; the restore still succeeds.
        if let journal = pendingReplacementJournal {
            for candidate in candidates
            where !journal.entry(for: candidate.snapshot.source).allSuperseded.isEmpty {
                try? journal.backUpAgain(revision: candidate.snapshot.revision, for: candidate.snapshot.source)
            }
        }
        // A delete moved the Proton photo of a restored source to the trash, which the person can empty. The
        // duplicate check verifies the photo again instead of trusting the backup state from before the delete.
        for candidate in candidates
        where stateStore?.removeRecords(for: candidate.snapshot.source, keeping: []) != true {
            return false
        }
        do {
            _ = try await engine.enqueueBatch(candidates)
        } catch {
            return false
        }
        refreshFromQueue()
        if isEnabled, !isUserPaused, !candidates.isEmpty { syncNow() }
        return true
    }

    /// Reconstructs a restore recheck from the pending store. Enqueue success alone never acknowledges it.
    public func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
        var outcomes: [PendingSourceKey: PendingBackupReturnOutcome] = [:]
        for state in states {
            outcomes[state.key] = .unreadable
            guard !isShuttingDown, let engine, let identityResolver, let pendingStore, let catalogStore,
                let queueStore, pendingStore.isOperational(), catalogStore.isOperational(), queueStore.isOperational(),
                state.key.kind == .photoLibraryAsset, let remote = state.remote
            else { continue }
            guard !isSyncing, !isRetiringInstantWork else {
                outcomes[state.key] = .waiting(until: Date().addingTimeInterval(30))
                continue
            }
            guard let entry = (catalogStore.presentEntries(for: [state.key.identifier]) ?? [:])[state.key.identifier],
                let candidate = PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry)),
                let plan = PhotoBackupAssetPlanner.exportPlan(for: PhotoLibraryCatalogMapper.info(for: entry)),
                catalogStore.isOperational()
            else { continue }
            let context = UploadRestoredCompoundContext(
                source: candidate.snapshot.source, revision: candidate.snapshot.revision,
                generation: state.generation, confirmedRemote: remote,
                requiredMembers: plan.secondaries.map(\.sourceResource))
            // Nil when a read failed: unknown is neither current nor stale (#1004).
            let currentRead: @Sendable () -> Bool? = {
                guard pendingStore.isOperational(), catalogStore.isOperational() else { return nil }
                guard case .readable(let read) = pendingStore.sourceStateRead(for: state.key) else { return nil }
                guard let current = read, current.desired == .included, current.needsQueueSync,
                    current.generation == state.generation, current.remote == remote
                else { return false }
                let presence = catalogStore.presence(for: [state.key.identifier])
                guard !presence.unknown.contains(state.key.identifier) else { return nil }
                guard let latest = presence.present[state.key.identifier],
                    let latestCandidate = PhotoBackupAssetPlanner.candidate(
                        for: PhotoLibraryCatalogMapper.info(for: latest))
                else { return false }
                return latestCandidate.snapshot == candidate.snapshot
            }
            let isCurrent: @Sendable () -> Bool = { currentRead() == true }
            switch currentRead() {
            case true?: break
            case false?:
                // A certified stale check ends the context it registered, so it cannot hold back a later version.
                if let stale = restoredRechecks[state.key], stale.generation == state.generation {
                    restoredRechecks.removeValue(forKey: state.key)
                    admittedRestoreRechecks.remove(state.key)
                    await identityResolver.endRestoredCompound(stale)
                }
                continue
            case nil:
                // An unknown read keeps the registered check; the durable duty asks again.
                continue
            }
            do {
                try await identityResolver.prepareRestoredCompound(context, isCurrent: isCurrent)
                if restoredRechecks[state.key] != context { admittedRestoreRechecks.remove(state.key) }
                restoredRechecks[state.key] = context
                guard !isShuttingDown, isCurrent() else { continue }
                let remoteOutcome = try await identityResolver.restoredPhotoOutcome(context)
                guard !isShuttingDown, isCurrent() else { continue }
                guard remoteOutcome == .completed else {
                    outcomes[state.key] = remoteOutcome
                    continue
                }
                let row = try queueStore.entry(for: context.source, revision: context.revision)
                guard queueStore.isOperational() else { continue }
                if admittedRestoreRechecks.contains(state.key), let row, row.state.isTerminalSuccess,
                    row.remoteCommitReconciliation == nil
                {
                    outcomes[state.key] = .completed
                    restoredRechecks.removeValue(forKey: state.key)
                    admittedRestoreRechecks.remove(state.key)
                    await identityResolver.endRestoredCompound(context)
                    continue
                }
                guard !isSyncing, !isRetiringInstantWork else {
                    outcomes[state.key] = .waiting(until: Date().addingTimeInterval(30))
                    continue
                }
                if let deferral = await Self.restoredCompoundDeferral(
                    engine: engine, candidate: candidate, isCurrent: isCurrent)
                {
                    outcomes[state.key] = deferral
                    continue
                }
                guard !isShuttingDown, isCurrent() else { continue }
                _ = try await engine.enqueueBatch([candidate])
                guard !isShuttingDown, isCurrent() else { continue }
                restoredRechecks[state.key] = context
                admittedRestoreRechecks.insert(state.key)
                outcomes[state.key] = .waiting(until: Date().addingTimeInterval(30))
                refreshFromQueue()
                if isEnabled, !isUserPaused { syncNow() }
            } catch {
                outcomes[state.key] = .unreadable
            }
        }
        return outcomes
    }

    /// Nil admits the recheck. A failure remains distinct from temporarily owned work.
    internal static func restoredCompoundDeferral(
        engine: UploadBackupSyncEngine, candidate: UploadBackupAssetCandidate,
        isCurrent: @Sendable () -> Bool
    ) async -> PendingBackupReturnOutcome? {
        do {
            guard try await engine.reopenRestoredCompound(candidate, isCurrent: isCurrent) else {
                return .waiting(until: Date().addingTimeInterval(30))
            }
            return nil
        } catch {
            return .unreadable
        }
    }

    // MARK: - Enable / disable (explicit consent only)

    /// Requests read-write photo access and, when granted (full OR limited), turns backup on and
    /// starts the first pass. Call only from an explicit user action - the UI must explain what
    /// will happen before invoking this.
    public func enableBackup() async {
        accessState = await PhotoLibraryAuthorization.request()
        guard accessState.allowsBackup else { return }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        startObservingChanges()
        // Re-enabling is an explicit user action. Give failed items a fresh start.
        queueStore?.requeueFailed(updatedAt: Date())
        refreshFromQueue()
        if isSyncing {
            pendingSyncAfterStop = true
            stopSync()
            return
        }
        await retryFailedAndSync()
    }

    public func disableBackup() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        isUserPaused = false
        defaults.set(false, forKey: Self.userPausedDefaultsKey)
        pendingSyncAfterStop = false
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        changeSubscription?.cancel()
        changeSubscription = nil
        stopSync()
        if !isSyncing {
            refreshFromQueue()
        }
        reportNoIndexBuild()
    }

    /// Backup is off, so no backup pass prepares the remote index until the person turns it on again.
    private func reportNoIndexBuild() {
        guard let identityResolver else { return }
        Task { await identityResolver.remoteIndexPreparationNotNeeded() }
    }

    public func refreshAccessState() {
        accessState = currentAccessState()
    }

    // MARK: - Sync lifecycle

    /// Ordinary foreground pass. Explicit "Back up now" actions use `retryFailedAndSync()` so they alone make
    /// waiting rows due at once (each reason and its retry count stay); lifecycle/change-driven calls honor backoff.
    public func syncNow() {
        _ = startSync(owner: .foreground)
    }

    /// The "Use Cellular Data" setting changed. A backup that waits for Wi-Fi starts again when the wait no longer
    /// holds; the setting itself persists in the shared defaults that every upload path reads.
    public func mobileDataSettingDidChange() {
        startAfterFirstNetworkPath()
        resumeIfWiFiWaitEnded()
    }

    /// Runs a pass when the app becomes active. An edit in Photos while this app was in the background may reach
    /// the app without a change notification; the pass reads the persistent change history since its last run.
    public func applicationDidBecomeActive() {
        onLibraryChange?()
        guard isEnabled, !isUserPaused, !isSyncing else { return }
        syncNow()
    }

    /// Durable user pause: stop the current pass AND suppress every automatic (re)start until the user
    /// resumes. Persisted so it survives relaunch. This is what the Pause button does; unlike a bare
    /// `stopSync()`, a change notification or the auto-resume can't quietly restart behind the user.
    public func pauseBackup() {
        guard !isUserPaused else { return }
        isUserPaused = true
        defaults.set(true, forKey: Self.userPausedDefaultsKey)
        pendingSyncAfterStop = false
        stopSync()
        if !isSyncing { refreshFromQueue() }  // reflect "Pausiert" immediately
    }

    /// Clears the durable pause and immediately resumes every retryable row.
    public func resumeBackup() async {
        guard isUserPaused else { return }
        isUserPaused = false
        defaults.set(false, forKey: Self.userPausedDefaultsKey)
        await retryFailedAndSync()
    }

    /// Manual "back up now": make failed, draft-blocked, and future-backoff work due immediately,
    /// invalidate the short-lived remote dedupe view, then run. Automatic passes keep their durable
    /// dates; only explicit user intent bypasses the wait, and all duplicate safety remains intact.
    public func retryFailedAndSync() async {
        if let runner {
            _ = await runner.makeRetryableWorkEligibleNow()
        } else {
            _ = queueStore?.makeRetryableWorkEligible(updatedAt: Date())
            _ = queueStore?.setRuntimeIssue(nil, for: .remoteIndexPreparation)
        }
        refreshFromQueue()
        if !isSyncing { _ = startSync(owner: .manual) }
    }

    /// Every item still preventing a complete backup. Proven remote deletions are intentionally absent:
    /// they are successful policy outcomes reported as aggregate information, not failed work.
    public func failedItems(limit: Int = 200) -> [BackupFailedItem] {
        guard let queueStore else { return [] }
        return Self.problemItems(in: queueStore, limit: limit)
    }

    /// The same list, read off the main actor: an offline pass gives every photo of a large library a reason, and
    /// the list must still find the photos the person can fix behind all of them.
    public func problemItems(limit: Int = 200) async -> [BackupFailedItem] {
        guard let queueStore else { return [] }
        return await Task.detached(priority: .utility) { Self.problemItems(in: queueStore, limit: limit) }.value
    }

    /// One complete metadata read for the native paged sheets, with the existing empty-list re-reads.
    public func problemSnapshot(
        clock: any BackupSchedulerClock = BackupContinuousClock()
    ) async -> BackupProblemSnapshot? {
        guard let queueStore else { return nil }
        var latest: BackupProblemSnapshot?
        var accepted: BackupProblemSnapshot?
        await readProblemList(
            using: {
                latest = await Task.detached(priority: .utility) {
                    BackupProblemSnapshot.backup(in: queueStore)
                }.value
                return latest?.rows.map(\.item) ?? []
            }, expectingItems: { summaryCountsProblemItems }, clock: clock,
            { _ in accepted = latest }, { accepted = nil })
        return accepted
    }

    public func makeProblemListSession() -> BackupProblemListSession {
        BackupProblemListSession(
            fixedActionMessage: { [weak self] in self?.bulkPreparationMessage },
            read: { [weak self] in await self?.problemSnapshot() })
    }

    public func followProblemList(session: BackupProblemListSession) async {
        await followProblemListChanges(coalescing: 0, clock: BackupContinuousClock()) {
            session.requestRefresh()
            await session.waitUntilIdle()
        }
    }

    private nonisolated static func problemItems(
        in queueStore: UploadBackupSyncQueueManifestStore, limit: Int
    ) -> [BackupFailedItem] {
        guard limit > 0 else { return [] }
        // Photos the person can fix come first, so many rows of other kinds never push them out of the list.
        let order: [BackupIssueCategory] = [.userResolvable, .decision, .automatic, .permanent]
        var items: [BackupIssueCategory: [BackupFailedItem]] = [:]
        queueStore.forEachProblemEntry { entry in
            let item = BackupFailedItem(entry: entry)
            if items[item.category, default: []].count < limit { items[item.category, default: []].append(item) }
            return items[.userResolvable, default: []].count < limit
        }
        return Array(order.flatMap { items[$0] ?? [] }.prefix(limit))
    }

    /// Gives `apply` the problem list now and, while a pass runs, again after each committed queue write: a photo
    /// can get another reason during a pass without changing a count. The first write after a quiet moment shows at
    /// once; further writes within `coalescing` seconds are read together after it. The end of the pass reads once
    /// more and stops. A read that comes back empty while the summary counts items is read again a bounded number of
    /// times; when it stays empty, `ifUnavailable` reports it.
    public func followProblemList(
        order: BackupProblemListReadOrder? = nil, limit: Int = 200, coalescing: TimeInterval = 1,
        clock: any BackupSchedulerClock = BackupContinuousClock(),
        _ apply: ([BackupFailedItem]) -> Void, ifUnavailable: () -> Void = {}
    ) async {
        let order = order ?? BackupProblemListReadOrder()
        await followProblemListChanges(coalescing: coalescing, clock: clock) {
            await readProblemList(order: order, limit: limit, clock: clock, apply, ifUnavailable: ifUnavailable)
        }
    }

    private func followProblemListChanges(
        coalescing: TimeInterval, clock: any BackupSchedulerClock, read: () async -> Void
    ) async {
        // Subscribe before the first read, so a write or the end of the pass during that read is not lost.
        let wake = BackupWorkWake()
        let follower = queueStore.map { wake.follow($0.changes()) }
        let id = UUID()
        passStateWakes[id] = wake
        defer {
            follower?.cancel()
            passStateWakes[id] = nil
        }
        var passEnded = !isSyncing
        await read()
        // A pass that started during the read is followed as well; its start already woke this list.
        while !passEnded || isSyncing {
            await wake.wait(clock: clock)
            guard !Task.isCancelled else { return }
            // A pass that ended before this read, also during the pause or the previous read, gets this last read.
            passEnded = !isSyncing
            await read()
            if !passEnded { try? await clock.sleep(for: coalescing) }
        }
    }

    /// The waits before each re-read of a list that came back empty while the summary counts items. A read can miss
    /// rows for a moment; after these re-reads the list is reported as unavailable instead.
    static let problemListRereadDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4]

    /// Reads the list and applies it. While the list is empty and the summary counts items that need attention, it
    /// reads again after each wait of `problemListRereadDelays`, so one empty read never decides what the sheet
    /// shows. A cancelled read applies nothing and reports nothing: the task that starts it again reads anew.
    /// A read that a newer read of the same open list overtakes (`order` is the one of that list) ends without
    /// applying or reporting: the newer read decides. After a decision on `item`, the first read leaves that photo out until the next read, so the resolved decision
    /// disappears at once; the re-reads show it again if it failed with another reason.
    public func readProblemList(
        order: BackupProblemListReadOrder? = nil, afterDecision item: BackupFailedItem? = nil, limit: Int = 200,
        clock: any BackupSchedulerClock = BackupContinuousClock(),
        _ apply: ([BackupFailedItem]) -> Void, ifUnavailable: () -> Void = {}
    ) async {
        await readProblemList(
            using: { await problemItems(limit: limit) }, order: order, afterDecision: item,
            expectingItems: { summaryCountsProblemItems }, clock: clock, apply, ifUnavailable)
    }

    /// Whether the summary counts photos that need attention, so the list must show some.
    private var summaryCountsProblemItems: Bool {
        #if DEBUG
            if let override = problemListExpectationForTesting { return override() }
        #endif
        return status.needsAttentionCount > 0
    }

    func readProblemList(
        using read: () async -> [BackupFailedItem], order: BackupProblemListReadOrder? = nil,
        afterDecision item: BackupFailedItem? = nil, expectingItems: () -> Bool, clock: any BackupSchedulerClock,
        _ apply: ([BackupFailedItem]) -> Void, _ ifUnavailable: () -> Void
    ) async {
        let order = order ?? BackupProblemListReadOrder()
        let generation = order.begin()
        var hiddenDecision = item
        var rereads = 0
        while let items = await applyCurrentProblemList(
            order: order, generation: generation,
            {
                let items = await read()
                defer { hiddenDecision = nil }
                guard let decided = hiddenDecision else { return items }
                return items.filter { $0.id != decided.id || $0.issue == .deletedElsewhere }
            }, apply)
        {
            guard items.isEmpty, expectingItems() else { return }
            guard rereads < Self.problemListRereadDelays.count else {
                ifUnavailable()
                return
            }
            try? await clock.sleep(for: Self.problemListRereadDelays[rereads])
            rereads += 1
        }
    }

    /// The files that upload now and the files that wait, read off the main actor.
    public func queueList(limit: Int = 200) async -> BackupQueueList {
        guard let queueStore else { return .empty }
        return await Task.detached(priority: .utility) {
            BackupQueueList(rows: queueStore.queueWorkRows(), limit: limit)
        }.value
    }

    /// Gives `apply` the queue now and, while a pass runs, again after each `interval`, so an open queue follows
    /// the files as they upload.
    public func followQueueList(
        limit: Int = 200, interval: Duration = .seconds(2), _ apply: (BackupQueueList) -> Void
    ) async {
        let list = await queueList(limit: limit)
        guard !Task.isCancelled else { return }
        apply(list)
        while isSyncing {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            let list = await queueList(limit: limit)
            guard !Task.isCancelled else { return }
            apply(list)
        }
    }

    /// Counts the person's actions on the problem list, so a read that an action overtakes is not shown.
    private(set) var problemListChanges: UInt64 = 0

    /// A read that started before the person's action would bring a dismissed row back, so the list reads again.
    /// Returns the list that it applied, or nil when the read was cancelled, overtaken by a newer read, or the
    /// controller shut down.
    @discardableResult
    func applyCurrentProblemList(
        order: BackupProblemListReadOrder, generation: UInt64, _ read: () async -> [BackupFailedItem],
        _ apply: ([BackupFailedItem]) -> Void
    ) async -> [BackupFailedItem]? {
        while !Task.isCancelled, !isShuttingDown, order.isLatest(generation) {
            let changes = problemListChanges
            let items = await read()
            guard !Task.isCancelled, !isShuttingDown, order.isLatest(generation) else { return nil }
            if changes == problemListChanges {
                apply(items)
                return items
            }
        }
        return nil
    }

    func noteProblemListChange() {
        problemListChanges &+= 1
    }

    /// Every row the person can resolve, independent of how many rows the list shows. Throws when the list could not
    /// be read completely: a cut-short list would leave the missing rows parked (#1004 B2).
    private func userResolvableEntries(
        in queueStore: UploadBackupSyncQueueManifestStore
    ) throws
        -> [UploadBackupSyncQueueEntry]
    {
        var entries: [UploadBackupSyncQueueEntry] = []
        try queueStore.decisionForEachProblemEntry { entry in
            if BackupFailedItem(entry: entry).category == .userResolvable { entries.append(entry) }
            return true
        }
        return entries
    }

    /// Hides the warning of a permanent item, or of a failed item that waits for the person's retry, without ever
    /// changing the backup-success count. A hidden failed item is not retried.
    public func dismissFailedItem(_ item: BackupFailedItem) {
        guard item.isDismissible, item.issue != .deletedElsewhere,
            let source = item.source,
            let revision = item.revision, let queueStore,
            let current = try? queueStore.entry(for: source, revision: revision),
            BackupIssueRecord.decode(current.lastError)?.kind != .deletedElsewhere,
            // A failed row that Try again reopened meanwhile backs up again and stays.
            item.isPermanent || current.state == .failed,
            queueStore.dismissPermanentFailure(
                source: source,
                revision: revision,
                updatedAt: Date()
            ) == true
        else { return }
        noteProblemListChange()
        refreshFromQueue()
    }

    public let bulkPhotoActions = BulkPhotoActionRunner()
    public var isBulkBackUpAgainAvailable: Bool { !isShuttingDown && !bulkPolicyPaused }

    private var bulkReadPolicyAllowsWork: Bool {
        BackupThrottlePolicy().maxConcurrentItems(for: runtimeSignals.current()) > 0
    }

    public func prepareBackUpAgain() async -> BulkPhotoActionRunner.Confirmation? {
        guard !isShuttingDown, bulkCompletionTask == nil, let queueStore else { return nil }
        bulkPreparationMessage = nil
        let confirmation = await bulkPhotoActions.prepareBackUpAgain(in: queueStore)
        if confirmation == nil, !Task.isCancelled, !isShuttingDown, !queueStore.isOperational() {
            bulkPreparationMessage = L10n.string("backup.error_local_state_unavailable")
        }
        return confirmation
    }

    @discardableResult
    public func startBackUpAgain(_ confirmation: BulkPhotoActionRunner.Confirmation) -> Bool {
        guard !isShuttingDown, bulkCompletionTask == nil, confirmation.action == .backUpAgain else { return false }
        guard bulkReadPolicyAllowsWork else {
            if bulkPhotoActions.confirmation == confirmation { bulkPhotoActions.dismissConfirmation() }
            return false
        }
        guard
            bulkPhotoActions.start(
                confirmation,
                perform: { [weak self] item in
                    guard let self, let source = item.source,
                        let revisions = confirmation.revisionsBySource[source]
                    else { return false }
                    return await backUpAgainIfAvailable(item, revisions: revisions)
                })
        else { return false }
        bulkCompletionTask = Task { [weak self, bulkPhotoActions] in
            await bulkPhotoActions.waitUntilFinished()
            guard let self else { return }
            bulkCompletionTask = nil
            guard !Task.isCancelled, !isShuttingDown,
                (bulkPhotoActions.summary?.completed ?? 0) > 0
            else { return }
            syncNow()
        }
        return true
    }

    /// A failed source read leaves the original decision and its reason intact. Resolving reads photo resources;
    /// the existing decision helper writes consent only after the exact confirmed version is still readable.
    private func backUpAgainIfAvailable(
        _ item: BackupFailedItem, revisions: Set<UploadBackupRevision>
    ) async -> Bool {
        guard !isShuttingDown, !Task.isCancelled, currentAccessState().allowsBackup,
            item.issue == .deletedElsewhere, let source = item.source, let revision = item.revision,
            source.kind == .photoLibraryAsset, source.resource == .primary,
            pendingReplacementJournal != nil, let queueStore, queueStore.isOperational(),
            let entry = try? queueStore.entry(for: source, revision: revision), entry.state == .failedPermanent,
            BackupIssueRecord.decode(entry.lastError)?.kind == .deletedElsewhere
        else { return false }
        do {
            let inputs = runtimeSignals.current
            let policy = BackupThrottlePolicy()
            let admission: BackupResourceReadAdmission = {
                try Task.checkCancellation()
                guard policy.maxConcurrentItems(for: inputs()) > 0 else { throw BulkSourceReadDeferred() }
            }
            let resolver = bulkResourceResolver
            let resolved = try await bulkResourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .backupMaterialization, intent: .userInitiated, memoryClass: .large)
            ) { _ in
                try admission()
                return try await resolver.resolve(entry, onPreparationProgress: { _ in }, readAdmission: admission)
            }
            guard let resource = resolved else { return false }
            defer { resource.cleanup?() }
            guard !isShuttingDown, !Task.isCancelled, currentAccessState().allowsBackup,
                resource.candidate.snapshot.source == source, resource.candidate.snapshot.revision == revision
            else { return false }
            return resolveRemoteDeletion(item, keepDeleted: false, expectedRevisions: revisions)
        } catch is BulkSourceReadDeferred {
            bulkPhotoActions.stopAfterCurrentPhoto()
            return false
        } catch {
            // The summary reports this photo as unchanged; its existing decision remains available.
            return false
        }
    }

    private struct BulkSourceReadDeferred: Error {}

    @discardableResult
    public func keepDeleted(_ item: BackupFailedItem) -> Bool {
        resolveRemoteDeletion(item, keepDeleted: true)
    }

    @discardableResult
    public func backUpAgain(_ item: BackupFailedItem) -> Bool {
        PhotoPerformanceSignposts.database.interval("BackupBackUpAgain") {
            guard resolveRemoteDeletion(item, keepDeleted: false) else { return false }
            syncNow()
            return true
        }
    }

    @discardableResult
    private func resolveRemoteDeletion(
        _ item: BackupFailedItem, keepDeleted: Bool, expectedRevisions: Set<UploadBackupRevision>? = nil
    ) -> Bool {
        guard item.issue == .deletedElsewhere, let source = item.source, let revision = item.revision,
            let queueStore, let journal = pendingReplacementJournal,
            let row = PhotoPerformanceSignposts.database.interval(
                "BackupDecisionEntry",
                {
                    (try? queueStore.entry(for: source, revision: revision))
                }), row.state == .failedPermanent,
            BackupIssueRecord.decode(row.lastError)?.kind == .deletedElsewhere
        else { return false }
        // The choice is about the photo, so it settles every revision of it that waits for the same question.
        do {
            let parked = try PhotoPerformanceSignposts.database.interval("BackupDecisionRows") {
                try queueStore.decisionRows(kind: source.kind, identifiers: [source.identifier]).filter {
                    guard $0.source == source, $0.state == .failedPermanent else { return false }
                    return BackupIssueRecord.decode(
                        (try queueStore.entry(for: source, revision: $0.revision))?.lastError)?
                        .kind == .deletedElsewhere
                }.map(\.revision)
            }
            let newest = parked.max() ?? revision
            if let expectedRevisions {
                guard queueStore.isOperational(), Set(parked) == expectedRevisions, newest == revision else {
                    return false
                }
            }
            // The journal is a file, so it cannot share the queue transaction. It takes the choice first: a reopened
            // revision without it would only wait for the question again. A failed queue write takes it back while
            // the journal still holds it.
            let previousChoice = journal.entry(for: source).deletionChoice
            let writtenChoice: EditReplacementDeletionChoice = keepDeleted ? .keptDeleted : .backUpAgain(newest)
            try PhotoPerformanceSignposts.database.interval("BackupDecisionJournal") {
                if keepDeleted {
                    try journal.keepDeleted(for: source)
                } else {
                    try journal.backUpAgain(revision: newest, for: source)
                }
            }
            let lastError =
                keepDeleted
                ? BackupIssueRecord(
                    kind: .remoteDeletion, detail: L10n.string("backup.state_skipped_remote_deletion")
                ).persistedValue : nil
            let updates = Set(parked + [revision]).sorted().map { parkedRevision in
                let reopens = !keepDeleted && parkedRevision == newest
                return UploadBackupSyncQueueManifestStore.StateUpdate(
                    revision: parkedRevision,
                    state: keepDeleted ? .skippedRemoteDeletion : reopens ? .discovered : .dismissedFailure,
                    lastError: lastError)
            }
            // All revisions change together, or none does: a photo reported as unchanged has no reopened revision.
            guard
                PhotoPerformanceSignposts.database.interval(
                    "BackupDecisionQueueWrite",
                    { queueStore.updateStates(of: source, updates, updatedAt: Date()) })
            else {
                do {
                    try journal.restoreDeletionChoice(previousChoice, ifStill: writtenChoice, for: source)
                } catch {
                    backgroundLog.notice(
                        .photoBackup, "decision.choiceNotRestored",
                        [(.init("choice"), .word(keepDeleted ? "keepDeleted" : "backUpAgain"))])
                }
                throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
            }
            SupportEventTrail.shared.record(
                keepDeleted ? .backupDeletionKept : .backupDeletionReopened, subject: source.identifier)
            noteProblemListChange()
            refreshFromQueue()
            return true
        } catch {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            refreshFromQueue()
            return false
        }
    }

    /// Re-dates only rows the person can resolve. Automatic backoff and every reason stay intact.
    public func retryUserResolvableWork() async {
        guard let queueStore else { return }
        let now = Date()
        let entries: [UploadBackupSyncQueueEntry]
        do {
            entries = try userResolvableEntries(in: queueStore)
        } catch {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            refreshFromQueue()
            return
        }
        // A reopen that fails records a failure, but the health probe below forgets a transient one once the database
        // answers again. Compare the recorded failures too, so a row that was not reopened never looks retried (#1228).
        let failuresBeforeReopen = queueStore.recordedFailureCount()
        for entry in entries {
            // A row that the runner claimed or changed meanwhile keeps its new state.
            _ = queueStore.reopenForUserRetry(
                entry, attempts: entry.state == .failed ? 0 : entry.attempts, updatedAt: now)
        }
        noteProblemListChange()
        guard queueStore.recordedFailureCount() == failuresBeforeReopen, queueStore.isOperational() else {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            refreshFromQueue()
            return
        }
        await runner?.invalidateRemoteStateForUserRetry()
        refreshFromQueue()
        if !isSyncing { _ = startSync(owner: .manual) }
    }

    /// Platform adapters report whether an OS background opportunity was accepted. This changes only
    /// presentation truth; queue execution and retry semantics remain entirely shared.
    public func setExecutionOpportunityIssue(_ issue: BackupExecutionOpportunityIssue?) {
        guard executionOpportunityIssue != issue else { return }
        executionOpportunityIssue = issue
        refreshFromQueue()
    }

    /// Runs one catch-up pass for an OS background window.
    /// `onRunStarted` receives the run ID for expiration-safe cancellation.
    /// `onRunAdmitted` receives the run ID of the window's own pass, also one that waited for the first network path,
    /// synchronously while that run starts and before `idleTimerHook` reports it; it must only record state.
    /// `onRunStarted` follows, for a waiting window when its wait resumes.
    /// A window that took over a pass can run a second pass of its own afterwards, for the person's pending retry: both
    /// callbacks then fire again with the new run ID, and the window holds that run from then on.
    /// Checkpointed state lets the next pass resume unfinished work.
    @discardableResult
    public func backgroundCatchUp(
        owner: BackupExecutionOwner = .background,
        onRunStarted: (@MainActor (String) -> Void)? = nil,
        onRunAdmitted: (@MainActor (String) -> Void)? = nil
    ) async -> BackgroundCatchUpEnd {
        if let refreshScan = activeRefreshScan, let scan = syncTask {
            // A refresh scan holds the lock, and this window needs it to upload: the scan yields and this pass scans.
            refreshScan.yielded = true
            stopCurrentSync()
            await scan.value
            // The window may have expired while the scan ended; then it starts no pass.
            guard !Task.isCancelled else { return .done }
        }
        if runnerStopTask != nil, let stopping = syncTask, let stoppingRunID = activeRunID,
            runtimeSignals.current().isAppInBackground
        {
            // A stop already ends the active pass, for example at the end of its short grace before iOS suspended the
            // app. The window does not take that pass over: it waits for its end, or for its own expiry, and then
            // runs its own pass.
            await waitForAdoptedRun(StartedBackupRun(runID: stoppingRunID, task: stopping))
            guard !Task.isCancelled else { return .done }
        }
        var started = startSync(owner: owner, onAdmitted: onRunAdmitted)
        if started == nil, lastStartWasDeferred {
            // The pass waits for the first network path. The window stays open until that pass ends.
            backgroundLog.notice(.photoBackup, "window.waitsForFirstPath", [(.init("owner"), Self.logValue(owner))])
            started = await waitForDeferredStart(onAdmitted: onRunAdmitted)
            if started == nil, waitsForFirstNetworkPath { return .noNetworkPath }
        } else if started == nil, let run = automaticRunInTheBackground() {
            // Nobody watches this automatic pass, so it runs on the window's time until it ends or the window ends.
            backgroundLog.notice(.photoBackup, "window.tookOver", [(.init("owner"), Self.logValue(owner))])
            onRunStarted?(run.runID)
            await waitForAdoptedRun(run)
            // The person's retry waited for Wi-Fi while the taken-over pass ran, and that pass does not carry it. The
            // window still has time, so it runs the retry as its own pass instead of leaving it to a later window.
            guard !Task.isCancelled, manualWiFiRetryPending, runtimeSignals.current().canEndWiFiWait,
                let retry = startSync(owner: owner, onAdmitted: onRunAdmitted)
            else { return .done }
            backgroundLog.notice(
                .photoBackup, "window.carriesRetryAfterTakeover", [(.init("owner"), Self.logValue(owner))])
            onRunStarted?(retry.runID)
            await retry.task.value
            return .done
        }
        guard let run = started else {
            backgroundLog.notice(
                .photoBackup, "window.noPass",
                [
                    (.init("owner"), Self.logValue(owner)), (.init("otherPassRunning"), .flag(isSyncing)),
                    (.init("enabled"), .flag(isEnabled)), (.init("userPaused"), .flag(isUserPaused)),
                    (.init("accessAllowed"), .flag(accessState.allowsBackup)),
                ])
            return .done
        }
        onRunStarted?(run.runID)
        await run.task.value
        return .done
    }

    /// The scan of a refresh window: it puts new and changed photos into the queue and uploads nothing. It does not wait
    /// for a network path. The automatic pass of the person's visit can still wait for that path or a long window; the
    /// scan leaves it waiting. A running pass, a waiting long window, or the person's own retry keeps its priority.
    public func backgroundRefreshScan(
        onRunStarted: (@MainActor (String) -> Void)? = nil
    ) async -> BackgroundRefreshScanEnd {
        // A refresh scan needs no network. It may scan next to the automatic deferral without taking it over. A long
        // window and the person's own retry can upload in the background, so the scan keeps the lock free for them.
        guard !isSyncing, deferredStartOwner == nil || deferredStartOwner == .foreground,
            deferredBackgroundOwner == nil
        else { return .notNeeded }
        let result = RefreshScanResult()
        guard let run = startSync(owner: .iOSRefreshTask, refreshScan: result) else {
            return result.lockWasBusy ? .notNeeded : .couldNotStart
        }
        onRunStarted?(run.runID)
        await run.task.value
        return result.end
    }

    /// The single entry point that starts a pass. Acquires durable execution ownership before any
    /// draining: a crashed/expired owner's stale lock is reaped here, and a live lock held by a
    /// different run makes this call stand down instead of starting a second drainer.
    private func startSync(
        owner: BackupExecutionOwner, refreshScan: RefreshScanResult? = nil,
        onAdmitted: ((String) -> Void)? = nil
    ) -> StartedBackupRun? {
        lastStartWasDeferred = false
        let scanOnly = refreshScan != nil
        guard !isShuttingDown, isEnabled, !isUserPaused, accessState.allowsBackup, !isSyncing,
            !isRetiringInstantWork, runnerStopTask == nil,
            let engine, let runner, let queueStore, let catalogStore
        else { return nil }
        if owner == .foreground, runtimeSignals.current().isAppInBackground {
            // While no scene is in the foreground, only a background window starts a pass. The app's own starts (the
            // resume at launch, a new photo, the network, a timer, the restart after a pass) wait for the next window
            // or for the person to open the app; a pass that already runs keeps going.
            backgroundLog.notice(
                .photoBackup, "pass.declined",
                [(.init("owner"), Self.logValue(owner)), (.init("reason"), .word("appInBackground"))])
            return nil
        }
        guard queueStore.isOperational(), catalogStore.isOperational(), pendingStoreIsReady else {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            refreshFromQueue()
            return nil
        }
        guard scanOnly || !waitsForFirstNetworkPath else {
            // A pass before the first network path would end as "Waiting for Wi-Fi" on Wi-Fi, too.
            if owner != .foreground, owner != .manual {
                if deferredBackgroundOwner == nil { deferredBackgroundOwner = owner }
            } else if owner == .manual || deferredStartOwner == nil {
                deferredStartOwner = owner
            }
            lastStartWasDeferred = true
            startFirstNetworkPathWait()
            return nil
        }
        var tookAutomaticDeferral = false
        if scanOnly {
            // A refresh scan uploads nothing, so it never takes a deferred pass over and never starts it.
        } else if deferredStartOwner == .foreground, owner != .foreground, owner != .manual,
            runtimeSignals.current().isAppInBackground
        {
            // The snapshot arrived before its observer, and no scene is in the foreground: this window runs the
            // automatic pass that waited for the path.
            deferredStartOwner = nil
            tookAutomaticDeferral = true
            if deferredBackgroundOwner == nil {
                firstNetworkPathWaitTask?.cancel()
                firstNetworkPathWaitTask = nil
            }
        } else if deferredStartOwner != nil {
            // The snapshot can arrive before its observer. A window must still yield to the deferred session pass.
            if owner == .manual { deferredStartOwner = .manual }
            let run = startAfterFirstNetworkPath()
            return owner == .foreground || owner == .manual ? run : nil
        }
        defer {
            // A window that took the automatic pass but started no run gives it back, so the path observer starts it.
            if tookAutomaticDeferral, activeRunID == nil, deferredStartOwner == nil { deferredStartOwner = .foreground }
        }
        var carriesManualRetry = false
        if !scanOnly, manualWiFiRetryPending, runtimeSignals.current().canEndWiFiWait, owner != .manual {
            if runtimeSignals.current().isAppInBackground {
                // No scene is in the foreground, so nobody watches the person's retry. Only a background window gets
                // here; it runs the retry as its own pass that holds the window's time and may skip the remote index
                // backoff.
                carriesManualRetry = true
            } else {
                let run = startSync(owner: .manual)
                // In the foreground a window cannot own or expire the person's resumed retry.
                return owner == .foreground ? run : nil
            }
        }
        if !scanOnly, owner != .manual, !carriesManualRetry,
            Self.remoteIndexBackoffHoldsAutomaticPass(in: queueStore, now: Date())
        {
            refreshFromQueue()
            scheduleAutoResumeIfOutstanding()
            return nil
        }
        guard let lockStore else {
            lastMessage = L10n.string("backup.error_execution_lock_unavailable")
            refreshFromQueue()
            return nil
        }

        let runID = UUID().uuidString
        // Recovery must precede the drain: clear any owner that stopped heartbeating (crash,
        // OS kill, BG expiration) so a dead run can never permanently block backup.
        let processContext = Self.processContext
        lockStore.recoverAbandonedProcessLocks(
            currentProcessContext: processContext,
            isProcessAlive: Self.processIsAlive
        )
        lockStore.recoverStaleLocks(olderThan: Date().addingTimeInterval(-Self.lockLease))
        switch lockStore.acquire(owner: owner, runID: runID, phase: "scanning", processContext: processContext) {
        case .acquired:
            break
        case .busy:
            // Another live run owns the queue (e.g. a foreground pass while a BG window fires).
            // Stand down: its own drain covers the work; a second drainer is never allowed.
            refreshScan?.lockWasBusy = true
            return nil
        case .unavailable:
            lastMessage = L10n.string("backup.error_execution_lock_unavailable")
            refreshFromQueue()
            return nil
        }
        activeRunID = runID
        activeRunOwner = owner
        activeRefreshScan = refreshScan
        if carriesManualRetry {
            // The intent moves to this run only once the run holds the lock; a declined start keeps it pending.
            manualWiFiRetryPending = false
            activeRunCarriesManualRetry = true
        }
        onAdmitted?(runID)

        // Retry previously failed items once per launch.
        if !didAutoRetryFailedThisLaunch {
            didAutoRetryFailedThisLaunch = true
            queueStore.requeueFailed(updatedAt: Date())
        }
        logPassStart(owner: owner, scanOnly: scanOnly)

        autoResumeTask?.cancel()
        autoResumeTask = nil  // a pass is starting; the timer's job is done
        instantEnqueueTask?.cancel()
        instantEnqueueTask = nil
        isSyncing = true
        passWaitedForWiFi = false
        passPausedByPolicy = false
        backedUpAtRunStart = lastProjectedProgress.backedUp
        updateIdleTimerIfNeeded()
        isScanning = false
        lastMessage = nil
        status = BackupStatus(
            progress: lastProjectedProgress, isScanning: false,
            executionOpportunityIssue: executionOpportunityIssue
        )
        refreshFromQueue()
        startHeartbeat(runID: runID)
        startStatusRefresh()
        let statusSetupTask = self.statusSetupTask
        #if DEBUG
            let scanBody = scanBodyForTesting
        #else
            let scanBody: (@Sendable () async throws -> Void)? = nil
        #endif

        if let refreshScan {
            // A refresh window: the scan alone. Without the reconcile loop the runner never drains, so nothing uploads.
            let task = Task {
                [weak self, monitor, engine, runner, queueStore, catalogStore, statusSetupTask, scanBody] in
                await statusSetupTask?.value
                self?.refreshFromQueue()
                self?.beginScanPhase()
                var end = BackgroundRefreshScanEnd.stopped
                do {
                    try await Self.scanLibrary(
                        by: self, scanBody: scanBody, monitor: monitor, engine: engine, runner: runner,
                        queueStore: queueStore, catalogStore: catalogStore)
                    end = .scanned
                } catch is CancellationError {
                } catch {
                    end = .failed
                    self?.reportScanFailure(error)
                }
                self?.finishScanPhase()
                refreshScan.end = end == .stopped && refreshScan.yielded ? .yielded : end
                await self?.finishSync(runID: runID)
            }
            syncTask = task
            return StartedBackupRun(runID: runID, task: task)
        }

        // The task inherits the main actor, but all heavy phases (`scan`, `runUntilDrained`) are
        // awaits onto other actors/off-actor structs - the main thread stays free for UI.
        #if DEBUG
            if let passBody = passBodyForTesting {
                let task = Task { [weak self] in
                    await passBody()
                    await self?.finishSync(runID: runID)
                }
                syncTask = task
                return StartedBackupRun(runID: runID, task: task)
            }
        #endif
        let task = Task {
            [
                weak self, monitor, tempStore, engine, runner, queueStore, catalogStore, statusSetupTask, scanBody,
                identityResolver
            ] in
            await statusSetupTask?.value
            self?.refreshFromQueue()
            // Scan and reconcile run concurrently. Reconcile drains existing work and newly enqueued
            // items, and it is the only runner caller. A slow scan cannot block uploads.
            self?.beginScanPhase()
            let scanDone = BackupScanSignal()
            var scanFinished = false
            let workIntent: LibraryWorkIntent = owner == .manual ? .userInitiated : .automatic
            #if DEBUG
                self?.reconcileStartsForTesting += 1
            #endif
            async let reconcile: BackupSyncProgress = Self.reconcileWhileScanning(
                runner: runner,
                scanDone: scanDone,
                workIntent: workIntent,
                queue: queueStore
            )
            do {
                try await Self.scanLibrary(
                    by: self, scanBody: scanBody, monitor: monitor, engine: engine, runner: runner,
                    queueStore: queueStore, catalogStore: catalogStore)
                scanFinished = true
            } catch is CancellationError {
                // The one-shot completion signal below releases the reconcile loop cleanly.
            } catch {
                self?.reportScanFailure(error)
            }
            self?.finishScanPhase()

            await scanDone.markDone()
            let finalProgress = await reconcile  // drains the tail enqueued during the scan, then returns
            // The last drain ran after the scan. Only a finished scan shows that no photo waits; then no index build
            // follows from this pass.
            if scanFinished, finalProgress.leavesNoUploadWork {
                await identityResolver?.remoteIndexPreparationNotNeeded()
            }
            do {
                // Requeue drops after the runner stops. The next pass retries them without looping in this pass.
                try await Self.reconcileMissingSources(
                    PhotoLibraryCatalogSync(store: catalogStore), engine: engine)
            } catch is CancellationError {
            } catch {
                self?.reportSyncMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            tempStore.sweep()  // every export is re-derivable; nothing to keep between passes
            self?.passWaitedForWiFi = finalProgress.isPausedByPolicy && finalProgress.isWaitingForWiFi
            self?.passPausedByPolicy = finalProgress.isPausedByPolicy
            await self?.finishSync(runID: runID)
        }
        syncTask = task
        return StartedBackupRun(runID: runID, task: task)
    }

    /// The scan of a pass: it replays the catalog when the queue may be incomplete, then enqueues the library's changes.
    /// The backup pass and the refresh scan share it. A test can replace it with `scanBody`.
    private nonisolated static func scanLibrary(
        by controller: PhotoLibraryBackupController?, scanBody: (@Sendable () async throws -> Void)?,
        monitor: PhotoLibraryChangeMonitor, engine: UploadBackupSyncEngine, runner: BackupSyncRunner,
        queueStore: UploadBackupSyncQueueManifestStore, catalogStore: PhotoLibraryCatalogManifestStore
    ) async throws {
        if let scanBody {
            try await scanBody()
            return
        }
        try await replayCatalogIfQueueNeedsRecovery(catalogStore: catalogStore, queueStore: queueStore, engine: engine)
        let preparedChanges = await prepareChangesOffMainActor(monitor)
        try await controller?.runScanPass(
            engine: engine,
            runner: runner,
            catalogStore: catalogStore,
            changes: preparedChanges.changes,
            commitChanges: { monitor.commit(preparedChanges) }
        )
    }

    /// Replays durable inventory only when the queue may be incomplete.
    /// Catalog sync writes queue rows before advancing the catalog, so replay is safe and idempotent.
    nonisolated static func replayCatalogIfQueueNeedsRecovery(
        catalogStore: PhotoLibraryCatalogManifestStore,
        queueStore: UploadBackupSyncQueueManifestStore,
        engine: UploadBackupSyncEngine
    ) async throws {
        guard let queueCount = queueStore.count(), queueStore.isOperational(), catalogStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        guard let catalogSnapshot = catalogStore.snapshot(), catalogStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        let catalogCount = catalogSnapshot.present
        guard let replayState = queueStore.catalogReplayState(), queueStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        switch BackupCatalogReplayPolicy.action(
            state: replayState,
            queueCount: queueCount,
            catalogCount: catalogCount
        ) {
        case .skip:
            return
        case .markCompleted:
            // Upgrade path for queues created before the replay marker existed. A non-empty queue
            // cannot be behind its catalog: catalog sync durably writes every queue chunk first.
            guard queueStore.setCatalogReplayState(.completed) else {
                throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
            }
            return
        case .replay:
            break
        }
        guard replayState == .inProgress || queueStore.setCatalogReplayState(.inProgress) else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }

        var progress = PhotoLibraryCatalogPassProgress()
        while true {
            try Task.checkCancellation()
            guard let page = catalogStore.presentEntries(afterLocalIdentifier: progress.cursor, limit: 500),
                catalogStore.isOperational()
            else {
                throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
            }
            guard case .advanced = progress.advance(past: page) else {
                // While a row is unknown, the replay stays in progress and retries the row on the next event (#1160).
                guard progress.mayComplete(countingUnknownRowsAs: "backup.catalogReplay.undecodableRow") else {
                    return
                }
                guard queueStore.setCatalogReplayState(.completed) else {
                    throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
                }
                return
            }
            let candidates = page.entries.compactMap {
                PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: $0))
            }
            _ = try await engine.enqueueBatch(candidates)
        }
    }

    private nonisolated static func reconcileMissingSources(
        _ sync: PhotoLibraryCatalogSync, engine: UploadBackupSyncEngine
    ) async throws {
        do {
            try await sync.reconcileMissingSources(engine: engine)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
    }

    private nonisolated static func prepareChangesOffMainActor(
        _ monitor: PhotoLibraryChangeMonitor
    ) async -> PhotoLibraryChangeMonitor.PreparedChangeSet {
        await Task.detached(priority: .utility) {
            monitor.prepareChanges()
        }.value
    }

    /// The reconcile loop: repeatedly drains runnable queue rows to the backend until the index scan
    /// has signalled completion AND nothing runnable remains. Runs concurrently with the scan, so a
    /// slow or resuming scan never delays uploads. Static + the heavy work is on the runner actor, so
    /// it never touches the main thread and does not depend on the controller's lifetime.
    /// Returns the last drain's policy state; the projector can still miss the runner's last callback at completion.
    /// Between drains it waits for a committed queue write, the end of the scan, or the next persisted due date;
    /// writes within `coalescing` seconds start one drain. `nonisolated`: the due-date read is SQLite work and must
    /// stay off the main actor.
    nonisolated static func reconcileWhileScanning(
        runner: BackupSyncRunner,
        scanDone: BackupScanSignal,
        workIntent: LibraryWorkIntent,
        queue: UploadBackupSyncQueueManifestStore,
        coalescing: TimeInterval = 1,
        clock: any BackupSchedulerClock = BackupContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> BackupSyncProgress {
        await reconcileWhileScanning(
            drain: { await runner.runUntilDrained(mode: .eligibleOnly, workIntent: workIntent) },
            isQueueOperational: { await runner.isQueueOperational() },
            scanDone: scanDone, queue: queue, coalescing: coalescing, clock: clock, now: now)
    }

    /// The same loop over any drain, so a test can count the drains of a row that stays due.
    nonisolated static func reconcileWhileScanning(
        drain: @escaping @Sendable () async -> BackupSyncProgress,
        isQueueOperational: @escaping @Sendable () async -> Bool,
        scanDone: BackupScanSignal,
        queue: UploadBackupSyncQueueManifestStore,
        coalescing: TimeInterval,
        clock: any BackupSchedulerClock,
        now: @escaping @Sendable () -> Date
    ) async -> BackupSyncProgress {
        // Subscribe before the first drain, so a row enqueued after a drain wakes the next one.
        let follower = scanDone.wake.follow(queue.changes())
        defer { follower.cancel() }
        while !Task.isCancelled {
            let progress = await drain()
            guard await isQueueOperational() else { return progress }
            // A failed remote index cannot safely dedupe anything, and a closed runtime policy has
            // no eligible transport. End this pass and let the controller's typed retry scheduler
            // choose the next attempt instead of draining again at every queue write.
            if progress.remoteIndexPreparationFailed || progress.isPausedByPolicy {
                return progress
            }
            if await scanDone.isDone() {
                // The scan may have enqueued rows between our last claim and its done-signal; one more
                // drain guarantees they upload before we return.
                return await drain()
            }
            // A row that is already due (its date passed after the drain's last claim) wakes the next drain at once;
            // the pause below keeps that to one drain per `coalescing` seconds. Cancellation wakes the wait.
            await scanDone.wake.wait(atMost: nextDueDelay(in: queue, now: now()), clock: clock)
            // Writes of the same scan chunk drain together. A scan that ended before the pause drains at once; one that
            // ends during it, and a stored date, drain at most `coalescing` seconds later.
            if await !scanDone.isDone() { try? await clock.sleep(for: coalescing) }
        }
        return BackupSyncProgress()
    }

    /// True while the stored remote-index issue waits for its next attempt: an automatic pass then waits too.
    /// An issue that could not be read holds the pass as well; the automatic resume reads it again (#1004 B2).
    nonisolated static func remoteIndexBackoffHoldsAutomaticPass(
        in queue: UploadBackupSyncQueueManifestStore, now: Date
    ) -> Bool {
        let issue: BackupIssueRecord?
        do {
            issue = try queue.decisionRuntimeIssue(for: .remoteIndexPreparation)
        } catch {
            return true
        }
        guard let retryAt = issue?.nextAttemptAt else { return false }
        return retryAt > now
    }

    /// The longest timed wait of the drain: the runner's longest park (Proton storage, 6 h). A later or damaged date
    /// wakes the drain after this time, which then reads the dates again; a sleep never gets an unbounded value.
    nonisolated static let longestDueWait: TimeInterval = 6 * 3600

    /// The wait after a due date that could not be read: the shortest automatic retry delay (BackupIssue).
    nonisolated static let unknownDueDateWait: TimeInterval = 30

    /// Seconds until the earliest persisted retry date or draft re-check, 0 when one is already due, or nil when
    /// nothing waits for a date. A due date counts: as the minimum it would otherwise hide every later date.
    nonisolated static func nextDueDelay(in queue: UploadBackupSyncQueueManifestStore, now: Date) -> TimeInterval? {
        // A blocked draft stores its re-check date as `updatedAt`, as the runner's own wait reads it.
        let dates: [Date?]
        do {
            dates = [
                try queue.decisionNextRunnableDate(excludingSourcesOf: []),
                try queue.decisionEarliestEntry(in: .blockedByDraft)?.updatedAt,
            ]
        } catch {
            // An unknown date reads again soon instead of waiting for the next queue write.
            return unknownDueDateWait
        }
        guard let next = dates.compactMap({ $0 }).min() else { return nil }
        return min(longestDueWait, max(0, next.timeIntervalSince(now)))
    }

    /// Runs the scan phase through the persistent catalog driver. `nonisolated` keeps SQLite and
    /// PhotoKit enumeration off the main actor.
    private nonisolated func runScanPass(
        engine: UploadBackupSyncEngine,
        runner: BackupSyncRunner,
        catalogStore: PhotoLibraryCatalogManifestStore,
        changes: PhotoLibraryChangeMonitor.ChangeSet,
        commitChanges: @escaping @Sendable () -> Void
    ) async throws {
        let sync = PhotoLibraryCatalogSync(
            store: catalogStore,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.lastCatalogProgress = progress }
            },
            onRemoved: { identifiers in
                _ = await runner.removePhotoLibraryAssets(identifiers)
            }
        )
        try await Self.reconcileMissingSources(sync, engine: engine)
        try await sync.reconcileLateRendersOnce(engine: engine)
        try await sync.runPass(
            engine: engine,
            changes: changes,
            onLibraryChange: { [weak self] in await self?.noteLibraryChange() },
            commitChanges: commitChanges
        )
    }

    private func resumeEnabledBackupAfterLaunch() {
        refreshAccessState()
        let inBackground: (BackgroundWorkLog.Key, BackgroundWorkLog.Value) = (
            .init("inBackground"), .flag(runtimeSignals.current().isAppInBackground)
        )
        guard isEnabled, accessState.allowsBackup, !isSyncing else {
            backgroundLog.notice(
                .photoBackup, "launch.resume",
                [
                    (.init("started"), .flag(false)), (.init("enabled"), .flag(isEnabled)),
                    (.init("accessAllowed"), .flag(accessState.allowsBackup)),
                    (.init("otherPassRunning"), .flag(isSyncing)), inBackground,
                ])
            return
        }
        syncNow()
        backgroundLog.notice(
            .photoBackup, "launch.resume",
            [
                (.init("started"), .flag(isSyncing)), (.init("waitsForFirstPath"), .flag(lastStartWasDeferred)),
                inBackground,
            ])
    }

    /// Stops only the active run identified by the caller. OS expiration handlers must use this
    /// overload so an expired attempt cannot cancel a foreground run or a later replacement run.
    public func stopSync(runID: String) {
        guard activeRunID == runID else { return }
        stopCurrentSync()
    }

    /// Stops the run of an expired OS background window. A run that the window took over from an automatic pass keeps
    /// going when a scene is in the foreground again, because the person now watches it.
    public func stopBackgroundWindowRun(runID: String) {
        guard activeRunID == runID else { return }
        if activeRunOwner == .foreground, !runtimeSignals.current().isAppInBackground { return }
        stopCurrentSync()
    }

    /// Explicit user actions may stop whichever run is currently active.
    public func stopSync() {
        stopCurrentSync()
    }

    private func stopCurrentSync() {
        // Cancel the scan and reconcile tasks before stopping the runner. Otherwise the next drain loop
        // can reset the runner stop flag; runner.stop() also aborts an in-flight upload.
        syncTask?.cancel()
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        instantEnqueueTask?.cancel()
        instantWorkItems.forEach { $0.task.cancel() }
        guard activeRunID != nil else { return }
        requestRunnerStop()
    }

    /// Creates the stop operation synchronously on the main actor after orchestration cancellation.
    /// A run keeps this handle until `completeSyncRun` crosses the settlement barrier.
    private func requestRunnerStop() {
        guard let runID = activeRunID, runnerStopTask == nil else { return }
        #if DEBUG
            if let operation = runnerStopOperationForTesting {
                let task = Task { await operation() }
                runnerStopRunID = runID
                runnerStopTask = task
                return
            }
        #endif
        guard let runner else { return }
        let task = Task { await runner.stop() }
        runnerStopRunID = runID
        runnerStopTask = task
        runnerStopRequestedAt = .now
        backgroundLog.notice(
            .photoBackup, "pass.stopRequested", [(.init("owner"), Self.logValue(activeRunOwner ?? .foreground))])
    }

    #if DEBUG
        /// Seeds a parked row on the offline UI-test account. It uses the real queue and decision actions.
        public func installDeletedElsewhereFixtureForTesting(count: Int = 1) -> Bool {
            guard let queueStore, pendingReplacementJournal != nil, (1...5_000).contains(count) else { return false }
            let entries = (1...count).map { index in
                let suffix = String(format: "%04d", index)
                let source = UploadSourceIdentity(
                    kind: .photoLibraryAsset,
                    identifier: count == 1 ? "fixture-deleted-photo" : "fixture-deleted-photo-\(suffix)")
                return UploadBackupSyncQueueEntry(
                    source: source, revision: .init(rawValue: Int64(count - index + 1)),
                    originalFilename: count == 1 ? "Deleted fixture.heic" : "Deleted \(suffix) fixture.heic",
                    state: .failedPermanent,
                    lastError: BackupIssueRecord(
                        kind: .deletedElsewhere, detail: L10n.string("backup.issue_deleted_elsewhere")
                    ).persistedValue, updatedAt: Date())
            }
            guard queueStore.upsertBatch(entries) else { return false }
            // Keep the fixture independent of PhotoKit authorization and assets on the simulator.
            isEnabled = true
            isUserPaused = false
            accessState = .denied
            refreshFromQueue()
            return true
        }

        /// Seeds the three native sections without PhotoKit or a network connection.
        public func installFailedItemsFixtureForTesting(
            kinds: [BackupIssueKind] = [.network, .accountStorage, .deletedElsewhere, .unsupported]
        ) -> Bool {
            guard let queueStore, pendingReplacementJournal != nil else { return false }
            let retryAt = Date().addingTimeInterval(3_600)
            for kind in kinds {
                let state: UploadBackupSyncQueueState =
                    switch kind {
                    case .deletedElsewhere: .failedPermanent
                    // A remote-service row is failed: it stopped retrying and waits for the person.
                    case .unsupported, .remoteService: .failed
                    default: .discovered
                    }
                let source = UploadSourceIdentity(
                    kind: .photoLibraryAsset, identifier: "fixture-\(kind.rawValue)")
                guard
                    queueStore.upsert(
                        .init(
                            source: source, revision: .init(rawValue: 1),
                            originalFilename: "\(kind.rawValue) fixture.heic", state: state,
                            lastError: BackupIssueRecord(
                                kind: kind, detail: "Fixture technical detail",
                                nextAttemptAt: kind.category == .automatic ? retryAt : nil
                            ).persistedValue, updatedAt: retryAt))
                else { return false }
            }
            isEnabled = true
            isUserPaused = false
            accessState = .denied
            refreshFromQueue()
            return true
        }

        /// Seeds one photo that waits for its upload while the person paused the backup, without PhotoKit or a
        /// network connection. Passes after a resume do nothing, so the photo keeps waiting in the grid.
        public func installPausedBackupFixtureForTesting() -> Bool {
            guard let queueStore, let catalogStore, pendingRecorder != nil else { return false }
            let date = Date(timeIntervalSince1970: 1_781_352_000)  // 13 June 2026: after every fixture photo
            let info = PhotoBackupAssetInfo(
                localIdentifier: "fixture-paused-photo", creationDate: date, modificationDate: date,
                pixelWidth: 160, pixelHeight: 160, durationSeconds: 0, isLivePhoto: false, isVideo: false,
                resources: [
                    .init(role: .originalPhoto, originalFilename: "Paused fixture.heic", mimeType: "image/heic")
                ])
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: info.localIdentifier)
            guard catalogStore.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: date)]),
                queueStore.upsert(
                    .init(
                        source: source, revision: .init(rawValue: 1), originalFilename: "Paused fixture.heic",
                        state: .queuedForUpload, updatedAt: date))
            else { return false }
            passBodyForTesting = {}
            isEnabled = true
            isUserPaused = true
            accessState = .full
            refreshFromQueue()
            return true
        }

        /// Seeds one uploading, one waiting, and one problem photo. The pause keeps a pass from changing the rows.
        public func installQueueFixtureForTesting() -> Bool {
            guard let queueStore else { return false }
            let now = Date()
            let rows: [(String, UploadBackupSyncQueueState, String?)] = [
                ("Uploading fixture.heic", .uploading, nil),
                ("Waiting fixture.heic", .queuedForUpload, nil),
                (
                    "Network fixture.heic", .discovered,
                    BackupIssueRecord(kind: .network, detail: "Fixture technical detail").persistedValue
                ),
            ]
            for (index, (filename, state, lastError)) in rows.enumerated() {
                let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "fixture-queue-\(index)")
                guard
                    queueStore.upsert(
                        .init(
                            source: source, revision: .init(rawValue: 1), originalFilename: filename, state: state,
                            lastError: lastError, updatedAt: now))
                else { return false }
            }
            isEnabled = true
            isUserPaused = true
            accessState = .denied
            refreshFromQueue()
            return true
        }

        /// Open problem lists that wait for the start or end of a pass.
        internal var passStateWakeCountForTesting: Int { passStateWakes.count }

        /// The queue store that this controller owns. Only it reports committed writes to the problem list.
        internal var queueStoreForTesting: UploadBackupSyncQueueManifestStore? { queueStore }

        /// Replaces what the summary says about problem items, so a test needs no status projection.
        @ObservationIgnored internal var problemListExpectationForTesting: (() -> Bool)?

        /// Turns the backup on without the launch resume, which reads the real photo library authorization again.
        internal func setEnabledForTesting() {
            isEnabled = true
        }

        /// A library change, as the change monitor reports it.
        internal func noteLibraryChangeForTesting() {
            scheduleChangeDrivenSync()
        }

        /// A change during the pass armed the restart after it.
        internal var isRestartAfterStopArmedForTesting: Bool { pendingSyncAfterStop }

        /// The person's manual retry waits for Wi-Fi.
        internal var isManualWiFiRetryPendingForTesting: Bool { manualWiFiRetryPending }

        /// Host tests start from a retry that already waits; the package tests reach this state through a manual pass.
        internal func markManualWiFiRetryPendingForTesting() { manualWiFiRetryPending = true }

        /// The first status projection arrived, so a pass start has counts to compare with.
        internal var hasStatusProjectionForTesting: Bool { hasStatusProjection }

        internal func setAccessStateForTesting(_ state: PhotoBackupAccessState) {
            accessState = state
        }

        internal func replaceScanForTesting(_ body: @escaping @Sendable () async throws -> Void) {
            scanBodyForTesting = body
        }

        internal func replacePassBodyForTesting(_ body: @escaping @Sendable () async -> Void) {
            passBodyForTesting = body
        }

        internal func replaceFirstNetworkPathSleepForTesting(_ sleep: @escaping @Sendable (Duration) async -> Void) {
            firstNetworkPathSleepForTesting = sleep
        }

        /// Set this right after the controller is created, before the test awaits anything.
        internal func holdLaunchResumeForTesting(_ gate: @escaping @Sendable () async -> Void) {
            launchResumeGateForTesting = gate
        }

        internal var deferredStartOwnerForTesting: BackupExecutionOwner? { deferredStartOwner }

        /// Returns when every ended pass has finished its completion, including the decision about its next wake.
        internal func waitForSyncRunCompletionForTesting() async {
            guard completingSyncRuns > 0 else { return }
            await withCheckedContinuation { syncRunCompletionWaiters.append($0) }
        }

        /// Background windows that wait for their deferred pass.
        internal var deferredStartWaiterCountForTesting: Int { deferredStartWaiters.count }
        /// How many passes started the reconcile loop, the only caller of the runner.
        internal private(set) var reconcileStartsForTesting = 0

        @discardableResult
        internal func installSyncRunForTesting(
            runID: String,
            task: Task<Void, Never>
        ) -> Bool {
            guard syncTask == nil, activeRunID == nil, runnerStopTask == nil else { return false }
            activeRunID = runID
            syncTask = task
            isSyncing = true
            return true
        }

        internal func installRunnerStopOperationForTesting(
            _ operation: @escaping @Sendable () async -> Void
        ) {
            runnerStopOperationForTesting = operation
        }

        internal func finishSyncForTesting(runID: String) async {
            await finishSync(runID: runID)
        }

        internal var isRunnerStopPendingForTesting: Bool {
            runnerStopTask != nil
        }

        internal var runnerStopRunIDForTesting: String? {
            runnerStopRunID
        }

        /// Installs a synthetic targeted-work task for deterministic lifecycle tests.
        /// The task models a PhotoKit/SQLite writer that can ignore cancellation while it is blocked.
        @discardableResult
        internal func installInstantWorkTaskForTesting(_ task: Task<Void, Never>) -> Bool {
            guard !isShuttingDown, !isRetiringInstantWork else { return false }
            let completion = InstantWorkCompletion()
            let trackedTask = Task.detached(priority: .utility) {
                await task.value
                await completion.markCompleted()
            }
            instantWorkItems.append(InstantWorkItem(task: trackedTask, completion: completion))
            return true
        }

        /// Starts a synthetic targeted writer only when the controller accepts new targeted work.
        /// This seam lets lifecycle tests prove that retirement rejects a new writer before it starts.
        @discardableResult
        internal func startInstantWorkForTesting(
            _ operation: @escaping @Sendable () async -> Void
        ) -> Bool {
            guard !isShuttingDown, !isRetiringInstantWork else { return false }
            let completion = InstantWorkCompletion()
            let task = Task.detached(priority: .utility) {
                await operation()
                await completion.markCompleted()
            }
            instantWorkItems.append(InstantWorkItem(task: task, completion: completion))
            return true
        }

        @discardableResult
        internal func startPreparedInstantWorkForTesting(
            prepare: @escaping @Sendable () async -> Void,
            consume: @escaping @Sendable () async -> Void
        ) -> Bool {
            startPreparedInstantWork(prepare: prepare, consume: { _ in await consume() })
        }

        internal var isRetiringInstantWorkForTesting: Bool { isRetiringInstantWork }
        internal var isAutoResumeScheduledForTesting: Bool { autoResumeTask != nil }
        internal var consecutiveNoProgressRunsForTesting: Int { consecutiveNoProgressRuns }
        internal var executionOwnerForTesting: BackupExecutionOwner? { lockStore?.currentLock()?.owner }

        internal func retireInstantWorkForTesting() async {
            guard !isRetiringInstantWork else { return }
            isRetiringInstantWork = true
            await retireInstantWorkTask()
        }

        internal func waitForInstantWorkRetirementForTesting() async {
            await instantWorkRetirementTask?.value
        }

        /// Delays each status-projector stream event before ingestion: simulates a starved consumer.
        internal func holdStatusProjectionIngestionForTesting(_ gate: @escaping @Sendable () async -> Void) async {
            await statusProjector?.setIngestionGateForTesting(gate)
        }

        /// Signals that a status-projector stream event fully settled: used with the gate above.
        internal func observeStatusProjectionIngestionForTesting(
            _ observer: @escaping @Sendable () async -> Void
        ) async {
            await statusProjector?.setIngestionObserverForTesting(observer)
        }
    #endif

    /// Stops every account-scoped worker, awaits its final callback, then closes all SQLite owners.
    /// Sign-out must await this before removing `accountDataDirectory`.
    public func shutdown() async {
        isShuttingDown = true
        let bulkCompletion = bulkCompletionTask
        bulkCompletion?.cancel()
        await bulkPhotoActions.shutdown()
        await bulkCompletion?.value
        bulkCompletionTask = nil
        manualWiFiRetryPending = false
        pendingSyncAfterStop = false
        changeSubscription?.cancel()
        changeSubscription = nil
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        firstNetworkPathWaitTask?.cancel()
        firstNetworkPathWaitTask = nil
        deferredStartOwner = nil
        deferredBackgroundOwner = nil
        resumeDeferredStartWaiters(with: nil)
        networkObservationTask?.cancel()
        networkObservationTask = nil
        instantEnqueueTask?.cancel()
        let activeSync = syncTask
        let activeStatusSetup = statusSetupTask
        syncTask?.cancel()
        statusSetupTask = nil
        let activeEnqueue = instantEnqueueTask
        instantEnqueueTask = nil
        activeEnqueue?.cancel()
        requestRunnerStop()
        let activeStop = runnerStopTask
        await activeStop?.value
        await activeSync?.value
        await activeStatusSetup?.value
        await activeEnqueue?.value
        await joinInstantWorkTasksForShutdown()
        for context in restoredRechecks.values { await identityResolver?.endRestoredCompound(context) }
        restoredRechecks.removeAll()
        admittedRestoreRechecks.removeAll()
        await runner?.setOnProgress(nil)
        await statusProjector?.stop()
        idleTimerHook?(false)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        tempStore.sweep()
        queueStore?.close()
        stateStore?.close()
        catalogStore?.close()
        lockStore?.close()
    }

    // MARK: - Execution-lock heartbeat

    private func startHeartbeat(runID: String) {
        heartbeatTask?.cancel()
        guard let lockStore else {
            heartbeatTask = nil
            return
        }
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                switch lockStore.heartbeat(runID: runID, phase: nil) {
                case .renewed, .unavailable:
                    // A failed read or write leaves ownership unknown; the next interval tries again.
                    continue
                case .lost:
                    // Another owner holds the lock, or nobody does: stop the run. In-flight transfers are cancelled and
                    // joined; unfinished rows go back to a runnable state, and a transfer that already committed keeps
                    // its result.
                    self?.stopSync(runID: runID)
                    return
                }
            }
        }
    }

    /// Keeps the visible counter honest from the durable queue while a pass runs. SQLite work stays
    /// on `BackupStatusProjector`; this task only supplies current lifecycle context once per second.
    private func startStatusRefresh() {
        statusRefreshTask?.cancel()
        guard let statusProjector else {
            statusRefreshTask = nil
            return
        }
        let generation = statusProjectionGeneration
        statusRefreshTask = Task { @MainActor [weak self, statusProjector] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isSyncing, !Task.isCancelled else { return }
                let request = self.nextStatusProjectionRequest()
                _ = await statusProjector.projectNow(
                    context: request.context,
                    generation: generation,
                    revision: request.revision
                )
            }
        }
    }

    // MARK: - Change-driven incremental sync (foreground sessions)

    private func noteLibraryChange() {
        onLibraryChange?()
    }

    private func startObservingChanges() {
        guard changeSubscription == nil else { return }
        changeSubscription = monitor.subscribe { [weak self] in
            Task { @MainActor in self?.scheduleChangeDrivenSync() }
        }
    }

    /// Uses the one shared runtime signal; it adds no second network monitor.
    private func startObservingNetwork() {
        let updates = runtimeSignals.updates()
        networkObservationTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard let self, !Task.isCancelled else { return }
                self.bulkPolicyPaused = !self.bulkReadPolicyAllowsWork
                if self.bulkPolicyPaused {
                    self.bulkPhotoActions.dismissConfirmation()
                    self.bulkPhotoActions.stopAfterCurrentPhoto()
                }
                self.startAfterFirstNetworkPath()
                self.resumeIfWiFiWaitEnded()
            }
        }
    }

    private var waitsForFirstNetworkPath: Bool {
        !firstNetworkPathWaitEnded && runtimeSignals.current().waitsForFirstNetworkPath
    }

    private func startFirstNetworkPathWait() {
        guard firstNetworkPathWaitTask == nil else { return }
        let wait = firstNetworkPathWait
        #if DEBUG
            let testSleep = firstNetworkPathSleepForTesting
        #endif
        firstNetworkPathWaitTask = Task { @MainActor [weak self] in
            #if DEBUG
                if let testSleep { await testSleep(wait) } else { try? await Task.sleep(for: wait) }
            #else
                try? await Task.sleep(for: wait)
            #endif
            guard let self, !Task.isCancelled else { return }
            self.firstNetworkPathWaitTask = nil
            self.firstNetworkPathWaitEnded = true
            self.startAfterFirstNetworkPath()
        }
    }

    @discardableResult
    private func startAfterFirstNetworkPath() -> StartedBackupRun? {
        guard !isShuttingDown, deferredStartOwner != nil || deferredBackgroundOwner != nil, !waitsForFirstNetworkPath
        else { return nil }
        let sessionOwner = deferredStartOwner
        let backgroundOwner = deferredBackgroundOwner
        deferredStartOwner = nil
        deferredBackgroundOwner = nil
        firstNetworkPathWaitTask?.cancel()
        firstNetworkPathWaitTask = nil
        if sessionOwner == .foreground, let backgroundOwner, !deferredStartWaiters.isEmpty,
            runtimeSignals.current().isAppInBackground
        {
            // No scene is in the foreground, so nobody watches the automatic pass: the waiting window runs it.
            let run = startSync(owner: backgroundOwner, onAdmitted: admitDeferredStartWaiters)
            if run == nil { deferredStartOwner = sessionOwner }
            resumeDeferredStartWaiters(with: run)
        } else if let sessionOwner {
            // The foreground or explicit pass runs on its own; a waiting window ends without owning it.
            let run = startSync(owner: sessionOwner)
            if run == nil { deferredStartOwner = sessionOwner }
            resumeDeferredStartWaiters(with: nil)
            return run
        } else if let backgroundOwner {
            resumeDeferredStartWaiters(with: startSync(owner: backgroundOwner, onAdmitted: admitDeferredStartWaiters))
        }
        return nil
    }

    /// Waits for the deferred pass of a background window. Cancellation, for example at the OS expiration, ends the
    /// wait at once, and the deferred pass of a background window does not outlive it.
    private func waitForDeferredStart(onAdmitted: (@MainActor (String) -> Void)?) async -> StartedBackupRun? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, deferredBackgroundOwner != nil else {
                    continuation.resume(returning: nil)
                    dropUnwaitedBackgroundDeferral()
                    return
                }
                deferredStartWaiters[id] = continuation
                deferredStartAdmissions[id] = onAdmitted
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDeferredStartWait(id) }
        }
    }

    /// The running automatic pass, while no scene is in the foreground. An explicit pass is never returned: a window
    /// must not own or stop it.
    private func automaticRunInTheBackground() -> StartedBackupRun? {
        guard activeRunOwner == .foreground, let activeRunID, let syncTask, runtimeSignals.current().isAppInBackground
        else { return nil }
        return StartedBackupRun(runID: activeRunID, task: syncTask)
    }

    /// Waits for a run that a background window took over. The cancellation of the window ends the wait at once; the
    /// run then belongs to the app again, and the window's expiration decides whether it stops.
    private func waitForAdoptedRun(_ run: StartedBackupRun) async {
        let id = UUID()
        Task { @MainActor [weak self] in
            await run.task.value
            self?.endAdoptedRunWait(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                adoptedRunWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endAdoptedRunWait(id) }
        }
    }

    private func endAdoptedRunWait(_ id: UUID) {
        adoptedRunWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelDeferredStartWait(_ id: UUID) {
        guard let continuation = deferredStartWaiters.removeValue(forKey: id) else { return }
        deferredStartAdmissions.removeValue(forKey: id)
        continuation.resume(returning: nil)
        dropUnwaitedBackgroundDeferral()
    }

    private func dropUnwaitedBackgroundDeferral() {
        guard deferredStartWaiters.isEmpty, deferredBackgroundOwner != nil else { return }
        deferredBackgroundOwner = nil
        // A deferred foreground or explicit pass keeps its wait.
        guard deferredStartOwner == nil else { return }
        firstNetworkPathWaitTask?.cancel()
        firstNetworkPathWaitTask = nil
    }

    /// Admits the run to every window that waits for it, before the run is reported active.
    private func admitDeferredStartWaiters(_ runID: String) {
        deferredStartAdmissions.values.forEach { $0(runID) }
    }

    private func resumeDeferredStartWaiters(with run: StartedBackupRun?) {
        let waiters = deferredStartWaiters.values
        deferredStartWaiters.removeAll()
        deferredStartAdmissions.removeAll()
        waiters.forEach { $0.resume(returning: run) }
    }

    // MARK: Device log

    /// What follows a pass that ended, for the device log.
    private enum NextAfterPass: String, BackgroundLogName {
        case none
        case foregroundPassAfterScan
        case restartAfterChange
        case wiFiWaitEnded
        case automaticResume
        case shutdown
        case anotherPassStarted
        case localStateUnavailable
        case stoppedInBackground
    }

    /// The facts of a pass that are gone once its run is cleared.
    private struct EndedPass {
        let owner: BackupExecutionOwner
        let stopped: Bool
        let waitedForWiFi: Bool
        let pausedByPolicy: Bool
        let startedAt: ContinuousClock.Instant
        let progressAtStart: BackupSyncProgress?
        let stopRequestedAt: ContinuousClock.Instant?
    }

    /// The owner of a pass and, off the main actor, the queue that it starts with.
    private func logPassStart(owner: BackupExecutionOwner, scanOnly: Bool) {
        runStartedAt = .now
        progressAtRunStart = hasStatusProjection ? lastProjectedProgress : nil
        runnerStopRequestedAt = nil
        lastProgressLogAt = .now
        backgroundLog.notice(
            .photoBackup, "pass.started",
            [(.init("owner"), Self.logValue(owner)), (.init("scanOnly"), .flag(scanOnly))])
        // The count reads the whole queue, which is too slow for the main actor on a large library. It counts the queue
        // when it runs, so its line can come after later lines; the owner names its pass.
        let ownerField: (BackgroundWorkLog.Key, BackgroundWorkLog.Value) = (.init("owner"), Self.logValue(owner))
        Task.detached(priority: .utility) { [queueStore, backgroundLog] in
            guard let counts = queueStore?.queueCounts() else { return }
            backgroundLog.notice(.photoBackup, "queue.snapshot", [ownerField] + Self.snapshotFields(counts))
        }
    }

    nonisolated private static func snapshotFields(
        _ counts: UploadBackupQueueDiagnostics
    ) -> [(BackgroundWorkLog.Key, BackgroundWorkLog.Value)] {
        var fields: [(BackgroundWorkLog.Key, BackgroundWorkLog.Value)] = UploadBackupSyncQueueState.allCases
            .compactMap { state in
                let rows = counts.rows[state] ?? 0
                return loggedQueueStates.contains(state) || rows > 0 ? (.name(state), .count(rows)) : nil
            }
        for state in [UploadBackupSyncQueueState.discovered, .checking] {
            let reasons = (counts.checkReasons[state] ?? [:]).sorted { order($0.key) < order($1.key) }
            for (reason, rows) in reasons {
                fields.append((.name(state).dot(key(reason)), .count(rows)))
            }
        }
        return fields
    }

    /// How a pass ended, and what it settled: rows that reached each successful end state, the change of failed rows,
    /// and the bytes that its transfers sent.
    private func logPassEnd(_ ended: EndedPass, progress: BackupSyncProgress) {
        let now = ContinuousClock.now
        var fields: [(BackgroundWorkLog.Key, BackgroundWorkLog.Value)] = [
            (.init("owner"), Self.logValue(ended.owner)), (.init("stopped"), .flag(ended.stopped)),
        ]
        if ended.stopped, let requested = ended.stopRequestedAt {
            fields.append((.init("stopMs"), .milliseconds(now - requested)))
        }
        fields += [
            (.init("durationMs"), .milliseconds(now - ended.startedAt)),
            (.init("waitedForWiFi"), .flag(ended.waitedForWiFi)),
            (.init("pausedByPolicy"), .flag(ended.pausedByPolicy)),
        ]
        // Before the first status projection the pass has no counts to compare with.
        guard let start = ended.progressAtStart else {
            fields.append((.init("baseline"), .word("none")))
            backgroundLog.notice(.photoBackup, "pass.ended", fields)
            return
        }
        fields += [
            (.init("completedRows"), .count(progress.uploaded - start.uploaded)),
            (.init("alreadyBackedUpRows"), .count(progress.alreadyBackedUp - start.alreadyBackedUp)),
            (
                .init("skippedRemoteDeletionRows"),
                .count(progress.skippedRemoteDeletions - start.skippedRemoteDeletions)
            ),
            (.init("failedRowsChange"), .count(progress.failed - start.failed)),
            (.init("sentBytes"), .count(max(0, progress.transferredByteCount - start.transferredByteCount))),
        ]
        backgroundLog.notice(.photoBackup, "pass.ended", fields)
    }

    private func logNext(_ next: NextAfterPass) {
        backgroundLog.notice(.photoBackup, "pass.next", [(.init("branch"), .name(next))])
    }

    /// One line of the running pass's counts at most every 30 seconds, when a status projection arrives.
    private func logProgressIfDue(_ progress: BackupSyncProgress) {
        guard isSyncing, let last = lastProgressLogAt, ContinuousClock.now - last >= .seconds(30) else { return }
        lastProgressLogAt = .now
        backgroundLog.notice(
            .photoBackup, "pass.progress",
            [
                (.init("completed"), .count(progress.uploaded)),
                (.init("alreadyBackedUp"), .count(progress.alreadyBackedUp)),
                (.init("checking"), .count(progress.checking)),
                (.init("queuedForUpload"), .count(progress.uploadQueued)),
                (.init("uploading"), .count(progress.uploading)), (.init("waiting"), .count(progress.waiting)),
                (.init("failed"), .count(progress.failed)), (.init("sentBytes"), .count(progress.transferredByteCount)),
            ])
    }

    /// The owners that the code names; any other value logs as `other`, so the log never repeats a value from a file.
    nonisolated private static func logValue(_ owner: BackupExecutionOwner) -> BackgroundWorkLog.Value {
        switch owner {
        case .foreground: .word("foreground")
        case .iOSBackgroundTask: .word("iosBackgroundTask")
        case .iOSRefreshTask: .word("iosRefreshTask")
        case .macOSBackgroundActivity: .word("macosBackgroundActivity")
        case .background: .word("background")
        case .manual: .word("manual")
        default: .word("other")
        }
    }

    nonisolated private static func key(_ reason: UploadBackupQueueDiagnostics.CheckReason) -> BackgroundWorkLog.Key {
        switch reason {
        case .none: BackgroundWorkLog.Key("none")
        case .unrecognized: BackgroundWorkLog.Key("unrecognized")
        case .issue(let kind): .name(kind)
        }
    }

    /// A fixed order of the reasons, so equal queues give equal lines.
    nonisolated private static func order(_ reason: UploadBackupQueueDiagnostics.CheckReason) -> String {
        switch reason {
        case .none: "0"
        case .unrecognized: "1"
        case .issue(let kind): "2" + kind.rawValue
        }
    }

    private func resumeIfWiFiWaitEnded() {
        guard !isShuttingDown, status.phase == .waitingForWiFi || manualWiFiRetryPending,
            runtimeSignals.current().canEndWiFiWait
        else { return }
        syncNow()
    }

    private func scheduleChangeDrivenSync() {
        guard !isShuttingDown, isEnabled else { return }
        if isSyncing {
            // Keep a follow-up pass armed until the targeted change is durably consumed. The active
            // pass can finish during the debounce window; without this guard that one notification
            // would be cancelled at teardown and wait until a later launch.
            pendingSyncAfterStop = true
            // A pass is already running: enqueue newly changed assets into the durable queue so the
            // concurrent reconcile loop picks them up in this pass. Debounce bursts of edits into one
            // targeted enqueue. Transaction-safe: enqueue is an idempotent upsert keyed by source +
            // revision; the dedup preflight still runs per-item in the runner, so nothing bypasses it.
            // Do not commit the change token here; the running pass owns that commit.
            guard !isRetiringInstantWork else { return }
            instantEnqueueTask?.cancel()
            instantEnqueueTask = Task { [weak self, monitor, engine, catalogStore, changeSleep] in
                try? await changeSleep(Self.liveChangeDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown, self.isSyncing else { return }
                    self.enqueueRecentChangesIntoRunningPass(
                        monitor: monitor, engine: engine, catalogStore: catalogStore)
                }
            }
            return
        }
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self, changeSleep] in
            try? await changeSleep(Self.liveChangeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isShuttingDown, self.isEnabled, !self.isSyncing else { return }
                self.syncNow()
            }
        }
    }

    /// Targeted enqueue of changes that arrived while a pass is running. Reads the change token without
    /// committing (the running pass owns the commit), runs a targeted catalog sync for exactly those
    /// identifiers so each becomes a durable `discovered` queue row with its real revision, and lets
    /// the concurrent reconcile loop drain it this pass. Re-enqueueing an asset the pass already
    /// handled is an idempotent upsert no-op (the queue's ON CONFLICT guard keeps state forward-only:
    /// a row already in checking/uploading/etc. is never regressed to discovered); the runner's per-
    /// item dedup preflight is never bypassed.
    private func enqueueRecentChangesIntoRunningPass(
        monitor: PhotoLibraryChangeMonitor,
        engine: UploadBackupSyncEngine?,
        catalogStore: PhotoLibraryCatalogManifestStore?
    ) {
        guard !isShuttingDown, !isRetiringInstantWork,
            let engine, let runner, let catalogStore
        else { return }
        startPreparedInstantWork(
            prepare: { await Self.prepareChangesOffMainActor(monitor) },
            consume: { [weak self] prepared in
                // An expired token is covered by the current pass's full scan. This path never
                // commits a token; the active pass remains its sole owner.
                guard !prepared.changes.requiresFullRescan else { return }
                let targeted = Array(Set(prepared.changes.changedIdentifiers + prepared.changes.deletedIdentifiers))
                guard !targeted.isEmpty else { return }
                let sync = PhotoLibraryCatalogSync(
                    store: catalogStore,
                    onRemoved: { identifiers in
                        _ = await runner.removePhotoLibraryAssets(identifiers)
                    }
                )
                _ = try? await sync.run(engine: engine, identifiers: targeted)
                await self?.noteLibraryChange()
            }
        )
    }

    /// Registers preparation and the resulting writer as one lifetime. Retirement must join a
    /// non-cooperative PhotoKit read before it can release the run or close account stores.
    @discardableResult
    private func startPreparedInstantWork<Value: Sendable>(
        prepare: @escaping @Sendable () async -> Value,
        consume: @escaping @Sendable (Value) async -> Void
    ) -> Bool {
        guard !isShuttingDown, !isRetiringInstantWork, isSyncing, let runID = activeRunID else { return false }
        let completion = InstantWorkCompletion()
        let task = Task.detached(priority: .utility) { [weak self] in
            if !Task.isCancelled, await self?.acceptsInstantWork(runID: runID) == true {
                let value = await prepare()
                if !Task.isCancelled, await self?.acceptsInstantWork(runID: runID) == true {
                    await consume(value)
                }
            }
            await completion.markCompleted()
        }
        // No actor suspension occurs between creating the task and recording its join handle.
        instantWorkItems.append(InstantWorkItem(task: task, completion: completion))
        return true
    }

    private func acceptsInstantWork(runID: String) -> Bool {
        !isShuttingDown && !isRetiringInstantWork && isSyncing && activeRunID == runID
    }

    // MARK: - Status projection

    private var projectionContext: BackupStatusProjectionContext {
        BackupStatusProjectionContext(
            isScanning: isScanning,
            isRunning: isSyncing,
            isUserPaused: isUserPaused,
            executionOpportunityIssue: executionOpportunityIssue
        )
    }

    private func applyStatusProjection(_ projection: BackupStatusProjection) {
        guard projection.generation == statusProjectionGeneration,
            projection.revision >= lastAppliedStatusProjectionRevision
        else { return }
        lastAppliedStatusProjectionRevision = projection.revision
        lastProjectedProgress = projection.progress
        hasStatusProjection = true
        nextAutomaticAttemptAt = projection.progress.outstanding.nextAttemptAt
        logProgressIfDue(projection.progress)
        guard projection.status != status else { return }
        status = projection.status
        noteUploadedLibraryMutation(projection.progress.uploaded)
    }

    private func beginScanPhase() {
        lastCatalogProgress = nil
        isScanning = true
        refreshFromQueue()
        followRemoteIndexPreparationOfFirstScan()
    }

    private func finishScanPhase() {
        isScanning = false
        scanIndexFollower?.cancel()
        scanIndexFollower = nil
        scanIndexPreparation = nil
        refreshFromQueue()
    }

    /// The first queue write of a first scan waits for the Proton index, and the drain reports the index only
    /// while photos wait in the queue. Without this, the scan would show no progress for minutes. Later scans
    /// update the index from recent changes in moments and need no progress.
    private func followRemoteIndexPreparationOfFirstScan() {
        guard let remoteIndexPreparer, catalogStore?.hasCompletedFullScan() == false else { return }
        scanIndexFollower?.cancel()
        scanIndexFollower = Task { [weak self] in
            // A failure is not shown here: the scan's queue writes and the drain report it.
            try? await remoteIndexPreparer.prepareRemoteIndex { [weak self] value in
                await self?.setScanIndexPreparation(value)
            }
        }
    }

    private func setScanIndexPreparation(_ value: UploadRemoteIndexPreparationProgress) {
        guard isScanning, scanIndexFollower?.isCancelled == false else { return }
        scanIndexPreparation = value.phase == .ready ? nil : value
    }

    /// Cancels every targeted writer and waits briefly before deciding whether retirement is needed.
    /// A PhotoKit/SQLite write may ignore cancellation, so the bounded wait preserves forward progress
    /// while an unfinished writer keeps the run lock and heartbeat through a retained join task.
    private func retireInstantWorkTask() async {
        let workItems = instantWorkItems
        instantWorkItems.removeAll(keepingCapacity: false)
        guard !workItems.isEmpty else {
            isRetiringInstantWork = false
            instantWorkRetirementRunID = nil
            return
        }

        workItems.forEach { $0.task.cancel() }
        let deadline = ContinuousClock.now + PhotoLibraryBackupController.instantWorkRetirementTimeout
        while ContinuousClock.now < deadline {
            var allCompleted = true
            for item in workItems {
                if !(await item.completion.isCompleted()) {
                    allCompleted = false
                    break
                }
            }
            if allCompleted { break }
            // The enclosing pass is commonly cancelled during expiration. Sleep in a detached task
            // so cancellation does not turn this bounded wait into a busy loop on the main actor.
            await Task.detached(priority: .utility) { () -> Void in
                try? await Task.sleep(for: .milliseconds(5))
            }.value
        }

        var remaining: [InstantWorkItem] = []
        for item in workItems {
            if await item.completion.isCompleted() {
                await item.task.value
            } else {
                remaining.append(item)
            }
        }
        guard !remaining.isEmpty else {
            isRetiringInstantWork = false
            instantWorkRetirementRunID = nil
            return
        }

        // Keep the exact run owner and heartbeat until every writer returns. The task itself is
        // retained by the controller so shutdown can join it before closing account SQLite stores.
        instantWorkRetirementTask = Task { @MainActor [weak self] in
            for item in remaining {
                await item.task.value
            }
            guard let self else { return }
            await self.finishInstantWorkRetirement()
        }
    }

    /// Joins active retirement and every targeted catalog writer before explicit account teardown
    /// closes stores. Unlike expiration retirement, this path has no deadline.
    private func joinInstantWorkTasksForShutdown() async {
        let retirement = instantWorkRetirementTask
        await retirement?.value

        let activeItems = instantWorkItems
        instantWorkItems.removeAll(keepingCapacity: false)
        for item in activeItems {
            item.task.cancel()
            await item.task.value
        }
        isRetiringInstantWork = false
        instantWorkRetirementRunID = nil
    }

    private func finishSync(runID: String) async {
        guard activeRunID == runID else { return }
        // The pass is still the lock owner while its final enqueue and every targeted writer retire.
        // This also rejects new targeted work during the re-entrant waits below.
        isRetiringInstantWork = true
        instantWorkRetirementRunID = runID
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        instantEnqueueTask?.cancel()
        let activeEnqueue = instantEnqueueTask
        instantEnqueueTask = nil
        await activeEnqueue?.value
        guard activeRunID == runID else { return }
        await retireInstantWorkTask()
        guard activeRunID == runID, !isRetiringInstantWork else { return }
        await completeSyncRun(runID: runID)
    }

    private func finishInstantWorkRetirement() async {
        let runID = instantWorkRetirementRunID
        instantWorkRetirementTask = nil
        instantWorkRetirementRunID = nil
        isRetiringInstantWork = false
        guard let runID else { return }
        await completeSyncRun(runID: runID)
    }

    private func completeSyncRun(runID: String) async {
        let stopTask = runnerStopRunID == runID ? runnerStopTask : nil
        await stopTask?.value
        guard activeRunID == runID else { return }
        // A pass can start during the final projection below; this pass keeps its own start values.
        let ended = EndedPass(
            owner: activeRunOwner ?? .foreground, stopped: stopTask != nil, waitedForWiFi: passWaitedForWiFi,
            pausedByPolicy: passPausedByPolicy, startedAt: runStartedAt, progressAtStart: progressAtRunStart,
            stopRequestedAt: runnerStopRequestedAt)
        if !isShuttingDown,
            let lock = lockStore?.currentLock(), lock.runID == runID,
            lock.owner == .manual || activeRunCarriesManualRetry
        {
            manualWiFiRetryPending = passPausedByPolicy
        }
        activeRunCarriesManualRetry = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lockStore?.release(runID: runID)
        let scannedOnly = activeRefreshScan != nil
        activeRunID = nil
        activeRunOwner = nil
        activeRefreshScan = nil
        isSyncing = false
        #if DEBUG
            completingSyncRuns += 1
            defer {
                completingSyncRuns -= 1
                if completingSyncRuns == 0 {
                    let waiters = syncRunCompletionWaiters
                    syncRunCompletionWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
        #endif
        updateIdleTimerIfNeeded()
        isScanning = false
        syncTask = nil
        if runnerStopRunID == runID {
            runnerStopTask = nil
            runnerStopRunID = nil
        }
        let shouldRestart = pendingSyncAfterStop && isEnabled && accessState.allowsBackup
        pendingSyncAfterStop = false
        guard !isShuttingDown else {
            logPassEnd(ended, progress: lastProjectedProgress)
            logNext(.shutdown)
            return
        }
        // Every runner event this pass already submitted must settle in the projector before the
        // decision projection below runs. A starved stream consumer could otherwise deliver one
        // last stale runner snapshot after that projection, re-stamping `nextAutomaticAttemptAt`.
        await statusProjector?.drainSubmittedEvents()
        let request = nextStatusProjectionRequest()
        let finalProjection = await statusProjector?.projectNow(
            context: request.context,
            generation: statusProjectionGeneration,
            revision: request.revision
        )
        logPassEnd(ended, progress: finalProjection?.progress ?? lastProjectedProgress)
        guard activeRunID == nil else {
            logNext(.anotherPassStarted)
            return
        }
        guard queueStore?.isOperational() == true, catalogStore?.isOperational() == true else {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            logNext(.localStateUnavailable)
            return
        }
        var finalProgress = finalProjection?.progress ?? lastProjectedProgress
        let waitedForWiFi = passWaitedForWiFi
        if waitedForWiFi {
            // The runner's last callback can reach the projector after this projection; keep its Wi-Fi wait.
            finalProgress.isPausedByPolicy = true
            finalProgress.isWaitingForWiFi = true
        }
        // A refresh scan uploads nothing, so it never counts as a pass without progress. In the background it plans and
        // starts no pass. A scene that came to the foreground during the scan found the pass busy: its pass starts now.
        if scannedOnly {
            let inForeground = !runtimeSignals.current().isAppInBackground
            logNext(inForeground ? .foregroundPassAfterScan : .none)
            if inForeground { syncNow() }
            return
        }
        let currentBackedUp = finalProgress.backedUp
        if currentBackedUp > backedUpAtRunStart {
            consecutiveNoProgressRuns = 0
        } else if !waitedForWiFi {
            // A Wi-Fi wait is a setting, not a failure: it must not stretch the fallback during a long wait.
            consecutiveNoProgressRuns = min(16, consecutiveNoProgressRuns + 1)
        }
        // Wi-Fi or Ethernet returned, or the setting was turned on, while this pass still ran (for example during
        // its scan). Start the next pass now instead of keeping "Waiting for Wi-Fi" until the fallback.
        let wiFiWaitEnded = (waitedForWiFi || manualWiFiRetryPending) && runtimeSignals.current().canEndWiFiWait
        // iOS ends a background window, and the short background time, with a stop and then suspends the app. A pass that
        // a stop ended while no scene is in the foreground therefore starts nothing more; the next window or the next
        // foreground start continues from the queue and the library's change history.
        if ended.stopped, runtimeSignals.current().isAppInBackground {
            logNext(.stoppedInBackground)
            return
        }
        if shouldRestart {
            logNext(.restartAfterChange)
            syncNow()
        } else {
            if wiFiWaitEnded {
                logNext(.wiFiWaitEnded)
                if startSync(owner: .foreground) != nil { return }
            }
            scheduleAutoResumeIfOutstanding(progress: finalProgress)
            logNext(autoResumeTask == nil ? .none : .automaticResume)
        }
    }

    /// Schedules exactly one wake at the queue's earliest typed eligibility date. If an
    /// unexpected row has no date, use the shared exponential retry policy and increase it only after
    /// a no-progress run. This keeps recovery persistent without hot-looping empty passes.
    private func scheduleAutoResumeIfOutstanding(progress: BackupSyncProgress? = nil) {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        guard !isShuttingDown, isEnabled, !isUserPaused, accessState.allowsBackup, !isSyncing,
            queueStore?.isOperational() == true,
            catalogStore?.isOperational() == true
        else { return }
        let p = progress ?? lastProjectedProgress
        guard p.hasOutstandingWork else { return }  // No work remains.
        let currentTime = Date()
        if p.isPausedByPolicy, p.isWaitingForWiFi, runtimeSignals.current().waitsForWiFi {
            // Wi-Fi returning or the mobile-data setting ends this wait and starts the next pass; a timer would only
            // repeat the whole pass while every upload still waits for Wi-Fi. A wait that already ended keeps the
            // timer, because its restart could not start.
            nextAutomaticAttemptAt = nil
            status = BackupStatus(
                progress: p, isScanning: false, isUserPaused: isUserPaused,
                executionOpportunityIssue: executionOpportunityIssue
            )
            return
        }
        guard
            let wakeAt = BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: p.outstanding.count,
                queueDate: p.outstanding.nextAttemptAt,
                consecutiveNoProgressRuns: consecutiveNoProgressRuns,
                now: currentTime,
                retryPolicy: retryPolicy
            )
        else { return }
        nextAutomaticAttemptAt = wakeAt
        var scheduledProgress = p
        scheduledProgress.outstanding.nextAttemptAt = wakeAt
        status = BackupStatus(
            progress: scheduledProgress, isScanning: false, isUserPaused: isUserPaused,
            executionOpportunityIssue: executionOpportunityIssue
        )
        autoResumeTask = Task { @MainActor [weak self] in
            let delay = max(0, wakeAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isEnabled, !self.isUserPaused, !self.isSyncing else { return }
            self.nextAutomaticAttemptAt = nil
            self.syncNow()
        }
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    /// The catalog sync throws technical English text. People see the localized local-state message, as for the
    /// missing-source recovery; the technical text stays in the diagnostics.
    private func reportScanFailure(_ error: Error) {
        PhotoDiagnostics.shared.increment("backup.scan.failed")
        let detail: String
        if let error = error as? UploadError, case .backend(let text) = error {
            detail = text
        } else {
            // The domain and the code are fixed values; the description of a system error can hold a path.
            let bridged = error as NSError
            detail = "\(bridged.domain) \(bridged.code)"
        }
        PhotoDiagnostics.shared.emitDebug("BackupSync", ["scanError": detail])
        reportSyncMessage(L10n.string("backup.error_local_state_unavailable"))
    }

    private func refreshFromQueue() {
        guard let statusProjector else { return }
        let request = nextStatusProjectionRequest()
        let generation = statusProjectionGeneration
        Task {
            _ = await statusProjector.projectNow(
                context: request.context,
                generation: generation,
                revision: request.revision
            )
        }
    }

    private func nextStatusProjectionRequest() -> (
        context: BackupStatusProjectionContext,
        revision: UInt64
    ) {
        statusProjectionRevision &+= 1
        return (projectionContext, statusProjectionRevision)
    }

    private func noteUploadedLibraryMutation(_ uploadedCount: Int) {
        guard let previous = lastObservedUploadedCount else {
            lastObservedUploadedCount = uploadedCount
            return
        }
        if uploadedCount > previous {
            uploadedLibraryMutationRevision &+= 1
        }
        lastObservedUploadedCount = uploadedCount
    }

    /// Keeps the display awake while a backup pass is actively running (iOS host implements
    /// `idleTimerHook`). When idle, paused, or disabled the hook receives `false` so the screen
    /// auto-locks. This method is called at every transition of `isSyncing` to guarantee the timer state
    /// stays in sync and never pins the display after backup ends, even on cancelled/exiting paths.
    private func updateIdleTimerIfNeeded() {
        idleTimerHook?(isSyncing)
    }

    /// Non-secret debugging hint recorded on the lock (platform + pid); never load-bearing.
    private static var processContext: String {
        let process = ProcessInfo.processInfo
        #if os(macOS)
            let platform = "macos"
        #else
            let platform = "ios"
        #endif
        return "\(platform)/pid-\(process.processIdentifier)"
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if pid == Int32(ProcessInfo.processInfo.processIdentifier) { return true }
        #if canImport(Darwin)
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        #else
            return true
        #endif
    }
}

/// One-shot completion flag shared between the index scan and the concurrent reconcile loop: the scan
/// sets it when it finishes (or gives up) so the reconcile loop knows to make one final drain pass and
/// stop, instead of polling forever.
actor BackupScanSignal {
    private var done = false
    /// Wakes the reconcile loop between drains.
    nonisolated let wake = BackupWorkWake()
    func markDone() async {
        done = true
        await wake.signal()
    }
    func isDone() -> Bool { done }
}

/// Wakes one waiting loop when its work may have changed: a committed queue write, the end of a scan or pass, a
/// persisted due date, or cancellation. Wakes that arrive while nobody waits count as one, so a burst of writes
/// costs one more read instead of one per write.
actor BackupWorkWake {
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// True while a loop waits for its next wake.
    var isWaiting: Bool { waiter != nil }

    func signal() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            pending = true
        }
    }

    /// Returns after the next signal, at once when one is pending, or after `delay` seconds on `clock`.
    func wait(atMost delay: TimeInterval? = nil, clock: any BackupSchedulerClock) async {
        guard !pending, !Task.isCancelled else {
            pending = false
            return
        }
        assert(waiter == nil, "one loop waits on a wake at a time")
        let timer = delay.map { delay in
            Task { [weak self] in
                guard (try? await clock.sleep(for: max(0, delay))) != nil else { return }
                await self?.signal()
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.signal() }
        }
        timer?.cancel()
        pending = false
    }

    /// Feeds every committed queue write into this wake until the caller cancels the returned task.
    nonisolated func follow(_ changes: AsyncStream<UploadBackupSyncQueueChange>) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in changes {
                await self?.signal()
            }
        }
    }
}

/// Numbers the reads of one open problem list (the automatic follow, a retry, a decision refresh) in the order in
/// which they start. Only the newest read of a list applies or reports, so an older result that arrives late never
/// replaces a newer one, and a list that shows "loading" always has a reader that ends in rows, "empty", or
/// "unavailable". Each open list has its own order; reads of different lists never overtake each other.
@MainActor
public final class BackupProblemListReadOrder {
    private var latest: UInt64 = 0

    public init() {}

    func begin() -> UInt64 {
        latest &+= 1
        return latest
    }

    func isLatest(_ generation: UInt64) -> Bool { generation == latest }
}
