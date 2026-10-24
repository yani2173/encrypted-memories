import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

/// `hitTest(cursorViewportPoint)` must return the same item before the gesture, during the transaction,
/// and after the first settled frame. Pinches use the cursor item; toolbar and keyboard changes use the viewport
/// center. `beginZoomTransaction` resolves against the committed column phase.
@Suite struct GridZoomAnchorIdentityTests {
    private let viewport = CGSize(width: 900, height: 700)
    private let width: CGFloat = 900
    private let count = 4000

    private func engine() -> SquareTileGridEngine { SquareTileGridEngine.testRegular(sectionCounts: [count]) }

    private func itemUnderCursor(
        _ e: SquareTileGridEngine, vp: CGPoint, level: Int, phase: Int?, scrollY: CGFloat
    ) -> Int? {
        e.hitTest(contentPoint: CGPoint(x: vp.x, y: vp.y + scrollY), level: level, width: width, columnPhase: phase)?
            .index
    }

    /// Simulate the host/coordinator pinch flow exactly: begin (anchor resolved with the committed phase),
    /// commit (cursor-aligned phase + anchor-rebased scrollY), settled hitTest at the same cursor point.
    private func simulatePinch(
        sourceLevel: Int, sourcePhase: Int?, targetLevel: Int, cursorVP: CGPoint, sourceScrollY: CGFloat
    )
        -> (
            displayed: Int, txAnchor: Int, after: Int?, phase: Int, scrollY: CGFloat, tx: GridZoomTransaction,
            e: SquareTileGridEngine
        )
    {
        let e = engine()
        let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + sourceScrollY)
        let displayed = itemUnderCursor(
            e, vp: cursorVP, level: sourceLevel, phase: sourcePhase, scrollY: sourceScrollY)!
        let tx = e.beginZoomTransaction(
            cursorContentPoint: cursorContent, viewportPoint: cursorVP,
            level: sourceLevel, width: width, columnPhase: sourcePhase)!
        let desiredCol = e.cursorColumn(viewportX: cursorVP.x, level: targetLevel, width: width)
        let phase = e.columnPhase(
            forItem: tx.anchorGlobalIndex, targetColumn: desiredCol, level: targetLevel, width: width)
        let scrollY = e.anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
            viewportPoint: cursorVP, level: targetLevel, width: width, columnPhase: phase
        ).y
        let after = itemUnderCursor(e, vp: cursorVP, level: targetLevel, phase: phase, scrollY: scrollY)
        return (displayed, tx.anchorGlobalIndex, after, phase, scrollY, tx, e)
    }

    private let cursorVP = CGPoint(x: 430, y: 360)
    private let scenarios: [Int?] = [.none, .some(1), .some(3), .some(5)]  // canonical + several committed phases

    @Test func cursorAnchorIdentitySurvivesCommit() {
        for sourcePhase in scenarios {
            for (s, t) in [(2, 4), (3, 1), (4, 5), (1, 5)] {
                let r = simulatePinch(
                    sourceLevel: s, sourcePhase: sourcePhase, targetLevel: t, cursorVP: cursorVP, sourceScrollY: 5000)
                #expect(
                    r.txAnchor == r.displayed,
                    "begin anchored \(r.txAnchor) ≠ displayed \(r.displayed) (phase \(String(describing: sourcePhase)))"
                )
                #expect(
                    r.after == r.displayed,
                    "after commit \(String(describing: r.after)) ≠ displayed \(r.displayed) (s\(s)→t\(t), phase \(String(describing: sourcePhase)))"
                )
            }
        }
    }

    @Test func liveZoomKeepsAnchorUnderCursor() {
        let r = simulatePinch(sourceLevel: 3, sourcePhase: 3, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        for lp in stride(from: CGFloat(3), through: 5, by: 0.25) {
            let frame = r.tx.frame(continuousLevel: lp, viewportSize: viewport, overscan: 0)
            let anchorSlot = frame.visibleSlots.first { $0.index == r.txAnchor }!
            #expect(
                anchorSlot.rect.insetBy(dx: -0.5, dy: -0.5).contains(cursorVP),
                "live: cursor not inside the anchor cell at levelPosition \(lp)")
        }
    }

    @Test func commitBridgeKeepsAnchorUnderCursor() {
        let r = simulatePinch(sourceLevel: 3, sourcePhase: 3, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        let pitch = r.e.resolvedMetrics(level: 5, width: width).pitch
        for prog in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let slots = GridZoomCommitBridge.frame(
                transaction: r.tx, engine: r.e, targetLevel: 5, viewportSize: viewport,
                scrollY: r.scrollY, overscan: 0, progress: prog, columnPhase: r.phase)
            let anchor = slots.first { $0.index == r.txAnchor }!
            #expect(
                abs(anchor.rect.midX - cursorVP.x) < pitch, "bridge: anchor left the cursor cell at progress \(prog)")
        }
    }

    @Test func firstSettledFrameKeepsAnchorUnderCursor() {
        let r = simulatePinch(sourceLevel: 2, sourcePhase: 3, targetLevel: 4, cursorVP: cursorVP, sourceScrollY: 5000)
        let plan = r.e.framePlan(
            level: 4, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: r.scrollY), overscan: 0,
            columnPhase: r.phase)
        let underCursor = plan.visibleSlots.first { $0.viewportRect.contains(cursorVP) }?.index
        #expect(
            underCursor == r.txAnchor, "first settled frame: \(String(describing: underCursor)) ≠ anchor \(r.txAnchor)")
    }

    @Test func scrollLockDoesNotUndoCommitScroll() {
        // The commit computes a new scrollY, so the lock must use the committed value.
        let r = simulatePinch(sourceLevel: 2, sourcePhase: nil, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(abs(r.scrollY - 5000) > 1, "the commit computed a new anchor-preserving scrollY")
    }

    @Test func pinchEndpointUsesClampedScrollBeforeRelease() {
        let e = engine()
        let target = 1

        let topPhase = e.columnPhase(forItem: 0, targetColumn: 0, level: target, width: width)
        let rawTop = e.anchoredScrollOffset(
            flatIndex: 0,
            localFraction: CGPoint(x: 0.5, y: 0.5),
            viewportPoint: CGPoint(x: 20, y: viewport.height - 8),
            level: target, width: width, columnPhase: topPhase
        ).y
        let clampedTop = e.clampScrollOffsetY(
            rawTop, level: target, width: width,
            viewportHeight: viewport.height, columnPhase: topPhase)
        #expect(rawTop < 0, "test must cover a top-edge impossible cursor anchor")
        #expect(clampedTop == 0, "top-edge target detent must be built at the committed top clamp")

        let last = count - 1
        let bottomPhase = e.columnPhase(forItem: last, targetColumn: 0, level: target, width: width)
        let targetMaxY = max(
            0, e.contentSize(level: target, width: width, columnPhase: bottomPhase).height - viewport.height)
        let rawBottom = e.anchoredScrollOffset(
            flatIndex: last,
            localFraction: CGPoint(x: 0.5, y: 0.5),
            viewportPoint: CGPoint(x: 20, y: 8),
            level: target, width: width, columnPhase: bottomPhase
        ).y
        let clampedBottom = e.clampScrollOffsetY(
            rawBottom, level: target, width: width,
            viewportHeight: viewport.height, columnPhase: bottomPhase)
        #expect(rawBottom > targetMaxY, "test must cover a bottom-edge impossible cursor anchor")
        #expect(clampedBottom == targetMaxY, "bottom-edge target detent must be built at the committed bottom clamp")
    }

    @Test func commitUsesSameCursorPointAsBegin() {
        let r = simulatePinch(sourceLevel: 3, sourcePhase: 3, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(r.tx.anchorViewportPoint == cursorVP, "the transaction must carry the begin cursor point")
    }

    @Test func problematic24To18Regression() {
        // A gesture from a committed non-canonical phase must preserve the item under the cursor after commit.
        let e = engine()
        let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + 5000)
        let displayed = itemUnderCursor(e, vp: cursorVP, level: 2, phase: 3, scrollY: 5000)!
        let canonical = e.anchorItem(nearContentPoint: cursorContent, level: 2, width: width)!.flatIndex
        #expect(displayed != canonical, "scenario must actually have displayed ≠ canonical (the swap source)")
        let r = simulatePinch(sourceLevel: 2, sourcePhase: 3, targetLevel: 4, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(
            r.after == displayed,
            "regression: cursor settled on \(String(describing: r.after)) ≠ displayed \(displayed)")
        #expect(r.after != canonical, "regression: cursor must NOT settle on the canonical (wrong) item \(canonical)")
    }

    @Test func working84CaseStillWorks() {
        // A gesture starting from the canonical phase (e.g. right after bottom-pin reset) keeps working.
        for (s, t) in [(2, 4), (4, 2), (3, 5)] {
            let r = simulatePinch(
                sourceLevel: s, sourcePhase: nil, targetLevel: t, cursorVP: cursorVP, sourceScrollY: 5000)
            #expect(r.after == r.displayed, "canonical-phase gesture broke: s\(s)→t\(t)")
        }
    }

    @Test func plusMinusCenterItemSurvivesCommit() {
        let e = engine()
        let scrollY: CGFloat = 5000
        let center = CGPoint(x: width / 2, y: viewport.height / 2)  // viewport-centre viewport point
        let centerContent = CGPoint(x: center.x, y: center.y + scrollY)
        for sourcePhase in scenarios {
            // The displayed item nearest the viewport centre uses a fallback, so it is never nil.
            let a = e.anchorItem(nearContentPoint: centerContent, level: 3, width: width, columnPhase: sourcePhase)!
            let before = a.flatIndex
            let target = 5
            let desiredCol = e.cursorColumn(viewportX: center.x, level: target, width: width)
            let phase = e.columnPhase(forItem: before, targetColumn: desiredCol, level: target, width: width)
            let newScrollY = e.anchoredScrollOffset(
                flatIndex: before, localFraction: a.localFraction,
                viewportPoint: center, level: target, width: width, columnPhase: phase
            ).y
            // After the +/- zoom, the item nearest the viewport centre is still the same item.
            let afterContent = CGPoint(x: center.x, y: center.y + newScrollY)
            let after = e.anchorItem(nearContentPoint: afterContent, level: target, width: width, columnPhase: phase)!
                .flatIndex
            #expect(
                after == before,
                "+/- centre item changed: \(after) ≠ \(before) (phase \(String(describing: sourcePhase)))")
            // The committed phase persists: a later scroll keeps the same column mapping (no snap-back to canonical).
            let cols = e.resolvedMetrics(level: target, width: width).columns
            let plan = e.framePlan(
                level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: newScrollY + 1234), overscan: 0,
                columnPhase: phase)
            for s in plan.visibleSlots {
                #expect(s.column == ((phase + s.index) % cols + cols) % cols, "phase did not persist on scroll")
            }
        }
    }

    @MainActor @Test func diagnosticsEmitWithoutDuplicateKeys() {
        let p = CGPoint(x: 430, y: 360)
        GridZoomAnchorLog.begin(
            trigger: .pinch, cursorViewportPoint: p, cursorContentPoint: p,
            hoveredIndexAtBegin: 5, transactionAnchorIndex: 5, level: 2)
        GridZoomAnchorLog.live(
            levelPosition: 3.5, cursorViewportPoint: p, indexUnderCursor: 5,
            transactionAnchorIndex: 5, focusRow: [4, 5, 6])
        GridZoomAnchorLog.release(
            targetLevel: 4, cursorViewportPoint: p, indexUnderCursorBeforeCommit: 5,
            transactionAnchorIndex: 5, committedPhase: 3, targetScrollY: 100, bridgeWillRun: true)
        GridZoomAnchorLog.postCommit(
            cursorViewportPoint: p, indexUnderCursorAfterCommit: 5,
            transactionAnchorIndex: 5, scrollY: 100, phase: 3)
        GridZoomAnchorLog.postCommit(
            cursorViewportPoint: p, indexUnderCursorAfterCommit: nil,
            transactionAnchorIndex: 5, scrollY: 100, phase: nil)
        #expect(Bool(true))  // reaching here, so no dictionary-literal duplicate-key trap on any emit path
    }

    @Test func triggerAnchorModeDiagnostic() {
        #expect(GridZoomTrigger.pinch.anchorMode == .cursor)
        #expect(GridZoomTrigger.toolbarPlus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.toolbarMinus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.keyboardPlus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.keyboardMinus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.pinch.isPlusMinus == false)
        #expect(GridZoomTrigger.keyboardMinus.isPlusMinus == true)
    }

    // Repeated gestures preserve the cursor item across committed phases.
    @Test func repeatedPinchIdentitySurvivesEachGesture() {
        // Gesture 1: 3 to 1 from the canonical phase.
        let g1 = simulatePinch(
            sourceLevel: 3, sourcePhase: nil, targetLevel: 1, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(g1.txAnchor == g1.displayed, "gesture 1 begin anchored a different item than displayed")
        #expect(g1.after == g1.displayed, "gesture 1: anchor left the cursor")
        // Gesture 2 (pinch back 1 to 4) begins on gesture 1's committed grid (level 1, phase g1.phase, scroll g1.scrollY).
        let g2 = simulatePinch(
            sourceLevel: 1, sourcePhase: g1.phase, targetLevel: 4, cursorVP: cursorVP, sourceScrollY: g1.scrollY)
        #expect(g2.displayed == g1.after, "the grid gesture 2 begins on must be exactly what gesture 1 committed")
        #expect(
            g2.txAnchor == g2.displayed,
            "gesture 2 begin anchored a different item than displayed (committed-phase swap)")
        #expect(g2.after == g2.displayed, "gesture 2: anchor left the cursor on the repeated gesture")
        // Gesture 3 (pinch in again 4 to 2) on gesture 2's committed grid.
        let g3 = simulatePinch(
            sourceLevel: 4, sourcePhase: g2.phase, targetLevel: 2, cursorVP: cursorVP, sourceScrollY: g2.scrollY)
        #expect(g3.displayed == g2.after, "the grid gesture 3 begins on must be exactly what gesture 2 committed")
        #expect(g3.after == g3.displayed, "gesture 3: anchor left the cursor after two prior commits")
    }

    // The pinch commit builds a cursor-aligned, clamped endpoint that the first settled frame must preserve.
    @Test func pinchChainEndpointEqualsFirstSettledFrame() {
        let e = engine()
        let sourceScrollY: CGFloat = 5000
        let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + sourceScrollY)
        let displayed = itemUnderCursor(e, vp: cursorVP, level: 3, phase: 3, scrollY: sourceScrollY)!
        let tx = e.beginZoomTransaction(
            cursorContentPoint: cursorContent, viewportPoint: cursorVP,
            level: 3, width: width, columnPhase: 3)!
        #expect(tx.anchorGlobalIndex == displayed, "begin anchor must equal the displayed item")
        for target in [1, 2] {  // adjacent + multi-level detents within the normal band, mid-content (no edge clamp)
            // The cursor-aligned detent frame both hosts build a lattice segment and the lattice chain commit from.
            let detent = GridPinchDetentGeometry.cursorAlignedFrame(
                level: target, transaction: tx, engine: e, width: width, viewportHeight: viewport.height)
            let rawY = e.anchoredScrollOffset(
                flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                viewportPoint: tx.anchorViewportPoint, level: target, width: width, columnPhase: detent.phase
            ).y
            #expect(
                abs(detent.scrollY - rawY) < 0.5,
                "scenario must be mid-content (no edge clamp) for a clean endpoint check at level \(target)")
            let plan = e.framePlan(
                level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: detent.scrollY), overscan: 0,
                columnPhase: detent.phase)
            let underCursor = plan.visibleSlots.first { $0.viewportRect.contains(cursorVP) }?.index
            #expect(
                underCursor == tx.anchorGlobalIndex,
                "endpoint equality: settled frame under cursor \(String(describing: underCursor)) ≠ anchor \(tx.anchorGlobalIndex) at level \(target)"
            )
        }
    }

    // Convert the render-space cursor to layout space once before anchor math. The settled frame must preserve it.
    @Test func sidebarLayoutSpaceAnchorIsConsistent() {
        let e = engine()  // the engine works purely in layout space
        let inset: CGFloat = 282 + MetalGridScrollHost.normalLevelLeadingGap  // sidebar + normal-level gap
        let fullWidth = width + inset  // render-space full viewport width
        let layoutW = fullWidth - inset  // == `width`, the inset-removed engine layout width
        #expect(layoutW == width)
        let renderCursorX = inset + 430  // a render-space cursor x (to the right of the sidebar)
        let layoutCursorX = renderCursorX - inset  // host rule: subtract the inset exactly once
        #expect(layoutCursorX == 430)
        let scrollY: CGFloat = 5000
        let cursorVPLayout = CGPoint(x: layoutCursorX, y: 360)
        let cursorContent = CGPoint(x: layoutCursorX, y: cursorVPLayout.y + scrollY)
        let displayed = e.hitTest(contentPoint: cursorContent, level: 2, width: layoutW, columnPhase: 3)?.index
        let tx = e.beginZoomTransaction(
            cursorContentPoint: cursorContent, viewportPoint: cursorVPLayout,
            level: 2, width: layoutW, columnPhase: 3)!
        #expect(
            tx.anchorGlobalIndex == displayed, "sidebar: anchor must resolve in layout space at the inset-removed width"
        )
        let col = e.cursorColumn(viewportX: cursorVPLayout.x, level: 4, width: layoutW)
        let phase = e.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: col, level: 4, width: layoutW)
        let y = e.anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
            viewportPoint: cursorVPLayout, level: 4, width: layoutW, columnPhase: phase
        ).y
        let plan = e.framePlan(
            level: 4, viewportSize: CGSize(width: layoutW, height: viewport.height),
            scrollOffset: CGPoint(x: 0, y: y), overscan: 0, columnPhase: phase)
        let under = plan.visibleSlots.first { $0.viewportRect.contains(cursorVPLayout) }?.index
        #expect(under == tx.anchorGlobalIndex, "sidebar: settled frame anchor must stay under the layout-space cursor")
    }
}
