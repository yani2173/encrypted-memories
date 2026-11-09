import CoreGraphics

// MARK: - GridZoomTransaction
//
// A settled frame plan cannot drive live zoom directly. Re-resolving it can change the column count and rewrap
// flat indices, which moves the row under the cursor.
//
// The transaction is captured once at gesture start. It lays out nearby indices relative to the anchor,
// so the focus row remains contiguous while the gesture changes level.
//
// The settled target grid remains row-major. This type owns identity and position continuity until commit.
//
// The transaction supports one contiguous section. Multi-section engines return nil because a flat index fan-out
// would cross section boundaries incorrectly.

/// A renderable square slot in viewport coordinates - exactly what the Metal renderer draws. Produced both
/// by the settled `GridFramePlan` (mapped from `GridSlot.viewportRect`) and by the live `GridZoomTransaction`.
/// Deliberately distinct from the engine's `GridSlot`, whose `slotRect` is content-space: keeping a separate
/// type means viewport-space and content-space rects are never conflated under one name.
public struct GridRenderSlot: Equatable, Sendable {
    public let index: Int  // Global flat item index used for UID lookup.
    public let column: Int
    public let row: Int
    public let rect: CGRect  // viewport-space, always square

    public init(index: Int, column: Int, row: Int, rect: CGRect) {
        self.index = index
        self.column = column
        self.row = row
        self.rect = rect
    }
}

/// One live-zoom frame: the resolved metrics + the focus row (ordered global indices under the cursor) +
/// every visible render slot, placed in viewport coordinates relative to the anchor.
public struct GridZoomTransactionFrame: Equatable, Sendable {
    public let columns: Int
    public let slotSide: CGFloat
    public let gap: CGFloat
    public let pitch: CGFloat
    /// The anchor's column within the focus row.
    public let anchorColumn: Int
    /// Ordered global indices in the row under the cursor - contiguous, always contains the anchor.
    public let focusRow: [Int]
    /// Every visible render slot (focus row plus the rows above and below), viewport coordinates. `row` is relative to
    /// the anchor row (0 = focus row, negative = above).
    public let visibleSlots: [GridRenderSlot]
}

public struct GridZoomTransaction: Equatable, Sendable {
    public let totalItems: Int
    /// The anchor's identity: the item under the cursor at gesture start.
    public let anchorGlobalIndex: Int
    /// The gesture point in viewport coordinates.
    public let anchorViewportPoint: CGPoint
    /// The gesture's unit position inside the anchor slot; its vertical fraction stays pinned.
    public let anchorLocalFraction: CGPoint
    /// The density ladder (for apparent-metric interpolation across the gesture).
    public let levels: [GridLevelMetrics]
    /// The level the gesture started on (the snap-back / commit reference).
    public let sourceLevel: Int

    public init(
        totalItems: Int, anchorGlobalIndex: Int, anchorViewportPoint: CGPoint,
        anchorLocalFraction: CGPoint, levels: [GridLevelMetrics], sourceLevel: Int
    ) {
        self.totalItems = totalItems
        self.anchorGlobalIndex = anchorGlobalIndex
        self.anchorViewportPoint = anchorViewportPoint
        self.anchorLocalFraction = anchorLocalFraction
        precondition(!levels.isEmpty, "GridZoomTransaction requires at least one grid level")
        self.levels = levels
        self.sourceLevel = sourceLevel
    }

    /// The anchor-relative lattice at a continuous level: apparent metrics + the origin/anchor-column that pin
    /// the anchor cell under the cursor. Shared by `frame()` and `rect(forGlobalIndex:)` so they never drift.
    struct Lattice {
        let columns: Int, side: CGFloat, gap: CGFloat, pitch: CGFloat, anchorColumn: Int
        let gridOriginX: CGFloat, gridOriginY: CGFloat

        func origin(of column: Int) -> CGFloat {
            gridOriginX + CGFloat(column) * pitch
        }
    }

