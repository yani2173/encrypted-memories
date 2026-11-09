import SwiftUI

/// Previous, Next, Close, Show Original and Revert to Original of the focused photo viewer, published to the scene so the app's View
/// menu can offer them as native commands.
///
/// Close needs the menu route as well: `onExitCommand` only fires while the viewer or one of its descendants
/// holds focus, and the native inspector column takes focus away from the media.
public struct PhotoViewerNavigation {
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let goPrevious: () -> Void
    public let goNext: () -> Void
    public let close: () -> Void
    /// The page is an edited photo whose original the viewer found; Show Original is disabled otherwise.
    public let canShowOriginal: Bool
    public let isShowingOriginal: Bool
    public let toggleOriginal: () -> Void
    /// "Revert to Original…" is available: the page is an edited photo of the own library and nothing runs.
    public let canRevertToOriginal: Bool
    public let revertToOriginal: () -> Void
}

extension FocusedValues {
    @Entry public var photoViewerNavigation: PhotoViewerNavigation?
}
