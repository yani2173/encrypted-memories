import AlbumCore
import AlbumsFeature
import CoreLocation
import DesignSystemCore
import GridCore
import MapUIKitAdapter
import MediaLocationCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import TimelineCore
import TimelineUIKitFeature

/// Lists a tapped cluster's member photos in the shared UIKit grid. It reuses the Photos selection and viewer
/// routes, and reverse-geocodes the cluster center for the navigation title.
struct MobileMapClusterSeriesScreen: View {
    let coordinate: CLLocationCoordinate2D
    private let pager: PhotoLocationClusterPager

    @Environment(MobileLibraryModel.self) private var model
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var selection = MobileGridSelectionController()
    @State private var pageIndex = 0
    @State private var clusterItems: [PhotoItem] = []
    @State private var placeName: String?
    @State private var contextMenu = MobileGridContextMenuController()
    @State private var showAlbumPicker = false

    private var selectionBusy: Bool { selection.isBusy }
    private var currentPage: PhotoLocationClusterPage? { pager.page(at: pageIndex) }
    private var placeTitle: String { PlaceNameText.displayable(placeName) ?? L10n.string("map.cluster_title") }

    init(pager: PhotoLocationClusterPager, coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        self.pager = pager
    }

    var body: some View {
        content
            .mobileGridContextMenu(contextMenu, model: model)
            .mobileNavigationTitle(selection.barTitle(default: placeTitle))
            .toolbar { toolbarContent }
            .mobileSelectionBars(isSelecting: selection.isSelecting)
            .task { await resolvePlaceName() }
            .task(id: "\(model.timelineRevision)-\(pageIndex)") {
                guard let currentPage else { return }
                clusterItems = Array(model.selectedItems(Set(currentPage.uids)).reversed())
            }
            .mobileSharePresentation(selection: selection)
            .mobileSelectionAlerts(selection: selection) { performTrash() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        MobileMapClusterPageToolbarItems(
            pageIndex: pageIndex, pageCount: pager.pageCount, currentPage: currentPage, isBusy: selectionBusy,
            previous: {
                selection.finish()
                pageIndex -= 1
            },
            next: {
                selection.finish()
                pageIndex += 1
            }
        )
        if !clusterItems.isEmpty {
            ProminentToolbarItem(placement: .topBarTrailing, isProminent: selection.isSelecting) {
                Button {
                    selection.toggleMode()
                } label: {
                    MobileSelectionModeLabel(isSelecting: selection.isSelecting)
                }
            }
            .mobileVisibilityPriority(.high)
        }
        MobileSelectionToolbarItems(
            selection: selection,
            canAddToAlbum: model.albumActions?.canAddPhotos == true,
            showAlbumPicker: $showAlbumPicker,
            onShare: startShare,
            onTrash: { selection.showTrashConfirm = true },
            albumPicker: { regularPresentation in
                if let coordinator = model.albumActions {
                    AlbumDestinationPicker(
                        coordinator: coordinator,
                        photoUIDs: model.selectedUIDs(selection.selected),
                        regularPresentation: regularPresentation,
                        onAlbumsChanged: { model.noteAlbumsChanged() },
                        onCompleted: { _ in
                            showAlbumPicker = false
                            selection.finish()
                        }
                    )
                }
            }
        )
    }

    @ViewBuilder private var content: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if let feed = model.thumbnailFeed, !clusterItems.isEmpty {
                UIKitTimelineGrid(
                    items: clusterItems,
                    thumbnailFeed: feed,
                    fillOrder: .topLeading,
                    initialViewportPlacement: .oldest,
                    selectionMode: selection.isSelecting,
                    selectedUIDs: selection.selected,
                    isActive: true,
                    scrollToTopSignal: pageIndex,
                    onOpenPhoto: open,
                    onToggleSelection: selection.toggle,
                    onSelectionChanged: selection.replace(with:),
                    dragOutProvider: model.backend,
                    onDragOutFailed: { selection.actionError = MobileSelectionError(message: $0.localizedMessage) },
                    contextMenuActions: { contextMenu.actions(for: $0, model: model) },
                    onContextMenuAction: { action, items in
                        contextMenu.perform(action, items: items, model: model, router: viewerRouter)
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label(L10n.string("map.empty_title"), systemImage: "photo.on.rectangle")
                } description: {
                    Text(L10n.string("map.no_places_found_message"))
                }
            }
        }
    }

    private func open(_ item: PhotoItem) {
        let items = clusterItems
        guard let index = items.firstIndex(where: { $0.uid == item.uid }) else { return }
        viewerRouter.presentation = MobileViewerPresentation(
            index: index, items: items, context: ViewerCollectionContext(filter: .map)
        )
    }

    private func startShare() {
        guard let backend = model.backend else { return }
        selection.startShare(
            items: model.selectedItems(selection.selected), backend: backend
        )
    }

    private func performTrash() {
        selection.performTrash { try await model.trashItems($0) }
    }

    private func resolvePlaceName() async {
        let name = await NativePlaceNameResolver.shared.placeName(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        placeName = name
    }
}

/// The native cluster pager toolbar, independent of photo loading and reverse geocoding.
struct MobileMapClusterPageToolbarItems: ToolbarContent {
    @Environment(\.verticalBarEdge) private var edge
    let pageIndex: Int
    let pageCount: Int
    let currentPage: PhotoLocationClusterPage?
    let isBusy: Bool
    let previous: () -> Void
    let next: () -> Void

    var body: some ToolbarContent {
        if pageCount > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: previous) { pageLabel("map.previous_page", symbol: "chevron.left") }
                    .disabled(currentPage?.hasPrevious != true || isBusy)
            }
            .mobileVisibilityPriority(.high)
            ToolbarItem(placement: .principal) {
                Text("\(pageIndex + 1)/\(pageCount)")
                    .monospacedDigit()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: next) { pageLabel("map.next_page", symbol: "chevron.right") }
                    .disabled(currentPage?.hasNext != true || isBusy)
            }
            .mobileVisibilityPriority(.high)
        }
    }

    @ViewBuilder private func pageLabel(_ key: String.LocalizationValue, symbol: String) -> some View {
        if edge == nil {
            Image(systemName: symbol)
        } else {
            Label(L10n.string(key), systemImage: symbol)
        }
    }
}
