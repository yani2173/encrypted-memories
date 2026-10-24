import CoreGraphics
import GridCore
import Metal
import MetalGridTextureCore
import MetalRenderingCore
import simd

/// Platform-neutral composition of a settled grid frame.
///
/// This owns the settled-frame sequence for visible and overscan classification, streaming-window sizing,
/// texture upload and upgrade selection, viewport draw filtering, and render-group assembly. Platform hosts
/// own scheduling and OS view plumbing and provide neutral data and closures.
///
/// It is data-in / data-out. It never retains AppKit/UIKit objects, imports no platform view framework, and
/// mutates only the injected texture cache (which is itself platform-neutral).
package enum MetalGridFrameComposer {
    // MARK: - Visible / overscan classification

    /// Split render slots into the viewport-visible and overscan-only UID lists (visible first, source order).
    /// A slot is *visible* when its viewport rect intersects the pure viewport; otherwise it is overscan
    /// (streamed/pinned but not drawn). Out-of-range slot indices are ignored.
    package static func classifyVisibility<ID>(
        slots: [GridRenderSlot], flatUIDs: [ID], viewportSize: CGSize
    ) -> (visible: [ID], overscan: [ID]) {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        var visible: [ID] = []
        var overscan: [ID] = []
        visible.reserveCapacity(slots.count)
        overscan.reserveCapacity(slots.count)
        for s in slots where s.index < flatUIDs.count {
            if s.rect.intersects(viewport) {
                visible.append(flatUIDs[s.index])
            } else {
                overscan.append(flatUIDs[s.index])
            }
        }
        return (visible, overscan)
    }

    /// Keep only the slots that actually intersect the viewport - the draw set (overscan feeds streaming/pinning
    /// only, never a draw). Missing thumbnails draw nothing, so the bottom-most clear surface stays continuous.
    package static func viewportDrawSlots(_ slots: [GridRenderSlot], viewportSize: CGSize) -> [GridRenderSlot] {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        return slots.filter { $0.rect.intersects(viewport) }
    }

    // MARK: - Texture streaming (visible-first upload + upgrade + off-main warm selection)

    /// Contains off-main warm work and pending visible quality upgrades for one frame.
    package struct StreamResult<ID> {
        package var warm: [ID]
        package var pendingVisibleQualityUpgrade: Bool
    }

    /// Runs the streaming pass in dependency order.
    ///
    /// Set the cap, pin visible IDs, upload visible tiles, upgrade deferred residents, and select off-main warm work.
    ///
    /// While a visible tile is missing and can still be fetched, only the visible tiles are pinned. The overscan band
    /// stays evictable, so textures of another zoom level cannot block the visible upload. Otherwise the nearest
    /// overscan is pinned too, within `cache.maxSafePinnedCount`.
    @MainActor
    package static func stream<ID: Hashable & Sendable>(
        cache: MetalGridTextureCache<ID>,
        visibleIDs: [ID],
        overscanIDs: [ID],
        effectiveUploadPixels: Int,
        allowUpgrade: Bool,
        now: Double = 0,
        hasImage: (ID) -> Bool,
        canRetry: (ID) -> Bool,
        needsSharperSource: (ID) -> Bool = { _ in false },
        provideImage: (ID) -> CGImage?,
        signposts: MetalGridComposeSignposts = MetalGridComposeSignposts()
    ) -> StreamResult<ID> {
        // Level-aware upload size first: `maxSafePinnedCount` reads the effective cap, so setting it here lets
        // dense zoom levels pin far more (cheap) visible tiles within the same byte budget.
        cache.setEffectiveMaxTexturePixels(effectiveUploadPixels)
        let visibleMissing = visibleIDs.contains { !cache.isResident($0) && canRetry($0) }
        // Pinning is clamped to what the byte budget can guarantee (visible first, then nearest overscan).
        let window = GridTextureStreamingPolicy.window(
            visibleIDs: visibleIDs, overscanIDs: overscanIDs,
            maxPinned: cache.maxSafePinnedCount, pinOverscan: !visibleMissing
        )
        cache.beginFrame(pinned: window.pinned)
        let priority = visibleMissing ? visibleIDs : window.priority
        var wanted: [ID] = []
        for uid in priority where !cache.isResident(uid) && hasImage(uid) { wanted.append(uid) }
        let upgradeCandidates =
            allowUpgrade ? visibleIDs.filter { cache.residentTextureNeedsMeaningfulUpgrade($0) } : []
        signposts.uploadInterval {
            cache.uploadVisible(
                wanted: wanted,
                revealStartedAt: now,
                revealIDs: Set(visibleIDs)
            ) { provideImage($0) }
        }
        // A pending photo's new revision replaces its texture in place, also while scrolling.
        let staleVisible = visibleIDs.filter { cache.isStale($0) }
        if !staleVisible.isEmpty { cache.replaceStaleResident(staleVisible) { provideImage($0) } }
        // Settled only: after fresh uploads spend their share of the budget, grow any visible texture still
        // below the current cap (carried over from a denser level) to full crispness, in place.
        if allowUpgrade {
            signposts.upgradeInterval {
                cache.upgradeUndersizedResident(upgradeCandidates) { provideImage($0) }
            }
        }
        var warm: [ID] = []
        var queuedWarm = Set<ID>()
        func appendWarm(_ uid: ID) {
            guard queuedWarm.insert(uid).inserted else { return }
            warm.append(uid)
        }
        for uid in priority where !cache.isResident(uid) && !cache.isInFlight(uid) && !hasImage(uid) && canRetry(uid) {
            appendWarm(uid)
        }
        for uid in staleVisible where cache.isStale(uid) && !hasImage(uid) && canRetry(uid) { appendWarm(uid) }
        var pendingVisibleQualityUpgrade = cache.pendingUpgradesThisFrame
        if allowUpgrade {
            for uid in upgradeCandidates where cache.residentTextureNeedsMeaningfulUpgrade(uid) {
                // A low-res resident keeps drawing while its RAM decode is missing OR materially below the
                // effective cap; request the source so a settled sparse frame can replace it with a sharp
                // texture. If the source is present at its adequate cap (source-limited included), or the
                // pinned floor cannot fit the replacement, there is no retryable work.
                guard !hasImage(uid) || needsSharperSource(uid), canRetry(uid) else { continue }
                appendWarm(uid)
                pendingVisibleQualityUpgrade = true
            }
        }
        return StreamResult(warm: warm, pendingVisibleQualityUpgrade: pendingVisibleQualityUpgrade)
    }

    // MARK: - Render group assembly (resident/placeholder draw + production decorations)

    private struct CompositionSlot {
        var index: Int
        var rect: CGRect
        var alpha: Float
    }

    /// Build the settled-grid render groups for a set of slots at an explicit display mode (the canonical
    /// settled appearance: rounded thumbnail cover-fit on the uniform bg + optional production decorations).
    /// Pure builder - no eviction, no draw. Returns (groups, resident-texture count).
    ///
    /// The image group is always the first (back-most) group even when empty (the renderer skips empty groups),
    /// then, if `decorations` are supplied, the selection outline + badge groups in a fixed order. Missing
    /// thumbnails draw nothing, so gaps + aspectFit letterbox reveal the same uniform surface.
    @MainActor
    package static func buildGroups<ID: Hashable & Sendable>(
        slots: [GridRenderSlot],
        flatUIDs: [ID],
        cache: MetalGridTextureCache<ID>,
        displayMode: TileContentDisplayMode,
        cornerRadius: CGFloat,
        decorations: MetalGridDecorations<ID>?,
        contentTransition: TileContentDisplayTransition? = nil,
        now: Double = .greatestFiniteMagnitude
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        buildGroups(
            compositionSlots: slots.map { CompositionSlot(index: $0.index, rect: $0.rect, alpha: 1) },
            flatUIDs: flatUIDs,
            cache: cache,
            displayMode: displayMode,
            cornerRadius: cornerRadius,
            decorations: decorations,
            contentTransition: contentTransition,
            now: now
        )
    }

    /// Build one interactive zoom frame through the same image + decoration composition used by settled
    /// frames. `GridTransitionDraw.alpha` is applied to the thumbnail and every one of its decorations, so
    /// duration/RAW labels remain attached to their moving media instead of disappearing for the gesture.
    @MainActor
    package static func buildTransitionGroups<ID: Hashable & Sendable>(
        draws: [GridTransitionDraw],
        flatUIDs: [ID],
        cache: MetalGridTextureCache<ID>,
        displayMode: TileContentDisplayMode,
        cornerRadius: CGFloat,
        decorations: MetalGridDecorations<ID>?,
        rectTransform: (CGRect) -> CGRect = { $0 },
        now: Double = .greatestFiniteMagnitude
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        buildGroups(
            compositionSlots: draws.map {
                CompositionSlot(
                    index: $0.index,
                    rect: rectTransform($0.rect),
                    alpha: Float(max(0, min(1, $0.alpha)))
                )
            },
            flatUIDs: flatUIDs,
            cache: cache,
            displayMode: displayMode,
            cornerRadius: cornerRadius,
            decorations: decorations,
            contentTransition: nil,
            now: now
        )
    }

    @MainActor
    private static func buildGroups<ID: Hashable & Sendable>(
        compositionSlots: [CompositionSlot],
        flatUIDs: [ID],
        cache: MetalGridTextureCache<ID>,
        displayMode: TileContentDisplayMode,
        cornerRadius: CGFloat,
        decorations: MetalGridDecorations<ID>?,
        contentTransition: TileContentDisplayTransition?,
        now: Double
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        var images: [MetalGridQuad] = []
        var imageTextures: [MTLTexture] = []
        var outlineQuads: [MetalGridQuad] = []
        var favoriteQuads: [MetalGridQuad] = []
        var checkFilledQuads: [MetalGridQuad] = []
        var checkEmptyQuads: [MetalGridQuad] = []
        var metadataBackgroundQuads: [MetalGridQuad] = []
        var metadataGlyphQuads: [MetalGridQuad] = []
        var metadataGlyphTextures: [MTLTexture] = []
        var realCount = 0
        for s in compositionSlots where s.index >= 0 && s.index < flatUIDs.count {
            let uid = flatUIDs[s.index]
            let cell = s.rect  // viewport-space, ALWAYS square (engine guarantee)
            let r = Self.cellRadius(base: cornerRadius, cell: cell)
            var displayed = cell
            let hasThumbnail = cache.isResident(uid)
            let drawAlpha: Float
            if hasThumbnail {
                cache.noteUsed(uid)
                drawAlpha = s.alpha * cache.thumbnailRevealOpacity(for: uid, now: now)
                let texture = cache.texture(for: uid)
                // The fitter is the only thing that sees media aspect; the slot is square regardless. The rounded
                // thumbnail sits directly on the uniform background (no per-cell card), so gaps + aspectFit
                // letterbox show the same surface.
                let mediaSize = CGSize(width: texture.width, height: texture.height)
                let fit: TileContentLayout
                if let contentTransition {
                    let source = TileContentFitter.fit(
                        slotRect: cell, mediaPixelSize: mediaSize, displayMode: contentTransition.from)
                    let target = TileContentFitter.fit(
                        slotRect: cell, mediaPixelSize: mediaSize, displayMode: contentTransition.to)
                    fit = Self.interpolate(source, target, progress: contentTransition.progress)
                } else {
                    fit = TileContentFitter.fit(slotRect: cell, mediaPixelSize: mediaSize, displayMode: displayMode)
                }
                displayed = fit.contentRect
                images.append(
                    MetalGridQuad(
                        rect: fit.contentRect,
                        uvMin: fit.uvMin,
                        uvMax: fit.uvMax,
                        radius: r,
                        alpha: drawAlpha
                    ))
                imageTextures.append(texture)
                realCount += 1
            } else {
                drawAlpha = s.alpha
            }
            if let decorations {
                appendDecorations(
                    uid: uid,
                    displayed: displayed,
                    hasThumbnail: hasThumbnail,
                    cardRadius: r,
                    drawAlpha: drawAlpha,
                    decorations: decorations,
                    cache: cache,
                    outline: &outlineQuads,
                    favorite: &favoriteQuads,
                    checkFilled: &checkFilledQuads,
                    checkEmpty: &checkEmptyQuads,
                    metadataBackgrounds: &metadataBackgroundQuads,
                    metadataGlyphs: &metadataGlyphQuads,
                    metadataGlyphTextures: &metadataGlyphTextures
                )
            }
        }
        var groups: [MetalGridRenderGroup] = [
            MetalGridRenderGroup(source: .perQuadTexture(imageTextures), quads: images)
        ]
        if !outlineQuads.isEmpty {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: outlineQuads))
        }
        if !metadataBackgroundQuads.isEmpty {
            groups.append(
                MetalGridRenderGroup(
                    source: .sharedTexture(cache.placeholderTexture),
                    quads: metadataBackgroundQuads
                )
            )
        }
        if !metadataGlyphQuads.isEmpty {
            groups.append(
                MetalGridRenderGroup(
                    source: .perQuadTexture(metadataGlyphTextures),
                    quads: metadataGlyphQuads
                )
            )
        }
        if !favoriteQuads.isEmpty, let texture = cache.glyphTexture(symbol: "heart.fill", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: favoriteQuads))
        }
        if !checkEmptyQuads.isEmpty, let texture = cache.glyphTexture(symbol: "circle", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: checkEmptyQuads))
        }
        if !checkFilledQuads.isEmpty, let decorations,
            let texture = cache.glyphTexture(symbol: "checkmark.circle.fill", color: decorations.accentGlyphColor)
        {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: checkFilledQuads))
        }
        return (groups, realCount)
    }

    private static func interpolate(
        _ source: TileContentLayout,
        _ target: TileContentLayout,
        progress: CGFloat
    ) -> TileContentLayout {
        let p = Float(progress * progress * (3 - 2 * progress))
        let cg = CGFloat(p)
        let rect = CGRect(
            x: source.contentRect.minX + (target.contentRect.minX - source.contentRect.minX) * cg,
            y: source.contentRect.minY + (target.contentRect.minY - source.contentRect.minY) * cg,
            width: source.contentRect.width + (target.contentRect.width - source.contentRect.width) * cg,
            height: source.contentRect.height + (target.contentRect.height - source.contentRect.height) * cg
        )
        return TileContentLayout(
            contentRect: rect,
            uvMin: source.uvMin + (target.uvMin - source.uvMin) * p,
            uvMax: source.uvMax + (target.uvMax - source.uvMax) * p
        )
    }

    /// The slot-size-derived card corner radius (shared `GridCornerRadiusPolicy`): tiny dense cells draw
    /// SHARP 90° corners (radius 0, renderer fast path), medium cells a reduced radius, large cells `base`.
    package static func cellRadius(base: CGFloat, cell: CGRect) -> Float {
        Float(GridCornerRadiusPolicy.radius(forSlotSidePoints: min(cell.width, cell.height), base: base))
    }

    @MainActor
    private static func appendDecorations<ID: Hashable & Sendable>(
        uid: ID,
        displayed: CGRect,
        hasThumbnail: Bool,
        cardRadius: Float,
        drawAlpha: Float,
        decorations: MetalGridDecorations<ID>,
        cache: MetalGridTextureCache<ID>,
        outline: inout [MetalGridQuad], favorite: inout [MetalGridQuad],
        checkFilled: inout [MetalGridQuad], checkEmpty: inout [MetalGridQuad],
        metadataBackgrounds: inout [MetalGridQuad],
        metadataGlyphs: inout [MetalGridQuad],
        metadataGlyphTextures: inout [MTLTexture]
    ) {
        let side = min(displayed.width, displayed.height)
        let badge = min(22, max(11, side * 0.3))
        let pad = min(7, max(3, side * 0.06))
        let isSelected = decorations.selected.contains(uid)
        // Draw the selection outline without changing layout.
        if isSelected {
            let radius = min(cardRadius, Float(min(displayed.width, displayed.height) * 0.5))
            outline.append(
                MetalGridQuad(
                    rect: displayed,
                    radius: radius,
                    alpha: drawAlpha,
                    color: decorations.accent,
                    mode: .border,
                    borderWidth: 3.5
                ))
        }

        let bottomTrailingInset =
            decorations.selectionMode || decorations.favorites.contains(uid)
            ? badge + pad
            : 0
        let overlay = decorations.overlay(uid)
        let overlayLayouts =
            hasThumbnail
            ? GridThumbnailOverlayPolicy.layouts(
                for: overlay,
                in: displayed,
                bottomTrailingInset: bottomTrailingInset
            )
            : []
        // A photo on its way to Proton shows its upload state top-trailing; selection mode owns the corners.
        let badgeFrame =
            decorations.uploadBadgeFrame.map { $0(uid, overlay.uploadBadge) }
            ?? overlay.uploadBadge.map { GridUploadBadgeFrame(glyph: GridUploadBadgeGlyph($0)) }
        if let badgeFrame, badgeFrame.alpha > 0, !decorations.selectionMode,
            let texture = cache.uploadBadgeTexture(badgeFrame.glyph)
        {
            let side = badge * badgeFrame.scale
            let center = CGPoint(x: displayed.maxX - pad - badge / 2, y: displayed.minY + pad + badge / 2)
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            metadataGlyphs.append(MetalGridQuad(rect: rect, radius: 0, alpha: drawAlpha * badgeFrame.alpha))
            metadataGlyphTextures.append(texture)
        }
        for layout in overlayLayouts {
            let glyphColor: MetalGridGlyphColor
            let backgroundColor: SIMD4<Float>
            let textStyle: MetalGridGlyphTextStyle
            switch layout.kind {
            case .duration:
                glyphColor = .white
                // Match the neutral 50% corner treatment used by Photos.
                backgroundColor = SIMD4(0, 0, 0, 0.5)
                textStyle = .monospaced
            case .raw:
                glyphColor = MetalGridGlyphColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
                backgroundColor = SIMD4(0.96, 0.96, 0.96, 0.92)
                textStyle = .system
            }

            // Resolve a label atomically. If a native adapter cannot rasterize any one glyph, omit the whole
            // label rather than leaving a blank or partially legible pill over the photo.
            var labelTextures: [MTLTexture] = []
            labelTextures.reserveCapacity(layout.glyphs.count)
            for glyph in layout.glyphs {
                let aspectRatio = glyph.rect.height > 0 ? Double(glyph.rect.width / glyph.rect.height) : 1
                guard
                    let texture = cache.glyphTexture(
                        text: glyph.text,
                        aspectRatio: aspectRatio,
                        textStyle: textStyle,
                        weight: .semibold,
                        color: glyphColor
                    )
                else {
                    labelTextures.removeAll()
                    break
                }
                labelTextures.append(texture)
            }
            guard labelTextures.count == layout.glyphs.count else { continue }

            let alpha = Float(layout.alpha) * drawAlpha
            metadataBackgrounds.append(
                MetalGridQuad(
                    rect: layout.backgroundRect,
                    radius: Float(layout.backgroundRect.height * 0.23),
                    alpha: alpha,
                    color: backgroundColor,
                    mode: .solid
                )
            )
            for (glyph, texture) in zip(layout.glyphs, labelTextures) {
                metadataGlyphs.append(MetalGridQuad(rect: glyph.rect, radius: 0, alpha: alpha))
                metadataGlyphTextures.append(texture)
            }
        }

        let bottomRight = CGRect(
            x: displayed.maxX - badge - pad,
            y: displayed.maxY - badge - pad,
            width: badge,
            height: badge
        )
        // Reserve the bottom-trailing badge area when placing a duration label.
        if decorations.favorites.contains(uid), !decorations.selectionMode {
            favorite.append(MetalGridQuad(rect: bottomRight, radius: 0, alpha: drawAlpha))
        }
        if decorations.selectionMode {
            // Checkmark badge, bottom-right (filled+accent when selected, empty circle otherwise).
            if isSelected {
                checkFilled.append(MetalGridQuad(rect: bottomRight, radius: 0, alpha: drawAlpha))
            } else {
                checkEmpty.append(MetalGridQuad(rect: bottomRight, radius: 0, alpha: drawAlpha))
            }
        }
    }
}

