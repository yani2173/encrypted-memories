import Foundation
import MLSearchCore
import MediaFeedCore
import PhotosCore

/// Synchronous indexing gate over the shared workload governor.
///
/// Combines current system pressure with active and recent viewport demand. The grace period keeps indexing
/// suspended until newly visible thumbnails have had time to arrive.
public final class AppleSmartSearchWorkGate: @unchecked Sendable {
    typealias DemandRefreshScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void

    private static let demandRefreshDelay: Duration = .seconds(2)

    private let visibleMediaDemandActive: @Sendable () -> Bool
    private let hostPermitsIndexing: @Sendable () -> Bool
    private let runtimeState: LibraryRuntimeState
    private let scheduleDemandRefresh: DemandRefreshScheduler
    private let governor = LibraryWorkloadGovernorPolicy()
    private let refreshLock = NSLock()
    private var demandRefreshScheduled = false
    private let indexingWakeLock = NSLock()
    private var indexingWake: (@Sendable () -> Void)?
    private var wakePolicy: SmartSearchGateWakePolicy?
    private var runtimeObservation: Task<Void, Never>?
    private var cacheArrivalWakeRegistration: ThumbnailFeedWakeRegistration?

    public init(
        feed: ThumbnailFeedCore,
        runtimeState: LibraryRuntimeState = .shared,
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true }
    ) {
        self.visibleMediaDemandActive = {
            feed.hasActiveUserInteraction() || feed.hasRecentVisibleDemand()
        }
        self.runtimeState = runtimeState
        self.hostPermitsIndexing = hostPermitsIndexing
        self.scheduleDemandRefresh = Self.defaultDemandRefreshScheduler
        self.cacheArrivalWakeRegistration = feed.setOnCacheArrivalWake { [weak self] in
            guard let self else { return }
            let wake = self.indexingWakeLock.withLock { self.indexingWake }
            wake?()
        }
    }

    init(
        visibleMediaDemandActive: @escaping @Sendable () -> Bool,
        runtimeState: LibraryRuntimeState = .shared,
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true },
        scheduleDemandRefresh: @escaping DemandRefreshScheduler = AppleSmartSearchWorkGate.defaultDemandRefreshScheduler
    ) {
        self.visibleMediaDemandActive = visibleMediaDemandActive
        self.runtimeState = runtimeState
        self.hostPermitsIndexing = hostPermitsIndexing
        self.scheduleDemandRefresh = scheduleDemandRefresh
    }

    /// The callback runs when a change of a runtime input (thermal state, Low Power Mode, visible demand, playback,
    /// search, user transfers) can open a gate that was closed, so a closed gate opens again without a polling loop.
    /// A change that closes the gate or leaves it as it was wakes nothing.
    public func setIndexingWake(_ callback: @escaping @Sendable () -> Void) {
        indexingWakeLock.withLock {
            indexingWake = callback
            guard runtimeObservation == nil else { return }
            // The baseline is the state at registration, so a change before the task runs still wakes.
            wakePolicy = SmartSearchGateWakePolicy(permits: permits(GateInputs(runtimeState.snapshot())))
            let updates = runtimeState.updates()
            runtimeObservation = Task { [weak self] in
                for await snapshot in updates {
                    guard let self else { return }
                    if let wake = self.wakeForRuntimeChange(snapshot) { wake() }
                }
            }
        }
    }

    #if DEBUG
        var wakePolicyForTesting: SmartSearchGateWakePolicy? { indexingWakeLock.withLock { wakePolicy } }
    #endif

    private func wakeForRuntimeChange(_ snapshot: LibraryRuntimeSnapshot) -> (@Sendable () -> Void)? {
        let permitted = permits(GateInputs(snapshot))
        return indexingWakeLock.withLock {
            // The gate can have closed again since this update; a wake against a closed gate finds nothing to do.
            let openNow = permits(GateInputs(runtimeState.snapshot()))
            guard wakePolicy?.runtimeChanged(permits: permitted, gateIsOpenNow: openNow) == true else { return nil }
            return indexingWake
        }
    }

    /// The indexing loop found the gate closed. The loop may have seen a close that the newest-only update stream
    /// merged with the reopen that followed, so the reopen alone would look like no change.
    private func noteClosedGate() -> (@Sendable () -> Void)? {
        indexingWakeLock.withLock {
            // The gate may have reopened after the loop read its inputs; the observer would not wake for that.
            let reopened = permits(GateInputs(runtimeState.snapshot()))
            guard wakePolicy?.loopFoundGateClosed(currentPermits: reopened) == true else { return nil }
            return indexingWake
        }
    }

    deinit {
        runtimeObservation?.cancel()
    }

    public func permitsIndexing() -> Bool {
        guard hostPermitsIndexing() else { return false }

        let visibleDemand = publishCurrentVisibleDemand()
        guard permits(GateInputs(runtimeState.snapshot(), visibleDemand: visibleDemand)) else {
            noteClosedGate()?()
            return false
        }
        return true
    }

    private func permits(_ inputs: GateInputs) -> Bool {
        let signals = LibraryWorkloadSignals(
            thermalLevel: inputs.thermalLevel,
            isLowPowerMode: inputs.isLowPowerMode,
            hasVisibleMediaDemand: inputs.hasVisibleMediaDemand || inputs.isPlayingVideo || inputs.isSearching,
            hasActiveUserInitiatedTransfer: inputs.hasUserTransfer
        )
        return !governor.budget(for: .backgroundSemanticIndexing, signals: signals).shouldYield
    }

    private func publishCurrentVisibleDemand() -> Bool {
        let visibleDemand = visibleMediaDemandActive()
        runtimeState.update { $0.hasVisibleMediaDemand = visibleDemand }
        if visibleDemand { scheduleRefreshIfNeeded() }
        return visibleDemand
    }

    private func scheduleRefreshIfNeeded() {
        let shouldSchedule = refreshLock.withLock {
            guard !demandRefreshScheduled else { return false }
            demandRefreshScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        scheduleDemandRefresh { [weak self] in
            guard let self else { return }
            self.refreshLock.withLock { self.demandRefreshScheduled = false }
            _ = self.publishCurrentVisibleDemand()
        }
    }

    /// The runtime values that `permitsIndexing` reads. Other runtime changes, such as the network path, never wake the
    /// indexing loop.
    private struct GateInputs {
        let thermalLevel: LibraryThermalLevel
        let isLowPowerMode: Bool
        let hasVisibleMediaDemand: Bool
        let isPlayingVideo: Bool
        let isSearching: Bool
        let hasUserTransfer: Bool

        init(_ snapshot: LibraryRuntimeSnapshot, visibleDemand: Bool? = nil) {
            thermalLevel = snapshot.thermalLevel
            isLowPowerMode = snapshot.isLowPowerMode
            hasVisibleMediaDemand = visibleDemand ?? snapshot.hasVisibleMediaDemand
            isPlayingVideo = snapshot.activeVideoPlaybackCount > 0
            isSearching = snapshot.activeSearchCount > 0
            hasUserTransfer = snapshot.activeUserTransferCount > 0
        }
    }

    private static let defaultDemandRefreshScheduler: DemandRefreshScheduler = { refresh in
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: demandRefreshDelay)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }
}

