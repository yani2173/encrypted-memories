import Foundation

/// Cost-bounded platform-image wrapper cache with coordinated memory-pressure semantics.
///
/// Generic over the wrapped object so pressure and purge behavior is testable without UIKit or AppKit.
/// Paired entries retain their decoded source in the same NSCache entry as the wrapper. Eviction therefore
/// releases both objects together; no side dictionary can outlive the cache budget or mismatch a wrapper.
public final class WrapperImageCache<Image: AnyObject>: @unchecked Sendable {
    private final class Entry: NSObject {
        let image: Image
        let source: AnyObject?

        init(image: Image, source: AnyObject?) {
            self.image = image
            self.source = source
        }
    }

    public struct InsertionTicket: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    private let cache = NSCache<NSString, Entry>()
    /// Nominal cost budget, retained so a memory-pressure scale can be restored to full with `scale: 1.0`.
    public let nominalCostLimitBytes: Int
    private let mutationLock = NSLock()
    private var generation: UInt64 = 0

    public init(countLimit: Int, costLimitBytes: Int) {
        nominalCostLimitBytes = max(1, costLimitBytes)
        cache.countLimit = max(0, countLimit)
        cache.totalCostLimit = nominalCostLimitBytes
    }

    public func image(forKey key: NSString) -> Image? {
        mutationLock.withLock { cache.object(forKey: key)?.image }
    }

    public func set(_ image: Image, forKey key: NSString, cost: Int) {
        mutationLock.withLock {
            cache.setObject(Entry(image: image, source: nil), forKey: key, cost: max(0, cost))
        }
    }

    /// Captures the cache generation before a wrapper is built. The ticket must be supplied to `setPaired`.
    /// A destructive whole-cache invalidation rejects late builders without coupling unrelated photo keys.
    public func captureTicket() -> InsertionTicket {
        mutationLock.withLock { InsertionTicket(generation: generation) }
    }

    public func isCurrent(_ ticket: InsertionTicket) -> Bool {
        mutationLock.withLock { ticket.generation == generation }
    }

    /// Reads a wrapper only when the destructive-invalidation ticket and retained decoded source both match.
    public func pairedImage(forKey key: NSString, source: AnyObject, ticket: InsertionTicket) -> Image? {
        mutationLock.withLock {
            guard ticket.generation == generation,
                let entry = cache.object(forKey: key),
                entry.source === source
            else { return nil }
            return entry.image
        }
    }

    /// Installs a wrapper and its decoded source atomically with the ticket-generation check.
    /// The source reference is retained only by this single budgeted cache entry.
    @discardableResult
    public func setPaired(
        _ image: Image,
        forKey key: NSString,
        cost: Int,
        source: AnyObject,
        ticket: InsertionTicket
    ) -> Bool {
        mutationLock.withLock {
            guard ticket.generation == generation else { return false }
            cache.setObject(Entry(image: image, source: source), forKey: key, cost: max(0, cost))
            return true
        }
    }

    /// Resolves a paired wrapper without ever publishing a builder result after source replacement or a
    /// destructive invalidation. The caller must capture `ticket` before its first authoritative source lookup.
    public func resolvePairedImage(
        forKey key: NSString,
        cost: Int,
        source: AnyObject,
        ticket: InsertionTicket,
        sourceIsCurrent: () -> Bool,
        build: () -> Image
    ) -> Image? {
        guard isCurrent(ticket), sourceIsCurrent() else { return nil }
        if let image = pairedImage(forKey: key, source: source, ticket: ticket) {
            return isCurrent(ticket) && sourceIsCurrent() ? image : nil
        }

        let image = build()
        guard sourceIsCurrent(), setPaired(image, forKey: key, cost: cost, source: source, ticket: ticket) else {
            return nil
        }
        guard isCurrent(ticket), sourceIsCurrent() else {
            removePaired(forKey: key, source: source)
            return nil
        }
        return image
    }

    /// Removes one key without invalidating builders for unrelated photos. Source identity remains owned by
    /// the authoritative decoded cache; this cache never retains a source-only marker.
    public func invalidatePaired(forKey key: NSString) {
        mutationLock.withLock { cache.removeObject(forKey: key) }
    }

    /// Removes the entry only when it still belongs to `source`, preserving a concurrently installed replacement.
    public func removePaired(forKey key: NSString, source: AnyObject) {
        mutationLock.withLock {
            guard cache.object(forKey: key)?.source === source else { return }
            cache.removeObject(forKey: key)
        }
    }

    /// Removes one entry. Destructive whole-cache operations own builder invalidation.
    public func remove(forKey key: NSString) {
        invalidatePaired(forKey: key)
    }

    /// Clears all wrappers and invalidates every in-flight wrapper build, including account-loss cleanup.
    public func invalidateAll() {
        mutationLock.withLock {
            generation &+= 1
            cache.removeAllObjects()
        }
    }

    /// Governor-driven memory-pressure response. A purge is a destructive cache invalidation; scaling only
    /// changes the future budget and leaves currently retained entries available.
    public func applyMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        mutationLock.withLock {
            cache.totalCostLimit = max(1, Int(Double(nominalCostLimitBytes) * clamped))
            if purge {
                generation &+= 1
                cache.removeAllObjects()
            }
        }
    }

    /// Set an explicit cost limit (bytes).
    public func setCostLimit(_ bytes: Int) {
        mutationLock.withLock { cache.totalCostLimit = max(1, bytes) }
    }

    /// Purge everything except the given key - the viewer's "drop non-visible pages, keep the on-screen one"
    /// purge. `NSCache` cannot enumerate, so the kept entry is snapshotted and re-inserted after the wipe.
    public func purge(keeping key: NSString?, keptCost: Int = 0) {
        mutationLock.withLock {
            generation &+= 1
            let kept = key.flatMap { cache.object(forKey: $0) }
            cache.removeAllObjects()
            if let kept, let key {
                cache.setObject(kept, forKey: key, cost: max(0, keptCost))
            }
        }
    }

    /// The cost limit currently in force (nominal × the last pressure scale) - for tests and diagnostics.
    public var currentCostLimitBytes: Int {
        mutationLock.withLock { cache.totalCostLimit }
    }
}
