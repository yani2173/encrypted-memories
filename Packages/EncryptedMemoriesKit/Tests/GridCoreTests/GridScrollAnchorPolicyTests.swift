import CoreGraphics
import Testing

@testable import GridCore

/// Locks the photo that anchors the grid's place through a resize: the first photo below a translucent top bar, kept
/// through every layout of one rotation, never a photo that the bar covers.
@Suite struct GridScrollAnchorPolicyTests {
    private struct Slot: Equatable {
        let id: Int
        let frame: CGRect
    }

    private static func row(_ firstID: Int, top: CGFloat, height: CGFloat = 100) -> [Slot] {
        (0..<3).map { Slot(id: firstID + $0, frame: CGRect(x: CGFloat($0) * 101, y: top, width: 100, height: height)) }
    }

    private func anchor(
        _ slots: [Slot], top: CGFloat = 100, bottom: CGFloat = 600, kept: Int? = nil
    ) -> Int? {
        GridScrollAnchorPolicy.anchor(
            among: slots, visibleTop: top, visibleBottom: bottom, isKept: { $0.id == kept }, frame: \.frame)?.id
    }

    @Test func theFirstPhotoBelowTheBarAnchorsInsteadOfTheRowUnderIt() {
        let slots = Self.row(0, top: 20) + Self.row(3, top: 121) + Self.row(6, top: 222)
        #expect(anchor(slots) == 3)
    }

    @Test func aKeptPhotoWinsWhileItsTopStaysBelowTheBar() {
        let slots = Self.row(0, top: 20) + Self.row(3, top: 121) + Self.row(6, top: 222)
        #expect(anchor(slots, kept: 7) == 7)
        #expect(anchor(slots, kept: 1) == 3, "a kept photo under the bar no longer anchors")
        #expect(anchor(slots, bottom: 200, kept: 7) == 3, "a kept photo below the usable area no longer anchors")
    }

    @Test func tilesTallerThanTheUsableAreaFallBackToTheTileThatReachesIntoIt() {
        let slots = Self.row(0, top: -150, height: 400) + Self.row(3, top: 251, height: 400)
        #expect(anchor(slots, top: 260, bottom: 400) == 3)
        #expect(anchor(slots, top: 700, bottom: 900) == 0, "the topmost slot when none reaches into the area")
        #expect(anchor([], top: 100, bottom: 600) == nil)
    }

    /// An iPhone rotation in the order UIKit lays it out: the landscape size with the portrait bar first, then the
    /// shorter landscape bar, then portrait again. The tiles change size with the width, the bar changes height.
    @Test func aRotationRoundTripKeepsTheFirstRowBelowTheBar() throws {
        let engine = SquareTileGridEngine(
            sectionCounts: [3_000],
            profile: GridLevelProfile(
                id: "rotation-test",
                levels: [GridLevelMetrics(levelID: 0, nominalColumns: 3, gap: 3, monthLabels: false)],
                defaultLevel: 0),
            fillOrder: .newestBottomTrailing)
        struct Layout {
            let size: CGSize
            let topInset: CGFloat
            let bottomInset: CGFloat
        }
        let portrait = Layout(size: CGSize(width: 402, height: 874), topInset: 116, bottomInset: 83)
        let layouts = [
            Layout(size: CGSize(width: 874, height: 402), topInset: 116, bottomInset: 64),
            Layout(size: CGSize(width: 874, height: 402), topInset: 78, bottomInset: 64),
            portrait,
        ]
        func plan(_ layout: Layout, _ offset: CGFloat) -> GridFramePlan {
            engine.framePlan(
                level: 0, viewportSize: layout.size, scrollOffset: CGPoint(x: 0, y: offset), overscan: 0)
        }
        func firstBelowBar(_ layout: Layout, _ offset: CGFloat) throws -> (id: Int, offset: CGFloat) {
            let top = offset + layout.topInset
            let slot = try #require(
                plan(layout, offset).visibleSlots.filter { $0.slotRect.minY >= top - 0.5 }
                    .min { ($0.slotRect.minY, $0.slotRect.minX) < ($1.slotRect.minY, $1.slotRect.minX) })
            return (slot.index, slot.slotRect.minY - top)
        }

        // The top row sits almost completely under the portrait bar.
        var layout = portrait
        var offset: CGFloat = 40_520
        let before = try firstBelowBar(layout, offset)
        var kept: Int?
        for next in layouts {
            let visibleTop = offset + layout.topInset
            let visibleBottom = offset + layout.size.height - layout.bottomInset
            let anchored = GridScrollAnchorPolicy.anchor(
                among: plan(layout, offset).visibleSlots, visibleTop: visibleTop, visibleBottom: visibleBottom,
                isKept: { $0.index == kept }, frame: \.slotRect)
            let anchorSlot = try #require(anchored)
            kept = anchorSlot.index
            let rect = try #require(engine.slotRect(flatIndex: anchorSlot.index, level: 0, width: next.size.width))
            offset = rect.minY - next.topInset - (anchorSlot.slotRect.minY - visibleTop)
            layout = next
        }
        let after = try firstBelowBar(layout, offset)
        #expect(after.id == before.id)
        #expect(abs(after.offset - before.offset) < 0.5)
    }
}
