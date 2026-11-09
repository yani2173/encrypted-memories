import GridCore

/// One bounded light sweep that every visible loading tile shares, owned by the grid host and driven per frame.
/// The sweep starts with the first visible loading tile and ends for all tiles together; it starts again after
/// the loading tiles left the screen or the grid was hidden. Every tile reads the light from this one clock, so a
/// tile that joins while the sweep runs shows the same phase as the tiles already there. Updates allocate nothing.
package struct MetalGridPlaceholderPulse {
    package static var maximumDuration: Double { 4.8 }
    /// Opacity of the white light beam at its centre, as in the approved preview. The only place that sets the
    /// strength of the light: the composer hands it to the shader.
    package static var beamOpacity: Float { 0.8 }
    /// The light position of a tile that does not animate.
    package static var staticLight: Float { -2 }
    private var sweepStartedAt: Double?
    package private(set) var reduceMotion: Bool
    package private(set) var isAnimating = false
    /// The animating state flipped during the latest update, so frozen layers draw once more.
    package private(set) var changed = false

    package init(reduceMotion: Bool = false) { self.reduceMotion = reduceMotion }

    package var needsLayerRedraw: Bool { isAnimating || changed }

    /// The light position every animating tile draws at `now`; `staticLight` while no sweep runs.
    package func lightPosition(now: Double) -> Float {
        guard isAnimating, let started = sweepStartedAt else { return Self.staticLight }
        return Float(GridThumbnailPlaceholderPolicy.lightPosition(at: now - started))
    }

    /// Returns whether the setting changed.
    @discardableResult
    package mutating func setReduceMotion(_ enabled: Bool) -> Bool {
        guard reduceMotion != enabled else { return false }
        reduceMotion = enabled
        return true
    }

    package mutating func update(loadingCount: Int, now: Double) {
        let was = isAnimating
        if loadingCount > 0, now.isFinite {
            if sweepStartedAt == nil { sweepStartedAt = now }
        } else {
            sweepStartedAt = nil
        }
        if let started = sweepStartedAt, now >= started, now - started < Self.maximumDuration {
            isAnimating = GridThumbnailPlaceholderPolicy.shouldAnimate(
                visibleLoadingCount: loadingCount, reduceMotion: reduceMotion)
        } else {
            isAnimating = false
        }
        changed = isAnimating != was
    }

    package mutating func update<ID>(visible: [ID], now: Double, isLoading: (ID) -> Bool) {
        var count = 0
        for id in visible where isLoading(id) { count += 1 }
        update(loadingCount: count, now: now)
    }

    /// The grid was hidden: its hidden time does not count, and the next visible loading tile starts a new sweep.
    package mutating func restart() {
        sweepStartedAt = nil
        isAnimating = false
        changed = false
    }
}
