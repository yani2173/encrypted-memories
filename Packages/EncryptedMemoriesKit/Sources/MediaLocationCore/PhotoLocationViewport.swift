import Foundation
import PhotosCore

public struct PhotoLocationViewport: Sendable, Equatable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    var isFinite: Bool {
        centerLatitude.isFinite
            && centerLongitude.isFinite
            && latitudeDelta.isFinite
            && longitudeDelta.isFinite
    }
}

/// Platform-neutral point dimensions supplied by the native map host. Core uses points only to choose a
/// bounded grid density; it never branches on device type or imports UIKit/AppKit.
public struct PhotoLocationViewportSize: Sendable, Equatable {
    public let widthPoints: Double
    public let heightPoints: Double

    public init(widthPoints: Double, heightPoints: Double) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }
}

/// One immutable aggregation decision shared by the loader cache and its detached worker. Keeping the
/// bounding box and resolution together prevents a resize or pan from being evaluated by two subtly
/// different policies.
public struct PhotoLocationAggregationPlan: Sendable, Equatable {
    public let boundingBox: GeoBoundingBox
    public let resolution: PhotoLocationAggregationResolution
}

public struct PhotoLocationVisibleCoordinatePolicy: Sendable, Equatable {
    public static let standard = PhotoLocationVisibleCoordinatePolicy(
        marginMultiplier: 1.6,
        maxCells: 400,
        cellDivisor: 12,
        minCellMeters: 80,
        minimumPinSpacingPoints: 64
    )

    public let marginMultiplier: Double
    /// Maximum number of aggregated pins returned per query. Each pin represents one grid cell and
    /// may stand in for dozens of photos, so this caps what MKMapView has to render - not the number
    /// of underlying photos. A dense neighborhood of 5k photos at the same block collapses to one cell.
    public let maxCells: Int
    /// How many grid cells fit across the viewport's span. Higher values create finer cells;
    /// lower values create coarser cells. The policy bounds a typical city view to a few hundred
    /// cells at most. The viewport point budget may lower the horizontal or vertical divisor independently.
    public let cellDivisor: Double
    /// Lower bound on grid-cell resolution in meters. This keeps a dense same-place burst bounded as
    /// the user zooms in. Zero disables the floor.
    public let minCellMeters: Double
    /// Center-to-center display spacing. The native badges are 54 points; the standard policy leaves ten
    /// points of breathing room so required annotations never rely on MapKit decluttering for correctness.
    public let minimumPinSpacingPoints: Double

    public init(
        marginMultiplier: Double,
        maxCells: Int,
        cellDivisor: Double,
        minCellMeters: Double = 0,
        minimumPinSpacingPoints: Double = 64
    ) {
        self.marginMultiplier = marginMultiplier
        self.maxCells = maxCells
        self.cellDivisor = cellDivisor
        self.minCellMeters = minCellMeters
        self.minimumPinSpacingPoints = minimumPinSpacingPoints
    }

    public func boundingBox(for viewport: PhotoLocationViewport) -> GeoBoundingBox? {
        guard viewport.isFinite, marginMultiplier.isFinite, marginMultiplier >= 0 else { return nil }

        let latitudeRadius = max(0, viewport.latitudeDelta) * marginMultiplier / 2
        let longitudeRadius = max(0, viewport.longitudeDelta) * marginMultiplier / 2
        let minLongitude: Double
        let maxLongitude: Double
        if longitudeRadius >= 180 {
            minLongitude = -180
            maxLongitude = 180
        } else {
            minLongitude = PhotoCoordinate.normalizedLongitude(viewport.centerLongitude - longitudeRadius)
            maxLongitude = PhotoCoordinate.normalizedLongitude(viewport.centerLongitude + longitudeRadius)
        }
        return GeoBoundingBox(
            minLatitude: max(-90, viewport.centerLatitude - latitudeRadius),
            maxLatitude: min(90, viewport.centerLatitude + latitudeRadius),
            minLongitude: minLongitude,
            maxLongitude: maxLongitude
        )
    }

    /// Filter to the visible box, then produce the final display partition. Every matching UID belongs to
    /// exactly one returned cell and the native host renders those cells directly; there is no second owner.
    public func aggregatedCoordinates(
        from coordinates: [PhotoCoordinate],
        in viewport: PhotoLocationViewport,
        viewportSize: PhotoLocationViewportSize? = nil
    ) -> [AggregatedCoordinate] {
        guard let plan = aggregationPlan(for: viewport, viewportSize: viewportSize) else { return [] }
        return aggregatedCoordinates(from: coordinates, using: plan)
    }

    public func aggregationPlan(
        for viewport: PhotoLocationViewport,
        viewportSize: PhotoLocationViewportSize? = nil
    ) -> PhotoLocationAggregationPlan? {
        guard maxCells > 0, let box = boundingBox(for: viewport) else { return nil }
        let divisors = cellDivisors(for: viewportSize)
        guard
            let resolution = PhotoLocationAggregation.resolution(
                in: viewport,
                latitudeCellDivisor: divisors.latitude,
                longitudeCellDivisor: divisors.longitude,
                maxCells: maxCells,
                minCellMeters: minCellMeters,
                boundingBox: box
            )
        else { return nil }
        return PhotoLocationAggregationPlan(boundingBox: box, resolution: resolution)
    }

    public func aggregatedCoordinates(
        from coordinates: [PhotoCoordinate],
        using plan: PhotoLocationAggregationPlan
    ) -> [AggregatedCoordinate] {
        PhotoLocationAggregation.aggregate(
            coordinates,
            resolution: plan.resolution,
            boundingBox: plan.boundingBox
        )
    }

    private func cellDivisors(
        for viewportSize: PhotoLocationViewportSize?
    ) -> (latitude: Double, longitude: Double) {
        guard let viewportSize,
            minimumPinSpacingPoints.isFinite,
            minimumPinSpacingPoints > 0,
            viewportSize.widthPoints.isFinite,
            viewportSize.heightPoints.isFinite,
            viewportSize.widthPoints > 0,
            viewportSize.heightPoints > 0
        else {
            return (cellDivisor, cellDivisor)
        }
        return (
            min(cellDivisor, max(1, viewportSize.heightPoints / minimumPinSpacingPoints)),
            min(cellDivisor, max(1, viewportSize.widthPoints / minimumPinSpacingPoints))
        )
    }
}

public extension PhotoLocationIndex {
    func coordinates(
        in viewport: PhotoLocationViewport,
        policy: PhotoLocationVisibleCoordinatePolicy,
        viewportSize: PhotoLocationViewportSize? = nil
    ) -> [AggregatedCoordinate] {
        guard let plan = policy.aggregationPlan(for: viewport, viewportSize: viewportSize) else { return [] }
        return policy.aggregatedCoordinates(
            from: querySnapshot().coordinates(in: plan.boundingBox),
            using: plan
        )
    }
}
