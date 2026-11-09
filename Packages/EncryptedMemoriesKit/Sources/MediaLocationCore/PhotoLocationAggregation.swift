import Foundation
import PhotosCore

public struct PhotoLocationAggregationResolution: Sendable, Equatable {
    public let latitudeStepExponent: Int
    public let longitudeCellCountExponent: Int
    public let maximumCellCount: Int
}

/// Bins map coordinates into a bounded number of stable, world-anchored cells.
public struct PhotoLocationAggregation {
    private struct AxisGrid {
        let cellCount: Int
        let step: Double
    }

    private struct Bin {
        var memberUIDs: [PhotoUID] = []
        var hero: PhotoCoordinate?
        var latitudeSum = 0.0
        var longitudeSinSum = 0.0
        var longitudeCosSum = 0.0

        mutating func append(_ coordinate: PhotoCoordinate) {
            memberUIDs.append(coordinate.uid)
            latitudeSum += coordinate.latitude
            let longitudeRadians = coordinate.longitude * .pi / 180
            longitudeSinSum += Foundation.sin(longitudeRadians)
            longitudeCosSum += Foundation.cos(longitudeRadians)
            if let current = hero {
                if isNewer(coordinate, than: current) { hero = coordinate }
            } else {
                hero = coordinate
            }
        }

        var displayCoordinate: (latitude: Double, longitude: Double)? {
            guard let hero, !memberUIDs.isEmpty else { return nil }
            let latitude = latitudeSum / Double(memberUIDs.count)
            let longitude: Double
            if Foundation.hypot(longitudeSinSum, longitudeCosSum) > 1e-12 {
                longitude = Foundation.atan2(longitudeSinSum, longitudeCosSum) * 180 / .pi
            } else {
                // A perfectly circular distribution has no unique centroid. Keep the pin on a real member
                // rather than inventing a location at an unrelated world-grid center.
                longitude = hero.longitude
            }
            return (latitude, longitude)
        }

        private func isNewer(_ lhs: PhotoCoordinate, than rhs: PhotoCoordinate) -> Bool {
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return (lhs.uid.volumeID, lhs.uid.nodeID) > (rhs.uid.volumeID, rhs.uid.nodeID)
        }
    }

    /// Every matching input UID appears exactly once in the result. The final world-grid resolution is
    /// selected from geometry before coordinates are scanned, so crossing an occupied-cell threshold can
    /// never discard members or abruptly choose a different resolution.
    public static func aggregate(
        _ coordinates: [PhotoCoordinate],
        in viewport: PhotoLocationViewport,
        cellDivisor: Double,
        maxCells: Int,
        minCellMeters: Double = 0,
        boundingBox: GeoBoundingBox? = nil
    ) -> [AggregatedCoordinate] {
        aggregate(
            coordinates,
            in: viewport,
            latitudeCellDivisor: cellDivisor,
            longitudeCellDivisor: cellDivisor,
            maxCells: maxCells,
            minCellMeters: minCellMeters,
            boundingBox: boundingBox
        )
    }

    /// Independent horizontal/vertical divisors let a shared adapter inject its actual viewport size: a tall
    /// phone can target more rows than columns while a wide Mac can target more columns.
    public static func aggregate(
        _ coordinates: [PhotoCoordinate],
        in viewport: PhotoLocationViewport,
        latitudeCellDivisor: Double,
        longitudeCellDivisor: Double,
        maxCells: Int,
        minCellMeters: Double = 0,
        boundingBox: GeoBoundingBox? = nil
    ) -> [AggregatedCoordinate] {
        guard
            let resolution = resolution(
                in: viewport,
                latitudeCellDivisor: latitudeCellDivisor,
                longitudeCellDivisor: longitudeCellDivisor,
                maxCells: maxCells,
                minCellMeters: minCellMeters,
                boundingBox: boundingBox
            )
        else { return [] }
        return aggregate(coordinates, resolution: resolution, boundingBox: boundingBox)
    }

