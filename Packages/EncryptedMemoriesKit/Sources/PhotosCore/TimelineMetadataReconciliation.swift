import Foundation

/// Owns one complete metadata pass and the latest pending inventory. The caller owns account admission.
public final class TimelineMetadataReconciliation: @unchecked Sendable {
    public struct Inventory: Sendable {
        public let items: [PhotoItem]
        public let classifiedNodeIDs: Set<String>
        public let libraryID: String?

        public init(items: [PhotoItem], classifiedNodeIDs: Set<String>, libraryID: String?) {
            self.items = items
            self.classifiedNodeIDs = classifiedNodeIDs
            self.libraryID = libraryID
        }
    }

    public struct Pass: Sendable {
        public let inventory: Inventory
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeSignature: TimelineOrderMetadataStore.InventorySignature?
    private var activeLibraryID: String?
    private var input: Inventory?
    private var pending:
        (
            inventory: Inventory, signature: TimelineOrderMetadataStore.InventorySignature
        )?
    private var task: Task<Void, Never>?
    private var retired = false
    private let startGate: TimelineMetadataStartGate?

    public init(startGate: TimelineMetadataStartGate? = nil) {
        self.startGate = startGate
    }

    /// Repeated offers for the active inventory do not repeat its metadata requests.
    public func schedule(
        _ inventory: Inventory, operation: @escaping @Sendable (Pass) async -> Void
    ) {
        let signature = TimelineOrderMetadataStore.InventorySignature(inventory.items)
        let replacedTask = lock.withLock { () -> Task<Void, Never>? in
            guard !retired else { return nil }
            if task != nil,
                activeLibraryID == inventory.libraryID || activeLibraryID == nil || inventory.libraryID == nil
            {
                pending = activeSignature == signature ? nil : (inventory, signature)
                return nil
            }
            let replacedTask = task
            pending = nil
            generation &+= 1
            activeLibraryID = inventory.libraryID
            activeSignature = signature
            input = inventory
            let runGeneration = generation
            task = Task(priority: .background) { [self] in
                await startGate?.wait()
                while let pass = takeInput(generation: runGeneration) {
                    await operation(pass)
                    finish(pass)
                }
            }
            return replacedTask
        }
        replacedTask?.cancel()
    }

    public func isCurrent(_ pass: Pass) -> Bool {
        lock.withLock { !retired && generation == pass.generation }
    }

    /// Logout and account replacement close admission before calling this method.
    public func retire() {
        let current = lock.withLock {
            retired = true
            generation &+= 1
            input = nil
            pending = nil
            return task
        }
        current?.cancel()
    }

    /// The owner's shutdown barrier joins all admitted operations, including replaced library passes.
    public func waitForCurrentPass() async {
        let current = lock.withLock { task }
        await current?.value
    }

    private func takeInput(generation: UInt64) -> Pass? {
        lock.withLock {
            guard !retired, self.generation == generation, !Task.isCancelled, let inventory = input else {
                return nil
            }
            input = nil
            return Pass(inventory: inventory, generation: generation)
        }
    }

    private func finish(_ pass: Pass) {
        lock.withLock {
            guard generation == pass.generation else { return }
            if !retired, !Task.isCancelled, let next = pending {
                pending = nil
                input = next.inventory
                activeSignature = next.signature
                activeLibraryID = next.inventory.libraryID ?? activeLibraryID
            } else {
                pending = nil
                input = nil
                task = nil
                activeSignature = nil
                activeLibraryID = nil
            }
        }
    }
}
