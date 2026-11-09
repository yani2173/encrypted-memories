import CoreGraphics

// MARK: - Grid profile camera rebase
//
// A viewport profile change is not a renderer concern and not a platform concern. It rebuilds the same logical
// timeline with a different level ladder, then rebases the camera from a logical item anchor so dynamic scene
// changes do not reuse a stale scroll offset.

public enum GridProfileRebaseLevelMapping: Equatable, Sendable {
    /// Keep the same integer level ID, clamped to the target ladder.
    case preserveLevelID
    /// Use a specific target level, clamped to the target ladder.
    case explicit(Int)
    /// Choose the target level whose resolved slot side is closest to the source level at the old width.
    /// When possible, this only considers levels with the same semantic role (`monthLabels` on/off), so a
    /// normal photo level does not silently become an overview level, and vice versa.
    case closestVisualMatch
}

public struct GridProfileRebaseInput: Sendable {
    public let targetEngine: SquareTileGridEngine
    public let oldViewportFrame: CGRect
    public let newViewportFrame: CGRect
    public let oldScrollY: CGFloat
    public let sourceLevel: Int
    public let sourceCommittedPhase: Int?
    public let targetCommittedPhase: Int?
    public let wasBottomPinned: Bool
    public let anchorFractionY: CGFloat
    public let levelMapping: GridProfileRebaseLevelMapping

    public init(
        targetEngine: SquareTileGridEngine,
        oldViewportFrame: CGRect,
        newViewportFrame: CGRect,
        oldScrollY: CGFloat,
        sourceLevel: Int,
        sourceCommittedPhase: Int?,
        targetCommittedPhase: Int? = nil,
        wasBottomPinned: Bool,
        anchorFractionY: CGFloat = 0.5,
        levelMapping: GridProfileRebaseLevelMapping = .closestVisualMatch
    ) {
        self.targetEngine = targetEngine
        self.oldViewportFrame = oldViewportFrame
        self.newViewportFrame = newViewportFrame
        self.oldScrollY = oldScrollY
        self.sourceLevel = sourceLevel
        self.sourceCommittedPhase = sourceCommittedPhase
        self.targetCommittedPhase = targetCommittedPhase
        self.wasBottomPinned = wasBottomPinned
        self.anchorFractionY = anchorFractionY
        self.levelMapping = levelMapping
    }
}

public struct GridProfileRebaseResult: Sendable {
    public let newScrollY: CGFloat
    public let sourceLevel: Int
    public let targetLevel: Int
    public let targetCommittedPhase: Int?
    public let anchorGlobalIndex: Int?
    public let anchorFractionY: CGFloat
    public let bottomPinned: Bool
    public let clamped: Bool
    public let targetContentSize: CGSize
    public let anchorLocalFractionY: CGFloat?

    public init(
        newScrollY: CGFloat,
        sourceLevel: Int,
        targetLevel: Int,
        targetCommittedPhase: Int?,
        anchorGlobalIndex: Int?,
        anchorFractionY: CGFloat,
        bottomPinned: Bool,
        clamped: Bool,
        targetContentSize: CGSize,
        anchorLocalFractionY: CGFloat?
    ) {
        self.newScrollY = newScrollY
        self.sourceLevel = sourceLevel
        self.targetLevel = targetLevel
        self.targetCommittedPhase = targetCommittedPhase
        self.anchorGlobalIndex = anchorGlobalIndex
        self.anchorFractionY = anchorFractionY
        self.bottomPinned = bottomPinned
        self.clamped = clamped
        self.targetContentSize = targetContentSize
        self.anchorLocalFractionY = anchorLocalFractionY
    }
}

