import Foundation
import MLSearchCore
import MediaFeedCore
import PhotosCore
import ProtonDriveBackend

/// Shared host binding for source inventory, encrypted thumbnail retention, and ML asset publication.
/// Platform shells provide only the primary items and a lightweight index-change notification.
public actor LibrarySourceAnalysisRuntime {
    private static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(5), .seconds(30),
    ]

    private let coordinator: LibrarySourceCoordinator
    private let feed: ThumbnailFeedCore
    private let assets: MLAssetUniverse
    private let onAssetsChanged: @Sendable () -> Void
    private let retryDelays: [Duration]
    private var refreshTask: Task<LibrarySourceRefreshOutcome, Never>?
    private var refreshGeneration: UInt64 = 0
    private var refreshRequestedWhileActive = false
    private var refreshHasEnteredCoordinator = false
    private var refreshRetryTask: Task<Void, Never>?
    private var refreshRetryGeneration: UInt64 = 0
    private var reconciliationRetryTask: Task<Void, Never>?
    private var reconciliationRetryGeneration: UInt64 = 0
    private var pendingReconciliationRetryChange: LibrarySourceChange?
    private var activeRetryOperations = 0
    private var retryDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingPrimaryInventory:
        (
            items: [PhotoItem],
            authority: SourceInventoryAuthority,
            generation: UInt64
        )?
    private var latestPrimaryInventoryGeneration: UInt64?
    private var primaryInventoryOutcome: (generation: UInt64, admission: PrimaryInventoryAdmission)?
    private var startupTask: Task<Bool, Never>?
    private var applyingPrimaryInventory = false
    private var primaryInventoryDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeApplyCount = 0
    private var applyDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingChange: LibrarySourceChange?
    private var started = false
    private var isActive: Bool
    private var closed = false

    public init(
        coordinator: LibrarySourceCoordinator,
        feed: ThumbnailFeedCore,
        assets: MLAssetUniverse,
        initiallyActive: Bool = true,
        onAssetsChanged: @escaping @Sendable () -> Void
    ) {
        self.coordinator = coordinator
        self.feed = feed
        self.assets = assets
        self.onAssetsChanged = onAssetsChanged
        isActive = initiallyActive
        retryDelays = Self.defaultRetryDelays
    }

    package init(
        coordinator: LibrarySourceCoordinator,
        feed: ThumbnailFeedCore,
        assets: MLAssetUniverse,
        retryDelays: [Duration],
        initiallyActive: Bool = true,
        onAssetsChanged: @escaping @Sendable () -> Void
    ) {
        self.coordinator = coordinator
        self.feed = feed
        self.assets = assets
        self.onAssetsChanged = onAssetsChanged
        self.retryDelays = retryDelays
        isActive = initiallyActive
    }

    /// Binds the three consumers to one graph epoch before any authoritative inventory is published.
    @discardableResult
    public func start() async -> Bool {
        guard !closed else { return false }
        if let startupTask { return await startupTask.value && !closed }
        if started {
            await drainPrimaryInventory()
            return !closed
        }
        let task = Task { await self.bindConsumers() }
        startupTask = task
        let ready = await task.value
        startupTask = nil
        return ready && !closed
    }

    private func bindConsumers() async -> Bool {
        let initial = await coordinator.attach { [weak self] change in
            await self?.receive(change)
        }
        guard !closed else {
            await coordinator.detach()
            return false
        }
        assets.resetSourceSession(to: initial.analysisScope.epoch)
        guard await feed.bindDerivedDataEpoch(initial.analysisScope.epoch) else {
            await coordinator.detach()
            pendingChange = nil
            return false
        }
        guard !closed else {
            await coordinator.detach()
            pendingChange = nil
            return false
        }
        let current = await coordinator.snapshot()
        guard !closed else {
            await coordinator.detach()
            pendingChange = nil
            return false
        }
        let latest: LibrarySourceChange
        if let pendingChange,
            pendingChange.analysisScope.revision > current.analysisScope.revision
        {
            latest = pendingChange
        } else {
            latest = current
        }
        pendingChange = nil
        started = true
        await apply(latest)
        guard !closed else { return false }
        await drainPrimaryInventory()
        guard !closed else { return false }
        scheduleRefresh()
        return true
    }

    /// Starts with a host-generation-fenced primary inventory. A newer update which arrives while
    /// binding wins even if this startup task was delayed behind an older runtime shutdown.
    @discardableResult
    public func start(
        primaryItems: [PhotoItem],
        authority: SourceInventoryAuthority,
        generation: UInt64
    ) async -> PrimaryInventoryAdmission {
        stagePrimaryInventory(primaryItems, authority: authority, generation: generation)
        guard await start() else { return .unavailable }
        return admission(for: generation)
    }

    @discardableResult
    public func replacePrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority
    ) async -> PrimaryInventoryAdmission {
        let generation = (latestPrimaryInventoryGeneration ?? 0) &+ 1
        return await replacePrimaryInventory(
            items,
            authority: authority,
            generation: generation
        )
    }

    @discardableResult
    public func replacePrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority,
        generation: UInt64
    ) async -> PrimaryInventoryAdmission {
        guard !closed else { return .unavailable }
        stagePrimaryInventory(items, authority: authority, generation: generation)
        if let startupTask { _ = await startupTask.value }
        guard started else { return .deferred }
        await drainPrimaryInventory()
        return admission(for: generation)
    }

    private func admission(for generation: UInt64) -> PrimaryInventoryAdmission {
        guard !closed else { return .unavailable }
        guard let primaryInventoryOutcome, primaryInventoryOutcome.generation == generation else {
            return .superseded
        }
        return primaryInventoryOutcome.admission
    }

    private func stagePrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority,
        generation: UInt64
    ) {
        guard !closed else { return }
        if let latestPrimaryInventoryGeneration,
            generation <= latestPrimaryInventoryGeneration
        {
            return
        }
        latestPrimaryInventoryGeneration = generation
        if pendingPrimaryInventory?.authority == .authoritative,
            authority != .authoritative
        {
            return
        }
        pendingPrimaryInventory = (items, authority, generation)
    }

    private func drainPrimaryInventory() async {
        guard !applyingPrimaryInventory else {
            await waitForPrimaryInventoryDrain()
            return
        }
        applyingPrimaryInventory = true
        defer { finishPrimaryInventoryDrain() }
        while !closed, let pendingPrimaryInventory {
            self.pendingPrimaryInventory = nil
            let result = await coordinator.replacePrimaryInventory(
                pendingPrimaryInventory.items,
                authority: pendingPrimaryInventory.authority
            )
            primaryInventoryOutcome = (pendingPrimaryInventory.generation, result)
        }
    }

    private func finishPrimaryInventoryDrain() {
        applyingPrimaryInventory = false
        let waiters = primaryInventoryDrainWaiters
        primaryInventoryDrainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForPrimaryInventoryDrain() async {
        guard applyingPrimaryInventory else { return }
        await withCheckedContinuation { continuation in
            primaryInventoryDrainWaiters.append(continuation)
        }
    }

    public func refresh() async {
        guard started, isActive, !closed else { return }
        cancelRefreshRetry()
        if let activeRefresh = refreshTask {
            // Requests which arrive before the owner has entered the coordinator are already represented
            // by its pending first pass. Once admission has happened, request exactly one fresh follow-up.
            if refreshHasEnteredCoordinator { refreshRequestedWhileActive = true }
            _ = await activeRefresh.value
            return
        }
        scheduleRefresh()
        let activeRefresh = refreshTask
        _ = await activeRefresh?.value
    }

    /// Pauses remote refresh and retry owners while an iOS host is inactive without discarding the
    /// already-published graph, encrypted cache, or ML inventory. Reactivation performs one fresh refresh and
    /// resumes a failed local cache reconciliation, if one was pending.
    public func setActive(_ active: Bool) async {
        guard !closed, active != isActive else { return }
        isActive = active
        if active {
            if let pendingReconciliationRetryChange {
                scheduleReconciliationRetry(pendingReconciliationRetryChange)
            }
            scheduleRefresh()
            return
        }

        await stopRefreshWork()
    }

    /// Stops the running refresh and both retry owners and waits until they have finished.
    /// Shared by the inactive and the shutdown path; each caller keeps its own steps around it.
    private func stopRefreshWork() async {
        refreshGeneration &+= 1
        let activeRefresh = refreshTask
        let refreshRetry = refreshRetryTask
        let reconciliationRetry = reconciliationRetryTask
        activeRefresh?.cancel()
        refreshRequestedWhileActive = false
        refreshHasEnteredCoordinator = false
        cancelRefreshRetry()
        cancelReconciliationRetry()
        await coordinator.cancelRefresh()
        _ = await activeRefresh?.value
        await refreshRetry?.value
        await reconciliationRetry?.value
        await waitForRetryDrain()
        refreshTask = nil
    }

    private func scheduleRefresh() {
        guard started, isActive, !closed, refreshTask == nil else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshRequestedWhileActive = false
        refreshHasEnteredCoordinator = false
        refreshTask = Task { [weak self] in
            guard let self else { return .cancelled }
            return await self.runRefreshLoop(generation: generation)
        }
    }

    private func runRefreshLoop(generation: UInt64) async -> LibrarySourceRefreshOutcome {
        while isActive, !closed, refreshGeneration == generation, !Task.isCancelled {
            refreshHasEnteredCoordinator = true
            let outcome = await coordinator.refresh()
            guard isActive, !closed, refreshGeneration == generation, !Task.isCancelled else {
                return .cancelled
            }
            guard refreshRequestedWhileActive else {
                didFinishRefresh(generation: generation, outcome: outcome)
                return outcome
            }
            refreshRequestedWhileActive = false
        }
        return .cancelled
    }

    private func didFinishRefresh(
        generation: UInt64,
        outcome: LibrarySourceRefreshOutcome
    ) {
        guard refreshGeneration == generation else { return }
        refreshTask = nil
        refreshHasEnteredCoordinator = false
        if outcome == .retryableFailure { scheduleRefreshRetry() }
    }

    private func scheduleRefreshRetry() {
        guard isActive, !closed, refreshRetryTask == nil, !retryDelays.isEmpty else { return }
        refreshRetryGeneration &+= 1
        let generation = refreshRetryGeneration
        activeRetryOperations += 1
        refreshRetryTask = Task { [weak self] in
            await self?.runRefreshRetries(generation: generation)
        }
    }

    private func runRefreshRetries(generation: UInt64) async {
        defer { finishRetryOperation() }
        for delay in retryDelays {
            do {
                try await Task.sleep(for: delay)
            } catch {
                break
            }
            guard isActive, !closed, refreshRetryGeneration == generation, !Task.isCancelled else {
                break
            }
            scheduleRefresh()
            guard let activeRefresh = refreshTask else { break }
            let outcome = await activeRefresh.value
            guard isActive, !closed, refreshRetryGeneration == generation, !Task.isCancelled else {
                break
            }
            if outcome != .retryableFailure { break }
        }
        if refreshRetryGeneration == generation { refreshRetryTask = nil }
    }

    private func cancelRefreshRetry() {
        refreshRetryGeneration &+= 1
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
    }

    private func receive(_ change: LibrarySourceChange) async {
        guard !closed else { return }
        guard started else {
            pendingChange = change
            return
        }
        await apply(change)
    }

    private func apply(_ change: LibrarySourceChange) async {
        guard started, !closed else { return }
        cancelReconciliationRetry()
        pendingReconciliationRetryChange = nil
        activeApplyCount += 1
        defer { finishApply() }
        let result = await feed.reconcile(
            selected: change.selectedScope,
            analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope
        )
        guard !closed, result != .unbound, result != .staleScope else { return }
        if result == .ioFailure { scheduleReconciliationRetry(change) }
        if assets.publish(change.analysisScope) {
            onAssetsChanged()
        }
    }

    private func scheduleReconciliationRetry(_ change: LibrarySourceChange) {
        pendingReconciliationRetryChange = change
        guard isActive, !closed, reconciliationRetryTask == nil, !retryDelays.isEmpty else { return }
        reconciliationRetryGeneration &+= 1
        let generation = reconciliationRetryGeneration
        activeRetryOperations += 1
        reconciliationRetryTask = Task { [weak self] in
            await self?.runReconciliationRetries(change, generation: generation)
        }
    }

    private func runReconciliationRetries(
        _ change: LibrarySourceChange,
        generation: UInt64
    ) async {
        defer { finishRetryOperation() }
        for delay in retryDelays {
            do {
                try await Task.sleep(for: delay)
            } catch {
                break
            }
            guard isActive, !closed, reconciliationRetryGeneration == generation, !Task.isCancelled else {
                break
            }
            let result = await feed.reconcile(
                selected: change.selectedScope,
                analysis: change.analysisScope,
                retention: change.thumbnailRetentionScope
            )
            guard isActive, !closed, reconciliationRetryGeneration == generation, !Task.isCancelled else {
                break
            }
            if result != .ioFailure {
                if pendingReconciliationRetryChange?.analysisScope.epoch == change.analysisScope.epoch,
                    pendingReconciliationRetryChange?.analysisScope.revision == change.analysisScope.revision
                {
                    pendingReconciliationRetryChange = nil
                }
                break
            }
        }
        if reconciliationRetryGeneration == generation { reconciliationRetryTask = nil }
    }

    private func cancelReconciliationRetry() {
        reconciliationRetryGeneration &+= 1
        reconciliationRetryTask?.cancel()
        reconciliationRetryTask = nil
    }

    private func finishRetryOperation() {
        activeRetryOperations -= 1
        guard activeRetryOperations == 0 else { return }
        let waiters = retryDrainWaiters
        retryDrainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForRetryDrain() async {
        guard activeRetryOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            retryDrainWaiters.append(continuation)
        }
    }

    private func finishApply() {
        activeApplyCount -= 1
        guard activeApplyCount == 0 else { return }
        let waiters = applyDrainWaiters
        applyDrainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForApplyDrain() async {
        guard activeApplyCount > 0 else { return }
        await withCheckedContinuation { continuation in
            applyDrainWaiters.append(continuation)
        }
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        isActive = false
        let startup = startupTask
        startup?.cancel()
        await stopRefreshWork()
        _ = await startup?.value
        await waitForPrimaryInventoryDrain()
        await waitForApplyDrain()
        await coordinator.detach()
        pendingPrimaryInventory = nil
        primaryInventoryOutcome = nil
        pendingChange = nil
        pendingReconciliationRetryChange = nil
    }
}
