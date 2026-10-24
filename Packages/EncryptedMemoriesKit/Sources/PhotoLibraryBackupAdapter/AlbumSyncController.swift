import AlbumSyncCore
import Foundation
import Observation
import PhotosCore
import UploadCore

/// The shared album-sync orchestrator for iOS, iPadOS, and macOS. It composes the
/// universal engine (`AlbumSyncRunner`) with PhotoKit pieces (album source, targeted backup
/// executor) and injected backend operations. Platform apps contribute dependency
/// injection, permission UI, and settings screens.
///
/// UX model: the user picks albums in a dedicated picker (search + multi-select); Settings shows
/// that selection. Deselecting removes the album from sync but keeps its Proton mapping, so
/// re-selecting reuses the same remote album. "Sync now" runs the whole selection sequentially.
///
/// Consent contract: nothing scans or syncs on its own. Loading the album list and syncing are
/// called from explicit user actions; the album list requires photo access (full or limited).
@MainActor
@Observable
public final class AlbumSyncController {
    public struct Configuration {
        /// Per-account directory holding the sync stores (sign-out purge covers it wholesale).
        public var accountDataDirectory: URL
        public var databasePolicy: LibraryDatabasePolicy

        var makeChangeMonitor: (URL) -> PhotoLibraryChangeMonitor = { PhotoLibraryChangeMonitor(tokenURL: $0) }
        var currentAccessState: () -> PhotoBackupAccessState = PhotoLibraryAuthorization.currentState
        var changeSleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        var localSource: any AlbumSyncLocalAlbumSource = PhotoKitAlbumSource()

        public init(accountDataDirectory: URL, databasePolicy: LibraryDatabasePolicy) {
            self.accountDataDirectory = accountDataDirectory
            self.databasePolicy = databasePolicy
        }
    }

