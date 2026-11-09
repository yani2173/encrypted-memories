import CoreGraphics

/// Shared row facts keep fold timing independent of each thumbnail's fitted height.
public struct GridSelectionBadgeRow: Equatable, Sendable {
    public var frame: CGRect
    public var normalMarks: CGRect
    public var usesAlternate: Bool?
    public var band: CGRect?
    public var hasFittingMarks: Bool

    public init(
        frame: CGRect, normalMarks: CGRect, usesAlternate: Bool? = nil, band: CGRect? = nil,
        hasFittingMarks: Bool = true
    ) {
        self.frame = frame
        self.normalMarks = normalMarks
        self.usesAlternate = usesAlternate
        self.band = band
        self.hasFittingMarks = hasFittingMarks
    }
}

/// A badge's slot decision and clock. The host supplies geometry, time and the motion preference.
public struct GridSelectionBadgeMotion {
    public static let duration = 0.20
    public static let switchShare: CGFloat = 0.40

    public init() {}

    public private(set) var isAnimating = false
    public private(set) var target: CGRect = .zero
    public private(set) var usesAlternate = false

    private var previousTile: CGRect?
    private var band: CGRect?
    private var decision = GridSelectionBadgeDecision()
    private var source: CGRect = .zero
    private var startedAt: Double = 0
    private var exterior = false
    private var wasTabletop = false

    public mutating func frame(
        tile: CGRect, side: CGFloat, inset: CGFloat, regions: ReservedRegionLayout,
        avoiding occupied: [CGRect] = [], neighboringTiles: [CGRect] = [], row: GridSelectionBadgeRow? = nil,
        layout: GridSelectionBadgeLayout? = nil, now: Double, reduceMotion: Bool
    ) -> CGRect {
        let tabletop = regions.horizontalFold != nil
        // Zoom and posture changes own geometry. Do not carry a tabletop slide into an unchanged no-fold path.
        if target.isNull || previousTile.map({ $0.size != tile.size }) == true
            || (previousTile != nil && wasTabletop != tabletop)
        {
            self = GridSelectionBadgeMotion()
        }
        wasTabletop = tabletop
        let inset = ReservedRegionLayout.selectionMarkInset(in: tile, side: side, preferred: inset)
        let home = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
        let oldTile = previousTile
        let delta = oldTile.map { CGPoint(x: tile.minX - $0.minX, y: tile.minY - $0.minY) } ?? .zero
        // The row follows scrolling. Its intrinsic slide uses the same clock and local endpoints.
        if oldTile != nil && !exterior {
            source = source.offsetBy(dx: delta.x, dy: delta.y)
            target = target.offsetBy(dx: delta.x, dy: delta.y)
        }
        if tabletop {
            source.origin.x = home.minX
            target.origin.x = home.minX
        }
        // Finish the old clock before validating its slot; otherwise a covered target can stop the render pump.
        if isAnimating && now - startedAt >= Self.duration { isAnimating = false }
        let shown = presentation(now: now)
        let wasAlternate = usesAlternate
        if let shared = row?.usesAlternate {
            usesAlternate = shared || (!tabletop && !regions.isClear(home))
            band = row?.band
        } else {
            decision.update(
                tile: tile, home: home, regions: regions, delta: delta, canAvoidBand: tile.height >= side + 2 * inset)
            usesAlternate = decision.usesAlternate
            band = decision.band
        }
        var desired = home
        if tabletop {
            desired = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset, top: !usesAlternate)
        } else if usesAlternate {
            let availableInside =
                exterior
                ? regions.inTileSelectionMarkRect(in: tile, side: side, inset: inset, avoiding: occupied) : nil
            let fitsInside = availableInside.map { tile.contains($0) && regions.isClear($0) } ?? false
            let neighborsStayClear =
                !exterior
                || (layout?.clearsTileCenters(target)
                    ?? neighboringTiles.allSatisfy { ReservedRegionLayout.markIsAtEdge(target, of: $0) })
            var preferredSide = true
            if exterior, let band {
                let horizontal = band.width >= band.height
                let center = horizontal ? tile.midY : tile.midX
                let midpoint = horizontal ? band.midY : band.midX
                let margin = max(4, (horizontal ? tile.height : tile.width) * 0.10)
                let before = horizontal ? target.maxY <= band.minY : target.maxX <= band.minX
                preferredSide = before ? center <= midpoint + margin : center >= midpoint - margin
            }
            // A clear in-tile slot replaces the exception. A held exception must still clear its moving neighbours.
            let held =
                oldTile != nil && wasAlternate && wasAlternate == usesAlternate
                && regions.isClear(target) && regions.bounds.contains(target)
                && ReservedRegionLayout.markIsAtEdge(target, of: tile)
                && (exterior || tile.contains(target)) && neighborsStayClear && preferredSide && !fitsInside
            desired =
                held
                ? target
                : (fitsInside
                    ? availableInside!
                    : regions.selectionMarkRect(
                        in: tile, side: side, inset: inset, avoiding: occupied,
                        neighboringTiles: neighboringTiles, prefersAlternate: true, layout: layout))
        }
        // There is nothing drawable when every usable point is excluded.
        if desired.isNull {
            target = .null
            source = .null
            previousTile = tile
            isAnimating = false
            return .null
        }
        let changed =
            oldTile == nil || wasAlternate != usesAlternate
            || (!isAnimating && desired != target)
            || (!regions.isClear(target) && !isAnimating)
        if oldTile == nil || reduceMotion {
            source = desired
            target = desired
            isAnimating = false
        } else if changed {
            source = shown
            target = desired
            startedAt = now
            isAnimating = source != target
        }
        // A new decision interrupts from the current presentation, not from the previous slot.
        exterior = !tabletop && usesAlternate && !tile.contains(target)
        previousTile = tile
        let result = presentation(now: now)
        return CGRect(origin: result.origin, size: CGSize(width: side, height: side))
    }

    private func presentation(now: Double) -> CGRect {
        guard isAnimating else { return target }
        let t = CGFloat(min(1, max(0, (now - startedAt) / Self.duration)))
        let eased = t * t * (3 - 2 * t)
        return CGRect(
            x: source.minX + (target.minX - source.minX) * eased,
            y: source.minY + (target.minY - source.minY) * eased,
            width: target.width, height: target.height)
    }
}

