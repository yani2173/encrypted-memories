/// Keeps the grid density through round trips between grid profiles.
///
/// Resizing a window, splitting the screen, rotating the device, or folding and unfolding iPhone Duo can switch the
/// grid profile (compact and regular ladders). Each switch picks the target level whose tiles look closest in size,
/// but the widths differ on the way out and back, so every round trip could end one density step away from where it
/// started, and repeated resizes crept the grid denser. The memory returns to the level each profile last showed, as
/// long as the person did not zoom since the grid arrived in the profile it leaves; a zoom makes the size match
/// decide again.
public struct GridProfileLevelMemory: Sendable {
    private var levels: [String: Int] = [:]
    private var arrival: (profileID: String, level: Int)?

    public init() {}

    /// The level for `targetProfileID` after the grid leaves `sourceProfileID` at `sourceLevel`. `closestVisualLevel`
    /// runs only when the memory has no level for the target profile.
    public mutating func level(
        leaving sourceProfileID: String, at sourceLevel: Int, entering targetProfileID: String,
        closestVisualLevel: () -> Int
    ) -> Int {
        let target =
            remembered(leaving: sourceProfileID, at: sourceLevel, entering: targetProfileID)
            ?? closestVisualLevel()
        arrived(in: targetProfileID, at: target)
        return target
    }

    /// The remembered level for `targetProfileID` when the grid leaves `sourceProfileID` at `sourceLevel`, or nil
    /// when the size match has to decide. A host that picks the level inside a scroll rebase calls this, then
    /// `arrived(in:at:)` with the level that it used.
    public mutating func remembered(
        leaving sourceProfileID: String, at sourceLevel: Int, entering targetProfileID: String
    ) -> Int? {
        if let arrival, arrival.profileID != sourceProfileID || arrival.level != sourceLevel {
            levels.removeAll()
        }
        levels[sourceProfileID] = sourceLevel
        return levels[targetProfileID]
    }

    /// Records the level that the grid shows after it entered `profileID`.
    public mutating func arrived(in profileID: String, at level: Int) {
        arrival = (profileID, level)
    }

    /// Forgets every level, for example when the caller sets a level or a profile explicitly.
    public mutating func reset() {
        levels.removeAll()
        arrival = nil
    }
}
