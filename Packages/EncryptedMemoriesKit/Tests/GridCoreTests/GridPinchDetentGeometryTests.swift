import CoreGraphics
import Testing

@testable import GridCore

/// The cursor-aligned pinch detent both hosts draw with: the anchor stays under the cursor, and the scroll offset
/// stays inside the real content bounds.
@Suite struct GridPinchDetentGeometryTests {
    private let engine = SquareTileGridEngine(
        sectionCounts: [3_000],
        profile: GridLevelProfile(
            id: "detent-test",
            levels: [
                GridLevelMetrics(
                    levelID: 0, nominalColumns: 3, gap: 4, monthLabels: false, transitionKindToNext: .focusRowRelayout),
                GridLevelMetrics(
                    levelID: 1, nominalColumns: 5, gap: 3, monthLabels: false, transitionKindToNext: .focusRowRelayout),
                GridLevelMetrics(levelID: 2, nominalColumns: 7, gap: 2, monthLabels: false),
            ],
            defaultLevel: 0))
    private let width: CGFloat = 400
    private let height: CGFloat = 800

    private func transaction(cursorContentY: CGFloat, viewportPoint: CGPoint) throws -> GridZoomTransaction {
        try #require(
            engine.beginZoomTransaction(
                cursorContentPoint: CGPoint(x: viewportPoint.x, y: cursorContentY), viewportPoint: viewportPoint,
                level: 0, width: width))
    }

    private func frame(_ transaction: GridZoomTransaction, level: Int) -> GridPinchDetentFrame {
        GridPinchDetentGeometry.cursorAlignedFrame(
            level: level, transaction: transaction, engine: engine, width: width, viewportHeight: height)
    }

    @Test func theAnchorStaysUnderTheCursorAtEveryDetent() throws {
        let cursor = CGPoint(x: 310, y: 420)
        let tx = try transaction(cursorContentY: 40_000, viewportPoint: cursor)
        for level in 0...2 {
            let detent = frame(tx, level: level)
            let plan = engine.framePlan(
                level: level, viewportSize: CGSize(width: width, height: height),
                scrollOffset: CGPoint(x: 0, y: detent.scrollY), overscan: 0, columnPhase: detent.phase)
            let slot = try #require(plan.visibleSlots.first { $0.index == tx.anchorGlobalIndex }, "level \(level)")
            #expect(slot.column == engine.cursorColumn(viewportX: cursor.x, level: level, width: width))
            let anchoredY = slot.viewportRect.minY + tx.anchorLocalFraction.y * slot.viewportRect.height
            #expect(abs(anchoredY - cursor.y) < 0.5, "level \(level)")
        }
    }

    @Test func theGestureStartDetentKeepsTheViewTheGestureBeganWith() throws {
        let beganAtScrollY: CGFloat = 40_000 - 420
        let tx = try transaction(cursorContentY: 40_000, viewportPoint: CGPoint(x: 310, y: 420))
        let detent = frame(tx, level: tx.sourceLevel)
        #expect(abs(detent.scrollY - beganAtScrollY) < 0.5)
        let plan = engine.framePlan(
            level: tx.sourceLevel, viewportSize: CGSize(width: width, height: height),
            scrollOffset: CGPoint(x: 0, y: detent.scrollY), overscan: 0, columnPhase: detent.phase)
        let slot = try #require(plan.visibleSlots.first { $0.index == tx.anchorGlobalIndex })
        let beganPlan = engine.framePlan(
            level: tx.sourceLevel, viewportSize: CGSize(width: width, height: height),
            scrollOffset: CGPoint(x: 0, y: beganAtScrollY), overscan: 0, columnPhase: nil)
        let beganSlot = try #require(beganPlan.visibleSlots.first { $0.index == tx.anchorGlobalIndex })
        #expect(slot.column == beganSlot.column)
        #expect(abs(slot.viewportRect.minY - beganSlot.viewportRect.minY) < 0.5)
    }

    @Test func theOffsetStopsAtTheTopOfTheLibrary() throws {
        let tx = try transaction(cursorContentY: 60, viewportPoint: CGPoint(x: 200, y: 500))
        for level in 0...2 {
            #expect(frame(tx, level: level).scrollY == 0, "level \(level)")
        }
    }

    @Test func theOffsetStopsAtTheBottomOfTheLibrary() throws {
        let lastRowY = try #require(engine.slotRect(flatIndex: 2_999, level: 0, width: width)).midY
        let tx = try transaction(cursorContentY: lastRowY, viewportPoint: CGPoint(x: 200, y: 100))
        for level in 0...2 {
            let detent = frame(tx, level: level)
            let column = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: level, width: width)
            #expect(
                detent.phase
                    == engine.columnPhase(
                        forItem: tx.anchorGlobalIndex, targetColumn: column, level: level, width: width),
                "level \(level)")
            let maxY = engine.contentSize(level: level, width: width, columnPhase: detent.phase).height - height
            #expect(detent.scrollY == maxY, "level \(level)")
        }
    }

    @Test func adjacentSegmentsGetTheSameFrameForTheirSharedDetent() throws {
        // The frame of a detent may depend on the anchor, the detent and the layout size only: not on the level the
        // gesture started on, which would otherwise make the frame differ between two segments that share a detent.
        let first = try transaction(cursorContentY: 25_000, viewportPoint: CGPoint(x: 90, y: 300))
        let second = GridZoomTransaction(
            totalItems: first.totalItems, anchorGlobalIndex: first.anchorGlobalIndex,
            anchorViewportPoint: first.anchorViewportPoint, anchorLocalFraction: first.anchorLocalFraction,
            levels: first.levels, sourceLevel: 2)
        #expect(first.sourceLevel != second.sourceLevel)
        for level in 0...2 {
            #expect(frame(first, level: level) == frame(second, level: level), "level \(level)")
        }
    }
}
