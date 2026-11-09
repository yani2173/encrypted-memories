import CoreGraphics

/// An area of a view that the device reserves (Apple's reserved regions): the folding region of iPhone Duo while it
/// is partly open (a division), or hardware such as a camera that covers content (an occlusion). A platform adapter
/// converts the system's regions into this form, in the coordinates of the view that lays out the grid.
public struct ReservedRegionArea: Equatable, Sendable {
    /// The region including the margins that interactive content keeps from it.
    public var frame: CGRect
    /// A division is active only while the device is partly open.
    public var isActive: Bool
    public var isDivision: Bool

    public init(frame: CGRect, isActive: Bool, isDivision: Bool = false) {
        self.frame = frame
        self.isActive = isActive
        self.isDivision = isDivision
    }
}

/// Keeps the selection mark of a grid tile clear of the active reserved regions. Photos may scroll through a region;
/// the mark moves out of it (HIG: move only what's necessary to keep elements visible and easy to tap).
public struct ReservedRegionLayout: Equatable, Sendable {
    public static let none = ReservedRegionLayout(areas: [], bounds: .null)

    /// The frames of the active regions, including their interactive margins.
    public let exclusions: [CGRect]
    public let divisions: [CGRect]
    /// The visible part of the view, without the bars; a mark that moves must stay inside it.
    public let bounds: CGRect

    public init(areas: [ReservedRegionArea], bounds: CGRect) {
        exclusions = areas.filter { $0.isActive && !$0.frame.isEmpty }.map(\.frame)
        divisions = areas.filter { $0.isActive && $0.isDivision && !$0.frame.isEmpty }.map(\.frame)
        self.bounds = bounds
    }

    public var isEmpty: Bool { exclusions.isEmpty }

    /// Optional bounds for centering the whole loading block in tabletop. Other layouts keep their existing placement.
    public var centeredLoadingBounds: CGRect? {
        guard let fold = horizontalFold else { return nil }
        return CGRect(
            x: bounds.minX, y: bounds.minY, width: bounds.width,
            height: max(0, min(bounds.maxY, fold.minY) - bounds.minY))
    }

    /// A viewport-spanning horizontal division supplies the generic tabletop placement rule.
    public var horizontalFold: CGRect? {
        divisions.first { $0.width >= $0.height && isCrossingBand($0) }
    }

    /// Whether `rect` stays clear of every active region.
    public func isClear(_ rect: CGRect) -> Bool {
        !exclusions.contains { $0.intersects(rect) }
    }

    /// The frame of a tile's selection mark: bottom-trailing unless an active region covers it. A covered mark moves to
    /// the nearest free position inside the visible part of the tile: clear of every region, completely inside `bounds`,
    /// and covering none of the tile's labels in `occupied`. Candidate positions lie on a grid of half a mark, starting
    /// at the bottom-trailing corner and always including the leading and top edges, so equally near positions keep the
    /// bottom row and the trailing side first. When only a label leaves room, the mark covers the label: selection comes
    /// first. If no in-tile slot fits, the mark uses a clear band-edge slot at the column centre.
    /// A fully excluded viewport has no usable placement.
    public func selectionMarkRect(
        in tile: CGRect, side: CGFloat, inset: CGFloat, avoiding occupied: [CGRect] = [],
        neighboringTiles: [CGRect] = [], prefersAlternate: Bool = false, layout: GridSelectionBadgeLayout? = nil
    ) -> CGRect {
        let inset = Self.selectionMarkInset(in: tile, side: side, preferred: inset)
        if horizontalFold != nil {
            var decision = GridSelectionBadgeDecision()
            decision.update(
                tile: tile, home: Self.homeMarkRect(in: tile, side: side, inset: inset), regions: self, delta: .zero,
                canAvoidBand: tile.height >= side + 2 * inset)
            return Self.homeMarkRect(in: tile, side: side, inset: inset, top: !decision.usesAlternate)
        }
        return inTileSelectionMarkRect(
            in: tile, side: side, inset: inset, avoiding: occupied,
            prefersAlternate: prefersAlternate)
            ?? exteriorMark(in: tile, side: side, inset: inset, neighboringTiles: neighboringTiles, layout: layout)
            ?? .null
    }

