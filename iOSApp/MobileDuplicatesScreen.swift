import DesignSystemCore
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates screen on iPhone and iPad: the shared `ExactDuplicatesView` with the Merge All toolbar button.
struct MobileDuplicatesScreen: View {
    let model: ExactDuplicatesModel
    @State private var confirmsMergeAll = false

    var body: some View {
        ExactDuplicatesView(model: model, confirmsMergeAll: $confirmsMergeAll, accent: ProtonColor.primary) { uid in
            MobileAlbumCover(coverUID: uid, fallbackSystemImage: "photo", size: 96)
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
}
