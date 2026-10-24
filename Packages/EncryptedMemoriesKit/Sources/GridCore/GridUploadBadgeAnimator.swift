import CoreGraphics

/// What the grid rasterizes for an upload badge. Progress and the checkmark have fine steps, so the animator
/// can move them smoothly while every step stays one cached texture.
package enum GridUploadBadgeGlyph: Equatable, Hashable, Sendable {
    package static let pieSteps = 64
    package static let checkSteps = 12

    /// The circle filled with white to `step` of `pieSteps`; 0 is the empty circle.
    case pie(Int)
    /// The white circle with its checkmark drawn to `step` of `checkSteps`.
    case check(Int)
    case attention
    case notBackedUp
    /// The empty circle with two vertical bars.
    case paused

    /// The SF Symbol a host draws on the badge, when the badge carries one.
    package var symbolName: String? {
        self == .notBackedUp ? "icloud.slash" : nil
    }

    /// The glyph of a badge without animation.
    package init(_ badge: GridUploadBadge) {
        switch badge {
        case .waiting: self = .pie(0)
        case .uploading: self = .pie(Self.pieStep(GridUploadBadgeAnimatorMath.fraction(of: badge)))
        case .done: self = .check(Self.checkSteps)
        case .attention: self = .attention
        case .notBackedUp: self = .notBackedUp
        case .paused: self = .paused
        }
    }

    static func pieStep(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * Double(pieSteps)).rounded())
    }
}

/// One frame of an upload badge: the glyph, its opacity, and its size relative to the badge slot.
package struct GridUploadBadgeFrame: Equatable, Sendable {
    package var glyph: GridUploadBadgeGlyph
    package var alpha: Float
    package var scale: CGFloat

    package init(glyph: GridUploadBadgeGlyph, alpha: Float = 1, scale: CGFloat = 1) {
        self.glyph = glyph
        self.alpha = alpha
        self.scale = scale
    }
}

enum GridUploadBadgeAnimatorMath {
    /// The filled share of the circle a badge asks for.
    static func fraction(of badge: GridUploadBadge) -> Double {
        switch badge {
        case .uploading(let step):
            Double(min(max(step, 0), GridUploadBadge.progressSteps)) / Double(GridUploadBadge.progressSteps)
        case .done: 1
        case .waiting, .attention, .notBackedUp, .paused: 0
        }
    }

    static func easeOut(_ t: Double) -> Double {
        let r = 1 - min(1, max(0, t))
        return 1 - r * r * r
    }

    static func easeIn(_ t: Double) -> Double {
        let p = min(1, max(0, t))
        return p * p
    }
}

