import AlbumsFeature
import Observation
import PhotoViewerCore
import PhotosCore
import SwiftUI

/// Presentation of existing library operations, independent of selection mode.
@MainActor @Observable final class MobileGridContextMenuController {
    struct Items: Identifiable {
        let id = UUID()
        let photos: [PhotoItem]
    }

    var albumItems: Items?
    var trashItems: Items?
    var error: String?
    /// Outcome of a completed Save to Library request.
    var notice: String?
    private(set) var isBusy = false

    func actions(
        for items: [PhotoItem], model: MobileLibraryModel,
        context: ViewerCollectionContext = .library, albumID: String? = nil
    ) -> [PhotoContextMenuAction] {
        let uids = Set(items.map(\.uid))
        if context == .sharedAlbum {
            return PhotoContextMenuPolicy.sharedAlbumActions(
                itemCount: items.count, canSave: model.backend != nil && !isBusy)
        }
        return PhotoContextMenuPolicy.actions(
            itemCount: items.count, isTrash: context == .trash,
            canMutate: model.backend != nil && !isBusy,
            canFavorite: model.favoriteMutationsInFlight.isDisjoint(with: uids),
            allFavorited: uids.isSubset(of: model.displayedFavoriteUIDs),
            canAddToAlbum: model.albumActions?.canAddPhotos == true,
            canRemoveFromAlbum: albumID != nil)
    }

    func perform(
        _ action: PhotoContextMenuAction, items: [PhotoItem], model: MobileLibraryModel,
        router: MobileViewerRouter, context: ViewerCollectionContext = .library,
        albumID: String? = nil, onRemoved: @escaping (Set<PhotoUID>) -> Void = { _ in }
    ) {
        guard !items.isEmpty else { return }
        guard !isBusy || action == .information else { return }
        let uids = Set(items.map(\.uid))
        switch action {
        case .copy, .share:
            break  // Owned by the common UIKit item-provider path.
        case .addToAlbum:
            albumItems = Items(photos: items)
        case .information:
            router.presentation = MobileViewerPresentation(
                index: 0, items: items, context: context, showsInfoInitially: true)
        case .trash:
            trashItems = Items(photos: items)
        case .favorite, .unfavorite:
            isBusy = true
            Task {
                defer { isBusy = false }
                if !(await model.toggleFavorite(uids)) { error = String(localized: "selection.favorite_failed") }
            }
        case .restore:
            mutate(failure: String(localized: "trash.restore_failed_message"), removed: uids, onRemoved: onRemoved) {
                try await model.restoreItems(items)
            }
        case .saveToLibrary:
            isBusy = true
            Task {
                defer { isBusy = false }
                let result = await model.saveToLibrary(items.map(\.uid))
                notice = result?.message ?? L10n.string("library.save_to_library_failed")
            }
        case .removeFromAlbum:
            guard let albumID else { return }
            mutate(failure: L10n.string("albums.remove_photos_failed_message"), removed: uids, onRemoved: onRemoved) {
                try await model.removeItems(items.map(\.uid), fromAlbum: albumID)
            }
        }
    }

    func confirmTrash(model: MobileLibraryModel, onRemoved: @escaping (Set<PhotoUID>) -> Void) {
        guard let pending = trashItems else { return }
        trashItems = nil
        let uids = Set(pending.photos.map(\.uid))
        mutate(failure: String(localized: "selection.trash_failed"), removed: uids, onRemoved: onRemoved) {
            try await model.trashItems(uids)
        }
    }

    private func mutate(
        failure: String, removed: Set<PhotoUID>, onRemoved: @escaping (Set<PhotoUID>) -> Void,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await action()
                onRemoved(removed)
            } catch {
                self.error = failure
            }
        }
    }
}

private struct MobileGridContextMenuPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var controller: MobileGridContextMenuController
    let model: MobileLibraryModel
    let onRemoved: (Set<PhotoUID>) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.albumItems) { payload in
                if let coordinator = model.albumActions {
                    AlbumDestinationPicker(
                        coordinator: coordinator, photoUIDs: payload.photos.map(\.uid),
                        regularPresentation: AlbumPresentationTraits.usesRegularSizing(
                            horizontal: horizontalSizeClass, vertical: verticalSizeClass),
                        onAlbumsChanged: { model.noteAlbumsChanged() },
                        onCompleted: { _ in controller.albumItems = nil })
                }
            }
            .alert(
                String(localized: "viewer.trash_title"),
                isPresented: Binding(
                    get: { controller.trashItems != nil },
                    set: { if !$0 { controller.trashItems = nil } }
                ), presenting: controller.trashItems
            ) { payload in
                Button(String(localized: "viewer.trash_confirm"), role: .destructive) {
                    // Capture the alert payload; SwiftUI can clear its binding before the action.
                    controller.trashItems = payload
                    controller.confirmTrash(model: model, onRemoved: onRemoved)
                }
                Button(L10n.string("action.cancel"), role: .cancel) { controller.trashItems = nil }
            } message: { _ in
                Text(String(localized: "viewer.trash_message"))
            }
            .alert(
                controller.error ?? "",
                isPresented: Binding(
                    get: { controller.error != nil }, set: { if !$0 { controller.error = nil } }
                )
            ) {
                Button(L10n.string("action.ok"), role: .cancel) { controller.error = nil }
            }
            .alert(
                controller.notice ?? "",
                isPresented: Binding(
                    get: { controller.notice != nil }, set: { if !$0 { controller.notice = nil } }
                )
            ) {
                Button(L10n.string("action.ok"), role: .cancel) { controller.notice = nil }
            }
    }
}

extension View {
    func mobileGridContextMenu(
        _ controller: MobileGridContextMenuController, model: MobileLibraryModel,
        onRemoved: @escaping (Set<PhotoUID>) -> Void = { _ in }
    ) -> some View {
        modifier(MobileGridContextMenuPresentation(controller: controller, model: model, onRemoved: onRemoved))
    }
}
