import AlbumCore
import AlbumsFeature
import DesignSystemCore
import GridCore
import MediaCacheUIKitAdapter
import PhotoViewerCore
import PhotosCore
import SwiftUI
import TimelineCore
import TimelineUIKitFeature
import UIKit

/// Hosts smart filters, albums, and Trash through the shared `PhotoFilter` routes. Each route opens the
/// shared timeline grid; a new smart filter adds a row instead of another screen.
///
/// Album actions route through the shared AlbumCore facade; this screen owns only native navigation and chrome.
struct MobileCollectionsScreen: View {
    /// `@Environment` over the `@Observable` model: Collections reads only `backend`/`thumbnailFeed`, so a
    /// timeline snapshot change no longer re-renders this list.
    @Environment(MobileLibraryModel.self) private var model
    @State private var showCreateAlbum = false
    @State private var pendingSharedAlbumLeave: SharedAlbumSummary?

    private struct AlbumsReloadKey: Equatable {
        var backendReady: Bool
        var revision: Int
    }

    /// Server-backed smart filters in the same set and order as the Mac sidebar. Titles and icons come from the
    /// localized `PhotoTag` values.
    static let smartCategories: [PhotoTag] = PhotoTag.allCases
    private var smartCategories: [PhotoTag] { Self.smartCategories }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "collections.section_library")) {
                    ForEach(smartCategories, id: \.rawValue) { tag in
                        NavigationLink {
                            MobileFilterGridScreen(title: tag.title, filter: .tag(tag))
                        } label: {
                            MobileCollectionRow(systemImage: tag.systemImage, title: tag.title)
                        }
                    }
                    NavigationLink {
                        MobileFilterGridScreen(title: String(localized: "collections.trash"), filter: .trash)
                    } label: {
                        MobileCollectionRow(systemImage: "trash", title: String(localized: "collections.trash"))
                    }
                }

                if let duplicates = model.duplicates {
                    Section(String(localized: "collections.section_utilities")) {
                        NavigationLink {
                            MobileDuplicatesScreen(model: duplicates)
                        } label: {
                            MobileCollectionRow(systemImage: "square.on.square", title: L10n.string("duplicates.title"))
                        }
                        .badge(duplicates.knownDuplicateCount ?? 0)
                        .accessibilityIdentifier("duplicates.entry")
                        .task { await duplicates.loadCountIfNeeded() }
                    }
                }

                Section(String(localized: "collections.section_albums")) {
                    albumsSection
                }
                if model.albumActions?.canListSharedWithMe == true {
                    Section(L10n.string("collections.section_shared_with_me")) {
                        sharedAlbumsSection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .mobileNavigationTitle(String(localized: "tab.collections"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showCreateAlbum = true
                        } label: {
                            Label(L10n.string("albums.create_title"), systemImage: "rectangle.stack.badge.plus")
                        }
                        .disabled(model.albumActions?.canCreate != true)
                    } label: {
                        Label(L10n.string("albums.create_title"), systemImage: "plus")
                    }
                    .accessibilityLabel(L10n.string("albums.create_title"))
                }
                .mobileVisibilityPriority(.high)
            }
            .task(id: AlbumsReloadKey(backendReady: model.backend != nil, revision: model.albumCatalogRevision)) {
                await loadAlbums()
            }
            .refreshable { await loadAlbums() }
            .confirmationDialog(
                L10n.string("albums.leave_shared_title"),
                isPresented: Binding(
                    get: { pendingSharedAlbumLeave != nil },
                    set: { if !$0 { pendingSharedAlbumLeave = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.string("albums.leave_shared_action"), role: .destructive) {
                    guard let album = pendingSharedAlbumLeave else { return }
                    Task {
                        _ = await model.albumActions?.leaveSharedAlbum(album)
                        pendingSharedAlbumLeave = nil
                    }
                }
                Button(L10n.string("action.cancel"), role: .cancel) {
                    pendingSharedAlbumLeave = nil
                }
            } message: {
                Text(L10n.string("albums.leave_shared_message"))
            }
            .alert(
                model.albumActions?.actionFailure?.title ?? "",
                isPresented: Binding(
                    get: { model.albumActions?.actionFailure != nil },
                    set: { if !$0 { model.albumActions?.clearActionFailure() } }
                )
            ) {
                Button(L10n.string("action.ok"), role: .cancel) {
                    model.albumActions?.clearActionFailure()
                }
            } message: {
                Text(model.albumActions?.actionFailure?.message ?? "")
            }
            .sheet(isPresented: $showCreateAlbum) {
                if let coordinator = model.albumActions {
                    AlbumCreationSheet(
                        coordinator: coordinator,
                        onAlbumsChanged: { model.noteAlbumsChanged() },
                        onCompleted: { _ in showCreateAlbum = false }
                    )
                }
            }
        }
    }

    @ViewBuilder private var albumsSection: some View {
        if let coordinator = model.albumActions {
            if coordinator.showsInitialAlbumLoadingPlaceholder {
                HStack {
                    ProgressView().controlSize(.small).tint(ProtonColor.primary)
                    Text("collections.loading_albums").foregroundStyle(ProtonColor.textWeak)
                }
            } else if let message = coordinator.loadErrorMessage, coordinator.albums.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("albums.load_failed").foregroundStyle(ProtonColor.textNorm)
                    Text(message).font(.caption).foregroundStyle(ProtonColor.textWeak)
                    Button(String(localized: "action.try_again")) { Task { await loadAlbums() } }
                        .font(.caption)
                }
            } else if coordinator.albums.isEmpty {
                Text("collections.empty_albums").foregroundStyle(ProtonColor.textWeak)
            } else {
                ForEach(coordinator.albums) { album in
                    NavigationLink {
                        MobileFilterGridScreen(title: album.title, filter: .album(id: album.id, title: album.title))
                    } label: {
                        MobileAlbumRow(album: album)
                    }
                }
            }
        }
    }

    @ViewBuilder private var sharedAlbumsSection: some View {
        if let coordinator = model.albumActions {
            if coordinator.showsInitialSharedAlbumLoadingPlaceholder {
                HStack {
                    ProgressView().controlSize(.small).tint(ProtonColor.primary)
                    Text(L10n.string("collections.loading_shared_albums"))
                        .foregroundStyle(ProtonColor.textWeak)
                }
            } else if let message = coordinator.sharedLoadErrorMessage, coordinator.sharedAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("albums.shared_load_failed"))
                    Text(message).font(.caption).foregroundStyle(ProtonColor.textWeak)
                    Button(L10n.string("action.retry")) {
                        Task { await coordinator.refreshSharedAlbums() }
                    }
                    .font(.caption)
                }
            } else if coordinator.sharedAlbums.isEmpty {
                Text(L10n.string("collections.empty_shared_albums"))
                    .foregroundStyle(ProtonColor.textWeak)
            } else {
                ForEach(coordinator.sharedAlbums) { album in
                    NavigationLink {
                        MobileFilterGridScreen(
                            title: album.title,
                            filter: .sharedAlbum(
                                volumeID: album.node.volumeID, nodeID: album.node.nodeID, title: album.title))
                    } label: {
                        MobileSharedAlbumRow(album: album, presentation: coordinator.presentation(for: album))
                    }
                    .swipeActions {
                        if coordinator.canLeaveSharedAlbum {
                            Button(role: .destructive) {
                                pendingSharedAlbumLeave = album
                            } label: {
                                Label(
                                    L10n.string("albums.leave_shared_action"),
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadAlbums() async {
        guard let coordinator = model.albumActions else { return }
        async let owned: Void = coordinator.refresh()
        async let shared: Void = coordinator.refreshSharedAlbums()
        _ = await (owned, shared)
    }
}

/// Row cover shared by owned and shared album rows and the Duplicates screen. Shows a symbol until the
/// thumbnail feed has the cover in memory or on disk.
struct MobileAlbumCover: View {
    @Environment(MobileLibraryModel.self) private var model
    let coverUID: PhotoUID?
    let fallbackSystemImage: String
    var size: CGFloat = 44
    @State private var coverImage: UIImage?
    @State private var loadedCoverUID: PhotoUID?

    private struct CoverLoadKey: Equatable {
        let uid: PhotoUID?
        let analysisRevision: UInt64
    }

    var body: some View {
        ZStack {
            ProtonColor.primary.opacity(0.12)
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.title3)
                    .foregroundStyle(ProtonColor.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: CoverLoadKey(uid: coverUID, analysisRevision: model.sourceAnalysisRevision)) {
            if loadedCoverUID != coverUID {
                coverImage = nil
                loadedCoverUID = coverUID
            }
            guard coverImage == nil else { return }
            guard let coverUID, let feed = model.thumbnailFeed else { return }
            coverImage = feed.memoryImage(for: coverUID)
            if coverImage == nil {
                coverImage = await feed.analysisImage(for: coverUID)
            }
        }
    }
}

private struct MobileSharedAlbumRow: View {
    let album: SharedAlbumSummary
    let presentation: SharedAlbumPresentation

    var body: some View {
        HStack(spacing: 12) {
            MobileAlbumCover(coverUID: album.coverPhotoUID, fallbackSystemImage: "person.2.crop.square.stack.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ProtonColor.textNorm)
                Text(presentation.detailLine)
                    .font(.caption)
                    .foregroundStyle(ProtonColor.textWeak)
                    .lineLimit(1)
                if let invitation = presentation.invitationDetail {
                    Text(invitation)
                        .font(.caption)
                        .foregroundStyle(ProtonColor.textWeak)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.accessibilityHint ?? "")
    }
}

private struct MobileCollectionRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(ProtonColor.primary)
                .frame(width: 44, height: 44)
                .background(ProtonColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(ProtonColor.textNorm)
        }
        .padding(.vertical, 4)
    }
}

private struct MobileAlbumRow: View {
    let album: AlbumSummary

    var body: some View {
        HStack(spacing: 12) {
            MobileAlbumCover(coverUID: album.coverPhotoUID, fallbackSystemImage: "rectangle.stack.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ProtonColor.textNorm)
                Text("albums.photo_count \(album.photoCount)")
                    .font(.caption)
                    .foregroundStyle(ProtonColor.textWeak)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Presents the shared timeline grid for a `PhotoFilter` route. The route supplies the title and data source.
private struct MobileFilterGridScreen: View {
    @Environment(MobileLibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let filter: PhotoFilter

    @Environment(MobileViewerRouter.self) private var viewerRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshotReconciler = TimelineSnapshotReconciler()
    private var snapshot: TimelineSnapshot { snapshotReconciler.snapshot }
    /// Photos deleted before upload join "Zuletzt gelöscht" with a "Nicht gesichert" badge.
    private var pendingTrash: PendingTrashPresentation { filter == .trash ? model.pendingTrash : .empty }
    private var displayedItems: [PhotoItem] {
        pendingTrash.merged(intoNewestFirst: snapshotReconciler.presentationItems)
    }
    private var isRouteEmpty: Bool { snapshot.isEmpty && pendingTrash.isEmpty }
    @State private var phase: Phase = .loading
    @State private var selection = MobileGridSelectionController()
    @State private var contextMenu = MobileGridContextMenuController()
    @State private var confirmEmptyTrash = false
    @State private var confirmDeleteAlbum = false
    @State private var isDeletingAlbum = false
    @State private var isRestoring = false
    @State private var isEmptyingTrash = false
    @State private var actionError: String?
    @State private var actionErrorTitle = ""
    @State private var showAlbumPicker = false
    @State private var showAlbumPhotoActions = false
    @State private var isRemovingFromAlbum = false
    @State private var networkMonitor = NetworkMonitor.shared

    private enum Phase: Equatable {
        case loading, loaded
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    var body: some View {
        alertContent
            .mobileGridContextMenu(contextMenu, model: model, onRemoved: removeContextItems)
            .task(id: filter) {
                snapshotReconciler.reset()
                await load()
            }
            .onChange(of: viewerRouter.completedMutation) { _, mutation in
                guard let mutation, snapshot.index(of: mutation.uid) != nil else { return }
                reconcileCompletedViewerMutation(mutation)
            }
            .onChange(of: networkMonitor.didRecentlyRestoreConnection) { _, restored in
                guard restored, phase.isFailure else { return }
                Task { await load() }
            }
            .onDisappear {
                snapshotReconciler.invalidatePendingWork()
                showAlbumPicker = false
                showAlbumPhotoActions = false
                selection.finish()
            }
    }

    private var navigationContent: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()
            gridContent
        }
        .mobileNavigationTitle(selection.barTitle(default: title))
        .mobileSelectionBars(isSelecting: selection.isSelecting)
        .toolbar(content: routeToolbarContent)
    }

    @ViewBuilder private var gridContent: some View {
        switch phase {
        case .loading:
            GridLoadingMark()
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "albums.detail_load_failed"), systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button(L10n.string("action.retry")) {
                    Task { await load() }
                }
                .buttonStyle(.glassProminent)
            }
        case .loaded:
            if isRouteEmpty {
                let copy = filter.emptyStateCopy
                ContentUnavailableView {
                    Label(copy.title, systemImage: copy.systemImage)
                } description: {
                    Text(copy.description)
                }
            } else if let feed = model.thumbnailFeed {
                UIKitTimelineGrid(
                    items: displayedItems,
                    thumbnailFeed: feed,
                    fillOrder: .topLeading,
                    selectionMode: selection.isSelecting,
                    selectedUIDs: selection.selected,
                    uploadBadges: pendingTrash.badges,
                    onOpenPhoto: open,
                    onToggleSelection: toggleSelectionHandler,
                    onSelectionChanged: filter.isReadOnly ? nil : { selection.replace(with: $0) },
                    dragOutProvider: model.backend,
                    onDragOutFailed: {
                        actionErrorTitle = L10n.string("dragout.error.title")
                        actionError = $0.localizedMessage
                    },
                    // Shared albums offer only reading actions and Save to Library; the shared policy decides.
                    contextMenuActions: {
                        contextMenu.actions(
                            for: $0, model: model,
                            context: ViewerCollectionContext(filter: filter), albumID: albumID)
                    },
                    onContextMenuAction: { action, items in
                        contextMenu.perform(
                            action, items: items, model: model, router: viewerRouter,
                            context: ViewerCollectionContext(filter: filter), albumID: albumID,
                            onRemoved: removeContextItems)
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private var toggleSelectionHandler: ((PhotoItem) -> Void)? {
        // Shared albums are read-only: no selection mode, so no trash, album or favorite actions.
        filter.isReadOnly ? nil : { selection.toggle($0) }
    }

    private var selectionDialogContent: some View {
        navigationContent
            .mobileSharePresentation(selection: selection)
            .mobileSelectionAlerts(selection: selection) { performTrash() }
    }

    private var alertContent: some View {
        selectionDialogContent
            .alert(L10n.string("trash.empty_title"), isPresented: $confirmEmptyTrash) {
                Button(L10n.string("trash.empty_confirm"), role: .destructive) {
                    Task { await emptyTrash() }
                }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("trash.empty_message"))
            }
            .alert(L10n.string("albums.delete_title"), isPresented: $confirmDeleteAlbum) {
                Button(L10n.string("albums.delete_action"), role: .destructive) {
                    Task { await deleteAlbum() }
                }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("albums.delete_message"))
            }
            .alert(
                actionErrorTitle,
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button(L10n.string("action.ok"), role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .confirmationDialog(
                L10n.string("albums.remove_photos_title"),
                isPresented: $showAlbumPhotoActions,
                titleVisibility: .visible
            ) {
                Button(L10n.string("albums.remove_photos_action")) {
                    removeSelectedFromAlbum()
                }
                Button(L10n.string("albums.move_photos_to_trash"), role: .destructive) {
                    selection.showTrashConfirm = true
                }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("albums.remove_photos_message"))
            }
    }

    private var albumID: String? {
        guard case .album(let id, _) = filter else { return nil }
        return id
    }

    @ToolbarContentBuilder private func routeToolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { topTrailingToolbarAction }
            .mobileVisibilityPriority(.high)
        if filter == .trash {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    restoreSelected()
                } label: {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Label(String(localized: "trash.restore_button"), systemImage: "arrow.uturn.backward")
                    }
                }
                .disabled(selection.selected.isEmpty || selection.isBusy || isRestoring)
                .accessibilityLabel(String(localized: "trash.restore_a11y"))
                .mobileSelectionItemVisibility(selection.isSelecting)
            }
            .sharedBackgroundVisibility(selection.isSelecting ? .automatic : .hidden)
            .mobileVisibilityPriority(.high)
        } else if !filter.isReadOnly {
            MobileSelectionToolbarItems(
                selection: selection,
                canAddToAlbum: model.albumActions?.canAddPhotos == true,
                isTrashBusy: isRemovingFromAlbum,
                showAlbumPicker: $showAlbumPicker,
                onShare: startShare,
                onTrash: {
                    if albumID == nil {
                        selection.showTrashConfirm = true
                    } else {
                        showAlbumPhotoActions = true
                    }
                },
                albumPicker: {
                    if let coordinator = model.albumActions {
                        AlbumDestinationPicker(
                            coordinator: coordinator,
                            photoUIDs: snapshot.orderedUIDs(including: selection.selected),
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
    }

    @ViewBuilder private var topTrailingToolbarAction: some View {
        if selection.isSelecting {
            Button(L10n.string("action.done")) { selection.finish() }
        } else if case .album = filter {
            albumActionsMenu
        } else if filter == .trash, isEmptyingTrash {
            ProgressView()
        } else if filter == .trash {
            Menu {
                Button {
                    selection.toggleMode()
                } label: {
                    Label(L10n.string("action.select"), systemImage: "checkmark.circle")
                }
                .disabled(isRouteEmpty || phase != .loaded || isEmptyingTrash)

                Divider()

                Button(role: .destructive) {
                    confirmEmptyTrash = true
                } label: {
                    Label(L10n.string("trash.empty_button"), systemImage: "trash.slash")
                }
                .disabled(isRouteEmpty || phase != .loaded || isEmptyingTrash)
            } label: {
                Label(L10n.string("albums.more_actions"), systemImage: "ellipsis")
            }
            .accessibilityLabel(L10n.string("albums.more_actions"))
        }
    }

    /// A native toolbar `Menu` receives the system Liquid Glass treatment and morph animation automatically.
    private var albumActionsMenu: some View {
        Menu {
            Button {
                selection.toggleMode()
            } label: {
                Label(L10n.string("action.select"), systemImage: "checkmark.circle")
            }
            .disabled(snapshot.isEmpty || phase != .loaded)

            Divider()

            Button(role: .destructive) {
                confirmDeleteAlbum = true
            } label: {
                Label(L10n.string("albums.delete_action"), systemImage: "trash")
            }
            .disabled(isDeletingAlbum || model.facade?.albums.capabilities.canDelete != true)
        } label: {
            Label(L10n.string("albums.more_actions"), systemImage: "ellipsis")
        }
        .accessibilityLabel(L10n.string("albums.more_actions"))
    }

    private func load() async {
        guard let backend = model.backend, filter.hasTimeline else { return }
        let token = snapshotReconciler.beginLoad()
        phase = .loading
        do {
            let sections = try await backend.timeline(filter: filter)
            // Build the snapshot off the main actor so opening a large album does not block the transition.
            let prepared = await Task.detached(priority: .userInitiated) {
                TimelineSnapshot(sections: sections)
            }.value
            guard !Task.isCancelled, snapshotReconciler.publishLoaded(prepared, token: token) else { return }
            phase = .loaded
        } catch {
            guard !Task.isCancelled, snapshotReconciler.isCurrent(token) else { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func open(_ item: PhotoItem) {
        let items = displayedItems
        let index: Int?
        if pendingTrash.isEmpty {
            index = snapshot.index(of: item.uid).map { snapshot.count - 1 - $0 }  // O(1)
        } else {
            index = items.firstIndex { $0.uid == item.uid }
        }
        guard let index else { return }
        viewerRouter.presentation = MobileViewerPresentation(
            index: index,
            items: items,
            context: ViewerCollectionContext(filter: filter)
        )
    }

    /// Selected photos of this route, including photos deleted before upload.
    private func routeItems(_ uids: Set<PhotoUID>) -> [PhotoItem] {
        snapshot.items(withUIDs: uids) + pendingTrash.items.filter { uids.contains($0.uid) }
    }

    private func removeContextItems(_ uids: Set<PhotoUID>) {
        // Context actions carry explicit items; they never enter or overwrite selection mode.
        selection.selected.subtract(uids)
        let epoch = snapshotReconciler.epoch
        Task {
            _ = await snapshotReconciler.remove(uids, within: epoch)
        }
    }

    private func reconcileCompletedViewerMutation(_ mutation: MobileViewerMutation) {
        let epoch = snapshotReconciler.epoch
        Task {
            if await snapshotReconciler.remove(
                [mutation.uid], within: epoch,
                withPublication: { update in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { update() }
                })
            {
                phase = .loaded
            }
        }
    }

    private func startShare() {
        guard let backend = model.backend else { return }
        selection.startShare(
            items: snapshot.items(withUIDs: selection.selected), backend: backend
        )
    }

    private func performTrash() {
        let epoch = snapshotReconciler.epoch
        selection.performTrash { uids in
            try await model.trashItems(uids)
            if await snapshotReconciler.remove(uids, within: epoch) {
                phase = .loaded
            }
        }
    }

    private func removeSelectedFromAlbum() {
        guard let albumID, !selection.selected.isEmpty, !isRemovingFromAlbum else { return }
        let uids = snapshot.orderedUIDs(including: selection.selected)
        isRemovingFromAlbum = true
        let epoch = snapshotReconciler.epoch
        Task {
            defer { isRemovingFromAlbum = false }
            do {
                try await model.removeItems(uids, fromAlbum: albumID)
                guard await snapshotReconciler.remove(Set(uids), within: epoch) else { return }
                phase = .loaded
                selection.finish()
            } catch {
                actionErrorTitle = L10n.string("albums.remove_photos_failed_title")
                actionError = L10n.string("albums.remove_photos_failed_message")
            }
        }
    }

    @MainActor private func restoreSelected() {
        let selectedItems = routeItems(selection.selected)
        guard !selectedItems.isEmpty, !isRestoring else { return }
        isRestoring = true
        let epoch = snapshotReconciler.epoch
        Task {
            defer { isRestoring = false }
            do {
                try await model.restoreItems(selectedItems)
                let uids = Set(selectedItems.map(\.uid))
                guard await snapshotReconciler.remove(uids, within: epoch) else { return }
                phase = .loaded
                selection.finish()
            } catch {
                actionErrorTitle = String(localized: "trash.restore_failed_title")
                actionError = String(localized: "trash.restore_failed_message")
            }
        }
    }

    @MainActor private func deleteAlbum() async {
        guard let albumID, !isDeletingAlbum else { return }
        isDeletingAlbum = true
        defer { isDeletingAlbum = false }
        do {
            try await model.deleteAlbum(albumID)
            dismiss()
        } catch {
            actionErrorTitle = L10n.string("albums.delete_failed_title")
            actionError = L10n.string("albums.delete_failed_message")
        }
    }

    @MainActor private func emptyTrash() async {
        guard filter == .trash, !isRouteEmpty, !isEmptyingTrash else { return }
        isEmptyingTrash = true
        let epoch = snapshotReconciler.epoch
        defer { isEmptyingTrash = false }
        do {
            // Photos deleted before upload only leave the list; they stay in Apple Photos.
            try await model.emptyTrash(includesProtonTrash: !snapshot.isEmpty)
            guard epoch == snapshotReconciler.epoch else { return }
            snapshotReconciler.reset()
            phase = .loaded
        } catch {
            actionErrorTitle = L10n.string("trash.empty_failed_title")
            actionError = L10n.string("trash.empty_failed_message")
        }
    }
}
