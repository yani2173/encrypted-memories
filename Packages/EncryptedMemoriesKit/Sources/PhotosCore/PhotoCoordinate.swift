import Foundation

/// A photo's place on the map: its decrypted GPS coordinate + capture date, keyed by `PhotoUID`.
///
/// Platform-agnostic (Foundation only) so one index drives the macOS, iPadOS, and iOS map UIs.
/// The core is shared; only the map view is platform-specific. The
/// coordinates are sensitive PII; MediaLocationCore stores them encrypted at rest (`PhotoLocationStore`)
/// and decrypted only in RAM (`PhotoLocationIndex`).
public struct PhotoCoordinate: Sendable, Equatable, Codable, Identifiable {
    public let uid: PhotoUID
    public let latitude: Double
    public let longitude: Double
    public let date: Date

    public var id: PhotoUID { uid }

    public init(uid: PhotoUID, latitude: Double, longitude: Double, date: Date) {
        self.uid = uid
        self.latitude = latitude
        self.longitude = longitude
        self.date = date
    }

    /// Wraps `longitude` into `[-180, 180)` degrees.
    public static func normalizedLongitude(_ longitude: Double) -> Double {
        let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (shifted >= 0 ? shifted : shifted + 360) - 180
    }
}

public enum PhotoCoordinateText {
    public static func format(latitude: Double, longitude: Double) -> String {
        "\(latitude.formatted(.number.precision(.fractionLength(6)))), \(longitude.formatted(.number.precision(.fractionLength(6))))"
    }
}

/// A lat/lon bounding box - the visible map rect (+ margin) the index is queried against.
public struct GeoBoundingBox: Sendable, Equatable {
    public let minLatitude, maxLatitude, minLongitude, maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= minLatitude, latitude <= maxLatitude else { return false }
        if minLongitude <= maxLongitude {
            return longitude >= minLongitude && longitude <= maxLongitude
        }
        // A wrapped box crosses the antimeridian (for example 170° ... -170°).
        return longitude >= minLongitude || longitude <= maxLongitude
    }
}
