import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates route on macOS: the shared `ExactDuplicatesView` under the window toolbar. The toolbar owns the
/// Merge All button and sets `confirmsMergeAll`; a click on a photo opens it in the viewer with its group.
struct MacDuplicatesView: View {
    let model: ExactDuplicatesModel
    let thumbnailFeed: ThumbnailFeed
    /// The height of the window toolbar that floats over this view.
    let topInset: CGFloat
    @Binding var confirmsMergeAll: Bool
    /// True once the library shows a photo, so the viewer can open it.
    let canOpen: (PhotoUID) -> Bool
    /// Changes when the library shows other photos; `canOpen` reads a library that is not observed.
    let libraryRevision: UInt64
    /// Opens a photo and the ID of its group in the viewer.
    let onOpen: (PhotoUID, String) -> Void

    /// A fixed, comfortable thumbnail size: a wide window adds margins, not larger photos.
    private static let thumbnailSide: CGFloat = 132
    private static let cornerRadius: CGFloat = 6

    /// The thumbnails come from the bounded decoded tier of the shared feed; the screen keeps none of its own.
    private var thumbnails: ExactDuplicateThumbnails {
        ExactDuplicateThumbnails(feedCore: thumbnailFeed.feedCore)
    }

    var body: some View {
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, accent: .accentColor, cornerRadius: Self.cornerRadius,
            canOpen: canOpen, libraryRevision: libraryRevision, onOpen: onOpen
        ) { uid in
            ExactDuplicateThumbnail(
                uid: uid, side: Self.thumbnailSide, cornerRadius: Self.cornerRadius, thumbnails: thumbnails)
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
