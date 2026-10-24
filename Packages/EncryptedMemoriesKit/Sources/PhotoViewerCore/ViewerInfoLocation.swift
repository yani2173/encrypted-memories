import PhotosCore

/// Presentation of the stored location and the place name already resolved by the viewer.
public struct ViewerInfoLocation {
    public let placeName: String?
    public let markerTitle: String
    public let coordinateText: String?
    public let showsMap: Bool
    /// Whether the location section has anything to show: a usable place name or the stored coordinates.
    public var hasContent: Bool { placeName != nil || coordinateText != nil }
    /// What VoiceOver reads for the map: the marker title and the stored coordinates. Nil without a map.
    public var mapAccessibilityLabel: String? {
        guard showsMap, let coordinateText else { return nil }
        return "\(markerTitle), \(coordinateText)"
    }
    /// Identity of the Info map. `Map(initialPosition:)` applies its camera only when a map first appears, so
    /// each host gives its map this value: a photo with other coordinates then gets a new map at its own place.
    public var mapIdentity: String? { showsMap ? coordinateText : nil }

    public init(metadata: PhotoMetadata?, placeName: String?, mapAndPlacesEnabled: Bool) {
        self.placeName = mapAndPlacesEnabled ? PlaceNameText.displayable(placeName) : nil
        markerTitle = self.placeName ?? L10n.string("map.cluster_title")
        if let latitude = metadata?.latitude, let longitude = metadata?.longitude {
            coordinateText = PhotoCoordinateText.format(latitude: latitude, longitude: longitude)
            showsMap = mapAndPlacesEnabled
        } else {
            coordinateText = nil
            showsMap = false
        }
    }
}
