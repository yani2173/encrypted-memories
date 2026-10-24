import Foundation
import PhotosCore

/// Short value for the Backup entry in a settings list. The entry opens the full backup screen, so
/// the value names only the state.
public enum BackupSettingsSummary: Sendable, Equatable {
    case unavailable
    case off
    case on
    case backingUp
    case paused
    case waiting
    case waitingForWiFi
    case incomplete

    public init(isAvailable: Bool, isEnabled: Bool, isUserPaused: Bool, display: BackupStatusPresentation) {
        guard isAvailable else {
            self = .unavailable
            return
        }
        guard isEnabled else {
            self = .off
            return
        }
        guard !isUserPaused else {
            self = .paused
            return
        }
        switch display.accessory {
        case .activity: self = .backingUp
        case .paused: self = .paused
        case .waiting: self = .waiting
        case .waitingForWiFi: self = .waitingForWiFi
        case .attention: self = .incomplete
        case .idle, .success, .notice: self = .on
        }
    }

    /// The backup screen explains every state; only this one asks the person to look.
    public var needsAttention: Bool { self == .incomplete }

    public var localizedValue: String {
        switch self {
        case .unavailable: L10n.string("settings.summary_unavailable")
        case .off: L10n.string("settings.summary_off")
        case .on: L10n.string("settings.summary_on")
        case .backingUp: L10n.string("backup.summary_backing_up")
        case .paused: L10n.string("backup.summary_paused")
        case .waiting: L10n.string("backup.summary_waiting")
        case .waitingForWiFi: L10n.string("backup.phase_waiting_wifi")
        case .incomplete: L10n.string("backup.summary_incomplete")
        }
    }
}
