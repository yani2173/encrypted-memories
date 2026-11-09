import CoreGraphics
import Observation
import PhotosCore
import SwiftUI

/// The same decorative thumbnail in excluded-photo and backup-problem rows.
public struct LocalPhotoThumbnail: View {
    private let uid: PhotoUID?
    private let retainsImageOnDisappear: Bool
    private let reloadID: ObjectIdentifier?
    private let load: @Sendable (PhotoUID) async -> CGImage?
    @State private var state = LocalPhotoThumbnailState()

    public init(
        uid: PhotoUID?, retainsImageOnDisappear: Bool = false, reloadID: ObjectIdentifier? = nil,
        load: @escaping @Sendable (PhotoUID) async -> CGImage?
    ) {
        self.uid = uid
        self.retainsImageOnDisappear = retainsImageOnDisappear
        self.reloadID = reloadID
        self.load = load
    }

    public var body: some View {
        ZStack {
            if let uid, let image = state.image(for: uid) {
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
        .task(id: TaskID(uid: uid, reloadID: reloadID)) {
            guard let uid else {
                state.clear(retainingImage: retainsImageOnDisappear)
                return
            }
            await state.load(uid, retainingImage: retainsImageOnDisappear || reloadID != nil, using: load)
        }
        .onDisappear { state.clear(retainingImage: retainsImageOnDisappear) }
    }

    private struct TaskID: Equatable {
        let uid: PhotoUID?
        let reloadID: ObjectIdentifier?
    }
}

/// Bind a result to the row's current identity, including the interval before its new task starts.
@MainActor
@Observable
final class LocalPhotoThumbnailState {
    private var uid: PhotoUID?
    private var image: CGImage?
    private var generation = UUID()

    func image(for uid: PhotoUID) -> CGImage? { self.uid == uid ? image : nil }

    func load(
        _ uid: PhotoUID, retainingImage: Bool = false, using load: @Sendable (PhotoUID) async -> CGImage?
    ) async {
        clear(retainingImage: retainingImage && self.uid == uid)
        self.uid = uid
        let generation = generation
        let image = await load(uid)
        guard !Task.isCancelled, self.generation == generation else { return }
        self.image = image
    }

    func clear(retainingImage: Bool = false) {
        generation = UUID()
        if !retainingImage {
            uid = nil
            image = nil
        }
    }
}
