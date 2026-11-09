import CoreGraphics
import GridCore
import PhotosCore

// MARK: - Zoom anchor-identity diagnostics
//
// `[GridZoomAnchor]` records the item under the gesture anchor at each stage.
@MainActor
enum GridZoomAnchorLog {
    static func begin(
        trigger: GridZoomTrigger, cursorViewportPoint: CGPoint, cursorContentPoint: CGPoint,
        hoveredIndexAtBegin: Int?, transactionAnchorIndex: Int?, level: Int
    ) {
        PhotoDiagnostics.shared.emit(
            "GridZoomAnchor",
            [
                "phase": "begin", "trigger": trigger.rawValue, "anchorMode": trigger.anchorMode.rawValue,
                "cursorViewportPoint": pt(cursorViewportPoint), "cursorContentPoint": pt(cursorContentPoint),
                "hoveredIndexAtBegin": idx(hoveredIndexAtBegin), "transactionAnchorIndex": idx(transactionAnchorIndex),
                "level": "\(level)",
            ])
    }

    static func release(
        targetLevel: Int, cursorViewportPoint: CGPoint, indexUnderCursorBeforeCommit: Int?,
        transactionAnchorIndex: Int, committedPhase: Int, targetScrollY: CGFloat, bridgeWillRun: Bool
    ) {
        PhotoDiagnostics.shared.emit(
            "GridZoomAnchor",
            [
                "phase": "release", "targetLevel": "\(targetLevel)", "cursorViewportPoint": pt(cursorViewportPoint),
                "indexUnderCursorBeforeCommit": idx(indexUnderCursorBeforeCommit),
                "transactionAnchorIndex": "\(transactionAnchorIndex)", "committedPhase": "\(committedPhase)",
                "targetScrollY": "\(Int(targetScrollY))", "bridgeWillRun": "\(bridgeWillRun)",
            ])
    }

    static func postCommit(
        cursorViewportPoint: CGPoint, indexUnderCursorAfterCommit: Int?,
        transactionAnchorIndex: Int, scrollY: CGFloat, phase: Int?
    ) {
        PhotoDiagnostics.shared.emit(
            "GridZoomAnchor",
            [
                "phase": "postCommit", "cursorViewportPoint": pt(cursorViewportPoint),
                "indexUnderCursorAfterCommit": idx(indexUnderCursorAfterCommit),
                "transactionAnchorIndex": "\(transactionAnchorIndex)",
                "anchorStillUnderCursor": "\(indexUnderCursorAfterCommit == transactionAnchorIndex)",
                "scrollY": "\(Int(scrollY))", "committedPhase": phase.map { "\($0)" } ?? "canonical",
            ])
    }

    private static func pt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
    private static func idx(_ i: Int?) -> String { i.map { "\($0)" } ?? "nil" }
}

// MARK: - Level-binding sync diagnostics
//
// `[GridLevelSync]` records external re-drives and suppressed stale post-commit binding echoes.
@MainActor
enum GridLevelSyncLog {
    static func decision(binding: Int, hostLevel: Int, staleEcho: Int?, action: String) {
        PhotoDiagnostics.shared.emit(
            "GridLevelSync",
            [
                "binding": "\(binding)", "hostLevel": "\(hostLevel)",
                "pendingEcho": staleEcho.map { "\($0)" } ?? "nil", "action": action,
            ])
    }
}

// MARK: - Viewport-resize diagnostics
//
// `[GridResize]` records the resize/sidebar rebase and its visible overlap validation.
@MainActor
enum GridResizeLog {
    static func begin(
        reason: String, oldFrame: CGRect, newFrame: CGRect, delta: GridViewportResizeDelta,
        level: Int, phase: Int?, wasBottomPinned: Bool, result: GridViewportResizeResult,
        anchorViewportY: CGFloat, oldScrollY: CGFloat, oldContentSize: CGSize
    ) {
        PhotoDiagnostics.shared.emit(
            "GridResize",
            [
                "phase": "begin", "reason": reason, "oldViewportFrame": rc(oldFrame), "newViewportFrame": rc(newFrame),
                "widthChanged": "\(delta.widthChanged)", "heightChanged": "\(delta.heightChanged)",
                "movedTopEdge": "\(delta.movedTopEdge)", "movedBottomEdge": "\(delta.movedBottomEdge)",
                "movedLeftEdge": "\(delta.movedLeftEdge)", "movedRightEdge": "\(delta.movedRightEdge)",
                "level": "\(level)", "committedPhase": phase.map { "\($0)" } ?? "canonical",
                "wasBottomPinned": "\(wasBottomPinned)",
                "anchorFractionY": String(format: "%.2f", result.anchorFractionY),
                "anchorGlobalIndex": result.anchorGlobalIndex.map { "\($0)" } ?? "nil",
                "anchorViewportY": "\(Int(anchorViewportY))",
                "anchorLocalFractionY": result.anchorLocalFractionY.map { String(format: "%.3f", $0) } ?? "nil",
                "oldScrollY": "\(Int(oldScrollY))", "oldContentSize": sz(oldContentSize),
            ])
    }
    static func end(result: GridViewportResizeResult, anchorViewportYAfter: CGFloat) {
        PhotoDiagnostics.shared.emit(
            "GridResize",
            [
                "phase": "end", "newContentSize": sz(result.newContentSize), "newScrollY": "\(Int(result.newScrollY))",
                "anchorViewportYAfter": "\(Int(anchorViewportYAfter))",
                "bottomPinned": "\(result.bottomPinned)", "clamped": "\(result.clamped)",
            ])
    }
    static func validation(
        visibleBefore: Int, visibleAfter: Int, visibleOverlap: Int, columnsBefore: Int,
        columnsAfter: Int, slotSideBefore: CGFloat, slotSideAfter: CGFloat, gapBefore: CGFloat, gapAfter: CGFloat
    ) {
        PhotoDiagnostics.shared.emit(
            "GridResize",
            [
                "phase": "validation", "visibleBefore": "\(visibleBefore)", "visibleAfter": "\(visibleAfter)",
                "visibleOverlap": "\(visibleOverlap)", "nominalColumnsBefore": "\(columnsBefore)",
                "nominalColumnsAfter": "\(columnsAfter)",
                "slotSideBefore": String(format: "%.1f", slotSideBefore),
                "slotSideAfter": String(format: "%.1f", slotSideAfter),
                "gapBefore": String(format: "%.1f", gapBefore), "gapAfter": String(format: "%.1f", gapAfter),
            ])
    }
    private static func sz(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }
    private static func rc(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))" }
}

