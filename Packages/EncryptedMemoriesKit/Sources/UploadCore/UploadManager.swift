import Foundation
import PhotosCore

/// Bounded-concurrency upload queue with a strict per-item state machine, album orchestration, and
/// partial-success handling. Pure of any SDK/HTTP concern - all transport goes through the injected
/// `PhotoUploading` (and optional `AlbumAttaching`) seams, which keeps the whole thing unit-testable.
public actor UploadManager {
    private enum ScopedUploadOutcome: Sendable {
        case uploaded(PhotoUID)
        case skipped(UploadSkipReason)
    }

    private enum ByteUploadGate {
        case allowed
        case receiptBacked
        case settlementUnavailable
    }

    private enum AlbumResolutionOutcome: Sendable {
        case resolved(String?)
        case failed(String)
    }

    private enum DurableSettlementReplayStart {
        case skipped
        case storeUnavailable
        case restored
    }

    /// Result of one durable settlement run. The detached task hands it back to the actor, which
    /// releases ownership and publishes the outcome in one synchronous block.
    private enum DurableSettlementOutcome {
        /// Nothing to replay: the record is already terminal, or no store is attached.
        case untouched
        /// The record reached its durable terminal state.
        case settled(UploadManualSettlementRecord)
        /// The settlement failed; the item must stay visibly failed.
        case failed(UploadManualSettlementRecord, message: String)
    }

    // MARK: Injected backends + config

    private let uploader: any PhotoUploading
    private let albums: (any AlbumAttaching)?
    /// The universal dedupe pipeline. Optional so the queue also works for backends without a
    /// duplicate service (and for focused queue tests); when nil, every item uploads as before.
    private let identityResolver: (any UploadIdentityResolving)?
    /// Durable evidence for a transport-confirmed manual commit. Production composition supplies
    /// one account-scoped SQLite store; focused queue tests may omit it.
    private let settlementStore: (any UploadManualSettlementStoreProtocol)?
    /// A production manager without durable settlement must fail closed before transport starts.
    private let requiresDurableSettlement: Bool
    private let maxConcurrent: Int
    private let now: @Sendable () -> Date
    private let runtimeState: LibraryRuntimeState

    // MARK: State

    private struct Job {
        var item: UploadItem
        let destination: UploadDestination
        var cancellationToken: UUID
        var cancellationRequested = false
        var retryRequested = false
        var generation: UInt64 = 0
        var settlementRecord: UploadManualSettlementRecord?
        var remoteCommitReceipt: UploadRemoteCommitReceipt?
        /// The receipt row that the store refused right after the remote commit (#1226). The
        /// receipt then exists only in memory. The receipt catch of `run`, Retry and shutdown write
        /// this row again.
        var unwrittenReceiptRecord: UploadManualSettlementRecord? = nil
        var resolvedAlbumID: String?
        /// Whether this item sets the album cover for `.firstUploaded`. Nil until the item decided it.
        var claimsFirstUploadedCover: Bool? = nil
        var task: Task<Void, Never>?
        var controlTask: Task<Void, Never>? = nil
        var controlID: UUID? = nil
        var nativeCancellationTask: Task<Void, Never>? = nil

        /// The job has a settlement record that is not proven terminal: a pending record, or a
        /// terminal copy whose terminal write failed. Its durable row is still pending (#1104).
        var hasUnsettledRecord: Bool {
            guard let settlementRecord else { return false }
            return !settlementRecord.isProvenTerminal
        }

        /// The row offers Retry only when a settlement step can run again in this session (#1104).
        /// A proven-terminal record is settled. An unsettled record stays retryable while the store
        /// can work, because Retry then settles the still-pending durable row; an unwritten receipt
        /// row stays retryable too, because Retry then writes it (#1226). With a lasting store
        /// failure no step can run before a relaunch. A Retry that would upload bytes waits for a
        /// relaunch while the byte gate refuses every byte upload (#1228).
        func snapshot(retryWaitsForRelaunch: Bool) -> UploadItem {
            var snapshot = item
            snapshot.hasTerminalSettlement =
                (settlementRecord?.isProvenTerminal ?? false) || retryWaitsForRelaunch
            return snapshot
        }
    }

    private var jobs: [UploadQueueItemID: Job] = [:]
    private var order: [UploadQueueItemID] = []  // enqueue order - the stable display order
    private var activeIDs: Set<UploadQueueItemID> = []
    private var nextOrdinal = 0
    private var settlementReplayStarted = false
    private var settlementTasks: [UploadQueueItemID: Task<Void, Never>] = [:]
    private var dedupePrimeTasks: [UUID: Task<Void, Never>] = [:]
    private var emittedCompletionIDs: Set<UploadQueueItemID> = []
    private var albumResolutionTasks: [UUID: Task<AlbumResolutionOutcome, Never>] = [:]
    private let shutdownGate = JoinedShutdownGate()
    private var lifecycleGeneration: UInt64 = 0
    private var isShuttingDown = false
    private var didShutDown = false

    /// Observability hook for the UI/coordinator (invoked on every state change with a fresh snapshot).
    private var onChange: (@Sendable ([UploadItem], UploadQueueStats) -> Void)?
    /// Completion hook for refresh integration. Fired once per successful library-node creation.
    private var onCompleted: (@Sendable (UploadCompletedEvent) -> Void)?
    /// Sequenced variant used by `UploadCoordinator`. The sequence is assigned at the manager's
    /// source event, before an escaping callback can be deferred or delivered out of order.
    private var onSequencedChange: (@Sendable (UInt64, [UploadItem], UploadQueueStats) -> Void)?
    private var nextChangeSequence: UInt64 = 0

    public init(
        uploader: any PhotoUploading,
        albums: (any AlbumAttaching)? = nil,
        identityResolver: (any UploadIdentityResolving)? = nil,
        settlementStore: (any UploadManualSettlementStoreProtocol)? = nil,
        requiresDurableSettlement: Bool = false,
        maxConcurrent: Int = 3,
        runtimeState: LibraryRuntimeState = .shared,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.runtimeState = runtimeState
        self.albums = albums
        self.identityResolver = identityResolver
        self.settlementStore = settlementStore
        self.requiresDurableSettlement = requiresDurableSettlement
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
    }

    public func setOnChange(_ handler: @Sendable @escaping ([UploadItem], UploadQueueStats) -> Void) {
        guard !isShuttingDown else { return }
        onChange = handler
        onSequencedChange = nil
        startDurableSettlementReplaySynchronouslyIfNeeded()
        notify()
    }

    /// Installs the ordered snapshot hook used by the main-actor coordinator. The manager actor
    /// assigns event sequence numbers at the source, before an escaping callback can be delayed.
    func setCoordinatorCallbacks(
        onChange handler: @Sendable @escaping (UInt64, [UploadItem], UploadQueueStats) -> Void,
        onCompleted completion: @Sendable @escaping (UploadCompletedEvent) -> Void
    ) {
        guard !isShuttingDown else { return }
        onChange = nil
        onSequencedChange = handler
        // Register terminal delivery before replay can publish its first recovered completion.
        onCompleted = completion
        startDurableSettlementReplaySynchronouslyIfNeeded()
        notify()
    }

    public func setOnCompleted(_ handler: @Sendable @escaping (UploadCompletedEvent) -> Void) {
        guard !isShuttingDown else { return }
        onCompleted = handler
    }

    public nonisolated var capabilities: UploadBackendCapabilities { uploader.capabilities }

    // MARK: - Enqueue

    @discardableResult
    public func enqueueFiles(_ urls: [URL], destination: UploadDestination) async -> [UploadQueueItemID] {
        guard !isShuttingDown else { return [] }
        let generation = lifecycleGeneration
        ensureDurableSettlementReplay()
        guard lifecycleIsCurrent(generation) else { return [] }
        let settlementAvailable =
            settlementStore?.isOperationalAllowingTransientRecovery() ?? !requiresDurableSettlement
        guard settlementAvailable else {
            let message = UploadError.backend("Durable manual upload settlement is unavailable.").errorDescription!
            let ids = urls.map {
                addItem(
                    url: $0,
                    destination: destination,
                    cancellationToken: UUID(),
                    resolvedAlbumID: nil,
                    failure: message
                )
            }
            notify()
            return ids
        }
        guard let resolutionResult = await resolveAlbum(for: destination, generation: generation) else {
            return []
        }

        let resolvedAlbumID: String?
        switch resolutionResult {
        case .resolved(let albumID):
            resolvedAlbumID = albumID
        case .failed(let failureMessage):
            // Destination can't be honoured (e.g. album creation unsupported). Surface every chosen
            // file as failed so nothing uploads to the library behind the user's back.
            let ids = urls.map {
                addItem(
                    url: $0,
                    destination: destination,
                    cancellationToken: UUID(),
                    resolvedAlbumID: nil,
                    failure: failureMessage
                )
            }
            notify()
            return ids
        }

        var ids: [UploadQueueItemID] = []
        for url in urls {
            if SupportedMedia.isSupported(url) {
                ids.append(
                    addItem(
                        url: url, destination: destination, cancellationToken: UUID(),
                        resolvedAlbumID: resolvedAlbumID, failure: nil))
            } else {
                ids.append(
                    addItem(
                        url: url, destination: destination, cancellationToken: UUID(),
                        resolvedAlbumID: nil,
                        failure: UploadError.unsupportedFile(url.lastPathComponent).errorDescription!))
            }
        }
        notify()  // broadcast the freshly-queued items before the scheduler advances them
        pump()
        primeDedupe(for: ids)
        return ids
    }

    /// Resolves the destination album for one enqueue. The task is registered, so `shutdown` cancels and
    /// joins it. Returns nil when the lifecycle ended during the await; the caller then adds no work.
    private func resolveAlbum(
        for destination: UploadDestination,
        generation: UInt64
    ) async -> AlbumResolutionOutcome? {
        let resolutionID = UUID()
        let resolution = Task { [albums] in
            do {
                guard destination.usesAlbum else { return AlbumResolutionOutcome.resolved(nil) }
                guard let albums else {
                    return .failed(
                        UploadError.albumStep("no album backend is wired").errorDescription
                            ?? "Album backend unavailable.")
                }
                return .resolved(try await albums.resolveAlbum(for: destination.target))
            } catch {
                return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        albumResolutionTasks[resolutionID] = resolution
        let outcome = await resolution.value
        albumResolutionTasks[resolutionID] = nil
        guard lifecycleIsCurrent(generation) else { return nil }
        return outcome
    }

    /// Kick the pipeline's batched duplicate prefetch for a fresh enqueue (Proton-sized chunks of
    /// name hashes), so per-item resolution becomes a cache hit. Fire-and-forget: failures simply
    /// mean per-item lookups later.
    @discardableResult
    private func primeDedupe(for ids: [UploadQueueItemID]) -> Task<Void, Never>? {
        guard let identityResolver else { return nil }
        let urls = ids.compactMap { jobs[$0] }
            .filter { !$0.item.state.isTerminal }
            .map(\.item.fileURL)
        guard !urls.isEmpty else { return nil }
        let fallbackDate = now()
        let taskID = UUID()
        let task = Task.detached(priority: .utility) { [weak self] in
            let descriptors = urls.map { Self.descriptor(forFile: $0, fallbackDate: fallbackDate) }
            guard !Task.isCancelled else {
                await self?.dedupePrimeDidFinish(taskID)
                return
            }
            await identityResolver.prime(descriptors)
            await self?.dedupePrimeDidFinish(taskID)
        }
        dedupePrimeTasks[taskID] = task
        return task
    }

    private func dedupePrimeDidFinish(_ taskID: UUID) {
        dedupePrimeTasks[taskID] = nil
    }

    private static func descriptor(forFile url: URL, fallbackDate: Date) -> UploadResourceDescriptor {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return UploadResourceDescriptor(
            source: .file(url),
            fileURL: url,
            filename: url.lastPathComponent,
            fileSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: (attrs?[.modificationDate] as? Date) ?? fallbackDate
        )
    }

    @discardableResult
    public func enqueueFolder(_ url: URL, destination: UploadDestination) async throws -> [UploadQueueItemID] {
        guard !isShuttingDown else { return [] }
        let generation = lifecycleGeneration
        ensureDurableSettlementReplay()
        guard lifecycleIsCurrent(generation) else { return [] }

        let settlementAvailable =
            settlementStore?.isOperationalAllowingTransientRecovery() ?? !requiresDurableSettlement
        let settlementFailure =
            settlementAvailable
            ? nil
            : UploadError.backend("Durable manual upload settlement is unavailable.").errorDescription!

        var resolvedAlbumID: String?
        var destinationFailure: String?
        if settlementAvailable {
            guard let resolutionResult = await resolveAlbum(for: destination, generation: generation) else {
                return []
            }

            switch resolutionResult {
            case .resolved(let albumID):
                resolvedAlbumID = albumID
            case .failed(let failureMessage):
                destinationFailure = failureMessage
            }
        }

        var ids: [UploadQueueItemID] = []
        // Keep folder prefetch bounded while the queue starts work on the current prefix.
        let dedupeBatchSize = 32
        var dedupeBatch: [UploadQueueItemID] = []
        dedupeBatch.reserveCapacity(dedupeBatchSize)
        let iterator = FolderEnumerator.stream(url).makeAsyncIterator()
        do {
            while !Task.isCancelled, lifecycleIsCurrent(generation) {
                guard let entry = try await iterator.next() else { break }
                guard !Task.isCancelled, lifecycleIsCurrent(generation) else { break }
                guard entry.isSupported else { continue }

                let id = addItem(
                    url: entry.url,
                    destination: destination,
                    cancellationToken: UUID(),
                    resolvedAlbumID: resolvedAlbumID,
                    failure: settlementFailure ?? destinationFailure
                )
                ids.append(id)
                dedupeBatch.append(id)
                if dedupeBatch.count == dedupeBatchSize {
                    guard await flushFolderEnqueueBatch(dedupeBatch, generation: generation) else {
                        return ids
                    }
                    dedupeBatch.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            if lifecycleIsCurrent(generation), !dedupeBatch.isEmpty {
                _ = await flushFolderEnqueueBatch(dedupeBatch, generation: generation)
            }
            guard lifecycleIsCurrent(generation) else { return ids }
            throw error
        }

        guard lifecycleIsCurrent(generation) else { return ids }
        if !dedupeBatch.isEmpty {
            guard await flushFolderEnqueueBatch(dedupeBatch, generation: generation) else { return ids }
        } else if ids.isEmpty {
            notify()
            pump()
        }
        return ids
    }

    private func flushFolderEnqueueBatch(
        _ ids: [UploadQueueItemID],
        generation: UInt64
    ) async -> Bool {
        notify()
        if !Task.isCancelled, let task = primeDedupe(for: ids) {
            await task.value
        }
        guard lifecycleIsCurrent(generation) else { return false }
        pump()
        return true
    }

    private func addItem(
        url: URL,
        destination: UploadDestination,
        cancellationToken: UUID,
        resolvedAlbumID: String?,
        failure: String?
    ) -> UploadQueueItemID {
        let id = UUID()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = UploadItem(
            id: id,
            ordinal: nextOrdinal,
            fileURL: url,
            displayName: url.lastPathComponent,
            mediaType: SupportedMedia.mimeType(for: url) ?? "application/octet-stream",
            byteCount: size,
            state: failure.map { .failed(message: $0) } ?? .queued
        )
        nextOrdinal += 1
        jobs[id] = Job(
            item: item, destination: destination, cancellationToken: cancellationToken,
            settlementRecord: nil, remoteCommitReceipt: nil,
            resolvedAlbumID: resolvedAlbumID, task: nil)
        order.append(id)
        return id
    }

    // MARK: - Durable manual settlement

    /// Starts the replay before an enqueue and notifies after the start returned, so the notification
    /// follows the restore and the scheduling. No `await` can separate them. No handler can receive
    /// this notification today: both registrations assign their handler and start the replay in one
    /// actor segment, so the replay has started whenever a handler exists. It advances the sequence number.
    private func ensureDurableSettlementReplay() {
        switch startDurableSettlementReplaySynchronouslyIfNeeded() {
        case .skipped:
            break
        case .storeUnavailable:
            if requiresDurableSettlement {
                notify()
            }
        case .restored:
            notify()
        }
    }

    private func restoreJobIfNeeded(for record: UploadManualSettlementRecord) {
        guard jobs[record.queueItemID] == nil else { return }
        let state: UploadItemState
        if record.stage == .terminal, record.terminalState == .completed {
            state = .completed
        } else if let lastError = record.lastError, record.stage == .terminal {
            state = .failed(message: lastError)
        } else {
            state = .finalizing
        }
        let item = UploadItem(
            id: record.queueItemID,
            ordinal: record.ordinal,
            fileURL: record.descriptor.fileURL,
            displayName: record.displayName,
            mediaType: record.mediaType,
            byteCount: record.byteCount,
            state: state,
            uploadedUID: record.uploadedUID,
            partialSuccess: record.resolvedAlbumID != nil && record.stage != .terminal
        )
        let destination = record.destination.destination(resolvedAlbumID: record.resolvedAlbumID)
        jobs[record.queueItemID] = Job(
            item: item,
            destination: destination,
            cancellationToken: UUID(),
            settlementRecord: record,
            remoteCommitReceipt: record.receipt,
            resolvedAlbumID: record.resolvedAlbumID,
            task: nil
        )
        order.append(record.queueItemID)
        nextOrdinal = max(nextOrdinal, record.ordinal + 1)
    }

    private func scheduleDurableSettlement(
        _ record: UploadManualSettlementRecord,
        manifestAlreadyRecorded: Bool
    ) {
        guard !isShuttingDown, record.isPending, settlementTasks[record.queueItemID] == nil else { return }
        restoreJobIfNeeded(for: record)
        let task = Task.detached(priority: .utility) { [weak self] in
            let outcome =
                await self?.runDurableSettlement(
                    record,
                    manifestAlreadyRecorded: manifestAlreadyRecorded
                ) ?? .untouched
            await self?.durableSettlementDidFinish(record.queueItemID, outcome: outcome)
        }
        settlementTasks[record.queueItemID] = task
    }

    /// Releases ownership and publishes the settlement result in one synchronous actor block, so a
    /// Retry that sees the published failure also finds the settlement owner released.
    private func durableSettlementDidFinish(_ id: UploadQueueItemID, outcome: DurableSettlementOutcome) {
        jobs[id]?.retryRequested = false
        settlementTasks[id] = nil
        switch outcome {
        case .untouched:
            return
        case .settled(let record):
            applyDurableTerminal(record)
        case .failed(let record, let message):
            recordSettlementFailure(record, message: message)
        }
    }

    /// Replays the exact evidence order used by backup reconciliation: manifest first, album second,
    /// then one durable terminal queue result. Local cancellation is not consulted after the receipt
    /// row exists.
    private func runDurableSettlement(
        _ original: UploadManualSettlementRecord,
        manifestAlreadyRecorded: Bool
    ) async -> DurableSettlementOutcome {
        guard let settlementStore else {
            return .failed(original, message: "Durable manual upload settlement is unavailable.")
        }
        let current: UploadManualSettlementRecord
        switch settlementStore.readOutcome(for: original.queueItemID) {
        case .found(let record):
            current = record
        case .absent:
            return .failed(original, message: "Durable manual upload settlement record is missing.")
        case .unreadable:
            return .failed(original, message: "Durable manual upload settlement could not be read.")
        }
        guard current.isPending else {
            return .untouched
        }
        guard let descriptor = current.descriptor.descriptor else {
            return .failed(current, message: "Durable upload descriptor is invalid.")
        }

        // A replayed receipt proves the bytes reached the library even when local metadata
        // settlement still fails. Preserve the same once-per-manager completion contract as
        // a live upload so the platform refreshes its library after a relaunch.
        emitCompletedUpload(current.queueItemID)

        var record = current
        if record.stage == .manifestPending && !manifestAlreadyRecorded {
            do {
                guard let identityResolver else {
                    throw UploadError.backend("Upload identity resolver is unavailable for settlement.")
                }
                try await identityResolver.recordUploaded(
                    descriptor,
                    identity: record.identity,
                    remoteVolumeID: record.receipt.remoteVolumeID,
                    remoteLinkID: record.receipt.remoteLinkID
                )
            } catch {
                await identityResolver?.remoteCommitNeedsReconciliation(descriptor)
                return .failed(
                    record,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }

        guard let albumID = record.resolvedAlbumID else {
            record.stage = .terminal
            record.terminalState = .completed
            record.lastError = nil
            record.updatedAt = now()
            guard settlementStore.upsert(record) else {
                return .failed(record, message: "Manual upload settlement could not be persisted.")
            }
            return .settled(record)
        }

        record.stage = .albumPending
        record.terminalState = nil
        record.lastError = nil
        record.updatedAt = now()
        guard settlementStore.upsert(record) else {
            return .failed(record, message: "Manual album settlement could not be persisted.")
        }
        updateDurableItemAsFinalizing(record)

        do {
            try await attachToAlbum(
                record.uploadedUID,
                of: record.queueItemID,
                albumID: albumID,
                cover: record.destination.cover.destinationCover
            )
        } catch {
            return .failed(
                record,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        record.stage = .terminal
        record.terminalState = .completed
        record.lastError = nil
        record.updatedAt = now()
        guard settlementStore.upsert(record) else {
            return .failed(record, message: "Manual album settlement could not be persisted.")
        }
        return .settled(record)
    }

    private func updateDurableItemAsFinalizing(_ record: UploadManualSettlementRecord) {
        restoreJobIfNeeded(for: record)
        guard jobs[record.queueItemID] != nil else { return }
        jobs[record.queueItemID]?.settlementRecord = record
        jobs[record.queueItemID]?.remoteCommitReceipt = record.receipt
        jobs[record.queueItemID]?.item.uploadedUID = record.uploadedUID
        jobs[record.queueItemID]?.item.state = .finalizing
        notify()
    }

    private func recordSettlementFailure(_ record: UploadManualSettlementRecord, message: String) {
        guard let settlementStore else { return }
        var failed = record
        failed.lastError = message
        failed.terminalState = nil
        failed.updatedAt = now()
        // Keep the stage pending. A later launch or an explicit retry must replay
        // metadata/album only. Never turn a receipt-backed failure into a fresh byte upload.
        // The pending stage is adopted only when the store durably wrote it. A transient store
        // failure heals at the store's next operation (#1104), so this write usually succeeds and
        // Retry settles the item in the same session. When this write fails too, the cached copy
        // keeps the terminal stage without a terminal state: while the store failure is transient,
        // Retry re-reads the still-pending durable row; while it is lasting, the row offers no
        // Retry and Clear finished drops the item but keeps its durable row. A later launch
        // settles that row once the store can read it again.
        if failed.stage == .terminal {
            failed.stage = failed.resolvedAlbumID != nil ? .albumPending : .manifestPending
            guard settlementStore.upsert(failed) else {
                failed.stage = .terminal
                adoptSettlementFailure(failed, message: message)
                return
            }
        } else {
            _ = settlementStore.upsert(failed)
        }
        adoptSettlementFailure(failed, message: message)
    }

    private func adoptSettlementFailure(
        _ failed: UploadManualSettlementRecord, message: String
    ) {
        jobs[failed.queueItemID]?.settlementRecord = failed
        jobs[failed.queueItemID]?.remoteCommitReceipt = failed.receipt
        jobs[failed.queueItemID]?.retryRequested = false
        restoreJobIfNeeded(for: failed)
        jobs[failed.queueItemID]?.item.uploadedUID = failed.uploadedUID
        if failed.resolvedAlbumID != nil {
            jobs[failed.queueItemID]?.item.partialSuccess = true
            jobs[failed.queueItemID]?.item.state = .failed(
                message: UploadError.albumStep(message).errorDescription ?? message
            )
        } else {
            jobs[failed.queueItemID]?.item.state = .failed(message: message)
        }
        notify()
    }

    private func applyDurableTerminal(_ record: UploadManualSettlementRecord) {
        restoreJobIfNeeded(for: record)
        jobs[record.queueItemID]?.settlementRecord = record
        jobs[record.queueItemID]?.remoteCommitReceipt = record.receipt
        jobs[record.queueItemID]?.item.uploadedUID = record.uploadedUID
        jobs[record.queueItemID]?.item.partialSuccess = false
        switch record.terminalState {
        case .completed:
            jobs[record.queueItemID]?.item.state = .completed
        case .failed:
            jobs[record.queueItemID]?.item.state = .failed(
                message: record.lastError ?? "Manual upload settlement failed."
            )
        case nil:
            return
        }
        jobs[record.queueItemID]?.retryRequested = false
        notify(includingShuttingDown: true)
    }

    private func durableSettlement(for id: UploadQueueItemID) -> UploadManualSettlementReadOutcome {
        if let record = jobs[id]?.settlementRecord {
            // A pending copy is safe to serve. After a failed write its stage or last error can
            // differ from the durable row, but both copies are pending, and every settlement
            // run (`runDurableSettlement`) reads the durable row again before it acts. A terminal
            // copy without a terminal state is not proven terminal (#1104): after a failed
            // terminal write the in-memory copy can say `.terminal` while the durable row is
            // still pending. Re-read the store so it can refute the stale copy.
            if record.isPending || record.isProvenTerminal {
                return .found(record)
            }
        }
        guard let settlementStore else { return .absent }
        switch settlementStore.readOutcome(for: id) {
        case .found(let record):
            jobs[id]?.settlementRecord = record
            jobs[id]?.remoteCommitReceipt = record.receipt
            return .found(record)
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        }
    }

    /// The job has an unsettled record or an unwritten receipt row, and the settlement store
    /// cannot work again before a relaunch (#1104, #1226). No settlement step and no row write can
    /// run for the job in this session: Retry would only read the failed store again. An unsettled
    /// record's durable row is still pending, and a later launch settles it once the store can read
    /// it again. An unwritten receipt row has no durable copy.
    private func settlementWaitsForRelaunch(_ id: UploadQueueItemID) -> Bool {
        guard jobs[id]?.hasUnsettledRecord == true || jobs[id]?.unwrittenReceiptRecord != nil else {
            return false
        }
        return settlementStore?.hasLastingFailure() ?? false
    }

    /// Retry of the job would upload bytes, and the byte gate refuses every byte upload before a
    /// relaunch (#1228): the job has no settlement record, no receipt and no uploaded file, and the
    /// manager requires durable settlement without a store, or its store has a lasting failure.
    private func byteRetryWaitsForRelaunch(_ id: UploadQueueItemID) -> Bool {
        guard let job = jobs[id], job.settlementRecord == nil, job.remoteCommitReceipt == nil,
            job.item.uploadedUID == nil
        else { return false }
        guard let settlementStore else { return requiresDurableSettlement }
        return settlementStore.hasLastingFailure()
    }

    private func itemSnapshot(_ id: UploadQueueItemID) -> UploadItem? {
        jobs[id]?.snapshot(
            retryWaitsForRelaunch: settlementWaitsForRelaunch(id) || byteRetryWaitsForRelaunch(id))
    }

    private func byteUploadGate(for id: UploadQueueItemID) -> ByteUploadGate {
        if jobs[id]?.settlementRecord != nil || jobs[id]?.remoteCommitReceipt != nil {
            return .receiptBacked
        }
        // Without a store no commit callback can write the receipt. A manager that requires durable
        // settlement refuses the bytes, like enqueue does (#1228).
        guard let settlementStore else { return requiresDurableSettlement ? .settlementUnavailable : .allowed }
        switch settlementStore.readOutcome(for: id) {
        case .found(let record):
            jobs[id]?.settlementRecord = record
            jobs[id]?.remoteCommitReceipt = record.receipt
            return .receiptBacked
        case .absent:
            return .allowed
        case .unreadable:
            // A read that failed is never proof that no receipt exists, even when a later
            // store operation has already healed the recorded failure (#1104).
            return .settlementUnavailable
        }
    }

    private func ensureByteUploadAllowed(_ id: UploadQueueItemID) throws {
        switch byteUploadGate(for: id) {
        case .allowed:
            return
        case .receiptBacked:
            throw UploadError.backend("Remote upload receipt exists; byte upload is not retryable.")
        case .settlementUnavailable:
            throw UploadError.backend("Durable manual upload settlement is unavailable; byte upload is blocked.")
        }
    }

    private func hasPendingSettlement(_ id: UploadQueueItemID) -> Bool {
        if let record = jobs[id]?.settlementRecord {
            // An unsettled record keeps the job visible while the store can work (#1104): its
            // durable row is still pending, and Retry can settle it. With a lasting store failure
            // no step can run before a relaunch, so Clear finished drops the job and keeps the row.
            return !record.isProvenTerminal && !settlementWaitsForRelaunch(id)
        }
        // A receipt without a record exists only in memory. The job stays while the store can
        // work, because Retry can still write its row (#1226); with a lasting store failure the row
        // cannot be written before a relaunch, so Clear finished drops the job. A job with neither
        // has no durable row, as `claimActiveCancellation` explains: decide from memory and never
        // read the store for it (#1104).
        return jobs[id]?.remoteCommitReceipt != nil && !settlementWaitsForRelaunch(id)
    }

    private func persistDurableSettlement(
        id: UploadQueueItemID,
        descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        receipt: UploadRemoteCommitReceipt
    ) throws {
        guard let settlementStore,
            let job = jobs[id]
        else {
            throw UploadError.backend("Durable manual upload settlement is unavailable.")
        }
        let record = UploadManualSettlementRecord(
            queueItemID: id,
            ordinal: job.item.ordinal,
            descriptor: UploadResourceDescriptorSnapshot(descriptor),
            identity: identity,
            receipt: receipt,
            displayName: job.item.displayName,
            mediaType: job.item.mediaType,
            byteCount: job.item.byteCount,
            resolvedAlbumID: job.resolvedAlbumID,
            destination: UploadManualSettlementDestination(job.destination),
            stage: .manifestPending,
            updatedAt: now()
        )
        guard writeReceiptRow(record, to: settlementStore) else {
            throw UploadError.backend("Manual upload receipt could not be persisted.")
        }
    }

    /// Writes the receipt row of a live job and caches the record in the same actor step. When
    /// the store refuses the write, the job keeps the receipt and the record in memory only: the
    /// current process must not retry bytes after a remote commit whose durable settlement could
    /// not be written, and the receipt catch of `run`, Retry or shutdown writes the row again
    /// (#1226).
    private func writeReceiptRow(
        _ record: UploadManualSettlementRecord,
        to settlementStore: any UploadManualSettlementStoreProtocol
    ) -> Bool {
        let id = record.queueItemID
        jobs[id]?.remoteCommitReceipt = record.receipt
        guard settlementStore.upsert(record) else {
            jobs[id]?.unwrittenReceiptRecord = record
            return false
        }
        jobs[id]?.settlementRecord = record
        jobs[id]?.unwrittenReceiptRecord = nil
        return true
    }

    /// Writes an unwritten receipt row again (#1226). Call it only after `durableSettlement(for:)`
    /// answered `.absent`, so the write never replaces a row that exists. Returns the written record.
    private func writeUnwrittenReceiptRow(_ id: UploadQueueItemID) -> UploadManualSettlementRecord? {
        guard let settlementStore, let record = jobs[id]?.unwrittenReceiptRecord,
            writeReceiptRow(record, to: settlementStore)
        else { return nil }
        return record
    }

    /// Settles a pending receipt row in this session: metadata and album only, never bytes.
    private func settleReceiptRow(_ record: UploadManualSettlementRecord) {
        let id = record.queueItemID
        guard settlementTasks[id] == nil else { return }
        jobs[id]?.retryRequested = true
        jobs[id]?.item.state = .finalizing
        jobs[id]?.item.uploadedUID = record.uploadedUID
        notify()
        scheduleDurableSettlement(record, manifestAlreadyRecorded: false)
    }

    // MARK: - Scheduler

    private func pump() {
        guard !isShuttingDown else {
            notify()
            return
        }
        while activeIDs.count < maxConcurrent, let id = nextQueuedID() {
            start(id)
        }
        notify()
    }

    private func nextQueuedID() -> UploadQueueItemID? {
        order.first { jobs[$0]?.item.state == .queued && !activeIDs.contains($0) }
    }

    private func start(_ id: UploadQueueItemID) {
        guard !isShuttingDown, var job = jobs[id] else { return }
        activeIDs.insert(id)
        job.item.state = .preparing
        job.task = Task { [weak self] in await self?.run(id) }
        jobs[id] = job
    }

    private func makeRequest(for job: Job) async -> PhotoUploadRequest {
        let url = job.item.fileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date) ?? now()
        let fileFallback = UploadCaptureDateReader.fileSystemFallback(from: attrs ?? [:], default: modified)
        let captureDate = await UploadCaptureDateReader.captureDate(for: url, fallback: fileFallback)
        return PhotoUploadRequest(
            queueItemID: job.item.id,
            cancellationToken: job.cancellationToken,
            fileURL: url,
            name: job.item.displayName,
            mediaType: job.item.mediaType,
            fileSize: job.item.byteCount,
            captureTime: captureDate,
            modificationDate: modified,
            tags: []
        )
    }

    // MARK: - Per-item run

    private func run(_ id: UploadQueueItemID) async {
        guard let job = jobs[id] else { return }
        let activity = runtimeState.beginActivity(.userTransfer)
        defer { activity.end() }
        let request = await makeRequest(for: job)
        // The descriptor mirrors the request snapshot (same name/size/mtime), so manifest rows
        // written here validate against the exact attributes that were uploaded. Hoisted out of
        // the do-block: the catch paths report a failed `.upload` attempt back to the pipeline.
        let descriptor = UploadResourceDescriptor(
            source: .file(request.fileURL),
            fileURL: request.fileURL,
            filename: request.name,
            fileSize: request.fileSize,
            modificationDate: request.modificationDate
        )
        do {
            if currentState(id) == .cancelled || currentState(id) == .paused {
                finish(id)
                return
            }

            // Hash and check duplicates before uploading bytes. The scoped operation settles claims
            // on cancellation, error, and remote commit.
            let outcome: ScopedUploadOutcome
            if let identityResolver {
                transition(id, to: .hashing)
                var onRemoteCommit:
                    (
                        @Sendable (
                            _ identity: UploadIdentity,
                            _ receipt: UploadRemoteCommitReceipt
                        ) async throws -> Void
                    )?
                if settlementStore != nil {
                    // The transport commit and SQLite insert are separate systems. A crash between them
                    // requires a server receipt or idempotency contract that this queue does not provide.
                    onRemoteCommit = { [weak self] identity, receipt in
                        guard let self else {
                            throw UploadError.backend("Upload manager was released before receipt persistence.")
                        }
                        try await self.persistDurableSettlement(
                            id: id,
                            descriptor: descriptor,
                            identity: identity,
                            receipt: receipt
                        )
                    }
                }
                outcome = try await identityResolver.withUploadDecision(
                    descriptor,
                    onRemoteCommit: onRemoteCommit
                ) { [weak self] preflight in
                    guard let self else { throw CancellationError() }
                    return try await self.performScopedUpload(
                        id: id,
                        request: request,
                        preflight: preflight
                    )
                }
            } else {
                try ensureByteUploadAllowed(id)
                let uid = try await upload(request, reportingProgressFor: id)
                outcome = .uploaded(uid)
            }

            let uploadedUID: PhotoUID
            switch outcome {
            case .skipped(let reason):
                transition(id, to: .skipped(reason))
                finish(id)
                return
            case .uploaded(let uid):
                uploadedUID = uid
                setUploadedUID(id, uid)
                // A transport can commit remotely after the local cancellation latch wins. The
                // UID is durable evidence: emit the library completion, and keep an album item as
                // attachment-only partial success so retry never sends the bytes again.
                emitCompletedUpload(id)
                switch durableSettlement(for: id) {
                case .found(let settlement):
                    updateDurableItemAsFinalizing(settlement)
                    scheduleDurableSettlement(settlement, manifestAlreadyRecorded: true)
                    finish(id)
                    return
                case .absent:
                    break
                case .unreadable:
                    // The store cannot confirm that no settlement record exists. Never treat the
                    // unreadable row as absence: album attachment and completion would duplicate
                    // a settlement that a later read can still see. Keep the item retryable.
                    if jobs[id]?.resolvedAlbumID != nil {
                        markPartialFailure(id, message: "Durable manual upload settlement could not be read.")
                    } else {
                        transition(id, to: .failed(message: "Durable manual upload settlement could not be read."))
                    }
                    finish(id)
                    return
                }
                if currentState(id) == .cancelled {
                    if jobs[id]?.resolvedAlbumID != nil {
                        markPartialFailure(id, message: "Upload completed; album attachment was cancelled.")
                    } else {
                        transition(id, to: .completed)
                    }
                    finish(id)
                    return
                }
            }

            if let albumID = jobs[id]?.resolvedAlbumID {
                transition(id, to: .finalizing)
                do {
                    try await attachToAlbum(
                        uploadedUID, of: id, albumID: albumID, cover: jobs[id]?.destination.cover)
                } catch {
                    // The photo upload succeeded, but the album step failed. Keep the partial-success state.
                    markPartialFailure(id, message: message(error))
                    finish(id)
                    return
                }
            }
            transition(id, to: .completed)
        } catch let settlement as UploadRemoteCommitSettlementError {
            // The server has accepted the bytes even though local manifest settlement failed.
            // Preserve the receipt as the queue UID. `withUploadDecision` owns the single
            // reconciliation settlement; this catch only exposes the receipt-backed queue state.
            if settlementStore != nil {
                jobs[id]?.remoteCommitReceipt = settlement.receipt
            }
            let uid = PhotoUID(
                volumeID: settlement.receipt.remoteVolumeID,
                nodeID: settlement.receipt.remoteLinkID
            )
            setUploadedUID(id, uid)
            emitCompletedUpload(id)
            switch durableSettlement(for: id) {
            case .found(let persisted):
                updateDurableItemAsFinalizing(persisted)
                scheduleDurableSettlement(persisted, manifestAlreadyRecorded: false)
                recordSettlementFailure(persisted, message: settlement.settlementMessage)
            case .absent where jobs[id]?.unwrittenReceiptRecord != nil:
                // The read above heals a transient store failure first, so the store has just
                // answered. Write the refused receipt row now, in the same actor step, and settle
                // it (#1226). When the write fails again, keep the item failed with its receipt.
                if let written = writeUnwrittenReceiptRow(id) {
                    settleReceiptRow(written)
                } else if jobs[id]?.resolvedAlbumID != nil {
                    markPartialFailure(id, message: settlement.settlementMessage)
                } else {
                    transition(id, to: .failed(message: settlement.settlementMessage))
                }
            case .absent, .unreadable:
                // Without a readable record the receipt exists only in memory. Keep the item
                // failed: Retry writes its row again while the store can work (#1226). An
                // unreadable row is never treated as absence (#1104).
                if jobs[id]?.resolvedAlbumID != nil {
                    markPartialFailure(id, message: settlement.settlementMessage)
                } else {
                    transition(id, to: .failed(message: settlement.settlementMessage))
                }
            }
        } catch is CancellationError {
            transition(id, to: .cancelled)
        } catch {
            if currentState(id) == .cancelled || currentState(id) == .paused {
                // already handled by cancel()/pause()
            } else {
                transition(id, to: .failed(message: message(error)))
            }
        }
        finish(id)
    }

    private func performScopedUpload(
        id: UploadQueueItemID,
        request: PhotoUploadRequest,
        preflight: UploadPreflightResult
    ) async throws -> UploadDecisionOperationResult<ScopedUploadOutcome> {
        if currentState(id) == .cancelled || currentState(id) == .paused {
            throw CancellationError()
        }
        switch preflight.decision {
        case .upload, .uploadReplacingDraft:
            try ensureByteUploadAllowed(id)
            let effectiveRequest =
                request
                .applying(identity: preflight.identity)
                .replacingExistingDraft(preflight.decision == .uploadReplacingDraft)
            let uid = try await upload(effectiveRequest, reportingProgressFor: id)
            return .remoteCommitted(
                .uploaded(uid),
                receipt: UploadRemoteCommitReceipt(
                    remoteVolumeID: uid.volumeID,
                    remoteLinkID: uid.nodeID
                )
            )

        case .awaitDeletionCheck:
            throw UploadError.backend(L10n.string("backup.issue_deletion_check"))

        case .uploadMissingSecondaries:
            // Manual uploads are single-resource compounds. The primary is already represented.
            return .noUpload(.skipped(.primaryAlreadyPresent))

        case .skip(let reason, _):
            guard let skipReason = UploadSkipReason(duplicateReason: reason) else {
                throw UploadError.backend(reason.blockingMessage)
            }
            return .noUpload(.skipped(skipReason))
        }
    }

    private func attachToAlbum(
        _ uid: PhotoUID,
        of id: UploadQueueItemID,
        albumID: String,
        cover: UploadDestination.Cover?
    ) async throws {
        guard let albums else { throw UploadError.albumStep("no album backend") }
        // Decided before the album request: while it runs, other uploads of this album can record their UIDs.
        let setsFirstUploadedCover =
            cover == .firstUploaded && claimsFirstUploadedCover(id, uid: uid, albumID: albumID)
        try await albums.addPhoto(uid, to: albumID)
        switch cover {
        case .firstUploaded where setsFirstUploadedCover:
            try? await albums.setCover(albumID: albumID, photo: uid)
        case .specific(let coverUID) where coverUID == uid:
            try? await albums.setCover(albumID: albumID, photo: uid)
        default:
            break
        }
    }

    /// Whether `id` is the first item of `albumID` that uploaded. Each item decides once: `setUploadedUID` decides
    /// when the upload returns, and an item restored from a durable settlement decides before its album request.
    private func claimsFirstUploadedCover(_ id: UploadQueueItemID, uid: PhotoUID, albumID: String) -> Bool {
        if let decided = jobs[id]?.claimsFirstUploadedCover { return decided }
        let decided = isFirstUploadedInAlbum(uid, albumID: albumID)
        jobs[id]?.claimsFirstUploadedCover = decided
        return decided
    }

    private func isFirstUploadedInAlbum(_ uid: PhotoUID, albumID: String) -> Bool {
        !order.contains { id in
            guard let job = jobs[id] else { return false }
            return job.resolvedAlbumID == albumID && job.item.uploadedUID != nil && job.item.uploadedUID != uid
        }
    }

    private func finish(_ id: UploadQueueItemID) {
        activeIDs.remove(id)
        jobs[id]?.task = nil
        pump()
    }

    private func lifecycleIsCurrent(_ generation: UInt64) -> Bool {
        !isShuttingDown && !didShutDown && lifecycleGeneration == generation
    }

    private func finishControl(_ id: UploadQueueItemID, controlID: UUID) {
        guard jobs[id]?.controlID == controlID else { return }
        jobs[id]?.controlTask = nil
        jobs[id]?.controlID = nil
    }

    // MARK: - State transitions

    private func currentState(_ id: UploadQueueItemID) -> UploadItemState? { jobs[id]?.item.state }

    /// Bridges an arbitrarily chatty synchronous SDK callback into one structured consumer. The newest-value
    /// buffer prevents one unstructured Task per byte/block callback, while finishing and joining the stream
    /// guarantees that the latest progress is applied before the terminal upload state is published.
    private func upload(
        _ request: PhotoUploadRequest,
        reportingProgressFor id: UploadQueueItemID
    ) async throws -> PhotoUID {
        // The item keeps its current state while it waits for a running backup transfer to end.
        let reservation = try await uploader.reserveNetwork(allowsExpensiveNetwork: request.allowsExpensiveNetwork)
        defer { reservation.release() }
        var request = request
        request.networkReservation = reservation
        let (stream, continuation) = AsyncStream.makeStream(
            of: UploadProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let consumer = Task { [weak self] in
            for await progress in stream {
                guard !Task.isCancelled else { return }
                await self?.applyProgress(id, progress)
            }
        }
        do {
            let uid = try await uploader.upload(request) { progress in
                continuation.yield(progress)
            }
            continuation.finish()
            await consumer.value
            return uid
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }

    private func transition(_ id: UploadQueueItemID, to state: UploadItemState) {
        guard jobs[id] != nil else { return }
        jobs[id]?.item.state = state
        notify()
    }

    private func applyProgress(_ id: UploadQueueItemID, _ progress: UploadProgress) {
        guard let state = jobs[id]?.item.state, state.isActive, state != .finalizing else { return }
        let next: UploadItemState
        switch progress.phase {
        case .preparing:
            next = .preparing
        case .hashing:
            next = .hashing
        case .uploading:
            let clamped = min(1, max(0, progress.fraction))
            let quantized = floor(clamped * 100) / 100
            if case .uploading(let previous) = state, quantized <= previous { return }
            next = .uploading(progress: quantized)
        }
        guard next != state else { return }
        jobs[id]?.item.state = next
        notify()
    }

    private func setUploadedUID(_ id: UploadQueueItemID, _ uid: PhotoUID) {
        jobs[id]?.item.uploadedUID = uid
        // Decide the first-uploaded cover in the same actor step that records the UID. Decided after the album
        // request, concurrent uploads of one album would each see the others' UIDs, and none would set the cover.
        if jobs[id]?.destination.cover == .firstUploaded, let albumID = jobs[id]?.resolvedAlbumID {
            _ = claimsFirstUploadedCover(id, uid: uid, albumID: albumID)
        }
    }

    private func emitCompletedUpload(_ id: UploadQueueItemID) {
        guard let job = jobs[id], let uid = job.item.uploadedUID else { return }
        guard emittedCompletionIDs.insert(id).inserted else { return }
        onCompleted?(
            UploadCompletedEvent(
                id: id,
                uploadedUID: uid,
                displayName: job.item.displayName,
                destination: job.destination,
                resolvedAlbumID: job.resolvedAlbumID
            ))
    }

    private func markPartialFailure(_ id: UploadQueueItemID, message: String) {
        jobs[id]?.item.partialSuccess = true
        jobs[id]?.item.state = .failed(message: UploadError.albumStep(message).errorDescription!)
        notify()
    }

    /// Claims the live cancellation latch before any await. Both item cancellation and shutdown
    /// use this actor-isolated helper, so a stale job snapshot cannot forward native cancel twice.
    private func claimActiveCancellation(
        _ id: UploadQueueItemID
    ) -> (uploadTask: Task<Void, Never>?, nativeTask: Task<Void, Never>)? {
        // Decide from memory only (#1104). A job's durable row is written by `writeReceiptRow`,
        // which caches the record in the same actor step, or restored by the replay, which caches
        // it too. A job without a cached record or receipt has no durable row, so a failed store
        // read must never block its cancellation.
        guard jobs[id]?.remoteCommitReceipt == nil, jobs[id]?.settlementRecord == nil else { return nil }
        guard activeIDs.contains(id), var job = jobs[id], !job.item.state.isTerminal else { return nil }
        guard !job.cancellationRequested else { return nil }
        job.cancellationRequested = true
        job.item.state = .cancelled
        let token = job.cancellationToken
        let uploader = self.uploader
        let nativeTask = Task { await uploader.cancel(token: token) }
        job.nativeCancellationTask = nativeTask
        let claim = (uploadTask: job.task, nativeTask: nativeTask)
        jobs[id] = job
        return claim
    }

    // MARK: - Controls

    public func pause(_ id: UploadQueueItemID) async {
        guard !isShuttingDown else { return }
        // A receipt or a pending record is the irreversible boundary. Decide from memory only, as
        // `claimActiveCancellation` explains: a failed store read must never block a pause (#1104).
        if jobs[id]?.remoteCommitReceipt != nil || jobs[id]?.settlementRecord?.isPending == true { return }
        guard let state = jobs[id]?.item.state else { return }
        switch state {
        case .queued:
            jobs[id]?.item.state = .paused
            notify()
        case .uploading, .preparing, .hashing:
            jobs[id]?.item.state = .paused
            notify()
            let token = jobs[id]!.cancellationToken
            let controlID = UUID()
            let uploader = self.uploader
            let task: Task<Void, Never> = Task { [weak self] in
                try? await uploader.pause(token: token)
                guard let self else { return }
                await self.finishControl(id, controlID: controlID)
            }
            jobs[id]?.controlID = controlID
            jobs[id]?.controlTask = task
            await task.value
        default:
            break
        }
    }

    public func resume(_ id: UploadQueueItemID) async {
        guard !isShuttingDown else { return }
        guard jobs[id]?.item.state == .paused else { return }
        if activeIDs.contains(id) {
            // Mid-flight pause: ask the backend to continue the same transfer.
            jobs[id]?.item.state = .uploading(progress: 0)
            notify()
            let token = jobs[id]!.cancellationToken
            let controlID = UUID()
            let uploader = self.uploader
            let task: Task<Void, Never> = Task { [weak self] in
                try? await uploader.resume(token: token)
                guard let self else { return }
                await self.finishControl(id, controlID: controlID)
            }
            jobs[id]?.controlID = controlID
            jobs[id]?.controlTask = task
            await task.value
        } else {
            jobs[id]?.item.state = .queued
            pump()
        }
    }

    public func cancel(_ id: UploadQueueItemID) async {
        guard !isShuttingDown else { return }
        // A persisted receipt is the irreversible boundary. Cancellation cannot demote its
        // manifest/album replay, even when the transport task still appears active. Decide from
        // memory only, as `claimActiveCancellation` explains (#1104).
        if jobs[id]?.remoteCommitReceipt != nil || jobs[id]?.settlementRecord?.isPending == true { return }
        guard let state = jobs[id]?.item.state, !state.isTerminal else { return }
        if let claim = claimActiveCancellation(id) {
            await claim.nativeTask.value
            claim.uploadTask?.cancel()
            // Cancellation is not complete until the scoped upload decision has released its
            // content/name claims. Awaiting the item task prevents callers from observing a
            // terminal UI state while identical waiters are still blocked behind this upload.
            await claim.uploadTask?.value
        } else if activeIDs.contains(id) {
            // Another actor-isolated control path already claimed cancellation. Wait for that
            // task, but never forward native cancellation from this stale call.
            await jobs[id]?.nativeCancellationTask?.value
            await jobs[id]?.task?.value
        } else {
            jobs[id]?.retryRequested = false
            jobs[id]?.cancellationRequested = true
            jobs[id]?.item.state = .cancelled
        }
        notify()
    }

    /// Ordered account teardown. No queued item may start after this point; active transports are
    /// cancelled and every per-item task is awaited before account-owned manifests are closed.
    public func shutdown() async {
        if !isShuttingDown {
            isShuttingDown = true
            lifecycleGeneration &+= 1
        }
        await shutdownGate.run { [weak self] in
            await self?.performShutdown()
        }
    }

    private func performShutdown() async {
        let resolutions = Array(albumResolutionTasks.values)
        albumResolutionTasks.removeAll()
        resolutions.forEach { $0.cancel() }
        for task in resolutions {
            _ = await task.value
        }

        let dedupeTasks = Array(dedupePrimeTasks.values)
        dedupePrimeTasks.removeAll()
        dedupeTasks.forEach { $0.cancel() }
        for task in dedupeTasks {
            await task.value
        }

        let controlTasks = jobs.values.compactMap(\.controlTask)
        for task in controlTasks {
            await task.value
        }

        // Claim every live item before the first suspension. A concurrent `cancel` call sees the
        // latch and waits instead of issuing a second native cancel after this snapshot goes stale.
        let activeTasks = jobs.values.compactMap(\.task)
        for id in activeIDs {
            _ = claimActiveCancellation(id)
        }

        // A cancel call that entered before shutdown owns the same stored native task. Await every
        // one before cancelling its outer upload task, so token cleanup cannot race native cancel.
        let nativeCancellationTasks = jobs.values.compactMap(\.nativeCancellationTask)
        for task in nativeCancellationTasks {
            await task.value
        }
        for task in activeTasks {
            task.cancel()
        }
        for task in activeTasks {
            await task.value
        }
        while !settlementTasks.isEmpty {
            let tasks = Array(settlementTasks.values)
            for task in tasks {
                await task.value
            }
        }
        // The account session ends here. Write every receipt row that the store refused before
        // (#1226). When the account data stays, the next launch settles the row.
        for id in order where jobs[id]?.unwrittenReceiptRecord != nil {
            guard case .absent = durableSettlement(for: id) else { continue }
            _ = writeUnwrittenReceiptRow(id)
        }
        settlementStore?.close()
        activeIDs.removeAll()
        jobs.removeAll()
        order.removeAll()
        onChange = nil
        onSequencedChange = nil
        onCompleted = nil
        didShutDown = true
    }

    public func retry(_ id: UploadQueueItemID) async {
        guard !isShuttingDown else { return }
        guard let job = jobs[id], job.item.state.isTerminal || job.item.state == .paused else { return }
        // A paused item can still own a live native operation. Never replace its token until the
        // prior task has settled, or a later cancel would target a different transport.
        guard !activeIDs.contains(id) else { return }
        guard !job.retryRequested else { return }
        // A Retry that cannot pass the byte gate before a relaunch only fails again (#1228). The store
        // failure can be new since the last publish, so publish the row again: it no longer offers Retry.
        guard !byteRetryWaitsForRelaunch(id) else {
            notify()
            return
        }
        // A job without a cached record or receipt has no durable row, as
        // `claimActiveCancellation` explains. Decide from memory, so a store that cannot be read
        // never blocks its Retry; the byte gate still refuses bytes while the store cannot be read.
        var durable: UploadManualSettlementReadOutcome =
            job.settlementRecord == nil && job.remoteCommitReceipt == nil ? .absent : durableSettlement(for: id)
        if jobs[id]?.remoteCommitReceipt != nil, case .absent = durable {
            // The receipt lives only in memory: the store refused its row after the remote commit
            // (#1226). Write the row now. A store whose transient failure healed accepts it, and the
            // item then settles from the row like a replayed one, without a byte upload. When the
            // write fails again, the item stays failed. Publish the row again: a lasting failure
            // removes its Retry.
            guard let written = writeUnwrittenReceiptRow(id) else {
                notify()
                return
            }
            durable = .found(written)
        }
        switch durable {
        case .found(let persisted) where !persisted.isPending:
            return

        // Receipt-backed rows retry only metadata and album settlement. They must never return to
        // the byte-upload path, even when the previous process stopped during manifest recording.
        case .found(let persisted):
            settleReceiptRow(persisted)
            return

        case .unreadable:
            // An unreadable read is not proof that the row is absent. Fail closed: never fall
            // through to the byte-upload retry path while the store cannot be read (#1104). The
            // failed read can be lasting, so publish the row again: it may no longer offer Retry.
            notify()
            return

        case .absent:
            break
        }

        if job.item.partialSuccess, let uid = job.item.uploadedUID, let albumID = job.resolvedAlbumID {
            // The file is already uploaded; only the album step failed. Retry just that step.
            jobs[id]?.retryRequested = true
            jobs[id]?.generation &+= 1
            let generation = jobs[id]?.generation ?? 0
            jobs[id]?.item.state = .finalizing
            jobs[id]?.item.partialSuccess = false
            notify()
            let controlID = UUID()
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.runAlbumRetry(
                    id: id,
                    uid: uid,
                    albumID: albumID,
                    cover: job.destination.cover,
                    generation: generation,
                    controlID: controlID
                )
            }
            jobs[id]?.controlID = controlID
            jobs[id]?.controlTask = task
            await task.value
            return
        }
        // Unsupported files can't be retried into success.
        if case .failed = job.item.state, !SupportedMedia.isSupported(job.item.fileURL) { return }
        // The failed attempt may have committed server-side (lost response). Re-resolve against
        // fresh remote state so the retry skips as a duplicate instead of uploading twice.
        jobs[id]?.retryRequested = true
        jobs[id]?.generation &+= 1
        let generation = jobs[id]?.generation ?? 0
        jobs[id]?.cancellationToken = UUID()
        jobs[id]?.cancellationRequested = false
        jobs[id]?.item.state = .queued
        jobs[id]?.item.uploadedUID = nil
        jobs[id]?.claimsFirstUploadedCover = nil
        notify()
        let controlID = UUID()
        let resolver = identityResolver
        let retryLifecycleGeneration = lifecycleGeneration
        let task: Task<Void, Never> = Task { [weak self] in
            await resolver?.invalidateCachedRemoteState()
            guard let self else { return }
            await self.retryInvalidationDidFinish(
                id: id,
                generation: generation,
                lifecycleGeneration: retryLifecycleGeneration,
                controlID: controlID
            )
        }
        jobs[id]?.controlID = controlID
        jobs[id]?.controlTask = task
        await task.value
    }

    private func runAlbumRetry(
        id: UploadQueueItemID,
        uid: PhotoUID,
        albumID: String,
        cover: UploadDestination.Cover?,
        generation: UInt64,
        controlID: UUID
    ) async {
        do {
            try await attachToAlbum(uid, of: id, albumID: albumID, cover: cover)
            guard jobs[id]?.generation == generation,
                jobs[id]?.retryRequested == true
            else {
                finishControl(id, controlID: controlID)
                return
            }
            jobs[id]?.retryRequested = false
            transition(id, to: .completed)
        } catch {
            if jobs[id]?.generation == generation, jobs[id]?.retryRequested == true {
                jobs[id]?.retryRequested = false
                markPartialFailure(id, message: message(error))
            }
        }
        finishControl(id, controlID: controlID)
    }

    private func retryInvalidationDidFinish(
        id: UploadQueueItemID,
        generation: UInt64,
        lifecycleGeneration: UInt64,
        controlID: UUID
    ) {
        defer { finishControl(id, controlID: controlID) }
        guard lifecycleIsCurrent(lifecycleGeneration),
            jobs[id]?.generation == generation,
            jobs[id]?.retryRequested == true,
            jobs[id]?.item.state == .queued
        else { return }
        // A retry is a new transport attempt. The latch is released only after the cache
        // invalidation completes and the generation still owns this queued attempt.
        jobs[id]?.retryRequested = false
        pump()
    }

    #if DEBUG
        /// Runs one scheduling pass, as a new item or a finished upload does. Tests check what a pass leaves alone.
        package func pumpForTesting() {
            pump()
        }
    #endif

    public func clearFinished() {
        guard !isShuttingDown else { return }
        let keep = order.filter {
            !(jobs[$0]?.item.state.isTerminal ?? true)
                || activeIDs.contains($0)
                || hasPendingSettlement($0)
        }
        let keepIDs = Set(keep)
        for id in order where !keepIDs.contains(id) {
            // Only a proven-terminal record has finished settlement, so only its durable row is
            // removed. Every other job dropped here has no durable row (no record and no receipt)
            // or keeps its still-pending row for a later launch (#1104).
            if jobs[id]?.settlementRecord?.isProvenTerminal == true {
                _ = settlementStore?.remove(queueItemID: id)
            }
            jobs[id] = nil
        }
        order = keep
        notify()
    }

    // MARK: - Introspection

    public func snapshot() -> [UploadItem] {
        guard !isShuttingDown else { return [] }
        if !settlementReplayStarted {
            // `snapshot` is async for callers outside the actor, but this actor method cannot await
            // itself. The handler registrations, `notify()` and the enqueue functions start the replay
            // too; a snapshot that comes first starts it here, without a notification.
            startDurableSettlementReplaySynchronouslyIfNeeded()
        }
        return order.compactMap { itemSnapshot($0) }
    }

    /// Loads durable rows once per manager lifetime and schedules only the metadata/album replay
    /// stages. This path never calls `PhotoUploading.upload`. It never notifies and the caller decides
    /// from the result. Five places start it: `snapshot()`, `notify()`, both handler registrations (they
    /// notify after the start) and `ensureDurableSettlementReplay()`, the only one that uses the result.
    @discardableResult
    private func startDurableSettlementReplaySynchronouslyIfNeeded() -> DurableSettlementReplayStart {
        guard !isShuttingDown, !settlementReplayStarted else { return .skipped }
        guard let settlementStore else { return .skipped }
        let records: [UploadManualSettlementRecord]
        switch settlementStore.readAllOutcome() {
        case .records(let rows):
            records = rows
        case .unreadable:
            // Latching the flag on a failed sweep would skip the replay for the whole
            // session (#1104). Leave it unset so the next trigger retries the sweep
            // after the transient store failure heals.
            return .storeUnavailable
        }
        settlementReplayStarted = true
        // A row whose job already lives in this session belongs to that job: its live upload or
        // its settlement task owns it. A sweep that succeeds late must not start a second owner,
        // which would record the manifest twice (#1104).
        let restored = records.filter { jobs[$0.queueItemID] == nil }
        for record in restored { restoreJobIfNeeded(for: record) }
        for record in restored where record.isPending {
            scheduleDurableSettlement(record, manifestAlreadyRecorded: false)
        }
        return .restored
    }

    private func notify(includingShuttingDown: Bool = false) {
        if !includingShuttingDown, !settlementReplayStarted {
            startDurableSettlementReplaySynchronouslyIfNeeded()
        }
        var items: [UploadItem] = []
        items.reserveCapacity(order.count)
        var stats = UploadQueueStats()
        stats.persistenceUnavailable =
            requiresDurableSettlement && !(settlementStore?.isOperational() ?? false)
        for id in order {
            guard let item = itemSnapshot(id) else { continue }
            items.append(item)
            switch item.state {
            case .queued: stats.queued += 1
            case .preparing, .hashing, .uploading, .finalizing: stats.active += 1
            case .completed: stats.completed += 1
            case .skipped(let reason):
                if reason.countsAsBackedUp {
                    stats.skippedDuplicates += 1
                } else {
                    stats.skippedRemoteDeletions += 1
                }
            case .failed: stats.failed += 1
            case .cancelled: stats.cancelled += 1
            case .paused: stats.paused += 1
            }
        }
        nextChangeSequence &+= 1
        onChange?(items, stats)
        onSequencedChange?(nextChangeSequence, items, stats)
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension UploadSkipReason {
    init?(duplicateReason: UploadDuplicateDecision.SkipReason) {
        switch duplicateReason {
        case .activeDuplicate:
            self = .activeDuplicate
        case .knownFromManifest:
            self = .knownFromManifest
        case .trashedDuplicate:
            self = .trashedDuplicate
        case .deletedRemotely:
            self = .deletedRemotely
        case .draftExists, .inconsistentRemoteState:
            return nil
        }
    }
}

private extension UploadDuplicateDecision.SkipReason {
    var blockingMessage: String {
        switch self {
        case .draftExists:
            return L10n.string("upload.error_remote_draft")
        case .inconsistentRemoteState:
            return L10n.string("upload.error_remote_inconsistent")
        case .activeDuplicate, .knownFromManifest, .trashedDuplicate, .deletedRemotely:
            return L10n.string("upload.error_duplicate_check_blocked")
        }
    }
}
