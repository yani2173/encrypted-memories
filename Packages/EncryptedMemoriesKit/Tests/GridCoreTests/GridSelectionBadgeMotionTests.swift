import CoreGraphics
import GridCore
import Testing

@Suite struct GridSelectionBadgeMotionTests {
    private let band = CGRect(x: 0, y: 455, width: 669, height: 40)
    private var regions: ReservedRegionLayout {
        ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: band, isActive: true)],
            bounds: CGRect(x: 0, y: 80, width: 669, height: 790))
    }

    private func tile(_ y: CGFloat, side: CGFloat = 32.5) -> CGRect {
        CGRect(x: 100, y: y, width: side, height: side)
    }

    private func frame(
        _ motion: inout GridSelectionBadgeMotion, y: CGFloat, now: Double, reduceMotion: Bool = false
    ) -> CGRect {
        motion.frame(tile: tile(y), side: 11, inset: 3, regions: regions, now: now, reduceMotion: reduceMotion)
    }

    @Test func denseTileWhollyInsideTheBandUsesAFullClearCircleBesideItsTile() {
        var motion = GridSelectionBadgeMotion()
        let rect = frame(&motion, y: 462, now: 0, reduceMotion: true)
        #expect(regions.isClear(rect))
        #expect(regions.bounds.contains(rect))
        #expect(rect.size == CGSize(width: 11, height: 11))
        #expect(!tile(462).contains(rect), "No circle fits inside a tile wholly inside the division")
    }

    @Test func crossingStartsATimedSlideThatContinuesAfterScrollingStops() {
        var motion = GridSelectionBadgeMotion()
        let home = frame(&motion, y: 380, now: 0)
        _ = frame(&motion, y: 430, now: 1)
        let target = motion.target
        #expect(motion.isAnimating)
        #expect(regions.isClear(target))
        let start = frame(&motion, y: 430, now: 1)
        let middle = frame(&motion, y: 430, now: 1.1)
        let end = frame(&motion, y: 430, now: 1.21)
        #expect(start != middle)
        #expect(middle != target)
        #expect(end == target)
        #expect(!motion.isAnimating)
        for rect in [home, start, middle, end] {
            #expect(rect.size == CGSize(width: 11, height: 11))
        }
    }

    @Test func aRunningSlideDoesNotRetargetOrRestartWithTheScrollOffset() {
        var still = GridSelectionBadgeMotion()
        var scrolled = GridSelectionBadgeMotion()
        _ = frame(&still, y: 380, now: 0)
        _ = frame(&scrolled, y: 380, now: 0)
        _ = frame(&still, y: 430, now: 1)
        _ = frame(&scrolled, y: 430, now: 1)
        let a = frame(&still, y: 430, now: 1.1)
        let b = frame(&scrolled, y: 470, now: 1.1)
        #expect(a == b.offsetBy(dx: 0, dy: -40), "The row follows scrolling; slide progress uses only time")
        #expect(still.target == scrolled.target.offsetBy(dx: 0, dy: -40))
    }

    @Test func edgeJitterKeepsTheAlternateSlotUntilTheTileClearsTheReleaseMargin() {
        var motion = GridSelectionBadgeMotion()
        _ = frame(&motion, y: 380, now: 0)
        _ = frame(&motion, y: 430, now: 1, reduceMotion: true)
        for (index, y) in [430.0, 429.8, 430.2, 429.9].enumerated() {
            let rect = frame(&motion, y: y, now: Double(index + 2), reduceMotion: true)
            let normal = ReservedRegionLayout.homeMarkRect(in: tile(y), side: 11, inset: 3)
            #expect(rect != normal)
            #expect(regions.isClear(rect))
        }
        let returned = frame(&motion, y: 380, now: 10, reduceMotion: true)
        #expect(returned == ReservedRegionLayout.homeMarkRect(in: tile(380), side: 11, inset: 3))
    }

    @Test func reduceMotionMovesImmediatelyWithoutAPartialOrScaledBadge() {
        var motion = GridSelectionBadgeMotion()
        _ = frame(&motion, y: 380, now: 0, reduceMotion: true)
        let moved = frame(&motion, y: 462, now: 1, reduceMotion: true)
        #expect(moved == motion.target)
        #expect(!motion.isAnimating)
        #expect(regions.isClear(moved))
        #expect(moved.size == CGSize(width: 11, height: 11))
        let returned = frame(&motion, y: 380, now: 2, reduceMotion: true)
        #expect(returned == ReservedRegionLayout.homeMarkRect(in: tile(380), side: 11, inset: 3))
    }

    @Test func everyColumnOfARowStartsTheSameTransition() {
        var row = [GridSelectionBadgeMotion](repeating: GridSelectionBadgeMotion(), count: 20)
        for (time, y) in [(0.0, 380.0), (1.0, 430.0), (1.1, 430.0), (1.21, 430.0)] {
            var frames: [CGRect] = []
            for index in row.indices {
                let tile = CGRect(x: CGFloat(index) * 33.5, y: y, width: 32.5, height: 32.5)
                frames.append(
                    row[index].frame(
                        tile: tile, side: 11, inset: 3, regions: regions, now: time, reduceMotion: false))
            }
            #expect(Set(frames.map(\.minY)).count == 1)
            #expect(Set(row.map(\.isAnimating)).count == 1)
        }
    }

    @Test func reversalRetargetsFromTheCurrentPositionWithoutAJump() {
        var motion = GridSelectionBadgeMotion()
        _ = frame(&motion, y: 380, now: 0)
        _ = frame(&motion, y: 430, now: 1)
        let before = frame(&motion, y: 430, now: 1.08)
        let after = frame(&motion, y: 380, now: 1.08)
        #expect(before.offsetBy(dx: 0, dy: -50) == after)
        #expect(motion.isAnimating)
        let returned = frame(&motion, y: 380, now: 1.29)
        #expect(returned == ReservedRegionLayout.homeMarkRect(in: tile(380), side: 11, inset: 3))
    }

    @Test func theNoSpaceExceptionUsesTheColumnCenterAndAvoidsTheNeighborsMiddle() {
        for y in [448.0, 462.0] {
            let own = tile(y)
            let neighbors = [tile(y - 33.5), tile(y + 33.5)]
            var motion = GridSelectionBadgeMotion()
            let rect = motion.frame(
                tile: own, side: 11, inset: 3, regions: regions,
                neighboringTiles: neighbors, now: 0, reduceMotion: true)
            #expect(regions.isClear(rect))
            #expect(rect.midX == own.midX)
            #expect((own.midY < band.midY) == (rect.maxY <= band.minY))
            for neighbor in neighbors {
                let center = neighbor.insetBy(dx: neighbor.width * 0.3, dy: neighbor.height * 0.3)
                #expect(!center.contains(CGPoint(x: rect.midX, y: rect.midY)))
            }
        }
    }
    @Test func progressFromBelowSwitchesExactlyAtFortyPercentAndKeepsTheSafeZone() {
        var motion = GridSelectionBadgeMotion()
        func step(_ share: CGFloat, _ time: Double) {
            _ = motion.frame(
                tile: tile(band.maxY - share * 333, side: 333), side: 22, inset: 7,
                regions: regions, now: time, reduceMotion: true)
        }
        step(-0.1, 0)
        step(0.399, 1)
        #expect(!motion.usesAlternate)
        step(0.4, 2)
        #expect(motion.usesAlternate)
        for index in 0..<20 {
            step(index.isMultiple(of: 2) ? 0.399 : 0.401, Double(index + 3))
            #expect(motion.usesAlternate)
        }
        step(0.301, 30)
        #expect(motion.usesAlternate)
        step(0.299, 31)
        #expect(!motion.usesAlternate)
    }

    @Test func earlySwitchHysteresisUsesTheFixedLineRatherThanTheLastScrollStep() {
        var motion = GridSelectionBadgeMotion()
        _ = frame(&motion, y: 400, now: 0, reduceMotion: true)
        _ = frame(&motion, y: 430, now: 1, reduceMotion: true)
        #expect(motion.usesAlternate)
        _ = frame(&motion, y: 425.4, now: 2, reduceMotion: true)
        #expect(motion.usesAlternate, "This is only 0.1pt before the early line, inside the 4pt safe zone")
        _ = frame(&motion, y: 421.4, now: 3, reduceMotion: true)
        #expect(!motion.usesAlternate)
    }
    @Test func theExceptionUsesTheNearestClearBandEdgeWithoutAnExtraTileInset() {
        var motion = GridSelectionBadgeMotion()
        let rect = frame(&motion, y: 462, now: 0, reduceMotion: true)
        #expect(rect.minY == band.maxY)
        #expect(rect.midX == tile(462).midX)
        #expect(regions.isClear(rect))
    }
    @Test func resizingWithoutABandKeepsTheNormalCircleInsideItsCurrentTile() {
        var motion = GridSelectionBadgeMotion()
        for (index, extent) in [90.0, 54.0, 32.5, 54.0, 90.0].enumerated() {
            let tile = CGRect(x: 100, y: 200, width: extent, height: extent)
            let side = min(22, max(11, extent * 0.3))
            let inset = min(7, max(3, extent * 0.06))
            let rect = motion.frame(
                tile: tile, side: side, inset: inset, regions: .none,
                now: Double(index) * 0.05, reduceMotion: false)
            #expect(tile.contains(rect))
            #expect(rect == ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset))
            #expect(!motion.isAnimating, "Zoom geometry must not start a fold-slot slide")
        }
    }

    @Test func aBoundedStatusOcclusionDoesNotActLikeAVerticalDivision() {
        let occlusion = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: CGRect(x: 382, y: 0, width: 84, height: 170), isActive: true)],
            bounds: CGRect(x: 0, y: 80, width: 466, height: 510))
        var motion = GridSelectionBadgeMotion()
        for (step, y) in [180.0, 160.0, 140.0, 100.0, 80.0, 100.0, 140.0, 180.0].enumerated() {
            let tile = CGRect(x: 312, y: y, width: 154, height: 154)
            let home = ReservedRegionLayout.homeMarkRect(in: tile, side: 22, inset: 7)
            let rect = motion.frame(
                tile: tile, side: 22, inset: 7, regions: occlusion,
                now: Double(step), reduceMotion: true)
            #expect(occlusion.isClear(rect))
            #expect(rect == home, "A clear home below the bounded status area must not move")
        }
    }

    @Test func aBoundedOcclusionReleasesTheAlternateWhenTheHomeClears() {
        let occlusion = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: CGRect(x: 382, y: 0, width: 84, height: 170), isActive: true)],
            bounds: CGRect(x: 0, y: 80, width: 466, height: 510))
        var motion = GridSelectionBadgeMotion()
        for (step, y) in [100.0, 170.0, 210.0].enumerated() {
            let tile = CGRect(x: 400, y: y, width: 32.5, height: 32.5)
            let rect = motion.frame(
                tile: tile, side: 11, inset: 3, regions: occlusion,
                now: Double(step), reduceMotion: true)
            #expect(!rect.isNull, "Space below the bounded status area is usable")
            #expect(occlusion.isClear(rect))
            if y >= 170 {
                #expect(rect == ReservedRegionLayout.homeMarkRect(in: tile, side: 11, inset: 3))
                #expect(!motion.usesAlternate)
            }
        }
    }
    @Test func tinyTileUsesAClearEstablishedCornerBeforeTheFoldNoSpaceException() {
        let tiny = CGRect(x: 100, y: 200, width: 15.05, height: 15.05)
        let bounds = CGRect(x: 0, y: 80, width: 466, height: 510)
        let narrow = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: CGRect(x: 100, y: 0, width: 2, height: 678), isActive: true)],
            bounds: bounds)
        let covered = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: CGRect(x: 0, y: 199, width: 466, height: 18), isActive: true)],
            bounds: bounds)
        var motion = GridSelectionBadgeMotion()
        let home = motion.frame(
            tile: tiny, side: 11, inset: 3, regions: .none, now: 0, reduceMotion: true)
        #expect(tiny.contains(home), "The centre-rule exception alone must never trigger DANEBEN")
        #expect(!ReservedRegionLayout.markIsAtEdge(home, of: tiny))
        let inside = motion.frame(
            tile: tiny, side: 11, inset: 3, regions: narrow, now: 1, reduceMotion: true)
        #expect(tiny.contains(inside), "A clear established corner wins before the no-space exception")
        #expect(narrow.isClear(inside))
        #expect(inside.minX == tiny.minX + 3)
        let outside = motion.frame(
            tile: tiny, side: 11, inset: 3, regions: covered, now: 2, reduceMotion: true)
        #expect(!outside.isNull)
        #expect(!tiny.contains(outside), "DANEBEN applies only after the fold covers every in-tile corner")
        #expect(covered.isClear(outside))
        for rect in [home, inside, outside] { #expect(rect.size == CGSize(width: 11, height: 11)) }
    }

    @Test func tinyCornerExceptionStartsBelow18Point67Points() {
        for side: CGFloat in [15.05, 18.66, 18.68, 22.35, 32.5] {
            let tile = CGRect(x: 0, y: 0, width: side, height: side)
            let inset = ReservedRegionLayout.selectionMarkInset(in: tile, side: 11, preferred: 3)
            let mark = ReservedRegionLayout.homeMarkRect(in: tile, side: 11, inset: inset)
            #expect(tile.contains(mark))
            if side < 18.67 {
                #expect(inset == 3)
                #expect(!ReservedRegionLayout.markIsAtEdge(mark, of: tile))
            } else {
                #expect(inset >= 0.1)
                #expect(ReservedRegionLayout.markIsAtEdge(mark, of: tile))
            }
        }
    }

    @Test func stoppingAfterAFastCrossingNeverParksAnExpiredSlideInsideTheBand() {
        var motion = GridSelectionBadgeMotion()
        _ = frame(&motion, y: 380, now: 0)
        _ = frame(&motion, y: 430, now: 1)
        _ = frame(&motion, y: 470, now: 1.1)
        for time in [1.21, 1.3, 1.42, 1.7] {
            let rect = frame(&motion, y: 470, now: time)
            #expect(
                motion.isAnimating || regions.isClear(rect), "A stopped row cannot leave a resting circle in the band")
            #expect(rect.size == CGSize(width: 11, height: 11))
        }
        #expect(!motion.isAnimating)
        #expect(regions.isClear(motion.target))
    }
    @Test func aChangedBandRecomputesEntryDirectionBeforeApplyingHysteresis() {
        var motion = GridSelectionBadgeMotion()
        _ = frame(&motion, y: 462, now: 0, reduceMotion: true)
        let movedBand = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: band.offsetBy(dx: 0, dy: 35), isActive: true)],
            bounds: regions.bounds)
        _ = motion.frame(
            tile: tile(462), side: 11, inset: 3, regions: movedBand, now: 1, reduceMotion: true)
        #expect(motion.usesAlternate)
        _ = motion.frame(
            tile: tile(457.4), side: 11, inset: 3, regions: movedBand, now: 2, reduceMotion: true)
        #expect(motion.usesAlternate, "A new band must use its own entry direction and release margin")
        _ = motion.frame(
            tile: tile(456), side: 11, inset: 3, regions: movedBand, now: 3, reduceMotion: true)
        #expect(!motion.usesAlternate)
    }
    @Test func continuedReversalKeepsTheReleasedHomeSlotUntilTheRowLeavesTheBand() {
        for (extent, badge, inset, release): (CGFloat, CGFloat, CGFloat, CGFloat) in [
            (32.5, 11, 3, 0.26), (221, 22, 7, 0.299), (333, 22, 7, 0.299),
        ] {
            var motion = GridSelectionBadgeMotion()
            var time = 0.0
            func step(_ share: CGFloat, alternate: Bool) {
                let frame = tile(band.maxY - share * extent, side: extent)
                let rect = motion.frame(
                    tile: frame, side: badge, inset: inset, regions: regions,
                    now: time, reduceMotion: true)
                time += 1
                #expect(motion.usesAlternate == alternate, "extent=\(extent), share=\(share)")
                if !alternate {
                    #expect(rect == ReservedRegionLayout.homeMarkRect(in: frame, side: badge, inset: inset))
                }
            }
            step(-0.05, alternate: false)
            step(0.4, alternate: true)
            for share in [release, release - 0.01, release - 0.02, 0.1, 0.05, 0, -0.01] {
                step(share, alternate: false)
            }
        }
    }

    @Test func oneFrameCrossingClearsThePreviousBandDirection() {
        for (extent, badge, inset): (CGFloat, CGFloat, CGFloat) in [(32.5, 11, 3), (221, 22, 7), (333, 22, 7)] {
            var motion = GridSelectionBadgeMotion()
            var time = 0.0
            func step(y: CGFloat, alternate: Bool) {
                let frame = tile(y, side: extent)
                _ = motion.frame(
                    tile: frame, side: badge, inset: inset, regions: regions,
                    now: time, reduceMotion: true)
                time += 1
                #expect(motion.usesAlternate == alternate, "extent=\(extent), y=\(y)")
            }
            let above = band.minY - extent - 20
            let below = band.maxY + 20
            step(y: above, alternate: false)
            step(y: band.minY - extent + extent * 0.001, alternate: false)
            step(y: below, alternate: false)
            step(y: band.maxY - extent * 0.399, alternate: false)
            step(y: band.maxY - extent * 0.4, alternate: true)
            step(y: above, alternate: false)
            step(y: band.minY - extent + extent * 0.001, alternate: false)
            step(y: band.minY - extent + extent * 0.4, alternate: true)
        }
    }
}
