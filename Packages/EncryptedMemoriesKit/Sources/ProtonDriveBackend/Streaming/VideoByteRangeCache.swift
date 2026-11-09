import CryptoKit
import Foundation
import MediaByteCache
import PhotosCore

/// On-disk cache of a video's *encrypted* blocks, keyed by `uid` + block index, so reopening a video
/// (or seeking back over already-watched regions) reuses bytes instead of re-downloading. We persist
/// the encrypted block - not the decrypted plaintext - so no clear video content lands on disk; the
/// decrypt happens in memory on read (mirroring Proton Drive Web, which keeps decrypted bytes only in
/// the page's memory and never persists them). A size budget with LRU eviction keeps disk bounded.
///
/// Thread-safe (NSLock); the resource loader hits this from its serving queue + detached tasks.
public final class VideoByteRangeCache: @unchecked Sendable {
    public static let shared = VideoByteRangeCache()

    private let root: URL
    private let lock = NSLock()
    /// Filesystem work runs on one dedicated queue so range-serving tasks never block the cooperative executor.
    private let ioQueue = DispatchQueue(label: "me.proton.photos.video-byte-range-cache", qos: .utility)
    let budgetBytes: Int
    private let fm = FileManager.default
    /// Shared fence used by detached range fetches that can return after `clearAll()`.
    private let writerGeneration = CacheWriterGeneration()
    private let runtimeState: LibraryRuntimeState
    private var storageTask: Task<Void, Never>?
    private var sizeOnDisk: Int?

    struct Lookup: Sendable {
        let encrypted: Data?
        let ticket: CacheWriterGeneration.Token
    }

    init(
        budgetBytes: Int? = nil,
        rootDirectory: URL? = nil,
        runtimeState: LibraryRuntimeState = .shared,
        policyBudget: @Sendable (DiskCacheBudgetPolicy) -> Int = { policy in
            VideoByteRangeCache.byteLimit(for: policy.videoBudget)
        }
    ) {
        self.budgetBytes = budgetBytes ?? policyBudget(DiskCacheBudgetPolicy(platform: .mobile))
        self.runtimeState = runtimeState
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root =
            rootDirectory
            ?? caches.appendingPathComponent("EncryptedMemories/video-blocks", isDirectory: true)
        // Reads do not require the directory. The first store or clear creates it on the I/O queue.
        storageTask = Task { [weak self, runtimeState] in
            var wasCritical = false
            for await snapshot in runtimeState.updates() {
                let critical = snapshot.storagePressure == .critical
                if critical, !wasCritical { await self?.clearForStoragePressureAsync() }
                wasCritical = critical
            }
        }
    }

    static func byteLimit(for budget: DiskCacheBudgetPolicy.Budget) -> Int {
        switch budget {
        case .bytes(let bytes): Int(clamping: bytes)
        case .unlimited: Int.max
        }
    }

    deinit { storageTask?.cancel() }

