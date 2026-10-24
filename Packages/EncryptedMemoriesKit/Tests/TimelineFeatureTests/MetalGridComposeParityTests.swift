import CoreGraphics
import GridCore
import Metal
import MetalGridComposeCore
import MetalGridTextureAppKitAdapter
import MetalGridTextureCore
import MetalRenderingCore
import PhotosCore
import Testing

/// Contract for the universal `MetalGridFrameComposer` that macOS (`MetalGridCoordinator`) and iOS
/// (`UIKitTimelineGridHost`) both delegate to. Locks the settled-frame sequence they share
/// duplicated per host: visible/overscan classification, viewport draw filtering, the streaming window +
/// pin + upload + warm selection, and the resident/placeholder + decoration render-group assembly.
@Suite @MainActor struct MetalGridComposeParityTests {
    private func uid(_ s: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: s) }

    private func slot(_ index: Int, y: CGFloat, side: CGFloat = 100) -> GridRenderSlot {
        GridRenderSlot(index: index, column: 0, row: index, rect: CGRect(x: 0, y: y, width: side, height: side))
    }

    private func makeImage(side: Int = 64) -> CGImage? {
        makeImage(width: side, height: side)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }

    private func makeCache(maxResidentBytes: Int = 256_000_000) -> MetalGridTextureCache<PhotoUID>? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }  // no GPU (CI) to skip
        return MetalGridTextureCache(
            device: device,
            budget: GridTextureBudget(
                maxUploadsPerFrame: 64, maxUploadBytesPerFrame: 64_000_000,
                maxCachedTextures: 4096, maxResidentBytes: maxResidentBytes, overscanFraction: 1.0
            ),
            maxTexturePixels: 64,
            glyphRasterizer: AppKitMetalGridGlyphRasterizer()
        )
    }

    @Test func classifyVisibilitySplitsVisibleAndOverscanInSourceOrder() {
        let flat = [uid("0"), uid("1"), uid("2"), uid("3")]
        let slots = [
            slot(0, y: -220),  // fully above the 480-tall viewport to overscan
            slot(1, y: 20),  // inside to visible
            slot(2, y: 300),  // inside to visible
            slot(3, y: 520),  // fully below to overscan
        ]
        let out = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flat, viewportSize: CGSize(width: 320, height: 480))
        #expect(out.visible == [uid("1"), uid("2")])
        #expect(out.overscan == [uid("0"), uid("3")])
    }

    @Test func classifyVisibilityIgnoresOutOfRangeSlotIndices() {
        let flat = [uid("0")]
        let slots = [slot(0, y: 10), slot(5, y: 10)]  // index 5 has no UID
        let out = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flat, viewportSize: CGSize(width: 320, height: 480))
        #expect(out.visible == [uid("0")])
        #expect(out.overscan.isEmpty)
    }

    @Test func viewportDrawSlotsKeepsOnlyViewportIntersectingSlots() {
        let slots = [slot(0, y: -220), slot(1, y: 20), slot(2, y: 520)]
        let drawn = MetalGridFrameComposer.viewportDrawSlots(slots, viewportSize: CGSize(width: 320, height: 480))
        #expect(drawn.map(\.index) == [1])
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamUploadsRamReadyVisibleTilesAndWarmsMissingRetryable() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let a = uid("a")
        let b = uid("b")
        let c = uid("c")
        // a,b are RAM-ready; c is missing but retryable, so it must be warmed, not uploaded.
        let ram: [PhotoUID: CGImage] = [a: image, b: image]
        let result = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [a, b, c], overscanIDs: [],
            effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )
        #expect(cache.isResident(a))
        #expect(cache.isResident(b))
        #expect(!cache.isResident(c))
        #expect(result.warm == [c])
        #expect(!result.pendingVisibleQualityUpgrade)
        #expect(cache.pinnedCount == 3)  // window pinned all three visible under the ample budget
        #expect(cache.effectiveMaxTexturePixels == 64)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func visiblePlaceholderReplacementFadesButPreparedOverscanDoesNot() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let visible = uid("visible-reveal")
        let overscan = uid("prepared-overscan")
        let ram: [PhotoUID: CGImage] = [visible: image, overscan: image]
        let startedAt = 100.0

        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [visible], overscanIDs: [overscan],
            effectiveUploadPixels: 64, allowUpgrade: false, now: startedAt,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )

        let start = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)], flatUIDs: [visible], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil, now: startedAt
        )
        #expect(start.groups[0].quads[0].alpha == 0)
        #expect(cache.hasActiveThumbnailReveal(in: [visible], now: startedAt))

        let halfwayAt = startedAt + GridThumbnailRevealPolicy.duration * 0.5
        let halfway = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)], flatUIDs: [visible], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil, now: halfwayAt
        )
        let halfwayAlpha = halfway.groups[0].quads[0].alpha
        #expect(halfwayAlpha > 0.5 && halfwayAlpha < 1)

        let settledAt = startedAt + GridThumbnailRevealPolicy.duration
        let settled = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)], flatUIDs: [visible], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil, now: settledAt
        )
        #expect(settled.groups[0].quads[0].alpha == 1)
        #expect(!cache.hasActiveThumbnailReveal(in: [visible], now: settledAt))

        // The first pass intentionally prioritizes missing visible media. A following pass may upload the
        // prepared overscan tile, but it must remain immediately opaque when it later enters the viewport.
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [visible], overscanIDs: [overscan],
            effectiveUploadPixels: 64, allowUpgrade: false, now: 200,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )
        #expect(cache.isResident(overscan))
        #expect(cache.thumbnailRevealOpacity(for: overscan, now: 200) == 1)
        #expect(!cache.hasActiveThumbnailReveal(in: [overscan], now: 200))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamUpgradesUndersizedResidentOnlyWhenAllowUpgrade() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage(side: 64))
        let a = uid("a")
        let ram: [PhotoUID: CGImage] = [a: image]
        func run(effective: Int, allowUpgrade: Bool) -> MetalGridFrameComposer.StreamResult<PhotoUID> {
            MetalGridFrameComposer.stream(
                cache: cache, visibleIDs: [a], overscanIDs: [],
                effectiveUploadPixels: effective, allowUpgrade: allowUpgrade,
                hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] })
        }

        // Dense level: uploaded small.
        _ = run(effective: 32, allowUpgrade: false)
        #expect(cache.texture(for: a).width == 32)

        // Zoom to a larger layout but still interacting (allowUpgrade:false) to no upgrade, no churn.
        let interacting = run(effective: 64, allowUpgrade: false)
        #expect(cache.texture(for: a).width == 32)
        #expect(cache.upgradesThisFrame == 0)
        #expect(!interacting.pendingVisibleQualityUpgrade)

        // Settled (allowUpgrade:true) with the RAM source present sharpens in place to the larger cap.
        _ = run(effective: 64, allowUpgrade: true)
        #expect(cache.texture(for: a).width == 64)
        #expect(cache.upgradesThisFrame == 1)
        #expect(cache.residentCount == 1)  // upgraded in place, no extra resident
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamRequestsWarmAndSignalsPendingWhenUpgradeSourceEvicted() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage(side: 64))
        let a = uid("a")

        // Upload small with the source present.
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [a], overscanIDs: [],
            effectiveUploadPixels: 32, allowUpgrade: false,
            hasImage: { _ in true }, canRetry: { _ in true }, provideImage: { _ in image })
        #expect(cache.texture(for: a).width == 32)

        // Settled at a larger cap but the RAM source was evicted (hasImage:false): the composer cannot upgrade in
        // place, so it must request the source in `warm` and signal a pending upgrade - the host then re-warms and
        // keeps ticking until it sharpens, never a permanent low-res and never a silent forever-spin.
        let settled = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [a], overscanIDs: [],
            effectiveUploadPixels: 64, allowUpgrade: true,
            hasImage: { _ in false }, canRetry: { _ in true }, provideImage: { _ in nil })
        #expect(cache.texture(for: a).width == 32)  // old soft texture still on screen (no placeholder gap)
        #expect(settled.warm.contains(a))  // source requested for re-decode
        #expect(settled.pendingVisibleQualityUpgrade)  // host keeps ticking until it sharpens
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamFreesTheOverscanBandWhileARetryableVisibleTileIsMissing() throws {
        let cache = try #require(makeCache())
        let vis = [uid("v0"), uid("v1")]
        let over = [uid("o0"), uid("o1"), uid("o2")]
        // Nothing is RAM-ready and every tile can be fetched, so a visible tile is missing and nothing uploads.
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: vis, overscanIDs: over,
            effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { _ in false }, canRetry: { _ in true }, provideImage: { _ in nil }
        )
        // Pinned clamps to the visible count, never the overscan band.
        #expect(cache.pinnedCount == vis.count)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamUploadsAVisibleTileThatPinnedOverscanOfAnotherZoomLevelWouldBlock() throws {
        let largeTextureBytes = 64 * 64 * 4
        // The budget holds four 64 px textures and a little more, so a fifth pinned texture would not fit.
        let cache = try #require(makeCache(maxResidentBytes: 4 * largeTextureBytes + 2048))
        let image = try #require(makeImage())
        let earlier = (0..<4).map { uid("earlier\($0)") }
        let visible = uid("visible")
        let ram: [PhotoUID: CGImage] = Dictionary(uniqueKeysWithValues: (earlier + [visible]).map { ($0, image) })
        func run(visibleIDs: [PhotoUID], overscanIDs: [PhotoUID], effectiveUploadPixels: Int) {
            _ = MetalGridFrameComposer.stream(
                cache: cache, visibleIDs: visibleIDs, overscanIDs: overscanIDs,
                effectiveUploadPixels: effectiveUploadPixels, allowUpgrade: false,
                hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
            )
        }

        // A zoom level with large tiles fills the budget; the next level shows other tiles and keeps these as overscan.
        run(visibleIDs: earlier, overscanIDs: [], effectiveUploadPixels: 64)
        #expect(earlier.allSatisfy { cache.isResident($0) })

        run(visibleIDs: [visible], overscanIDs: earlier, effectiveUploadPixels: 32)
        #expect(cache.isResident(visible))
        #expect(!cache.residencySaturatedThisFrame)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamPinsTheOverscanBandWhenAMissingVisibleTileCannotBeFetched() throws {
        let cache = try #require(makeCache())
        let vis = [uid("v0"), uid("v1")]
        let over = [uid("o0"), uid("o1"), uid("o2")]
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: vis, overscanIDs: over,
            effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { _ in false }, canRetry: { _ in false }, provideImage: { _ in nil }
        )
        #expect(cache.pinnedCount == vis.count + over.count)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamPinsTheOverscanBandOnceEveryVisibleTileIsResident() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let vis = [uid("v0"), uid("v1")]
        let over = [uid("o0"), uid("o1"), uid("o2")]
        let ram: [PhotoUID: CGImage] = Dictionary(uniqueKeysWithValues: vis.map { ($0, image) })
        func run() {
            _ = MetalGridFrameComposer.stream(
                cache: cache, visibleIDs: vis, overscanIDs: over,
                effectiveUploadPixels: 64, allowUpgrade: false,
                hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
            )
        }
        run()
        #expect(vis.allSatisfy { cache.isResident($0) })
        // The first pass still saw missing visible tiles; the pass that follows finds none.
        #expect(cache.pinnedCount == vis.count)
        run()
        #expect(cache.pinnedCount == vis.count + over.count)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamDoesNotUploadOrWarmOverscanWhileVisibleTilesAreMissing() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let visible = [uid("v0"), uid("v1")]
        let overscan = [uid("o0"), uid("o1")]
        let ram: [PhotoUID: CGImage] = Dictionary(uniqueKeysWithValues: overscan.map { ($0, image) })

        let result = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: visible, overscanIDs: overscan,
            effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )

        #expect(result.warm == visible)
        #expect(!cache.isResident(overscan[0]))
        #expect(!cache.isResident(overscan[1]))
        #expect(cache.uploadsThisFrame == 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func streamUploadsOverscanAfterVisibleTilesAreResident() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let visible = [uid("v0"), uid("v1")]
        let overscan = [uid("o0"), uid("o1")]
        let ram: [PhotoUID: CGImage] = Dictionary(uniqueKeysWithValues: (visible + overscan).map { ($0, image) })

        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: visible, overscanIDs: overscan,
            effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )
        #expect(visible.allSatisfy { cache.isResident($0) })

        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: visible, overscanIDs: overscan,
            effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )

        #expect(overscan.allSatisfy { cache.isResident($0) })
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func buildGroupsEmitsImageGroupThenDecorationGroupsInFixedOrder() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let a = uid("a")
        let b = uid("b")
        let c = uid("c")
        let flat = [a, b, c]
        cache.beginFrame(pinned: Set(flat))
        cache.uploadVisible(wanted: flat) { _ in image }
        #expect(cache.isResident(a) && cache.isResident(b) && cache.isResident(c))

        let slots = [slot(0, y: 0), slot(1, y: 100), slot(2, y: 200)]
        let accent = SIMD4<Float>(0, 0, 1, 1)
        let decorations = MetalGridDecorations<PhotoUID>(
            accent: accent, accentGlyphColor: .white, selectionMode: false,
            selected: [a], favorites: [b],
            overlay: {
                if $0 == b { return GridThumbnailOverlay(showsRAW: true) }
                if $0 == c { return GridThumbnailOverlay(durationText: "10:45") }
                return .empty
            }
        )
        let out = MetalGridFrameComposer.buildGroups(
            slots: slots, flatUIDs: flat, cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: decorations
        )

        #expect(out.realCount == 3)
        // Group 0 is always the (possibly empty) image group: one textured quad per resident tile.
        guard case .perQuadTexture(let textures) = out.groups[0].source else {
            Issue.record("group 0 must be the per-quad image group")
            return
        }
        #expect(textures.count == 3)
        #expect(out.groups[0].quads.count == 3)
        // Quad geometry parity: image quad matches the fitter's own contentRect/UV for a square tile.
        let expectedFit = TileContentFitter.fit(
            slotRect: slots[0].rect, mediaPixelSize: CGSize(width: 64, height: 64), displayMode: .squareFillCrop)
        #expect(out.groups[0].quads[0].rect == expectedFit.contentRect)
        #expect(out.groups[0].quads[0].uvMin == expectedFit.uvMin)
        #expect(out.groups[0].quads[0].uvMax == expectedFit.uvMax)
        #expect(out.groups[0].quads[0].mode == .textured)

        // Group 1 is the selection outline (a is selected): shared placeholder texture, border mode, accent.
        #expect(out.groups[1].quads.count == 1)
        #expect(out.groups[1].quads[0].mode == .border)
        #expect(out.groups[1].quads[0].rect == slots[0].rect)
        #expect(out.groups[1].quads[0].color == accent)

        // Then the two metadata pills, their eight bounded per-character glyphs, and the favorite heart.
        #expect(out.groups.count == 5)
        #expect(out.groups[2].quads.count == 2)
        #expect(out.groups[2].quads.allSatisfy { $0.mode == .solid })
        guard case .perQuadTexture(let glyphTextures) = out.groups[3].source else {
            Issue.record("group 3 must be the per-character metadata glyph group")
            return
        }
        #expect(glyphTextures.count == 8)
        #expect(out.groups[3].quads.count == 8)
        #expect(out.groups[4].quads.count == 1)
        #expect(out.groups[4].quads[0].mode == .textured)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func buildGroupsWithoutDecorationsEmitsOnlyTheImageGroup() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let a = uid("a")
        cache.beginFrame(pinned: [a])
        cache.uploadVisible(wanted: [a]) { _ in image }

        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)], flatUIDs: [a], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil
        )
        #expect(out.groups.count == 1)
        #expect(out.realCount == 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func favoriteHeartUsesSameBottomRightPositionForPhotoAndVideo() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let video = uid("favorite-video")
        let photo = uid("favorite-photo")
        cache.beginFrame(pinned: [video, photo])
        cache.uploadVisible(wanted: [video, photo]) { _ in image }

        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0), slot(1, y: 100)], flatUIDs: [video, photo], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11,
            decorations: MetalGridDecorations(
                accent: SIMD4(0, 0, 1, 1),
                accentGlyphColor: .white,
                selectionMode: false,
                selected: [],
                favorites: [video, photo],
                overlay: {
                    $0 == video ? GridThumbnailOverlay(durationText: "10:45") : .empty
                }
            )
        )

        #expect(out.groups.count == 4)
        let durationBackground = try #require(out.groups[1].quads.first)
        let favoriteHearts = out.groups[3].quads
        #expect(favoriteHearts.count == 2)
        let videoHeart = try #require(favoriteHearts.first)
        let photoHeart = try #require(favoriteHearts.last)
        #expect(durationBackground.rect.midX < 50)
        #expect(videoHeart.rect.midX > 50)
        #expect(photoHeart.rect.midX > 50)
        #expect(videoHeart.rect.minX == photoHeart.rect.minX)
        #expect(photoHeart.rect.minY - videoHeart.rect.minY == 100)
        #expect(durationBackground.rect.maxY == 100)
        #expect(!durationBackground.rect.intersects(videoHeart.rect))
        #expect(videoHeart.rect.maxY < 100)
        #expect(photoHeart.rect.minY >= 100)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func videoDurationOccupiesBottomRightWhenNoBadgeObstructsIt() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let video = uid("duration-video")
        cache.beginFrame(pinned: [video])
        cache.uploadVisible(wanted: [video]) { _ in image }

        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)], flatUIDs: [video], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11,
            decorations: MetalGridDecorations(
                accent: SIMD4(0, 0, 1, 1),
                accentGlyphColor: .white,
                selectionMode: false,
                selected: [],
                favorites: [],
                overlay: { _ in GridThumbnailOverlay(durationText: "10:45") }
            )
        )

        let background = try #require(out.groups[1].quads.first)
        #expect(background.rect.midX > 50)
        #expect(background.rect.midY > 50)
        #expect(background.rect.maxX == 100)
        #expect(background.rect.maxY == 100)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rawIndicatorUsesFixedSizeInAspectFitAndFollowsPinchUntilCompactCutoff() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage(width: 64, height: 48))
        let raw = uid("raw-indicator")
        cache.beginFrame(pinned: [raw])
        cache.uploadVisible(wanted: [raw]) { _ in image }
        let decorations = MetalGridDecorations<PhotoUID>(
            accent: SIMD4(0, 0, 1, 1),
            accentGlyphColor: .white,
            selectionMode: false,
            selected: [],
            favorites: [],
            overlay: { _ in GridThumbnailOverlay(showsRAW: true) }
        )

        let aspectFit = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)],
            flatUIDs: [raw],
            cache: cache,
            displayMode: .aspectFitInsideSquare,
            cornerRadius: 11,
            decorations: decorations
        )
        #expect(aspectFit.groups.count == 3)
        let aspectImage = try #require(aspectFit.groups[0].quads.first)
        let aspectRAW = try #require(aspectFit.groups[1].quads.first)
        #expect(aspectImage.rect.height < 100)
        #expect(aspectRAW.rect.height == 20)
        #expect(aspectRAW.rect.minX == aspectImage.rect.minX + 5)
        #expect(aspectRAW.rect.minY == aspectImage.rect.minY + 5)
        #expect(aspectImage.rect.contains(aspectRAW.rect))

        let movingRect = CGRect(x: 23, y: 41, width: 96, height: 96)
        let moving = MetalGridFrameComposer.buildTransitionGroups(
            draws: [
                GridTransitionDraw(
                    index: 0,
                    rect: movingRect,
                    alpha: 0.6,
                    componentID: 0,
                    isTarget: true,
                    localProgress: 0.5
                )
            ],
            flatUIDs: [raw],
            cache: cache,
            displayMode: .squareFillCrop,
            cornerRadius: 11,
            decorations: decorations
        )
        #expect(moving.groups.count == 3)
        let movingImage = try #require(moving.groups[0].quads.first)
        let movingRAW = try #require(moving.groups[1].quads.first)
        #expect(abs(movingImage.alpha - 0.6) < 0.001)
        #expect(abs(movingRAW.alpha - 0.6) < 0.001)
        #expect(movingRAW.rect.height == 20)
        #expect(movingRAW.rect.minX == movingRect.minX + 5)
        #expect(movingRAW.rect.minY == movingRect.minY + 5)

        let compact = MetalGridFrameComposer.buildTransitionGroups(
            draws: [
                GridTransitionDraw(
                    index: 0,
                    rect: CGRect(x: 23, y: 41, width: 64, height: 64),
                    alpha: 1,
                    componentID: 0,
                    isTarget: true,
                    localProgress: 1
                )
            ],
            flatUIDs: [raw],
            cache: cache,
            displayMode: .squareFillCrop,
            cornerRadius: 11,
            decorations: decorations
        )
        #expect(compact.groups.count == 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func pinchTransitionMovesDurationWithThumbnailAndHonorsCompactCutoff() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let video = uid("pinch-video")
        cache.beginFrame(pinned: [video])
        cache.uploadVisible(wanted: [video]) { _ in image }
        let decorations = MetalGridDecorations<PhotoUID>(
            accent: SIMD4(0, 0, 1, 1),
            accentGlyphColor: .white,
            selectionMode: false,
            selected: [],
            favorites: [],
            overlay: { _ in GridThumbnailOverlay(durationText: "1:14") }
        )

        let movingRect = CGRect(x: 23, y: 41, width: 96, height: 96)
        let moving = MetalGridFrameComposer.buildTransitionGroups(
            draws: [
                GridTransitionDraw(
                    index: 0,
                    rect: movingRect,
                    alpha: 0.6,
                    componentID: 0,
                    isTarget: true,
                    localProgress: 0.5
                )
            ],
            flatUIDs: [video],
            cache: cache,
            displayMode: .squareFillCrop,
            cornerRadius: 11,
            decorations: decorations
        )

        #expect(moving.groups.count == 3)
        let movingImage = try #require(moving.groups[0].quads.first)
        let movingDuration = try #require(moving.groups[1].quads.first)
        #expect(abs(movingImage.alpha - 0.6) < 0.001)
        #expect(abs(movingDuration.alpha - 0.6) < 0.001)
        #expect(movingDuration.rect.maxX == movingRect.maxX)
        #expect(movingDuration.rect.maxY == movingRect.maxY)
        #expect(movingDuration.color == SIMD4<Float>(0, 0, 0, 0.5))

        let compact = MetalGridFrameComposer.buildTransitionGroups(
            draws: [
                GridTransitionDraw(
                    index: 0,
                    rect: CGRect(x: 23, y: 41, width: 64, height: 64),
                    alpha: 1,
                    componentID: 0,
                    isTarget: true,
                    localProgress: 1
                )
            ],
            flatUIDs: [video],
            cache: cache,
            displayMode: .squareFillCrop,
            cornerRadius: 11,
            decorations: decorations
        )
        #expect(compact.groups.count == 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func selectionOutlineAndModeTransitionFollowDisplayedImageGeometry() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage(width: 64, height: 48))
        let a = uid("wide")
        cache.beginFrame(pinned: [a])
        cache.uploadVisible(wanted: [a]) { _ in image }
        let tile = slot(0, y: 0)
        let decorations = MetalGridDecorations<PhotoUID>(
            accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white,
            selectionMode: false, selected: [a], favorites: [],
            overlay: { _ in GridThumbnailOverlay(durationText: "0:42", showsRAW: true) })

        let fitted = MetalGridFrameComposer.buildGroups(
            slots: [tile], flatUIDs: [a], cache: cache,
            displayMode: .aspectFitInsideSquare, cornerRadius: 11, decorations: decorations)
        let imageRect = fitted.groups[0].quads[0].rect
        let outlineRect = fitted.groups[1].quads[0].rect
        let fittedLabels = fitted.groups[2].quads
        #expect(imageRect == outlineRect)
        #expect(imageRect.height < tile.rect.height)
        #expect(fittedLabels.count == 2)
        #expect(fittedLabels.allSatisfy { imageRect.contains($0.rect) })

        let halfway = MetalGridFrameComposer.buildGroups(
            slots: [tile], flatUIDs: [a], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: decorations,
            contentTransition: .init(from: .aspectFitInsideSquare, to: .squareFillCrop, progress: 0.5))
        let halfwayRect = halfway.groups[0].quads[0].rect
        let halfwayLabels = halfway.groups[2].quads
        #expect(halfwayRect.height > imageRect.height)
        #expect(halfwayRect.height < tile.rect.height)
        #expect(halfwayLabels.count == 2)
        #expect(halfwayLabels.allSatisfy { halfwayRect.contains($0.rect) })
        let fittedDuration = try #require(fittedLabels.first { $0.rect.midY > imageRect.midY })
        let halfwayDuration = try #require(halfwayLabels.first { $0.rect.midY > halfwayRect.midY })
        #expect(halfwayDuration.rect.maxY > fittedDuration.rect.maxY)

        let settledSquare = MetalGridFrameComposer.buildGroups(
            slots: [tile], flatUIDs: [a], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: decorations)
        let settledLabels = settledSquare.groups[2].quads
        #expect(settledLabels.count == 2)
        #expect(settledLabels.contains { $0.rect.midY < tile.rect.midY })
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func buildGroupsGivesDenseTinySlotsSharpCornersAndLargeSlotsTheFullRadius() throws {
        let cache = try #require(makeCache())
        let image = try #require(makeImage())
        let a = uid("a")
        let b = uid("b")
        cache.beginFrame(pinned: [a, b])
        cache.uploadVisible(wanted: [a, b]) { _ in image }

        // Dense tiny square slot (48 pt) to radius 0: sharp 90° corners on the image quad and its decorations.
        let dense = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0, side: 48)], flatUIDs: [a], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11,
            decorations: MetalGridDecorations<PhotoUID>(
                accent: SIMD4<Float>(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: false,
                selected: [a], favorites: [], overlay: { _ in .empty }
            )
        )
        #expect(dense.groups[0].quads[0].radius == 0)
        #expect(dense.groups[1].quads[0].mode == .border)
        #expect(dense.groups[1].quads[0].radius == 0)  // selection outline follows the same policy

        // Large settled slot (200 pt) to the untouched polished base radius.
        let large = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0, side: 200)], flatUIDs: [b], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil
        )
        #expect(large.groups[0].quads[0].radius == 11)

        // Medium slot (96 pt) to reduced radius, strictly between sharp and base.
        let medium = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0, side: 96)], flatUIDs: [b], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil
        )
        #expect(medium.groups[0].quads[0].radius > 0)
        #expect(medium.groups[0].quads[0].radius < 11)
    }
}
