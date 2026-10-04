import CoreLocation
import DesignSystemCore
import MapUIKitAdapter
import MediaLocationCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit

/// Presents the shared map host over the library's GPS index. Empty states distinguish scanning, no places,
/// and scan failures. Pins open the viewer; clusters open `MobileMapClusterSeriesScreen`.
struct MobileMapScreen: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(MobileSceneContext.self) private var sceneContext
    @Environment(MobileLibraryModel.self) private var model
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var clusterPresentation: MobileMapClusterPresentation?
    /// Cached frosted-bar height. Reading the key window during `body` would trigger layout cycles.
    @State private var topFrostHeight: CGFloat = mobileTopBarFrostHeightDefault

    var body: some View {
        NavigationStack {
            // Reading `revision` registers this view with the @Observable index so it re-renders (and re-frames
            // the map) as the crawl adds coordinates.
            let revision = model.locationIndex.revision

            Group {
                if model.locationIndex.coordinates.isEmpty {
                    // Empty states distinguish scanning, no geotagged photos after completion, and probe
                    // failure. `.idle` keeps the generic message while the crawl has not started.
                    if !networkMonitor.isOnline {
                        OfflineContentUnavailableView()
                    } else {
                        switch model.locationIndex.scanProgress.phase {
                        case .scanning:
                            let progress = model.locationIndex.scanProgress
                            ContentUnavailableView {
                                Label(L10n.string("map.scanning_title"), systemImage: "location.magnifyingglass")
                            } description: {
                                Text(L10n.string("map.scanning_message \(progress.scanned) \(progress.total)"))
                            }
                        case .failed:
                            ContentUnavailableView {
                                Label(L10n.string("map.scan_failed_title"), systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(L10n.string("map.scan_failed_message"))
                            } actions: {
                                Button(L10n.string("action.retry")) {
                                    model.restartLocationCrawlIfNeeded()
                                }
                            }
                        case .completed:
                            ContentUnavailableView {
                                Label(L10n.string("map.empty_title"), systemImage: "mappin.slash")
                            } description: {
                                Text(L10n.string("map.no_places_found_message"))
                            }
                        case .idle:
                            ContentUnavailableView {
                                Label(L10n.string("map.empty_title"), systemImage: "mappin.slash")
                            } description: {
                                Text(L10n.string("map.empty_message"))
                            }
                        }
                    }
                } else {
                    MobileLibraryMap(
                        index: model.locationIndex,
                        revision: revision,
                        thumbnail: { model.thumbnailFeed?.memoryImage(for: $0) },
                        loadThumbnail: { await model.thumbnailFeed?.cachedImage(for: $0) },
                        onSelectPhoto: openPhoto,
                        onSelectCluster: { uids, coordinate in
                            let orderedUIDs = model.selectedUIDs(Set(uids))
                            let pager = PhotoLocationClusterPager(uids: Array(orderedUIDs.reversed()))
                            guard pager.totalCount > 0 else { return }
                            clusterPresentation = MobileMapClusterPresentation(pager: pager, coordinate: coordinate)
                        }
                    )
                    // Full-bleed under the navigation bar so the native iOS 26 Liquid Glass title floats over
                    // the map, mirroring the macOS map. The map pans freely underneath it.
                    .ignoresSafeArea()
                }
            }
            // Places appear while the scan runs; the banner says how much of the library is still left.
            .overlay(alignment: .bottom) {
                let progress = model.locationIndex.scanProgress
                if !model.locationIndex.coordinates.isEmpty, let fraction = progress.fractionScanned {
                    MobileMapScanBanner(progress: progress, fraction: fraction)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) { TopFrostBar(height: topFrostHeight) }
            .task(id: verticalSizeClass) {
                await Task.yield()
                topFrostHeight = mobileTopBarFrostHeight(in: sceneContext)
            }
            .mobileNavigationTitle(String(localized: "tab.map"))
            .navigationDestination(item: $clusterPresentation) { presentation in
                MobileMapClusterSeriesScreen(pager: presentation.pager, coordinate: presentation.coordinate)
            }
            // Re-runs when the library finishes loading, so opening Map before the timeline is ready still starts
            // the crawl once items exist (the start is idempotent).
            .task(id: model.items.isEmpty) { model.startLocationCrawlIfNeeded() }
            .onChange(of: networkMonitor.didRecentlyRestoreConnection) { _, restored in
                if restored {
                    model.restartLocationCrawlIfNeeded()
                }
            }
        }
    }

    private func openPhoto(_ uid: PhotoUID) {
        guard let index = model.index(of: uid) else { return }  // O(1) via the snapshot index
        viewerRouter.presentation = MobileViewerPresentation(
            index: index, items: model.items, context: ViewerCollectionContext(filter: .map)
        )
    }
}

/// Scan progress over a map that already shows places: how many photos are checked and how many remain.
private struct MobileMapScanBanner: View {
    let progress: PhotoLocationScanProgress
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("map.scanning_title"))
                .font(.footnote.weight(.semibold))
            Text(L10n.string("map.scanning_message \(progress.scanned) \(progress.total)"))
                .font(.caption)
                .foregroundStyle(ProtonColor.textWeak)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: fraction)
                .tint(ProtonColor.primary)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("map.scanProgress")
    }
}

/// Identifiable payload for pushing the cluster series screen: the member UIDs and the cluster's center
/// coordinate (used for reverse-geocoding the title).
private struct MobileMapClusterPresentation: Identifiable, Hashable {
    let id = UUID()
    let pager: PhotoLocationClusterPager
    let coordinate: CLLocationCoordinate2D

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MobileMapClusterPresentation, rhs: MobileMapClusterPresentation) -> Bool {
        lhs.id == rhs.id
    }
}

/// SwiftUI wrapper around the shared UIKit map host. `revision` causes `updateUIView` to refresh the host
/// when the crawl adds coordinates.
private struct MobileLibraryMap: UIViewRepresentable {
    let index: PhotoLocationIndex
    let revision: Int
    let thumbnail: (PhotoUID) -> UIImage?
    let loadThumbnail: (PhotoUID) async -> UIImage?
    let onSelectPhoto: (PhotoUID) -> Void
    let onSelectCluster: ([PhotoUID], CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> UIKitLibraryMapHostView {
        return UIKitLibraryMapHostView(
            index: index,
            visibleCoordinatePolicy: .standard,
            thumbnail: thumbnail,
            loadThumbnail: loadThumbnail,
            onSelectPhoto: onSelectPhoto,
            onSelectCluster: onSelectCluster
        )
    }

    func updateUIView(_ view: UIKitLibraryMapHostView, context: Context) {
        view.configure(
            thumbnail: thumbnail,
            loadThumbnail: loadThumbnail,
            onSelectPhoto: onSelectPhoto,
            onSelectCluster: onSelectCluster
        )
        view.refreshIfChanged()
    }
}
