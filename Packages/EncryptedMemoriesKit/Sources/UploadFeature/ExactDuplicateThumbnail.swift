import MediaFeedCore
import PhotosCore
import SwiftUI

/// The thumbnails of the Duplicates screen, read through the host's shared thumbnail feed on every platform.
///
/// The feed owns the images: its decoded tier holds them at the display size of the grid, within a bounded budget
/// that shrinks under memory pressure. A tile reads from that tier when it draws and keeps no image of its own, so
/// 1,500 groups cost no more memory than the photos on screen. A tile that finds none loads it into the tier while
/// it is on screen (`ThumbnailFeedCore.visibleDecoded`).
public struct ExactDuplicateThumbnails {
    /// Reads the image of a photo from the shared tier, without loading it. Nil while the tier has none.
    let read: @MainActor (PhotoUID, VisibleThumbnailAccess?) -> Image?
    /// Loads the image of a photo into the shared tier, until it exists or the task is cancelled.
    let load: @MainActor (PhotoUID, VisibleThumbnailAccess?) async -> Void
    /// True when the feed proved that the photo has no thumbnail.
    let unfetchable: @MainActor (PhotoUID, VisibleThumbnailAccess?) -> Bool
    private let feedCore: ThumbnailFeedCore?

    public init(
        read: @escaping @MainActor (PhotoUID) -> Image?, load: @escaping @MainActor (PhotoUID) async -> Void
    ) {
        self.read = { uid, _ in read(uid) }
        self.load = { uid, _ in await load(uid) }
        self.unfetchable = { _, _ in false }
        self.feedCore = nil
    }

    /// Both native hosts use this shared path. Only the visible tile can read with its capability.
    public init(feedCore: ThumbnailFeedCore?) {
        self.feedCore = feedCore
        read = { uid, access in
            guard let access, let image = feedCore?.memoryDecoded(for: uid, access: access)?.image else { return nil }
            return Image(decorative: image, scale: 1)
        }
        load = { uid, access in
            guard let access else { return }
            _ = await feedCore?.visibleDecoded(for: uid, access: access)
        }
        unfetchable = { uid, access in
            guard let access else { return false }
            return feedCore?.isKnownUnfetchable(uid, access: access) ?? false
        }
    }

    func beginAccess(for uid: PhotoUID) -> VisibleThumbnailAccess? {
        feedCore?.beginVisibleThumbnailAccess(for: uid)
    }
}

/// One square thumbnail of the Duplicates screen. It draws the image that the shared tier holds now, and loads it
/// while it is on screen; leaving the screen cancels its load.
public struct ExactDuplicateThumbnail: View {
    private let uid: PhotoUID
    private let side: CGFloat
    private let cornerRadius: CGFloat
    private let thumbnails: ExactDuplicateThumbnails
    /// Counts the loads of this tile, so it draws again after one. It holds no image.
    @State private var loads = 0
    /// Counts the times the shared tier lost the image of this tile, so the tile loads it again.
    @State private var evictions = 0
    @State private var access: VisibleThumbnailAccess?
    @State private var unavailable = false

    public init(uid: PhotoUID, side: CGFloat, cornerRadius: CGFloat, thumbnails: ExactDuplicateThumbnails) {
        self.uid = uid
        self.side = side
        self.cornerRadius = cornerRadius
        self.thumbnails = thumbnails
    }

    private struct LoadKey: Equatable {
        let uid: PhotoUID
        let evictions: Int
    }

    public var body: some View {
        _ = loads
        let image = thumbnails.read(uid, access)
        let isMissing = image == nil
        return ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: unavailable ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        unavailable ? L10n.string("duplicates.thumbnail_unavailable") : L10n.string("loading.content")
                    )
                    .accessibilityIdentifier(
                        unavailable ? "duplicates.thumbnailUnavailable" : "duplicates.thumbnailLoading")
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: LoadKey(uid: uid, evictions: evictions)) {
            // A task that starts after the tile left the screen opens no access.
            guard !Task.isCancelled else { return }
            access?.end()
            let currentAccess = thumbnails.beginAccess(for: uid)
            access = currentAccess
            unavailable = false
            loads &+= 1
            guard thumbnails.read(uid, currentAccess) == nil else { return }
            // Counts a tile that is still blank after 3 s, also when its photo has no thumbnail.
            let overdue = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard access === currentAccess, thumbnails.read(uid, currentAccess) == nil else { return }
                PhotoDiagnostics.shared.increment("duplicates.thumbnail.blankOver3Seconds")
            }
            await withTaskCancellationHandler {
                await thumbnails.load(uid, currentAccess)
            } onCancel: {
                overdue.cancel()
                currentAccess?.end()
            }
            guard !Task.isCancelled else { return }
            unavailable = thumbnails.read(uid, currentAccess) == nil && thumbnails.unfetchable(uid, currentAccess)
            loads &+= 1
        }
        .onDisappear {
            access?.end()
            access = nil
        }
        // Memory pressure can drop the image while the tile shows it; the next draw without it loads it again. A
        // photo without a thumbnail never had an image here, so it does not load in a loop.
        .onChange(of: isMissing) { wasMissing, missing in
            if missing, !wasMissing { evictions &+= 1 }
        }
    }
}
