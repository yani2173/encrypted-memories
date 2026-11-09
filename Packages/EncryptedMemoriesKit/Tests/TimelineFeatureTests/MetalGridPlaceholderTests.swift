import CoreGraphics
import GridCore
import Metal
import MetalGridComposeCore
import MetalGridTextureAppKitAdapter
import MetalGridTextureCore
import MetalRenderingCore
import PhotosCore
import Testing

@Suite @MainActor struct MetalGridKnownTilePlaceholderCompositionTests {
    private func cache(maxResidentBytes: Int = 1_000_000, maxUploads: Int = 8) throws -> MetalGridTextureCache<PhotoUID>
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try #require(
            MetalGridTextureCache(
                device: device,
                budget: GridTextureBudget(
                    maxUploadsPerFrame: maxUploads, maxUploadBytesPerFrame: 1_000_000,
                    maxCachedTextures: 8, maxResidentBytes: maxResidentBytes, overscanFraction: 1
                ),
                maxTexturePixels: 64, glyphRasterizer: AppKitMetalGridGlyphRasterizer()))
    }

    private func slot(_ index: Int, side: CGFloat) -> GridRenderSlot {
        GridRenderSlot(index: index, column: 0, row: index, rect: CGRect(x: 0, y: 0, width: side, height: side))
    }

    @Test func knownMissingTilesUseTheirOwnGeometryAndNoUnknownTilesAreInvented() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "photo")
        let result = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, side: 48), slot(1, side: 200)], flatUIDs: [id], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil, now: 1)
        let placeholders = result.groups.flatMap(\.quads).filter { $0.mode == .thumbnailPlaceholder }
        #expect(result.realCount == 0)
        #expect(placeholders.count == 1)
        let tile = try #require(placeholders.first)
        #expect(tile.rect == CGRect(x: 0, y: 0, width: 48, height: 48))
        #expect(tile.radius == 0)

        let large = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, side: 200)], flatUIDs: [id], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil)
        let largeTile = try #require(large.groups.flatMap(\.quads).first { $0.mode == .thumbnailPlaceholder })
        #expect(largeTile.radius == 11)
    }

    @Test func lightMovesAndReduceMotionIsStatic() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "photo")
        func light(_ time: Double, reduceMotion: Bool) throws -> Float {
            var pulse = MetalGridPlaceholderPulse(reduceMotion: reduceMotion)
            pulse.update(loadingCount: 1, now: 0)
            let result = MetalGridFrameComposer.buildGroups(
                slots: [slot(0, side: 100)], flatUIDs: [id], cache: cache,
                displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil,
                now: time, placeholderPulse: pulse)
            return try #require(result.groups.flatMap(\.quads).first { $0.mode == .thumbnailPlaceholder }).borderWidth
        }
        #expect(try light(0.25, reduceMotion: false) < light(1, reduceMotion: false))
        #expect(try light(0.25, reduceMotion: true) == light(1, reduceMotion: true))
    }

    @Test func placeholdersCarryTheApprovedWhiteBeamAtEightyPercent() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "photo")
        #expect(MetalGridPlaceholderPulse.beamOpacity == 0.8)
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(loadingCount: 1, now: 0)
        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, side: 100)], flatUIDs: [id], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil, now: 1, placeholderPulse: pulse)
        let tile = try #require(out.groups.flatMap(\.quads).first { $0.mode == .thumbnailPlaceholder })
        #expect(tile.color == SIMD4<Float>(1, 1, 1, MetalGridPlaceholderPulse.beamOpacity))
    }

    @Test func tilesAddedAtDifferentTimesShowTheSameSharedPhase() throws {
        let cache = try cache()
        let ids = ["first", "late"].map { PhotoUID(volumeID: "v", nodeID: $0) }
        func lights(_ shown: Int, pulse: MetalGridPlaceholderPulse, now: Double) throws -> [Float] {
            let slots = (0..<shown).map {
                GridRenderSlot(
                    index: $0, column: $0, row: 0,
                    rect: CGRect(x: CGFloat($0) * 110, y: 0, width: 100, height: 100))
            }
            let out = MetalGridFrameComposer.buildGroups(
                slots: slots, flatUIDs: ids, cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                decorations: nil, now: now, placeholderPulse: pulse)
            return out.groups.flatMap(\.quads).filter { $0.mode == .thumbnailPlaceholder }.map(\.borderWidth)
        }
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(loadingCount: 1, now: 10)
        let alone = try lights(1, pulse: pulse, now: 11)
        pulse.update(loadingCount: 2, now: 11.7)
        let together = try lights(2, pulse: pulse, now: 11.7)
        #expect(alone.count == 1 && together.count == 2)
        #expect(together[0] == together[1])
        #expect(together[0] != alone[0])
        // The shared clock starts with the sweep: the same sweep started elsewhere on the clock shows the same phase.
        var later = MetalGridPlaceholderPulse()
        later.update(loadingCount: 1, now: 1000)
        #expect(try lights(1, pulse: later, now: 1001) == alone)
    }

    @Test func realThumbnailReplacesThePlaceholder() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "photo")
        let context = try #require(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        cache.beginFrame(pinned: [id])
        cache.uploadVisible(wanted: [id]) { _ in image }
        let result = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, side: 100)], flatUIDs: [id], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil)
        #expect(result.realCount == 1)
        #expect(!result.groups.flatMap(\.quads).contains { $0.mode == .thumbnailPlaceholder })
        #expect(result.groups.flatMap(\.quads).contains { $0.mode == .textured })
    }

    @Test func aspectFitPlaceholderFadesWithTheArrivingPhoto() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "photo")
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [id], overscanIDs: [], effectiveUploadPixels: 64, allowUpgrade: false,
            now: 100, hasImage: { _ in true }, canRetry: { _ in true }, provideImage: { _ in image })
        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, side: 100)], flatUIDs: [id], cache: cache,
            displayMode: .aspectFitInsideSquare, cornerRadius: 11, decorations: nil,
            now: 100 + GridThumbnailRevealPolicy.duration * 0.5)
        let placeholder = try #require(out.groups.flatMap(\.quads).first { $0.mode == .thumbnailPlaceholder })
        let photo = try #require(out.groups.flatMap(\.quads).first { $0.mode == .textured })
        #expect(photo.rect.height < placeholder.rect.height)
        #expect(placeholder.alpha > 0 && placeholder.alpha < 1)
    }

    @Test func zoomTransitionRetainsThePlaceholderAndItsOpacity() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "photo")
        let rect = CGRect(x: 5, y: 7, width: 100, height: 100)
        let result = MetalGridFrameComposer.buildTransitionGroups(
            draws: [.init(index: 0, rect: rect, alpha: 0.4, componentID: 0, isTarget: true, localProgress: 0.5)],
            flatUIDs: [id], cache: cache, displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil)
        let tile = try #require(result.groups.flatMap(\.quads).first { $0.mode == .thumbnailPlaceholder })
        #expect(tile.rect == rect)
        #expect(abs(tile.alpha - 0.4) < 0.001)
    }

    @Test func aFailedTileDrawsStaticWhileAnotherTileSweeps() throws {
        let cache = try cache()
        let id = PhotoUID(volumeID: "v", nodeID: "failed")
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [id], overscanIDs: [], effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { _ in false }, canRetry: { _ in false }, provideImage: { _ in nil })
        #expect(!cache.isResident(id))
        // While another tile sweeps, the failed tile still draws without the light.
        var sweeping = MetalGridPlaceholderPulse()
        sweeping.update(loadingCount: 1, now: 0)
        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, side: 100)], flatUIDs: [id], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil,
            now: 1, placeholderPulse: sweeping, canRetryPlaceholder: { _ in false })
        let tile = try #require(out.groups.flatMap(\.quads).first { $0.mode == .thumbnailPlaceholder })
        #expect(tile.borderWidth == -2)
    }

    @Test func saturatedCacheCannotKeepAPlaceholderAnimatingForever() throws {
        let cache = try cache(maxResidentBytes: 4)
        let id = PhotoUID(volumeID: "v", nodeID: "saturated")
        let context = try #require(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        cache.beginFrame(pinned: [id])
        cache.uploadVisible(wanted: [id]) { _ in image }
        #expect(cache.residencySaturatedThisFrame)
        #expect(!cache.isResident(id))
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(visible: [id], now: 0) { !cache.isResident($0) }
        #expect(pulse.isAnimating)
        pulse.update(visible: [id], now: 5) { !cache.isResident($0) }
        #expect(!pulse.isAnimating)
        pulse.update(visible: [id], now: 50) { !cache.isResident($0) }
        #expect(!pulse.isAnimating)
    }

    @Test func allLoadingTilesShareOneBoundedSweepAndAnEmptyScreenStartsANewOne() {
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(loadingCount: 1, now: 0)
        #expect(pulse.isAnimating)
        pulse.update(loadingCount: 2, now: 3)
        #expect(pulse.isAnimating)
        pulse.update(loadingCount: 2, now: 4.9)
        #expect(!pulse.isAnimating)
        pulse.update(loadingCount: 0, now: 6)
        #expect(!pulse.isAnimating)
        pulse.update(loadingCount: 1, now: 7)
        #expect(pulse.isAnimating)
        let changed = pulse.setReduceMotion(true)
        pulse.update(loadingCount: 1, now: 7.1)
        #expect(changed)
        #expect(!pulse.isAnimating)
        let unchanged = pulse.setReduceMotion(true)
        #expect(!unchanged)
    }

    @Test func hiddenTimeDoesNotCountAndTheSweepRestarts() {
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(loadingCount: 1, now: 0)
        pulse.update(loadingCount: 1, now: 4)
        pulse.restart()
        #expect(!pulse.isAnimating)
        pulse.update(loadingCount: 1, now: 100)
        #expect(pulse.isAnimating)
        pulse.update(loadingCount: 1, now: 104)
        #expect(pulse.isAnimating)
        pulse.update(loadingCount: 1, now: 105.5)
        #expect(!pulse.isAnimating)
    }

    @Test func layersRedrawOnceMoreWhenTheSweepEnds() {
        var pulse = MetalGridPlaceholderPulse()
        pulse.update(loadingCount: 1, now: 0)
        #expect(pulse.needsLayerRedraw)
        pulse.update(loadingCount: 1, now: 4.9)
        #expect(pulse.changed && pulse.needsLayerRedraw)
        pulse.update(loadingCount: 1, now: 5)
        #expect(!pulse.needsLayerRedraw)
    }

    @Test func visibleLoadingCountIgnoresTransparentOffscreenAndLoadedTiles() {
        let ids = (0..<4).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }
        let box = CGRect(x: 0, y: 0, width: 40, height: 40)
        let source = [GridRenderSlot(index: 0, column: 0, row: 0, rect: box)]
        let target = [
            GridRenderSlot(index: 1, column: 0, row: 0, rect: box),
            GridRenderSlot(index: 2, column: 0, row: 1, rect: CGRect(x: 0, y: 200, width: 40, height: 40)),
            GridRenderSlot(index: 3, column: 1, row: 0, rect: box.offsetBy(dx: 50, dy: 0)),
        ]
        func count(_ opacity: Double) -> Int {
            MetalGridFrameComposer.visibleLoadingCount(
                source: source, target: target, targetOpacity: opacity, flatUIDs: ids,
                viewportSize: CGSize(width: 100, height: 100)
            ) { $0 != ids[3] }
        }
        #expect(count(0) == 1)
        #expect(count(0.5) == 2)
        #expect(count(1) == 1)
    }

    @Test func transitionTilesRespectAlphaViewportAndInset() {
        let ids = [PhotoUID(volumeID: "v", nodeID: "in"), PhotoUID(volumeID: "v", nodeID: "out")]
        let draws = [
            GridTransitionDraw(
                index: 0, rect: CGRect(x: -30, y: 0, width: 20, height: 20), alpha: 1,
                componentID: 0, isTarget: false, localProgress: 0),
            GridTransitionDraw(
                index: 1, rect: CGRect(x: 90, y: 0, width: 20, height: 20), alpha: 1,
                componentID: 1, isTarget: false, localProgress: 0),
            GridTransitionDraw(
                index: 1, rect: CGRect(x: 10, y: 0, width: 20, height: 20), alpha: 0,
                componentID: 2, isTarget: true, localProgress: 0),
        ]
        let viewport = CGSize(width: 100, height: 100)
        #expect(
            MetalGridFrameComposer.visibleIDs(draws: draws, flatUIDs: ids, viewportSize: viewport, inset: 20)
                == [ids[0]])
        #expect(
            MetalGridFrameComposer.visibleLoadingCount(
                draws: draws, flatUIDs: ids, viewportSize: viewport, inset: 20
            ) { _ in true } == 1)
    }

    @Test func decodedUploadsContinueOnlyWhileAFrameMakesProgress() throws {
        let cache = try cache(maxUploads: 1)
        let ids = ["first", "second"].map { PhotoUID(volumeID: "v", nodeID: $0) }
        let context = try #require(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: ids, overscanIDs: [], effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { _ in true }, canRetry: { _ in true }, provideImage: { _ in image })
        #expect(cache.isResident(ids[0]))
        #expect(!cache.isResident(ids[1]))
        #expect(MetalGridFrameComposer.hasProgressingVisibleUploads(cache: cache, ramReadyMissing: 1))
        cache.beginFrame(pinned: Set(ids))
        #expect(!MetalGridFrameComposer.hasProgressingVisibleUploads(cache: cache, ramReadyMissing: 1))
    }
}
