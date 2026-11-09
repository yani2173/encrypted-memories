import CoreGraphics
import Foundation
import GridCore

// MARK: - Metal grid shared value types
//
// Per-frame render accounting for the Metal-backed photo grid. The scroll host owns
// physics, and the viewport-sized MTKView draws visible items through the texture cache.

/// Per-frame render accounting for the `[MetalGridPerf]` diagnostics block.
struct MetalGridStats: Equatable, Sendable {
    var visibleItems = 0
    var overscanItems = 0
    var realTextureItems = 0
    var placeholderItems = 0
    var textureUploads = 0
    var textureUploadBytes = 0
    var deferredTextureUploads = 0
    var cacheHits = 0
    var cacheMisses = 0
    var evictions = 0
    var evictMs: Double = 0
    var residentTextureCount = 0
    var pinnedTextureCount = 0
    var textureCapacity = 0
    var pinnedTextureOverflow = false
    var residentByteBudget = 0
    var uploadByteBudget = 0
    var byteBudgetOverflow = false
    var residencySaturated = false
    var encodedSlotItems = 0
    var drawCalls = 0
    var textureBinds = 0
    var instanceCount = 0
    var cpuLayoutMs: Double = 0
    var cpuInstanceMs: Double = 0
    var textureUploadMs: Double = 0
    var drawMs: Double = 0
    var gpuMs: Double = 0
    var fpsEstimate: Double = 0
    var memoryEstimateBytes = 0

    var summary: String {
        "visibleItems=\(visibleItems) overscanItems=\(overscanItems) realTextureItems=\(realTextureItems) "
            + "placeholderItems=\(placeholderItems) textureUploads=\(textureUploads) textureUploadBytes=\(textureUploadBytes) "
            + "deferredTextureUploads=\(deferredTextureUploads) cacheHits=\(cacheHits) cacheMisses=\(cacheMisses) "
            + "evictions=\(evictions) evictMs=\(fmt(evictMs)) residentTextureCount=\(residentTextureCount) "
            + "pinnedTextureCount=\(pinnedTextureCount) textureCapacity=\(textureCapacity) "
            + "pinnedTextureOverflow=\(pinnedTextureOverflow) encodedSlotItems=\(encodedSlotItems) "
            + "residentBudgetMB=\(fmt(Double(residentByteBudget) / 1_048_576)) uploadBudgetBytes=\(uploadByteBudget) "
            + "byteBudgetOverflow=\(byteBudgetOverflow) residencySaturated=\(residencySaturated) "
            + "drawCalls=\(drawCalls) textureBinds=\(textureBinds) "
            + "instanceCount=\(instanceCount) cpuLayoutMs=\(fmt(cpuLayoutMs)) cpuInstanceMs=\(fmt(cpuInstanceMs)) "
            + "textureUploadMs=\(fmt(textureUploadMs)) drawMs=\(fmt(drawMs)) gpuMs=\(fmt(gpuMs)) fpsEstimate=\(fmt(fpsEstimate)) "
            + "memoryEstimateMB=\(fmt(Double(memoryEstimateBytes) / 1_048_576))"
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Derives visible, real, and placeholder counts from a frame's draw list without Metal. The
    /// `realResident(id)` closure reports whether a GPU texture is resident for each item.
    static func counts<ID>(
        visibleCount: Int,
        overscanCount: Int,
        drawnUIDs: [ID],
        realResident: (ID) -> Bool
    ) -> (real: Int, placeholder: Int) {
        var real = 0
        for uid in drawnUIDs where realResident(uid) { real += 1 }
        return (real, drawnUIDs.count - real)
    }

    static func frame(
        visibleCount: Int,
        overscanCount: Int,
        realCount: Int,
        cellCount: Int,
        textureUploads: Int,
        textureUploadBytes: Int,
        deferredTextureUploads: Int,
        textureUploadMs: Double,
        evictions: Int,
        evictMs: Double,
        residentBytes: Int,
        residentTextureCount: Int,
        pinnedTextureCount: Int,
        textureCapacity: Int,
        pinnedTextureOverflow: Bool,
        residentByteBudget: Int,
        uploadByteBudget: Int,
        byteBudgetOverflow: Bool,
        residencySaturated: Bool,
        drawCalls: Int,
        textureBinds: Int,
        instanceCount: Int,
        drawMs: Double,
        gpuMs: Double
    ) -> MetalGridStats {
        var stats = MetalGridStats()
        stats.visibleItems = visibleCount
        stats.overscanItems = overscanCount
        stats.realTextureItems = realCount
        stats.placeholderItems = max(0, cellCount - realCount)
        stats.encodedSlotItems = cellCount
        stats.textureUploads = textureUploads
        stats.textureUploadBytes = textureUploadBytes
        stats.deferredTextureUploads = deferredTextureUploads
        stats.textureUploadMs = textureUploadMs
        stats.evictions = evictions
        stats.evictMs = evictMs
        stats.memoryEstimateBytes = residentBytes
        stats.residentTextureCount = residentTextureCount
        stats.pinnedTextureCount = pinnedTextureCount
        stats.textureCapacity = textureCapacity
        stats.pinnedTextureOverflow = pinnedTextureOverflow
        stats.residentByteBudget = residentByteBudget
        stats.uploadByteBudget = uploadByteBudget
        stats.byteBudgetOverflow = byteBudgetOverflow
        stats.residencySaturated = residencySaturated
        stats.cacheHits = realCount
        stats.cacheMisses = stats.placeholderItems
        stats.drawCalls = drawCalls
        stats.textureBinds = textureBinds
        stats.instanceCount = instanceCount
        stats.drawMs = drawMs
        stats.gpuMs = gpuMs
        return stats
    }
}

typealias MetalGridBudget = GridTextureBudget
