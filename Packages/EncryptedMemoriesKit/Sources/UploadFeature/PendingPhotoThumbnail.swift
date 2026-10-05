import CoreGraphics
import PhotosCore
import SwiftUI

/// The small preview of a local photo in a backup list row, such as the backup queue or the excluded photos.
/// A gray photo symbol stands in until the image loads or when the photo has no image.
public struct PendingPhotoThumbnail: View {
    private let uid: PhotoUID
    private let load: @Sendable (PhotoUID) async -> CGImage?
    @State private var image: CGImage?

    public init(uid: PhotoUID, load: @escaping @Sendable (PhotoUID) async -> CGImage?) {
        self.uid = uid
        self.load = load
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.rect(cornerRadius: 7))
        .accessibilityHidden(true)
        .task(id: uid) { image = await load(uid) }
    }
}