    func lattice(continuousLevel x: CGFloat, width rawWidth: CGFloat) -> Lattice {
        let width = max(rawWidth, 1)
        // Past the largest detent, scale the level-zero grid around the cursor while keeping its columns fixed.
        // Cell, gap, and pitch use the same scale factor. Column changes happen only when the gesture commits.
        if x < 0 {
            // At x == 0 this branch matches the settled level-zero geometry.
            let columns = levels[0].nominalColumns
            let baseSide = apparentSlotSide(at: 0, width: width)
            let baseGap = levels[0].gap
            let basePitch = baseSide + baseGap
            let f = apparentSlotSide(at: x, width: width) / max(baseSide, 0.001)  // > 1 past level 0 (grows)
            let side = baseSide * f
            let gap = baseGap * f
            let pitch = side + gap
            let anchorCellX = anchorViewportPoint.x - anchorLocalFraction.x * side
            let anchorCellY = anchorViewportPoint.y - anchorLocalFraction.y * side
            // Preserve the column from the unscaled surface. Resolving it from the enlarged pitch could move a
            // right-side anchor into the preceding column and expose a leading strip.
            let cA = min(max(Int((anchorViewportPoint.x / basePitch).rounded(.down)), 0), columns - 1)
            return Lattice(
                columns: columns, side: side, gap: gap, pitch: pitch, anchorColumn: cA,
                gridOriginX: anchorCellX - CGFloat(cA) * pitch, gridOriginY: anchorCellY)
        }
        let gap = apparentGap(at: x)
        let target = apparentSlotSide(at: x, width: width)
        // At an integer detent, use the level's nominal column count so the transaction and settled plan agree.
        // Between detents, derive the count from the apparent side.
        let columns: Int
        let nearestLevel = x.rounded()
        if abs(x - nearestLevel) < 1e-6, nearestLevel >= 0, Int(nearestLevel) < levels.count {
            let lv = Int(nearestLevel)
            columns = levels[lv].nominalColumns  // fixed columns: the detent holds its count
        } else {
            columns = SquareTileGridEngine.columnsForFixedSide(side: target, gap: gap, width: width)
        }
        let side = target  // equals the settled side at every detent
        let pitch = side + gap
        // Pin the anchor under the cursor: its cell's local point sits at `anchorViewportPoint`.
        let anchorCellX = anchorViewportPoint.x - anchorLocalFraction.x * side
        let anchorCellY = anchorViewportPoint.y - anchorLocalFraction.y * side
        // The anchor's column = the column the cursor is over; the lattice is shifted so the anchor cell
        // aligns there, so the focus row is centred on the cursor anchor rather than slot%cols.
        let cA = min(max(Int((anchorViewportPoint.x / pitch).rounded(.down)), 0), columns - 1)
        return Lattice(
            columns: columns, side: side, gap: gap, pitch: pitch, anchorColumn: cA,
            gridOriginX: anchorCellX - CGFloat(cA) * pitch, gridOriginY: anchorCellY)
    }

    /// The viewport rect of an arbitrary global index in the transaction lattice at `x` (nil if out of range).
    /// The lattice is infinite, so this is valid even for items currently off-screen - used by the commit
    /// bridge + the commit-delta measurement.
    public func rect(forGlobalIndex g: Int, continuousLevel x: CGFloat, viewportSize: CGSize) -> CGRect? {
        guard g >= 0, g < totalItems else { return nil }
        let l = lattice(continuousLevel: x, width: viewportSize.width)
        let m = (g - anchorGlobalIndex) + l.anchorColumn  // anchor sits at (row 0, col anchorColumn)
        let row = Int(floor(Double(m) / Double(l.columns)))
        let col = m - row * l.columns
        return CGRect(
            x: l.origin(of: col),
            y: l.gridOriginY + CGFloat(row) * l.pitch, width: l.side, height: l.side)
    }

