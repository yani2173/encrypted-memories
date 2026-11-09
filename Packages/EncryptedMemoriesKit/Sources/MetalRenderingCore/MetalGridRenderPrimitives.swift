import CoreGraphics
import Metal
import QuartzCore
import simd

/// How a quad is shaded by the shared Metal grid renderer.
package enum MetalGridQuadMode: Int32 {
    case textured = 0
    case solid = 1
    case border = 2
    case thumbnailPlaceholder = 3
}

/// One quad in viewport coordinates, with its texture UV window, corner radius, alpha, and shader mode.
package struct MetalGridQuad {
    package var rect: CGRect
    package var uvMin: SIMD2<Float>
    package var uvMax: SIMD2<Float>
    package var radius: Float
    package var alpha: Float
    package var color: SIMD4<Float>
    package var mode: MetalGridQuadMode
    package var borderWidth: Float

    package init(
        rect: CGRect,
        uvMin: SIMD2<Float> = SIMD2(0, 0),
        uvMax: SIMD2<Float> = SIMD2(1, 1),
        radius: Float,
        alpha: Float = 1,
        color: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        mode: MetalGridQuadMode = .textured,
        borderWidth: Float = 0
    ) {
        self.rect = rect
        self.uvMin = uvMin
        self.uvMax = uvMax
        self.radius = radius
        self.alpha = alpha
        self.color = color
        self.mode = mode
        self.borderWidth = borderWidth
    }
}

/// A batch of quads sharing draw state.
package struct MetalGridRenderGroup {
    package enum Source {
        case sharedTexture(MTLTexture)
        case perQuadTexture([MTLTexture])
    }

    package var source: Source
    package var quads: [MetalGridQuad]

    package init(source: Source, quads: [MetalGridQuad]) {
        self.source = source
        self.quads = quads
    }
}

/// Narrow drawable boundary for shared Metal rendering. Platform adapters create surfaces and pass this in.
package struct MetalGridDrawableTarget {
    package let drawable: CAMetalDrawable
    package let renderPassDescriptor: MTLRenderPassDescriptor
    package let presentsWithTransaction: Bool

    package var pixelSize: CGSize {
        CGSize(width: drawable.texture.width, height: drawable.texture.height)
    }

    /// Adds a bounded, callback-only observation of the actual Core Animation presentation. Callers must keep
    /// the handler nonblocking; Metal can invoke it away from the main actor.
    package func addPresentedHandler(_ handler: @escaping @Sendable (CFTimeInterval?) -> Void) {
        #if targetEnvironment(simulator)
            // The simulator MTLDrawable protocol omits addPresentedHandler/presentedTime. Leave presentation
            // unavailable there; deterministic tests exercise the accumulator directly instead of fabricating it.
            _ = handler
        #else
            drawable.addPresentedHandler { drawable in
                let presentedTime = drawable.presentedTime
                handler(presentedTime > 0 ? presentedTime : nil)
            }
        #endif
    }

    package init(
        drawable: CAMetalDrawable,
        renderPassDescriptor: MTLRenderPassDescriptor,
        presentsWithTransaction: Bool
    ) {
        self.drawable = drawable
        self.renderPassDescriptor = renderPassDescriptor
        self.presentsWithTransaction = presentsWithTransaction
    }
}

/// Shared render-surface palette values. Platform adapters may expose these through native color wrappers.
package enum MetalGridRenderPalette {
    package static let backgroundRGBA: (r: Double, g: Double, b: Double, a: Double) = (0.122, 0.122, 0.122, 1.0)

    package static var clearColor: MTLClearColor {
        MTLClearColor(
            red: backgroundRGBA.r,
            green: backgroundRGBA.g,
            blue: backgroundRGBA.b,
            alpha: backgroundRGBA.a
        )
    }

    package static var backgroundVector: SIMD4<Float> {
        SIMD4(
            Float(backgroundRGBA.r),
            Float(backgroundRGBA.g),
            Float(backgroundRGBA.b),
            Float(backgroundRGBA.a)
        )
    }
}
