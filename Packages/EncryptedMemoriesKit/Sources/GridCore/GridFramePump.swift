/// Platform hosts distinguish a missing surface from transient drawable starvation.
public enum GridRenderOutcome: Equatable, Sendable {
    case skippedNoSurface
    case noDrawable
    /// A drawable existed, but the GPU frame could not be encoded (for example a failed buffer allocation).
    case encodingFailed
    case drawn(hasPendingWork: Bool)
}

/// Coalesces render invalidations into at most one render per display tick.
/// Hosts call `beginTick` before rendering and `completeTick` with its outcome.
public struct GridFramePump: Equatable, Sendable {
    /// A fresh pump wants a first frame - content configured before the first tick must draw.
    private var dirty = true
    /// Whether the host surface is the active one. A fresh pump is active (the common single-surface case).
    private var active = true
    private var invalidationVersion: UInt64 = 0
    private var encodingFailures = 0

    /// How often one unchanged frame request retries after an encoding failure before it waits for an invalidation.
    public static let maximumEncodingRetries = 3
    private var tickVersion: UInt64?

    public init() {}

    /// Note that the on-screen state changed (scroll, new items, layout, arrived thumbnails).
    public mutating func invalidate() {
        dirty = true
        invalidationVersion &+= 1
        encodingFailures = 0
    }

    /// Whether the host surface is currently active (its tab/window is foreground).
    public var isActive: Bool { active }

    /// Set whether the host surface is active. Reactivating re-arms one frame so the surface redraws on
    /// return; deactivating leaves `dirty` untouched (so the pending frame is drawn once the surface is
    /// active again) but immediately gates `shouldTick` to false. Returns whether the active state changed,
    /// so the host only reacts (stop the link / arm a render) on a real transition.
    @discardableResult
    public mutating func setActive(_ active: Bool) -> Bool {
        guard active != self.active else { return false }
        self.active = active
        if active { invalidate() }
        return true
    }

    /// Whether the next display tick should render: only when active AND something is dirty.
    public var shouldTick: Bool { active && dirty }

    /// Capture invalidations before rendering so a callback during the draw cannot lose the next frame.
    public mutating func beginTick() -> Bool {
        guard shouldTick else { return false }
        tickVersion = invalidationVersion
        return true
    }

    @discardableResult
    public mutating func completeTick(_ outcome: GridRenderOutcome) -> Bool {
        switch outcome {
        case .skippedNoSurface:
            encodingFailures = 0
            return completeTick(presented: true, hasPendingWork: false)
        case .noDrawable:
            return completeTick(presented: false, hasPendingWork: false)
        case .encodingFailed:
            encodingFailures += 1
            return completeTick(presented: encodingFailures > Self.maximumEncodingRetries, hasPendingWork: false)
        case .drawn(let hasPendingWork):
            encodingFailures = 0
            return completeTick(presented: true, hasPendingWork: hasPendingWork)
        }
    }

    /// Report the outcome of a tick's render. Returns whether the tick loop must keep running - never while
    /// inactive, so a host that deactivates mid-flight stops its loop on the next `completeTick`.
    @discardableResult
    public mutating func completeTick(presented: Bool, hasPendingWork: Bool) -> Bool {
        let invalidatedDuringTick = tickVersion.map { $0 != invalidationVersion } ?? false
        tickVersion = nil
        dirty = invalidatedDuringTick || !presented || hasPendingWork
        return active && dirty
    }
}
