import Foundation

public enum LibraryMemoryHeadroom: Int, Sendable, Comparable, Equatable {
    case unknown = 0
    case healthy = 1
    case constrained = 2
    case critical = 3

    public static func < (lhs: LibraryMemoryHeadroom, rhs: LibraryMemoryHeadroom) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LibraryNetworkState: Sendable, Equatable {
    public var isReachable: Bool
    public var isConstrained: Bool
    public var isExpensive: Bool
    /// False until the platform reported its first network path. The other values are then only defaults.
    public var isDetermined: Bool
    /// The interface types that the path uses and that are available to it. Types only, for support diagnostics.
    public var usedInterfaces: Set<LibraryNetworkInterfaceKind>
    public var availableInterfaces: Set<LibraryNetworkInterfaceKind>

    public init(
        isReachable: Bool = true, isConstrained: Bool = false, isExpensive: Bool = false, isDetermined: Bool = true,
        usedInterfaces: Set<LibraryNetworkInterfaceKind> = [],
        availableInterfaces: Set<LibraryNetworkInterfaceKind> = []
    ) {
        self.isReachable = isReachable
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
        self.isDetermined = isDetermined
        self.usedInterfaces = usedInterfaces
        self.availableInterfaces = availableInterfaces
    }

    /// The process state before the first network path arrives.
    public static let undetermined = LibraryNetworkState(isDetermined: false)

    public init(path: LibraryNetworkPath) {
        self.init(
            isReachable: path.isSatisfied,
            isConstrained: path.isConstrained,
            isExpensive: Self.isExpensive(path),
            usedInterfaces: path.usedInterfaces,
            availableInterfaces: path.availableInterfaces
        )
    }

    /// The interface types as sorted names, for example "cellular,other". Empty when none is known.
    public static func diagnosticList(_ interfaces: Set<LibraryNetworkInterfaceKind>) -> String {
        interfaces.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Cellular data and Personal Hotspot are expensive. A VPN runs over a tunnel interface (`.other`) that can hide
    /// the expensive cellular link below it, so a tunnel counts as expensive when cellular is its only physical
    /// interface: no Wi-Fi and no wired Ethernet.
    public static func isExpensive(_ path: LibraryNetworkPath) -> Bool {
        if path.isExpensive { return true }
        let interfaces = path.availableInterfaces
        return path.usedInterfaces.contains(.other) && interfaces.contains(.cellular)
            && !interfaces.contains(.wifi) && !interfaces.contains(.wiredEthernet)
    }
}

/// Platform-neutral kind of a network interface, mapped from `NWInterface.InterfaceType`.
public enum LibraryNetworkInterfaceKind: String, Sendable, Hashable, CaseIterable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
}

/// The facts of one network path that the network decision needs. The Apple adapter fills it from `NWPath`.
public struct LibraryNetworkPath: Sendable, Equatable {
    public var isSatisfied: Bool
    public var isConstrained: Bool
    /// The system's own expensive flag of the path.
    public var isExpensive: Bool
    /// The interface types that the path uses. `.other` is, for example, the tunnel of a VPN.
    public var usedInterfaces: Set<LibraryNetworkInterfaceKind>
    public var availableInterfaces: Set<LibraryNetworkInterfaceKind>

    public init(
        isSatisfied: Bool,
        isConstrained: Bool = false,
        isExpensive: Bool = false,
        usedInterfaces: Set<LibraryNetworkInterfaceKind> = [],
        availableInterfaces: Set<LibraryNetworkInterfaceKind> = []
    ) {
        self.isSatisfied = isSatisfied
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
        self.usedInterfaces = usedInterfaces
        self.availableInterfaces = availableInterfaces
    }
}

public enum LibraryExecutionOpportunity: Int, Sendable, Comparable, Equatable {
    case foregroundActive = 0
    case foregroundInactive = 1
    case backgroundPermitted = 2
    case suspended = 3

