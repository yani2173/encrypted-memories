import CoreGraphics
import GridCore
import MetalGridTextureCore

package typealias AppKitMetalGridTexturePolicy = MetalGridTexturePolicy

package enum AppKitMetalGridTexturePolicies {
    package static let defaultMaxTexturePixels = 320

    /// macOS desktop budget. Byte and time budgets are binding; count limits are structural backstops.
    /// The resident byte cap is 512 MiB, the texture count cap is 16,384, and each frame allows 6 MiB
    /// of uploads and 6 ms of upload work. Level-aware texture sizes let the byte cap govern dense levels.
    package static let `default` = AppKitMetalGridTexturePolicy(
        budget: GridTextureBudget(
            maxUploadsPerFrame: 48, maxUploadBytesPerFrame: 6_291_456, maxCachedTextures: 16_384,
            maxResidentBytes: 536_870_912, overscanFraction: 1.2, maxUploadMillisecondsPerFrame: 6.0),
        maxTexturePixels: defaultMaxTexturePixels
    )

    package static func policy(
        budget: GridTextureBudget,
        maxTexturePixels: Int = defaultMaxTexturePixels
    ) -> AppKitMetalGridTexturePolicy {
        AppKitMetalGridTexturePolicy(budget: budget, maxTexturePixels: maxTexturePixels)
    }
}

package extension GridTextureBudget {
    /// macOS adapter default. Other adapters must inject their own measured policy.
    static let `default` = AppKitMetalGridTexturePolicies.default.budget
}
