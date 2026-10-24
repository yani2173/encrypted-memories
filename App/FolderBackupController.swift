import Foundation
import Observation
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonDriveBackend
import UploadCore

/// One folder the user chose to keep backed up, persisted as a security-scoped bookmark so the
/// sandboxed app can reach it across launches.
struct BackupFolder: Identifiable, Equatable {
    let id: UUID
    var bookmark: Data
    var displayPath: String
    /// True when the bookmark no longer resolves cleanly - the user must re-pick the folder.
    var needsRenewal: Bool
}

/// macOS composition of the shared backup sync stack. This type owns security-scoped folder access
/// and lifecycle; UploadCore owns synchronization and recovery.
@MainActor
@Observable
final class FolderBackupController {
    private(set) var folders: [BackupFolder] = []
    /// The user-facing state surface shared by both platform settings views. Raw runner progress stays internal.
    private(set) var status = BackupStatus()
    private(set) var isSyncing = false
    private(set) var lastMessage: String?

    /// False when the account's dedupe manifest or sync stores could not open - backup is then
    /// disabled entirely instead of running without duplicate protection. The pending store is required too:
    /// without it, a file deleted before upload could upload after all.
    var isAvailable: Bool {
        runner != nil && (!requiresPendingStore || pendingStore?.isOperational() == true)
    }

    /// Watched folders the pending grid may read; kept accessible while they are registered.
    let pendingAccess = PendingFolderAccess()
    @ObservationIgnored private let pendingStore: PendingBackupManifestStore?
    @ObservationIgnored private let requiresPendingStore: Bool
    @ObservationIgnored private var accessedFolders: [BackupFolder.ID: URL] = [:]

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private let statusProjector: BackupStatusProjector?
    private let statusProjectionGeneration = UUID()
    private var statusProjectionRevision: UInt64 = 0
    private var lastAppliedStatusProjectionRevision: UInt64 = 0
    private var statusSetupTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var runnerStopTask: Task<Void, Never>?
    private var runnerStopRunID: UUID?
    private var isShuttingDown = false
    private var isScanning = false
    /// A scan failure is not a queue item. Keep it as run-local state so a drained prefix cannot
    /// be presented as a complete backup, without polluting the durable queue with a fake row.
    private var hasFolderEnumerationFailure = false

    private static let foldersDefaultsKey = "backup.folderBookmarks.v1"

