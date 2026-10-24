import Foundation
import Photos
import os

#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore
#endif

struct PhotoLibraryLiveChangeBuffer {
    struct Snapshot: Equatable {
        var changedIdentifiers: Set<String>
        var deletedIdentifiers: Set<String>
        var requiresFullRescan: Bool
        var generation: UInt64
    }

    private struct Batch {
        var changedIdentifiers: Set<String>
        var deletedIdentifiers: Set<String>
        var requiresFullRescan: Bool
        var generation: UInt64
    }

    private var batches: [Batch] = []
    private var generation: UInt64 = 0

    mutating func record(
        changedIdentifiers: Set<String>,
        deletedIdentifiers: Set<String>,
        requiresFullRescan: Bool
    ) {
        guard requiresFullRescan || !changedIdentifiers.isEmpty || !deletedIdentifiers.isEmpty else { return }
        generation &+= 1
        var changed = changedIdentifiers
        changed.subtract(deletedIdentifiers)
        batches.append(
            Batch(
                changedIdentifiers: changed,
                deletedIdentifiers: deletedIdentifiers,
                requiresFullRescan: requiresFullRescan,
                generation: generation
            )
        )
    }

    func snapshot() -> Snapshot {
        var changed: Set<String> = []
        var deleted: Set<String> = []
        var requiresFullRescan = false
        for batch in batches {
            changed.formUnion(batch.changedIdentifiers)
            deleted.formUnion(batch.deletedIdentifiers)
            requiresFullRescan = requiresFullRescan || batch.requiresFullRescan
        }
        changed.subtract(deleted)
        return Snapshot(
            changedIdentifiers: changed,
            deletedIdentifiers: deleted,
            requiresFullRescan: requiresFullRescan,
            generation: generation
        )
    }

    mutating func commit(through committedGeneration: UInt64) {
        batches.removeAll { $0.generation <= committedGeneration }
    }

    mutating func reset() {
        batches.removeAll(keepingCapacity: false)
    }
}

/// Incremental change tracking across launches (persistent change history) plus a live in-session
/// observer. The persistent token is PhotoKit-specific state, so it lives here in the adapter,
/// persisted as a secure-coded archive next to the account's backup stores.
public final class PhotoLibraryChangeMonitor: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private final class ObservedAssetsBox: @unchecked Sendable {
        let fetchResult: PHFetchResult<PHAsset>