// MARK: - MetalGrid performance signposts
//
// Lightweight, throttled counters for the resize/render hot path so stutter is measurable without spamming
// stdout (a live drag fires per frame; `emit` prints synchronously in DEBUG). Off the critical path by default.
@MainActor
enum MetalGridPerfLog {
    static func resizeFrame(
        layoutMs: Double, visibleSlotCount: Int, renderQuadCount: Int, textureUploadCount: Int,
        widthChanged: Bool, heightChanged: Bool, metricsRecomputed: Bool, contentSizeRecomputed: Bool
    ) {
        PhotoDiagnostics.shared.emit(
            "MetalGridPerf",
            [
                "phase": "resizeFrame", "layoutMs": String(format: "%.2f", layoutMs),
                "visibleSlotCount": "\(visibleSlotCount)", "renderQuadCount": "\(renderQuadCount)",
                "textureUploadCount": "\(textureUploadCount)", "widthChanged": "\(widthChanged)",
                "heightChanged": "\(heightChanged)", "metricsRecomputed": "\(metricsRecomputed)",
                "contentSizeRecomputed": "\(contentSizeRecomputed)",
            ], throttleSeconds: 0.5)
    }
}

// MARK: - Commit seam diagnostics
//
// `[GridZoomCommit]` records the live-to-settled commit phases.
@MainActor
enum GridZoomCommitLog {
    static func begin(sourceLevel: Int, anchorGlobalIndex: Int, anchorViewportPoint: CGPoint, focusRow: [Int]) {
        PhotoDiagnostics.shared.emit(
            "GridZoomCommit",
            [
                "phase": "begin", "sourceLevel": "\(sourceLevel)",
                "anchorGlobalIndex": "\(anchorGlobalIndex)",
                "anchorViewportPoint": "(\(Int(anchorViewportPoint.x)),\(Int(anchorViewportPoint.y)))",
                "focusRowIndices": "\(focusRow)",
            ])
    }

    static func frame(progress: CGFloat, anchorViewportRect: CGRect, focusRow: [Int], focusRowStable: Bool) {
        PhotoDiagnostics.shared.emit(
            "GridZoomCommit",
            [
                "phase": "frame", "progress": String(format: "%.2f", progress),
                "anchorViewportRect": rect(anchorViewportRect),
                "focusRowVisibleIndices": "\(focusRow)", "focusRowStable": "\(focusRowStable)",
            ])
    }

    static func release(
        anchorGlobalIndex: Int, hoveredGlobalIndex: Int, selectedGlobalIndex: Int?,
        targetLevel: Int, targetColumns: Int, desiredCursorColumn: Int, computedColumnPhase: Int,
        delta: GridZoomCommitDelta, anchorDeltaColumns: Int
    ) {
        PhotoDiagnostics.shared.emit(
            "GridZoomCommit",
            [
                "phase": "release", "anchorGlobalIndex": "\(anchorGlobalIndex)",
                "hoveredGlobalIndex": "\(hoveredGlobalIndex)",
                "selectedGlobalIndex": selectedGlobalIndex.map { "\($0)" } ?? "none",
                "anchorIsHovered": "\(anchorGlobalIndex == hoveredGlobalIndex)",
                "targetLevel": "\(targetLevel)", "targetColumns": "\(targetColumns)",
                "desiredCursorColumn": "\(desiredCursorColumn)", "computedColumnPhase": "\(computedColumnPhase)",
                "transactionAnchorX": "\(Int(delta.transactionAnchorRect.midX))",
                "settledAnchorX": "\(Int(delta.settledAnchorRect.midX))",
                "anchorDeltaX": "\(Int(delta.anchorDelta.width))", "anchorDeltaColumns": "\(anchorDeltaColumns)",
            ])
    }

    static func bridge(maxMatchedIndexMovePx: CGFloat, maxMatchedIndexMoveColumns: Double, largeMoveRejected: Bool) {
        PhotoDiagnostics.shared.emit(
            "GridZoomCommit",
            [
                "phase": "bridge", "maxMatchedIndexMovePx": "\(Int(maxMatchedIndexMovePx))",
                "maxMatchedIndexMoveColumns": String(format: "%.2f", maxMatchedIndexMoveColumns),
                "largeMoveRejected": "\(largeMoveRejected)",
            ])
    }

    static func end(settledUsesCommittedPhase: Bool) {
        PhotoDiagnostics.shared.emit(
            "GridZoomCommit",
            [
                "phase": "end", "settledUsesCommittedPhase": "\(settledUsesCommittedPhase)",
            ])
    }

    private static func rect(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))"
    }
}
