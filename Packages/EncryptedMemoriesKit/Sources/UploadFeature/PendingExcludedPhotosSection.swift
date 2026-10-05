import CoreGraphics
import PhotosCore
import SwiftUI
import UploadCore

/// "Vom Backup ausgenommen" in the Backup settings of macOS, iOS and iPadOS: photos deleted before they were
/// backed up. Each one can go back into the backup; Apple Photos keeps them either way.
public struct PendingExcludedPhotosSection: View {
    private let tiles: [PendingTile]
    private let thumbnail: @Sendable (PhotoUID) async -> CGImage?
    private let include: @MainActor (PendingTile) async -> Void
    @State private var including: Set<PhotoUID> = []

    public init(
        tiles: [PendingTile],
        thumbnail: @escaping @Sendable (PhotoUID) async -> CGImage?,
        include: @escaping @MainActor (PendingTile) async -> Void
    ) {
        self.tiles = tiles
        self.thumbnail = thumbnail
        self.include = include
    }

    public var body: some View {
        Section {
            ForEach(tiles, id: \.item.uid) { tile in
                HStack(spacing: 12) {
                    PendingPhotoThumbnail(uid: tile.item.uid, load: thumbnail)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.displayName)
                            .lineLimit(1)
                        Text(tile.item.captureTime, format: .dateTime.day().month().year())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L10n.string("backup.excluded_include")) {
                        let uid = tile.item.uid
                        including.insert(uid)
                        Task {
                            await include(tile)
                            including.remove(uid)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(including.contains(tile.item.uid))
                }
            }
        } header: {
            Text(L10n.string("backup.excluded_title"))
        } footer: {
            Text(L10n.string("backup.excluded_footer"))
        }
    }
}
