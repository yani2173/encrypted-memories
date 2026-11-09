import CoreGraphics
import GridCore
import Testing

/// A selection mark that an active reserved region covers moves to the nearest free position inside its tile.
@Suite struct ReservedRegionLayoutTests {
    private let tile = CGRect(x: 100, y: 200, width: 120, height: 120)
    private let bounds = CGRect(x: 0, y: 0, width: 951, height: 680)
    private let side: CGFloat = 22
    private let inset: CGFloat = 7

    private var home: CGRect { ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset) }

    private func mark(_ areas: [ReservedRegionArea], occupied: [CGRect] = [], bounds: CGRect? = nil) -> CGRect {
        ReservedRegionLayout(areas: areas, bounds: bounds ?? self.bounds)
            .selectionMarkRect(in: tile, side: side, inset: inset, avoiding: occupied)
    }

    private func active(_ frame: CGRect) -> ReservedRegionArea { ReservedRegionArea(frame: frame, isActive: true) }

    @Test func aMarkWithoutAnActiveRegionStaysBottomTrailing() {
        #expect(home == CGRect(x: 191, y: 291, width: 22, height: 22))
        #expect(ReservedRegionLayout.none.selectionMarkRect(in: tile, side: side, inset: inset) == home)
        // An inactive division (the device is flat) moves nothing.
        let fold = ReservedRegionArea(frame: CGRect(x: 0, y: 300, width: 951, height: 40), isActive: false)
        #expect(mark([fold]) == home)
    }

    @Test func aTabletopFoldMovesTheMarkUpJustAboveTheFold() {
        // A horizontal fold covers the lower part of the tile; the mark keeps the trailing side.
        let fold = CGRect(x: 0, y: 285, width: 951, height: 40)
        #expect(mark([active(fold)]) == CGRect(x: 191, y: 258, width: 22, height: 22))
    }

    @Test func aBookFoldMovesTheMarkLeadingJustBesideTheFold() {
        // A vertical fold covers the trailing part of the tile; the mark keeps the bottom row.
        let fold = CGRect(x: 185, y: 0, width: 40, height: 680)
        #expect(mark([active(fold)]) == CGRect(x: 158, y: 291, width: 22, height: 22))
    }

    @Test func aFreeSpotBetweenTheCornersIsUsed() {
        // The fold covers both trailing corners, both bottom corners lie below the visible view, and a label fills the
        // top-leading corner. The mark moves to the nearest free spot of the visible bottom row, beside the fold.
        let fold = CGRect(x: 185, y: 0, width: 40, height: 680)
        let visible = CGRect(x: 0, y: 0, width: 951, height: 290)
        let label = CGRect(x: 100, y: 200, width: 40, height: 30)
        #expect(
            mark([active(fold)], occupied: [label], bounds: visible) == CGRect(x: 158, y: 217, width: 22, height: 22))
    }

    @Test func theLeadingEdgeIsAFreeSpotWhenTheStepsMissIt() {
        // A small tile of the densest book level: the band covers every step from the trailing side, and only the
        // leading edge itself stays free.
        let small = CGRect(x: 100, y: 200, width: 27, height: 27)
        let fold = CGRect(x: 115, y: 0, width: 40, height: 680)
        let moved = ReservedRegionLayout(areas: [active(fold)], bounds: bounds)
            .selectionMarkRect(in: small, side: 11, inset: 3)
        // ECKE uses a 2.599pt inset for this 27pt tile; the existing half-step search finds its leading edge.
        #expect(moved == CGRect(x: small.maxX - 11 - 2.599 - 11, y: small.maxY - 11 - 2.599, width: 11, height: 11))
    }

    @Test func theTopEdgeIsAFreeSpotWhenTheStepsMissIt() {
        // A tile of a dense tabletop level: the band covers every step from the bottom, and only the top edge itself
        // stays free.
        let small = CGRect(x: 100, y: 200, width: 54, height: 54)
        let fold = CGRect(x: 0, y: 222, width: 951, height: 40)
        let moved = ReservedRegionLayout(areas: [active(fold)], bounds: bounds)
            .selectionMarkRect(in: small, side: 16.2, inset: 3.24)
        #expect(moved == CGRect(x: small.maxX - 16.2 - 3.24, y: small.minY + 3.24, width: 16.2, height: 16.2))
    }

    @Test func theMarkAvoidsLabels() {
        let fold = CGRect(x: 0, y: 285, width: 951, height: 40)
        // A label covers the free spot just above the fold, so the mark takes the nearest spot beside the label.
        let label = mark([active(fold)]).insetBy(dx: -1, dy: -1)
        #expect(mark([active(fold)], occupied: [label]) == CGRect(x: 191, y: 225, width: 22, height: 22))
    }

    @Test func theMarkCoversALabelWhenNothingElseIsFree() {
        // Only the leading edge of a small tile stays free, and a duration label fills it: selection comes first.
        let small = CGRect(x: 100, y: 200, width: 27, height: 27)
        let fold = CGRect(x: 115, y: 0, width: 40, height: 680)
        let label = CGRect(x: 100, y: 209, width: 14, height: 18)
        let moved = ReservedRegionLayout(areas: [active(fold)], bounds: bounds)
            .selectionMarkRect(in: small, side: 11, inset: 3, avoiding: [label])
        // ECKE uses a 2.599pt inset for this 27pt tile; the existing half-step search finds its leading edge.
        #expect(moved == CGRect(x: small.maxX - 11 - 2.599 - 11, y: small.maxY - 11 - 2.599, width: 11, height: 11))
        #expect(moved.intersects(label))
    }

    @Test func aTileWithoutAFreeSpotMovesBesideTheBand() {
        let wide = CGRect(x: 0, y: 150, width: 951, height: 250)
        let moved = mark([active(wide)])
        #expect(moved == CGRect(x: 149, y: 128, width: 22, height: 22))
        #expect(!moved.intersects(wide))
        #expect(moved.midX == tile.midX)
    }
    @Test func aHorizontalOcclusionIsNotATabletopDivision() {
        let area = active(CGRect(x: 0, y: 285, width: 951, height: 40))
        let layout = ReservedRegionLayout(areas: [area], bounds: bounds)
        #expect(layout.horizontalFold == nil)
        #expect(
            layout.selectionMarkRect(in: tile, side: side, inset: inset)
                == CGRect(x: 191, y: 258, width: 22, height: 22))
    }

    @Test func tabletopCentersTheWholeLoadingBlockAboveTheFold() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 951)
        let fold = CGRect(x: 0, y: 455, width: 669, height: 40)
        let layout = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: fold, isActive: true, isDivision: true)], bounds: bounds)
        let region = layout.centeredLoadingBounds ?? bounds
        let block = CGRect(x: region.midX - 110, y: region.midY - 70, width: 220, height: 140)
        #expect(region == CGRect(x: 0, y: 0, width: 669, height: 455))
        #expect(block.midY == 227.5, "Indicator and text share one centered block")
        #expect(block.maxY < fold.minY)
        #expect(block.midX == bounds.midX)
    }

    @Test func loadingPlacementWithoutATabletopDivisionKeepsTheExistingCenter() {
        for size in [
            CGSize(width: 393, height: 852), CGSize(width: 1024, height: 1366),
            CGSize(width: 1440, height: 900), CGSize(width: 466, height: 678), CGSize(width: 669, height: 951),
        ] {
            let bounds = CGRect(origin: .zero, size: size)
            for areas in [
                [],
                [
                    ReservedRegionArea(
                        frame: CGRect(x: 0, y: 400, width: size.width, height: 40), isActive: false, isDivision: true)
                ],
                [
                    ReservedRegionArea(
                        frame: CGRect(x: size.width / 2, y: 0, width: 40, height: size.height), isActive: true,
                        isDivision: true)
                ],
                [ReservedRegionArea(frame: CGRect(x: 0, y: 400, width: size.width, height: 40), isActive: true)],
            ] {
                let layout = ReservedRegionLayout(areas: areas, bounds: bounds)
                #expect(layout.centeredLoadingBounds == nil, "No tabletop override preserves the existing view path")
                let region = layout.centeredLoadingBounds ?? bounds
                #expect(region.midX == bounds.midX && region.midY == bounds.midY)
            }
        }
    }

    @Test func aSyntheticHorizontalDivisionCentersLoadingAboveItsOwnFold() {
        let bounds = CGRect(x: 20, y: 30, width: 900, height: 760)
        let layout = ReservedRegionLayout(
            areas: [
                ReservedRegionArea(
                    frame: CGRect(x: 20, y: 300, width: 900, height: 30), isActive: true, isDivision: true)
            ],
            bounds: bounds)
        #expect(layout.centeredLoadingBounds == CGRect(x: 20, y: 30, width: 900, height: 270))
    }
}
