// GridTransitionComponentBuilder.swift
//
// Builds presentation keys for settled frame plans and joins the source/target positions of relocating
// identities. Columns and rows are relative to the anchor. The schedules own occupant crossfades for
// each component.

import CoreGraphics

package struct GridTransitionLattice: Sendable {
    package let keys: [RelativeSlotKey]
    package let sourceOcc: [RelativeSlotKey: Int]
    package let targetOcc: [RelativeSlotKey: Int]
    package let sourceRect: [RelativeSlotKey: CGRect]  // real (nil for entries)
    package let targetRect: [RelativeSlotKey: CGRect]  // real (nil for exits)
    package let presentationSourceRect: [RelativeSlotKey: CGRect]  // filled for every key
    package let presentationTargetRect: [RelativeSlotKey: CGRect]
    package let components: [GridTransitionComponent]  // windows nil (assigned later by a scheduler)

    package init(
        keys: [RelativeSlotKey],
        sourceOcc: [RelativeSlotKey: Int],
        targetOcc: [RelativeSlotKey: Int],
        sourceRect: [RelativeSlotKey: CGRect],
        targetRect: [RelativeSlotKey: CGRect],
        presentationSourceRect: [RelativeSlotKey: CGRect],
        presentationTargetRect: [RelativeSlotKey: CGRect],
        components: [GridTransitionComponent]
    ) {
        self.keys = keys
        self.sourceOcc = sourceOcc
        self.targetOcc = targetOcc
        self.sourceRect = sourceRect
        self.targetRect = targetRect
        self.presentationSourceRect = presentationSourceRect
        self.presentationTargetRect = presentationTargetRect
        self.components = components
    }
}

