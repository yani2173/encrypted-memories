import CoreGraphics
import Foundation
import GridCore
import Metal
import MetalGridComposeCore
import MetalGridTextureAppKitAdapter
import MetalGridTextureCore
import MetalRenderingCore
import PhotosCore
import Testing
import TimelineCore

@Suite @MainActor struct GridSelectionBadgeComposerTests {
    private let band = CGRect(x: 0, y: 455, width: 669, height: 40)
    private let viewport = CGSize(width: 669, height: 951)
    private var regions: ReservedRegionLayout {
        ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: band, isActive: true)],
            bounds: CGRect(x: 0, y: 80, width: 669, height: 790))
    }

    // Existing avoidance regressions keep the non-tabletop occupation path pinned.
    private var tabletopRegions: ReservedRegionLayout {
        ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: band, isActive: true, isDivision: true)], bounds: regions.bounds)
    }

    private func hasBandFreeRightCorner(in tile: CGRect, side: CGFloat, inset: CGFloat) -> Bool {
        guard tile.height >= side + 2 * inset else { return false }
        return [false, true].contains { top in
            regions.isClear(ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset, top: top))
        }
    }

    private func cache(sizes: [CGSize] = [CGSize(width: 64, height: 64)]) throws -> MetalGridTextureCache<Int> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache: MetalGridTextureCache<Int> = try #require(
            MetalGridTextureCache(
                device: device,
                budget: GridTextureBudget(
                    maxUploadsPerFrame: 64, maxUploadBytesPerFrame: 64_000_000,
                    maxCachedTextures: 4096, maxResidentBytes: 256_000_000, overscanFraction: 1),
                maxTexturePixels: 64, glyphRasterizer: AppKitMetalGridGlyphRasterizer()))
        var images: [Int: CGImage] = [:]
        for (index, size) in sizes.enumerated() {
            let context = try #require(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            images[index] = try #require(context.makeImage())
        }
        let ids = Array(sizes.indices)
        for start in stride(from: 0, to: ids.count, by: 64) {
            cache.beginFrame(pinned: Set(ids))
            cache.uploadVisible(wanted: Array(ids[start..<min(start + 64, ids.count)])) { images[$0] }
        }
        try #require(ids.allSatisfy { cache.isResident($0) }, "Use real resident thumbnails")
        return cache
    }

    private func badge(
        tile: CGRect, selected: Bool, regions: ReservedRegionLayout, cache: MetalGridTextureCache<Int>
    ) throws -> MetalGridQuad {
        let output = MetalGridFrameComposer.buildGroups(
            slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)],
            flatUIDs: [0], cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
            decorations: MetalGridDecorations(
                accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                reservedRegions: regions))
        return try #require(output.groups.last?.quads.last)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerKeepsFilledAndEmptyCirclesFullClearAndAtEdgesAtEveryLevel() throws {
        let regions = tabletopRegions
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in profile.levels.indices {
            let geometry = engine.resolvedMetrics(level: level, width: viewport.width)
            for selected in [false, true] {
                let flatTile = CGRect(x: 100, y: 90, width: geometry.slotSide, height: geometry.slotSide)
                let normal = try badge(tile: flatTile, selected: selected, regions: .none, cache: cache)
                for y in stride(from: 90.0, through: 800.0 - geometry.slotSide, by: 3) {
                    let tile = CGRect(x: 100, y: y, width: geometry.slotSide, height: geometry.slotSide)
                    let mark = try badge(tile: tile, selected: selected, regions: regions, cache: cache)
                    #expect(mark.rect.size == normal.rect.size)
                    #expect(mark.rect.width == mark.rect.height)
                    #expect(mark.uvMin == SIMD2<Float>(0, 0))
                    #expect(mark.uvMax == SIMD2<Float>(1, 1))
                    #expect(mark.alpha == 1)
                    #expect(regions.bounds.contains(mark.rect))
                    if hasBandFreeRightCorner(
                        in: tile, side: normal.rect.width, inset: flatTile.maxX - normal.rect.maxX)
                    {
                        #expect(regions.isClear(mark.rect), "level=\(level), y=\(y), selected=\(selected)")
                    }
                    let middle = tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.3)
                    #expect(!middle.contains(CGPoint(x: mark.rect.midX, y: mark.rect.midY)))
                }
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func composerForwardsItsRealMetricsAndDrawsTheWholeMovingCircleAboveThePhoto() throws {
        let regions = tabletopRegions
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in [0, 3, 5] {
            for selected in [false, true] {
                let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
                let layout = GridSelectionBadgeLayout()
                var motion = GridSelectionBadgeMotion()
                var calls = 0
                var time = 0.0
                func compose(y: CGFloat) throws -> MetalGridQuad {
                    let tile = CGRect(x: 100, y: y, width: metrics.slotSide, height: metrics.slotSide)
                    let output = MetalGridFrameComposer.buildGroups(
                        slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)],
                        flatUIDs: [0], cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                        decorations: MetalGridDecorations(
                            accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                            selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                            reservedRegions: regions, selectionBadgeLayout: layout,
                            selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                                calls += 1
                                return motion.frame(
                                    tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                    neighboringTiles: neighbors, row: row, layout: layout, now: time,
                                    reduceMotion: false)
                            }))
                    return try #require(output.groups.last?.quads.last)
                }
                let normal = try compose(y: 90)
                time = 1
                let start = try compose(y: 450)
                time = 1.1
                let middle = try compose(y: 450)
                time = 1.21
                let end = try compose(y: 450)
                #expect(calls == 4, "The production composer must forward its actual sizing and frames")
                #expect(middle.rect != start.rect && middle.rect != end.rect)
                let tile = CGRect(x: 100, y: 450, width: metrics.slotSide, height: metrics.slotSide)
                if hasBandFreeRightCorner(in: tile, side: end.rect.width, inset: tile.maxX - end.rect.maxX) {
                    #expect(regions.isClear(end.rect))
                }
                for quad in [start, middle, end] {
                    #expect(quad.rect.size == normal.rect.size)
                    #expect(quad.rect.width == quad.rect.height)
                    #expect(tile.contains(quad.rect), "An available in-tile path stays in its own thumbnail")
                    #expect(quad.uvMin == SIMD2<Float>(0, 0) && quad.uvMax == SIMD2<Float>(1, 1))
                    #expect(quad.alpha == 1)
                }
                #expect(abs(middle.rect.midX - (start.rect.midX + end.rect.midX) / 2) < 0.001)
                #expect(abs(middle.rect.midY - (start.rect.midY + end.rect.midY) / 2) < 0.001)
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func timedCoreRestingSlotsStayClearThroughoutTheRealProductionLadder() throws {
        let regions = tabletopRegions
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in profile.levels.indices {
            let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
            let reference = CGRect(x: 100, y: 90, width: metrics.slotSide, height: metrics.slotSide)
            let normal = try badge(tile: reference, selected: false, regions: .none, cache: cache)
            let side = normal.rect.width
            let inset = reference.maxY - normal.rect.maxY
            for reversed in [false, true] {
                var motion = GridSelectionBadgeMotion()
                let steps = Array(stride(from: 90.0, through: 800.0 - metrics.slotSide, by: 1))
                for (step, y) in (reversed ? steps.reversed().map { $0 } : steps).enumerated() {
                    let tile = CGRect(x: 100, y: y, width: metrics.slotSide, height: metrics.slotSide)
                    let neighbors = [
                        tile.offsetBy(dx: 0, dy: -metrics.pitch), tile.offsetBy(dx: 0, dy: metrics.pitch),
                    ]
                    let rect = motion.frame(
                        tile: tile, side: side, inset: inset, regions: regions,
                        neighboringTiles: neighbors, now: Double(step), reduceMotion: true)
                    if hasBandFreeRightCorner(in: tile, side: side, inset: inset) {
                        #expect(regions.isClear(rect), "level=\(level), y=\(y), reverse=\(reversed)")
                    }
                    #expect(regions.bounds.contains(rect))
                    #expect(rect.size == normal.rect.size)
                    let middle = tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.3)
                    #expect(!middle.contains(CGPoint(x: rect.midX, y: rect.midY)))
                    if !tile.contains(rect) {
                        for neighbor in neighbors {
                            let middle = neighbor.insetBy(dx: neighbor.width * 0.3, dy: neighbor.height * 0.3)
                            #expect(
                                !middle.contains(CGPoint(x: rect.midX, y: rect.midY)),
                                "The no-space exception must not enter a neighbouring thumbnail's middle")
                        }
                    }
                }
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func normalScrollingOfTheProductionDenseFrameKeepsTheBadgeClear() throws {
        let regions = tabletopRegions
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let plan = engine.framePlan(
            level: profile.levels.count - 1, viewportSize: viewport,
            scrollOffset: CGPoint(x: 0, y: 1012), overscan: 0)
        let witness = try #require(plan.visibleSlots.first { band.contains($0.viewportRect) })
        #expect(witness.index == 880)
        #expect(witness.viewportRect == CGRect(x: 0, y: 462, width: 32.5, height: 32.5))
        for selected in [false, true] {
            let circle = try badge(tile: witness.viewportRect, selected: selected, regions: regions, cache: cache)
            if hasBandFreeRightCorner(
                in: witness.viewportRect, side: circle.rect.width, inset: witness.viewportRect.maxX - circle.rect.maxX)
            {
                #expect(regions.isClear(circle.rect))
            }
            #expect(witness.viewportRect.contains(circle.rect), "ECKEN keeps even this extreme tile's circle inside")
            #expect(regions.bounds.contains(circle.rect))
            #expect(circle.rect.width == circle.rect.height)
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func outerDisplayDenseCirclesUseEdgeInsetsWithoutChangingSizeOrDensity() throws {
        let cache = try cache()
        let width: CGFloat = 466
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let metrics = engine.resolvedMetrics(level: profile.levels.count - 1, width: width)
        #expect(metrics.slotSide == 22.35)
        let tile = CGRect(x: 100, y: 200, width: metrics.slotSide, height: metrics.slotSide)
        for selected in [false, true] {
            let quad = try badge(tile: tile, selected: selected, regions: .none, cache: cache)
            #expect(quad.rect.size == CGSize(width: 11, height: 11))
            #expect(tile.insetBy(dx: 0.5, dy: 0.5).contains(quad.rect))
            #expect(ReservedRegionLayout.markIsAtEdge(quad.rect, of: tile))
            #expect(quad.uvMin == SIMD2<Float>(0, 0) && quad.uvMax == SIMD2<Float>(1, 1))
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func theFineInsetAndTinyTileExceptionUseTheRealProductionLadder() throws {
        let cache = try cache()
        // Below 18.67pt, an 11pt circle with a 0.1pt inset cannot put its centre outside the inner 40%.
        let tinyTileThreshold: CGFloat = 18.67
        for width: CGFloat in [320, 393, 466, 669, 1024] {
            let profile = TimelineGridProfileConfiguration.production.resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
            let engine = SquareTileGridEngine(
                sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
            for level in profile.levels.indices {
                let metrics = engine.resolvedMetrics(level: level, width: width)
                let tile = CGRect(x: 100, y: 200, width: metrics.slotSide, height: metrics.slotSide)
                for selected in [false, true] {
                    let quad = try badge(tile: tile, selected: selected, regions: .none, cache: cache)
                    #expect(tile.contains(quad.rect), "The full circle must not be clipped")
                    let inset = tile.maxY - quad.rect.maxY
                    if metrics.slotSide < tinyTileThreshold {
                        #expect(inset == 3, "BESTAND: only impossible tiny tiles retain the established corner")
                        #expect(!ReservedRegionLayout.markIsAtEdge(quad.rect, of: tile))
                    } else {
                        #expect(inset >= 0.1 - 0.00001)
                        #expect(ReservedRegionLayout.markIsAtEdge(quad.rect, of: tile))
                        if metrics.slotSide >= 28.34 { #expect(inset >= 3) }
                    }
                    if width == 393 && level == profile.levels.count - 1 {
                        #expect(abs(inset - 0.109) < 0.00001)
                        #expect(quad.rect.size == CGSize(width: 11, height: 11))
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerMotionKeepsCirclesInsideEachZoomGeometry() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for selected in [false, true] {
            let layout = GridSelectionBadgeLayout()
            var motion = GridSelectionBadgeMotion()
            for (step, level) in [3, 5, 0, 5, 3].enumerated() {
                let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
                let tile = CGRect(x: 100, y: 200, width: metrics.slotSide, height: metrics.slotSide)
                let normal = try badge(tile: tile, selected: selected, regions: .none, cache: cache)
                let output = MetalGridFrameComposer.buildGroups(
                    slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)], flatUIDs: [0],
                    cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                        selectionBadgeLayout: layout,
                        selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                            motion.frame(
                                tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout, now: Double(step) * 0.05,
                                reduceMotion: false)
                        }))
                let circle = try #require(output.groups.last?.quads.last)
                #expect(circle.rect == normal.rect)
                #expect(tile.contains(circle.rect))
                #expect(!motion.isAnimating)
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aspectFitRowSwitchesTogetherDespiteDifferentThumbnailHeights() throws {
        let cache = try cache(sizes: [
            CGSize(width: 64, height: 64), CGSize(width: 64, height: 48), CGSize(width: 64, height: 36),
        ])
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let metrics = engine.resolvedMetrics(level: 1, width: viewport.width)
        for reversed in [false, true] {
            let layout = GridSelectionBadgeLayout()
            var motions = [GridSelectionBadgeMotion(), GridSelectionBadgeMotion(), GridSelectionBadgeMotion()]
            let entry = reversed ? band.maxY : band.minY - metrics.slotSide
            let ys: [CGFloat] =
                reversed
                ? [700, entry - 0.40 * metrics.slotSide, entry - 0.45 * metrics.slotSide, 700]
                : [90, entry + 8, entry + 40, 90]
            for (step, y) in ys.enumerated() {
                let slots = (0..<3).map {
                    GridRenderSlot(
                        index: $0, column: $0, row: 0,
                        rect: CGRect(
                            x: CGFloat($0) * metrics.pitch, y: y,
                            width: metrics.slotSide, height: metrics.slotSide))
                }
                let output = MetalGridFrameComposer.buildGroups(
                    slots: slots, flatUIDs: [0, 1, 2], cache: cache, displayMode: .aspectFitInsideSquare,
                    cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: [0], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                        selectionBadgeLayout: layout,
                        selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                            motions[uid].frame(
                                tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout, now: Double(step),
                                reduceMotion: true)
                        }))
                #expect(
                    Set(motions.map(\.usesAlternate)).count == 1,
                    "One row must switch together: reverse=\(reversed), y=\(y)")
                for group in output.groups where group.quads.first?.rect.width == 22 {
                    for quad in group.quads { #expect(regions.isClear(quad.rect)) }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func denseScrollFrameKeepsTheNoSpaceSearchWithinOneFrameBudget() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        var motions: [Int: GridSelectionBadgeMotion] = [:]
        let clock = ContinuousClock()
        let layout = GridSelectionBadgeLayout()
        var measurements: [Double] = []
        var noSpaceCount = 0
        for step in 0..<4 {
            let plan = engine.framePlan(
                level: profile.levels.count - 1, viewportSize: viewport,
                scrollOffset: CGPoint(x: 0, y: 1012 + step), overscan: 0)
            let slots = plan.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            }
            noSpaceCount = plan.visibleSlots.filter { band.contains($0.viewportRect) }.count
            var searchMilliseconds = 0.0
            let start = clock.now
            let output = MetalGridFrameComposer.buildGroups(
                slots: slots, flatUIDs: Array(0..<4_000), cache: cache, displayMode: .squareFillCrop,
                cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                        var motion = motions[uid] ?? GridSelectionBadgeMotion()
                        let searchStart = clock.now
                        let result = motion.frame(
                            tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout, now: Double(step), reduceMotion: true
                        )
                        if band.contains(tile) {
                            let elapsed = searchStart.duration(to: clock.now).components
                            searchMilliseconds +=
                                Double(elapsed.seconds) * 1_000
                                + Double(elapsed.attoseconds) / 1e15
                        }
                        motions[uid] = motion
                        return result
                    }))
            let elapsed = start.duration(to: clock.now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            if step > 0 { measurements.append(milliseconds) }
            print(
                "DENSE_FRAME sample=\(step) slots=\(slots.count) noSpace=\(noSpaceCount) wallMs=\(milliseconds) noSpaceSearchMs=\(searchMilliseconds)"
            )
            #expect(!output.groups.isEmpty)
        }
        #expect(layout.preparationCount == 1, "Scrolling within one visible-row bucket reuses prepared facts")
        #expect(noSpaceCount == 20, "The measurement must include one full no-space row")
        let average = measurements.reduce(0, +) / Double(measurements.count)
        print("DENSE_FRAME meanMs=\(average)")
        #expect(average < 1000.0 / 60.0, "A warmed dense scroll frame must fit the 60Hz budget")
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func preparedGeometryReusesScrollTranslationsAndInvalidatesRowBandAndSizeChanges() throws {
        let cache = try cache()
        let layout = GridSelectionBadgeLayout()
        func compose(width: CGFloat, offset: CGFloat, band: CGRect) {
            let viewport = CGSize(width: width, height: 951)
            let profile = TimelineGridProfileConfiguration.production.resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
            let engine = SquareTileGridEngine(
                sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
            let plan = engine.framePlan(
                level: profile.levels.count - 1, viewportSize: viewport,
                scrollOffset: CGPoint(x: 0, y: offset), overscan: 0)
            _ = MetalGridFrameComposer.buildGroups(
                slots: plan.visibleSlots.map {
                    GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
                }, flatUIDs: Array(0..<4_000), cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty },
                    reservedRegions: ReservedRegionLayout(
                        areas: [ReservedRegionArea(frame: band, isActive: true)],
                        bounds: CGRect(origin: .zero, size: viewport)), selectionBadgeLayout: layout))
        }
        compose(width: 669, offset: 1012, band: band)
        #expect(layout.preparationCount == 1)
        compose(width: 669, offset: 1012.25, band: band)
        #expect(layout.preparationCount == 1, "A fractional scroll translates the cached row facts")
        compose(width: 669, offset: 1013, band: band)
        #expect(layout.preparationCount == 1)
        compose(width: 669, offset: 1046, band: band)
        #expect(layout.preparationCount == 2, "A newly visible row invalidates the row bucket")
        let changedBand = band.offsetBy(dx: 0, dy: 10)
        compose(width: 669, offset: 1046, band: changedBand)
        #expect(layout.preparationCount == 3, "A changed band invalidates candidates and row facts")
        compose(width: 466, offset: 1046, band: CGRect(x: 0, y: 465, width: 466, height: 40))
        #expect(layout.preparationCount == 4, "Changed tile size and usable geometry invalidate the cache")
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aStoppedRowKeepsOneDecisionWhileItsAspectFitThumbnailsArrive() throws {
        let cache = try cache(sizes: [])
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let metrics = engine.resolvedMetrics(level: 1, width: viewport.width)
        var motions = [GridSelectionBadgeMotion(), GridSelectionBadgeMotion(), GridSelectionBadgeMotion()]
        var homes = Array(repeating: CGRect.zero, count: 3)
        let layout = GridSelectionBadgeLayout()
        for step in 0..<5 {
            if step >= 2 {
                let uid = step - 2
                cache.beginFrame(pinned: [0, 1, 2])
                cache.uploadVisible(wanted: [uid]) { _ in image }
                #expect(cache.isResident(uid), "A real landscape texture must replace its square placeholder")
            }
            let y: CGFloat = step == 0 ? 90 : band.minY - metrics.slotSide + 8
            _ = MetalGridFrameComposer.buildGroups(
                slots: (0..<3).map {
                    GridRenderSlot(
                        index: $0, column: $0, row: 0,
                        rect: CGRect(
                            x: CGFloat($0) * metrics.pitch, y: y,
                            width: metrics.slotSide, height: metrics.slotSide))
                }, flatUIDs: [0, 1, 2], cache: cache, displayMode: .aspectFitInsideSquare, cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [0], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                        homes[uid] = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
                        return motions[uid].frame(
                            tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout,
                            now: Double(step), reduceMotion: true)
                    }))
            #expect(
                Set(motions.map(\.usesAlternate)).count == 1,
                "A stopped row cannot split its switch decision on arrival")
            if step > 0 {
                #expect(
                    motions.allSatisfy { $0.usesAlternate }, "Holding still inside hysteresis keeps the row's decision")
                for uid in 0..<3 { #expect(motions[uid].target != homes[uid]) }
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerContinuedReversalKeepsEveryReleasedCircleHome() throws {
        try verifyContinuedReversal(jumping: false)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerOneFrameCrossingStartsTheNextEntryFromTheCorrectEdge() throws {
        try verifyContinuedReversal(jumping: true)
    }

    private func verifyContinuedReversal(jumping: Bool) throws {
        let cache = try cache(sizes: Array(repeating: CGSize(width: 64, height: 64), count: 40))
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in profile.levels.indices {
            let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
            let initial = engine.framePlan(level: level, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
            let row = try #require(initial.visibleSlots.first { $0.column == 0 && $0.row > 0 })
            let rowSlots = initial.visibleSlots.filter { $0.row == row.row }
            try #require(rowSlots.count == metrics.columns)
            for selected in [false, true] {
                var motions: [Int: GridSelectionBadgeMotion] = [:]
                var homes: [Int: CGRect] = [:]
                let layout = GridSelectionBadgeLayout()
                var time = 0.0
                func step(y: CGFloat, alternate: Bool, crossingSide: Bool = true) {
                    var offset = row.slotRect.minY - y
                    // Keep the inclusive switch sample across the line after viewport-coordinate rounding.
                    let belowSwitchLine = band.maxY - metrics.slotSide * 0.4
                    if y == belowSwitchLine { offset = crossingSide ? offset.nextUp : offset.nextDown }
                    if y == band.minY - metrics.slotSide + metrics.slotSide * 0.4 { offset = offset.nextDown }
                    let plan = engine.framePlan(
                        level: level, viewportSize: viewport,
                        scrollOffset: CGPoint(x: 0, y: offset), overscan: 0)
                    let slots = plan.visibleSlots.filter { $0.row == row.row }.map {
                        GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
                    }
                    #expect(slots.count == metrics.columns)
                    #expect(slots.allSatisfy { abs($0.rect.minY - y) < 0.000_000_001 })
                    if y == belowSwitchLine {
                        #expect(slots.allSatisfy { crossingSide ? $0.rect.minY <= y : $0.rect.minY > y })
                    }
                    _ = MetalGridFrameComposer.buildGroups(
                        slots: slots, flatUIDs: Array(0..<4_000), cache: cache, displayMode: .squareFillCrop,
                        cornerRadius: 11,
                        decorations: MetalGridDecorations(
                            accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                            selected: selected ? Set(rowSlots.map(\.index)) : [], favorites: [],
                            overlay: { _ in .empty },
                            reservedRegions: regions, selectionBadgeLayout: layout,
                            selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                                homes[uid] = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
                                var motion = motions[uid] ?? GridSelectionBadgeMotion()
                                let rect = motion.frame(
                                    tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                                    neighboringTiles: neighbors, row: row, layout: layout, now: time, reduceMotion: true
                                )
                                motions[uid] = motion
                                return rect
                            }))
                    time += 1
                    #expect(motions.count == metrics.columns)
                    #expect(
                        motions.values.allSatisfy { $0.usesAlternate == alternate },
                        "level=\(level), y=\(y), jumping=\(jumping), selected=\(selected)")
                    if !alternate {
                        #expect(
                            motions.allSatisfy { homes[$0.key] == $0.value.target },
                            "A released row must keep every full circle in its normal slot")
                    }
                }
                let above = band.minY - metrics.slotSide - 20
                let below = band.maxY + 20
                if jumping {
                    step(y: above, alternate: false)
                    step(y: band.minY - metrics.slotSide + metrics.slotSide * 0.001, alternate: false)
                    step(y: below, alternate: false)
                    step(y: band.maxY - metrics.slotSide * 0.399, alternate: false)
                    if metrics.columns == 7 {
                        step(y: band.maxY - metrics.slotSide * 0.4, alternate: false, crossingSide: false)
                    }
                    step(y: band.maxY - metrics.slotSide * 0.4, alternate: true)
                    step(y: above, alternate: false)
                    step(y: band.minY - metrics.slotSide + metrics.slotSide * 0.001, alternate: false)
                    step(y: band.minY - metrics.slotSide + metrics.slotSide * 0.4, alternate: true)
                } else {
                    step(y: below, alternate: false)
                    if metrics.columns == 7 {
                        step(y: band.maxY - metrics.slotSide * 0.4, alternate: false, crossingSide: false)
                    }
                    step(y: band.maxY - metrics.slotSide * 0.4, alternate: true)
                    let release = 0.4 - max(0.1, 4 / metrics.slotSide) - 0.001
                    for share in [release, release - 0.01, release - 0.02, 0.1, 0.05, 0, -0.01] {
                        step(y: band.maxY - metrics.slotSide * share, alternate: false)
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aSubQuantumRowHeightChangeKeepsHysteresisAndThePreparedCache() throws {
        let cache = try cache(sizes: Array(repeating: CGSize(width: 64, height: 64), count: 40))
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [3_600], profile: profile, fillOrder: .newestBottomTrailing)
        let plan = engine.framePlan(level: 3, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let first = try #require(plan.visibleSlots.first { $0.column == 0 && $0.row > 0 })
        let row = plan.visibleSlots.filter { $0.row == first.row }
        try #require(row.count == 7)
        let layout = GridSelectionBadgeLayout()
        var motions: [Int: GridSelectionBadgeMotion] = [:]
        var time = 0.0
        func step(share: CGFloat, heightChange: CGFloat = 0, alternate: Bool) {
            let slots = row.map { slot in
                GridRenderSlot(
                    index: slot.index, column: slot.column, row: slot.row,
                    rect: CGRect(
                        x: slot.viewportRect.minX, y: band.maxY - first.slotRect.height * share,
                        width: slot.viewportRect.width, height: slot.viewportRect.height + heightChange))
            }
            _ = MetalGridFrameComposer.buildGroups(
                slots: slots, flatUIDs: Array(0..<3_600), cache: cache, displayMode: .squareFillCrop,
                cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                        var motion = motions[uid] ?? GridSelectionBadgeMotion()
                        _ = motion.frame(
                            tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout, now: time, reduceMotion: true)
                        motions[uid] = motion
                        return motion.target
                    }))
            time += 1
            #expect(motions.count == 7)
            #expect(motions.values.allSatisfy { $0.usesAlternate == alternate })
        }
        step(share: -0.05, alternate: false)
        step(share: 0.41, alternate: true)
        step(share: 0.35, alternate: true)
        let preparations = layout.preparationCount
        for change in [0.000_000_1, 0.000_000_2, 0, 0.000_000_1, 0] {
            step(share: 0.35, heightChange: change, alternate: true)
            #expect(layout.preparationCount == preparations)
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func tabletopScrollUsesOnlyRightCornersAndOneVerticalSwitchInEachDirection() throws {
        let regions = tabletopRegions
        let sizes = (0..<240).map { index in
            [CGSize(width: 64, height: 64), CGSize(width: 64, height: 48), CGSize(width: 48, height: 64)][index % 3]
        }
        let cache = try cache(sizes: sizes)
        for fit in [false, true] {
            let profile = TimelineGridProfileConfiguration.production.resolver.profile(
                for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
            let engine = SquareTileGridEngine(sectionCounts: [240], profile: profile, fillOrder: .newestBottomTrailing)
            let initial = engine.framePlan(
                level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 1_000), overscan: 0)
            let witness = try #require(initial.visibleSlots.first { $0.column == 0 && $0.viewportRect.minY > 200 })
            try #require(engine.resolvedMetrics(level: 2, width: viewport.width).columns == 5)
            let layout = GridSelectionBadgeLayout()
            var motions: [Int: GridSelectionBadgeMotion] = [:]
            var xViolations: [String] = []
            var cornerViolations: [String] = []
            var partViolations: [String] = []
            var previousCorner: [Int: Bool] = [:]
            var switches: [Int: Int] = [:]
            var trace =
                "frame,time,uid,tileX,tileY,tileW,tileH,side,edgeInset,centerFromRight,edgeGap,yFromTop,animating,targetCorner,part\n"
            for frame in 0..<582 {
                let time = Double(frame) / 60
                let fraction = CGFloat(min(frame, 581 - frame)) / 290
                let y = 120 + 580 * fraction
                let plan = engine.framePlan(
                    level: 2, viewportSize: viewport,
                    scrollOffset: CGPoint(x: 0, y: witness.slotRect.minY - y), overscan: 0)
                let slots = plan.visibleSlots.map {
                    GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
                }
                let visible = Set(slots.map(\.index))
                motions = motions.filter { visible.contains($0.key) }
                _ = MetalGridFrameComposer.buildGroups(
                    slots: slots, flatUIDs: Array(0..<240), cache: cache,
                    displayMode: fit ? .aspectFitInsideSquare : .squareFillCrop, cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: Set(stride(from: 0, to: 240, by: 2)), favorites: [], overlay: { _ in .empty },
                        reservedRegions: regions, selectionBadgeLayout: layout,
                        selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                            var motion = motions[uid] ?? GridSelectionBadgeMotion()
                            let rect = motion.frame(
                                tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout, now: time, reduceMotion: false)
                            motions[uid] = motion
                            let top = CGRect(
                                x: tile.maxX - inset - side, y: tile.minY + inset, width: side, height: side)
                            let bottom = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
                            let atTop = abs(motion.target.minY - top.minY) < 0.000_000_01
                            let atBottom = abs(motion.target.minY - bottom.minY) < 0.000_000_01
                            let part =
                                (row?.frame ?? tile).maxY < band.minY
                                ? "upper" : ((row?.frame ?? tile).minY > band.maxY ? "lower" : "crossing")
                            let key = "frame=\(frame),uid=\(uid)"
                            if abs(tile.maxX - rect.maxX - inset) > 0.000_000_01 || rect.midX < tile.midX {
                                xViolations.append(key)
                            }
                            if !atTop && !atBottom
                                || (!motion.isAnimating && abs(rect.minY - top.minY) > 0.000_000_01
                                    && abs(rect.minY - bottom.minY) > 0.000_000_01)
                            {
                                cornerViolations.append(key)
                            }
                            if part == "upper" && !atTop || part == "lower" && !atBottom { partViolations.append(key) }
                            if uid >= witness.index && uid < witness.index + 5, atTop || atBottom {
                                if let previous = previousCorner[uid], previous != atBottom {
                                    switches[uid, default: 0] += 1
                                }
                                previousCorner[uid] = atBottom
                            }
                            trace +=
                                "\(frame),\(time),\(uid),\(tile.minX),\(tile.minY),\(tile.width),\(tile.height),\(side),\(inset),\(rect.midX-tile.maxX),\(tile.maxX-rect.maxX),\(rect.midY-tile.minY),\(motion.isAnimating),\(atTop ? "top" : (atBottom ? "bottom" : "other")),\(part)\n"
                            return rect
                        }))
            }
            if let directory = ProcessInfo.processInfo.environment["GRID_BADGE_TRACE_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try trace.write(
                    to: folder.appendingPathComponent(fit ? "aspect-fit.csv" : "square.csv"), atomically: true,
                    encoding: .utf8)
                try (xViolations + cornerViolations + partViolations).joined(separator: "\n").write(
                    to: folder.appendingPathComponent(fit ? "aspect-fit-violations.txt" : "square-violations.txt"),
                    atomically: true, encoding: .utf8)
            }
            print(
                "TWO_CORNERS fit=\(fit) x=\(xViolations.count) corner=\(cornerViolations.count) part=\(partViolations.count) switches=\(switches)"
            )
            #expect(xViolations.isEmpty, "Every frame must keep the normal right inset: \(xViolations.prefix(6))")
            #expect(
                cornerViolations.isEmpty,
                "Only top-right/bottom-right targets and timed intermediate positions: \(cornerViolations.prefix(6))")
            #expect(partViolations.isEmpty, "Upper is top-right; lower stays bottom-right: \(partViolations.prefix(6))")
            #expect((witness.index..<(witness.index + 5)).allSatisfy { switches[$0] == 2 }, "One switch each direction")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func noHorizontalFoldKeepsTheEstablishedBottomRightCircle() throws {
        let cache = try cache()
        for size in [
            CGSize(width: 393, height: 852), CGSize(width: 1_024, height: 1_366), CGSize(width: 1_440, height: 900),
            CGSize(width: 669, height: 951), CGSize(width: 466, height: 678),
        ] {
            let tile = CGRect(x: 40, y: 100, width: 132.2, height: 132.2)
            let bounds = CGRect(origin: .zero, size: size)
            for areas in [
                [], [ReservedRegionArea(frame: CGRect(x: 0, y: 450, width: size.width, height: 40), isActive: false)],
                [
                    ReservedRegionArea(
                        frame: CGRect(x: size.width - 30, y: 0, width: 20, height: size.height), isActive: true,
                        isDivision: true)
                ],
            ] {
                let region = ReservedRegionLayout(areas: areas, bounds: bounds)
                let mark = try badge(tile: tile, selected: false, regions: region, cache: cache)
                let flat = try badge(tile: tile, selected: false, regions: .none, cache: cache)
                #expect(mark.rect == flat.rect, "No active horizontal fold preserves the existing position")
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func syntheticHorizontalFoldOnDifferentGeometryUsesTheSameRightCorners() throws {
        let cache = try cache()
        let size = CGSize(width: 900, height: 760)
        let fold = CGRect(x: 0, y: 270, width: 900, height: 30)
        let region = ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: fold, isActive: true, isDivision: true)],
            bounds: CGRect(origin: .zero, size: size))
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: size.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [240], profile: profile, fillOrder: .newestBottomTrailing)
        let side = engine.resolvedMetrics(level: 2, width: size.width).slotSide
        for y: CGFloat in [80, 500] {
            let tile = CGRect(x: 40, y: y, width: side, height: side)
            let flat = try badge(tile: tile, selected: false, regions: .none, cache: cache)
            let actual = try badge(tile: tile, selected: false, regions: region, cache: cache)
            let inset = tile.maxX - flat.rect.maxX
            #expect(actual.rect.minX == flat.rect.minX)
            #expect(actual.rect.minY == (tile.midY < fold.midY ? tile.minY + inset : flat.rect.minY))
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func extremeTabletopTileKeepsOnlyItsRightCornersWithOneSwitchAndHysteresis() throws {
        let regions = tabletopRegions
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [3_600], profile: profile, fillOrder: .newestBottomTrailing)
        let extent = engine.resolvedMetrics(level: profile.levels.count - 1, width: viewport.width).slotSide
        #expect(extent < band.height)
        for selected in [false, true] {
            let layout = GridSelectionBadgeLayout()
            var motion = GridSelectionBadgeMotion()
            var switches = 0
            var previous: Bool?
            let line = band.minY - extent + extent * GridSelectionBadgeMotion.switchShare
            let ys: [CGFloat] = [
                380, line - 1, line, line - 0.1, line + 0.1, 441.1, 440.9, 441.1, 440.9,
                445, 444.9, 445.1, 462, 510, 510, band.maxY - extent * 0.4,
                band.maxY - extent * 0.4 + 0.1, band.maxY - extent * 0.4 - 0.1, 473, 472, 472.1, 471.9, 462, 380,
            ]
            for (step, y) in ys.enumerated() {
                let tile = CGRect(x: 100, y: y, width: extent, height: extent)
                _ = MetalGridFrameComposer.buildGroups(
                    slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)], flatUIDs: [0],
                    cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                        reservedRegions: regions, selectionBadgeLayout: layout,
                        selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                            let rect = motion.frame(
                                tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout,
                                now: Double(step), reduceMotion: true)
                            let top = ReservedRegionLayout.homeMarkRect(in: frame, side: side, inset: inset, top: true)
                            let bottom = ReservedRegionLayout.homeMarkRect(in: frame, side: side, inset: inset)
                            #expect(
                                rect == top || rect == bottom, "ECKEN wins even when both corners intersect the fold")
                            #expect(rect.minX == bottom.minX)
                            #expect(frame.contains(rect))
                            #expect(rect.size == CGSize(width: side, height: side))
                            #expect(!motion.isAnimating, "Reduce Motion has no intermediate presentation")
                            let atBottom = rect == bottom
                            if let previous, previous != atBottom { switches += 1 }
                            previous = atBottom
                            if band.contains(frame) { #expect(!regions.isClear(rect), "Explicit extreme-case overlap") }
                            return rect
                        }))
            }
            #expect(switches == 2, "One switch each direction, including jitter in the safe zone")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func tabletopChoosesABandFreeRightCornerWheneverOneExists() throws {
        let regions = tabletopRegions
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [3_600], profile: profile, fillOrder: .newestBottomTrailing)
        for level in [2, 3, 5] {
            let extent = engine.resolvedMetrics(level: level, width: viewport.width).slotSide
            if level == 2 { #expect(abs(extent - 131.8) < 0.000_000_001) }
            let layout = GridSelectionBadgeLayout()
            var motion = GridSelectionBadgeMotion()
            var violations: [String] = []
            var switches = 0
            var previous: Bool?
            let down = Array(stride(from: 90.0, through: 700.0, by: 1))
            let ys = down + down.reversed()
            for (step, y) in ys.enumerated() {
                let tile = CGRect(x: 100, y: y, width: extent, height: extent)
                _ = MetalGridFrameComposer.buildGroups(
                    slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)], flatUIDs: [0],
                    cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: [], favorites: [], overlay: { _ in .empty },
                        reservedRegions: regions, selectionBadgeLayout: layout,
                        selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                            let rect = motion.frame(
                                tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout,
                                now: Double(step), reduceMotion: true)
                            let top = ReservedRegionLayout.homeMarkRect(in: frame, side: side, inset: inset, top: true)
                            let bottom = ReservedRegionLayout.homeMarkRect(in: frame, side: side, inset: inset)
                            if regions.isClear(top) || regions.isClear(bottom) {
                                if !regions.isClear(rect) { violations.append("level=\(level),y=\(y),rect=\(rect)") }
                            }
                            #expect(rect == top || rect == bottom)
                            if let previous, previous != motion.usesAlternate { switches += 1 }
                            previous = motion.usesAlternate
                            // A stopped row never changes its decision, including the borderline no-common-range case.
                            let repeated = motion.frame(
                                tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout,
                                now: Double(step) + 0.5, reduceMotion: true)
                            #expect(repeated == rect)
                            return rect
                        }))
            }
            #expect(violations.isEmpty, "A free right corner wins: \(violations.prefix(5))")
            #expect(switches == 2, "Only one switch each direction")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func noHorizontalFoldKeepsTheEstablishedPositionAfterLeavingTabletop() throws {
        let cache = try cache()
        let tile = CGRect(x: 100, y: 200, width: 131.8, height: 131.8)
        let normal = try badge(tile: tile, selected: false, regions: .none, cache: cache)
        let layout = GridSelectionBadgeLayout()
        var motion = GridSelectionBadgeMotion()
        for (step, region) in [tabletopRegions, ReservedRegionLayout.none].enumerated() {
            _ = MetalGridFrameComposer.buildGroups(
                slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)], flatUIDs: [0],
                cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty }, reservedRegions: region,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                        let rect = motion.frame(
                            tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout,
                            now: Double(step), reduceMotion: false)
                        if step == 1 {
                            #expect(rect == normal.rect, "The tabletop slide must not leak into the no-fold state")
                            #expect(!motion.isAnimating)
                        }
                        return rect
                    }))
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func tabletopAspectFitPanoramasFollowBidirectionalScrollWithoutExtraSlides() throws {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [200], profile: profile, fillOrder: .newestBottomTrailing)
        let level = profile.levels.count - 1
        let initial = engine.framePlan(level: level, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let first = try #require(initial.visibleSlots.first { $0.column == 0 })
        let rowSlots = initial.visibleSlots.filter { $0.row == first.row }
        try #require(rowSlots.count == 20)
        for size in [CGSize(width: 64, height: 16), CGSize(width: 64, height: 36)] {
            let cache = try cache(sizes: Array(repeating: size, count: 200))
            for selected in [false, true] {
                let layout = GridSelectionBadgeLayout()
                var motions: [Int: GridSelectionBadgeMotion] = [:]
                var extraSlides: [String] = []
                var laggingFrames: [String] = []
                var switches: [Int: Int] = [:]
                var decisionStartedAt: [Int: Double] = [:]
                var sawFlatCircle = false
                for frame in 0..<582 {
                    let y = 120 + 580 * CGFloat(min(frame, 581 - frame)) / 290
                    let slots = rowSlots.map { slot in
                        GridRenderSlot(
                            index: slot.index, column: slot.column, row: slot.row,
                            rect: slot.viewportRect.offsetBy(dx: 0, dy: y - first.viewportRect.minY))
                    }
                    _ = MetalGridFrameComposer.buildGroups(
                        slots: slots, flatUIDs: Array(0..<200), cache: cache,
                        displayMode: .aspectFitInsideSquare, cornerRadius: 11,
                        decorations: MetalGridDecorations(
                            accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                            selected: selected ? Set(rowSlots.map(\.index)) : [], favorites: [],
                            overlay: { _ in .empty },
                            reservedRegions: tabletopRegions, selectionBadgeLayout: layout,
                            selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                                let previous = motions[uid]
                                var motion = previous ?? GridSelectionBadgeMotion()
                                let rect = motion.frame(
                                    tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                                    neighboringTiles: neighbors, row: row, layout: layout,
                                    now: Double(frame) / 60, reduceMotion: false)
                                sawFlatCircle = sawFlatCircle || tile.height < side + inset
                                let top = ReservedRegionLayout.homeMarkRect(
                                    in: tile, side: side, inset: inset, top: true)
                                let bottom = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
                                if tile.height >= side + 2 * inset && (regions.isClear(top) || regions.isClear(bottom))
                                {
                                    #expect(regions.isClear(motion.target), "A fitting circle uses a free right corner")
                                }

                                if let previous {
                                    if previous.usesAlternate != motion.usesAlternate {
                                        switches[uid, default: 0] += 1
                                        decisionStartedAt[uid] = Double(frame) / 60
                                    }
                                    let elapsed = Double(frame) / 60 - (decisionStartedAt[uid] ?? 0)
                                    if elapsed > GridSelectionBadgeMotion.duration {
                                        if motion.isAnimating { extraSlides.append("frame=\(frame),uid=\(uid)") }
                                        let corner = ReservedRegionLayout.homeMarkRect(
                                            in: tile, side: side, inset: inset, top: !motion.usesAlternate)
                                        if abs(rect.minY - corner.minY) > 0.000_000_01 {
                                            laggingFrames.append("frame=\(frame),uid=\(uid)")
                                        }
                                    }
                                }
                                motions[uid] = motion
                                #expect(rect.size == CGSize(width: side, height: side))
                                return rect
                            }))
                }
                #expect(
                    sawFlatCircle == (size.height == 16),
                    "The 4:1 witness is flatter than the circle; 16:9 is the control")
                #expect(extraSlides.isEmpty, "Only a corner decision may start a slide: \(extraSlides.prefix(5))")
                #expect(
                    laggingFrames.isEmpty,
                    "A settled corner follows the exact thumbnail y each scroll frame: \(laggingFrames.prefix(5))")
                #expect(rowSlots.allSatisfy { switches[$0.index] == 2 }, "One switch each direction at 20 columns")
                print(
                    "PANORAMA ratio=\(size.width / size.height) selected=\(selected) extraSlides=\(extraSlides.count) lagging=\(laggingFrames.count) switches=\(switches)"
                )
            }
        }
    }
}
