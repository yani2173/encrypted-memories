import CoreGraphics

/// Geometry of the mobile viewer's filmstrip rows below the media. The bars themselves are native; compact
/// landscape trades filmstrip height for the shorter window. The folded layout of a partly open device gives the
/// lower part to a slightly taller filmstrip and the photo details.
public struct ViewerChromeLayoutProfile: Equatable, Sendable {
    /// The date and time, the place and the albums of the photo, shown in the lower part of the folded layout.
    public struct Details: Equatable, Sendable {
        /// The insets beside and above and below the details.
        public let horizontalPadding: CGFloat
        public let verticalPadding: CGFloat
        /// The space between the date row, the place and the album chips.
        public let groupSpacing: CGFloat
        /// The space between the date and the time: beside each other, or stacked when the row is too narrow.
        public let titleSpacing: CGFloat
        public let stackedTitleSpacing: CGFloat
        /// The album chips: their spacing, their insets and the longest title width before it truncates.
        public let albumChipSpacing: CGFloat
        public let albumChipHorizontalPadding: CGFloat
        public let albumChipVerticalPadding: CGFloat
        public let albumChipMaxWidth: CGFloat
    }

    public let controlSide: CGFloat
    public let filmstripHeight: CGFloat
    public let filmstripItemSide: CGFloat
    public let rowSpacing: CGFloat
    public let bottomPadding: CGFloat
    /// The details of the photo, or `nil` while the lower part shows only the filmstrip.
    public let details: Details?

    public var showsDetails: Bool { details != nil }

    /// The height of the filmstrip row while it lies over the media: its top spacing, the strip and its bottom
    /// padding. The media ends this far above the bottom of its area.
    public var stackedLowerPartHeight: CGFloat { rowSpacing + filmstripHeight + bottomPadding }

    public static let regular = ViewerChromeLayoutProfile(
        controlSide: 52,
        filmstripHeight: 54,
        filmstripItemSide: 46,
        rowSpacing: 8,
        bottomPadding: 8,
        details: nil
    )

    public static let compactLandscape = ViewerChromeLayoutProfile(
        controlSide: 44,
        filmstripHeight: 46,
        filmstripItemSide: 46,
        rowSpacing: 6,
        bottomPadding: 4,
        details: nil
    )

    public static let folded = ViewerChromeLayoutProfile(
        controlSide: 52,
        filmstripHeight: 68,
        filmstripItemSide: 60,
        rowSpacing: 8,
        bottomPadding: 8,
        details: Details(
            horizontalPadding: 20,
            verticalPadding: 12,
            groupSpacing: 12,
            titleSpacing: 8,
            stackedTitleSpacing: 2,
            albumChipSpacing: 8,
            albumChipHorizontalPadding: 12,
            albumChipVerticalPadding: 6,
            albumChipMaxWidth: 240
        )
    )

    /// The profile for the lower part. `sideBySide` is the system's folded arrangement, read from the z-index it gives
    /// the media and the lower part (`ViewerArrangement`); it is never derived from the device.
    public static func resolve(sideBySide: Bool, compactLandscape: Bool) -> ViewerChromeLayoutProfile {
        if sideBySide { return .folded }
        return compactLandscape ? .compactLandscape : .regular
    }
}
