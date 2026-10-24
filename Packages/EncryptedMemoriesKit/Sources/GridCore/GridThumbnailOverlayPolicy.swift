import CoreGraphics

/// Platform-neutral metadata shown inside a grid thumbnail.
///
/// Photo-domain mapping lives in TimelineCore. GridCore owns only the visual contract so every host uses the
/// same label content, geometry, and fade behavior.
package struct GridThumbnailOverlay: Equatable, Sendable {
    package var durationText: String?
    package var showsRAW: Bool
    /// Backup state of a photo that is still on its way to Proton; drawn in the top-trailing corner.
    package var uploadBadge: GridUploadBadge?

    package init(durationText: String? = nil, showsRAW: Bool = false, uploadBadge: GridUploadBadge? = nil) {
        self.durationText = durationText
        self.showsRAW = showsRAW
        self.uploadBadge = uploadBadge
    }

    package static let empty = GridThumbnailOverlay()
}

/// Upload state shown on a pending tile: an empty circle while waiting, a circle that fills while bytes move, a
/// checkmark once backed up, an exclamation mark for a failure that needs the person, and a pause symbol while
/// the person pauses the backup.
package enum GridUploadBadge: Equatable, Hashable, Sendable {
    package static let progressSteps = 20

    case waiting
    /// `step` of `progressSteps`.
    case uploading(step: Int)
    case done
    case attention
    /// A photo in "Zuletzt gelöscht" that was deleted before it uploaded: it exists only on this device.
    case notBackedUp
    /// A waiting or uploading photo while the person pauses the backup.
    case paused
}

package enum GridThumbnailOverlayLabelKind: Equatable, Sendable {
    case duration
    case raw
}

package struct GridThumbnailOverlayGlyphLayout: Equatable, Sendable {
    package var text: String
    package var rect: CGRect

    package init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

package struct GridThumbnailOverlayLabelLayout: Equatable, Sendable {
    package var kind: GridThumbnailOverlayLabelKind
    package var backgroundRect: CGRect
    package var glyphs: [GridThumbnailOverlayGlyphLayout]
    package var alpha: CGFloat

    package init(
        kind: GridThumbnailOverlayLabelKind,
        backgroundRect: CGRect,
        glyphs: [GridThumbnailOverlayGlyphLayout],
        alpha: CGFloat
    ) {
        self.kind = kind
        self.backgroundRect = backgroundRect
        self.glyphs = glyphs
        self.alpha = alpha
    }
}

/// Layout policy for duration and RAW labels.
///
/// Labels follow the displayed media rectangle through layout transitions. They use a fixed readable size and
/// are omitted when either the thumbnail or the formatted text is too small to present without clipping.
package enum GridThumbnailOverlayPolicy {
    package static let minimumReadableSide: CGFloat = 68

    package static func layouts(
        for overlay: GridThumbnailOverlay,
        in displayedRect: CGRect,
        bottomTrailingInset: CGFloat = 0
    ) -> [GridThumbnailOverlayLabelLayout] {
        guard displayedRect.width > 0, displayedRect.height > 0 else { return [] }

        var result: [GridThumbnailOverlayLabelLayout] = []
        if let duration = overlay.durationText,
            let layout = makeLayout(
                text: duration,
                kind: .duration,
                displayedRect: displayedRect,
                bottomTrailingInset: max(0, bottomTrailingInset)
            )
        {
            result.append(layout)
        }
        if overlay.showsRAW,
            let layout = makeLayout(
                text: "RAW",
                kind: .raw,
                displayedRect: displayedRect,
                bottomTrailingInset: 0
            )
        {
            result.append(layout)
        }
        return result
    }

    private static func makeLayout(
        text: String,
        kind: GridThumbnailOverlayLabelKind,
        displayedRect: CGRect,
        bottomTrailingInset: CGFloat
    ) -> GridThumbnailOverlayLabelLayout? {
        guard !text.isEmpty else { return nil }

        let shortSide = min(displayedRect.width, displayedRect.height)
        let height: CGFloat
        let outerPadding: CGFloat
        let innerPadding: CGFloat
        let glyphHeight: CGFloat
        switch kind {
        case .duration:
            // Keep the duration readable until the compact level omits it.
            guard shortSide >= minimumReadableSide else { return nil }
            height = 20
            outerPadding = 0
            innerPadding = 2.5
            glyphHeight = 13
        case .raw:
            // RAW follows the same readable-or-absent contract as duration.
            guard shortSide >= minimumReadableSide else { return nil }
            height = 20
            outerPadding = 5
            innerPadding = 3
            glyphHeight = 13
        }
        let glyphTexts = text.map(String.init)
        let glyphWidths = glyphTexts.map { glyphWidth(for: $0, kind: kind, height: glyphHeight) }
        let width = glyphWidths.reduce(0, +) + 2 * innerPadding
        let trailingInset = kind == .duration ? bottomTrailingInset : 0
        let badgeRequiredWidth = width + 2 * outerPadding
        let requiredWidth = badgeRequiredWidth + trailingInset
        let requiredHeight = height + 2 * outerPadding
        guard requiredWidth <= displayedRect.width, requiredHeight <= displayedRect.height else { return nil }
        // Preserve enough visible image around duration labels even when the text technically fits.
        if kind == .duration, badgeRequiredWidth > displayedRect.width * 0.75 { return nil }

        let originX: CGFloat
        let originY: CGFloat
        switch kind {
        case .duration:
            originX = displayedRect.maxX - outerPadding - trailingInset - width
            originY = displayedRect.maxY - outerPadding - height
        case .raw:
            originX = displayedRect.minX + outerPadding
            originY = displayedRect.minY + outerPadding
        }
        let background = CGRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )

        var glyphs: [GridThumbnailOverlayGlyphLayout] = []
        glyphs.reserveCapacity(glyphTexts.count)
        var glyphX = background.minX + innerPadding
        let glyphY = background.midY - glyphHeight / 2
        for (glyph, glyphWidth) in zip(glyphTexts, glyphWidths) {
            glyphs.append(
                GridThumbnailOverlayGlyphLayout(
                    text: glyph,
                    rect: CGRect(x: glyphX, y: glyphY, width: glyphWidth, height: glyphHeight)
                )
            )
            glyphX += glyphWidth
        }

        return GridThumbnailOverlayLabelLayout(
            kind: kind,
            backgroundRect: background,
            glyphs: glyphs,
            alpha: 1
        )
    }

    private static func glyphWidth(
        for glyph: String,
        kind: GridThumbnailOverlayLabelKind,
        height: CGFloat
    ) -> CGFloat {
        switch kind {
        case .duration:
            return height * 0.62
        case .raw:
            return height * (glyph == "W" ? 0.84 : 0.66)
        }
    }
}
