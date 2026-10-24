import Foundation

/// A position uses the original Double values. Nearby points never count as identical.
public struct PhotoExactPosition: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(_ coordinate: PhotoCoordinate) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

/// Counts only. This type cannot encode a place, a coordinate, an identifier, or a capture timestamp.
public struct PlaceCandidateSupportSnapshot: Codable, Sendable, Equatable {
    public let photoCount: Int
    public let distinctExactCoordinates: Int
    public let captureSpanWeeks: Int
    public let excludedPhotoCount: Int
}

public protocol PhotoPlaceSupportSource: AnyObject, Sendable {
    func photoPlaceSupportSnapshot() async -> [PlaceCandidateSupportSnapshot]
}

/// One lazy analysis shared by search, support export, and all map viewports of an index revision.
/// Construction shares the existing array storage. Analysis sorts integer offsets, not another photo array.
public final class PhotoPlaceEvidence: @unchecked Sendable {
    public struct Cell: Hashable, Comparable, Sendable {
        public let latitude: Int
        public let longitude: Int

        public init(_ point: PhotoCoordinate) {
            latitude = Int(floor(point.latitude / 0.05))
            longitude = Int(floor(point.longitude * max(0.2, cos(point.latitude * .pi / 180)) / 0.05))
        }

        fileprivate init(latitude: Int, longitude: Int) {
            self.latitude = latitude
            self.longitude = longitude
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.latitude, lhs.longitude) < (rhs.latitude, rhs.longitude)
        }
    }

    private struct Candidate {
        let position: PhotoExactPosition
        let days: [Int]
    }

    private struct DayBounds {
        var minLatitude: Double
        var maxLatitude: Double
        var minLongitude: Double
        var maxLongitude: Double

        init(_ point: PhotoCoordinate) {
            minLatitude = point.latitude
            maxLatitude = point.latitude
            minLongitude = point.longitude
            maxLongitude = point.longitude
        }

        mutating func include(_ point: PhotoCoordinate) {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }

        func contradicts(_ point: PhotoExactPosition) -> Bool {
            // Require varying GPS and separation from the entire day's bounds, not one outlying photo.
            guard minLatitude != maxLatitude || minLongitude != maxLongitude else { return false }
            let latitudeGap = max(minLatitude - point.latitude, point.latitude - maxLatitude)
            if latitudeGap >= 2 { return true }
            // Retain ambiguous polar and antimeridian geometry. Four degrees here exceed 200 km.
            guard max(abs(point.latitude), abs(minLatitude), abs(maxLatitude)) <= 60,
                maxLongitude - minLongitude < 180
            else { return false }
            let longitudeGap = max(minLongitude - point.longitude, point.longitude - maxLongitude)
            return longitudeGap >= 4 && longitudeGap < 180
        }
    }

    private struct Analysis {
        var excluded: Set<PhotoExactPosition> = []
        var diagnostics: [PlaceCandidateSupportSnapshot] = []
    }

    public let coordinates: [PhotoCoordinate]
    private let lock = NSLock()
    private let warmingLock = NSLock()
    private var warmingTask: Task<Void, Never>?
    private var analysisCompleted = false
    private var cached: Analysis?
    #if DEBUG
        private let statusLock = NSLock()
        private var completedOnMainThread: Bool?
        private var analysisStarts = 0
        private var beforeAnalysis: (@Sendable () -> Void)?
        private var beforeWarmingWait: (@Sendable () -> Void)?
    #endif

    public init(coordinates: [PhotoCoordinate]) { self.coordinates = coordinates }

    /// Canceled work does not publish or cache a partial classification.
    public func prewarm() { _ = analysis() }

    /// The index owns this independent task; cancelling a reader does not cancel classification.
    public func registerWarmingTask(_ task: Task<Void, Never>) {
        warmingLock.withLock { warmingTask = task }
    }

    public var warmingIsRetired: Bool {
        warmingLock.withLock { !analysisCompleted && warmingTask?.isCancelled == true }
    }

    public func waitForWarming() async -> Bool {
        #if DEBUG
            let beforeWait = statusLock.withLock { beforeWarmingWait }
            beforeWait?()
        #endif
        let task = warmingLock.withLock { warmingTask }
        await task?.value
        return !warmingIsRetired
    }

    public func excludedPositions() -> Set<PhotoExactPosition> { analysis().excluded }

    public func supportSnapshot() -> [PlaceCandidateSupportSnapshot] { analysis().diagnostics }

    #if DEBUG
        public func setBeforeWarmingWaitForTesting(_ hook: @escaping @Sendable () -> Void) {
            statusLock.withLock { beforeWarmingWait = hook }
        }
        public func setBeforeAnalysisForTesting(_ hook: @escaping @Sendable () -> Void) {
            statusLock.withLock { beforeAnalysis = hook }
        }
        public var analysisStartsForTesting: Int { statusLock.withLock { analysisStarts } }
        public var hasAnalyzed: Bool {
            statusLock.withLock { completedOnMainThread != nil }
        }
        public var analyzedOnMainThread: Bool? { statusLock.withLock { completedOnMainThread } }
    #endif

    public static func isValid(_ point: PhotoCoordinate) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
            && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
            && !(point.latitude == 0 && point.longitude == 0)
    }

    private func analysis() -> Analysis {
        lock.withLock {
            if let cached { return cached }
            guard !warmingIsRetired else { return Analysis() }
            do {
                #if DEBUG
                    let beforeAnalysis = statusLock.withLock {
                        analysisStarts += 1
                        return self.beforeAnalysis
                    }
                    beforeAnalysis?()
                #endif
                let result = try analyze()
                try Task.checkCancellation()
                cached = result
                warmingLock.withLock { analysisCompleted = true }
                #if DEBUG
                    statusLock.withLock { completedOnMainThread = Thread.isMainThread }
                #endif
                return result
            } catch {
                // analyze throws only CancellationError. Consumers discard canceled work.
                return Analysis()
            }
        }
    }

    private static func day(_ date: Date) -> Int? {
        let seconds = date.timeIntervalSince1970
        // Missing crawl dates (.distantPast), invalid dates, and implausible dates cannot establish evidence.
        guard seconds.isFinite, seconds > 0, seconds < 4_102_444_800 else { return nil }
        return Int(floor(seconds / 86_400))
    }

    /// Select capture-day ordinals across the complete range. Input order cannot change the sample.
    private func sampledDays(_ offsets: ArraySlice<Int>, totalDays: Int) throws -> [Int] {
        let sampleCount = min(32, totalDays)
        var days: [Int] = []
        var previousDay: Int?
        var ordinal = -1
        for (index, offset) in offsets.enumerated() {
            if index.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard let day = Self.day(coordinates[offset].date), day != previousDay else { continue }
            previousDay = day
            ordinal += 1
            let selectedOrdinal = days.count * (totalDays - 1) / (sampleCount - 1)
            if ordinal == selectedOrdinal { days.append(day) }
            if days.count == sampleCount { break }
        }
        return days
    }

    private func analyze() throws -> Analysis {
        try Task.checkCancellation()
        var offsets: [Int] = []
        for offset in coordinates.indices {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            if Self.isValid(coordinates[offset]) { offsets.append(offset) }
        }
        var comparisons = 0
        try offsets.sort { left, right in
            comparisons += 1
            if comparisons.isMultiple(of: 4096) { try Task.checkCancellation() }
            let a = coordinates[left]
            let b = coordinates[right]
            let ac = Cell(a)
            let bc = Cell(b)
            if ac != bc { return ac < bc }
            if a.latitude != b.latitude { return a.latitude < b.latitude }
            if a.longitude != b.longitude { return a.longitude < b.longitude }
            return (Self.day(a.date) ?? Int.min) < (Self.day(b.date) ?? Int.min)
        }
        var result = Analysis()
        var candidates: [Cell: Candidate] = [:]
        var repeatedCells = Set<Cell>()
        var diagnosticCells: [(Cell, PlaceCandidateSupportSnapshot)] = []
        var start = 0
        while start < offsets.count {
            try Task.checkCancellation()
            let first = coordinates[offsets[start]]
            let cell = Cell(first)
            var end = start
            var distinct = 0
            var previous: PhotoExactPosition?
            var earliest: Date?
            var latest: Date?
            var dayCount = 0
            var previousDay: Int?
            while end < offsets.count, Cell(coordinates[offsets[end]]) == cell {
                if end.isMultiple(of: 1024) { try Task.checkCancellation() }
                let point = coordinates[offsets[end]]
                let position = PhotoExactPosition(point)
                if position != previous {
                    distinct += 1
                    previous = position
                }
                if let day = Self.day(point.date) {
                    earliest = min(earliest ?? point.date, point.date)
                    latest = max(latest ?? point.date, point.date)
                    if day != previousDay { dayCount += 1 }
                    previousDay = day
                }
                end += 1
            }
            let count = end - start
            let span = earliest.flatMap { first in latest.map { $0.timeIntervalSince(first) } } ?? 0
            if count >= 6 {
                diagnosticCells.append(
                    (
                        cell,
                        PlaceCandidateSupportSnapshot(
                            photoCount: count, distinctExactCoordinates: distinct,
                            captureSpanWeeks: Int((span / (7 * 86_400)).rounded()), excludedPhotoCount: 0)
                    ))
                diagnosticCells.sort {
                    if $0.1.photoCount != $1.1.photoCount { return $0.1.photoCount > $1.1.photoCount }
                    return $0.0 < $1.0
                }
                if diagnosticCells.count > 10 { diagnosticCells.removeLast() }
            }
            // Sampling and candidate caps bound day evidence independently of library size.
            // Unexamined positions stay eligible. Nearby variation protects fixed home coordinates.
            if distinct == 1, count >= 50 { repeatedCells.insert(cell) }
            if distinct == 1, count >= 50, dayCount >= 20, span >= 90 * 86_400,
                abs(first.latitude) <= 60, abs(first.longitude) <= 175, candidates.count < 128
            {
                let days = try sampledDays(offsets[start..<end], totalDays: dayCount)
                candidates[cell] = Candidate(position: PhotoExactPosition(first), days: days)
            }
            start = end
        }
        result.diagnostics = diagnosticCells.map(\.1)
        guard !candidates.isEmpty else { return result }
        var protected = Set<Cell>()
        let requestedDays = Set(candidates.values.flatMap(\.days))
        var bounds: [Int: DayBounds] = [:]
        for (ordinal, offset) in offsets.enumerated() {
            if ordinal.isMultiple(of: 1024) { try Task.checkCancellation() }
            let point = coordinates[offset]
            let cell = Cell(point)
            let position = PhotoExactPosition(point)
            for lat in -1...1 {
                for lon in -1...1 {
                    let neighbor = Cell(latitude: cell.latitude + lat, longitude: cell.longitude + lon)
                    if let candidate = candidates[neighbor], candidate.position != position {
                        protected.insert(neighbor)
                    }
                }
            }
            // Repeated stationary groups cannot prove that another stationary group is false.
            guard !repeatedCells.contains(cell), let day = Self.day(point.date), requestedDays.contains(day) else {
                continue
            }
            if bounds[day] != nil { bounds[day]?.include(point) } else { bounds[day] = DayBounds(point) }
        }
        for (cell, candidate) in candidates where !protected.contains(cell) {
            let contradicted = candidate.days.filter { bounds[$0]?.contradicts(candidate.position) == true }.count
            if contradicted >= 20, contradicted * 5 >= candidate.days.count * 4 {
                result.excluded.insert(candidate.position)
            }
        }
        // Diagnostics describe the unfiltered candidates, so a suppressed default remains diagnosable.
        if !result.excluded.isEmpty {
            var excludedCounts: [Cell: Int] = [:]
            for (ordinal, offset) in offsets.enumerated() {
                if ordinal.isMultiple(of: 1024) { try Task.checkCancellation() }
                if result.excluded.contains(PhotoExactPosition(coordinates[offset])) {
                    excludedCounts[Cell(coordinates[offset]), default: 0] += 1
                }
            }
            result.diagnostics = diagnosticCells.map { cell, entry in
                PlaceCandidateSupportSnapshot(
                    photoCount: entry.photoCount, distinctExactCoordinates: entry.distinctExactCoordinates,
                    captureSpanWeeks: entry.captureSpanWeeks, excludedPhotoCount: excludedCounts[cell] ?? 0)
            }
        }
        return result
    }
}