    func inTileSelectionMarkRect(
        in tile: CGRect, side: CGFloat, inset: CGFloat, avoiding occupied: [CGRect] = [],
        prefersAlternate: Bool = false
    ) -> CGRect? {
        let home = Self.homeMarkRect(in: tile, side: side, inset: inset)
        guard prefersAlternate || !isClear(home) else { return home }
        let visible = tile.intersection(bounds)
        guard !visible.isNull, side > 0 else { return home }
        return nearestFreeRect(
            in: visible, side: side, inset: inset, home: home, avoiding: occupied + (prefersAlternate ? [home] : []),
            tile: tile)
            ?? nearestFreeRect(in: visible, side: side, inset: inset, home: home, avoiding: [], tile: tile)
    }

    /// Keep the established corner unless its centre would enter the inner 40%. The 0.1pt floor is the
    /// approved fine inset; smaller impossible tiles retain their established corner as an explicit exception.
    public static func selectionMarkInset(in tile: CGRect, side: CGFloat, preferred: CGFloat) -> CGFloat {
        let maximum = maximumEdgeInset(in: tile, side: side)
        guard maximum >= 0.1 else { return preferred }
        return min(preferred, maximum)
    }

    private static func maximumEdgeInset(in tile: CGRect, side: CGFloat) -> CGFloat {
        min(tile.width, tile.height) * 0.30 - side / 2 - 0.001
    }

    /// Only a region spanning the usable viewport is a crossing band. A bounded camera/status area is not one.
    public func isCrossingBand(_ region: CGRect) -> Bool {
        (region.minX <= bounds.minX && region.maxX >= bounds.maxX)
            || (region.minY <= bounds.minY && region.maxY >= bounds.maxY)
    }

    /// The middle 40% is never a selection badge slot.
    public static func markIsAtEdge(_ mark: CGRect, of tile: CGRect) -> Bool {
        !tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.3)
            .contains(CGPoint(x: mark.midX, y: mark.midY))
    }

    private func exteriorMark(
        in tile: CGRect, side: CGFloat, inset: CGFloat, neighboringTiles: [CGRect],
        layout: GridSelectionBadgeLayout?
    ) -> CGRect? {
        let home = Self.homeMarkRect(in: tile, side: side, inset: inset)
        let prepared = layout ?? GridSelectionBadgeLayout()
        if layout == nil {
            let tiles = [tile] + neighboringTiles.filter { $0 != tile }
            prepared.prepare(slots: tiles, tiles: tiles, normalMarks: [], regions: self, scrollBucket: 0)
        }
        var nearest: CGRect?
        var distance = CGFloat.infinity
        for (index, region) in exclusions.enumerated() where region.intersects(tile) || region.intersects(home) {
            let axes = isCrossingBand(region) ? [region.width >= region.height] : [true, false]
            for horizontal in axes {
                let sides =
                    isCrossingBand(region)
                    ? [horizontal ? tile.midY < region.midY : tile.midX < region.midX] : [true, false]
                for before in sides {
                    guard
                        let rect = prepared.exteriorCandidate(
                            tile: tile, side: side, regionIndex: index, horizontal: horizontal, before: before)
                    else { continue }
                    let candidateDistance = hypot(rect.midX - tile.midX, rect.midY - tile.midY)
                    if candidateDistance < distance {
                        nearest = rect
                        distance = candidateDistance
                    }
                }
            }
        }
        return nearest
    }

    private func nearestFreeRect(
        in visible: CGRect, side: CGFloat, inset: CGFloat, home: CGRect, avoiding occupied: [CGRect], tile: CGRect
    ) -> CGRect? {
        var nearest: CGRect?
        var nearestDistance = CGFloat.infinity
        let tinyCornerException = Self.maximumEdgeInset(in: tile, side: side) < 0.1
        // Impossible tiny tiles retain only their established corners, not arbitrary centre candidates.
        let xs =
            tinyCornerException
            ? [tile.maxX - side - inset, tile.minX + inset]
            : Self.positions(from: visible.maxX - side - inset, to: visible.minX + inset, step: side / 2)
        let ys =
            tinyCornerException
            ? [tile.maxY - side - inset, tile.minY + inset]
            : Self.positions(from: visible.maxY - side - inset, to: visible.minY + inset, step: side / 2)
        for y in ys {
            for x in xs {
                let rect = CGRect(x: x, y: y, width: side, height: side)
                let distance = distance(rect, home)
                if distance < nearestDistance - 0.5, isClear(rect), bounds.contains(rect),
                    tile.contains(rect),
                    tinyCornerException || Self.markIsAtEdge(rect, of: tile),
                    !occupied.contains(where: { $0.intersects(rect) })
                {
                    nearest = rect
                    nearestDistance = distance
                }
            }
        }
        return nearest
    }

    /// The mark of `side` points in the bottom-trailing corner of a tile, `inset` points from both edges.
    public static func homeMarkRect(in tile: CGRect, side: CGFloat, inset: CGFloat, top: Bool = false) -> CGRect {
        CGRect(
            x: tile.maxX - side - inset, y: top ? tile.minY + inset : tile.maxY - side - inset,
            width: side, height: side)
    }

    /// Positions from `start` down to `end` in steps of `step`, ending exactly on `end` when the steps miss it. A start
    /// below `end` (a tile too small for the mark) gives none; the tolerance absorbs rounding.
    private static func positions(from start: CGFloat, to end: CGFloat, step: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        var position = start
        while position >= end - 0.5 {
            result.append(position)
            position -= step
        }
        if let last = result.last, last > end + 0.5 { result.append(end) }
        return result
    }

    private func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }
}