    public static func < (lhs: LibraryExecutionOpportunity, rhs: LibraryExecutionOpportunity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Privacy-safe process state shared by backup, indexing, cache and prefetch policy. It deliberately
/// cannot carry asset identifiers, filenames, hashes, queries or user content.
public struct LibraryRuntimeSnapshot: Sendable, Equatable {
    public var thermalLevel: LibraryThermalLevel
    public var memoryPressure: MemoryConditions.Pressure
    /// Cache footprint, including proactive background reduction. This is not a pressure signal.
    public var memoryBudgetTier: MemoryBudgetTier
    public var memoryHeadroom: LibraryMemoryHeadroom
    public var storagePressure: LibraryStoragePressure
    public var isLowPowerMode: Bool
    public var network: LibraryNetworkState
    public var executionOpportunity: LibraryExecutionOpportunity
    public var hasVisibleMediaDemand: Bool
    public var hasActiveUserInteraction: Bool
    public var activeUserTransferCount: Int
    public var activeVideoPlaybackCount: Int
    public var activeSearchCount: Int
    public var generation: UInt64
    public var monotonicUptimeNanoseconds: UInt64

    public init(
        thermalLevel: LibraryThermalLevel = .nominal,
        memoryPressure: MemoryConditions.Pressure = .normal,
        memoryBudgetTier: MemoryBudgetTier = .normal,
        memoryHeadroom: LibraryMemoryHeadroom = .unknown,
        storagePressure: LibraryStoragePressure = .normal,
        isLowPowerMode: Bool = false,
        network: LibraryNetworkState = LibraryNetworkState(),
        executionOpportunity: LibraryExecutionOpportunity = .foregroundActive,
        hasVisibleMediaDemand: Bool = false,
        hasActiveUserInteraction: Bool = false,
        activeUserTransferCount: Int = 0,
        activeVideoPlaybackCount: Int = 0,
        activeSearchCount: Int = 0,
        generation: UInt64 = 0,
        monotonicUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.thermalLevel = thermalLevel
        self.memoryPressure = memoryPressure
        self.memoryBudgetTier = memoryBudgetTier
        self.memoryHeadroom = memoryHeadroom
        self.storagePressure = storagePressure
        self.isLowPowerMode = isLowPowerMode
        self.network = network
        self.executionOpportunity = executionOpportunity
        self.hasVisibleMediaDemand = hasVisibleMediaDemand
        self.hasActiveUserInteraction = hasActiveUserInteraction
        self.activeUserTransferCount = max(0, activeUserTransferCount)
        self.activeVideoPlaybackCount = max(0, activeVideoPlaybackCount)
        self.activeSearchCount = max(0, activeSearchCount)
        self.generation = generation
        self.monotonicUptimeNanoseconds = monotonicUptimeNanoseconds
    }

    public static let initial = LibraryRuntimeSnapshot()
}

/// One process-wide state source. Synchronous feature gates read `snapshot()` without an actor hop;
/// actor clients consume a newest-only stream. Session invalidation is atomic with the state reset.
public final class LibraryRuntimeState: @unchecked Sendable {
    public static let shared = makeProcessState()

    /// The process state starts without a network path: a backup that must not use mobile data waits until the
    /// first path arrives.
    public static func makeProcessState() -> LibraryRuntimeState {
        LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: .undetermined))
    }

    private let lock = NSLock()
    private var current: LibraryRuntimeSnapshot
    private var activities: [UUID: LibraryRuntimeActivity] = [:]
    private var continuations: [UUID: AsyncStream<LibraryRuntimeSnapshot>.Continuation] = [:]

    public init(initial: LibraryRuntimeSnapshot = .initial) {
        current = initial
    }

    public func snapshot() -> LibraryRuntimeSnapshot {
        lock.withLock { current }
    }

