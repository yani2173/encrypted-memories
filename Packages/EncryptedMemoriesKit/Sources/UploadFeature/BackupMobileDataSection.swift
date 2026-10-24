import PhotosCore
import SwiftUI

/// "Use Cellular Data" in the Backup settings of macOS, iOS and iPadOS. The value persists in the shared defaults
/// that every backup upload path reads; `onChange` lets the host resume a backup that waits for Wi-Fi.
public struct BackupMobileDataSection: View {
    @AppStorage(AppSettingsKey.backupUsesMobileData)
    private var usesMobileData = AppSettingsDefault.backupUsesMobileData
    private let onChange: @MainActor () -> Void

    public init(onChange: @escaping @MainActor () -> Void = {}) {
        self.onChange = onChange
    }

    public var body: some View {
        Section {
            Toggle(L10n.string("settings.backup_use_mobile_data"), isOn: $usesMobileData)
                .accessibilityIdentifier("backup.useMobileData")
                .onChange(of: usesMobileData) { _, _ in onChange() }
        } footer: {
            Text(L10n.string("settings.backup_use_mobile_data_footer"))
        }
    }
}