/// Prepared row facts and the existing no-space filter's one-dimensional centre exclusions.
/// A visible-row bucket keeps its shape while scrolling; only its viewport translation changes.
public final class GridSelectionBadgeLayout {
    public init() {}

    public private(set) var preparationCount = 0
    private struct Shape: Equatable {
        var slots: [CGRect]
        var tiles: [CGRect]
        var marks: [CGRect]
        var regions: ReservedRegionLayout
        var scrollBucket: Int
        var indices: [Int]
    }
    private struct RowKey: Hashable {
        var y: CGFloat
        var height: CGFloat
    }
    private struct Interval {
        var lower: CGFloat
        var upper: CGFloat
    }
    private struct CandidateKey: Hashable {
        var x: CGFloat
        var y: CGFloat
        var side: CGFloat
        var region: Int
        var horizontal: Bool
        var before: Bool
    }
    private var shape: Shape?
    private var offset = CGPoint.zero
    private var horizontalIntervals: [CGFloat: [Interval]] = [:]
    private var verticalIntervals: [CGFloat: [Interval]] = [:]
    private var rows: [GridSelectionBadgeRow] = []
    private var candidates: [CandidateKey: CGRect] = [:]
    private struct RowState {
        var frame: CGRect?
        var decision = GridSelectionBadgeDecision()
    }
    private var rowIDs: [Int] = []
    private var rowStates: [Int: RowState] = [:]

