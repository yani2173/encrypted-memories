import CoreGraphics

/// The presentation frame of one pinch detent: the column phase and the vertical scroll offset the detent draws with.
public struct GridPinchDetentFrame: Equatable, Sendable {
    public let phase: Int?
    public let scrollY: CGFloat

    public init(phase: Int?, scrollY: CGFloat) {
        self.phase = phase
        self.scrollY = scrollY
    }
}

/// The geometry of a pinch detent that both platform hosts share.
public enum GridPinchDetentGeometry {
    /// The cursor-aligned frame of `level` for the gesture that `transaction` anchors: the column phase puts the
    /// anchor item under the cursor column, and the clamped scroll offset keeps its local point under the cursor.
    /// `width` and `viewportHeight` are the layout size the engine plans in. The result depends on the anchor, the
    /// detent and that size only, so two adjacent pinch segments that share a cursor-aligned detent get the
    /// identical frame for it. The gesture-start detent keeps the frame that its host captured.
    public static func cursorAlignedFrame(
        level: Int,
        transaction: GridZoomTransaction,
        engine: SquareTileGridEngine,
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> GridPinchDetentFrame {
        let column = engine.cursorColumn(viewportX: transaction.anchorViewportPoint.x, level: level, width: width)
        let phase = engine.columnPhase(
            forItem: transaction.anchorGlobalIndex, targetColumn: column, level: level, width: width)
        let anchoredY = engine.anchoredScrollOffset(
            flatIndex: transaction.anchorGlobalIndex, localFraction: transaction.anchorLocalFraction,
            viewportPoint: transaction.anchorViewportPoint, level: level, width: width, columnPhase: phase
        ).y
        let scrollY = engine.clampScrollOffsetY(
            anchoredY, level: level, width: width, viewportHeight: viewportHeight, columnPhase: phase)
        return GridPinchDetentFrame(phase: phase, scrollY: scrollY)
    }
}
