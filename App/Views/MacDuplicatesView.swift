import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates route on macOS: the shared `ExactDuplicatesView` under the window toolbar. The toolbar owns the
/// buttons Select, Merge All, and Merge Selected and sets `confirmsMergeAll` and `confirmsMergeSelected`; the window
/// opens a copy larger in its photo viewer.
struct MacDuplicatesView: View {
    let model: ExactDuplicatesModel
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    /// The height of the window toolbar that floats over this view.
    let topInset: CGFloat
    @Binding var confirmsMergeAll: Bool
    @Binding var confirmsMergeSelected: Bool
    /// The library item of a copy.
    let item: (PhotoUID) -> PhotoItem?
    /// Opens the viewer with the copies of a group, at the copy at the index.
    let open: ([PhotoItem], Int) -> Void

    var body: some View {
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, confirmsMergeSelected: $confirmsMergeSelected,
            accent: .accentColor, item: item, open: open
        ) { uid in
            AlbumSidebarCover(
                coverUID: uid, fallbackSystemImage: "photo", thumbnailFeed: thumbnailFeed,
                sourceAnalysisRevision: sourceAnalysisRevision, size: 120
            )
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
