import Foundation
import PhotosCore

public enum MLIndexStoreReadError: Error, Equatable, Sendable {
    case storageUnavailable
}

/// Batched persistence boundary for ML embeddings and failure state. Keys are
/// `(PhotoUID, MLModelDescriptor)`, writes are first-write-wins, and reads are deterministic.
public protocol MLIndexStore: Sendable {
    /// Insert embeddings for a single model epoch. Idempotent per `(uid, descriptor)`;
    /// first write wins. A present embedding clears failure state for the same key in the
    /// same operation. Dimension-mismatched records are rejected (`permanentFailure`).
    @discardableResult
    func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport

    /// Bulk membership check for a model epoch. Returns the subset of `uids` already indexed.
    /// Must not load vectors or scan other epochs.
    func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) throws -> Set<PhotoUID>

    /// Reconciles one authoritative inventory. After the first session-local baseline, callers pass
    /// the last successfully reconciled inventory so stores can remove only the exact delta.
    @discardableResult
    func reconcileTrackedUIDs(
        currentAuthoritativeUIDs: [PhotoUID],
        previousAuthoritativeUIDs: [PhotoUID]?,
        descriptor: MLModelDescriptor
    ) -> Bool

    /// Visit deterministic, bounded query blocks for one model epoch.
    ///
    /// Stores must keep each block bounded independently of epoch size.
    /// A storage failure throws even if earlier blocks were delivered. Callers must discard partial results.
    func forEachVectorBlock(
        for descriptor: MLModelDescriptor,
        maximumRows: Int,
        _ body: (MLVectorBlock) throws -> Void
    ) throws

    /// Remove embeddings and failure state for multiple assets in one durable operation.
    /// Implementations must bump the vector generation at most once for the batch.
    func remove(uids: [PhotoUID], descriptor: MLModelDescriptor)

    /// Atomically drops every embedding and failure record for a model epoch. Callers may retire
    /// external model state only after this returns `true`.
    @discardableResult
    func removeAll(for descriptor: MLModelDescriptor) -> Bool

    /// Total record count for a model epoch.
    func count(for descriptor: MLModelDescriptor) -> Int

    /// Monotonic epoch generation. Callers use it to detect that an epoch's vectors changed.
    func generation(for descriptor: MLModelDescriptor) -> UInt64

    /// Persist retry/permanent failure state independently from embeddings.
    @discardableResult
    func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool
    func failureRecords(
        for descriptor: MLModelDescriptor, from uids: [PhotoUID]
    ) throws -> [PhotoUID: MLIndexFailureRecord]
}

extension MLIndexStore {
    public func coverage(for descriptor: MLModelDescriptor, allAssets: [PhotoUID]) throws -> MLIndexCoverage {
        let uniqueAssets = Array(Set(allAssets))
        let indexed = try indexedUIDs(for: descriptor, from: uniqueAssets)
        let failures = try failureRecords(for: descriptor, from: uniqueAssets)
        let permanent = failures.values.reduce(into: 0) { count, failure in
            if failure.kind == .permanent, !indexed.contains(failure.uid) { count += 1 }
        }
        return MLIndexCoverage(total: uniqueAssets.count, indexed: indexed.count, permanentlyUnindexable: permanent)
    }
}

/// Pure in-memory `MLIndexStore` for tests and ephemeral previews.
///
/// Production persistence is `SQLiteMLIndexStore`; this stays behind the same protocol so
/// Core logic tests need no filesystem. Thread-safe via `NSLock`, cheap to construct.
///
/// Not a cache: there is no size limit and no eviction. Hosts that want bounded memory
/// must layer that policy above the store.
public final class InMemoryMLIndexStore: MLIndexStore, @unchecked Sendable {
    private var recordsByDescriptor: [MLModelDescriptor: [PhotoUID: MLEmbeddingRecord]] = [:]
    private var failuresByDescriptor: [MLModelDescriptor: [PhotoUID: MLIndexFailureRecord]] = [:]
    private var generations: [MLModelDescriptor: UInt64] = [:]
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport {
        var indexed = 0
        var skipped = 0
        var rejected = 0

        lock.lock()
        defer { lock.unlock() }

        for record in records {
            guard record.isDimensionConsistent else {
                rejected += 1
                continue
            }
            // In-place mutation through the defaulted subscript: no bucket copy per record
            // (a take-mutate-put loop would CoW-copy the whole epoch on every insert).
            if recordsByDescriptor[record.descriptor, default: [:]][record.uid] != nil {
                // First-write-wins: the stored record and the "skipped" report agree.
                skipped += 1
            } else {
                recordsByDescriptor[record.descriptor, default: [:]][record.uid] = record
                generations[record.descriptor, default: 0] &+= 1
                indexed += 1
            }
            failuresByDescriptor[record.descriptor]?.removeValue(forKey: record.uid)
        }

        return MLIndexBatchReport(
            total: records.count,
            indexed: indexed,
            skippedAlreadyIndexed: skipped,
            permanentFailure: rejected
        )
    }

