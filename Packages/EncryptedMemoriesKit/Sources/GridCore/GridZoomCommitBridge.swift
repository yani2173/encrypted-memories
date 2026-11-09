import CoreGraphics

// MARK: - Zoom anchor mode / trigger

/// Where a zoom is anchored. A trackpad pinch anchors at the cursor; toolbar +/- anchors at the
/// center of the grid viewport, never at a toolbar button location, stale hover point, or viewport top.
public enum GridZoomAnchorMode: String, Sendable {
    case cursor
    case viewportCenter
}

public enum GridZoomTrigger: String, Sendable {
    case pinch
    case toolbarPlus
    case toolbarMinus

    public var anchorMode: GridZoomAnchorMode {
        self == .pinch ? .cursor : .viewportCenter
    }
}

// MARK: - Commit bridge

/// The release bridge from the `GridZoomTransaction` final frame to the settled `GridFramePlan`.
///
/// This is geometry-only Core logic: visible items are matched by global index, never by screen position, and
/// their viewport rects ease from transaction-final positions to settled positions. It owns no renderer,
/// texture, photo, diagnostics, or platform-view state.
public enum GridZoomCommitBridge {
    /// Bridge duration in seconds. Bounded to 120-180 ms; 160 ms default.
    public static let duration: CFTimeInterval = 0.16

    /// easeOutCubic, monotonic on [0, 1], with no overshoot.
    public static func easedProgress(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        let inverse = 1 - c
        return 1 - inverse * inverse * inverse
    }

    /// The bridge may smooth only a small sub-cell residual. Above this, the coordinator must settle
    /// immediately because the phase/anchor model is wrong.
    public static func tolerance(targetPitch: CGFloat) -> CGFloat {
        max(24, 0.25 * targetPitch)
    }

    /// The maximum horizontal center movement any matched global index would undergo from the transaction-final
    /// frame to the settled phased plan. With the cursor-aligned phase this is a uniform sub-cell residual;
    /// without a compatible phase it is a multi-column distance.
    public static func maxMatchedIndexMoveX(
        transaction tx: GridZoomTransaction,
        engine: SquareTileGridEngine,
        targetLevel: Int,
        viewportSize: CGSize,
        scrollY: CGFloat,
        overscan: CGFloat,
        columnPhase: Int? = nil
    ) -> CGFloat {
        let lv = engine.clampLevel(targetLevel)
        let settled = engine.framePlan(
            level: lv,
            viewportSize: viewportSize,
            scrollOffset: CGPoint(x: 0, y: scrollY),
            overscan: overscan,
            columnPhase: columnPhase
        )
        let fromFrame = tx.frame(continuousLevel: CGFloat(lv), viewportSize: viewportSize, overscan: overscan)
        var fromMid: [Int: CGFloat] = [:]
        for slot in fromFrame.visibleSlots {
            fromMid[slot.index] = slot.rect.midX
        }

        var maxMove: CGFloat = 0
        for slot in settled.visibleSlots {
            if let midX = fromMid[slot.index] {
                maxMove = max(maxMove, abs(slot.viewportRect.midX - midX))
            }
        }
        return maxMove
    }

    /// The bridge's render slots at linear progress `t` (0 to 1). Each visible global index's viewport rect is
    /// eased from its transaction-final rect to its settled rect, matched strictly by global index. Items visible
    /// in only one endpoint use the other lattice's analytic position so they slide in/out instead of popping.
    ///
    /// Hard guarantee: if any matched index would move more than one column, the bridge snaps straight to the
    /// settled frame, so a thumbnail can never be displayed flying across columns.
    public static func frame(
        transaction tx: GridZoomTransaction,
        engine: SquareTileGridEngine,
        targetLevel: Int,
        viewportSize: CGSize,
        scrollY: CGFloat,
        overscan: CGFloat,
        progress t: CGFloat,
        columnPhase: Int? = nil
    ) -> [GridRenderSlot] {
        let lv = engine.clampLevel(targetLevel)
        let scrollOffset = CGPoint(x: 0, y: scrollY)
        let settled = engine.framePlan(
            level: lv,
            viewportSize: viewportSize,
            scrollOffset: scrollOffset,
            overscan: overscan,
            columnPhase: columnPhase
        )
        let fromFrame = tx.frame(continuousLevel: CGFloat(lv), viewportSize: viewportSize, overscan: overscan)

        var toRect: [Int: CGRect] = [:]
        var rowCol: [Int: (row: Int, col: Int)] = [:]
        for slot in settled.visibleSlots {
            toRect[slot.index] = slot.viewportRect
            rowCol[slot.index] = (slot.row, slot.column)
        }

        var fromRect: [Int: CGRect] = [:]
        for slot in fromFrame.visibleSlots {
            fromRect[slot.index] = slot.rect
            if rowCol[slot.index] == nil {
                rowCol[slot.index] = (slot.row, slot.column)
            }
        }

        let pitch = settled.slotSide + settled.gap
        var maxMatchedMove: CGFloat = 0
        for (index, from) in fromRect {
            if let to = toRect[index] {
                maxMatchedMove = max(maxMatchedMove, abs(to.midX - from.midX))
            }
        }
        let progress = maxMatchedMove > pitch ? 1 : easedProgress(t)

        let width = viewportSize.width
        var slots: [GridRenderSlot] = []
        let bridgedIndices = Set(toRect.keys).union(fromRect.keys).sorted()
        slots.reserveCapacity(bridgedIndices.count)
        for index in bridgedIndices {
            let from =
                fromRect[index]
                ?? tx.rect(
                    forGlobalIndex: index,
                    continuousLevel: CGFloat(lv),
                    viewportSize: viewportSize
                )
            let to =
                toRect[index]
                ?? engine.slotRect(
                    flatIndex: index,
                    level: lv,
                    width: width,
                    columnPhase: columnPhase
                ).map {
                    CGRect(
                        x: $0.minX - scrollOffset.x,
                        y: $0.minY - scrollOffset.y,
                        width: $0.width,
                        height: $0.height
                    )
                }
            guard let from, let to else { continue }

            let rect = CGRect(
                x: from.minX + (to.minX - from.minX) * progress,
                y: from.minY + (to.minY - from.minY) * progress,
                width: from.width + (to.width - from.width) * progress,
                height: from.height + (to.height - from.height) * progress
            )
            let rc = rowCol[index] ?? (0, 0)
            slots.append(GridRenderSlot(index: index, column: rc.col, row: rc.row, rect: rect))
        }
        return slots
    }
}

