/// How the viewer's media and its lower part (the filmstrip, and the details in the folded layout) share the display.
///
/// An overlay arrangement lays the lower part over the media while the display is whole, and puts the two on separate
/// parts of the display when the system selects the folded layout of a partly open device: the media above and the
/// lower part below in tabletop, the media leading and the lower part trailing in book pose. The system reports this
/// through each part's z-index in the arrangement (`overlayArrangementZIndex`): the lower part lies above the media
/// only while the display is whole. The viewer never reads the device or the hinge angle.
public enum ViewerArrangement {
    public enum VideoTransportPlacement: Equatable, Sendable {
        case hidden
        case media
        case lowerPart
    }

    /// The system arrangement chooses the transport's region; the flat design stays over the media.
    public static func videoTransportPlacement(
        isDivided: Bool, showsChrome: Bool, isAvailable: Bool
    ) -> VideoTransportPlacement {
        guard showsChrome else { return .hidden }
        guard isAvailable else { return .hidden }
        return isDivided ? .lowerPart : .media
    }

    /// Whether the system put the two parts side by side: the lower part no longer lies above the media.
    public static func isSideBySide(lowerPartZIndex: Int, mediaZIndex: Int) -> Bool {
        lowerPartZIndex <= mediaZIndex
    }
}
