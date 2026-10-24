import PhotoViewerCore
import PhotosCore
import XCTest

final class ViewerInfoLocationTests: XCTestCase {
    private let metadata = PhotoMetadata(latitude: 48.3, longitude: 14.2)

    func testKnownLocationShowsTheResolvedNameMapAndStoredCoordinates() {
        let location = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: true)
        XCTAssertEqual(location.placeName, "Known place")
        XCTAssertEqual(location.markerTitle, "Known place")
        XCTAssertTrue(location.showsMap)
        XCTAssertEqual(location.coordinateText, PhotoCoordinateText.format(latitude: 48.3, longitude: 14.2))
    }

    func testKnownLocationWithoutANameStillShowsMapAndCoordinates() {
        for name: String? in [nil, ""] {
            let location = ViewerInfoLocation(metadata: metadata, placeName: name, mapAndPlacesEnabled: true)
            XCTAssertNil(location.placeName)
            XCTAssertEqual(location.markerTitle, L10n.string("map.cluster_title"))
            XCTAssertTrue(location.showsMap)
            XCTAssertNotNil(location.coordinateText)
        }
    }

    func testWhitespaceOnlyPlaceNameUsesTheFallbackMarkerTitle() {
        for name: String? in [" ", "\n", " \t\n ", "\u{00A0}"] {
            let location = ViewerInfoLocation(metadata: metadata, placeName: name, mapAndPlacesEnabled: true)
            XCTAssertNil(location.placeName)
            XCTAssertEqual(location.markerTitle, L10n.string("map.cluster_title"))
            XCTAssertTrue(location.showsMap)
            XCTAssertNotNil(location.coordinateText)
        }
    }

    func testPlaceNameWithTextIsKeptExactlyAsGiven() {
        let location = ViewerInfoLocation(metadata: metadata, placeName: " Known place ", mapAndPlacesEnabled: true)
        XCTAssertEqual(location.placeName, " Known place ")
        XCTAssertEqual(location.markerTitle, " Known place ")
    }

    func testLocationSectionHasContentOnlyWithANameOrCoordinates() {
        let noCoordinates = PhotoMetadata()
        for name: String? in [nil, "", " ", "\n\u{00A0}"] {
            let location = ViewerInfoLocation(metadata: noCoordinates, placeName: name, mapAndPlacesEnabled: true)
            XCTAssertFalse(location.hasContent, "a blank name without coordinates leaves the section empty")
        }
        let hidden = ViewerInfoLocation(metadata: noCoordinates, placeName: "Known place", mapAndPlacesEnabled: false)
        XCTAssertFalse(hidden.hasContent, "Map and Places off hides the name; nothing else is left")
        let named = ViewerInfoLocation(metadata: noCoordinates, placeName: "Known place", mapAndPlacesEnabled: true)
        XCTAssertTrue(named.hasContent)
        for enabled in [true, false] {
            let located = ViewerInfoLocation(metadata: metadata, placeName: " ", mapAndPlacesEnabled: enabled)
            XCTAssertTrue(located.hasContent, "stored coordinates are always shown")
        }
    }

    func testMapAccessibilityLabelNamesTheMarkerAndTheStoredCoordinates() {
        let coordinates = PhotoCoordinateText.format(latitude: 48.3, longitude: 14.2)
        let named = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: true)
        XCTAssertEqual(named.mapAccessibilityLabel, "Known place, \(coordinates)")
        for name: String? in [nil, "", " "] {
            let unnamed = ViewerInfoLocation(metadata: metadata, placeName: name, mapAndPlacesEnabled: true)
            XCTAssertEqual(unnamed.mapAccessibilityLabel, "\(L10n.string("map.cluster_title")), \(coordinates)")
        }
    }

    func testMapAccessibilityLabelExistsOnlyWhereTheMapIsShown() {
        let off = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: false)
        XCTAssertNil(off.mapAccessibilityLabel, "Map and Places off shows no map")
        let none = ViewerInfoLocation(metadata: PhotoMetadata(), placeName: "Known place", mapAndPlacesEnabled: true)
        XCTAssertNil(none.mapAccessibilityLabel, "no stored coordinates shows no map")
    }

    func testMapIdentityChangesWithTheStoredCoordinates() {
        func identity(_ latitude: Double, _ longitude: Double, name: String? = "Known place") -> String? {
            let metadata = PhotoMetadata(latitude: latitude, longitude: longitude)
            return ViewerInfoLocation(metadata: metadata, placeName: name, mapAndPlacesEnabled: true).mapIdentity
        }
        XCTAssertNotNil(identity(48.3, 14.2))
        XCTAssertNotEqual(identity(48.3, 14.2), identity(40.71, -74.0), "another place needs a new map")
        XCTAssertNotEqual(identity(48.3, 14.2), identity(48.3, 14.3))
        XCTAssertNotEqual(identity(48.3, 14.2), identity(48.4, 14.2))
        XCTAssertEqual(identity(48.3, 14.2), identity(48.3, 14.2, name: nil), "the place name does not rebuild the map")
    }

    func testMapIdentityExistsOnlyWhereTheMapIsShown() {
        let off = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: false)
        XCTAssertNil(off.mapIdentity)
        let none = ViewerInfoLocation(metadata: PhotoMetadata(), placeName: nil, mapAndPlacesEnabled: true)
        XCTAssertNil(none.mapIdentity)
    }

    func testNoLocationShowsNeitherMapNorCoordinates() {
        let location = ViewerInfoLocation(metadata: PhotoMetadata(), placeName: nil, mapAndPlacesEnabled: true)
        XCTAssertNil(location.placeName)
        XCTAssertFalse(location.showsMap)
        XCTAssertNil(location.coordinateText)
    }

    func testMapAndPlacesOffKeepsOnlyStoredCoordinates() {
        let location = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: false)
        XCTAssertNil(location.placeName)
        XCTAssertFalse(location.showsMap)
        XCTAssertEqual(location.coordinateText, PhotoCoordinateText.format(latitude: 48.3, longitude: 14.2))
    }
}
