import CoreGraphics

/// Layout-invariant scroll position: the item at the top of the viewport plus how far its top sat below the
/// viewport top. Restoring re-resolves that item at the current zoom, width, and column phase, so route memory
/// survives layout changes without relying on a stale raw scroll offset.
public struct GridScrollAnchor<ItemID: Hashable & Sendable>: Equatable, Sendable {
    public let itemID: ItemID
    public let topOffset: CGFloat

    public init(itemID: ItemID, topOffset: CGFloat) {
        self.itemID = itemID
        self.topOffset = topOffset
    }
}

/// Chooses the photo that anchors a scroll position.
public enum GridScrollAnchorPolicy {
    /// The photo that anchors the place the person sees. The usable area lies between `visibleTop` (below a
    /// translucent top bar) and `visibleBottom` (above a bottom bar), in content coordinates.
    ///
    /// - A slot for which `isKept` is true wins while its top edge lies in the usable area. A rotation lays out several
    ///   intermediate sizes; keeping one photo through all of them stops the place from creeping with each layout.
    /// - Otherwise the first slot whose top edge lies in the usable area anchors. A photo that the top bar covers is a
    ///   poor anchor: when the bar height or the tile size changes, it can end above the usable area.
    /// - When no slot starts in the area (tiles taller than the area), the topmost slot that reaches into it anchors,
    ///   then the topmost slot.
    ///
    /// Ties keep the first slot in order.
    public static func anchor<Slot>(
        among slots: [Slot], visibleTop: CGFloat, visibleBottom: CGFloat,
        isKept: (Slot) -> Bool = { _ in false }, frame: (Slot) -> CGRect
    ) -> Slot? {
        func startsInView(_ slot: Slot) -> Bool {
            frame(slot).minY >= visibleTop - 0.5 && frame(slot).minY < visibleBottom
        }
        func topmost(_ candidates: [Slot]) -> Slot? { candidates.min(by: { frame($0).minY < frame($1).minY }) }
        if let kept = slots.first(where: { isKept($0) && startsInView($0) }) { return kept }
        let reachesIntoView = slots.filter { frame($0).maxY > visibleTop && frame($0).minY < visibleBottom }
        return topmost(slots.filter(startsInView)) ?? topmost(reachesIntoView) ?? topmost(slots)
    }
}