    @discardableResult
    public func update(
        _ transform: (inout LibraryRuntimeSnapshot) -> Void
    ) -> LibraryRuntimeSnapshot {
        // Writers run on several threads (the network queue and the main actor). Yielding inside the lock keeps the
        // subscribers in write order, so none ends on an older snapshot. A newest-only buffer never blocks a yield.
        lock.withLock {
            var next = current
            transform(&next)
            next.activeUserTransferCount = max(0, next.activeUserTransferCount)
            next.generation = current.generation
            // The timestamp describes an accepted semantic transition; it must not itself make a
            // no-op update look different and flood newest-only subscribers.
            next.monotonicUptimeNanoseconds = current.monotonicUptimeNanoseconds
            guard next != current else { return current }
            next.monotonicUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            current = next
            for continuation in continuations.values { continuation.yield(next) }
            return next
        }
    }

    /// Invalidates callbacks from the previous account/run and resets content-independent demand.
    @discardableResult
    public func beginNewGeneration(
        preservingSystemSignals: Bool = true
    ) -> LibraryRuntimeSnapshot {
        lock.withLock {
            let old = current
            activities.removeAll()
            let generation = old.generation &+ 1
            current =
                preservingSystemSignals
                ? LibraryRuntimeSnapshot(
                    thermalLevel: old.thermalLevel,
                    memoryPressure: old.memoryPressure,
                    memoryBudgetTier: old.memoryBudgetTier,
                    memoryHeadroom: old.memoryHeadroom,
                    storagePressure: old.storagePressure,
                    isLowPowerMode: old.isLowPowerMode,
                    network: old.network,
                    executionOpportunity: old.executionOpportunity,
                    generation: generation
                )
                : LibraryRuntimeSnapshot(generation: generation)
            for continuation in continuations.values { continuation.yield(current) }
            return current
        }
    }

    /// An owner holds this registration only while it actively needs foreground resources.
    /// Independent windows and jobs cannot clear each other's demand. A generation reset retires all owners.
    public func beginActivity(_ activity: LibraryRuntimeActivity) -> LibraryRuntimeActivityRegistration {
        let id = UUID()
        update { snapshot in
            activities[id] = activity
            Self.adjust(activity, in: &snapshot, by: 1)
        }
        return LibraryRuntimeActivityRegistration(
            isActive: { [weak self] in
                guard let self else { return false }
                return self.lock.withLock { self.activities[id] != nil }
            },
            finish: { [weak self] in
                guard let self else { return }
                self.update { snapshot in
                    guard let activity = self.activities.removeValue(forKey: id) else { return }
                    Self.adjust(activity, in: &snapshot, by: -1)
                }
            })
    }

    private static func adjust(
        _ activity: LibraryRuntimeActivity, in snapshot: inout LibraryRuntimeSnapshot, by delta: Int
    ) {
        switch activity {
        case .videoPlayback: snapshot.activeVideoPlaybackCount = max(0, snapshot.activeVideoPlaybackCount + delta)
        case .userTransfer: snapshot.activeUserTransferCount = max(0, snapshot.activeUserTransferCount + delta)
        case .search: snapshot.activeSearchCount = max(0, snapshot.activeSearchCount + delta)
        }
    }

    public func updates() -> AsyncStream<LibraryRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Same lock as the writers: a newer snapshot can never be overtaken by this first one.
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(current)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
        }
    }
}

public enum LibraryRuntimeActivity: Sendable {
    case videoPlayback
    case userTransfer
    case search
}

public final class LibraryRuntimeActivityRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable () -> Void)?
    private let checkActive: @Sendable () -> Bool

    fileprivate init(isActive: @escaping @Sendable () -> Bool, finish: @escaping @Sendable () -> Void) {
        checkActive = isActive
        self.finish = finish
    }

    /// A persistent view can renew its demand after an account generation resets the process state.
    public var isActive: Bool { checkActive() }

    public func end() {
        let action = lock.withLock {
            let action = finish
            finish = nil
            return action
        }
        action?()
    }

    deinit { end() }
}
