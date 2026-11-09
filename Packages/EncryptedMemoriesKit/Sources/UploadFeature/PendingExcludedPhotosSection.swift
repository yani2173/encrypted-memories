import CoreGraphics
import PhotosCore
import SwiftUI
import UploadCore

/// The one decision of what "Back Up Again" shows after it ran, shared by macOS, iOS and iPadOS: a photo the
/// pending store refused says why nothing happened; a photo that went back into the backup shows nothing.
enum PendingExcludedRestoreFailure {
    /// The alert title to show, or nil when the include succeeded and nothing should appear.
    static func message(includeSucceeded: Bool) -> String? {
        includeSucceeded ? nil : L10n.string("backup.excluded_include_failed")
    }

    /// The alert slot after a "Back Up Again" ran: a success never clears an earlier failure, so a later success
    /// cannot swallow the alert of an earlier refused photo; only the dismissal clears it.
    static func updated(_ current: String?, includeSucceeded: Bool) -> String? {
        includeSucceeded ? current : message(includeSucceeded: false)
    }
}

/// The photos of "Excluded from Backup" on macOS, iOS and iPadOS: photos deleted before they were backed up. Each one
/// can go back into the backup; Apple Photos keeps them either way. The list or sheet around it shows the title.
public struct PendingExcludedPhotosSection: View {
    private let tiles: [PendingTile]
    private let thumbnail: @Sendable (PhotoUID) async -> CGImage?
    private let include: @MainActor (PendingTile) async -> Bool
    @State private var including: Set<PhotoUID> = []
    @State private var restoreFailure: String?

    public init(
        tiles: [PendingTile],
        thumbnail: @escaping @Sendable (PhotoUID) async -> CGImage?,
        include: @escaping @MainActor (PendingTile) async -> Bool
    ) {
        self.tiles = tiles
        self.thumbnail = thumbnail
        self.include = include
    }

    public var body: some View {
        Section {
            ForEach(tiles, id: \.item.uid) { tile in
                HStack(spacing: 12) {
                    LocalPhotoThumbnail(uid: tile.item.uid, retainsImageOnDisappear: true, load: thumbnail)
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
                            restoreFailure = PendingExcludedRestoreFailure.updated(
                                restoreFailure, includeSucceeded: await include(tile))
                            including.remove(uid)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(including.contains(tile.item.uid))
                }
            }
        } footer: {
            Text(L10n.string("backup.excluded_footer"))
        }
        .alert(
            restoreFailure ?? "",
            isPresented: Binding(
                get: { restoreFailure != nil },
                set: { if !$0 { restoreFailure = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) {}
        }
    }
}
