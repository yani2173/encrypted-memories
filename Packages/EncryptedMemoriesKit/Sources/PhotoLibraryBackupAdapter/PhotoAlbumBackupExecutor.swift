import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore

/// `AlbumSyncBackupExecuting` over the standard backup pipeline, restricted to an explicit asset
/// list. Uses the same identity resolver (dedupe manifest + duplicate service) as full photo
/// backup and manual uploads - one duplicate authority, so album sync can never re-upload bytes
/// that any other path already settled.
///
/// The queue/state stores are album-sync-private, per-run scratch so counts stay scoped to the
/// current album. A queue receipt is nevertheless durable until its identity-manifest settlement
/// succeeds; the next serialized run replays every such receipt before resetting ordinary rows.
public final class PhotoAlbumBackupExecutor: AlbumSyncBackupExecuting, @unchecked Sendable {
    static let queueDatabaseFileName = "album-sync-backup-queue-v1.sqlite"
    static let stateDatabaseFileName = "album-sync-backup-state-v1.sqlite"

    private let accountDataDirectory: URL
    private let databasePolicy: LibraryDatabasePolicy
    private let identityResolver: any UploadIdentityResolving
    private let uploader: any PhotoUploading
    private let injectedResourceResolver: (any BackupResourceResolving)?
    private let injectedProofCatalog: (any UploadBackupAssetCatalog)?
    private let stopFenceAcquired: (@Sendable () async -> Void)?
    private let stopFenceBarrier: (@Sendable () async -> Void)?
    private let runtimeSignals: BackupRuntimeSignalSource
    private let clock: any BackupSchedulerClock

    private let lock = NSLock()
    private struct ActiveOperation {
        let id: UUID
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }
    private var activeOperation: ActiveOperation?
    private var activeRunner: BackupSyncRunner?
    private var stopOwnerCount = 0

