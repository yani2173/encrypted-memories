import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates route on macOS: the shared `ExactDuplicatesView` under the window toolbar. The toolbar owns the
/// Merge All button and sets `confirmsMergeAll`.
struct MacDuplicatesView: View {
    let model: ExactDuplicatesModel
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    /// The height of the window toolbar that floats over this view.
    let topInset: CGFloat
    @Binding var confirmsMergeAll: Bool

    var body: some View {
        ExactDuplicatesView(model: model, confirmsMergeAll: $confirmsMergeAll, accent: .accentColor) { uid in
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