    static func resolution(
        in viewport: PhotoLocationViewport,
        latitudeCellDivisor: Double,
        longitudeCellDivisor: Double,
        maxCells: Int,
        minCellMeters: Double,
        boundingBox: GeoBoundingBox?
    ) -> PhotoLocationAggregationResolution? {
        guard viewport.isFinite,
            latitudeCellDivisor.isFinite,
            longitudeCellDivisor.isFinite,
            latitudeCellDivisor > 0,
            longitudeCellDivisor > 0,
            minCellMeters.isFinite,
            maxCells > 0
        else { return nil }

        let metersPerDegreeLatitude = 111_320.0
        let longitudeScale = max(abs(Foundation.cos(viewport.centerLatitude * .pi / 180)), 0.01)
        let latitudeFloor = minCellMeters > 0 ? minCellMeters / metersPerDegreeLatitude : 0
        let longitudeFloor = minCellMeters > 0 ? minCellMeters / (metersPerDegreeLatitude * longitudeScale) : 0
        let requestedLatitudeStep = max(max(viewport.latitudeDelta, 0) / latitudeCellDivisor, latitudeFloor)
        let requestedLongitudeStep = max(max(viewport.longitudeDelta, 0) / longitudeCellDivisor, longitudeFloor)

        var latitudeExponent = latitudeStepExponent(for: requestedLatitudeStep)
        var longitudeCountExponent = longitudeCellCountExponent(for: requestedLongitudeStep)
        let latitudeSpan = boundingBox.map { max(0, $0.maxLatitude - $0.minLatitude) } ?? 180
        let longitudeSpan = boundingBox.map(longitudeSpan(of:)) ?? 360
        guard latitudeSpan.isFinite, longitudeSpan.isFinite else { return nil }

        var latitudeCount = worstCaseLatitudeCellCount(span: latitudeSpan, exponent: latitudeExponent)
        var longitudeCount = worstCaseLongitudeCellCount(span: longitudeSpan, countExponent: longitudeCountExponent)
        while latitudeCount > maxCells / longitudeCount {
            if latitudeCount >= longitudeCount, latitudeCount > 1 {
                latitudeExponent += 1
                latitudeCount = worstCaseLatitudeCellCount(span: latitudeSpan, exponent: latitudeExponent)
            } else if longitudeCountExponent > 0 {
                longitudeCountExponent -= 1
                longitudeCount = worstCaseLongitudeCellCount(
                    span: longitudeSpan,
                    countExponent: longitudeCountExponent
                )
            } else {
                latitudeExponent += 1
                latitudeCount = worstCaseLatitudeCellCount(span: latitudeSpan, exponent: latitudeExponent)
            }
        }

        return PhotoLocationAggregationResolution(
            latitudeStepExponent: latitudeExponent,
            longitudeCellCountExponent: longitudeCountExponent,
            maximumCellCount: latitudeCount * longitudeCount
        )
    }

    static func aggregate(
        _ coordinates: [PhotoCoordinate],
        resolution: PhotoLocationAggregationResolution,
        boundingBox: GeoBoundingBox?
    ) -> [AggregatedCoordinate] {
        guard !coordinates.isEmpty else { return [] }
        var bins: [PhotoLocationCellID: Bin] = [:]
        bins.reserveCapacity(min(coordinates.count, resolution.maximumCellCount))

        for (offset, coordinate) in coordinates.enumerated() {
            if offset.isMultiple(of: 1_024), Task.isCancelled { return [] }
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                (-90...90).contains(coordinate.latitude)
            else { continue }
            if let boundingBox,
                !boundingBox.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
            {
                continue
            }
            let key = cellID(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                resolution: resolution
            )
            bins[key, default: Bin()].append(coordinate)
        }

        return bins.compactMap { key, bin in
            guard let hero = bin.hero, let center = bin.displayCoordinate else { return nil }
            return AggregatedCoordinate(
                cellID: key,
                memberUIDs: bin.memberUIDs,
                latitude: center.latitude,
                longitude: center.longitude,
                uid: hero.uid
            )
        }.sorted(by: cellOrder)
    }