/// One switch rule, reused for a whole horizontal row or for an isolated tile/occlusion.
struct GridSelectionBadgeDecision {
    private(set) var usesAlternate = false
    private(set) var band: CGRect?
    private var entersBefore = true
    private var triggerShare = GridSelectionBadgeMotion.switchShare

    mutating func update(
        tile: CGRect, home: CGRect, regions: ReservedRegionLayout, delta: CGPoint, canAvoidBand: Bool = true
    ) {
        if let fold = regions.horizontalFold {
            if band != fold {
                band = fold
                usesAlternate = tile.midY >= fold.midY
                entersBefore = !usesAlternate
            }
            if tile.maxY < fold.minY { entersBefore = true }
            if tile.minY > fold.maxY { entersBefore = false }
            let extent = tile.height
            let entry = entersBefore ? fold.minY - extent : fold.maxY
            let direction: CGFloat = entersBefore ? 1 : -1
            let preferredLine = entry + direction * extent * GridSelectionBadgeMotion.switchShare
            // Reflect the row's exact bottom-mark envelope into its top-mark envelope.
            let top = home.offsetBy(dx: 0, dy: tile.minY + tile.maxY - home.minY - home.maxY)
            let upperClearThrough = fold.minY - (top.maxY - tile.minY)
            let lowerClearFrom = fold.maxY - (home.minY - tile.minY)
            let commonRange = upperClearThrough - lowerClearFrom
            let safeZone = max(4, canAvoidBand ? min(extent * 0.10, commonRange) : extent * 0.10)
            let switchLine: CGFloat
            if !canAvoidBand {
                switchLine = preferredLine
            } else if abs(commonRange) >= safeZone {
                let lower = min(lowerClearFrom, upperClearThrough) + (entersBefore ? safeZone : 0)
                let upper = max(lowerClearFrom, upperClearThrough) - (entersBefore ? 0 : safeZone)
                switchLine = min(upper, max(lower, preferredLine))
            } else {
                // Borderline sizes give clearance priority; when neither corner fits, retain ECKEN.
                switchLine = min(
                    max(upperClearThrough, lowerClearFrom), max(min(upperClearThrough, lowerClearFrom), preferredLine))
            }
            let releaseLine = switchLine - direction * safeZone
            let crossed = entersBefore ? tile.minY >= switchLine : tile.minY <= switchLine
            let released = entersBefore ? tile.minY < releaseLine : tile.minY > releaseLine
            if crossed { usesAlternate = entersBefore }
            if released { usesAlternate = !entersBefore }
            if canAvoidBand, fold.intersects(home), !fold.intersects(top) { usesAlternate = false }
            if canAvoidBand, fold.intersects(top), !fold.intersects(home) { usesAlternate = true }
            return
        }
        let active = regions.exclusions.first {
            regions.isCrossingBand($0) && ($0.intersects(tile) || $0.intersects(home))
        }
        if let band,
            !regions.exclusions.contains(band)
                || (!usesAlternate && !band.intersects(tile) && !band.intersects(home))
        {
            self.band = nil
            usesAlternate = false
        }
        if band == nil, let active {
            band = active
            let horizontal = active.width >= active.height
            let movement = horizontal ? delta.y : delta.x
            entersBefore =
                movement == 0
                ? (horizontal ? tile.midY < active.midY : tile.midX < active.midX)
                : movement > 0
        }
        if let current = band, regions.exclusions.contains(current) {
            let horizontal = current.width >= current.height
            let rowFrame = tile
            let normalMarks = home
            let extent = horizontal ? rowFrame.height : rowFrame.width
            let start = horizontal ? rowFrame.minY : rowFrame.minX
            let entry =
                entersBefore
                ? (horizontal ? current.minY : current.minX) - extent
                : (horizontal ? current.maxY : current.maxX)
            let direction: CGFloat = entersBefore ? 1 : -1
            let switchLine = entry + direction * extent * GridSelectionBadgeMotion.switchShare
            let crossedSwitch = entersBefore ? start >= switchLine : start <= switchLine
            let safeShare = max(0.10, 4 / extent)
            let rowIsClear = !current.intersects(normalMarks)
            if !usesAlternate
                && (crossedSwitch || !rowIsClear || !regions.isClear(home))
            {
                usesAlternate = true
                let normalEntry =
                    entersBefore
                    ? (horizontal ? rowFrame.maxY - normalMarks.maxY : rowFrame.maxX - normalMarks.maxX) / extent
                    : (horizontal ? normalMarks.minY - rowFrame.minY : normalMarks.minX - rowFrame.minX) / extent
                triggerShare = min(GridSelectionBadgeMotion.switchShare, normalEntry)
            } else if usesAlternate {
                let passed =
                    entersBefore
                    ? (horizontal ? rowFrame.minY > current.maxY : rowFrame.minX > current.maxX)
                    : (horizontal ? rowFrame.maxY < current.minY : rowFrame.maxX < current.minX)
                let releaseLine = entry + direction * extent * (triggerShare - safeShare)
                let crossedRelease = entersBefore ? start < releaseLine : start > releaseLine
                if rowIsClear, regions.isClear(home), crossedRelease || passed {
                    usesAlternate = false
                    if passed { band = nil }
                }
            }
        } else {
            usesAlternate = !regions.isClear(home)
            band = active
        }
    }
}