    /// `pendingRecorder` is the photo backup's recorder, so one event stream serves the pending grid.
    init(
        facade: ProtonClientFacade,
        pendingStore: PendingBackupManifestStore? = nil,
        pendingRecorder: PendingBackupEventRecorder? = nil,
        requiresPendingStore: Bool = false
    ) {
        self.pendingStore = pendingStore
        self.requiresPendingStore = requiresPendingStore
        let directory = facade.accountDataDirectory
        let policy = facade.accountDatabasePolicy
        let queueStore = UploadBackupSyncQueueManifestStore(
            url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName),
            policy: policy
        )
        let stateStore = UploadBackupStateManifestStore(
            url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName),
            policy: policy
        )
        self.queueStore = queueStore
        self.stateStore = stateStore
        statusProjector = queueStore.map { BackupStatusProjector(queue: $0) }

        // The shared dedupe pipeline prevents each sync pass from re-uploading existing files.
        if let queueStore, let stateStore, let identityResolver = facade.uploadIdentityResolver {
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
                resolver: FileBackupResourceResolver(),
                identityResolver: identityResolver,
                uploader: facade.photoUploader,
                throttleInputs: BackupRuntimeSignalSource.apple.current,
                runtimeChanges: BackupRuntimeSignalSource.apple.updates,
                events: pendingRecorder
            )
        } else {
            engine = nil
            runner = nil
        }

        loadFolders()
        reconcileQueueWithRegisteredFolders()
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
    }

    private var projectionContext: BackupStatusProjectionContext {
        BackupStatusProjectionContext(isScanning: isScanning, isRunning: isSyncing)
    }

    private func applyStatusProjection(_ projection: BackupStatusProjection) {
        guard projection.generation == statusProjectionGeneration,
            projection.revision >= lastAppliedStatusProjectionRevision
        else { return }
        lastAppliedStatusProjectionRevision = projection.revision
        status =
            hasFolderEnumerationFailure
            ? Self.statusAfterFolderEnumerationFailure(projection.status)
            : projection.status
    }

    private static func statusAfterFolderEnumerationFailure(_ status: BackupStatus) -> BackupStatus {
        var status = status
        status.phase = .needsAttention
        // The failing subtree has no queue row. Surface one run-level attention item rather than
        // claiming that the successfully enumerated prefix represents the complete tree.
        status.failed = max(1, status.failed)
        status.fractionCompleted = nil
        status.currentItemName = nil
        return status
    }

    // MARK: - Folder registry (bookmarks are the App-side boundary)

    func addFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folder = BackupFolder(id: UUID(), bookmark: bookmark, displayPath: url.path, needsRenewal: false)
            folders.removeAll { $0.displayPath == folder.displayPath }
            folders.append(folder)
            folders.sort { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
            persistFolders()
            refreshFolderAccess()
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func removeFolder(_ id: BackupFolder.ID) {
        folders.removeAll { $0.id == id }
        persistFolders()
        refreshFolderAccess()
        reconcileQueueWithRegisteredFolders()
        refreshFromQueue()
    }

    private func loadFolders() {
        guard let raw = UserDefaults.standard.array(forKey: Self.foldersDefaultsKey) as? [Data] else { return }
        folders = raw.compactMap { bookmark in
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            else {
                return BackupFolder(id: UUID(), bookmark: bookmark, displayPath: "?", needsRenewal: true)
            }
            return BackupFolder(id: UUID(), bookmark: bookmark, displayPath: url.path, needsRenewal: stale)
        }
        .sorted { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
        refreshFolderAccess()
    }

    /// Keeps every registered folder readable, for pending thumbnails, the viewer and export.
    private func refreshFolderAccess() {
        let registered = Set(folders.filter { !$0.needsRenewal }.map(\.id))
        for (id, url) in accessedFolders where !registered.contains(id) {
            url.stopAccessingSecurityScopedResource()
            accessedFolders[id] = nil
        }
        for folder in folders where registered.contains(folder.id) && accessedFolders[folder.id] == nil {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: folder.bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ), url.startAccessingSecurityScopedResource()
            else { continue }
            accessedFolders[folder.id] = url
        }
        pendingAccess.setRoots(Array(accessedFolders.values))
    }

    // MARK: - Pending grid

    /// The folder backup as a source of the pending grid.
    var pendingFileSource: PendingFileSource? {
        guard let queueStore, pendingStore != nil else { return nil }
        return PendingFileSource(
            queue: queueStore,
            metadata: PendingFolderMetadataProvider(access: pendingAccess),
            removeFromBackup: { [weak self] paths in await self?.removeFromBackup(paths: paths) ?? false },
            returnToBackup: { [weak self] paths in await self?.returnToBackup(paths: paths) ?? false }
        )
    }

    /// Removes excluded files from queued and in-flight work; a rescan never offers them again.
    private func removeFromBackup(paths: [String]) async -> Bool {
        guard let runner, queueStore?.isOperational() == true else { return false }
        _ = await runner.removeSources(kind: .fileURL, identifiers: paths)
        return queueStore?.isOperational() == true
    }

    /// Enqueues restored files again and starts a pass. Files that are gone need nothing and count as done.
    private func returnToBackup(paths: [String]) async -> Bool {
        guard let engine else { return false }
        let candidates = paths.compactMap { path in
            pendingAccess.fileURL(forPath: path).flatMap { try? FolderBackupCatalog.candidate(for: $0) }
        }
        do {
            _ = try await engine.enqueueBatch(candidates)
        } catch {
            return false
        }
        refreshFromQueue()
        if !candidates.isEmpty { syncNow() }
        return true
    }

    private func persistFolders() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: Self.foldersDefaultsKey)
    }

    /// The queue is a derived work index. Keep only rows that still belong to a folder the user
    /// has registered; the separate backup-state manifest retains deduplication history.
    private func reconcileQueueWithRegisteredFolders() {
        let activeRootPaths =
            folders
            .map(\.displayPath)
            .filter { $0.hasPrefix("/") }
        queueStore?.removeFileSources(outsideRootPaths: activeRootPaths)
    }

    // MARK: - Sync lifecycle

    func syncNow() {
        guard !isShuttingDown, !isSyncing, runnerStopTask == nil, isAvailable, let engine, let runner else { return }
        reconcileQueueWithRegisteredFolders()
        let runID = UUID()
        activeRunID = runID
        isSyncing = true
        isScanning = true
        hasFolderEnumerationFailure = false
        lastMessage = nil
        refreshFromQueue()
        let snapshotFolders = folders
        let statusSetupTask = self.statusSetupTask
        syncTask = Task { [weak self, statusSetupTask] in
            await statusSetupTask?.value
            self?.refreshFromQueue()
            var accessedURLs: [URL] = []
            defer {
                for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
            }

            // Scan every reachable folder first (cheap, no bytes), then drain the shared queue.
            for folder in snapshotFolders {
                guard !Task.isCancelled else {
                    self?.finishScanPhase()
                    await self?.finishSync(runID: runID)
                    return
                }
                var stale = false
                guard
                    let url = try? URL(
                        resolvingBookmarkData: folder.bookmark,
                        options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    ), !stale, url.startAccessingSecurityScopedResource()
                else {
                    self?.markFolderNeedsRenewal(folder.id)
                    self?.recordFolderEnumerationFailure(
                        Self.localizedFolderError(
                            failureClass: .missing,
                            name: folder.displayPath
                        )
                    )
                    continue
                }
                accessedURLs.append(url)
                do {
                    _ = try await engine.scan(FolderBackupCatalog(folder: url))
                } catch is CancellationError {
                    self?.finishScanPhase()
                    await self?.finishSync(runID: runID)
                    return
                } catch let error as FolderEnumerationError {
                    guard !Task.isCancelled else {
                        self?.finishScanPhase()
                        await self?.finishSync(runID: runID)
                        return
                    }
                    self?.reportFolderEnumerationError(error, folder: folder, root: url)
                } catch {
                    guard !Task.isCancelled else {
                        self?.finishScanPhase()
                        await self?.finishSync(runID: runID)
                        return
                    }
                    self?.recordFolderEnumerationFailure(
                        Self.localizedFolderError(
                            failureClass: .transient,
                            name: folder.displayPath
                        )
                    )
                }
            }

            self?.finishScanPhase()
            guard !Task.isCancelled else {
                await self?.finishSync(runID: runID)
                return
            }
            _ = await runner.runUntilDrained(workIntent: .userInitiated)
            await self?.finishSync(runID: runID)
        }
    }

    func stopSync() {
        syncTask?.cancel()
        requestRunnerStop()
    }

    func shutdown() async {
        isShuttingDown = true
        let activeSync = syncTask
        let activeStatusSetup = statusSetupTask
        syncTask?.cancel()
        statusSetupTask = nil
        requestRunnerStop()
        let activeStop = runnerStopTask
        await activeStop?.value
        await activeSync?.value
        await activeStatusSetup?.value
        await runner?.setOnProgress(nil)
        await statusProjector?.stop()
        queueStore?.close()
        stateStore?.close()
        for url in accessedFolders.values { url.stopAccessingSecurityScopedResource() }
        accessedFolders.removeAll()
        pendingAccess.setRoots([])
    }

    private func markFolderNeedsRenewal(_ id: BackupFolder.ID) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].needsRenewal = true
            persistFolders()
        }
        // A folder that must be picked again is no longer readable for the pending grid either.
        refreshFolderAccess()
    }

    private func reportFolderEnumerationError(
        _ error: FolderEnumerationError,
        folder: BackupFolder,
        root: URL
    ) {
        if error.requiresRootAccessRenewal(for: root) {
            markFolderNeedsRenewal(folder.id)
        }
        let name = error.url.lastPathComponent.isEmpty ? folder.displayPath : error.url.lastPathComponent
        recordFolderEnumerationFailure(
            Self.localizedFolderError(failureClass: error.failureClass, name: name)
        )
    }

    private static func localizedFolderError(
        failureClass: FolderEnumerationError.FailureClass,
        name: String
    ) -> String {
        let key =
            switch failureClass {
            case .permissionDenied: "settings.backup_folder_error_permission %@"
            case .missing: "settings.backup_folder_error_missing %@"
            case .transient: "settings.backup_folder_error_transient %@"
            }
        return String(format: NSLocalizedString(key, comment: "Folder backup read error"), name)
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    private func recordFolderEnumerationFailure(_ message: String) {
        hasFolderEnumerationFailure = true
        status = Self.statusAfterFolderEnumerationFailure(status)
        reportSyncMessage(message)
    }

    private func finishScanPhase() {
        isScanning = false
        refreshFromQueue()
    }

    private func finishSync(runID: UUID) async {
        let stopTask = runnerStopRunID == runID ? runnerStopTask : nil
        await stopTask?.value
        guard activeRunID == runID else { return }
        activeRunID = nil
        if runnerStopRunID == runID {
            runnerStopTask = nil
            runnerStopRunID = nil
        }
        syncTask = nil
        isSyncing = false
        isScanning = false
        refreshFromQueue()
    }

    private func requestRunnerStop() {
        guard let runID = activeRunID, runnerStopTask == nil, let runner else { return }
        let task = Task { await runner.stop() }
        runnerStopRunID = runID
        runnerStopTask = task
    }

    /// Seeds the UI snapshot from the durable queue - shows outstanding work from a previous
    /// launch before any sync pass runs (relaunch-resume visibility).
    private func refreshFromQueue() {
        guard let statusProjector else { return }
        statusProjectionRevision &+= 1
        let context = projectionContext
        let revision = statusProjectionRevision
        let generation = statusProjectionGeneration
        Task {
            _ = await statusProjector.projectNow(
                context: context,
                generation: generation,
                revision: revision
            )
        }
    }
}
