import DesignSystemCore
import SwiftUI
import UploadCore

/// The one icon of the backup status row on macOS, iOS and iPadOS. Only `.activity` spins, so the row never shows a
/// second activity indicator.
public struct BackupStatusIcon: View {
    private let accessory: BackupStatusPresentation.Accessory

    public init(_ accessory: BackupStatusPresentation.Accessory) {
        self.accessory = accessory
    }

    public var body: some View {
        Image(systemName: Self.symbolName(for: accessory))
            .foregroundStyle(Self.color(for: accessory))
            .spinsWhileActive(Self.spins(accessory))
    }

    static func spins(_ accessory: BackupStatusPresentation.Accessory) -> Bool { accessory == .activity }

    static func symbolName(for accessory: BackupStatusPresentation.Accessory) -> String {
        switch accessory {
        case .activity: "arrow.trianglehead.2.clockwise"
        case .attention: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        case .waiting: "clock.arrow.circlepath"
        case .waitingForWiFi: BackupStatus.waitingForWiFiSymbolName
        case .notice: "info.circle"
        case .success: "checkmark.shield.fill"
        case .idle: "checkmark.shield"
        }
    }

    static func color(for accessory: BackupStatusPresentation.Accessory) -> Color {
        switch accessory {
        case .activity, .success: ProtonColor.primary
        case .attention: .orange
        case .paused, .waiting, .waitingForWiFi, .notice, .idle: ProtonColor.textWeak
        }
    }
}