/// Production decoration descriptors for `buildGroups`, injected as neutral data. Platform hosts convert their
/// native accent colour (AppKit/UIKit) into the SIMD/glyph values at their adapter edge; this stays neutral.
/// Selection/favorite membership is passed as value-type sets; photo-domain metadata has already been mapped
/// into the shared `GridThumbnailOverlay` value by TimelineCore before reaching this generic composer.
package struct MetalGridDecorations<ID: Hashable> {
    package var accent: SIMD4<Float>
    package var accentGlyphColor: MetalGridGlyphColor
    package var selectionMode: Bool
    package var selected: Set<ID>
    package var favorites: Set<ID>
    package var overlay: @MainActor (ID) -> GridThumbnailOverlay
    /// The animated upload badge for a photo and the badge the backup reports; nil draws the badge as is.
    package var uploadBadgeFrame: (@MainActor (ID, GridUploadBadge?) -> GridUploadBadgeFrame?)?

    package init(
        accent: SIMD4<Float>,
        accentGlyphColor: MetalGridGlyphColor,
        selectionMode: Bool,
        selected: Set<ID>,
        favorites: Set<ID>,
        overlay: @escaping @MainActor (ID) -> GridThumbnailOverlay,
        uploadBadgeFrame: (@MainActor (ID, GridUploadBadge?) -> GridUploadBadgeFrame?)? = nil
    ) {
        self.accent = accent
        self.accentGlyphColor = accentGlyphColor
        self.selectionMode = selectionMode
        self.selected = selected
        self.favorites = favorites
        self.overlay = overlay
        self.uploadBadgeFrame = uploadBadgeFrame
    }
}

/// Minimal signpost seam so a host can keep its Instruments intervals around the upload/upgrade work the
/// composer now owns, without the composer importing the host's diagnostics module. Default = no-op, so a
/// host that does not instrument simply omits it (iOS today).
package struct MetalGridComposeSignposts {
    package var uploadInterval: (() -> Void) -> Void
    package var upgradeInterval: (() -> Void) -> Void

    package init(
        uploadInterval: @escaping (() -> Void) -> Void = { $0() },
        upgradeInterval: @escaping (() -> Void) -> Void = { $0() }
    ) {
        self.uploadInterval = uploadInterval
        self.upgradeInterval = upgradeInterval
    }
}
