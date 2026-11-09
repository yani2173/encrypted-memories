// GridTransitionController.swift
//
// Coordinator-side driver for adjacent normal-level transitions. It builds one immutable plan per gesture,
// keeps progress owned by the host, and produces read-only draw intent for each frame.

import CoreGraphics

package enum GridTransitionFallbackReason: String, Sendable {
    case latticeBuildFailed, selectionRelocates, scheduleDegenerate, none
}

package final class GridTransitionController {
    package private(set) var plan: GridTransitionPlan?
    package private(set) var q: Double = 0
    package private(set) var lastFallback: GridTransitionFallbackReason = .none
    private var elapsed: Double = 0
    package var tuning: GridTransitionTuning
    private let telemetrySink: CoreTelemetrySink?

    package init(tuning: GridTransitionTuning = .default, telemetrySink: CoreTelemetrySink? = nil) {
        self.tuning = tuning
        self.telemetrySink = telemetrySink
    }

    package var isActive: Bool { plan != nil }

    /// Try to begin a click (toolbar +/-) transition. Returns true iff a plan was built and
    /// Returns false when the host must use the stable instant snap.
    @discardableResult
    package func beginClick(
        source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
        viewportSize: CGSize, selection: Set<Int>
    ) -> Bool {
        guard
            let lat = GridTransitionComponentBuilder.build(
                source: source, target: target,
                anchorIndex: anchorIndex, viewportSize: viewportSize),
            !lat.components.isEmpty
        else { return fail(.latticeBuildFailed) }
        let relocating = GridTransitionSelectionEligibility.relocatingIdentities(in: lat)
        guard GridTransitionSelectionEligibility.isEligible(selection: selection, relocatingIdentities: relocating)
        else { return fail(.selectionRelocates) }
        guard
            let p = ClickZoomTransitionScheduler.makePlan(
                lattice: lat, sourceLevel: source.levelID,
                targetLevel: target.levelID, tuning: tuning)
        else { return fail(.scheduleDegenerate) }
        plan = p
        q = 0
        elapsed = 0
        lastFallback = .none
        emit(
            "GridTransition",
            [
                "event": "PLAN_BUILT",
                "durationMs": "\(Int(tuning.clickDurationMs))", "components": "\(p.components.count)",
                "src": "\(source.levelID)", "tgt": "\(target.levelID)",
            ])
        return true
    }

    /// Try to begin a live pinch transition. It uses the same eligibility gate as a click, but the plan's
    /// progress `q` is then driven by `setProgress` during interactive scrubbing instead of the trapezoidal
    /// time profile - there is no `advanceClick`/timer for a pinch plan. Returns true iff a plan was built
    /// Returns false when the host must use the geometry-only reflow fallback.
    @discardableResult
    package func beginPinch(
        source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
        viewportSize: CGSize, selection: Set<Int>
    ) -> Bool {
        guard
            let lat = GridTransitionComponentBuilder.build(
                source: source, target: target,
                anchorIndex: anchorIndex, viewportSize: viewportSize),
            !lat.components.isEmpty
        else { return fail(.latticeBuildFailed) }
        let relocating = GridTransitionSelectionEligibility.relocatingIdentities(in: lat)
        guard GridTransitionSelectionEligibility.isEligible(selection: selection, relocatingIdentities: relocating)
        else { return fail(.selectionRelocates) }
        guard
            let p = PinchZoomTransitionScheduler.makePlan(
                lattice: lat, sourceLevel: source.levelID,
                targetLevel: target.levelID, tuning: tuning)
        else { return fail(.scheduleDegenerate) }
        plan = p
        q = 0
        elapsed = 0
        lastFallback = .none
        emit(
            "GridTransition",
            [
                "event": "PLAN_BUILT",
                "components": "\(p.components.count)", "src": "\(source.levelID)", "tgt": "\(target.levelID)",
            ])
        return true
    }

    /// The kind of the active plan (nil when inactive). The coordinator's draw branch uses it to pick the
    /// Click transitions advance by elapsed time. Pinch transitions use host-provided progress.
    package var activeKind: GridTransitionKindTag? { plan?.kind }

    private func fail(_ reason: GridTransitionFallbackReason) -> Bool {
        lastFallback = reason
        plan = nil
        q = 0
        // Keep the reason in telemetry so callers can distinguish an unavailable transition from a settled plan.
        emit("GridTransition", ["event": "FALLBACK", "reason": reason.rawValue])
        return false
    }

    /// Host-owned progress. The coordinator calls this from its display-link tick with the wall-clock
    /// delta; q is the trapezoidal click profile of total elapsed time, not a component timer.
    /// Returns true while the transition is still running; false once it has settled (q==1) and ended.
    @discardableResult
    package func advanceClick(bySeconds dt: Double) -> Bool {
        guard plan != nil else { return false }
        elapsed += max(0, dt)
        q = ClickZoomTransitionScheduler.progress(atElapsed: elapsed, tuning: tuning)
        if elapsed >= tuning.clickDurationSeconds {
            q = 1
            end()
            return false
        }
        return true
    }

    /// Directly set host-owned q (used by live pinch / reverse - q is authoritative, lp follows it).
    package func setProgress(_ value: Double) { q = min(1, max(0, value)) }

    package func end() {
        let was = plan != nil
        plan = nil
        q = 0
        elapsed = 0
        if was { emit("GridTransition", ["event": "SETTLED"]) }
    }

    /// Per-frame draw intent (read-only on the immutable plan). Empty when inactive.
    package func currentDraws() -> [GridTransitionDraw] {
        guard let plan else { return [] }
        return GridTransitionRendererInput.draws(plan: plan, at: q)
    }

    package func partialComponentCount() -> Int { plan?.partialComponentCount(at: q) ?? 0 }

    private func emit(_ event: String, _ fields: [String: String]) {
        telemetrySink?(CoreTelemetryEvent(name: event, fields: fields))
    }
}