    /// The live frame at a continuous level position (fractional = mid-pinch). Focus row preserved.
    public func frame(continuousLevel x: CGFloat, viewportSize: CGSize, overscan: CGFloat) -> GridZoomTransactionFrame {
        let l = lattice(continuousLevel: x, width: viewportSize.width)
        let columns = l.columns
        let side = l.side
        let gap = l.gap
        let pitch = l.pitch
        let cA = l.anchorColumn
        let gridOriginY = l.gridOriginY

        let firstRow = Int(((-overscan - gridOriginY) / pitch).rounded(.down))
        let lastRow = Int(((viewportSize.height + overscan - gridOriginY) / pitch).rounded(.up))

        var slots: [GridRenderSlot] = []
        var focusRow: [Int] = []
        guard firstRow <= lastRow else {
            return GridZoomTransactionFrame(
                columns: columns, slotSide: side, gap: gap, pitch: pitch,
                anchorColumn: cA, focusRow: [], visibleSlots: [])
        }
        slots.reserveCapacity((lastRow - firstRow + 1) * columns)
        focusRow.reserveCapacity(columns)
        for row in firstRow...lastRow {
            for col in 0..<columns {
                let delta = row * columns + col - cA  // offset from the anchor (anchor at row 0, col cA)
                let g = anchorGlobalIndex + delta
                guard g >= 0, g < totalItems else { continue }
                let cell = CGRect(
                    x: l.origin(of: col),
                    y: gridOriginY + CGFloat(row) * pitch, width: side, height: side)
                guard cell.maxY > -overscan, cell.minY < viewportSize.height + overscan,
                    cell.maxX > 0, cell.minX < viewportSize.width
                else { continue }
                slots.append(GridRenderSlot(index: g, column: col, row: row, rect: cell))
                if row == 0 { focusRow.append(g) }
            }
        }
        focusRow.sort()
        return GridZoomTransactionFrame(
            columns: columns, slotSide: side, gap: gap, pitch: pitch,
            anchorColumn: cA, focusRow: focusRow, visibleSlots: slots)
    }

    // Apparent metrics use the same interpolation as the settled engine.
    public func apparentSlotSide(at x: CGFloat, width: CGFloat) -> CGFloat {
        GridApparentMetrics.slotSide(at: x, width: width, levels: levels)
    }
    public func apparentGap(at x: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        if x <= 0 { return levels[0].gap }
        if x >= CGFloat(maxIndex) { return levels[maxIndex].gap }
        let lo = Int(x)
        return lerp(levels[lo].gap, levels[lo + 1].gap, smoothstep(x - CGFloat(lo)))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

public extension SquareTileGridEngine {
    /// Capture a live-zoom transaction anchored at the item under (or nearest to) the cursor. `cursorContentPoint`
    /// is the cursor in content space at the current `level`; `viewportPoint` is where to hold it (the cursor in
    /// viewport space). Returns nil for an empty library OR a multi-section engine (the transaction's flat
    /// single-run model is only valid for one section - see the file header; production uses one physical
    /// section by design, so it drives the transaction).
    func beginZoomTransaction(
        cursorContentPoint: CGPoint, viewportPoint: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil
    ) -> GridZoomTransaction? {
        guard sectionCounts.count <= 1 else { return nil }
        // Resolve the anchor in the currently displayed grid, including its committed phase. Otherwise a prior
        // phased zoom could make the content point resolve to a different item.
        guard
            let a = anchorItem(
                nearContentPoint: cursorContentPoint, level: level, width: width, columnPhase: columnPhase)
        else { return nil }
        return GridZoomTransaction(
            totalItems: totalItems, anchorGlobalIndex: a.flatIndex,
            anchorViewportPoint: viewportPoint, anchorLocalFraction: a.localFraction,
            levels: levels, sourceLevel: clampLevel(level))
    }
}