        init(_ fetchResult: PHFetchResult<PHAsset>) {
            self.fetchResult = fetchResult
        }
    }

    public struct ChangeSet: Sendable {
        /// Assets to (re)scan - inserted or updated.
        public var changedIdentifiers: [String]
        /// Assets deleted locally (backup never mirrors deletions; rows become source-missing
        /// lazily when work touches them).
        public var deletedIdentifiers: [String]
        /// The stored token no longer resolves (expired history / first run) - callers fall back
        /// to a full cheap rescan, which preflight keeps mostly read-only.
        public var requiresFullRescan: Bool

        public init(changedIdentifiers: [String], deletedIdentifiers: [String], requiresFullRescan: Bool) {
            self.changedIdentifiers = changedIdentifiers
            self.deletedIdentifiers = deletedIdentifiers
            self.requiresFullRescan = requiresFullRescan
        }
    }

    public struct PreparedChangeSet: @unchecked Sendable {
        public let changes: ChangeSet
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            fileprivate let commitToken: PHPersistentChangeToken?
        #else
            fileprivate let commitToken: PHPersistentChangeToken
        #endif
        fileprivate let liveGeneration: UInt64
    }

    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "Backup")
    private let tokenURL: URL
    struct LiveChange: @unchecked Sendable {
        let assets: PHFetchResult<PHAsset>
        let changed: Set<String>
        let deleted: Set<String>
        let requiresFullRescan: Bool
    }

    struct Operations: Sendable {
        var fetch: @Sendable () -> PHFetchResult<PHAsset> = {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            return PHAsset.fetchAssets(with: options)
        }
        var register: @Sendable (any PHPhotoLibraryChangeObserver) -> Void = { PHPhotoLibrary.shared().register($0) }
        var unregister: @Sendable (any PHPhotoLibraryChangeObserver) -> Void = {
            PHPhotoLibrary.shared().unregisterChangeObserver($0)
        }
        var details: @Sendable (PHChange, PHFetchResult<PHAsset>) -> LiveChange? = { change, assets in
            guard let details = change.changeDetails(for: assets) else { return nil }
            return LiveChange(
                assets: details.fetchResultAfterChanges,
                changed: details.hasIncrementalChanges
                    ? Set((details.insertedObjects + details.changedObjects).map(\.localIdentifier)) : [],
                deleted: details.hasIncrementalChanges ? Set(details.removedObjects.map(\.localIdentifier)) : [],
                requiresFullRescan: !details.hasIncrementalChanges)
        }
    }

    private let operations: Operations
    private let lock = NSLock()
    private final class Callback: Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    /// Cancelling a subscription leaves every other consumer observing. Retain it for the consumer's lifetime.
    public final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellation: (@Sendable () -> Void)?

        fileprivate init(_ cancellation: @escaping @Sendable () -> Void) { self.cancellation = cancellation }

        public func cancel() {
            let action = lock.withLock {
                let action = cancellation
                cancellation = nil
                return action
            }
            action?()
        }

        deinit { cancel() }
    }

    private final class Registration: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        weak var monitor: PhotoLibraryChangeMonitor?
        let generation: UInt64

        init(monitor: PhotoLibraryChangeMonitor, generation: UInt64) {
            self.monitor = monitor
            self.generation = generation
        }

        func photoLibraryDidChange(_ changeInstance: PHChange) {
            monitor?.receive(changeInstance, generation: generation)
        }
    }

    private let legacyID = UUID()
    private var callbacks: [UUID: Callback] = [:]
    private var registration: Registration?
    private var observedAssets: PHFetchResult<PHAsset>?
    private var liveChanges = PhotoLibraryLiveChangeBuffer()
    private var isObserving = false
    private var isStarting = false
    private var observationGeneration: UInt64 = 0

    public convenience init(tokenURL: URL) {
        self.init(tokenURL: tokenURL, operations: Operations())
    }

    convenience init(
        tokenURL: URL,
        fetchObservedAssets: @escaping @Sendable () -> PHFetchResult<PHAsset>
    ) {
        var operations = Operations()
        operations.fetch = fetchObservedAssets
        self.init(tokenURL: tokenURL, operations: operations)
    }

    init(tokenURL: URL, operations: Operations) {
        self.tokenURL = tokenURL
        self.operations = operations
        super.init()
    }

    deinit {
        if let registration { operations.unregister(registration) }
    }

    /// Starts or replaces the legacy subscription. Its stop never cancels another consumer.
    public func startObserving(_ handler: @Sendable @escaping () -> Void) {
        addSubscriber(id: legacyID, handler: handler)
    }

    public func stopObserving() { removeSubscriber(id: legacyID) }

    public func subscribe(_ handler: @Sendable @escaping () -> Void) -> Subscription {
        let id = UUID()
        addSubscriber(id: id, handler: handler)
        return Subscription { [weak self] in self?.removeSubscriber(id: id) }
    }

    private func addSubscriber(id: UUID, handler: @Sendable @escaping () -> Void) {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested { return }
        #endif
        let (generation, replaced): (UInt64?, Callback?) = lock.withLock {
            let replaced = callbacks.updateValue(Callback(handler), forKey: id)
            guard !isObserving, !isStarting else { return (nil, replaced) }
            isStarting = true
            observationGeneration &+= 1
            return (observationGeneration, replaced)
        }
        // Releasing a client closure can destroy another subscription and re-enter cancellation.
        withExtendedLifetime(replaced) {}
        guard let generation else { return }

        let fetchObservedAssets = operations.fetch
        Task.detached(priority: .utility) { [weak self] in
            let assets = ObservedAssetsBox(fetchObservedAssets())
            guard !Task.isCancelled else { return }
            self?.finishStarting(with: assets, generation: generation)
        }
    }

    private func removeSubscriber(id: UUID) {
        let (removed, retired): (Callback?, Registration?) = lock.withLock {
            let removed = callbacks.removeValue(forKey: id)
            guard callbacks.isEmpty else { return (removed, nil) }
            observationGeneration &+= 1
            isStarting = false
            isObserving = false
            observedAssets = nil
            liveChanges.reset()
            let retired = registration
            registration = nil
            return (removed, retired)
        }
        if let retired { operations.unregister(retired) }
        withExtendedLifetime(removed) {}
    }

    private func finishStarting(with assets: ObservedAssetsBox, generation: UInt64) {
        let admitted: Registration? = lock.withLock {
            guard isStarting, generation == observationGeneration, !callbacks.isEmpty else { return nil }
            observedAssets = assets.fetchResult
            isStarting = false
            isObserving = true
            let admitted = Registration(monitor: self, generation: generation)
            registration = admitted
            return admitted
        }
        guard let admitted else { return }

        // Registration may re-enter a consumer. A distinct observer per generation keeps late cleanup
        // from unregistering a replacement that started while the external call was suspended.
        operations.register(admitted)
        let registrationIsCurrent = lock.withLock {
            isObserving && generation == observationGeneration && registration === admitted
        }
        if !registrationIsCurrent { operations.unregister(admitted) }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        receive(changeInstance, generation: lock.withLock { observationGeneration })
    }

    private func receive(_ changeInstance: PHChange, generation: UInt64) {
        let handlers: [(UUID, Callback)] = lock.withLock {
            guard isObserving, generation == observationGeneration,
                let observedAssets,
                let details = operations.details(changeInstance, observedAssets)
            else { return [] }
            self.observedAssets = details.assets
            liveChanges.record(
                changedIdentifiers: details.changed,
                deletedIdentifiers: details.deleted,
                requiresFullRescan: details.requiresFullRescan)
            return Array(callbacks)
        }
        for (id, callback) in handlers {
            let isCurrent = lock.withLock {
                generation == observationGeneration && callbacks[id] === callback
            }
            // A callback admitted before cancellation can finish; consumers retain their lifecycle fences.
            if isCurrent { callback.handler() }
        }
    }

    /// Changes since the stored token. This deliberately does not advance the stored token. Callers
    /// must commit the returned value only after their durable scan/enqueue work succeeds.
    public func prepareChanges() -> PreparedChangeSet {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                return PreparedChangeSet(
                    changes: ChangeSet(
                        changedIdentifiers: [], deletedIdentifiers: [],
                        requiresFullRescan: !FileManager.default.fileExists(atPath: tokenURL.path)),
                    commitToken: nil, liveGeneration: 0)
            }
        #endif
        let library = PHPhotoLibrary.shared()
        let live = lock.withLock { liveChanges.snapshot() }
        let currentToken = library.currentChangeToken

        guard let previous = loadToken() else {
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(live.changedIdentifiers),
                    deletedIdentifiers: Array(live.deletedIdentifiers),
                    requiresFullRescan: true
                ),
                commitToken: currentToken,
                liveGeneration: live.generation
            )
        }
        do {
            var changed = live.changedIdentifiers
            var deleted = live.deletedIdentifiers
            for change in try library.fetchPersistentChanges(since: previous) {
                do {
                    let details = try change.changeDetails(for: .asset)
                    changed.formUnion(details.insertedLocalIdentifiers)
                    changed.formUnion(details.updatedLocalIdentifiers)
                    deleted.formUnion(details.deletedLocalIdentifiers)
                } catch {
                    // Advancing past one unreadable history entry could permanently miss an asset.
                    // Fall back to the stable full scan and commit the token only after that succeeds.
                    return PreparedChangeSet(
                        changes: ChangeSet(
                            changedIdentifiers: Array(changed),
                            deletedIdentifiers: Array(deleted),
                            requiresFullRescan: true
                        ),
                        commitToken: currentToken,
                        liveGeneration: live.generation
                    )
                }
            }
            changed.subtract(deleted)
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(changed),
                    deletedIdentifiers: Array(deleted),
                    requiresFullRescan: live.requiresFullRescan
                ),
                commitToken: currentToken,
                liveGeneration: live.generation
            )
        } catch {
            // Token expired or history unavailable - full cheap rescan is the documented fallback.
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(live.changedIdentifiers),
                    deletedIdentifiers: Array(live.deletedIdentifiers),
                    requiresFullRescan: true
                ),
                commitToken: currentToken,
                liveGeneration: live.generation
            )
        }
    }

    /// Advances the persistent token after the caller has durably handled the prepared changes. When the token cannot
    /// be written, the stored token and the live changes stay, so the next pass reports the changes again.
    @discardableResult
    public func commit(_ prepared: PreparedChangeSet) -> Bool {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                do { try Data("synthetic-token".utf8).write(to: tokenURL, options: .atomic) } catch {
                    fatalError("The synthetic PhotoKit token was not saved")
                }
                return true
            }
            guard let token = prepared.commitToken else { fatalError("Missing PhotoKit token") }
        #else
            let token = prepared.commitToken
        #endif
        guard store(token: token) else { return false }
        lock.withLock {
            liveChanges.commit(through: prepared.liveGeneration)
        }
        return true
    }

    private func loadToken() -> PHPersistentChangeToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func store(token: PHPersistentChangeToken) -> Bool {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try data.write(to: tokenURL, options: .atomic)
            return true
        } catch {
            let error = error as NSError
            Self.logger.error(
                "Photo library change token could not be saved: \(error.domain, privacy: .public) \(error.code)")
            return false
        }
    }
}