    /// Stable, filesystem-safe directory name for a uid (SHA-256 hex of the volume~node pair).
    private func dir(for uid: PhotoUID) -> URL {
        let digest = SHA256.hash(data: Data("\(uid.volumeID)~\(uid.nodeID)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hex, isDirectory: true)
    }

    private func file(for uid: PhotoUID, block: Int) -> URL {
        dir(for: uid).appendingPathComponent("\(block).blk")
    }

    /// Captures one ticket before checking disk. The caller passes the same ticket to `store`, so concurrent
    /// misses for one block cannot consume another request's generation.
    func lookup(uid: PhotoUID, block: Int) -> Lookup {
        let url = file(for: uid, block: block)
        let ticket = writerGeneration.capture()
        let encrypted: Data? = lock.withLock {
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.deletingLastPathComponent().path)
            return data
        }
        return Lookup(encrypted: encrypted, ticket: ticket)
    }

    /// Async cache lookup for range-serving paths. The synchronous method remains for diagnostics and tests.
    func lookupAsync(uid: PhotoUID, block: Int) async -> Lookup {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.lookup(uid: uid, block: block))
            }
        }
    }

    /// Captures the generation owned by one long-lived prefetch or resource-loader lifetime. Every later
    /// block store must carry this owner token in addition to its per-miss lookup ticket.
    func captureOwnerGeneration() -> CacheWriterGeneration.Token {
        writerGeneration.capture()
    }

    /// Persists a block's encrypted bytes for the exact lookup ticket, then enforces the budget. A missing,
    /// failed, or cancelled request carries no cache-side reservation and therefore cannot leak state.
    @discardableResult
    func store(
        uid: PhotoUID,
        block: Int,
        encrypted: Data,
        ticket: CacheWriterGeneration.Token,
        ownerGeneration: CacheWriterGeneration.Token,
        publicationOwner: VideoCacheWriteOwner? = nil
    ) -> Bool {
        // A fresh post-clear lookup must not let an old owner write. Equality also rejects a stale miss
        // ticket when a caller mixes requests from different generations.
        guard ticket == ownerGeneration else { return false }
        guard runtimeState.snapshot().storagePressure.permitsDiskWrite(for: .video) else { return false }
        let d = dir(for: uid)
        // Keep the generation fence across the complete write and budget pass. This establishes the one
        // lock order used by this cache: generation first, then cache. clearAll uses the same order.
        return writerGeneration.performIfCurrent(ownerGeneration) {
            lock.withLock { () -> Bool in
                guard runtimeState.snapshot().storagePressure.permitsDiskWrite(for: .video) else {
                    return false
                }
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                let url = d.appendingPathComponent("\(block).blk")
                let previousTotal = sizeOnDiskLocked()
                let oldSize = fileSize(url)
                let publish = { () -> Bool in
                    do {
                        try encrypted.write(to: url, options: .atomic)
                    } catch {
                        return false
                    }
                    self.sizeOnDisk = max(0, previousTotal - oldSize + encrypted.count)
                    return true
                }
                // The owner fence covers publication, not the later budget scan. Close waits at most
                // for this block's write, and queued writes recheck ownership on the I/O queue.
                let published = publicationOwner.map { $0.performIfOpen(publish) ?? false } ?? publish()
                guard published else { return false }
                enforceBudgetLocked(keep: d.lastPathComponent, ticket: ticket)
                return true
            }
        } ?? false
    }

    /// Async cache store for range-serving paths. Budget accounting and eviction stay serialized with writes.
    @discardableResult
    func storeAsync(
        uid: PhotoUID,
        block: Int,
        encrypted: Data,
        ticket: CacheWriterGeneration.Token,
        ownerGeneration: CacheWriterGeneration.Token,
        publicationOwner: VideoCacheWriteOwner? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(
                    returning: self.store(
                        uid: uid,
                        block: block,
                        encrypted: encrypted,
                        ticket: ticket,
                        ownerGeneration: ownerGeneration,
                        publicationOwner: publicationOwner
                    ))
            }
        }
    }

    /// Clears the whole video block cache (wired to the existing "delete cache" Settings action).
    public func clearAll() {
        // Advance before deleting. Tickets are per lookup, so late old requests cannot consume a new miss.
        writerGeneration.invalidateAndPerform {
            lock.withLock {
                try? fm.removeItem(at: root)
                try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                sizeOnDisk = 0
            }
        }
        PhotoDiagnostics.shared.emit("VideoCache", ["action": "clearAll", "sizeOnDisk": "0"])
    }

    /// Async reset for UI-facing cache controls. It joins the dedicated I/O queue before returning.
    public func clearAllAsync() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                self.clearAll()
                continuation.resume()
            }
        }
    }

    private func clearForStoragePressureAsync() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                // Keep the owner generation so an open player can cache new blocks after recovery.
                let generation = self.writerGeneration.capture()
                _ = self.writerGeneration.performIfCurrent(generation) {
                    self.lock.withLock {
                        guard self.runtimeState.snapshot().storagePressure == .critical else { return }
                        try? self.fm.removeItem(at: self.root)
                        try? self.fm.createDirectory(at: self.root, withIntermediateDirectories: true)
                        self.sizeOnDisk = nil
                    }
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Budget

    /// Evicts least-recently-used uid directories until under budget. Coarse-grained (per video, by
    /// the directory's newest mtime) - cheap and good enough; a single video's blocks live or die
    /// together, which keeps a partially-played file fully reusable.
    private func enforceBudgetLocked(keep: String, ticket: CacheWriterGeneration.Token) {
        var total = sizeOnDiskLocked()
        guard total > budgetBytes else { return }
        let dirs =
            (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        let sorted =
            dirs
            .filter { $0.lastPathComponent != keep }  // never evict the video being played
            .sorted { mtime($0) < mtime($1) }  // oldest first
        for d in sorted where total > budgetBytes {
            let size = directorySize(d)
            try? fm.removeItem(at: d)
            total = max(0, total - size)
            sizeOnDisk = total
            PhotoDiagnostics.shared.emit(
                "VideoCache",
                [
                    "action": "evict", "dir": d.lastPathComponent, "freed": "\(size)", "sizeOnDisk": "\(total)",
                ])
        }
    }

    private func sizeOnDiskLocked() -> Int {
        if let sizeOnDisk { return sizeOnDisk }
        let measured = directorySize(root)
        sizeOnDisk = measured
        return measured
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func directorySize(_ url: URL) -> Int {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