/// Animates upload badges over time, the way the system animates progress: the badge fades in, the circle
/// fills smoothly as bytes move instead of jumping between progress steps, the checkmark draws itself on the
/// full circle with a small pop, and after a moment the badge fades out. The backup only sets targets; timing
/// belongs to the grid, so a photo that finishes quickly still shows the whole sequence.
///
/// Platform-neutral: hosts pass their frame time and draw another frame while `isAnimating` is true.
@MainActor
package final class GridUploadBadgeAnimator<ID: Hashable> {
    package struct Timing: Sendable {
        package var fadeIn: Double = 0.2
        /// Time constant of the fill: the circle covers about 95 % of a jump in three of these.
        package var fill: Double = 0.2
        package var checkDraw: Double = 0.32
        package var hold: Double = 0.8
        package var fadeOut: Double = 0.3

        package init() {}
    }

    private enum Phase: Equatable {
        /// Empty or filling toward `target`.
        case progress
        /// The circle is full; the checkmark draws from `start`, holds, then the badge fades out.
        case finishing(start: Double)
        case finished
        /// The badge went away before the checkmark: `glyph` fades out from `start`.
        case leaving(start: Double, glyph: GridUploadBadgeGlyph)
        /// An attention, "not backed up", or paused badge.
        case fixed(GridUploadBadgeGlyph)
    }

    private struct State {
        var phase: Phase
        var shown: Double
        var target: Double
        var appearedAt: Double
        var updatedAt: Double
        /// The backup reported the photo as backed up; the circle finishes before the checkmark.
        var completes: Bool

        var isFixed: Bool {
            if case .fixed = phase { return true }
            return false
        }
    }

    private let timing: Timing
    private var states: [ID: State] = [:]
    /// The drawn frame in which each photo last asked for its badge. Frames, not wall time: the host draws
    /// nothing while the grid rests, and a rest must not make the visible badges start over.
    private var lastSeen: [ID: UInt64] = [:]
    private var drawnFrame: UInt64 = 0
    private var frameTime: Double = -.infinity
    private var lastForgetFrame: UInt64 = 0
    /// About five seconds of continuous drawing.
    private static var forgetAfterFrames: UInt64 { 600 }

    package init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// The badge to draw for `id` at `now`, given the badge the backup reports now (nil for none).
    package func frame(for id: ID, target: GridUploadBadge?, now: Double) -> GridUploadBadgeFrame? {
        guard target != nil || states[id] != nil else { return nil }
        if now != frameTime {
            frameTime = now
            drawnFrame &+= 1
        }
        lastSeen[id] = drawnFrame
        // Photos not drawn for a while lose their state; a revisit starts from the current badge.
        if lastSeen.count > 256, drawnFrame &- lastForgetFrame > Self.forgetAfterFrames {
            lastForgetFrame = drawnFrame
            forgetUnseen(frames: Self.forgetAfterFrames)
        }
        var state = states[id]
        let frame = advance(&state, target: target, now: now)
        states[id] = state
        return frame
    }

    /// Whether any of `ids` still moves at `now`, so the host keeps drawing frames.
    package func isAnimating(_ ids: [ID], now: Double) -> Bool {
        ids.contains { id in
            guard let state = states[id] else { return false }
            switch state.phase {
            case .progress:
                return now - state.appearedAt < timing.fadeIn || abs(state.shown - state.target) > 0.002
                    || state.completes
            case .finishing, .leaving:
                return true
            case .fixed:
                return now - state.appearedAt < timing.fadeIn
            case .finished:
                return false
            }
        }
    }

    /// A pending photo became its Proton photo: the animation continues under the new identity.
    package func adopt(from source: ID, to target: ID) {
        guard states[target] == nil, let state = states.removeValue(forKey: source) else { return }
        states[target] = state
        lastSeen[target] = lastSeen.removeValue(forKey: source)
    }

    /// Forgets photos not drawn in the last `frames` drawn frames, bounding the state to what the grid shows.
    package func forgetUnseen(frames: UInt64) {
        let cutoff = drawnFrame > frames ? drawnFrame - frames : 0
        let stale = lastSeen.filter { $0.value < cutoff }.map(\.key)
        for id in stale {
            lastSeen[id] = nil
            states[id] = nil
        }
    }

    private func advance(_ slot: inout State?, target: GridUploadBadge?, now: Double) -> GridUploadBadgeFrame? {
        guard let target else { return leave(&slot, now: now) }
        switch target {
        case .waiting, .uploading, .done:
            // The backup resumed or the photo finished during the pause: the circle continues from its fill
            // without a new fade-in, and a finished photo fills it before its checkmark.
            if slot?.phase == .fixed(.paused) { slot?.phase = .progress }
        case .attention, .notBackedUp, .paused:
            break
        }
        var state: State
        switch target {
        case .attention, .notBackedUp, .paused:
            let glyph = GridUploadBadgeGlyph(target)
            if var current = slot, current.isFixed || (target == .paused && current.phase == .progress) {
                // Another fixed glyph, or a circle the person paused: no new fade-in.
                current.phase = .fixed(glyph)
                state = current
            } else {
                state = State(
                    phase: .fixed(glyph), shown: 0, target: 0, appearedAt: resumedAppearance(slot, now: now),
                    updatedAt: now, completes: false)
            }
        case .done:
            if let current = slot, !current.isFixed {
                state = current
            } else {
                // First seen when already backed up (scrolled into view): the full circle, then the checkmark.
                state = State(
                    phase: .progress, shown: 1, target: 1, appearedAt: now - timing.fadeIn, updatedAt: now,
                    completes: true)
            }
            if state.phase == .finished {
                slot = state
                return nil
            }
            if case .leaving = state.phase { resume(&state, now: now) }
            state.target = 1
            state.completes = true
        case .waiting, .uploading:
            let fraction = GridUploadBadgeAnimatorMath.fraction(of: target)
            if let current = slot, !current.isFixed, current.phase != .finished {
                state = current
            } else {
                state = State(
                    phase: .progress, shown: fraction, target: fraction, appearedAt: now, updatedAt: now,
                    completes: false)
            }
            if case .leaving = state.phase { resume(&state, now: now) }
            if state.phase == .progress {
                // The circle never runs backwards. When a photo's upload starts over (a new version arrived
                // while it uploaded), the circle holds its fill until the new upload passes it.
                state.target = max(fraction, state.target)
                state.completes = false
            }
        }
        let frame = step(&state, now: now)
        slot = state
        return frame
    }

    /// The backup reports no badge: a backed-up photo finishes its checkmark, any other badge fades out.
    private func leave(_ slot: inout State?, now: Double) -> GridUploadBadgeFrame? {
        guard var state = slot else { return nil }
        switch state.phase {
        case .finished:
            slot = nil
            return nil
        case .fixed(let glyph):
            state.phase = .leaving(start: now, glyph: glyph)
        case .progress where !state.completes:
            state.phase = .leaving(start: now, glyph: .pie(GridUploadBadgeGlyph.pieStep(state.shown)))
        case .progress, .finishing, .leaving:
            break
        }
        let frame = step(&state, now: now)
        slot = state
        return frame
    }

    private func step(_ state: inout State, now: Double) -> GridUploadBadgeFrame? {
        // The host draws no frames while nothing moves; a new target after a quiet time starts from where the
        // circle stood instead of jumping by the whole pause.
        let elapsed = min(1.0 / 30, max(0, now - state.updatedAt))
        state.updatedAt = now
        switch state.phase {
        case .progress:
            let target = state.completes ? 1 : state.target
            state.shown += (target - state.shown) * (1 - exp(-elapsed / max(0.001, timing.fill)))
            if abs(target - state.shown) < 0.004 { state.shown = target }
            if state.completes, state.shown >= 1 { state.phase = .finishing(start: now) }
            if case .finishing = state.phase { return step(&state, now: now) }
            return frame(.pie(GridUploadBadgeGlyph.pieStep(state.shown)), state: state, now: now)
        case .finishing(let start):
            let t = now - start
            let fadeStart = timing.checkDraw + timing.hold
            if t >= fadeStart + timing.fadeOut {
                state.phase = .finished
                return nil
            }
            let drawn = GridUploadBadgeAnimatorMath.easeOut(t / max(0.001, timing.checkDraw))
            let check = GridUploadBadgeGlyph.check(Int((drawn * Double(GridUploadBadgeGlyph.checkSteps)).rounded()))
            // A small pop while the checkmark draws.
            let pop = t < timing.checkDraw ? 1 + 0.08 * sin(Double.pi * t / max(0.001, timing.checkDraw)) : 1
            guard t > fadeStart else { return GridUploadBadgeFrame(glyph: check, scale: pop) }
            let out = GridUploadBadgeAnimatorMath.easeIn((t - fadeStart) / max(0.001, timing.fadeOut))
            return GridUploadBadgeFrame(glyph: check, alpha: Float(1 - out), scale: 1 - 0.2 * out)
        case .leaving(let start, let glyph):
            let out = leavingProgress(start: start, now: now)
            guard out < 1 else {
                state.phase = .finished
                return nil
            }
            return GridUploadBadgeFrame(glyph: glyph, alpha: Float(1 - out), scale: 1 - 0.2 * out)
        case .finished:
            return nil
        case .fixed(let glyph):
            return frame(glyph, state: state, now: now)
        }
    }

    private func leavingProgress(start: Double, now: Double) -> Double {
        GridUploadBadgeAnimatorMath.easeIn((now - start) / max(0.001, timing.fadeOut))
    }

    /// A badge that comes back while it fades out continues from its current opacity instead of jumping.
    private func resume(_ state: inout State, now: Double) {
        state.appearedAt = resumedAppearance(state, now: now)
        state.phase = .progress
    }

    /// The appearance time that makes the fade-in continue from the opacity a leaving badge has now.
    private func resumedAppearance(_ state: State?, now: Double) -> Double {
        guard let state, case .leaving(let start, _) = state.phase else { return now }
        let alpha = 1 - leavingProgress(start: start, now: now)
        // easeOut(t) = 1 - (1 - t)^3, so t = 1 - cbrt(1 - alpha).
        let t = 1 - pow(max(0, 1 - alpha), 1.0 / 3)
        return now - t * timing.fadeIn
    }

    private func frame(_ glyph: GridUploadBadgeGlyph, state: State, now: Double) -> GridUploadBadgeFrame {
        let appear = GridUploadBadgeAnimatorMath.easeOut((now - state.appearedAt) / max(0.001, timing.fadeIn))
        return GridUploadBadgeFrame(glyph: glyph, alpha: Float(appear), scale: 0.8 + 0.2 * appear)
    }
}