// MARK: - Commit seam measurement

/// What moves at the transaction-final to settled-plan commit, with the scroll offset rebased from the anchor.
public struct GridZoomCommitDelta: Equatable, Sendable {
    /// Settled anchor viewport origin minus transaction anchor viewport origin.
    public let anchorDelta: CGSize
    public let transactionAnchorRect: CGRect
    public let settledAnchorRect: CGRect
    /// The scroll Y the commit rebases to from the anchor item and local fraction at the target metrics.
    public let settledScrollOffsetY: CGFloat
    public let transactionFocusRow: [Int]
    public let settledFocusRow: [Int]
    /// Intersection over transaction focus-row count. Equal to 1 if the transaction row is empty.
    public let focusRowOverlap: Double
    /// Visible intersection over visible union across the whole local neighborhood.
    public let neighborhoodOverlap: Double

    /// Horizontal shift in whole columns, rounded; this is the dominant component of the phase seam.
    public func anchorColumnShift(pitch: CGFloat) -> Int {
        pitch > 0 ? Int((anchorDelta.width / pitch).rounded()) : 0
    }
}

public extension SquareTileGridEngine {
    /// Measure the commit seam: the transaction's final frame at `targetLevel` versus the settled
    /// `GridFramePlan` after the scroll offset is rebased from the anchor.
    func commitDelta(
        transaction tx: GridZoomTransaction,
        targetLevel: Int,
        viewportSize: CGSize,
        columnPhase: Int? = nil
    ) -> GridZoomCommitDelta {
        let width = viewportSize.width
        let lv = clampLevel(targetLevel)
        let txFrame = tx.frame(continuousLevel: CGFloat(lv), viewportSize: viewportSize, overscan: 0)
        let scrollY = anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex,
            localFraction: tx.anchorLocalFraction,
            viewportPoint: tx.anchorViewportPoint,
            level: lv,
            width: width,
            columnPhase: columnPhase
        ).y
        let plan = framePlan(
            level: lv,
            viewportSize: viewportSize,
            scrollOffset: CGPoint(x: 0, y: scrollY),
            overscan: 0,
            columnPhase: columnPhase
        )

        let txAnchorRect =
            txFrame.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.rect
            ?? tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: CGFloat(lv), viewportSize: viewportSize)
            ?? .zero
        let settledAnchorRect = plan.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.viewportRect ?? .zero
        let anchorDelta = CGSize(
            width: settledAnchorRect.minX - txAnchorRect.minX,
            height: settledAnchorRect.minY - txAnchorRect.minY
        )

        let txFocus = txFrame.focusRow
        let anchorRow = plan.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.row
        let settledFocus = plan.visibleSlots.filter { $0.row == anchorRow }.map(\.index).sorted()
        let focusIntersection = Set(txFocus).intersection(settledFocus).count
        let focusRowOverlap = txFocus.isEmpty ? 1 : Double(focusIntersection) / Double(txFocus.count)

        let txVisible = Set(txFrame.visibleSlots.map(\.index))
        let settledVisible = Set(plan.visibleSlots.map(\.index))
        let union = txVisible.union(settledVisible).count
        let neighborhoodOverlap = union == 0 ? 1 : Double(txVisible.intersection(settledVisible).count) / Double(union)

        return GridZoomCommitDelta(
            anchorDelta: anchorDelta,
            transactionAnchorRect: txAnchorRect,
            settledAnchorRect: settledAnchorRect,
            settledScrollOffsetY: scrollY,
            transactionFocusRow: txFocus,
            settledFocusRow: settledFocus,
            focusRowOverlap: focusRowOverlap,
            neighborhoodOverlap: neighborhoodOverlap
        )
    }
}
