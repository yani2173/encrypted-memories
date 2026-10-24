import Foundation
import Observation
import PhotosCore

/// Shared Apple network-path monitor for the app chrome.
///
/// This reports whether the device has a usable network path. It intentionally does not infer Proton server
/// outages from request failures, because those can be auth, quota, server, or transport problems.
@MainActor
@Observable
public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    /// True when a usable network path exists. Starts optimistic so first paint is not a false offline flash.
    public private(set) var isOnline = true
    /// True briefly after the path recovers from offline to online. The shared grid banner uses this for a
    /// subtle "connection restored" pulse without each platform view owning its own timer.
    public private(set) var didRecentlyRestoreConnection = false

    private var restoredPulseTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    private init() {
        apply(online: Self.isOnline(LibraryRuntimeState.shared.snapshot().network))
        let updates = LibraryRuntimeState.shared.updates()
        observationTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.apply(online: Self.isOnline(snapshot.network))
            }
        }
    }

    /// Online means a usable path. Cellular data and Personal Hotspot are online, even while the backup waits for
    /// Wi-Fi because mobile data is off for backups.
    public nonisolated static func isOnline(_ network: LibraryNetworkState) -> Bool {
        network.isReachable
    }

    private func apply(online: Bool) {
        let wasOnline = isOnline
        isOnline = online

        guard online else {
            restoredPulseTask?.cancel()
            didRecentlyRestoreConnection = false
            return
        }

        if !wasOnline {
            restoredPulseTask?.cancel()
            didRecentlyRestoreConnection = true
            restoredPulseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                didRecentlyRestoreConnection = false
            }
        }
    }
}
