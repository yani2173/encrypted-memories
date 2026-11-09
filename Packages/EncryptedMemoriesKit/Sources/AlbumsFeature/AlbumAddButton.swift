import AlbumCore
import PhotosCore
import SwiftUI

/// The Add to Album toolbar button of the grid and the viewer. It opens `AlbumDestinationPicker` for `photoUIDs`
/// in a popover anchored to the button; each platform places it in its native toolbar. Adding, creating, capability
/// gating, and failures stay in `AlbumActionCoordinator`.
public struct AlbumAddButton: View {
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    private let coordinator: AlbumActionCoordinator
    private let photoUIDs: [PhotoUID]
    @Binding private var isPresented: Bool
    private let arrowEdge: Edge
    private let onAlbumsChanged: () -> Void
    private let onCompleted: (AlbumID) -> Void

    public init(
        coordinator: AlbumActionCoordinator,
        photoUIDs: [PhotoUID],
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        onAlbumsChanged: @escaping () -> Void = {},
        onCompleted: @escaping (AlbumID) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.photoUIDs = photoUIDs
        _isPresented = isPresented
        self.arrowEdge = arrowEdge
        self.onAlbumsChanged = onAlbumsChanged
        self.onCompleted = onCompleted
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(L10n.string("albums.add_selection_title"), systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(photoUIDs.isEmpty || !coordinator.canAddPhotos)
        .help(L10n.string("albums.add_selection_title"))
        .accessibilityLabel(L10n.string("albums.add_selection_title"))
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            AlbumDestinationPicker(
                coordinator: coordinator,
                photoUIDs: photoUIDs,
                regularPresentation: regularPresentation,
                onAlbumsChanged: onAlbumsChanged,
                onCompleted: { albumID in
                    isPresented = false
                    onCompleted(albumID)
                }
            )
        }
    }

    private var regularPresentation: Bool? {
        #if os(iOS)
            AlbumPresentationTraits.usesRegularSizing(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
        #else
            nil
        #endif
    }
}
