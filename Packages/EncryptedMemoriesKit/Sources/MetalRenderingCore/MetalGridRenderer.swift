import CoreGraphics
import Metal
import QuartzCore
import simd

/// The persistent Metal renderer for the grid. Draws one quad per visible cell (rounded-corner SDF +
/// premultiplied alpha), plus solid/border/glyph quads for selection outlines and badges.
///
/// Platform adapters own view hosting and convert their drawable surface into `MetalGridDrawableTarget`.
package final class MetalGridRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let clearColor: MTLClearColor
    /// Two-texture linear-mix pipeline for overview dissolves. Nil when shader setup fails.
    private let compositePipeline: MTLRenderPipelineState?
    /// `true` when the dissolve composite pipeline could not be built. Dissolves then draw the target layer
    /// directly; the platform adapter reports this through its diagnostics.
    package let compositePipelineUnavailable: Bool
    /// Offscreen source and target render targets used by `renderLayerDissolve`.
    private var layerA: MTLTexture?
    private var layerB: MTLTexture?
    /// Which frozen dissolve layers actually need re-rasterizing this frame (pure state machine); a steady
    /// scrub reuses both offscreen textures and only re-runs the cheap composite.
    private var dissolveCache = DissolveLayerCache()

    package private(set) var lastEncodeMs: Double = 0
    package private(set) var lastGpuMs: Double = 0
    package private(set) var lastCompletedGpuMs: Double?
    package private(set) var lastFrameBoundaryWaitMs: Double = 0
    package private(set) var lastDrawCalls = 0
    package private(set) var lastInstanceCount = 0
    package private(set) var lastTextureBinds = 0
    private var pendingGpuCommandBuffers: [MTLCommandBuffer] = []

    /// Triple-buffered vertex pool for the steady `render(...)` path: instead of allocating a fresh
    /// `MTLBuffer` per group every frame, each frame packs all groups' vertices into one growable,
    /// reused buffer (per-group byte offsets) drawn from a 3-deep ring. `frameBoundary` bounds the CPU
    /// to `maxInFlight` frames ahead of the GPU so a pooled buffer is never overwritten while a prior
    /// frame still reads it. The offscreen dissolve path keeps simple per-group allocation (transient).
    private static let maxInFlight = 3
    private let frameBoundary = DispatchSemaphore(value: maxInFlight)
    private var vertexPool: [MTLBuffer?] = Array(repeating: nil, count: maxInFlight)
    private var frameCounter = 0

    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var local: SIMD2<Float>
        var size: SIMD2<Float>
        var radius: Float
        var alpha: Float
        var color: SIMD4<Float>
        var mode: Float
        var borderWidth: Float
    }
    private struct Uniforms { var viewportSize: SIMD2<Float> }

    package init?(device: MTLDevice, clearColor: MTLClearColor = MetalGridRenderPalette.clearColor) {
        self.device = device
        self.clearColor = clearColor
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vfn = library.makeFunction(name: "metalGridVertex"),
                let ffn = library.makeFunction(name: "metalGridFragment")
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vfn
            descriptor.fragmentFunction = ffn
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            // Composite pipeline: opaque (no blending) fullscreen linear mix of two layer textures.
            let composite: MTLRenderPipelineState?
            if let cv = library.makeFunction(name: "metalGridCompositeVertex"),
                let cf = library.makeFunction(name: "metalGridCompositeFragment")
            {
                let cd = MTLRenderPipelineDescriptor()
                cd.vertexFunction = cv
                cd.fragmentFunction = cf
                cd.colorAttachments[0].pixelFormat = .bgra8Unorm
                cd.colorAttachments[0].isBlendingEnabled = false
                composite = try? device.makeRenderPipelineState(descriptor: cd)
            } else {
                composite = nil
            }
            self.compositePipeline = composite
            self.compositePipelineUnavailable = composite == nil

            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge
            sd.tAddressMode = .clampToEdge
            guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
            self.sampler = sampler
        } catch {
            return nil
        }
    }

    @MainActor
    @discardableResult
    package func render(
        to target: MetalGridDrawableTarget, viewportSize: CGSize, groups: [MetalGridRenderGroup]
    ) -> Bool {
        drainCompletedGpuTimings()
        lastFrameBoundaryWaitMs = 0
        let start = CFAbsoluteTimeGetCurrent()
        defer { lastEncodeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let pass = target.renderPassDescriptor
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.commit()
            return false
        }
        // Claim a pool slot only once we're committed to drawing (the guards above can early-return without
        // a matching signal). The completion handler releases it when the GPU is done with this frame.
        let boundaryWaitStarted = CFAbsoluteTimeGetCurrent()
        frameBoundary.wait()
        lastFrameBoundaryWaitMs = (CFAbsoluteTimeGetCurrent() - boundaryWaitStarted) * 1000
        frameCounter &+= 1
        let slot = frameCounter % Self.maxInFlight
        commandBuffer.addCompletedHandler { [frameBoundary] _ in frameBoundary.signal() }
        configure(encoder, viewportSize: viewportSize)
        let (drawCalls, instances, textureBinds) = encode(groups: groups, into: encoder, pooledSlot: slot)
        encoder.endEncoding()
        pendingGpuCommandBuffers.append(commandBuffer)
        present(commandBuffer, to: target)
        lastDrawCalls = drawCalls
        lastInstanceCount = instances
        lastTextureBinds = textureBinds
        return instances == groups.reduce(0) { $0 + $1.quads.count }
    }

    /// Set the shared per-frame state (pipeline, sampler, viewport uniforms) on an encoder. Used by the
    /// normal `render(...)` AND the offscreen layer passes, so both rasterise identically.
    private func configure(_ encoder: MTLRenderCommandEncoder, viewportSize: CGSize) {
        var uniforms = Uniforms(
            viewportSize: SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1))))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    }

    /// Encode all groups from back to front on an already-configured encoder. Returns draw calls, instances, and binds.
    /// Pure w.r.t. the encoder - identical work whether the target is the drawable or an offscreen texture.
    ///
    /// `pooledSlot` selects the vertex storage. A non-nil slot writes each group's vertices directly into
    /// the reused ring buffer at precomputed offsets. `nil` uses the offscreen dissolve path with per-group
    /// arrays and a fresh shared buffer. Both paths preserve group order, draw order, and draw-call,
    /// instance, and texture-bind counts.
    @discardableResult
    private func encode(
        groups: [MetalGridRenderGroup], into encoder: MTLRenderCommandEncoder, pooledSlot: Int? = nil
    ) -> (Int, Int, Int) {
        let stride = MemoryLayout<Vertex>.stride
        // Group metadata only (no vertices yet): source order preserved; each non-empty group reserves a
        // contiguous `quadCount * 6`-vertex run, its start offset recorded up front so the pooled and
        // per-group paths bind identical byte offsets.
        var planned: [(group: MetalGridRenderGroup, vertexOffset: Int)] = []
        planned.reserveCapacity(groups.count)
        var totalVerts = 0
        for group in groups where !group.quads.isEmpty {
            planned.append((group, totalVerts))
            totalVerts += group.quads.count * 6
        }
        guard totalVerts > 0 else { return (0, 0, 0) }

        // Steady path: grow the ring slot once, then write each quad's six vertices straight into it.
        let packed: MTLBuffer?
        if let slot = pooledSlot {
            let buffer = pooledBuffer(slot: slot, byteCount: totalVerts * stride)
            packed = buffer
            if let buffer {
                let base = buffer.contents().assumingMemoryBound(to: Vertex.self)
                for (group, vertexOffset) in planned {
                    var cursor = base.advanced(by: vertexOffset)
                    for q in group.quads {
                        writeQuad(q, into: cursor)
                        cursor = cursor.advanced(by: 6)
                    }
                }
            }
        } else {
            packed = nil  // per-group allocation below
        }

        var drawCalls = 0
        var instances = 0
        var textureBinds = 0
        for (group, vertexOffset) in planned {
            let quadCount = group.quads.count
            let buffer: MTLBuffer
            let byteOffset: Int
            if let pooled = packed {
                buffer = pooled
                byteOffset = vertexOffset * stride
            } else {
                var verts: [Vertex] = []
                verts.reserveCapacity(quadCount * 6)
                for q in group.quads { appendQuad(into: &verts, q) }
                guard let b = device.makeBuffer(bytes: verts, length: stride * verts.count, options: .storageModeShared)
                else { continue }
                buffer = b
                byteOffset = 0
            }
            encoder.setVertexBuffer(buffer, offset: byteOffset, index: 0)
            switch group.source {
            case .sharedTexture(let texture):
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quadCount * 6)
                drawCalls += 1
                textureBinds += 1
                instances += quadCount
            case .perQuadTexture(let textures) where textures.count == quadCount:
                for (i, texture) in textures.enumerated() {
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
                    drawCalls += 1
                    textureBinds += 1
                    instances += 1
                }
            default:
                break
            }
        }
        return (drawCalls, instances, textureBinds)
    }

    /// The ring buffer for `slot`, grown (doubling) when the frame needs more than it currently holds.
    /// Bound by the `frameBoundary` semaphore, so the slot's prior frame has finished reading before reuse.
    private func pooledBuffer(slot: Int, byteCount: Int) -> MTLBuffer? {
        if let existing = vertexPool[slot], existing.length >= byteCount { return existing }
        let capacity = max(byteCount, (vertexPool[slot]?.length ?? 0) * 2)
        let buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
        vertexPool[slot] = buffer
        return buffer
    }

    // MARK: - Overview layer dissolve (offscreen, two-layer linear cross-dissolve)

    private func ensureLayerTextures(width: Int, height: Int) {
        if let a = layerA, a.width == width, a.height == height, layerB != nil { return }
        guard width > 0, height > 0 else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        layerA = device.makeTexture(descriptor: d)
        layerB = device.makeTexture(descriptor: d)
    }

    /// A new dissolve plan began (fresh begin): re-raster both layers on the next frame even if nothing has
    /// streamed in, so the new plan's geometry replaces the previous plan's frozen layers.
    @MainActor package func invalidateDissolveLayers() { dissolveCache.invalidate() }

    /// The dissolve committed/finished: drop the two offscreen textures (their GPU memory returns once the last
    /// in-flight command buffer that references them completes) and reset the layer cache.
    @MainActor package func endLayerDissolve() {
        layerA = nil
        layerB = nil
        dissolveCache.release()
    }

    /// Whether optional presentation pipelines are available.
    package var hasAuxiliaryPipelines: Bool { compositePipeline != nil }

    private func encodeLayerPass(
        into cmd: MTLCommandBuffer, texture: MTLTexture,
        groups: [MetalGridRenderGroup], viewportSize: CGSize
    ) -> (Int, Int, Int) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return (0, 0, 0) }
        configure(enc, viewportSize: viewportSize)
        let stats = encode(groups: groups, into: enc)
        enc.endEncoding()
        return stats
    }

    /// Renders two settled layers to offscreen targets and composites them with `A·(1−t) + B·t`. The cache
    /// re-rasterizes only invalidated layers; steady progress runs the fullscreen composite only.
    @MainActor
    package func renderLayerDissolve(
        to target: MetalGridDrawableTarget, viewportSize: CGSize,
        redrawSource: Bool, redrawTarget: Bool,
        sourceGroups: () -> [MetalGridRenderGroup],
        targetGroups: () -> [MetalGridRenderGroup], t: Float
    ) {
        drainCompletedGpuTimings()
        lastFrameBoundaryWaitMs = 0
        let start = CFAbsoluteTimeGetCurrent()
        defer { lastEncodeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
        guard let composite = compositePipeline,
            let cmd = commandQueue.makeCommandBuffer()
        else {
            render(to: target, viewportSize: viewportSize, groups: targetGroups())
            return
        }
        let width = Int(target.pixelSize.width)
        let height = Int(target.pixelSize.height)
        ensureLayerTextures(width: width, height: height)
        guard let texA = layerA, let texB = layerB else {
            render(to: target, viewportSize: viewportSize, groups: targetGroups())
            return  // safe fallback
        }
        // Decide which layers to draw. A layer-texture resize invalidates both cached layers.
        let draw = dissolveCache.plan(
            redrawSource: redrawSource, redrawTarget: redrawTarget, width: width, height: height)
        var sourceStats = (0, 0, 0)
        var targetStats = (0, 0, 0)
        if draw.source {
            sourceStats = encodeLayerPass(into: cmd, texture: texA, groups: sourceGroups(), viewportSize: viewportSize)
        }
        if draw.target {
            targetStats = encodeLayerPass(into: cmd, texture: texB, groups: targetGroups(), viewportSize: viewportSize)
        }
        let drawablePass = target.renderPassDescriptor
        drawablePass.colorAttachments[0].loadAction = .clear
        drawablePass.colorAttachments[0].clearColor = clearColor
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: drawablePass) else {
            cmd.commit()
            return
        }
        enc.setRenderPipelineState(composite)
        enc.setFragmentTexture(texA, index: 0)
        enc.setFragmentTexture(texB, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        var tt = max(0, min(1, t))
        enc.setFragmentBytes(&tt, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)  // fullscreen triangle
        enc.endEncoding()
        pendingGpuCommandBuffers.append(cmd)
        present(cmd, to: target)
        lastDrawCalls = sourceStats.0 + targetStats.0 + 1
        lastInstanceCount = sourceStats.1 + targetStats.1
        lastTextureBinds = sourceStats.2 + targetStats.2 + 2
    }

    @MainActor
    private func drainCompletedGpuTimings() {
        lastCompletedGpuMs = nil
        guard !pendingGpuCommandBuffers.isEmpty else { return }
        var stillPending: [MTLCommandBuffer] = []
        stillPending.reserveCapacity(pendingGpuCommandBuffers.count)
        for commandBuffer in pendingGpuCommandBuffers {
            if commandBuffer.status == .completed {
                if let duration = Self.gpuDurationMs(commandBuffer) {
                    lastGpuMs = duration
                    lastCompletedGpuMs = duration
                }
            } else {
                stillPending.append(commandBuffer)
            }
        }
        pendingGpuCommandBuffers = stillPending
    }

    private static func gpuDurationMs(_ commandBuffer: MTLCommandBuffer) -> Double? {
        let start = commandBuffer.gpuStartTime
        let end = commandBuffer.gpuEndTime
        guard start > 0, end >= start else { return nil }
        return (end - start) * 1000
    }

    private func present(_ commandBuffer: MTLCommandBuffer, to target: MetalGridDrawableTarget) {
        if target.presentsWithTransaction {
            // During live resize, present inside the window's CATransaction so the frame follows the window
            // border. Settled, scroll, and zoom paths use asynchronous presentation.
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            target.drawable.present()
        } else {
            commandBuffer.present(target.drawable)
            commandBuffer.commit()
        }
    }

    /// The six triangle vertices for one quad (two triangles: tl,bl,tr / tr,bl,br), the single source of the
    /// renderer's vertex layout. Shared by the pooled direct-write path (`writeQuad`) and the transient
    /// per-group path (`appendQuad`) so both emit byte-identical geometry.
    private func quadVertices(_ q: MetalGridQuad) -> (Vertex, Vertex, Vertex, Vertex, Vertex, Vertex) {
        let x0 = Float(q.rect.minX)
        let y0 = Float(q.rect.minY)
        let x1 = Float(q.rect.maxX)
        let y1 = Float(q.rect.maxY)
        let w = Float(q.rect.width)
        let h = Float(q.rect.height)
        let size = SIMD2(w, h)
        let m = Float(q.mode.rawValue)
        func v(_ px: Float, _ py: Float, _ ux: Float, _ uy: Float, _ lx: Float, _ ly: Float) -> Vertex {
            Vertex(
                position: SIMD2(px, py), uv: SIMD2(ux, uy), local: SIMD2(lx, ly), size: size,
                radius: q.radius, alpha: q.alpha, color: q.color, mode: m, borderWidth: q.borderWidth)
        }
        let tl = v(x0, y0, q.uvMin.x, q.uvMin.y, 0, 0)
        let tr = v(x1, y0, q.uvMax.x, q.uvMin.y, w, 0)
        let bl = v(x0, y1, q.uvMin.x, q.uvMax.y, 0, h)
        let br = v(x1, y1, q.uvMax.x, q.uvMax.y, w, h)
        return (tl, bl, tr, tr, bl, br)
    }

    /// Append one quad's six vertices to a growable array - the transient offscreen dissolve path.
    private func appendQuad(into verts: inout [Vertex], _ q: MetalGridQuad) {
        let (a, b, c, d, e, f) = quadVertices(q)
        verts.append(contentsOf: [a, b, c, d, e, f])
    }

    /// Write one quad's six vertices directly into pooled ring-buffer memory (six contiguous `Vertex` slots
    /// from `ptr`). `Vertex` is trivial, so assigning into possibly-uninitialised buffer memory is safe.
    private func writeQuad(_ q: MetalGridQuad, into ptr: UnsafeMutablePointer<Vertex>) {
        let (a, b, c, d, e, f) = quadVertices(q)
        ptr[0] = a
        ptr[1] = b
        ptr[2] = c
        ptr[3] = d
        ptr[4] = e
        ptr[5] = f
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position;
            float2 uv;
            float2 local;
            float2 size;
            float radius;
            float alpha;
            float4 color;
            float mode;
            float borderWidth;
        };
        struct VertexOut {
            float4 position [[position]];
            float2 uv;
            float2 local;
            float2 size;
            float radius;
            float alpha;
            float4 color;
            float mode;
            float borderWidth;
        };
        struct Uniforms { float2 viewportSize; };

        vertex VertexOut metalGridVertex(
            uint vid [[vertex_id]],
            const device VertexIn *vertices [[buffer(0)]],
            constant Uniforms &u [[buffer(1)]]
        ) {
            VertexIn in = vertices[vid];
            float2 ndc = float2(
                (in.position.x / max(u.viewportSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (in.position.y / max(u.viewportSize.y, 1.0)) * 2.0
            );
            VertexOut out;
            out.position = float4(ndc, 0.0, 1.0);
            out.uv = in.uv;
            out.local = in.local;
            out.size = in.size;
            out.radius = in.radius;
            out.alpha = in.alpha;
            out.color = in.color;
            out.mode = in.mode;
            out.borderWidth = in.borderWidth;
            return out;
        }

        static inline float roundedRectSDF(float2 local, float2 size, float radius) {
            float r = min(radius, min(size.x, size.y) * 0.5);
            float2 halfSize = size * 0.5;
            float2 q = abs(local - halfSize) - (halfSize - r);
            return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        }

        static inline float segmentDistance(float2 p, float2 a, float2 b) {
            float2 ab = b - a;
            float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
            return length(p - (a + t * ab));
        }

        fragment float4 metalGridFragment(
            VertexOut in [[stage_in]],
            texture2d<float> tex [[texture(0)]],
            sampler s [[sampler(0)]]
        ) {
            int mode = int(in.mode + 0.5);
            if (mode == 3) {
                // The approved photo-outline icon is defined in a 100 by 100 coordinate space.
                // Evaluating it per fragment keeps the shared placeholder sharp at every zoom level.
                float side = max(min(in.size.x, in.size.y), 1.0);
                float2 p = (in.local / side - float2(0.29)) * (100.0 / 0.42);
                float edge = abs(roundedRectSDF(p - float2(12.0, 18.0), float2(76.0, 64.0), 14.0));
                float sun = abs(length(p - float2(68.0, 37.0)) - 6.0);
                float landscape = min(
                    min(segmentDistance(p, float2(14.0, 66.0), float2(35.0, 46.0)),
                        segmentDistance(p, float2(35.0, 46.0), float2(54.0, 64.0))),
                    min(segmentDistance(p, float2(54.0, 64.0), float2(64.0, 54.0)),
                        segmentDistance(p, float2(64.0, 54.0), float2(86.0, 75.0))));
                float antialias = 100.0 / (side * 0.42);
                float icon = 1.0 - smoothstep(1.5 - antialias, 1.5 + antialias, min(edge, min(sun, landscape)));
                float diagonal = (p.x + p.y) / 200.0;
                // The approved light beam: 40 icon units wide at 45 degrees (20 * sqrt(2) / 200 along the diagonal),
                // linear falloff, white at the opacity the quad carries in color.a, drawn only on the icon strokes.
                float beam = in.borderWidth < -1.0
                    ? 0.0 : max(1.0 - abs(diagonal - in.borderWidth) / 0.14142, 0.0);
                float gray = mix(mix(0.16, 0.48, icon), in.color.r, icon * beam * in.color.a);
                float mask = in.radius <= 0.0 ? 1.0
                    : 1.0 - smoothstep(-1.0, 1.0, roundedRectSDF(in.local, in.size, in.radius));
                float coverage = in.alpha * mask;
                return float4(float3(gray * coverage), coverage);
            }
            if (mode == 2) {
                // Rounded-rect ring: outer fill minus an inner fill inset by borderWidth. Always SDF-based -
                // at radius 0 the SDF degenerates to the plain rect ring, so no separate path is needed.
                float dist = roundedRectSDF(in.local, in.size, in.radius);
                float fillMask = 1.0 - smoothstep(-1.0, 1.0, dist);
                float inner = 1.0 - smoothstep(-1.0, 1.0, dist + in.borderWidth);
                float ring = clamp(fillMask - inner, 0.0, 1.0);
                float coverage = in.alpha * ring;
                float4 c = in.color;
                return float4(c.rgb * c.a * coverage, c.a * coverage);
            }
            // Sharp-corner fast path: radius 0 (dense square tiles, GridCornerRadiusPolicy) needs no SDF and no
            // anti-aliased edge band - full coverage, hard 90° edges, no per-fragment rounded-corner cost. All
            // quads at a dense level share radius 0, so the branch is coherent across the warp.
            float fillMask = (in.radius <= 0.0)
                ? 1.0
                : 1.0 - smoothstep(-1.0, 1.0, roundedRectSDF(in.local, in.size, in.radius));
            if (mode == 1) {
                float coverage = in.alpha * fillMask;
                float4 c = in.color;
                return float4(c.rgb * c.a * coverage, c.a * coverage);
            } else {
                float4 t = tex.sample(s, in.uv) * in.color;
                float coverage = in.alpha * fillMask;
                return float4(t.rgb * coverage, t.a * coverage);
            }
        }

        // Overview layer dissolve composite: mix two complete grid layers over the same background.
        struct CompositeOut { float4 position [[position]]; float2 uv; };
        vertex CompositeOut metalGridCompositeVertex(uint vid [[vertex_id]]) {
            float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            float2 p = pos[vid];
            CompositeOut o;
            o.position = float4(p, 0.0, 1.0);
            o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);   // texel-centre exact at matching resolution
            return o;
        }
        fragment float4 metalGridCompositeFragment(
            CompositeOut in [[stage_in]],
            texture2d<float> texA [[texture(0)]],
            texture2d<float> texB [[texture(1)]],
            constant float &t [[buffer(0)]],
            sampler s [[sampler(0)]]
        ) {
            float4 a = texA.sample(s, in.uv);
            float4 b = texB.sample(s, in.uv);
            return float4(mix(a.rgb, b.rgb, t), 1.0);
        }

        """
}
