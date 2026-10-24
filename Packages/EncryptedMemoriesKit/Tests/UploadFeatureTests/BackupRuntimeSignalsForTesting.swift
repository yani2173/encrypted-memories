import Foundation
import PhotosCore
import UploadCore

@testable import PhotoLibraryBackupAdapter

/// No path monitor runs in the test process, so the shared runtime state never leaves "undetermined". With mobile data
/// off, a backup that reads `.apple` then waits for Wi-Fi. Tests that need a pass inject an explicit network instead.
extension BackupRuntimeSignalSource {
    /// A satisfied, determined Wi-Fi path with mobile data off, mapped like the shared runtime state.
    static var wiFiWithMobileDataOff: BackupRuntimeSignalSource {
        mobileDataOff(LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: LibraryNetworkState())))
    }

    /// The network of `runtime` with mobile data off. Updates of `runtime` reach the backup as network changes.
    static func mobileDataOff(_ runtime: LibraryRuntimeState) -> BackupRuntimeSignalSource {
        BackupRuntimeSignalSource(
            current: { BackupThrottleInputs(runtime: runtime.snapshot(), usesMobileData: false) },
            updates: { runtime.updates() })
    }
}