/// Decides when a runtime change can open an indexing gate that is closed. A change that closes the gate or leaves it
/// as it was cannot start indexing, so it wakes nothing.
struct SmartSearchGateWakePolicy {
    private var observedPermits: Bool
    private(set) var loopSawClosedGate = false

    init(permits: Bool) {
        observedPermits = permits
    }

    /// A runtime update arrived. Returns whether it can open a closed gate. The gate counts as closed when the last
    /// update closed it or when the loop found it closed since the last wake. `gateIsOpenNow` is the gate state at
    /// this moment: an update that opened the gate wakes nothing when the gate has closed again. The next opening
    /// wakes then, because the gate still counts as closed.
    mutating func runtimeChanged(permits: Bool, gateIsOpenNow: Bool) -> Bool {
        let wasClosed = !observedPermits || loopSawClosedGate
        observedPermits = permits
        guard wasClosed, permits, gateIsOpenNow else { return false }
        loopSawClosedGate = false
        return true
    }

    /// The loop found the gate closed. `currentPermits` is the gate state now: when it is open again, the update that
    /// reopened it can have been merged with an earlier update, and this call wakes in its place.
    mutating func loopFoundGateClosed(currentPermits: Bool) -> Bool {
        guard currentPermits else {
            loopSawClosedGate = true
            return false
        }
        loopSawClosedGate = false
        // This wake covers the reopen, so the update of that reopen must not wake a second time.
        observedPermits = true
        return true
    }
}
