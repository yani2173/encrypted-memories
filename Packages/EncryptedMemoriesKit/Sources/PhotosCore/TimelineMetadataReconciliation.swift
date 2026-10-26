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
    private let runtimeState: LibraryRuntimeState
    private let coordinator: LibraryResourceCoordinator
    /// The runtime snapshots that held a pass back, so a test can tell that the task waits.
    private var heldSnapshots = 0

    public init(
        startGate: TimelineMetadataStartGate? = nil, runtimeState: LibraryRuntimeState = .shared,
        coordinator: LibraryResourceCoordinator = .shared
    ) {
        self.startGate = startGate
        self.runtimeState = runtimeState
        self.coordinator = coordinator
    }

    var heldSnapshotCount: Int { lock.withLock { heldSnapshots } }

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
                // Only an owed pass waits: after the last pass, the task ends instead of waiting untracked.
                while hasOwedInput(generation: runGeneration), let opportunity = await waitUntilAPassMayRun() {
                    if opportunity == .backgroundPermitted {
                        await runInBackgroundWindow(generation: runGeneration, operation: operation)
                    } else {
                        guard let pass = takeInput(generation: runGeneration) else { break }
                        await operation(pass)
                        finish(pass)
                    }
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

    /// A pass waits while the app is suspended. A foreground app runs it, also when inactive; a background window of
    /// iOS runs it under the coordinator's permit. The runtime state yields its current snapshot first, so a change
    /// between the check and the subscription cannot be missed. Returns the opportunity, or nil after cancellation.
    private func waitUntilAPassMayRun() async -> LibraryExecutionOpportunity? {
        for await snapshot in runtimeState.updates() {
            if Self.passMayRun(snapshot) { return snapshot.executionOpportunity }
            lock.withLock { heldSnapshots += 1 }
        }
        return nil
    }

    private static func passMayRun(_ snapshot: LibraryRuntimeSnapshot) -> Bool {
        snapshot.executionOpportunity != .suspended
    }

    /// In a background window a pass runs only under the coordinator's single heavy permit, so a waiting backup item
    /// goes first. When the permit yields or the window ends, the pass is cancelled; the operation stops at its next
    /// page and keeps the pages it saved. The pass stays owed and runs again in the next window or in the foreground.
    private func runInBackgroundWindow(
        generation: UInt64, operation: @escaping @Sendable (Pass) async -> Void
    ) async {
        guard
            let permit = await LibraryBackgroundWindowPermit.acquire(
                LibraryBackgroundWorkTuning.orderPass, coordinator: coordinator, runtimeState: runtimeState)
        else { return }
        defer { permit.release() }
        guard let pass = takeInput(generation: generation) else { return }
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation(pass)
                return false
            }
            group.addTask { await permit.nextStop() != nil }
            // The first child that ends decides: the pass, or a stop that cancels it.
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if stopped { keepOwed(pass) } else { finish(pass) }
    }

    private func hasOwedInput(generation: UInt64) -> Bool {
        lock.withLock { !retired && self.generation == generation && !Task.isCancelled && input != nil }
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

    /// A stopped pass stays owed, unless a newer inventory already waits; that one runs instead.
    private func keepOwed(_ pass: Pass) {
        lock.withLock {
            guard generation == pass.generation, !retired, !Task.isCancelled else { return }
            if !takePendingInventory() { input = pass.inventory }
        }
    }

    /// Moves the newest pending inventory to the input. Call with the lock held.
    private func takePendingInventory() -> Bool {
        guard let next = pending else { return false }
        pending = nil
        input = next.inventory
        activeSignature = next.signature
        activeLibraryID = next.inventory.libraryID ?? activeLibraryID
        return true
    }

    private func finish(_ pass: Pass) {
        lock.withLock {
            guard generation == pass.generation else { return }
            if retired || Task.isCancelled || !takePendingInventory() {
                pending = nil
                input = nil
                task = nil
                activeSignature = nil
                activeLibraryID = nil
            }
        }
    }
}
