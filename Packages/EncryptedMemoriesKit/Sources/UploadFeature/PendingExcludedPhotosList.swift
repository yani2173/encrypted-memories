import CoreGraphics
import DesignSystemCore
import PhotosCore
import SwiftUI
import UploadCore

/// The label of the "Excluded from Backup" entry in the Backup settings of macOS, iOS and iPadOS, with the number
/// of excluded photos when the list is not empty.
public struct PendingExcludedPhotosEntryLabel: View {
    private let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        LabeledContent {
            if count > 0 {
                Text(count.formatted())
                    .monospacedDigit()
            }
        } label: {
            Text(L10n.string("backup.excluded_title"))
        }
    }
}

/// The list behind the "Excluded from Backup" entry on macOS, iOS and iPadOS. After the last photo went back into
/// the backup, it shows its empty state in place.
public struct PendingExcludedPhotosList: View {
    private let tiles: [PendingTile]
    private let thumbnail: @Sendable (PhotoUID) async -> CGImage?
    private let include: @MainActor (PendingTile) async -> Bool

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
        Form {
            if !tiles.isEmpty {
                PendingExcludedPhotosSection(tiles: tiles, thumbnail: thumbnail, include: include)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if tiles.isEmpty {
                LibraryEmptyView(copy: .excludedFromBackup)
            }
        }
    }
}

extension PhotoFilterEmptyStateCopy {
    /// The empty list of photos excluded from the backup.
    public static var excludedFromBackup: PhotoFilterEmptyStateCopy {
        PhotoFilterEmptyStateCopy(
            title: L10n.string("backup.excluded_empty"),
            description: L10n.string("backup.excluded_empty_description"),
            systemImage: "icloud.slash")
    }
}
