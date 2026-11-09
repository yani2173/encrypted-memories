import CoreGraphics

package enum GridApparentMetrics {
    package static func slotSide(at x: CGFloat, width: CGFloat, levels: [GridLevelMetrics]) -> CGFloat {
        func side(_ i: Int) -> CGFloat {
            GridColumnGeometry(columns: levels[i].nominalColumns, gap: levels[i].gap, width: width).side
        }
        let last = levels.count - 1
        if x <= 0 { return side(0) * (1 - x * 0.6) }
        if x >= CGFloat(last) { return side(last) }
        let lo = Int(x)
        let t = x - CGFloat(lo)
        return side(lo) + (side(lo + 1) - side(lo)) * t * t * (3 - 2 * t)
    }
}

/// One horizontal mapping for slot placement, queries and zoom.
package struct GridColumnGeometry: Equatable, Sendable {
    package let columns: Int
    package let side: CGFloat
    package let gap: CGFloat

    package var pitch: CGFloat { side + gap }

    package init(columns: Int, gap: CGFloat, width: CGFloat) {
        self.columns = max(1, columns)
        self.gap = max(0, gap)
        side = SquareTileGridEngine.nominalSlotSide(columns: columns, gap: gap, width: width)
    }

    package func origin(of column: Int) -> CGFloat {
        CGFloat(column) * pitch
    }

    package func column(at x: CGFloat) -> Int {
        guard pitch > 0, pitch.isFinite, x.isFinite else { return 0 }
        return min(max(Int(x / pitch), 0), columns - 1)
    }
}