    private static func latitudeStepExponent(for requestedStep: Double) -> Int {
        guard requestedStep.isFinite, requestedStep > 0 else { return 0 }
        return min(10, max(-40, Int(Foundation.ceil(Foundation.log2(requestedStep)))))
    }

    /// Longitude is a circular power-of-two partition, not a power-of-two degree step. This keeps the
    /// antimeridian seam closed and guarantees that every coarser cell owns exactly two finer children.
    private static func longitudeCellCountExponent(for requestedStep: Double) -> Int {
        guard requestedStep.isFinite, requestedStep > 0 else { return 0 }
        let requestedCellCount = max(1, 360 / requestedStep)
        return min(50, max(0, Int(Foundation.floor(Foundation.log2(requestedCellCount)))))
    }

    private static func cellID(
        latitude: Double,
        longitude: Double,
        resolution: PhotoLocationAggregationResolution
    ) -> PhotoLocationCellID {
        let latitudeGrid = latitudeGrid(exponent: resolution.latitudeStepExponent)
        let longitudeGrid = longitudeGrid(countExponent: resolution.longitudeCellCountExponent)
        let latitudeIndex = min(
            latitudeGrid.cellCount - 1,
            max(0, Int(Foundation.floor((latitude + 90) / latitudeGrid.step)))
        )
        let longitudeIndex = min(
            longitudeGrid.cellCount - 1,
            max(0, Int(Foundation.floor((PhotoCoordinate.normalizedLongitude(longitude) + 180) / longitudeGrid.step)))
        )
        return PhotoLocationCellID(
            latitudeStepExponent: resolution.latitudeStepExponent,
            longitudeCellCountExponent: resolution.longitudeCellCountExponent,
            latitudeIndex: latitudeIndex,
            longitudeIndex: longitudeIndex
        )
    }

    private static func latitudeGrid(exponent: Int) -> AxisGrid {
        let step = Foundation.pow(2, Double(exponent))
        return AxisGrid(cellCount: max(1, Int(Foundation.ceil(180 / step))), step: step)
    }

    private static func longitudeGrid(countExponent: Int) -> AxisGrid {
        let cellCount = 1 << countExponent
        return AxisGrid(cellCount: cellCount, step: 360 / Double(cellCount))
    }

    private static func worstCaseLatitudeCellCount(span: Double, exponent: Int) -> Int {
        let grid = latitudeGrid(exponent: exponent)
        return min(grid.cellCount, max(1, Int(Foundation.ceil(span / grid.step)) + 1))
    }

    private static func worstCaseLongitudeCellCount(span: Double, countExponent: Int) -> Int {
        let grid = longitudeGrid(countExponent: countExponent)
        return min(grid.cellCount, max(1, Int(Foundation.ceil(span / grid.step)) + 1))
    }

    private static func longitudeSpan(of box: GeoBoundingBox) -> Double {
        if box.minLongitude <= box.maxLongitude {
            return min(360, max(0, box.maxLongitude - box.minLongitude))
        }
        return min(360, max(0, 360 - box.minLongitude + box.maxLongitude))
    }

    private static func cellOrder(_ lhs: AggregatedCoordinate, _ rhs: AggregatedCoordinate) -> Bool {
        let a = lhs.cellID
        let b = rhs.cellID
        if a.latitudeStepExponent != b.latitudeStepExponent {
            return a.latitudeStepExponent < b.latitudeStepExponent
        }
        if a.longitudeCellCountExponent != b.longitudeCellCountExponent {
            return a.longitudeCellCountExponent < b.longitudeCellCountExponent
        }
        if a.latitudeIndex != b.latitudeIndex { return a.latitudeIndex < b.latitudeIndex }
        if a.longitudeIndex != b.longitudeIndex { return a.longitudeIndex < b.longitudeIndex }
        return (lhs.uid.volumeID, lhs.uid.nodeID) < (rhs.uid.volumeID, rhs.uid.nodeID)
    }
}
