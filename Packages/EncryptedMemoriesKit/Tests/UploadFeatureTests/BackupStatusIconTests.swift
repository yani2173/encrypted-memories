import DesignSystemCore
import SwiftUI
import Testing
import UploadCore

@testable import UploadFeature

@Suite struct BackupStatusIconTests {
    private let table: [(BackupStatusPresentation.Accessory, String, Color)] = [
        (.activity, "arrow.trianglehead.2.clockwise", ProtonColor.primary),
        (.attention, "exclamationmark.triangle.fill", .orange),
        (.paused, "pause.circle", ProtonColor.textWeak),
        (.waiting, "clock.arrow.circlepath", ProtonColor.textWeak),
        (.waitingForWiFi, BackupStatus.waitingForWiFiSymbolName, ProtonColor.textWeak),
        (.notice, "info.circle", ProtonColor.textWeak),
        (.success, "checkmark.shield.fill", ProtonColor.primary),
        (.idle, "checkmark.shield", ProtonColor.textWeak),
    ]

    @Test func everyAccessoryHasItsSymbolAndColorRole() {
        #expect(table.count == 8)
        for (accessory, symbol, color) in table {
            #expect(BackupStatusIcon.symbolName(for: accessory) == symbol, "\(accessory)")
            #expect(BackupStatusIcon.color(for: accessory) == color, "\(accessory)")
            #expect(BackupStatusIcon.spins(accessory) == (accessory == .activity), "only activity spins: \(accessory)")
        }
    }
}
