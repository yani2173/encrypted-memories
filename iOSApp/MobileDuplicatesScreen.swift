import DesignSystemCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates screen on iPhone and iPad: the shared `ExactDuplicatesView` with the Merge All toolbar button. A
/// copy opens larger in the app's photo viewer, which pages through the copies of its group and plays a video.
struct MobileDuplicatesScreen: View {
    let model: ExactDuplicatesModel
    @Environment(MobileLibraryModel.self) private var library
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var confirmsMergeAll = false
    @State private var confirmsMergeSelected = false

    var body: some View {
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, confirmsMergeSelected: $confirmsMergeSelected,
            accent: ProtonColor.primary, item: { library.snapshot.item(for: $0) },
            open: { items, index in
                viewerRouter.presentation = MobileViewerPresentation(
                    index: index, items: items, context: ViewerCollectionContext(filter: .duplicates))
            }
        ) { uid in
            MobileAlbumCover(coverUID: uid, fallbackSystemImage: "photo", size: 96)
        }
        .mobileNavigationTitle(L10n.string("duplicates.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string(model.isSelecting ? "action.done" : "action.select")) {
                    if model.isSelecting {
                        model.stopSelecting()
                    } else {
                        model.startSelecting()
                    }
                }
                .disabled(!model.isSelecting && !model.canMerge)
                .accessibilityIdentifier("duplicates.select")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.isSelecting {
                    Button(L10n.string("duplicates.merge_selected")) { confirmsMergeSelected = true }
                        .disabled(!model.canMergeSelected)
                        .accessibilityIdentifier("duplicates.mergeSelected")
                } else {
                    Button(L10n.string("duplicates.merge_all")) { confirmsMergeAll = true }
                        .disabled(!model.canMerge)
                        .accessibilityIdentifier("duplicates.mergeAll")
                }
            }
        }
    }
}
