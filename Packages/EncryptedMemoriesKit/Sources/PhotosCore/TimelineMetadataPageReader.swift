import Foundation

/// Actor-owned paging over one inventory. MIME fallback remains available without an order cache.
public final class TimelineMetadataPageReader {
    private let inventory: TimelineMetadataReconciliation.Inventory
    private let orderStore: TimelineOrderMetadataStore?
    private let timelineStore: TimelineMetadataStore?
    private var classifiedNodeIDs: Set<String>
    private var cursor: PhotoUID?
    private var offset = 0
    private var preparedRebuildRevision: UInt64 = 0
    public private(set) var useOrderCache = false

    public init(
        inventory: TimelineMetadataReconciliation.Inventory, orderStore: TimelineOrderMetadataStore?,
        timelineStore: TimelineMetadataStore? = nil
    ) {
        self.inventory = inventory
        self.orderStore = orderStore
        self.timelineStore = timelineStore
        classifiedNodeIDs = inventory.classifiedNodeIDs
    }

    public func prepare(
        isCurrent: () -> Bool, isolation: isolated (any Actor)? = #isolation
    ) async throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        // A queued inventory can predate checkpoints committed by the preceding pass.
        if let timelineStore {
            let volumeID = inventory.libraryID ?? inventory.items.first?.uid.volumeID ?? ""
            if let evidence = timelineStore.mediaTypeEvidence(volumeID: volumeID) {
                classifiedNodeIDs.formUnion(evidence.keys)
            }
        }
        let initialRebuildRevision = orderStore?.rebuildRevision ?? 0
        useOrderCache =
            await orderStore?.synchronizeInChunks(
                inventory.items, isClassified: { self.classifiedNodeIDs.contains($0.nodeID) }) == true
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if !useOrderCache, let orderStore, orderStore.rebuildRevision == initialRebuildRevision {
            orderStore.rebuildUnlessBusy()
        }
        preparedRebuildRevision = orderStore?.rebuildRevision ?? 0
    }

    public func nextPage(
        isCurrent: () -> Bool, isolation: isolated (any Actor)? = #isolation
    ) async throws -> [TimelineOrderMetadataStore.Candidate] {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if useOrderCache, let orderStore, orderStore.rebuildRevision != preparedRebuildRevision {
            // A reader replaced the prepared inventory while its network page was awaited.
            // Replay from the beginning; committed metadata in the fresh cache remains known.
            try await prepare(isCurrent: isCurrent)
            cursor = nil
        }
        if useOrderCache, let orderStore {
            let page = try orderStore.nextPage(after: cursor)
            if let last = page.last { cursor = last.uid }
            return page
        }
        while offset < inventory.items.count {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            let end = min(offset + TimelineOrderMetadataStore.pageSize, inventory.items.count)
            let page = inventory.items[offset..<end].compactMap { item -> TimelineOrderMetadataStore.Candidate? in
                guard !classifiedNodeIDs.contains(item.uid.nodeID) else { return nil }
                return .init(uid: item.uid, captureTime: item.captureTime, needsOrder: false)
            }
            offset = end
            if !page.isEmpty { return page }
        }
        return []
    }
}
