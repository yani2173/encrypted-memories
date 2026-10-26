import PhotosCore
import SwiftUI

/// The native unavailable view of an empty Map, shared by macOS and iOS: the shared offline view, a scan in
/// progress, a failed scan with the shared prominent Try again button, a finished scan without places, and the idle
/// state. Each platform places it itself and supplies what Try again does.
public struct MapEmptyStateView: View {
    private let state: MapEmptyState
    private let retry: () -> Void

    public init(_ state: MapEmptyState, retry: @escaping () -> Void) {
        self.state = state
        self.retry = retry
    }

    @ViewBuilder public var body: some View {
        if let copy = Self.copy(for: state) {
            if state.offersRetry {
                ContentUnavailableView {
                    Label(copy.title, systemImage: copy.systemImage)
                } description: {
                    Text(copy.message)
                } actions: {
                    RetryButton(.prominent, action: retry)
                }
            } else {
                ContentUnavailableView {
                    Label(copy.title, systemImage: copy.systemImage)
                } description: {
                    Text(copy.message)
                }
            }
        } else {
            OfflineContentUnavailableView()
        }
    }

    struct Copy: Equatable {
        let title: String
        let message: String
        let systemImage: String
    }

    /// The copy of a state; the offline state has none, because the shared offline view owns its own.
    nonisolated static func copy(for state: MapEmptyState) -> Copy? {
        switch state {
        case .offline:
            nil
        case .scanning(let scanned, let total):
            Copy(
                title: L10n.string("map.scanning_title"),
                message: L10n.string("map.scanning_message \(scanned) \(total)"),
                systemImage: "location.magnifyingglass")
        case .failed:
            Copy(
                title: L10n.string("map.scan_failed_title"), message: L10n.string("map.scan_failed_message"),
                systemImage: "exclamationmark.triangle")
        case .completed:
            Copy(
                title: L10n.string("map.empty_title"), message: L10n.string("map.no_places_found_message"),
                systemImage: "mappin.slash")
        case .idle:
            Copy(
                title: L10n.string("map.empty_title"), message: L10n.string("map.empty_message"),
                systemImage: "mappin.slash")
        }
    }
}
