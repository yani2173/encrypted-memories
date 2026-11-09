/// Tracks a scroll gesture separately from the shared sweep clock.
package struct MetalGridPlaceholderScrollTracker<ID: Hashable> {
    private var visibleAtStart: Set<ID>?
    package init() {}

    package mutating func began(visibleIDs: [ID]) {
        visibleAtStart = Set(visibleIDs)
    }

    @discardableResult
    package mutating func ended(
        visibleIDs: [ID], isVisible: Bool, reduceMotion: Bool, isLoading: (ID) -> Bool,
        pulse: inout MetalGridPlaceholderPulse
    ) -> Bool {
        defer { visibleAtStart = nil }
        guard let visibleAtStart, isVisible, !reduceMotion else { return false }
        guard visibleIDs.contains(where: { !visibleAtStart.contains($0) && isLoading($0) }) else { return false }
        pulse.restart()
        return true
    }

    package mutating func reset() { visibleAtStart = nil }
}