    /// One row of the Settings list: a selected album with its live library info (when photo
    /// access allowed reading it this session) and its persisted sync state.
    public struct SelectedAlbum: Identifiable, Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case notSynced
            case synced(Date)
            /// The album vanished from the library (deleted or dropped from a limited selection).
            case missingLocally
            /// A same-name Proton album exists; the user has not answered the dialog yet.
            case needsDecision
        }

        public let id: String
        public var title: String
        /// nil until the library was read this session (needs photo access).
        public var assetCount: Int?
        public var state: State
        /// Photos of the last run that could not be backed up or attached.
        public var needsAttentionCount: Int
        /// The last run's photo list with reasons. Empty before the first run of this build.
        public var problems: [BackupFailedItem] = []

        public var hasNeedsAttention: Bool { needsAttentionCount > 0 }
        /// The row opens the shared problem list only when that list has photos.
        public var showsProblemList: Bool { hasNeedsAttention && !problems.isEmpty }

        /// Shared en/de wording (PhotosCore catalog) - platforms never re-invent these states.
        public var localizedStateDescription: String {
            switch state {
            case .notSynced:
                L10n.string("albumsync.state_not_synced")
            case .synced(let date):
                L10n.string("albumsync.state_synced \(date.formatted(.relative(presentation: .named)))")
            case .missingLocally:
                L10n.string("albumsync.state_missing")
            case .needsDecision:
                L10n.string("albumsync.state_needs_decision")
            }
        }

        /// Row-level status with the correct priority. A previous failed photo means this album is
        /// not cleanly synced, even when `lastSyncedAt` is recent.
        public var localizedRowStatusDescription: String {
            guard hasNeedsAttention else { return localizedStateDescription }
            // A photo that is in the album while its backup is incomplete is no photo "not in the album".
            return hasIncompletePhotos
                ? L10n.string("albumsync.detail_needs_attention \(needsAttentionCount)")
                : L10n.string("albumsync.detail_not_in_album \(needsAttentionCount)")
        }

        /// The last run listed a photo that is in the album while a part of it is not backed up, for example the
        /// video of a Live Photo.
        public var hasIncompletePhotos: Bool { Self.containsIncompletePhotos(problems) }

        /// Title of the shared problem list for an album's last-run photos.
        public static func localizedProblemSheetTitle(for problems: [BackupFailedItem]) -> String {
            containsIncompletePhotos(problems)
                ? L10n.string("albumsync.problem_sheet_title_attention")
                : L10n.string("albumsync.problem_sheet_title")
        }

        private static func containsIncompletePhotos(_ problems: [BackupFailedItem]) -> Bool {
            problems.contains { $0.id.hasPrefix(AlbumSyncProblemList.incompleteIDPrefix) }
        }
    }

    /// A same-name Proton album exists and no mapping does - the user must decide. Published for
    /// the platform UI to present as a dialog; resolved via `resolveConflict(useExisting:)`.
    public struct PendingConflict: Sendable, Equatable {
        public let album: LocalAlbumSummary
        public let existing: [AlbumSyncRemoteAlbum]
    }

    public private(set) var accessState: PhotoBackupAccessState
    /// Albums the user selected for sync. Settings shows this list.
    public private(set) var selectedAlbums: [SelectedAlbum] = []
    /// All local albums, for the picker sheet. Loaded on demand (explicit user action).
    public private(set) var availableAlbums: [LocalAlbumSummary] = []
    public private(set) var isLoadingAlbums = false
    public private(set) var progress = AlbumSyncProgress()
    public private(set) var isSyncing = false
    public private(set) var pendingConflict: PendingConflict?
    public private(set) var lastMessage: String?
    /// How the hosts show `lastMessage`: a Stop result is information, everything else an error.
    public private(set) var lastMessageStyle: MessageStyle = .error

    public enum MessageStyle: Sendable, Equatable {
        case error
        case information
    }

    /// False when the mapping store or the dedupe manifest could not open - sync then refuses to
    /// run rather than risking duplicate albums or duplicate uploads.
    public var isAvailable: Bool { runner != nil && mappingStore?.isOperational() == true }

    /// The ids currently in the persisted selection (for pre-checking the picker).
    public var selectedAlbumIDs: Set<String> { Set(selectedAlbums.map(\.id)) }

    private let runner: AlbumSyncRunner?
    private let backupExecutor: PhotoAlbumBackupExecutor?
    private let remoteLinkLookup: (any AlbumSyncRemoteLinkLookup)?
    private let localSource: any AlbumSyncLocalAlbumSource
    private let mappingStore: AlbumSyncMappingStore?
    private let lastRunStore: AlbumSyncLastRunStore
    private var changeSubscription: PhotoLibraryChangeMonitor.Subscription?
    private let changeMonitor: PhotoLibraryChangeMonitor
    private let currentAccessState: () -> PhotoBackupAccessState
    private let changeSleep: @Sendable (UInt64) async throws -> Void
    private var syncTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
    private var queuedAlbumIDs: [String] = []
    /// Unanswered same-name conflicts by album id (one dialog at a time; rows offer "Decide…").
    private var openConflicts: [String: [AlbumSyncRemoteAlbum]] = [:]
    /// True once `availableAlbums` was read this session - only then can "missing locally" be
    /// claimed honestly.
    private var libraryWasRead = false
    private var lastProgressUpdate = Date.distantPast
    private var isObservingChanges = false
    private var isShuttingDown = false
    private var changePendingDuringSync = false
    private var remoteAlbumsChangedDuringBatch = false
    private var onRemoteAlbumsChanged: (@MainActor @Sendable () -> Void)?
    /// Whether the person pressed Stop during the current batch.
    private var stopState = AlbumSyncStopState()

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        remoteOps: any AlbumSyncRemoteAlbumOps
    ) {
        currentAccessState = configuration.currentAccessState
        changeSleep = configuration.changeSleep
        localSource = configuration.localSource
        accessState = currentAccessState()

        let directory = configuration.accountDataDirectory
        changeMonitor = configuration.makeChangeMonitor(directory.appendingPathComponent("album-sync-change-token.v1"))
        let mappingStore = AlbumSyncMappingStore(
            url: directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName),
            policy: configuration.databasePolicy
        )
        self.mappingStore = mappingStore
        lastRunStore = AlbumSyncLastRunStore(directory: directory)

        let lookup = UploadManifestRemoteLinkLookup(
            manifestURL: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName),
            policy: configuration.databasePolicy
        )
        remoteLinkLookup = lookup

        if let mappingStore, let lookup, let identityResolver {
            let executor = PhotoAlbumBackupExecutor(
                accountDataDirectory: directory,
                databasePolicy: configuration.databasePolicy,
                identityResolver: identityResolver,
                uploader: uploader
            )
            backupExecutor = executor
            runner = AlbumSyncRunner(
                localSource: localSource,
                backup: executor,
                remoteOps: remoteOps,
                linkLookup: lookup,
                mappingStore: mappingStore
            )
        } else {
            backupExecutor = nil
            runner = nil
        }

        reloadSelection()
        Task { [weak self, lastRunStore] in
            await lastRunStore.load()
            self?.reloadSelection()
        }
        startObservingChangesIfNeeded(scheduleCatchUp: true)
        if let runner {
            Task {
                await runner.setOnProgress { snapshot in
                    Task { @MainActor [weak self] in self?.applyProgress(snapshot) }
                }
            }
        }
    }

    /// Platform shells call this once at composition time to refresh their visible Proton album
    /// lists after this shared controller creates or mutates a remote album. The callback is UI
    /// invalidation only; sync correctness never depends on it.
    public func setRemoteAlbumsChangedHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        onRemoteAlbumsChanged = handler
    }

    // MARK: - Album list (explicit user action; requests photo access)

    /// Loads all local albums for the picker. The first call may present the system photo-access
    /// prompt, so only invoke from an explicit user action (opening the picker).
    public func loadAvailableAlbums() async {
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }
        accessState = await PhotoLibraryAuthorization.request()
        guard accessState.allowsBackup else { return }
        do {
            availableAlbums = try await localSource.listAlbums()
            libraryWasRead = true
        } catch {
            setMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        reloadSelection()
        startObservingChangesIfNeeded()
    }

    public func refreshAccessState() {
        accessState = currentAccessState()
    }

    // MARK: - Selection

    /// Applies the picker result: `ids` becomes the new selection. Removed albums keep their
    /// Proton mapping (re-selecting reuses the same remote album); nothing remote is touched.
    public func applySelection(_ ids: Set<String>) {
        guard let mappingStore, mappingStore.isOperational() else {
            reportMappingStoreUnavailable()
            return
        }
        let current = selectedAlbumIDs
        let byID = Dictionary(availableAlbums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for added in ids.subtracting(current) {
            guard let album = byID[added] else { continue }
            guard
                mappingStore.addSelection(
                    AlbumSyncSelection(
                        localAlbumID: album.id,
                        title: album.title,
                        addedAt: Date()
                    ))
            else {
                reportMappingStoreUnavailable()
                break
            }
        }
        for removed in current.subtracting(ids) {
            guard mappingStore.removeSelection(localAlbumID: removed) else {
                reportMappingStoreUnavailable()
                break
            }
            openConflicts[removed] = nil
        }
        reloadSelection()
        startObservingChangesIfNeeded()
    }

    /// The row's ✕: stop syncing this album. Keeps the mapping - never touches Proton.
    public func removeFromSelection(_ albumID: String) {
        guard mappingStore?.removeSelection(localAlbumID: albumID) == true else {
            reportMappingStoreUnavailable()
            return
        }
        openConflicts[albumID] = nil
        queuedAlbumIDs.removeAll { $0 == albumID }
        if pendingConflict?.album.id == albumID { pendingConflict = nil }
        reloadSelection()
    }

    // MARK: - Sync lifecycle

    /// Syncs every selected album, sequentially. Albums missing from the library are skipped
    /// honestly (their row says so); same-name conflicts pause only the affected album.
    public func syncSelected() {
        startObservingChangesIfNeeded()
        let ids =
            selectedAlbums
            .filter { $0.state != .missingLocally }
            .map(\.id)
        enqueue(ids)
    }

    /// Re-sync one album from its row.
    public func syncNow(albumID: String) {
        startObservingChangesIfNeeded()
        enqueue([albumID])
    }

    /// The user answered the same-name dialog. "Use existing" persists the mapping (that IS the
    /// decision) and queues the album; cancel leaves it selected but unsynced.
    public func resolveConflict(useExisting remoteAlbumID: String?) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        openConflicts[conflict.album.id] = nil
        if let remoteAlbumID, let mappingStore {
            guard
                mappingStore.upsert(
                    AlbumSyncMapping(
                        localAlbumID: conflict.album.id,
                        remoteAlbumID: remoteAlbumID,
                        title: conflict.album.title,
                        createdAt: Date()
                    ))
            else {
                reportMappingStoreUnavailable()
                reloadSelection()
                return
            }
            enqueue([conflict.album.id])
        }
        reloadSelection()
    }

    /// Re-opens the dialog for a row whose conflict was dismissed earlier.
    public func presentConflict(albumID: String) {
        guard let existing = openConflicts[albumID],
            let album = selectedAlbums.first(where: { $0.id == albumID })
        else { return }
        pendingConflict = PendingConflict(
            album: LocalAlbumSummary(id: album.id, title: album.title, assetCount: album.assetCount ?? 0),
            existing: existing
        )
    }

    public func stopSync() {
        stopState.stopPressed(isSyncing: isSyncing, queuedAlbums: queuedAlbumIDs.count)
        queuedAlbumIDs.removeAll()
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        changePendingDuringSync = false
        guard let runner else { return }
        Task { await runner.stop() }
    }

    /// Ordered sign-out boundary for the album mapping database and any per-run backup stores.
    public func shutdown() async {
        isShuttingDown = true
        changeSubscription?.cancel()
        changeSubscription = nil
        isObservingChanges = false
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        queuedAlbumIDs.removeAll()
        changePendingDuringSync = false
        let activeSync = syncTask
        syncTask?.cancel()
        await runner?.stop()
        await backupExecutor?.stop()
        await activeSync?.value
        await remoteLinkLookup?.shutdown()
        mappingStore?.close()
        onRemoteAlbumsChanged = nil
    }

    // MARK: - Batch engine

    private func enqueue(_ ids: [String]) {
        guard !isShuttingDown, runner != nil, !ids.isEmpty else { return }
        for id in ids where !queuedAlbumIDs.contains(id) {
            queuedAlbumIDs.append(id)
        }
        if isSyncing { stopState.albumsAdded(ids) }
        startBatchIfIdle()
    }

    private func startBatchIfIdle() {
        guard !isShuttingDown, let runner, !isSyncing, !queuedAlbumIDs.isEmpty else { return }
        isSyncing = true
        remoteAlbumsChangedDuringBatch = false
        stopState.batchStarted()
        setMessage(nil)

        syncTask = Task { [weak self] in
            while let album = self?.dequeueNextAlbum() {
                do {
                    let report = try await runner.sync(album: album, resolution: .automatic)
                    self?.recordFinishedRun(report.problems, albumID: album.id)
                    self?.remoteAlbumsChangedDuringBatch = true
                    self?.showStopResult(after: .finished(report))
                } catch let error as AlbumSyncError {
                    switch error {
                    case .nameConflict(let existing):
                        self?.recordConflict(album: album, existing: existing)
                    case .stopped:
                        self?.dropQueueAfterStop()
                        self?.showStopResult(after: .stopped)
                        self?.reloadSelection()
                    default:
                        self?.setMessage(error.errorDescription)
                        self?.reloadSelection()
                    }
                } catch {
                    if self?.stopState.endsAsStop(error) == true {
                        self?.dropQueueAfterStop()
                        self?.showStopResult(after: .cancelled)
                    } else {
                        self?.setMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                    self?.reloadSelection()
                }
            }
            self?.finishSync()
        }
    }

    /// After a Stop, the message line says that the sync stopped, or that the album finished when the batch that was
    /// already sent completed it. Without a Stop nothing changes.
    private func showStopResult(after outcome: AlbumSyncStopState.Outcome) {
        let current = AlbumSyncStopState.Message(text: lastMessage, style: lastMessageStyle)
        guard let next = stopState.message(after: outcome, current: current) else { return }
        setMessage(next.text, style: next.style)
    }

    func setMessage(_ message: String?, style: MessageStyle = .error) {
        lastMessage = message
        lastMessageStyle = style
    }

    /// A stopped album ends: the waiting albums go, except the ones added after Stop.
    private func dropQueueAfterStop() {
        queuedAlbumIDs.removeAll { !stopState.keepsAfterStop($0) }
    }

    private func dequeueNextAlbum() -> LocalAlbumSummary? {
        while !queuedAlbumIDs.isEmpty {
            let id = queuedAlbumIDs.removeFirst()
            guard let row = selectedAlbums.first(where: { $0.id == id }) else { continue }
            if libraryWasRead, row.state == .missingLocally { continue }
            if stopState.nextAlbumStarted(), lastMessageStyle == .information { setMessage(nil) }
            return LocalAlbumSummary(id: row.id, title: row.title, assetCount: row.assetCount ?? 0)
        }
        return nil
    }

    private func recordConflict(album: LocalAlbumSummary, existing: [AlbumSyncRemoteAlbum]) {
        openConflicts[album.id] = existing
        if pendingConflict == nil {
            pendingConflict = PendingConflict(album: album, existing: existing)
        }
        reloadSelection()
    }

    private func finishSync() {
        isSyncing = false
        guard !isShuttingDown else { return }
        reloadSelection()
        if remoteAlbumsChangedDuringBatch {
            remoteAlbumsChangedDuringBatch = false
            onRemoteAlbumsChanged?()
        }
        if changePendingDuringSync {
            changePendingDuringSync = false
            scheduleChangeDrivenSync()
        }
    }

    // MARK: - Change-driven sync for selected albums

    private func startObservingChangesIfNeeded(scheduleCatchUp: Bool = false) {
        guard !isShuttingDown, accessState.allowsBackup, !selectedAlbums.isEmpty else { return }
        if !isObservingChanges {
            isObservingChanges = true
            changeSubscription = changeMonitor.subscribe { [weak self] in
                Task { @MainActor in self?.scheduleChangeDrivenSync() }
            }
        }
        if scheduleCatchUp {
            scheduleChangeDrivenSync()
        }
    }

    private func scheduleChangeDrivenSync() {
        guard !isShuttingDown, accessState.allowsBackup, !selectedAlbums.isEmpty else { return }
        if isSyncing {
            changePendingDuringSync = true
            return
        }
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self, changeSleep] in
            try? await changeSleep(3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshLocalAlbumsForAutomaticSync()
            await MainActor.run { [weak self] in
                guard let self, !self.isShuttingDown, self.accessState.allowsBackup,
                    !self.selectedAlbums.isEmpty, !self.isSyncing
                else { return }
                self.syncSelected()
            }
        }
    }

    private func refreshLocalAlbumsForAutomaticSync() async {
        guard accessState.allowsBackup else { return }
        do {
            availableAlbums = try await localSource.listAlbums()
            libraryWasRead = true
            reloadSelection()
        } catch {
            setMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Row derivation

    private func reloadSelection() {
        guard let mappingStore else {
            selectedAlbums = []
            return
        }
        let mappings = Dictionary(
            mappingStore.allMappings().map { ($0.localAlbumID, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let live = Dictionary(availableAlbums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        selectedAlbums = mappingStore.selections().map { selection in
            let liveAlbum = live[selection.localAlbumID]
            let mapping = mappings[selection.localAlbumID]
            let state: SelectedAlbum.State
            if openConflicts[selection.localAlbumID] != nil {
                state = .needsDecision
            } else if libraryWasRead, liveAlbum == nil {
                state = .missingLocally
            } else if let synced = mapping?.lastSyncedAt {
                state = .synced(synced)
            } else {
                state = .notSynced
            }
            return SelectedAlbum(
                id: selection.localAlbumID,
                title: liveAlbum?.title ?? selection.title,
                assetCount: liveAlbum?.assetCount,
                state: state,
                needsAttentionCount: mapping?.lastFailedCount ?? 0,
                problems: lastRunStore.items(albumID: selection.localAlbumID)
            )
        }
    }

    // MARK: - Progress mirror (throttled, phase changes immediate)

    func applyProgress(_ snapshot: AlbumSyncProgress) {
        guard snapshot != progress else { return }
        let now = Date()
        if snapshot.phase == progress.phase, now.timeIntervalSince(lastProgressUpdate) < 0.15 {
            return
        }
        lastProgressUpdate = now
        progress = snapshot
    }

    /// Only a finished run replaces the list; a stopped or failed run keeps the previous one. The runner has stored
    /// the new count before it reports the end of the run, so the row reloads only after the list is stored: it never
    /// combines the new count with the previous run's list.
    func recordFinishedRun(_ problems: [BackupFailedItem], albumID: String) {
        lastRunStore.record(problems, albumID: albumID)
        reloadSelection()
    }

    private func reportMappingStoreUnavailable() {
        setMessage(AlbumSyncError.mappingStoreUnavailable.errorDescription)
    }

    #if DEBUG
        /// Seeds one synced album whose last run left photos outside the Proton album, on the offline
        /// UI-test account. It uses the real mapping store and last-run file, without PhotoKit or a network.
        public func installNotInAlbumFixtureForTesting(albumID: String, title: String) -> Bool {
            guard let mappingStore, mappingStore.isOperational() else { return false }
            let items = AlbumSyncProblemList.items(
                missingIdentifiers: ["fixture-network"],
                attachFailedIdentifiers: ["fixture-attach"],
                backup: AlbumSyncBackupReport(
                    total: 2, backedUp: 1, failed: 1, sourceMissing: 0, skippedRemoteDeletion: 0,
                    problems: [
                        "fixture-network": BackupFailedItem(
                            id: "fixture-network", filename: "network fixture.heic",
                            reason: L10n.string("backup.issue_network"), isPermanent: false, issue: .network)
                    ],
                    filenames: ["fixture-attach": "attach fixture.heic"]))
            let now = Date()
            guard
                mappingStore.addSelection(AlbumSyncSelection(localAlbumID: albumID, title: title, addedAt: now)),
                mappingStore.upsert(
                    AlbumSyncMapping(
                        localAlbumID: albumID, remoteAlbumID: "fixture-remote-album", title: title, createdAt: now,
                        lastSyncedAt: now, lastFailedCount: items.count))
            else { return false }
            lastRunStore.record(items, albumID: albumID)
            // Keep the fixture independent of PhotoKit authorization on the simulator.
            accessState = .denied
            reloadSelection()
            return true
        }
    #endif
}