    public func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> Set<PhotoUID> {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = recordsByDescriptor[descriptor] else { return [] }
        return Set(uids.filter { bucket[$0] != nil })
    }

    @discardableResult
    public func reconcileTrackedUIDs(
        currentAuthoritativeUIDs: [PhotoUID],
        previousAuthoritativeUIDs: [PhotoUID]?,
        descriptor: MLModelDescriptor
    ) -> Bool {
        let current = Set(currentAuthoritativeUIDs)
        return lock.withLock {
            let candidates: Set<PhotoUID>
            if let previousAuthoritativeUIDs {
                candidates = Set(previousAuthoritativeUIDs)
            } else {
                let indexed = recordsByDescriptor[descriptor].map { Set($0.keys) } ?? []
                let failed = failuresByDescriptor[descriptor].map { Set($0.keys) } ?? []
                candidates = indexed.union(failed)
            }
            var vectorsChanged = false
            for uid in candidates where !current.contains(uid) {
                vectorsChanged =
                    recordsByDescriptor[descriptor]?.removeValue(forKey: uid) != nil
                    || vectorsChanged
                failuresByDescriptor[descriptor]?.removeValue(forKey: uid)
            }
            if vectorsChanged {
                generations[descriptor, default: 0] &+= 1
            }
            return true
        }
    }

    public func forEachVectorBlock(
        for descriptor: MLModelDescriptor,
        maximumRows: Int,
        _ body: (MLVectorBlock) throws -> Void
    ) throws {
        guard maximumRows > 0 else { return }
        let records = lock.withLock {
            // Deterministic order (dictionary order is not): sort by uid, matching the
            // persistent store's key order.
            (recordsByDescriptor[descriptor]?.values.sorted { Self.uidOrder($0.uid, $1.uid) }) ?? []
        }
        var block = MLVectorBlock(descriptor: descriptor)
        block.reserveCapacity(min(maximumRows, records.count))
        for record in records {
            if Task.isCancelled { return }
            if block.count == maximumRows {
                try body(block)
                block = MLVectorBlock(descriptor: descriptor)
                block.reserveCapacity(maximumRows)
            }
            _ = block.append(uid: record.uid, vector: record.vector)
        }
        if !block.isEmpty { try body(block) }
    }

    public func remove(uids: [PhotoUID], descriptor: MLModelDescriptor) {
        guard !uids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var vectorsChanged = false
        for uid in Set(uids) {
            vectorsChanged = recordsByDescriptor[descriptor]?.removeValue(forKey: uid) != nil || vectorsChanged
            failuresByDescriptor[descriptor]?.removeValue(forKey: uid)
        }
        if vectorsChanged {
            generations[descriptor, default: 0] &+= 1
        }
    }

    @discardableResult
    public func removeAll(for descriptor: MLModelDescriptor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = recordsByDescriptor.removeValue(forKey: descriptor) != nil
        failuresByDescriptor.removeValue(forKey: descriptor)
        if changed { generations[descriptor, default: 0] &+= 1 }
        return true
    }

    public func count(for descriptor: MLModelDescriptor) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordsByDescriptor[descriptor]?.count ?? 0
    }

    public func generation(for descriptor: MLModelDescriptor) -> UInt64 {
        lock.withLock { generations[descriptor] ?? 0 }
    }

    @discardableResult
    public func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool {
        lock.withLock {
            for record in records where recordsByDescriptor[record.descriptor]?[record.uid] == nil {
                failuresByDescriptor[record.descriptor, default: [:]][record.uid] = record
            }
            return true
        }
    }

    public func failureRecords(
        for descriptor: MLModelDescriptor,
        from uids: [PhotoUID]
    ) -> [PhotoUID: MLIndexFailureRecord] {
        lock.withLock {
            guard let bucket = failuresByDescriptor[descriptor] else { return [:] }
            return Dictionary(
                uniqueKeysWithValues: uids.compactMap { uid in
                    bucket[uid].map { (uid, $0) }
                })
        }
    }

    private static func uidOrder(_ a: PhotoUID, _ b: PhotoUID) -> Bool {
        a.volumeID != b.volumeID ? a.volumeID < b.volumeID : a.nodeID < b.nodeID
    }
}
