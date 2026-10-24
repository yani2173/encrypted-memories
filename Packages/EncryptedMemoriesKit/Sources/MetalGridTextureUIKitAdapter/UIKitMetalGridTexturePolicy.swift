import CoreGraphics
import GridCore
import MetalGridTextureCore

package enum UIKitMetalGridTextureSurfaceClass: String, Sendable {
    case compact
    case regular
    case expanded

    package static func resolving(viewportSize: CGSize) -> Self {
        let shortestSide = min(viewportSize.width, viewportSize.height)
        if shortestSide < 430 { return .compact }
        if shortestSide < 768 { return .regular }
        return .expanded
    }
}

package typealias UIKitMetalGridTexturePolicy = MetalGridTexturePolicy

/// Per-surface iOS/iPadOS texture budgets.
///
/// Byte caps reserve memory for decoded and byte caches; dense
/// levels use lower upload caps, while sparse levels use the absolute pixel ceiling.
package enum UIKitMetalGridTexturePolicies {
    package static let compact = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(
            maxUploadsPerFrame: 16, maxUploadBytesPerFrame: 2_097_152, maxCachedTextures: 2_048,
            maxResidentBytes: 67_108_864, overscanFraction: 0.75, maxUploadMillisecondsPerFrame: 2.5),
        maxTexturePixels: 480
    )

    package static let regular = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(
            maxUploadsPerFrame: 24, maxUploadBytesPerFrame: 3_145_728, maxCachedTextures: 3_072,
            maxResidentBytes: 100_663_296, overscanFraction: 0.9, maxUploadMillisecondsPerFrame: 3.5),
        maxTexturePixels: 512
    )

    package static let expanded = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(
            maxUploadsPerFrame: 32, maxUploadBytesPerFrame: 4_194_304, maxCachedTextures: 6_144,
            maxResidentBytes: 201_326_592, overscanFraction: 1.0, maxUploadMillisecondsPerFrame: 4.5),
        maxTexturePixels: 512
    )

    package static func policy(for surfaceClass: UIKitMetalGridTextureSurfaceClass) -> UIKitMetalGridTexturePolicy {
        switch surfaceClass {
        case .compact: compact
        case .regular: regular
        case .expanded: expanded
        }
    }

    package static func policy(forViewportSize viewportSize: CGSize) -> UIKitMetalGridTexturePolicy {
        policy(for: UIKitMetalGridTextureSurfaceClass.resolving(viewportSize: viewportSize))
    }
}
