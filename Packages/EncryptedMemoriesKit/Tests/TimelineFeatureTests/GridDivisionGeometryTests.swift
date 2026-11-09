import CoreGraphics
import GridCore
import Testing
import TimelineCore

@Suite struct GridDivisionGeometryTests {
    private let viewport = CGSize(width: 867, height: 669)

    @Test(arguments: [CGFloat(867), 951])
    func verticalDivisionsUseTheOrdinaryFullWidthAtEveryZoomStep(width: CGFloat) throws {
        let size = CGSize(width: width, height: viewport.height)
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        #expect(profile.id == "touchRegularTimeline")
        #expect(profile.defaultLevel == 1)
        let engine = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
        // Literal expected values for the touch-regular ladder: 4, 6, 8, 10, 20 and 30 columns with gaps 4, 3, 2.5,
        // 2, 1 and 1; each tile side is (width - gap x (columns - 1)) / columns. For 867 that yields
        // 213.75, 142, 106.1875, 84.9, 42.4 and 838/30; for 951 it yields 234.75, 156, 116.6875, 93.3, 46.6 and 922/30.
        let expectedColumns = [4, 6, 8, 10, 20, 30]
        let expectedGaps: [CGFloat] = [4, 3, 2.5, 2, 1, 1]
        let expectedSides: [CGFloat] =
            width == 867
            ? [213.75, 142, 106.1875, 84.9, 42.4, 838.0 / 30.0]
            : [234.75, 156, 116.6875, 93.3, 46.6, 922.0 / 30.0]
        for level in 0..<engine.levelCount {
            let plan = engine.framePlan(level: level, viewportSize: size, scrollOffset: .zero, overscan: 0)
            #expect(profile.levels[level].nominalColumns == expectedColumns[level])
            #expect(profile.levels[level].gap == expectedGaps[level])
            let resolved = engine.resolvedMetrics(level: level, width: width)
            #expect(resolved.columns == expectedColumns[level])
            #expect(abs(resolved.slotSide - expectedSides[level]) < 1e-9)
            let row = plan.visibleSlots.filter { $0.row == 0 }.sorted { $0.column < $1.column }
            #expect(row.count == expectedColumns[level])
            let first = try #require(row.first)
            let last = try #require(row.last)
            #expect(first.slotRect.minX == 0)
            #expect(abs(last.slotRect.maxX - width) < 1e-9)
            for pair in zip(row, row.dropFirst()) {
                #expect(abs(pair.1.slotRect.minX - pair.0.slotRect.maxX - expectedGaps[level]) < 1e-9)
            }
            for slot in plan.visibleSlots {
                let point = CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY)
                #expect(engine.hitTest(contentPoint: point, level: level, width: width)?.index == slot.index)
                #expect(engine.cursorColumn(viewportX: point.x, level: level, width: width) == slot.column)
                #expect(engine.slotRect(flatIndex: slot.index, level: level, width: width) == slot.slotRect)
            }
        }

        let contentPoint = CGPoint(x: width / 2, y: 1_200)
        let viewportPoint = CGPoint(x: width / 2, y: 300)
        let zoom = try #require(
            engine.beginZoomTransaction(
                cursorContentPoint: contentPoint, viewportPoint: viewportPoint, level: 1, width: width))
        for level in 0...5 {
            let frame = zoom.frame(continuousLevel: CGFloat(level), viewportSize: size, overscan: 0)
            #expect(frame.columns == expectedColumns[level])
            #expect(abs(frame.slotSide - expectedSides[level]) < 1e-9)
            #expect(frame.gap == expectedGaps[level])
        }
        // Halfway between levels 0 and 1 the side and gap average (213.75 + 142) / 2 = 177.875 and (4 + 3) / 2 = 3.5
        // at 867 pt ((234.75 + 156) / 2 = 195.375 at 951 pt), which fits round((width + gap) / (side + gap)) = 5 columns.
        let midFrame = zoom.frame(continuousLevel: 0.5, viewportSize: size, overscan: 0)
        #expect(midFrame.columns == 5)
        #expect(abs(midFrame.slotSide - (width == 867 ? 177.875 : 195.375)) < 1e-9)
        #expect(midFrame.gap == 3.5)

        for level in 0..<(engine.levelCount - 1) {
            let source = engine.framePlan(
                level: level, viewportSize: size, scrollOffset: .zero, overscan: 100)
            let target = engine.framePlan(
                level: level + 1, viewportSize: size, scrollOffset: .zero, overscan: 100)
            let controller = GridTransitionController()
            #expect(
                controller.beginPinch(
                    source: source, target: target, anchorIndex: 0, viewportSize: size, selection: []))
            let sourceRects = Dictionary(
                uniqueKeysWithValues: source.visibleSlots.map { ($0.index, $0.slotRect) })
            let targetRects = Dictionary(
                uniqueKeysWithValues: target.visibleSlots.map { ($0.index, $0.slotRect) })
            for progress in [0.0, 1.0] {
                controller.setProgress(progress)
                let draws = controller.currentDraws()
                let settledRects = progress < 0.5 ? sourceRects : targetRects
                // Each end state shows the settled layout of its level: every drawn rect equals the ordinary
                // full-width slot rect of the same flat index.
                for draw in draws {
                    let settled = try #require(settledRects[draw.index])
                    #expect(draw.rect == settled)
                }
                let minX = draws.map { $0.rect.minX }.min() ?? 0
                let maxX = draws.map { $0.rect.maxX }.max() ?? 0
                #expect(minX == 0)
                #expect(abs(maxX - width) < 1e-9)
                let anchor = try #require(draws.first { $0.index == 0 })
                let side = progress < 0.5 ? expectedSides[level] : expectedSides[level + 1]
                #expect(anchor.rect == CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
    }
}
