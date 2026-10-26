import PhotosCore
import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct MapEmptyStateViewTests {
    private static let contentStates: [MapEmptyState] = [
        .scanning(scanned: 12, total: 480), .failed, .completed, .idle,
    ]

    @Test func everyStateUsesItsOwnCopyAndSymbol() throws {
        let scanning = try #require(MapEmptyStateView.copy(for: .scanning(scanned: 12, total: 480)))
        #expect(scanning.title == L10n.string("map.scanning_title"))
        #expect(scanning.message == L10n.string("map.scanning_message \(12) \(480)"))
        #expect(scanning.systemImage == "location.magnifyingglass")

        let failed = try #require(MapEmptyStateView.copy(for: .failed))
        #expect(failed.title == L10n.string("map.scan_failed_title"))
        #expect(failed.message == L10n.string("map.scan_failed_message"))
        #expect(failed.systemImage == "exclamationmark.triangle")

        let completed = try #require(MapEmptyStateView.copy(for: .completed))
        #expect(completed.title == L10n.string("map.empty_title"))
        #expect(completed.message == L10n.string("map.no_places_found_message"))
        #expect(completed.systemImage == "mappin.slash")

        let idle = try #require(MapEmptyStateView.copy(for: .idle))
        #expect(idle.title == L10n.string("map.empty_title"))
        #expect(idle.message == L10n.string("map.empty_message"))
        #expect(idle.systemImage == "mappin.slash")

        // The offline state is the shared offline view and has no copy of its own.
        #expect(MapEmptyStateView.copy(for: .offline) == nil)
    }

    @Test func theCountsShowInTheScanningMessage() throws {
        let first = try #require(MapEmptyStateView.copy(for: .scanning(scanned: 1, total: 20)))
        let second = try #require(MapEmptyStateView.copy(for: .scanning(scanned: 15, total: 20)))
        #expect(first.message != second.message)
    }

    @Test func noCopyIsTheRawKey() throws {
        for state in Self.contentStates {
            let copy = try #require(MapEmptyStateView.copy(for: state))
            for text in [copy.title, copy.message] {
                #expect(!text.hasPrefix("map."))
            }
        }
    }

    @MainActor @Test func everyContentStateDrawsItsMessageBeyondTheTitle() throws {
        for state in Self.contentStates {
            let copy = try #require(MapEmptyStateView.copy(for: state))
            let titleOnly = try RenderedInk.pixels(
                ContentUnavailableView { Label(copy.title, systemImage: copy.systemImage) })
            let full = try RenderedInk.pixels(MapEmptyStateView(state, retry: {}))
            #expect(full - titleOnly > 100, "\(state)")
        }
    }

    @MainActor @Test func theOfflineStateDrawsTheSharedOfflineView() throws {
        let offline = try RenderedInk.pixels(MapEmptyStateView(.offline, retry: {}))
        let shared = try RenderedInk.pixels(OfflineContentUnavailableView())
        #expect(offline == shared)
        #expect(offline > 100)
    }
}
