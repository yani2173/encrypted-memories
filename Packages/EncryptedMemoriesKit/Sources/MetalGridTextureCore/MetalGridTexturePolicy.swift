import GridCore

/// The texture budget and the pixel ceiling of one grid surface. Every platform uses this shape; the value
/// tables stay in the platform adapters, because they are real platform values.
package struct MetalGridTexturePolicy: Equatable, Sendable {
    package let budget: GridTextureBudget
    package let maxTexturePixels: Int

    package init(budget: GridTextureBudget, maxTexturePixels: Int) {
        self.budget = budget
        self.maxTexturePixels = maxTexturePixels
    }
}