/// Affine source-to-target presentation transform (per-axis median scale plus median translation), fit
/// from keys that have both real rects, used to synthesize off-grid endpoints for entries/exits.
package struct GridTransitionPresentationTransform {
    package let sx: Double, sy: Double, tx: Double, ty: Double

    // One shared rectangle is sufficient. Additional rectangles make the median fit more robust.
    package static func fit(
        keys: [RelativeSlotKey], sourceRect: [RelativeSlotKey: CGRect],
        targetRect: [RelativeSlotKey: CGRect], minCommon: Int = 1
    ) -> GridTransitionPresentationTransform? {
        let common = keys.filter { sourceRect[$0] != nil && targetRect[$0] != nil }
        guard common.count >= minCommon else { return nil }
        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            let n = s.count
            return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        }
        let sx = median(common.map { Double(targetRect[$0]!.width) / Double(max(0.001, sourceRect[$0]!.width)) })
        let sy = median(common.map { Double(targetRect[$0]!.height) / Double(max(0.001, sourceRect[$0]!.height)) })
        guard sx > 1e-4, sy > 1e-4 else { return nil }
        let tx = median(common.map { Double(targetRect[$0]!.midX) - sx * Double(sourceRect[$0]!.midX) })
        let ty = median(common.map { Double(targetRect[$0]!.midY) - sy * Double(sourceRect[$0]!.midY) })
        return .init(sx: sx, sy: sy, tx: tx, ty: ty)
    }

    package func forward(_ r: CGRect) -> CGRect {  // Source space to target space.
        let w = sx * Double(r.width)
        let h = sy * Double(r.height)
        let cx = sx * Double(r.midX) + tx
        let cy = sy * Double(r.midY) + ty
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
    package func inverse(_ r: CGRect) -> CGRect {  // Target space to source space.
        let w = Double(r.width) / sx
        let h = Double(r.height) / sy
        let cx = (Double(r.midX) - tx) / sx
        let cy = (Double(r.midY) - ty) / sy
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Presentation endpoints for every key: real where it exists, else synthesized off-grid.
    package func endpoints(
        keys: [RelativeSlotKey], sourceRect: [RelativeSlotKey: CGRect],
        targetRect: [RelativeSlotKey: CGRect]
    ) -> (source: [RelativeSlotKey: CGRect], target: [RelativeSlotKey: CGRect]) {
        var ps: [RelativeSlotKey: CGRect] = [:]
        var pt: [RelativeSlotKey: CGRect] = [:]
        for k in keys {
            if let s = sourceRect[k] {
                ps[k] = s
            } else if let t = targetRect[k] {
                ps[k] = inverse(t)
            }
            if let t = targetRect[k] {
                pt[k] = t
            } else if let s = sourceRect[k] {
                pt[k] = forward(s)
            }
        }
        return (ps, pt)
    }
}

package enum GridTransitionComponentBuilder {
    package static func build(
        source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
        viewportSize: CGSize
    ) -> GridTransitionLattice? {
        guard let aS = source.visibleSlots.first(where: { $0.index == anchorIndex }),
            let aT = target.visibleSlots.first(where: { $0.index == anchorIndex })
        else { return nil }
        // single-section in the visible region (matches the engine's single-section zoom guard)
        let sections = Set(source.visibleSlots.map(\.section)).union(target.visibleSlots.map(\.section))
        guard sections.count == 1 else { return nil }

        func relKey(_ s: GridSlot, _ a: GridSlot) -> RelativeSlotKey {
            .init(dr: s.row - a.row, dc: s.column - a.column)
        }
        var sourceOcc: [RelativeSlotKey: Int] = [:]
        var targetOcc: [RelativeSlotKey: Int] = [:]
        var sourceRect: [RelativeSlotKey: CGRect] = [:]
        var targetRect: [RelativeSlotKey: CGRect] = [:]
        for s in source.visibleSlots {
            let k = relKey(s, aS)
            sourceOcc[k] = s.index
            sourceRect[k] = s.viewportRect
        }
        for s in target.visibleSlots {
            let k = relKey(s, aT)
            targetOcc[k] = s.index
            targetRect[k] = s.viewportRect
        }
        let keys = Array(Set(sourceOcc.keys).union(targetOcc.keys)).sorted()

        // union-find over keys
        var parent: [RelativeSlotKey: RelativeSlotKey] = [:]
        for k in keys { parent[k] = k }
        func find(_ x: RelativeSlotKey) -> RelativeSlotKey {
            var r = x
            while parent[r]! != r {
                parent[r] = parent[parent[r]!]!
                r = parent[r]!
            }
            return r
        }
        func union(_ a: RelativeSlotKey, _ b: RelativeSlotKey) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var srcKeyOf: [Int: RelativeSlotKey] = [:]
        var tgtKeyOf: [Int: RelativeSlotKey] = [:]
        for (k, id) in sourceOcc { srcKeyOf[id] = k }
        for (k, id) in targetOcc { tgtKeyOf[id] = k }
        func isStable(_ k: RelativeSlotKey) -> Bool {
            if let s = sourceOcc[k], let t = targetOcc[k], s == t { return true }
            return false
        }
        for id in Set(srcKeyOf.keys).intersection(tgtKeyOf.keys) {
            let sk = srcKeyOf[id]!
            let tk = tgtKeyOf[id]!
            if sk != tk { union(sk, tk) }  // Link both positions of a relocated identity.
        }

        // group non-stable keys participating in a relocation
        var groups: [RelativeSlotKey: [RelativeSlotKey]] = [:]
        for k in keys where !isStable(k) {
            let mixed = sourceOcc[k] != nil && targetOcc[k] != nil && sourceOcc[k] != targetOcc[k]
            let relocSrc = sourceOcc[k] != nil && targetOcc[k] == nil && tgtKeyOf[sourceOcc[k]!] != nil
            let relocTgt = targetOcc[k] != nil && sourceOcc[k] == nil && srcKeyOf[targetOcc[k]!] != nil
            guard mixed || relocSrc || relocTgt else { continue }
            groups[find(k), default: []].append(k)
        }

        let va = Double(viewportSize.width * viewportSize.height)
        func area(_ k: RelativeSlotKey, gp: Double) -> Double {
            let s = sourceRect[k]
            let t = targetRect[k]
            let r: CGRect
            if let s, let t {
                r = CGRect(
                    x: s.minX + (t.minX - s.minX) * gp, y: s.minY + (t.minY - s.minY) * gp,
                    width: s.width + (t.width - s.width) * gp, height: s.height + (t.height - s.height) * gp)
            } else {
                r = s ?? t ?? .zero
            }
            let ix = max(0, min(Double(r.maxX), Double(viewportSize.width)) - max(Double(r.minX), 0))
            let iy = max(0, min(Double(r.maxY), Double(viewportSize.height)) - max(Double(r.minY), 0))
            return ix * iy
        }

        var components: [GridTransitionComponent] = []
        var cid = 0
        for (_, ks) in groups.sorted(by: { $0.value.count > $1.value.count }) {
            let peak =
                [0.3, 0.4, 0.5, 0.6, 0.7]
                .map { gp in ks.reduce(0.0) { $0 + area($1, gp: gridTransitionSmootherstep(gp)) } }.max() ?? 0
            let fdist = ks.map { abs($0.dr) }.min() ?? 0
            let drs = ks.map(\.dr)
            let side: GridTransitionComponentSide =
                fdist == 0
                ? .focus : (drs.allSatisfy { $0 <= 0 } ? .upper : (drs.allSatisfy { $0 >= 0 } ? .lower : .focus))
            components.append(
                .init(
                    id: cid, keys: ks.sorted(), focusDistance: fdist, side: side,
                    visibleAreaFraction: va > 0 ? peak / va : 0, window: nil))
            cid += 1
        }

        let presSource: [RelativeSlotKey: CGRect]
        let presTarget: [RelativeSlotKey: CGRect]
        // Preserve the affine presentation for entries and exits.
        guard
            let transform = GridTransitionPresentationTransform.fit(
                keys: keys, sourceRect: sourceRect, targetRect: targetRect)
        else { return nil }
        (presSource, presTarget) = transform.endpoints(keys: keys, sourceRect: sourceRect, targetRect: targetRect)

        return GridTransitionLattice(
            keys: keys, sourceOcc: sourceOcc, targetOcc: targetOcc,
            sourceRect: sourceRect, targetRect: targetRect,
            presentationSourceRect: presSource, presentationTargetRect: presTarget,
            components: components)
    }

    /// Assemble an immutable plan from a lattice + assigned component windows.
    package static func assemble(
        kind: GridTransitionKindTag, lattice lat: GridTransitionLattice,
        windows: [Int: ClosedRange<Double>], sourceLevel: Int, targetLevel: Int,
        durationMs: Double, curve: LocalAlphaCurve
    ) -> GridTransitionPlan {
        var comps = lat.components
        for i in comps.indices { comps[i].window = windows[comps[i].id] }
        var componentOfKey: [RelativeSlotKey: Int] = [:]
        for c in comps { for k in c.keys { componentOfKey[k] = c.id } }
        return GridTransitionPlan(
            kind: kind, sourceLevel: sourceLevel, targetLevel: targetLevel, durationMs: durationMs, curve: curve,
            components: comps, keys: lat.keys, sourceOcc: lat.sourceOcc, targetOcc: lat.targetOcc,
            sourceRect: lat.sourceRect, targetRect: lat.targetRect,
            presentationSourceRect: lat.presentationSourceRect, presentationTargetRect: lat.presentationTargetRect,
            componentOfKey: componentOfKey, windowOf: windows)
    }
}
