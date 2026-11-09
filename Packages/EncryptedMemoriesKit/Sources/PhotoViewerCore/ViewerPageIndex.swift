import PhotosCore

/// Stable UID-to-page projection for a viewer route.
///
/// Native pagers continue to own their integer page. Filmstrips use this value to resolve a `PhotoUID`
/// back into that existing page without becoming a second navigation owner.
public struct ViewerPageIndex: Equatable, Sendable {
    public let orderedUIDs: [PhotoUID]
    private let indicesByUID: [PhotoUID: Int]

    public init(orderedUIDs: [PhotoUID]) {
        self.orderedUIDs = orderedUIDs
        var indicesByUID: [PhotoUID: Int] = [:]
        indicesByUID.reserveCapacity(orderedUIDs.count)
        for (index, uid) in orderedUIDs.enumerated() where indicesByUID[uid] == nil {
            indicesByUID[uid] = index
        }
        self.indicesByUID = indicesByUID
    }

    public func uid(at index: Int) -> PhotoUID? {
        orderedUIDs.indices.contains(index) ? orderedUIDs[index] : nil
    }

    public func index(of uid: PhotoUID) -> Int? {
        indicesByUID[uid]
    }

    /// Resolves a small ordered identity list without scanning the complete viewer route.
    public func items(withUIDs uids: [PhotoUID], from items: [PhotoItem]) -> [PhotoItem] {
        uids.compactMap { uid in
            guard let index = indicesByUID[uid], items.indices.contains(index) else { return nil }
            return items[index]
        }
    }
}