public extension SquareTileGridEngine {
    /// Rebase the camera when the adapter switches viewport profiles for the same logical timeline data.
    ///
    /// Resolve the target level, preserve a bottom pin when present, or move the source item at the
    /// normalized viewport anchor into the target engine. Clamp the resulting offset only at the end.
    ///
    /// The engines must describe the same section structure. A data change and a profile change are separate
    /// state transitions; combining them would make the anchor identity ambiguous.
    func rebasedScrollOffsetForProfileChange(_ input: GridProfileRebaseInput) -> GridProfileRebaseResult {
        precondition(
            sectionCounts == input.targetEngine.sectionCounts,
            "Grid profile rebase requires matching source and target section structures")

        let sourceLevel = clampLevel(input.sourceLevel)
        let targetLevel = targetLevel(
            for: input.levelMapping,
            sourceLevel: sourceLevel,
            sourceWidth: max(input.oldViewportFrame.width, 1),
            targetEngine: input.targetEngine,
            targetWidth: max(input.newViewportFrame.width, 1))
        let sourcePhase = input.sourceCommittedPhase
        let targetPhase = input.targetCommittedPhase
        let f = min(max(input.anchorFractionY, 0), 1)
        let oldW = max(input.oldViewportFrame.width, 1)
        let oldVH = max(input.oldViewportFrame.height, 0)
        let newW = max(input.newViewportFrame.width, 1)
        let newVH = max(input.newViewportFrame.height, 0)
        let targetContent = input.targetEngine.contentSize(level: targetLevel, width: newW, columnPhase: targetPhase)
        let maxY = max(0, targetContent.height - newVH)

        func make(_ rawY: CGFloat, anchor: Int?, localY: CGFloat?, pinned: Bool) -> GridProfileRebaseResult {
            let clampedY = min(max(0, rawY), maxY)
            return GridProfileRebaseResult(
                newScrollY: clampedY,
                sourceLevel: sourceLevel,
                targetLevel: targetLevel,
                targetCommittedPhase: targetPhase,
                anchorGlobalIndex: anchor,
                anchorFractionY: f,
                bottomPinned: pinned,
                clamped: abs(clampedY - rawY) > 0.5,
                targetContentSize: targetContent,
                anchorLocalFractionY: localY
            )
        }

        if input.wasBottomPinned { return make(maxY, anchor: nil, localY: nil, pinned: true) }

        let oldAnchorContentY = input.oldScrollY + oldVH * f
        guard totalItems > 0,
            input.targetEngine.totalItems > 0,
            let anchor = anchorItem(
                nearContentPoint: CGPoint(x: oldW / 2, y: oldAnchorContentY),
                level: sourceLevel,
                width: oldW,
                columnPhase: sourcePhase),
            let targetSlot = input.targetEngine.slotRect(
                flatIndex: anchor.flatIndex,
                level: targetLevel,
                width: newW,
                columnPhase: targetPhase)
        else {
            return make(input.oldScrollY, anchor: nil, localY: nil, pinned: false)
        }

        let localY = anchor.localFraction.y
        let targetAnchorContentY = targetSlot.minY + localY * targetSlot.height
        return make(targetAnchorContentY - newVH * f, anchor: anchor.flatIndex, localY: localY, pinned: false)
    }

    private func targetLevel(
        for mapping: GridProfileRebaseLevelMapping,
        sourceLevel: Int,
        sourceWidth: CGFloat,
        targetEngine: SquareTileGridEngine,
        targetWidth: CGFloat
    ) -> Int {
        switch mapping {
        case .preserveLevelID:
            return targetEngine.clampLevel(sourceLevel)
        case .explicit(let level):
            return targetEngine.clampLevel(level)
        case .closestVisualMatch:
            return closestVisualLevel(
                sourceLevel: sourceLevel,
                sourceWidth: sourceWidth,
                in: targetEngine,
                targetWidth: targetWidth
            )
        }
    }

    /// Maps a density level between viewport profiles while preserving the apparent tile size.
    func closestVisualLevel(
        sourceLevel: Int,
        sourceWidth: CGFloat,
        in targetEngine: SquareTileGridEngine,
        targetWidth: CGFloat
    ) -> Int {
        let sourceMetrics = metrics(level: sourceLevel)
        let sourceSide = resolvedMetrics(level: sourceLevel, width: sourceWidth).slotSide
        let roleMatched = (0..<targetEngine.levelCount).filter {
            targetEngine.metrics(level: $0).monthLabels == sourceMetrics.monthLabels
        }
        let candidates = roleMatched.isEmpty ? Array(0..<targetEngine.levelCount) : roleMatched
        return candidates.min { lhs, rhs in
            let lDelta = abs(targetEngine.resolvedMetrics(level: lhs, width: targetWidth).slotSide - sourceSide)
            let rDelta = abs(targetEngine.resolvedMetrics(level: rhs, width: targetWidth).slotSide - sourceSide)
            if abs(lDelta - rDelta) > 0.5 { return lDelta < rDelta }
            return abs(lhs - sourceLevel) < abs(rhs - sourceLevel)
        } ?? targetEngine.defaultLevel
    }
}
