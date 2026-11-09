import CoreGraphics
import GridCore
import Metal

/// Persistent one-texture-per-image GPU cache backed by `GridTextureResidencyPolicy`. Visible items are pinned;
/// offscreen items are evicted by LRU when count or byte budgets require it. A neutral placeholder remains resident.
/// Uploads run on the render thread from decoded images. The cache bounds both per-frame uploads and residency.
@MainActor
package final class MetalGridTextureCache<ID: Hashable & Sendable> {
    private let device: MTLDevice
    private let glyphRasterizer: any MetalGridGlyphRasterizing
    private let budget: GridTextureBudget
    /// Whether the GPU supports sampler channel swizzles required by the direct-upload path.
    private let supportsTextureSwizzle: Bool
    private var lru: GridTextureResidencyPolicy<ID>
    private var textures: [ID: MTLTexture] = [:]
    /// Start time for a real texture that replaced a visible placeholder. This is tied to the actual GPU
    /// residency transition, not to a platform view callback, so every Metal grid gets the same reveal.
    private var thumbnailRevealStartedAt: [ID: Double] = [:]
    /// Resident textures whose photo has a newer image; see `markStale`.
    private var staleTextures = Set<ID>()
    package private(set) var placeholderTexture: MTLTexture

    /// Rolling per-frame accounting (reset each `beginFrame`).
    package private(set) var uploadsThisFrame = 0
    package private(set) var uploadBytesThisFrame = 0
    package private(set) var uploadMsThisFrame: Double = 0
    package private(set) var evictionsThisFrame = 0
    package private(set) var evictMsThisFrame: Double = 0
    package private(set) var deferredUploadsThisFrame = 0
    /// In-place re-uploads this frame that grew an already-resident texture to the current effective cap
    /// (`upgradeUndersizedResident`) - a subset of `uploadsThisFrame`, surfaced separately for diagnostics.
    package private(set) var upgradesThisFrame = 0
    /// Uploads this frame that skipped the main-thread CGContext normalization redraw and copied the decoded
    /// image's bytes straight into the texture (a correctly-sized sRGB/DeviceRGB 8-bit RGB(A) source, corrected
    /// by a GPU-side channel swizzle). A subset of `uploadsThisFrame`; its complement is `normalizedUploadsThisFrame`.
    package private(set) var directUploadsThisFrame = 0
    /// Uploads this frame that went through the CGContext RGBA8 normalization redraw - the always-correct
    /// fallback for exotic formats (CMYK, grayscale, 16-bit, float), wide-gamut colorspaces, straight
    /// (non-premultiplied) alpha, a source needing resampling, or a device without texture-swizzle support.
    package private(set) var normalizedUploadsThisFrame = 0
    /// True once an upload was refused this frame because the resident byte/count budget cannot admit it
    /// even after evicting every non-pinned texture. That state only changes when the streaming window
    /// changes (scroll/zoom) or images arrive - both trigger their own redraw - so callers may stop
    /// display-link pumping on it instead of spinning on placeholders that can never fill.
    package private(set) var residencySaturatedThisFrame = false
    /// True when at least one visible resident texture is still below the current effective cap because the
    /// per-frame upload budget ran out (not because residency refused it - that never changes without a
    /// window change). Callers keep the display link ticking on this so a soft carried-over texture finishes
    /// upgrading to full resolution over the next frames instead of freezing mid-upgrade on an idle grid.
    package private(set) var pendingUpgradesThisFrame = false

    /// Absolute pixel side ceiling a thumbnail is uploaded at (platform adapter policy - Retina crispness
    /// without wasting VRAM). The per-frame *effective* cap (`effectiveMaxTexturePixels`) is derived from the
    /// on-screen slot size and can only ever be smaller, never larger, than this.
    package let maxTexturePixels: Int

    /// The cap actually applied to thumbnail uploads this frame: the coordinator lowers it for dense zoom
    /// levels (tiny slots) via `setEffectiveMaxTexturePixels` so those upload smaller textures. Defaults to
    /// `maxTexturePixels`, so a caller that never sets it behaves exactly as before. Glyph textures ignore
    /// this and always size against `maxTexturePixels` (their size must stay stable across zoom).
    package private(set) var effectiveMaxTexturePixels: Int

    /// Memory-pressure scale on the resident count/byte ceiling (governor-driven, 1.0 = full platform
    /// budget). `< 1` shrinks how much offscreen residency `evictToBudget` keeps each frame; `0` keeps
    /// only the pinned visible working set. Default 1.0 leaves eviction byte-identical to before.
    package private(set) var residencyPressureScale: Double = 1.0

    package var residentCount: Int { lru.residentCount }
    package var pinnedCount: Int { lru.pinnedCount }
    package var inFlightCount: Int { lru.inFlightCount }
    package var residencyCapacity: Int { lru.capacity }
    package var pinnedOverflow: Bool { lru.pinnedCount > lru.capacity }
    /// Exact resident GPU texture bytes (single source of truth: the policy's cost ledger).
    package var residentBytes: Int { lru.residentCost }
    package var residentByteBudget: Int { budget.maxResidentBytes }
    package var uploadByteBudgetPerFrame: Int { budget.maxUploadBytesPerFrame }
    /// True when resident bytes exceed the budget - transiently possible inside a frame (uploads land
    /// before `evictToBudget`), never after eviction ran. Persistent `true` in logs signals a bug.
    package var byteBudgetOverflow: Bool { lru.residentCost > budget.maxResidentBytes }
    /// Largest pin set the byte budget can guarantee residency for, assuming worst-case (square,
    /// `effectiveMaxTexturePixels`-sided) uploads. The streaming window clamps pinning to this so visible-first
    /// pinning degrades to placeholders instead of overflowing the budget.
    ///
    /// Using the *effective* cap (not the absolute `maxTexturePixels`) makes this accurate per zoom level: at
    /// the dense overview levels - where the pin count explodes (viewport + 2× overscan can exceed the count
    /// cap entirely) - the effective cap is small, so each texture is cheap and far more of the visible tiles
    /// can be pinned within the same byte budget instead of degrading to placeholders. Structural admission in
    /// the residency policy still enforces the byte ceiling regardless, so an over-optimistic estimate can only
    /// cost a transient placeholder, never a budget overflow.
    package var maxSafePinnedCount: Int {
        let worstCaseBytesPerTexture = max(1, effectiveMaxTexturePixels * effectiveMaxTexturePixels * 4)
        return min(budget.maxCachedTextures, budget.maxResidentBytes / worstCaseBytesPerTexture)
    }

    package init?(
        device: MTLDevice,
        budget: GridTextureBudget,
        maxTexturePixels: Int = 320,
        glyphRasterizer: any MetalGridGlyphRasterizing
    ) {
        self.device = device
        self.glyphRasterizer = glyphRasterizer
        self.budget = budget
        self.maxTexturePixels = maxTexturePixels
        self.effectiveMaxTexturePixels = maxTexturePixels
        self.supportsTextureSwizzle = device.supportsFamily(.apple1) || device.supportsFamily(.mac2)
        self.lru = GridTextureResidencyPolicy(
            capacity: budget.maxCachedTextures,
            costCapacity: budget.maxResidentBytes,
            uploadBudgetPerFrame: budget.maxUploadsPerFrame
        )
        guard let placeholder = Self.makePlaceholder(device: device) else { return nil }
        self.placeholderTexture = placeholder
    }

    // MARK: - Per-frame lifecycle

    package func beginFrame(pinned: Set<ID>) {
        lru.beginFrame(pinned: pinned)
        uploadsThisFrame = 0
        uploadBytesThisFrame = 0
        uploadMsThisFrame = 0
        evictionsThisFrame = 0
        evictMsThisFrame = 0
        deferredUploadsThisFrame = 0
        upgradesThisFrame = 0
        directUploadsThisFrame = 0
        normalizedUploadsThisFrame = 0
        residencySaturatedThisFrame = false
        pendingUpgradesThisFrame = false
    }

    /// Set the per-frame effective upload cap (derived by the coordinator from the on-screen slot size at the
    /// current zoom level; see `GridTextureUploadSizing`). Clamped to `1...maxTexturePixels`, so it can only
    /// shrink uploads relative to the platform ceiling, never enlarge them beyond it.
    package func setEffectiveMaxTexturePixels(_ pixels: Int) {
        effectiveMaxTexturePixels = min(maxTexturePixels, max(1, pixels))
    }

    package func noteUsed(_ id: ID) { lru.noteUsed(id) }

    package func isResident(_ id: ID) -> Bool { lru.isResident(id) }
    package func isInFlight(_ id: ID) -> Bool { lru.isInFlight(id) }

    /// The texture to draw for `id` - real if resident, else the shared placeholder.
    package func texture(for id: ID) -> MTLTexture {
        textures[id] ?? placeholderTexture
    }

    /// Wall-clock opacity for a newly resident visible thumbnail. Completed entries are retired lazily so
    /// offscreen arrivals do not require a timer and the state remains bounded by texture residency.
    package func thumbnailRevealOpacity(for id: ID, now: Double) -> Float {
        guard let startedAt = thumbnailRevealStartedAt[id] else { return 1 }
        let elapsed = now - startedAt
        guard GridThumbnailRevealPolicy.isActive(elapsed: elapsed) else {
            if elapsed >= GridThumbnailRevealPolicy.duration {
                thumbnailRevealStartedAt.removeValue(forKey: id)
            }
            return elapsed < 0 ? 0 : 1
        }
        return GridThumbnailRevealPolicy.opacity(elapsed: elapsed)
    }

    /// Whether any of the current draw IDs still needs reveal frames. Expired entries are removed here too,
    /// allowing the platform display-link pumps to stop immediately after the shared animation settles.
    package func hasActiveThumbnailReveal(in ids: [ID], now: Double) -> Bool {
        var active = false
        for id in ids {
            guard let startedAt = thumbnailRevealStartedAt[id] else { continue }
            let elapsed = now - startedAt
            if GridThumbnailRevealPolicy.isActive(elapsed: elapsed) {
                active = true
            } else if elapsed >= GridThumbnailRevealPolicy.duration {
                thumbnailRevealStartedAt.removeValue(forKey: id)
            }
        }
        return active
    }

    /// Returns whether a resident texture is at least 20 percent below the effective size cap.
    package func residentTextureNeedsMeaningfulUpgrade(_ id: ID) -> Bool {
        guard let current = textures[id] else { return false }
        let currentLongest = max(current.width, current.height)
        guard currentLongest < effectiveMaxTexturePixels else { return false }
        return effectiveMaxTexturePixels * 4 >= currentLongest * 5
    }

    /// Duration accounting must not depend on user or network adjustments to wall-clock time.
    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    private var uploadTimeBudgetExhausted: Bool {
        uploadsThisFrame > 0 && uploadMsThisFrame >= budget.maxUploadMillisecondsPerFrame
    }

    /// Uploads visible items within the frame and residency budgets.
    /// `deferredUploadsThisFrame` reports budget-limited work for later frames.
    package func uploadVisible(wanted: [ID], provideImage: (ID) -> CGImage?) {
        uploadVisible(
            wanted: wanted,
            revealStartedAt: nil,
            revealIDs: [],
            provideImage: provideImage
        )
    }

    package func uploadVisible(
        wanted: [ID],
        revealStartedAt: Double?,
        revealIDs: Set<ID>,
        provideImage: (ID) -> CGImage?
    ) {
        let chosen = lru.selectUploads(wanted: wanted)
        var budgetDeferred = 0
        var frameByteBudgetExhausted = false
        var frameTimeBudgetExhausted = false
        for id in chosen {
            if frameByteBudgetExhausted || frameTimeBudgetExhausted {
                lru.abandonUpload(id)
                budgetDeferred += 1
                continue
            }
            guard let image = provideImage(id) else {
                lru.abandonUpload(id)  // image vanished between selection and upload - retry later
                continue
            }
            let size = uploadPixelSize(for: image, cap: effectiveMaxTexturePixels)
            let bytes = size.width * size.height * 4
            // The first upload of a frame always proceeds so one oversized image can never starve forever.
            if uploadsThisFrame > 0, uploadBytesThisFrame + bytes > budget.maxUploadBytesPerFrame {
                frameByteBudgetExhausted = true
                lru.abandonUpload(id)
                budgetDeferred += 1
                continue
            }
            guard lru.canAdmitUpload(id, cost: bytes) else {
                // Pinned upload refusal means the visible working set exceeds the resident byte floor.
                // Overscan refusal is deferred because later eviction can make room.
                if lru.isPinned(id) { residencySaturatedThisFrame = true }
                lru.abandonUpload(id)
                budgetDeferred += 1
                continue
            }
            let start = ContinuousClock.now
            guard let texture = makeTexture(from: image, width: size.width, height: size.height) else {
                lru.abandonUpload(id)
                continue
            }
            uploadMsThisFrame += Self.elapsedMilliseconds(since: start)
            textures[id] = texture
            if let revealStartedAt, revealIDs.contains(id) {
                thumbnailRevealStartedAt[id] = revealStartedAt
            }
            uploadBytesThisFrame += bytes
            uploadsThisFrame += 1
            frameTimeBudgetExhausted = uploadTimeBudgetExhausted
            lru.completeUpload(id, cost: bytes)
        }
        deferredUploadsThisFrame = max(0, wanted.count - chosen.count) + budgetDeferred
    }

    /// Re-uploads visible textures that are below the current effective cap. The existing texture stays visible
    /// until the larger replacement is ready. The same per-frame and residency budgets apply as for fresh uploads.
    package func upgradeUndersizedResident(_ ids: [ID], provideImage: (ID) -> CGImage?) {
        let cap = effectiveMaxTexturePixels
        for id in ids {
            guard uploadsThisFrame < budget.maxUploadsPerFrame else {
                pendingUpgradesThisFrame = true
                break
            }
            guard !uploadTimeBudgetExhausted else {
                pendingUpgradesThisFrame = true
                break
            }
            guard let current = residentMetrics(for: id) else { continue }  // Fresh uploads handle nonresident items.
            let currentLongest = current.longest
            guard currentLongest < cap else { continue }  // The texture already meets the cap.
            guard let image = provideImage(id) else { continue }  // Keep the resident texture.
            let size = uploadPixelSize(for: image, cap: cap)
            let targetLongest = max(size.width, size.height)
            // Require at least 25 percent growth to prevent repeated uploads near the cap.
            guard targetLongest > currentLongest, targetLongest * 4 >= currentLongest * 5 else { continue }
            let newBytes = size.width * size.height * 4
            let oldBytes = current.bytes
            if uploadsThisFrame > 0, uploadBytesThisFrame + newBytes > budget.maxUploadBytesPerFrame {
                pendingUpgradesThisFrame = true
                break
            }
            // Replacement keeps the residency count stable and can evict offscreen texture bytes.
            guard lru.canReplaceResident(id, oldCost: oldBytes, newCost: newBytes) else { continue }
            let start = ContinuousClock.now
            guard let texture = makeTexture(from: image, width: size.width, height: size.height) else { continue }
            uploadMsThisFrame += Self.elapsedMilliseconds(since: start)
            textures[id] = texture
            uploadBytesThisFrame += newBytes
            uploadsThisFrame += 1
            upgradesThisFrame += 1
            lru.completeUpload(id, cost: newBytes)  // resident-replace branch: swaps the byte cost in place
        }
    }

    /// Reads only scalar residency metrics before a replacement is prepared. The dictionary keeps the old
    /// texture alive for visual continuity, but this helper lets the local reference release before the new
    /// texture is allocated so the old and new textures are not additionally retained by this method's scope.
    private func residentMetrics(for id: ID) -> (longest: Int, bytes: Int)? {
        guard let texture = textures[id] else { return nil }
        return (
            longest: max(texture.width, texture.height),
            bytes: texture.width * texture.height * 4
        )
    }

    /// Evict offscreen LRU textures down to the count + byte budget and release their GPU memory. Under
    /// memory pressure (`residencyPressureScale < 1`) the ceiling is scaled down; the visible pinned set
    /// is never evicted, so the grid stays drawable. At full scale this is the original budget eviction.
    package func evictToBudget() {
        let start = ContinuousClock.now
        let evicted: [ID]
        if residencyPressureScale >= 1 {
            evicted = lru.evictToBudget()
        } else {
            let maxCount = Int(Double(budget.maxCachedTextures) * residencyPressureScale)
            let maxCost = Int(Double(budget.maxResidentBytes) * residencyPressureScale)
            evicted = lru.evictToReducedBudget(maxCount: maxCount, maxCost: maxCost)
        }
        for id in evicted {
            textures.removeValue(forKey: id)
            staleTextures.remove(id)
            thumbnailRevealStartedAt.removeValue(forKey: id)
        }
        evictionsThisFrame = evicted.count
        evictMsThisFrame += Self.elapsedMilliseconds(since: start)
    }

    /// Marks the textures of photos whose content changed (a new revision of a pending photo). They keep
    /// drawing until `replaceStaleResident` uploads the new image, so the tile never flashes the placeholder.
    package func markStale(_ ids: [ID]) {
        for id in ids where textures[id] != nil { staleTextures.insert(id) }
    }

    package func isStale(_ id: ID) -> Bool { staleTextures.contains(id) }

    /// A pending photo became its Proton photo: the Proton identity draws the same texture at once, with no
    /// upload and no fade. The texture is shared; residency counts it for both until the pending one is evicted.
    package func adoptTexture(from source: ID, to target: ID) {
        guard textures[target] == nil, !lru.isInFlight(target), let texture = textures[source] else { return }
        textures[target] = texture
        lru.completeUpload(target, cost: texture.width * texture.height * 4)
        if staleTextures.contains(source) { staleTextures.insert(target) }
    }

    /// Replaces stale visible textures in place, within the frame's upload budget. A texture whose new image is
    /// not in memory yet keeps drawing until it is.
    package func replaceStaleResident(_ ids: [ID], provideImage: (ID) -> CGImage?) {
        for id in ids where staleTextures.contains(id) {
            guard uploadsThisFrame < budget.maxUploadsPerFrame, !uploadTimeBudgetExhausted else {
                pendingUpgradesThisFrame = true
                return
            }
            guard let current = residentMetrics(for: id) else {
                staleTextures.remove(id)
                continue
            }
            guard let image = provideImage(id) else { continue }
            let size = uploadPixelSize(for: image, cap: effectiveMaxTexturePixels)
            let newBytes = size.width * size.height * 4
            if uploadsThisFrame > 0, uploadBytesThisFrame + newBytes > budget.maxUploadBytesPerFrame {
                pendingUpgradesThisFrame = true
                return
            }
            guard lru.canReplaceResident(id, oldCost: current.bytes, newCost: newBytes) else { continue }
            let start = ContinuousClock.now
            guard let texture = makeTexture(from: image, width: size.width, height: size.height) else { continue }
            uploadMsThisFrame += Self.elapsedMilliseconds(since: start)
            textures[id] = texture
            staleTextures.remove(id)
            uploadBytesThisFrame += newBytes
            uploadsThisFrame += 1
            lru.completeUpload(id, cost: newBytes)
        }
    }

    /// Governor-driven memory-pressure response: set the resident ceiling scale (`1.0` = full budget,
    /// `0.0` = keep only the visible pinned set) and reclaim immediately at the new ceiling. Applies to
    /// future frames too, so residency stays reduced while pressure persists and grows back once the
    /// governor restores `1.0`. Visible tiles are never evicted, so what is on screen stays drawable.
    package func setResidencyPressureScale(_ scale: Double) {
        let clamped = min(1, max(0, scale))
        guard clamped != residencyPressureScale else { return }
        residencyPressureScale = clamped
        evictToBudget()
    }

    // MARK: - Texture creation

    /// Pixel size a decoded image will be uploaded at (longest side clamped to `cap`) - the texture byte cost
    /// (w·h·4) is derived from this before any normalization/upload work is spent, so budget refusals cost
    /// nothing. `cap` is the effective per-frame cap for thumbnails and the absolute `maxTexturePixels` for
    /// glyphs; either way the aspect ratio is preserved and an image never upscales past its source.
    private func uploadPixelSize(for image: CGImage, cap: Int) -> (width: Int, height: Int) {
        let srcW = max(image.width, 1)
        let srcH = max(image.height, 1)
        let longest = max(srcW, srcH)
        let cap = max(1, cap)
        let scale = longest > cap ? CGFloat(cap) / CGFloat(longest) : 1
        return (max(1, Int((CGFloat(srcW) * scale).rounded())), max(1, Int((CGFloat(srcH) * scale).rounded())))
    }

    /// Builds an upright RGBA8 texture at the requested upload size. Compatible images use direct upload;
    /// other images use normalization.
    private func makeTexture(from image: CGImage, width w: Int, height h: Int) -> MTLTexture? {
        if let texture = makeTextureDirect(from: image, width: w, height: h) {
            directUploadsThisFrame += 1
            return texture
        }
        normalizedUploadsThisFrame += 1
        return makeTextureNormalized(from: image, width: w, height: h)
    }

    /// Copies compatible decoded bytes directly into a texture.
    /// Unsupported formats return `nil` and use the normalized upload path.
    private func makeTextureDirect(from image: CGImage, width w: Int, height h: Int) -> MTLTexture? {
        guard let swizzle = CGImageDirectUpload.swizzle(for: image, targetWidth: w, targetHeight: h) else {
            return nil
        }
        // An identity layout (bytes already R,G,B,A) uploads anywhere; a remap needs GPU swizzle support.
        guard swizzle.isIdentity || supportsTextureSwizzle else { return nil }
        guard let provider = image.dataProvider, let data = provider.data else { return nil }
        let bytesPerRow = image.bytesPerRow
        guard CFDataGetLength(data) >= bytesPerRow * h, let bytes = CFDataGetBytePtr(data) else { return nil }
        guard
            let texture = makeEmptyTexture(width: w, height: h, swizzle: swizzle.isIdentity ? nil : mtlSwizzle(swizzle))
        else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        return texture
    }

    /// The CGContext RGBA8 normalization redraw - the always-correct fallback that resamples/format-converts
    /// any source into an upright premultiplied RGBA8 buffer before upload.
    private func makeTextureNormalized(from image: CGImage, width w: Int, height h: Int) -> MTLTexture? {
        let isDownsampling = w < image.width || h < image.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard
            let ctx = CGContext(
                data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        // Interpolation quality only matters when actually downsampling (a 1:1 draw ignores it).
        // `.medium` (bilinear) is materially cheaper on the render thread than `.high` (Lanczos) and
        // visually indistinguishable for grid thumbnails at these sizes; the full-res viewer decode
        // is a separate path that keeps high quality.
        ctx.interpolationQuality = isDownsampling ? .medium : .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let texture = makeEmptyTexture(width: w, height: h, swizzle: nil) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    /// A blank `rgba8Unorm`, shaderRead, non-mipmapped texture at `w×h`, optionally with a sampler swizzle so
    /// a direct upload of non-RGBA-ordered bytes still samples as straight `(R,G,B,A)`.
    private func makeEmptyTexture(width w: Int, height h: Int, swizzle: MTLTextureSwizzleChannels?) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        if let swizzle { descriptor.swizzle = swizzle }
        return device.makeTexture(descriptor: descriptor)
    }

    /// Map the platform-neutral GridCore swizzle description onto `MTLTextureSwizzleChannels`.
    private func mtlSwizzle(_ swizzle: CGImageDirectUpload.Swizzle) -> MTLTextureSwizzleChannels {
        func map(_ channel: CGImageDirectUpload.Channel) -> MTLTextureSwizzle {
            switch channel {
            case .red: return .red
            case .green: return .green
            case .blue: return .blue
            case .alpha: return .alpha
            case .one: return .one
            }
        }
        return MTLTextureSwizzleChannels(
            red: map(swizzle.red), green: map(swizzle.green), blue: map(swizzle.blue), alpha: map(swizzle.alpha)
        )
    }

    // MARK: - Glyph textures (badges) - resident, not LRU-managed

    private var glyphs: [MetalGridGlyphRequest: MTLTexture] = [:]

    /// A cached, tinted SF-Symbol texture for a badge glyph. Resident for the session (a handful of small
    /// textures), so badge rendering is a cheap textured quad.
    package func glyphTexture(
        symbol: String,
        pixelSize: Int = 44,
        weight: MetalGridGlyphWeight = .bold,
        color: MetalGridGlyphColor
    ) -> MTLTexture? {
        let request = MetalGridGlyphRequest(symbol: symbol, pixelSize: pixelSize, weight: weight, color: color)
        return glyphTexture(for: request)
    }

    /// A cached single-character text texture. Callers intentionally submit individual duration/RAW glyphs,
    /// not complete labels, so the cache remains bounded to digits, punctuation, and the three RAW letters
    /// regardless of library size or the number of distinct video durations.
    package func glyphTexture(
        text: String,
        pixelSize: Int = 60,
        aspectRatio: Double,
        textStyle: MetalGridGlyphTextStyle = .system,
        weight: MetalGridGlyphWeight = .semibold,
        color: MetalGridGlyphColor
    ) -> MTLTexture? {
        let request = MetalGridGlyphRequest(
            text: text,
            pixelSize: pixelSize,
            aspectRatio: aspectRatio,
            textStyle: textStyle,
            weight: weight,
            color: color
        )
        return glyphTexture(for: request)
    }

    /// A cached upload badge texture. About 80 small glyphs (fill and checkmark steps) stay resident.
    package func uploadBadgeTexture(_ glyph: GridUploadBadgeGlyph) -> MTLTexture? {
        glyphTexture(for: MetalGridGlyphRequest(uploadBadge: glyph))
    }

    private func glyphTexture(for request: MetalGridGlyphRequest) -> MTLTexture? {
        if let cached = glyphs[request] { return cached }
        guard let cg = glyphRasterizer.image(for: request) else { return nil }
        // Rasterize against the ABSOLUTE cap, never the per-frame thumbnail cap. The rendered quad still scales
        // with its badge geometry; keeping one sharp cached glyph texture prevents dense levels from getting a
        // separately rasterized blurry alphabet.
        let size = uploadPixelSize(for: cg, cap: maxTexturePixels)
        guard let texture = makeTexture(from: cg, width: size.width, height: size.height) else { return nil }
        glyphs[request] = texture
        return texture
    }

    /// A small neutral warm-gray texture used as the resting placeholder + letterbox background.
    private static func makePlaceholder(device: MTLDevice) -> MTLTexture? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 40
            pixels[i + 1] = 38
            pixels[i + 2] = 36
            pixels[i + 3] = 255  // warm dark gray
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side * 4)
        return texture
    }
}
