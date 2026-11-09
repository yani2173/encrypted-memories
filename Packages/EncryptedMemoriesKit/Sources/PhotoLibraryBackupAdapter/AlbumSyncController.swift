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
        var backupExecutorOverride: (any AlbumSyncBackupExecuting)? = nil
        var recoveryCatalog: @Sendable (String) -> any UploadBackupAssetCatalog = {
            PhotoLibraryBackupCatalog(localIdentifiers: [$0])
        }
        var recoveryResourceResolver: (any BackupResourceResolving)?
        var bulkActionPause: @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }

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

    private let remoteOps: any AlbumSyncRemoteAlbumOps
    private let identityResolver: (any UploadIdentityResolving)?
    private let recoveryCatalog: @Sendable (String) -> any UploadBackupAssetCatalog
    private let recoveryResourceResolver: any BackupResourceResolving
    private var recoveryTask: Task<AlbumSyncPhotoRecovery.Result, any Error>?
    private var recoveryContextTask: Task<AlbumSyncPhotoRecovery.Context?, any Error>?
    private var recoveryGeneration = UUID()
    private var recoveryContexts: [String: AlbumSyncPhotoRecovery.Context] = [:]
    private struct FinishedProblems {
        let id = UUID()
        let items: [BackupFailedItem]
    }
    private var finishedProblems: [String: FinishedProblems] = [:]
    public private(set) var problemListRevision = UUID()
    private let runner: AlbumSyncRunner?
    private let backupExecutor: (any AlbumSyncBackupExecuting)?
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
        remoteOps: any AlbumSyncRemoteAlbumOps,
        tagAdder: (any PhotoTagAdding)? = nil
    ) {
        self.remoteOps = remoteOps
        self.identityResolver = identityResolver
        bulkPhotoActions = BulkPhotoActionRunner(sleep: configuration.bulkActionPause)
        recoveryCatalog = configuration.recoveryCatalog
        let recoveryTempStore = BackupTempFileStore(
            directory: configuration.accountDataDirectory.appendingPathComponent("album-sync-restore-temp"))
        recoveryTempStore.sweep()
        recoveryResourceResolver =
            configuration.recoveryResourceResolver
            ?? PhotoLibraryResourceResolver(tempStore: recoveryTempStore)
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
            let executor =
                configuration.backupExecutorOverride
                ?? PhotoAlbumBackupExecutor(
                    accountDataDirectory: directory,
                    databasePolicy: configuration.databasePolicy,
                    identityResolver: identityResolver,
                    uploader: uploader,
                    tagAdder: tagAdder
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

    // MARK: - Selection

    /// Applies the picker result: `ids` becomes the new selection. Removed albums keep their
    /// Proton mapping (re-selecting reuses the same remote album); nothing remote is touched.
    public func applySelection(_ ids: Set<String>) {
        invalidateRecovery()
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
            recoveryContexts[removed] = nil
            finishedProblems[removed] = nil
            problemListRevision = UUID()
            openConflicts[removed] = nil
        }
        reloadSelection()
        startObservingChangesIfNeeded()
    }

    /// The row's ✕: stop syncing this album. Keeps the mapping - never touches Proton.
    public func removeFromSelection(_ albumID: String) {
        invalidateRecovery()
        recoveryContexts[albumID] = nil
        guard mappingStore?.removeSelection(localAlbumID: albumID) == true else {
            reportMappingStoreUnavailable()
            return
        }
        finishedProblems[albumID] = nil
        problemListRevision = UUID()
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

    /// The full finished run stays in this session; after relaunch only the saved cache is available.
    public func problemListItems(albumID: String) -> [BackupFailedItem] {
        guard selectedAlbumIDs.contains(albumID) else { return [] }
        return finishedProblems[albumID]?.items ?? lastRunStore.items(albumID: albumID)
    }

    public func problemSnapshot(albumID: String) async -> BackupProblemSnapshot? {
        guard !isShuttingDown, selectedAlbumIDs.contains(albumID) else { return nil }
        let revision = problemListRevision
        let items = problemListItems(albumID: albumID)
        let snapshot = await Task.detached(priority: .utility) {
            BackupProblemSnapshot.album(items: items)
        }.value
        guard !isShuttingDown, selectedAlbumIDs.contains(albumID), revision == problemListRevision else { return nil }
        return snapshot
    }

    public func makeProblemListSession(albumID: String) -> BackupProblemListSession {
        BackupProblemListSession(
            fixedActionMessage: { [weak self] in
                guard let self, !isShuttingDown, selectedAlbumIDs.contains(albumID),
                    lastMessage == L10n.string("albumsync.error_restore_photo")
                else { return nil }
                return lastMessage
            }, read: { [weak self] in await self?.problemSnapshot(albumID: albumID) })
    }

    /// This finished-run token does not change when later work is stopped.
    public func problemListID(albumID: String) -> UUID? {
        finishedProblems[albumID]?.id
    }

    /// Native Restore controls can announce their disabled state before a tap.
    public func canRestorePhotos(albumID: String) -> Bool {
        !isShuttingDown && !isSyncing && recoveryTask == nil && !isBulkRestoring
            && selectedAlbumIDs.contains(albumID) && recoveryContexts[albumID] != nil
    }

    /// Explicitly restores one exact photo through the current finished-run membership and context.
    public func restorePhoto(_ item: BackupFailedItem, albumID: String) async throws -> AlbumSyncPhotoRecovery.Result {
        guard !isBulkRestoring else { throw AlbumSyncPhotoRecovery.Error.unavailable }
        return try await restoreAdmittedPhoto(item, albumID: albumID)
    }

    /// The single exact restore path; a running bulk restore calls it for each confirmed row.
    private func restoreAdmittedPhoto(
        _ item: BackupFailedItem, albumID: String
    ) async throws -> AlbumSyncPhotoRecovery.Result {
        try Task.checkCancellation()
        guard recoveryTask == nil, !isSyncing, !isShuttingDown,
            let context = recoveryContexts[albumID]
        else { throw AlbumSyncPhotoRecovery.Error.unavailable }
        let generation = recoveryGeneration
        let task = Task {
            try await self.performRestore(item, albumID: albumID, generation: generation, context: context)
        }
        recoveryTask = task
        defer {
            recoveryTask = nil
            startBatchIfIdle()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The album problem list restores the existing copy, then uses the normal sync to add it to the album.
    public func restorePhotoFromProblemList(_ item: BackupFailedItem, albumID: String) async {
        do {
            _ = try await restorePhoto(item, albumID: albumID)
            syncNow(albumID: albumID)
        } catch {
            guard !UploadError.isCancellation(error) else { return }
            setMessage(L10n.string("albumsync.error_restore_photo"))
        }
    }

    // MARK: - Bulk restore

    public let bulkPhotoActions: BulkPhotoActionRunner
    /// The confirmation that prepareRestore made and the finished run it covers; each run has its own id.
    private var bulkRestoreConsent: (problemListID: UUID, confirmationID: UUID)?
    /// From start to settlement no album sync starts, also between photos of the run.
    private var isBulkRestoring = false
    private var bulkRestoreStopped = false
    private var bulkRestoreRestored = 0
    /// The album whose run or result the shared runner holds; only that album's list shows them.
    public private(set) var bulkRestoreAlbumID: String?
    private var bulkRestoreTask: Task<Void, Never>?

    public func isBulkRestoreAvailable(albumID: String) -> Bool {
        canRestorePhotos(albumID: albumID)
    }

    /// Consent covers every deleted row of the finished run, beyond the loaded page. No row changes here.
    public func prepareRestore(albumID: String) async -> BulkPhotoActionRunner.Confirmation? {
        guard isBulkRestoreAvailable(albumID: albumID), let finished = finishedProblems[albumID] else { return nil }
        let deleted = finished.items.filter { $0.issue == .remoteDeletion }
        guard let confirmation = bulkPhotoActions.prepare(deleted, action: .restore) else { return nil }
        bulkRestoreConsent = (finished.id, confirmation.id)
        return confirmation
    }

    /// Call only from the visible confirmation. Each row uses the existing exact restore; a refused row stays.
    @discardableResult
    public func startRestore(_ confirmation: BulkPhotoActionRunner.Confirmation, albumID: String) -> Bool {
        // Only the confirmation that prepareRestore made (always .restore), for the album's current run, can start.
        guard let consent = bulkRestoreConsent,
            consent.confirmationID == confirmation.id, finishedProblems[albumID]?.id == consent.problemListID,
            isBulkRestoreAvailable(albumID: albumID)
        else { return false }
        let generation = recoveryGeneration
        guard
            bulkPhotoActions.start(
                confirmation,
                perform: { [weak self] item in
                    guard let self else { return false }
                    // Stop, selection changes and a new finished run invalidate recovery; the run ends there.
                    guard recoveryGeneration == generation else {
                        bulkPhotoActions.cancel()
                        return false
                    }
                    do {
                        _ = try await restoreAdmittedPhoto(item, albumID: albumID)
                        bulkRestoreRestored += 1
                        return true
                    } catch {
                        return false
                    }
                })
        else { return false }
        isBulkRestoring = true
        bulkRestoreStopped = false
        bulkRestoreRestored = 0
        bulkRestoreAlbumID = albumID
        bulkRestoreTask = Task { [weak self, bulkPhotoActions] in
            await bulkPhotoActions.waitUntilFinished()
            guard let self else { return }
            isBulkRestoring = false
            bulkRestoreConsent = nil
            bulkRestoreTask = nil
            guard !isShuttingDown else { return }
            // The normal album sync adds restored copies once; after Stop the next sync reconciles them.
            if !bulkRestoreStopped, bulkRestoreRestored > 0 {
                syncNow(albumID: albumID)
            } else {
                startBatchIfIdle()
            }
        }
        return true
    }

    func waitUntilBulkRestoreSettled() async { await bulkRestoreTask?.value }

    private func invalidateRecovery() {
        recoveryGeneration = UUID()
        recoveryTask?.cancel()
    }

    private func captureRecoveryContext() async throws -> AlbumSyncPhotoRecovery.Context? {
        let task = Task { [remoteOps] in try await remoteOps.photoRecoveryContext() }
        recoveryContextTask = task
        defer { recoveryContextTask = nil }
        let context: AlbumSyncPhotoRecovery.Context?
        do {
            context = try await task.value
        } catch {
            if UploadError.isCancellation(error) {
                if stopState.isRequested || isShuttingDown { throw AlbumSyncError.stopped }
                throw error
            }
            context = nil
        }
        if stopState.isRequested || isShuttingDown { throw AlbumSyncError.stopped }
        try Task.checkCancellation()
        if task.isCancelled { throw CancellationError() }
        return context
    }

    private func validateRecovery(_ item: BackupFailedItem, albumID: String, generation: UUID) async throws {
        try requireRecoveryAdmission(item, albumID: albumID, generation: generation)
        guard let source = item.source,
            case .present(let identifiers) = try await localSource.albumContents(albumID: albumID),
            identifiers.contains(source.identifier)
        else { throw AlbumSyncPhotoRecovery.Error.unavailable }
        try requireRecoveryAdmission(item, albumID: albumID, generation: generation)
    }

    private func requireRecoveryAdmission(_ item: BackupFailedItem, albumID: String, generation: UUID) throws {
        try Task.checkCancellation()
        guard !isShuttingDown, !isSyncing, generation == recoveryGeneration,
            currentAccessState().allowsBackup, mappingStore?.isOperational() == true,
            selectedAlbumIDs.contains(albumID), item.issue == .remoteDeletion,
            let source = item.source, source.kind == .photoLibraryAsset, source.resource == .primary,
            finishedProblems[albumID]?.items.contains(item) == true
        else { throw AlbumSyncPhotoRecovery.Error.unavailable }
    }

    private func performRestore(
        _ item: BackupFailedItem, albumID: String, generation: UUID, context: AlbumSyncPhotoRecovery.Context
    ) async throws -> AlbumSyncPhotoRecovery.Result {
        try await validateRecovery(item, albumID: albumID, generation: generation)
        guard let source = item.source, let identityResolver,
            let record = await identityResolver.identityRecord(for: source)
        else { throw AlbumSyncPhotoRecovery.Error.unavailable }
        try await validateRecovery(item, albumID: albumID, generation: generation)
        let catalog = recoveryCatalog(source.identifier)
        let candidate = try await AlbumSyncPhotoRecovery.candidate(for: source, catalog: catalog)
        try await validateRecovery(item, albumID: albumID, generation: generation)
        if let revision = item.revision, revision != candidate.snapshot.revision {
            throw AlbumSyncPhotoRecovery.Error.unavailable
        }
        let entry = UploadBackupSyncQueueEntry(
            source: source, revision: candidate.snapshot.revision, originalFilename: candidate.originalFilename,
            byteCount: candidate.byteCount, updatedAt: Date())
        guard let prepared = try await recoveryResourceResolver.resolve(entry) else {
            throw AlbumSyncPhotoRecovery.Error.unavailable
        }
        defer { prepared.cleanup?() }
        guard AlbumSyncPhotoRecovery.sameVersion(candidate.snapshot, prepared.candidate.snapshot) else {
            throw AlbumSyncPhotoRecovery.Error.unavailable
        }
        return try await AlbumSyncPhotoRecovery.restore(
            record: record, descriptor: prepared.descriptor, remote: remoteOps, expectedContext: context
        ) { [self] in
            try await validateRecovery(item, albumID: albumID, generation: generation)
            let current = try await AlbumSyncPhotoRecovery.candidate(for: source, catalog: catalog)
            guard current == candidate, await identityResolver.identityRecord(for: source) == record else {
                throw AlbumSyncPhotoRecovery.Error.unavailable
            }
            try await validateRecovery(item, albumID: albumID, generation: generation)
        }
    }

    public func stopSync() {
        if isBulkRestoring {
            bulkRestoreStopped = true
            bulkPhotoActions.cancel()
        }
        invalidateRecovery()
        recoveryContextTask?.cancel()
        stopState.stopPressed(isSyncing: isSyncing, queuedAlbums: queuedAlbumIDs.count)
        queuedAlbumIDs.removeAll()
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        changePendingDuringSync = false
        guard let runner else { return }
        let contextRead = recoveryContextTask
        Task {
            await runner.stop()
            _ = await contextRead?.result
        }
    }

    /// Ordered sign-out boundary for the album mapping database and any per-run backup stores.
    public func shutdown() async {
        isShuttingDown = true
        finishedProblems.removeAll()
        problemListRevision = UUID()
        invalidateRecovery()
        recoveryContextTask?.cancel()
        let activeRecovery = recoveryTask
        let bulkRestore = bulkRestoreTask
        await bulkPhotoActions.shutdown()
        await bulkRestore?.value
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
        _ = await activeRecovery?.result
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
        guard !isShuttingDown, let runner, !isSyncing, recoveryTask == nil, !isBulkRestoring, !queuedAlbumIDs.isEmpty
        else { return }
        isSyncing = true
        remoteAlbumsChangedDuringBatch = false
        stopState.batchStarted()
        setMessage(nil)

        syncTask = Task { [weak self] in
            while let album = self?.dequeueNextAlbum() {
                do {
                    let generation = self?.recoveryGeneration
                    let recoveryContext = try await self?.captureRecoveryContext()
                    let report = try await runner.sync(album: album, resolution: .automatic)
                    let currentContext = generation == self?.recoveryGeneration ? recoveryContext : nil
                    self?.recordFinishedRun(report.problems, albumID: album.id, recoveryContext: currentContext)
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
    func recordFinishedRun(
        _ problems: [BackupFailedItem], albumID: String,
        recoveryContext: AlbumSyncPhotoRecovery.Context? = nil
    ) {
        guard !isShuttingDown else { return }
        invalidateRecovery()
        if selectedAlbumIDs.contains(albumID) {
            recoveryContexts[albumID] = recoveryContext
            finishedProblems[albumID] = FinishedProblems(items: problems)
        } else {
            recoveryContexts[albumID] = nil
            finishedProblems[albumID] = nil
        }
        lastRunStore.record(problems, albumID: albumID)
        reloadSelection()
        problemListRevision = UUID()
    }

    private func reportMappingStoreUnavailable() {
        setMessage(AlbumSyncError.mappingStoreUnavailable.errorDescription)
    }

    #if DEBUG
        /// Seeds one synced album whose last run left photos outside the Proton album, on the offline
        /// UI-test account. It uses the real mapping store and last-run file, without PhotoKit or a network.
        public func installNotInAlbumFixtureForTesting(albumID: String, title: String) -> Bool {
            guard let mappingStore, mappingStore.isOperational() else { return false }
            var items = AlbumSyncProblemList.items(
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
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesAlbumSyncRestoreFixture") {
                items = AlbumSyncProblemList.items(
                    missingIdentifiers: [], attachFailedIdentifiers: [], trashedIdentifiers: ["fixture-trashed"],
                    backup: AlbumSyncBackupReport(
                        total: 1, backedUp: 0, failed: 0, sourceMissing: 0, skippedRemoteDeletion: 1,
                        filenames: ["fixture-trashed": "trashed fixture.heic"]))
            }
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
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesAlbumSyncBulkRestoreFixture") {
                // A finished run with a session context offers Restore All; denied access keeps every row.
                recordFinishedRun(
                    items, albumID: albumID,
                    recoveryContext: .init(sessionID: UUID(), volumeID: "fixture-volume", hashKeyEpoch: "fixture"))
            }
            return true
        }
    #endif
}
