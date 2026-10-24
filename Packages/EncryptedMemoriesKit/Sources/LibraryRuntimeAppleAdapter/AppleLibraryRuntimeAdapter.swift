import Foundation
import Network
import PhotosCore

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

/// The process-wide Apple signal source for library resource policy.
///
/// Feature modules never create their own network, thermal, power or memory-pressure observers.
/// They consume `LibraryRuntimeState` or a feature-specific projection of it. UIKit/AppKit supply
/// lifecycle opportunity through `setExecutionOpportunity(_:)`.
@MainActor
public final class AppleLibraryRuntimeAdapter {
    public static let shared = AppleLibraryRuntimeAdapter()

    private static let memoryWarningLatchDuration: Duration = .seconds(20)
    private let runtimeState: LibraryRuntimeState
    private let memoryGovernor: MemoryPressureGovernor
    private let networkMonitor: NWPathMonitor
    private let networkQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.library-runtime-network", qos: .utility)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var notificationTokens: [NSObjectProtocol] = []
    private var warningDecayTask: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?
    private var installed = false
    private var dispatchPressure: MemoryConditions.Pressure = .normal
    private var memoryWarningLatched = false

    private init() {
        runtimeState = .shared
        memoryGovernor = .shared
        networkMonitor = NWPathMonitor()
    }

    /// Installs every dynamic Apple signal observer exactly once per process.
    public func install() {
        guard !installed else { return }
        installed = true

        #if canImport(UIKit) && !os(watchOS)
            let applicationState = UIApplication.shared.applicationState
            runtimeState.update {
                $0.executionOpportunity = applicationState == .background ? .backgroundPermitted : .foregroundInactive
                if applicationState == .active { $0.executionOpportunity = .foregroundActive }
            }
        #endif

        Task {
            await LibraryResourceCoordinator.shared.startObserving()
        }
        installNetworkMonitor()
        installMemoryPressureSource()
        installProcessNotifications()
        publishMemoryConditions()
        if runtimeState.snapshot().executionOpportunity == .foregroundActive {
            startStoragePolling()
        } else {
            storageTask = Task { await sampleStorageCapacity() }
        }
    }

    /// Platform lifecycle adapters provide opportunity; Core remains framework-free.
    public func setExecutionOpportunity(_ opportunity: LibraryExecutionOpportunity) {
        let previous = runtimeState.snapshot().executionOpportunity
        runtimeState.update { $0.executionOpportunity = opportunity }
        publishMemoryConditions()
        if opportunity == .foregroundActive, previous != .foregroundActive {
            startStoragePolling()
        } else if opportunity != .foregroundActive {
            storageTask?.cancel()
            storageTask = nil
        }
    }

    private func startStoragePolling() {
        storageTask?.cancel()
        storageTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleStorageCapacity()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func sampleStorageCapacity() async {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let available = await Task.detached(priority: .utility) {
            DeviceStorage.availableCapacity(at: home)
        }.value
        guard !Task.isCancelled else { return }
        runtimeState.update {
            $0.storagePressure = LibraryStoragePressure.next(
                after: $0.storagePressure, availableBytes: available)
        }
    }

    private func installNetworkMonitor() {
        // The state is lock-protected. Updating it here, in path order, keeps a busy main thread (for example while
        // the app returns to the foreground) from letting the backup read the previous network.
        let runtimeState = runtimeState
        networkMonitor.pathUpdateHandler = { path in
            let state = LibraryNetworkState(path: Self.networkPath(path))
            runtimeState.update { $0.network = state }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private nonisolated static func networkPath(_ path: NWPath) -> LibraryNetworkPath {
        LibraryNetworkPath(
            isSatisfied: path.status == .satisfied,
            isConstrained: path.isConstrained,
            isExpensive: path.isExpensive,
            usedInterfaces: Set(
                LibraryNetworkInterfaceKind.allCases.filter { path.usesInterfaceType(interfaceType(for: $0)) }),
            availableInterfaces: Set(path.availableInterfaces.map { interfaceKind(for: $0.type) })
        )
    }

    private nonisolated static func interfaceKind(for type: NWInterface.InterfaceType) -> LibraryNetworkInterfaceKind {
        switch type {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .wiredEthernet
        case .loopback: .loopback
        case .other: .other
        @unknown default: .other
        }
    }

    private nonisolated static func interfaceType(for kind: LibraryNetworkInterfaceKind) -> NWInterface.InterfaceType {
        switch kind {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .wiredEthernet
        case .loopback: .loopback
        case .other: .other
        }
    }

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let data = source.data
            MainActor.assumeIsolated {
                guard let self else { return }
                if data.contains(.critical) {
                    self.dispatchPressure = .critical
                } else if data.contains(.warning) {
                    self.dispatchPressure = .warning
                } else {
                    self.dispatchPressure = .normal
                    self.clearMemoryWarningLatch()
                }
                self.publishMemoryConditions()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func installProcessNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.publishMemoryConditions() }
            })
        notificationTokens.append(
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.publishMemoryConditions() }
            })

        #if canImport(UIKit) && !os(watchOS)
            notificationTokens.append(
                center.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.latchMemoryWarning() }
                })
        #endif
    }

    private func latchMemoryWarning() {
        memoryWarningLatched = true
        publishMemoryConditions()
        warningDecayTask?.cancel()
        warningDecayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.memoryWarningLatchDuration)
            guard !Task.isCancelled else { return }
            self?.memoryWarningLatched = false
            self?.publishMemoryConditions()
        }
    }

    private func clearMemoryWarningLatch() {
        warningDecayTask?.cancel()
        warningDecayTask = nil
        memoryWarningLatched = false
    }

    private func publishMemoryConditions() {
        let info = ProcessInfo.processInfo
        let opportunity = runtimeState.snapshot().executionOpportunity
        memoryGovernor.update(
            AppleRuntimeMemoryPolicy.conditions(
                dispatchPressure: dispatchPressure,
                memoryWarningLatched: memoryWarningLatched,
                executionOpportunity: opportunity,
                thermal: Self.thermal(info.thermalState),
                lowPowerMode: info.isLowPowerModeEnabled
            ))
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> MemoryConditions.Thermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}

/// Merges observed pressure independently from proactive background cache reduction.
/// A UIKit warning retains purge-now semantics in every execution opportunity.
public enum AppleRuntimeMemoryPolicy {
    /// Background activity affects cache budgets, not observed pressure.
    public static func pressure(
        dispatchPressure: MemoryConditions.Pressure,
        memoryWarningLatched: Bool
    ) -> MemoryConditions.Pressure {
        memoryWarningLatched ? .critical : dispatchPressure
    }

    public static func conditions(
        dispatchPressure: MemoryConditions.Pressure,
        memoryWarningLatched: Bool,
        executionOpportunity: LibraryExecutionOpportunity,
        thermal: MemoryConditions.Thermal,
        lowPowerMode: Bool
    ) -> MemoryConditions {
        let isBackgrounded = executionOpportunity == .backgroundPermitted || executionOpportunity == .suspended
        return MemoryConditions(
            pressure: pressure(
                dispatchPressure: dispatchPressure,
                memoryWarningLatched: memoryWarningLatched
            ),
            thermal: thermal,
            lowPowerMode: lowPowerMode,
            isBackgrounded: isBackgrounded
        )
    }
}
