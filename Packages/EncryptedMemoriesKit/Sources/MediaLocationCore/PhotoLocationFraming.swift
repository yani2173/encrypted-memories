import Foundation
import PhotosCore

/// Where to point the map when it first opens. The naive "fit every coordinate" framing is skewed by
/// outliers: one holiday photo in another continent drags the center out into the ocean (the classic
/// "somewhere between Africa and Europe" complaint). This frames the dense core instead, the place
/// most of the photos actually are - and drops the far-flung few.
///
/// Platform-neutral (Foundation only), so the macOS and iOS map hosts share one framing rule.
public enum PhotoLocationFraming {
    /// A bounding box around the dense core of `coordinates`, with distant outliers dropped.
    ///
    /// Anchors on the median latitude/longitude, then keeps only the
    /// points within `gate` median-distances of that anchor. A tight cluster has a small median
    /// distance, so a photo far away is well outside the gate and excluded; a genuinely spread-out
    /// library has a large median distance, so the gate still contains it. Longitude is weighted by
    /// the cosine of the anchor latitude so the distance test isn't skewed away from the equator.
    ///
    /// Returns `nil` for empty/all-non-finite input.
    public static func denseBoundingBox(
        for coordinates: [PhotoCoordinate],
        gate: Double = 3.0,
        paddingFraction: Double = 0.15,
        minimumSpanDegrees: Double = 0.02,
        excluding positions: Set<PhotoExactPosition> = []
    ) -> GeoBoundingBox? {
        let points = coordinates.filter {
            $0.latitude.isFinite && $0.longitude.isFinite && !positions.contains(PhotoExactPosition($0))
        }
        guard !points.isEmpty else { return nil }
        guard points.count > 2 else {
            return paddedBox(of: points, paddingFraction: paddingFraction, minimumSpanDegrees: minimumSpanDegrees)
        }

        let medLat = median(points.map(\.latitude))
        let medLon = median(points.map(\.longitude))
        // A degree of longitude covers less ground toward the poles; weight it so the gate is fair.
        let lonScale = max(0.1, cos(medLat * .pi / 180))

        func distance(_ p: PhotoCoordinate) -> Double {
            let dLat = p.latitude - medLat
            let dLon = (p.longitude - medLon) * lonScale
            return (dLat * dLat + dLon * dLon).squareRoot()
        }

        let medDist = median(points.map(distance))
        // When more than half the points sit on the same spot the median distance is ~0; fall back to a
        // small floor so we still keep the cluster (and not just the exact-median points).
        let cutoff = max(medDist * gate, minimumSpanDegrees)
        let core = points.filter { distance($0) <= cutoff }
        return paddedBox(
            of: core.isEmpty ? points : core,
            paddingFraction: paddingFraction,
            minimumSpanDegrees: minimumSpanDegrees
        )
    }

    // MARK: - Helpers

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func paddedBox(
        of points: [PhotoCoordinate],
        paddingFraction: Double,
        minimumSpanDegrees: Double
    ) -> GeoBoundingBox? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for p in points {
            minLat = Swift.min(minLat, p.latitude)
            maxLat = Swift.max(maxLat, p.latitude)
            minLon = Swift.min(minLon, p.longitude)
            maxLon = Swift.max(maxLon, p.longitude)
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let latSpan = Swift.max(maxLat - minLat, minimumSpanDegrees)
        let lonSpan = Swift.max(maxLon - minLon, minimumSpanDegrees)
        let latHalf = latSpan / 2 * (1 + paddingFraction)
        let lonHalf = lonSpan / 2 * (1 + paddingFraction)
        return GeoBoundingBox(
            minLatitude: centerLat - latHalf,
            maxLatitude: centerLat + latHalf,
            minLongitude: centerLon - lonHalf,
            maxLongitude: centerLon + lonHalf
        )
    }
}
