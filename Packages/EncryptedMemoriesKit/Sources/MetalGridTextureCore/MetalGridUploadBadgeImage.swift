import CoreGraphics
import GridCore

/// Draws upload badges with CoreGraphics only, for every platform alike. A dark translucent disc with a white
/// outline keeps the badge legible on bright photos. Progress fills the disc with white like a pie until it is
/// solid; the checkmark then draws itself on that white disc. A paused upload shows two white bars in the empty
/// circle. `GridUploadBadgeAnimator` picks the steps.
package enum MetalGridUploadBadgeImage {
    /// The SF Symbol a platform rasterizer renders for `glyph`, when the glyph carries one.
    package static func symbolName(for glyph: GridUploadBadgeGlyph) -> String? { glyph.symbolName }

    /// `symbol` is the host-rendered white `symbolName(for:)`, drawn centered on the disc.
    package static func make(_ glyph: GridUploadBadgeGlyph, pixelSize: Int, symbol: CGImage? = nil) -> CGImage? {
        guard pixelSize > 0,
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let size = CGFloat(pixelSize)
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let disc = bounds.insetBy(dx: size * 0.04, dy: size * 0.04)
        context.setShouldAntialias(true)
        switch glyph {
        case .pie(let step):
            let steps = GridUploadBadgeGlyph.pieSteps
            drawPie(context, in: disc, fraction: Double(min(max(step, 0), steps)) / Double(steps))
        case .check(let step):
            // The same white as the full circle, so the checkmark draws onto it without a change of tone.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: disc)
            let steps = GridUploadBadgeGlyph.checkSteps
            drawCheckmark(context, in: disc, drawn: Double(min(max(step, 0), steps)) / Double(steps))
        case .paused:
            drawPie(context, in: disc, fraction: 0)
            drawPauseBars(context, in: disc)
        case .attention:
            drawDisc(context, disc)
            drawExclamation(context, in: disc)
        case .notBackedUp:
            drawDisc(context, disc)
            if let symbol {
                let side = disc.width * 0.62
                let aspect = CGFloat(symbol.width) / CGFloat(max(1, symbol.height))
                let width = aspect >= 1 ? side : side * aspect
                let height = aspect >= 1 ? side / aspect : side
                context.draw(
                    symbol,
                    in: CGRect(x: disc.midX - width / 2, y: disc.midY - height / 2, width: width, height: height))
            }
        }
        return context.makeImage()
    }

    private static func drawDisc(_ context: CGContext, _ rect: CGRect) {
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        context.fillEllipse(in: rect)
    }

    private static func drawPie(_ context: CGContext, in disc: CGRect, fraction: Double) {
        drawDisc(context, disc)
        let lineWidth = disc.width * 0.07
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        if fraction > 0 {
            let center = CGPoint(x: disc.midX, y: disc.midY)
            // CoreGraphics has a bottom-left origin: start at 12 o'clock and fill clockwise.
            let start = CGFloat.pi / 2
            let end = start - CGFloat(min(1, fraction)) * 2 * .pi
            context.setFillColor(white)
            context.move(to: center)
            context.addArc(center: center, radius: disc.width / 2, startAngle: start, endAngle: end, clockwise: true)
            context.closePath()
            context.fillPath()
        }
        context.setStrokeColor(white)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: disc.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }

    /// The checkmark stroke drawn from its start to `drawn` of its length, as a pen would draw it.
    private static func drawCheckmark(_ context: CGContext, in disc: CGRect, drawn: Double) {
        guard drawn > 0 else { return }
        let width = disc.width
        let points = [
            CGPoint(x: disc.minX + width * 0.29, y: disc.minY + width * 0.51),
            CGPoint(x: disc.minX + width * 0.44, y: disc.minY + width * 0.35),
            CGPoint(x: disc.minX + width * 0.72, y: disc.minY + width * 0.66),
        ]
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = CGFloat(min(1, drawn)) * lengths.reduce(0, +)
        context.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(width * 0.11)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: points[0])
        for (index, length) in lengths.enumerated() where remaining > 0 {
            let from = points[index]
            let to = points[index + 1]
            let share = min(1, remaining / max(length, 0.0001))
            context.addLine(to: CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share))
            remaining -= length
        }
        context.strokePath()
    }

    /// Two vertical bars with round ends, centered on the disc.
    private static func drawPauseBars(_ context: CGContext, in disc: CGRect) {
        let width = disc.width
        let bar = CGSize(width: width * 0.11, height: width * 0.36)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for offset in [-width * 0.1, width * 0.1] {
            let rect = CGRect(
                x: disc.midX + offset - bar.width / 2, y: disc.midY - bar.height / 2, width: bar.width,
                height: bar.height)
            context.addPath(
                CGPath(roundedRect: rect, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2, transform: nil))
        }
        context.fillPath()
    }

    private static func drawExclamation(_ context: CGContext, in disc: CGRect) {
        let width = disc.width
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(width * 0.11)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: disc.midX, y: disc.minY + width * 0.72))
        context.addLine(to: CGPoint(x: disc.midX, y: disc.minY + width * 0.44))
        context.strokePath()
        let dot = width * 0.12
        context.fillEllipse(in: CGRect(x: disc.midX - dot / 2, y: disc.minY + width * 0.22, width: dot, height: dot))
    }
}
