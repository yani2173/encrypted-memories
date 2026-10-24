import DesignSystemCore
import MediaCacheUIKitAdapter
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates screen on iPhone and iPad: the shared `ExactDuplicatesView` with the Merge All toolbar button. A tap
/// on a photo opens the shared viewer with the photos of its group and the merge tools.
struct MobileDuplicatesScreen: View {
    let model: ExactDuplicatesModel
    /// The shared thumbnail feed of the library. The thumbnails come from its bounded decoded tier.
    let feed: UIKitThumbnailFeed?
    @Environment(MobileLibraryModel.self) private var libraryModel
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var confirmsMergeAll = false

    /// Three copies side by side fit an iPhone list row; a larger group scrolls.
    private static let thumbnailSide: CGFloat = 104
    private static let cornerRadius: CGFloat = 10

    var body: some View {
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, accent: ProtonColor.primary,
            cornerRadius: Self.cornerRadius, canOpen: { libraryModel.snapshot.item(for: $0) != nil },
            onOpen: { openPhoto($0, groupID: $1) }
        ) { uid in
            ExactDuplicateThumbnail(
                uid: uid, side: Self.thumbnailSide, cornerRadius: Self.cornerRadius, thumbnails: thumbnails)
        }
        .mobileNavigationTitle(L10n.string("duplicates.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("duplicates.merge_all")) { confirmsMergeAll = true }
                    .disabled(!model.canMerge)
                    .accessibilityIdentifier("duplicates.mergeAll")
            }
        }
    }

    private var thumbnails: ExactDuplicateThumbnails {
        ExactDuplicateThumbnails(feedCore: feed?.feedCore)
    }

    /// Opens `uid` with the other photos of its group that the library shows.
    private func openPhoto(_ uid: PhotoUID, groupID: String) {
        let snapshot = libraryModel.snapshot
        guard let opened = model.viewerItems(opening: uid, inGroup: groupID, item: { snapshot.item(for: $0) })
        else { return }
        viewerRouter.presentation = MobileViewerPresentation(
            index: opened.index, items: opened.items, context: .library,
            duplicateGroup: MobileDuplicateViewerGroup(model: model))
    }
}