    /// The slot index identifies the visible-row scroll bucket. Fitted shapes and normal marks invalidate it
    /// when a thumbnail arrives or changes aspect. Region/bounds changes also invalidate all prepared facts.
    public func prepare(
        slots: [CGRect], tiles: [CGRect], normalMarks: [CGRect], regions: ReservedRegionLayout, scrollBucket: Int,
        indices: [Int] = []
    ) {
        let nextOffset = slots.first?.origin ?? .zero
        func normalized(_ rect: CGRect) -> CGRect {
            CGRect(
                x: Self.key(rect.minX - nextOffset.x), y: Self.key(rect.minY - nextOffset.y),
                width: Self.key(rect.width), height: Self.key(rect.height))
        }
        let next = Shape(
            slots: slots.map(normalized), tiles: tiles.map(normalized),
            marks: normalMarks.map(normalized), regions: regions, scrollBucket: scrollBucket,
            indices: indices.count == slots.count ? indices : Array(scrollBucket..<(scrollBucket + slots.count)))
        if nextOffset != offset { candidates.removeAll(keepingCapacity: true) }
        offset = nextOffset
        if shape != next {
            shape = next
            preparationCount += 1
            candidates.removeAll(keepingCapacity: true)
            horizontalIntervals.removeAll(keepingCapacity: true)
            verticalIntervals.removeAll(keepingCapacity: true)
            let xs = Array(Set(next.tiles.map { Self.key($0.midX) })).sorted()
            let ys = Array(Set(next.tiles.map { Self.key($0.midY) })).sorted()
            for tile in next.tiles {
                let middle = tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.3)
                // Sorted coordinates locate only columns/rows that can constrain this centre line.
                for x in Self.coordinates(xs, from: middle.minX, to: middle.maxX) {
                    horizontalIntervals[x, default: []].append(
                        Interval(lower: middle.minY - 0.001, upper: middle.maxY + 0.001))
                }
                for y in Self.coordinates(ys, from: middle.minY, to: middle.maxY) {
                    verticalIntervals[y, default: []].append(
                        Interval(lower: middle.minX - 0.001, upper: middle.maxX + 0.001))
                }
            }
            horizontalIntervals = horizontalIntervals.mapValues(Self.merged)
            verticalIntervals = verticalIntervals.mapValues(Self.merged)
            var identities: [RowKey: Int] = [:]
            let rowKeys = next.slots.enumerated().map { index, slot in
                let key = RowKey(y: slot.minY, height: slot.height)
                identities[key] = min(identities[key] ?? next.indices[index], next.indices[index])
                return key
            }
            rowIDs = rowKeys.compactMap { identities[$0] }
        }
        var rowFacts: [Int: GridSelectionBadgeRow] = [:]
        let tabletop = regions.horizontalFold != nil
        for (index, slot) in slots.enumerated() {
            let identity = rowIDs[index]
            let mark = normalMarks.indices.contains(index) ? normalMarks[index] : slot
            let tile = tiles.indices.contains(index) ? tiles[index] : slot
            let fits = !tabletop || tile.height >= mark.height + 2 * (tile.maxY - mark.maxY)
            if let previous = rowFacts[identity] {
                let leading = min(previous.frame.minX, slot.minX)
                rowFacts[identity] = GridSelectionBadgeRow(
                    frame: CGRect(
                        x: leading, y: slot.minY, width: max(previous.frame.maxX, slot.maxX) - leading,
                        height: slot.height),
                    normalMarks: fits
                        ? (previous.hasFittingMarks ? previous.normalMarks.union(mark) : mark) : previous.normalMarks,
                    hasFittingMarks: previous.hasFittingMarks || fits)
            } else {
                rowFacts[identity] = GridSelectionBadgeRow(frame: slot, normalMarks: mark, hasFittingMarks: fits)
            }
        }
        rows = rowIDs.compactMap { rowFacts[$0] }
        updateRowDecisions(regions: regions)
    }

    private func updateRowDecisions(regions: ReservedRegionLayout) {
        let horizontal = ReservedRegionLayout(
            areas: regions.exclusions.filter { regions.isCrossingBand($0) && $0.width >= $0.height }
                .map { ReservedRegionArea(frame: $0, isActive: true, isDivision: regions.divisions.contains($0)) },
            bounds: regions.bounds)
        var next: [Int: RowState] = [:]
        for (index, row) in rows.enumerated() {
            let identity = rowIDs[index]
            guard next[identity] == nil else { continue }
            let frame = row.frame
            let marks = row.normalMarks
            var state = rowStates[identity] ?? RowState()
            if let previous = state.frame,
                Self.key(previous.width) != Self.key(frame.width) || Self.key(previous.height) != Self.key(frame.height)
            {
                state = RowState()
            }
            let delta = state.frame.map { CGPoint(x: frame.minX - $0.minX, y: frame.minY - $0.minY) } ?? .zero
            state.decision.update(
                tile: frame, home: marks, regions: horizontal, delta: delta, canAvoidBand: row.hasFittingMarks)
            state.frame = frame
            next[identity] = state
        }
        rowStates = next
    }

    public func row(at index: Int) -> GridSelectionBadgeRow? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        let decision = rowStates[rowIDs[index]]?.decision
        return GridSelectionBadgeRow(
            frame: row.frame, normalMarks: row.normalMarks,
            usesAlternate: decision?.band == nil ? nil : decision?.usesAlternate, band: decision?.band,
            hasFittingMarks: row.hasFittingMarks)
    }

    public func clearsTileCenters(_ mark: CGRect) -> Bool {
        let x = Self.key(mark.midX - offset.x)
        let y = mark.midY - offset.y
        if let intervals = horizontalIntervals[x] { return Self.containing(y, in: intervals) == nil }
        // All exterior points use a prepared tile centre line. An unrecognised line is not reusable.
        return false
    }

    func exteriorCandidate(tile: CGRect, side: CGFloat, regionIndex: Int, horizontal: Bool, before: Bool) -> CGRect? {
        guard let shape, shape.regions.exclusions.indices.contains(regionIndex) else { return nil }
        let region = shape.regions.exclusions[regionIndex]
        let fixed = horizontal ? tile.midX : tile.midY
        let translation = horizontal ? offset.y : offset.x
        let line = Self.key(fixed - (horizontal ? offset.x : offset.y))
        let intervals = (horizontal ? horizontalIntervals[line] : verticalIntervals[line]) ?? []
        let half = side / 2
        let boundary = horizontal ? (before ? region.minY : region.maxY) : (before ? region.minX : region.maxX)
        var center = horizontal ? tile.midY : tile.midX
        center = before ? min(center, boundary - half) : max(center, boundary + half)
        // Fully covered rows in the same column share the band-edge candidate in this scroll bucket.
        let key = CandidateKey(
            x: horizontal ? fixed : center, y: horizontal ? center : fixed, side: side, region: regionIndex,
            horizontal: horizontal, before: before)
        if let cached = candidates[key] { return cached.isNull ? nil : cached }
        let lower = (horizontal ? shape.regions.bounds.minY : shape.regions.bounds.minX) + half
        let upper = (horizontal ? shape.regions.bounds.maxY : shape.regions.bounds.maxX) - half
        var answer = CGRect.null
        // Each step crosses one whole indexed interval or region. It never tests candidates against every tile.
        for _ in 0...(intervals.count + shape.regions.exclusions.count) {
            guard center >= lower, center <= upper else { break }
            if let interval = Self.containing(center - translation, in: intervals) {
                center = (before ? interval.lower : interval.upper) + translation
                continue
            }
            let rect = CGRect(
                x: horizontal ? fixed - half : center - half,
                y: horizontal ? center - half : fixed - half, width: side, height: side)
            if let obstruction = shape.regions.exclusions.first(where: { $0.intersects(rect) }) {
                center =
                    horizontal
                    ? (before ? obstruction.minY - half : obstruction.maxY + half)
                    : (before ? obstruction.minX - half : obstruction.maxX + half)
                continue
            }
            if shape.regions.bounds.contains(rect) { answer = rect }
            break
        }
        candidates[key] = answer
        return answer.isNull ? nil : answer
    }

    private static func key(_ value: CGFloat) -> CGFloat { (value * 1_000_000).rounded() / 1_000_000 }

    private static func coordinates(_ values: [CGFloat], from lower: CGFloat, to upper: CGFloat) -> ArraySlice<CGFloat>
    {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < lower { low = mid + 1 } else { high = mid }
        }
        let start = low
        while low < values.count, values[low] < upper { low += 1 }
        return values[start..<low]
    }

    private static func merged(_ values: [Interval]) -> [Interval] {
        var result: [Interval] = []
        for value in values.sorted(by: { $0.lower < $1.lower }) {
            if let last = result.last, value.lower <= last.upper {
                result[result.count - 1].upper = max(last.upper, value.upper)
            } else {
                result.append(value)
            }
        }
        return result
    }

    private static func containing(_ point: CGFloat, in intervals: [Interval]) -> Interval? {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].upper <= point { low = mid + 1 } else { high = mid }
        }
        guard intervals.indices.contains(low), intervals[low].lower < point else { return nil }
        return intervals[low]
    }
}
