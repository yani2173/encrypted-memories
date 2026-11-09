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
    /// The host calls this after encoding a frame. Placeholder readiness never establishes inventory authority.
    package static func hasPresentableFirstContent<ID>(
        visibleIDs: [ID], allowsPlaceholders: Bool, isKnown: (ID) -> Bool, isResident: (ID) -> Bool
    ) -> Bool {
        visibleIDs.contains { isKnown($0) && (allowsPlaceholders || isResident($0)) }
    }

    @MainActor
    package static func hasProgressingVisibleUploads<ID: Hashable & Sendable>(
        cache: MetalGridTextureCache<ID>, ramReadyMissing: Int
    ) -> Bool {
        ramReadyMissing > 0 && cache.uploadsThisFrame > 0 && cache.deferredUploadsThisFrame > 0
            && !cache.residencySaturatedThisFrame
    }

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

    /// The id drawn by a transition draw when it is visible: opaque enough, inside the viewport, and in range.
    private static func visibleID<ID>(
        of draw: GridTransitionDraw, flatUIDs: [ID], viewport: CGRect, inset: CGFloat
    ) -> ID? {
        guard draw.alpha > 0, draw.rect.offsetBy(dx: inset, dy: 0).intersects(viewport),
            flatUIDs.indices.contains(draw.index)
        else { return nil }
        return flatUIDs[draw.index]
    }

    package static func visibleIDs<ID>(
        draws: [GridTransitionDraw], flatUIDs: [ID], viewportSize: CGSize, inset: CGFloat = 0
    ) -> [ID] {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        return draws.compactMap { visibleID(of: $0, flatUIDs: flatUIDs, viewport: viewport, inset: inset) }
    }

    /// Counts the visible transition tiles that are still loading, without building a list.
    package static func visibleLoadingCount<ID>(
        draws: [GridTransitionDraw], flatUIDs: [ID], viewportSize: CGSize, inset: CGFloat = 0,
        isLoading: (ID) -> Bool
    ) -> Int {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        var count = 0
        for draw in draws {
            if let id = visibleID(of: draw, flatUIDs: flatUIDs, viewport: viewport, inset: inset), isLoading(id) {
                count += 1
            }
        }
        return count
    }

    /// Counts the loading tiles of the visible dissolve layers (a layer with zero opacity does not count).
    package static func visibleLoadingCount<ID>(
        source: [GridRenderSlot], target: [GridRenderSlot], targetOpacity: Double,
        flatUIDs: [ID], viewportSize: CGSize, isLoading: (ID) -> Bool
    ) -> Int {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        func count(_ slots: [GridRenderSlot]) -> Int {
            var count = 0
            for slot in slots where flatUIDs.indices.contains(slot.index) && slot.rect.intersects(viewport) {
                if isLoading(flatUIDs[slot.index]) { count += 1 }
            }
            return count
        }
        return (targetOpacity < 1 ? count(source) : 0) + (targetOpacity > 0 ? count(target) : 0)
    }

    /// Keep only the slots that actually intersect the viewport. Overscan feeds streaming, not drawing.
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
                revealIDs: wanted.isEmpty ? [] : Set(visibleIDs)
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
    /// Missing known tiles draw behind real images and their decorations.
    @MainActor
    package static func buildGroups<ID: Hashable & Sendable>(
        slots: [GridRenderSlot],
        flatUIDs: [ID],
        cache: MetalGridTextureCache<ID>,
        displayMode: TileContentDisplayMode,
        cornerRadius: CGFloat,
        decorations: MetalGridDecorations<ID>?,
        contentTransition: TileContentDisplayTransition? = nil,
        now: Double = .greatestFiniteMagnitude,
        placeholderPulse: MetalGridPlaceholderPulse = MetalGridPlaceholderPulse(),
        canRetryPlaceholder: (ID) -> Bool = { _ in true }
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        buildGroups(
            compositionSlots: slots.map { CompositionSlot(index: $0.index, rect: $0.rect, alpha: 1) },
            flatUIDs: flatUIDs,
            cache: cache,
            displayMode: displayMode,
            cornerRadius: cornerRadius,
            decorations: decorations,
            contentTransition: contentTransition,
            now: now,
            placeholderPulse: placeholderPulse,
            canRetryPlaceholder: canRetryPlaceholder
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
        now: Double = .greatestFiniteMagnitude,
        placeholderPulse: MetalGridPlaceholderPulse = MetalGridPlaceholderPulse(),
        canRetryPlaceholder: (ID) -> Bool = { _ in true }
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
            now: now,
            placeholderPulse: placeholderPulse,
            canRetryPlaceholder: canRetryPlaceholder
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
        now: Double,
        placeholderPulse: MetalGridPlaceholderPulse,
        canRetryPlaceholder: (ID) -> Bool
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        var images: [MetalGridQuad] = []
        var imageTextures: [MTLTexture] = []
        var placeholders: [MetalGridQuad] = []
        var outlineQuads: [MetalGridQuad] = []
        var favoriteQuads: [MetalGridQuad] = []
        var checkFilledQuads: [MetalGridQuad] = []
        var checkEmptyQuads: [MetalGridQuad] = []
        var metadataBackgroundQuads: [MetalGridQuad] = []
        var metadataGlyphQuads: [MetalGridQuad] = []
        var metadataGlyphTextures: [MTLTexture] = []
        var realCount = 0
        var pendingDecorations:
            [(uid: ID, index: Int, slot: CGRect, frame: CGRect, resident: Bool, radius: Float, alpha: Float)] =
                []
        let sharedLight = placeholderPulse.lightPosition(now: now)
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
            if !hasThumbnail || drawAlpha < s.alpha {
                let placeholderAlpha = hasThumbnail ? max(0, s.alpha - drawAlpha) : s.alpha
                let animate = placeholderPulse.isAnimating && canRetryPlaceholder(uid)
                placeholders.append(
                    MetalGridQuad(
                        rect: cell, radius: r, alpha: placeholderAlpha,
                        color: SIMD4(1, 1, 1, MetalGridPlaceholderPulse.beamOpacity), mode: .thumbnailPlaceholder,
                        borderWidth: animate ? sharedLight : MetalGridPlaceholderPulse.staticLight
                    ))
            }
            if decorations != nil {
                pendingDecorations.append((uid, s.index, cell, displayed, hasThumbnail, r, drawAlpha))
            }
        }
        if let decorations {
            let neighboringTiles = pendingDecorations.map(\.frame)
            if decorations.selectionMode {
                decorations.selectionBadgeLayout.prepare(
                    slots: pendingDecorations.map(\.slot), tiles: neighboringTiles,
                    normalMarks: neighboringTiles.map { frame in
                        let metrics = selectionMarkMetrics(in: frame)
                        return ReservedRegionLayout.homeMarkRect(in: frame, side: metrics.side, inset: metrics.inset)
                    }, regions: decorations.reservedRegions, scrollBucket: compositionSlots.first?.index ?? 0,
                    indices: pendingDecorations.map(\.index))
            }
            for (index, pending) in pendingDecorations.enumerated() {
                appendDecorations(
                    uid: pending.uid,
                    displayed: pending.frame,
                    hasThumbnail: pending.resident,
                    cardRadius: pending.radius,
                    drawAlpha: pending.alpha,
                    neighboringTiles: neighboringTiles,
                    row: decorations.selectionBadgeLayout.row(at: index),
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
        var groups: [MetalGridRenderGroup] = []
        if !placeholders.isEmpty {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: placeholders))
        }
        groups.append(MetalGridRenderGroup(source: .perQuadTexture(imageTextures), quads: images))
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

    private static func selectionMarkMetrics(
        in frame: CGRect
    ) -> (side: CGFloat, preferredInset: CGFloat, inset: CGFloat) {
        let extent = min(frame.width, frame.height)
        let side = min(22, max(11, extent * 0.3))
        let preferred = min(7, max(3, extent * 0.06))
        return (side, preferred, ReservedRegionLayout.selectionMarkInset(in: frame, side: side, preferred: preferred))
    }

    @MainActor
    private static func appendDecorations<ID: Hashable & Sendable>(
        uid: ID,
        displayed: CGRect,
        hasThumbnail: Bool,
        cardRadius: Float,
        drawAlpha: Float,
        neighboringTiles: [CGRect],
        row: GridSelectionBadgeRow?,
        decorations: MetalGridDecorations<ID>,
        cache: MetalGridTextureCache<ID>,
        outline: inout [MetalGridQuad], favorite: inout [MetalGridQuad],
        checkFilled: inout [MetalGridQuad], checkEmpty: inout [MetalGridQuad],
        metadataBackgrounds: inout [MetalGridQuad],
        metadataGlyphs: inout [MetalGridQuad],
        metadataGlyphTextures: inout [MTLTexture]
    ) {
        let metrics = selectionMarkMetrics(in: displayed)
        let badge = metrics.side
        let pad = metrics.preferredInset
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

        let overlay = decorations.overlay(uid)
        let bottomTrailingInset =
            decorations.selectionMode || decorations.favorites.contains(uid)
            ? badge + pad
            : 0
        let overlayLayouts =
            hasThumbnail
            ? GridThumbnailOverlayPolicy.layouts(
                for: overlay,
                in: displayed,
                bottomTrailingInset: bottomTrailingInset
            )
            : []
        // The selection mark leaves the bottom-trailing corner when an active reserved region (the iPhone Duo fold)
        // covers it, for the nearest free position of the tile; the labels keep their place.
        let selectionInset = metrics.inset
        let homeMark = ReservedRegionLayout.homeMarkRect(
            in: displayed, side: badge, inset: decorations.selectionMode ? selectionInset : pad)
        let selectionMark: CGRect
        if decorations.selectionMode, let frame = decorations.selectionBadgeFrame {
            selectionMark = frame(
                uid, displayed, badge, selectionInset, decorations.reservedRegions,
                overlayLayouts.map(\.backgroundRect), neighboringTiles, row, decorations.selectionBadgeLayout)
        } else if decorations.selectionMode, !decorations.reservedRegions.isEmpty {
            selectionMark = decorations.reservedRegions.selectionMarkRect(
                in: displayed, side: badge, inset: selectionInset, avoiding: overlayLayouts.map(\.backgroundRect),
                neighboringTiles: neighboringTiles, layout: decorations.selectionBadgeLayout)
        } else {
            selectionMark = homeMark
        }
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

        // Reserve the bottom-trailing badge area when placing a duration label.
        if decorations.favorites.contains(uid), !decorations.selectionMode {
            favorite.append(MetalGridQuad(rect: homeMark, radius: 0, alpha: drawAlpha))
        }
        if decorations.selectionMode, !selectionMark.isNull {
            // Checkmark badge, bottom-right unless a reserved region covers it (filled+accent when selected, empty
            // circle otherwise).
            if isSelected {
                checkFilled.append(MetalGridQuad(rect: selectionMark, radius: 0, alpha: drawAlpha))
            } else {
                checkEmpty.append(MetalGridQuad(rect: selectionMark, radius: 0, alpha: drawAlpha))
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
    /// The active reserved regions of the viewport (the iPhone Duo fold); selection marks move out of them.
    package var reservedRegions: ReservedRegionLayout
    package var selectionBadgeLayout: GridSelectionBadgeLayout
    package var selectionBadgeFrame:
        (
            @MainActor (
                ID, CGRect, CGFloat, CGFloat, ReservedRegionLayout, [CGRect], [CGRect], GridSelectionBadgeRow?,
                GridSelectionBadgeLayout
            ) -> CGRect
        )?

    package init(
        accent: SIMD4<Float>,
        accentGlyphColor: MetalGridGlyphColor,
        selectionMode: Bool,
        selected: Set<ID>,
        favorites: Set<ID>,
        overlay: @escaping @MainActor (ID) -> GridThumbnailOverlay,
        uploadBadgeFrame: (@MainActor (ID, GridUploadBadge?) -> GridUploadBadgeFrame?)? = nil,
        reservedRegions: ReservedRegionLayout = .none,
        selectionBadgeLayout: GridSelectionBadgeLayout = GridSelectionBadgeLayout(),
        selectionBadgeFrame: (
            @MainActor (
                ID, CGRect, CGFloat, CGFloat, ReservedRegionLayout, [CGRect], [CGRect], GridSelectionBadgeRow?,
                GridSelectionBadgeLayout
            ) -> CGRect
        )? = nil
    ) {
        self.accent = accent
        self.accentGlyphColor = accentGlyphColor
        self.selectionMode = selectionMode
        self.selected = selected
        self.favorites = favorites
        self.overlay = overlay
        self.uploadBadgeFrame = uploadBadgeFrame
        self.reservedRegions = reservedRegions
        self.selectionBadgeLayout = selectionBadgeLayout
        self.selectionBadgeFrame = selectionBadgeFrame
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