    public init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading
    ) {
        self.accountDataDirectory = accountDataDirectory
        self.databasePolicy = databasePolicy
        self.identityResolver = identityResolver
        self.uploader = uploader
        injectedResourceResolver = nil
        injectedProofCatalog = nil
        stopFenceAcquired = nil
        stopFenceBarrier = nil
        runtimeSignals = .apple
        clock = BackupContinuousClock()
    }

    init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading,
        resourceResolver: any BackupResourceResolving,
        proofCatalog: (any UploadBackupAssetCatalog)? = nil,
        stopFenceAcquired: (@Sendable () async -> Void)? = nil,
        stopFenceBarrier: (@Sendable () async -> Void)? = nil,
        runtimeSignals: BackupRuntimeSignalSource = .apple,
        clock: any BackupSchedulerClock = BackupContinuousClock()
    ) {
        self.accountDataDirectory = accountDataDirectory
        self.databasePolicy = databasePolicy
        self.identityResolver = identityResolver
        self.uploader = uploader
        injectedResourceResolver = resourceResolver
        injectedProofCatalog = proofCatalog
        self.stopFenceAcquired = stopFenceAcquired
        self.stopFenceBarrier = stopFenceBarrier
        self.runtimeSignals = runtimeSignals
        self.clock = clock
    }

    public func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        try await withOperation { [self] in
            try await performEnsureBackedUp(localIdentifiers: localIdentifiers, onProgress: onProgress)
        }
    }

    private func withOperation<Value: Sendable>(
        _ operation: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        let operationID = UUID()
        let startGate = PhotoAlbumBackupExecutorStartGate()
        var operationTask: Task<Value, any Error>?
        let admitted = lock.withLock {
            guard activeOperation == nil, stopOwnerCount == 0 else { return false }
            let task = Task { [self] in
                await startGate.wait()
                defer { finishOperation(id: operationID) }
                try Task.checkCancellation()
                return try await operation()
            }
            operationTask = task
            activeOperation = ActiveOperation(
                id: operationID, cancel: { task.cancel() }, wait: { _ = await task.result })
            return true
        }
        guard admitted, let operationTask else {
            throw AlbumSyncError.alreadyRunning
        }
        return try await withTaskCancellationHandler {
            await startGate.open()
            return try await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
    }

    private func performEnsureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        let queueURL = accountDataDirectory.appendingPathComponent(Self.queueDatabaseFileName)
        let stateURL = accountDataDirectory.appendingPathComponent(Self.stateDatabaseFileName)
        let tempStore = BackupTempFileStore(
            directory: accountDataDirectory.appendingPathComponent("album-sync-temp", isDirectory: true)
        )
        let resourceResolver = injectedResourceResolver ?? PhotoLibraryResourceResolver(tempStore: tempStore)

        guard
            let recoveryQueue = UploadBackupSyncQueueManifestStore(
                url: queueURL,
                policy: databasePolicy
            )
        else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        do {
            try await UploadRemoteCommitRecovery(
                queue: recoveryQueue,
                resolver: resourceResolver,
                identityResolver: identityResolver
            ).settleAll()
            try Task.checkCancellation()
        } catch {
            recoveryQueue.close()
            throw error
        }
        recoveryQueue.close()

        // AlbumSyncRunner serializes calls. Reset is allowed only after the complete strict receipt
        // scan above succeeds while this registered operation still owns the stores.
        try Task.checkCancellation()
        try resetScratchDatabaseFiles(urls: [queueURL, stateURL])
        guard !localIdentifiers.isEmpty else { return AlbumSyncBackupReport() }
        guard
            let queueStore = UploadBackupSyncQueueManifestStore(
                url: queueURL,
                policy: databasePolicy
            ),
            let stateStore = UploadBackupStateManifestStore(
                url: stateURL,
                policy: databasePolicy
            )
        else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        defer {
            queueStore.close()
            stateStore.close()
        }

        let preflight = UploadBackupPreflightIndex(store: stateStore)
        let engine = UploadBackupSyncEngine(
            preflight: preflight,
            queue: queueStore,
            remoteProofResolver: identityResolver
        )
        let runner = BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: resourceResolver,
            identityResolver: identityResolver,
            uploader: uploader,
            throttleInputs: runtimeSignals.current,
            runtimeChanges: runtimeSignals.updates,
            clock: clock
        )
        lock.withLock { activeRunner = runner }
        defer { lock.withLock { activeRunner = nil } }

        await runner.setOnProgress { snapshot in onProgress(snapshot) }
        _ = try await engine.scan(PhotoLibraryBackupCatalog(localIdentifiers: localIdentifiers))
        _ = await runner.runUntilDrained(workIntent: .userInitiated)
        try await runner.checkCancellation()
        try Task.checkCancellation()
        guard await runner.isQueueOperational(), queueStore.isOperational() else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        tempStore.sweep()

        return try AlbumSyncBackupReport.read(from: queueStore, localIdentifiers: localIdentifiers)
    }

    public func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        try await withOperation { [self] in
            try await performRemoteProofLinks(for: localIdentifiers)
        }
    }

    private func performRemoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        guard
            let queue = UploadBackupSyncQueueManifestStore(
                url: accountDataDirectory.appendingPathComponent(Self.queueDatabaseFileName),
                policy: databasePolicy)
        else { throw AlbumSyncError.mappingStoreUnavailable }
        defer { queue.close() }
        return try await AlbumSyncRemoteProofLookup.remoteLinks(
            for: localIdentifiers,
            catalog: injectedProofCatalog ?? PhotoLibraryBackupCatalog(localIdentifiers: localIdentifiers),
            queue: queue, resolver: identityResolver)
    }

    public func stop() async {
        let (operation, runner) = lock.withLock {
            stopOwnerCount += 1
            return (activeOperation, activeRunner)
        }
        defer {
            lock.withLock {
                precondition(stopOwnerCount > 0)
                stopOwnerCount -= 1
            }
        }
        await stopFenceAcquired?()
        operation?.cancel()
        await runner?.stop()
        await operation?.wait()
        await stopFenceBarrier?()
    }

    private func finishOperation(id: UUID) {
        lock.withLock {
            guard activeOperation?.id == id else { return }
            activeRunner = nil
            activeOperation = nil
        }
    }

    private func resetScratchDatabaseFiles(urls: [URL]) throws {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] {
                let target = URL(fileURLWithPath: url.path + suffix)
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}

private actor PhotoAlbumBackupExecutorStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}
