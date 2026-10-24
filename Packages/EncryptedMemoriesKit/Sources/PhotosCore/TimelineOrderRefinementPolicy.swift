import Foundation

/// Defers only metadata-driven order corrections that would move a currently visible photo.
/// Hosts reuse their UID index and the bounded visible slots. No library-sized lookup is allocated here.
public enum TimelineOrderRefinementPolicy {
    public enum Decision: Equatable {
        case ordinaryUpdate
        case applyCorrection
        case deferVisibleCorrection
    }

    public static func decision(
        incoming: [PhotoItem], previousCount: Int, visibleIndices: Set<Int>,
        previous: (PhotoUID) -> (index: Int, item: PhotoItem)?
    ) -> Decision {
        guard incoming.count == previousCount else { return .ordinaryUpdate }
        var changedMetadata = false
        var movedVisiblePhoto = false
        for (index, item) in incoming.enumerated() {
            guard let old = previous(item.uid), old.item.captureTime == item.captureTime else { return .ordinaryUpdate }
            changedMetadata = changedMetadata || old.item.timelineOrder != item.timelineOrder
            if old.index != index {
                movedVisiblePhoto = movedVisiblePhoto || visibleIndices.contains(old.index)
            }
        }
        guard changedMetadata else { return .ordinaryUpdate }
        return movedVisiblePhoto ? .deferVisibleCorrection : .applyCorrection
    }
    /// A pending correction already has matching membership. Scroll callbacks only compare the visible slots.
    public static func movesVisiblePhoto(
        incoming: [PhotoItem], visibleIndices: Set<Int>, previousUID: (Int) -> PhotoUID
    ) -> Bool {
        visibleIndices.contains { index in
            incoming.indices.contains(index) && incoming[index].uid != previousUID(index)
        }
    }
}
