import CryptoKit
import Foundation
import PhotosCore

/// The encrypted GPS snapshot kept by `PhotoLocationStore`.
///
/// A negative result is part of the snapshot. It prevents a photo without GPS from being probed on every
/// launch, while a later coordinate always removes the negative entry.
public struct PhotoLocationSnapshot: Sendable, Equatable, Codable {
    public var coordinates: [PhotoCoordinate]
    public var noLocationUIDs: Set<PhotoUID>

    public init(coordinates: [PhotoCoordinate] = [], noLocationUIDs: Set<PhotoUID> = []) {
        self.coordinates = coordinates
        self.noLocationUIDs = noLocationUIDs
    }
}

struct PhotoLocationDelta: Sendable, Equatable, Codable {
    let coordinates: [PhotoCoordinate]
    let noLocationUIDs: Set<PhotoUID>

    init(coordinates: [PhotoCoordinate] = [], noLocationUIDs: Set<PhotoUID> = []) {
        self.coordinates = coordinates
        self.noLocationUIDs = noLocationUIDs
    }
}

/// Encrypted-at-rest persistence for the whole-library GPS index.
///
/// The store keeps an encrypted base snapshot and encrypted append-only delta frames. A manifest switches
/// generations only after the new base and journal are complete, so a crash cannot expose a partial compaction.
/// Obsolete derived-store formats are discarded and rebuilt from the authoritative remote library.
///
/// GPS is sensitive PII. Coordinates, negative-cache UIDs, manifests, and journal frames remain encrypted.
/// Platform-agnostic (Foundation + CryptoKit) and shared across Apple platforms.
public final class PhotoLocationStore: @unchecked Sendable {
    /// Stable ownership for one configured account/key generation. A delayed writer must carry the lease it
    /// started with, so sign-out or account replacement rejects it before encryption and disk mutation.
    public struct SessionLease: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    /// Orders writes inside one account session. The session lease rejects another account; this lease also
    /// rejects an older same-account snapshot that finishes after a newer one.
    struct WriteLease: Equatable, Sendable {
        fileprivate let sessionGeneration: UInt64
        fileprivate let writeGeneration: UInt64
    }

    struct PersistenceMetrics: Equatable, Sendable {
        let baseRewrites: Int
        let journalAppends: Int
    }

    private struct Manifest: Codable {
        let generation: String
    }

    private static let version = 2
    private static let manifestName = "locations.v2.manifest.enc"
    private static let legacyName = "locations.v1.enc"

    private let directory: URL
    private let journalCompactionThresholdBytes: Int
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var accountUID: String?
    private var sessionGeneration: UInt64 = 0
    private var nextWriteGeneration: UInt64 = 0
    private var lastAcceptedWriteGeneration: UInt64?
    private var baseRewriteCount = 0
    private var journalAppendCount = 0
    private var validatedBaseGeneration: String?
    private var validatedJournalGeneration: String?
    #if DEBUG
        private var beforeWriteHook: (@Sendable () -> Void)?
    #endif

    public init(
        directory: URL = PhotoLocationStore.defaultDirectory,
        journalCompactionThresholdBytes: Int = 1_048_576
    ) {
        self.directory = directory
        self.journalCompactionThresholdBytes = max(1, journalCompactionThresholdBytes)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EncryptedMemories/locations", isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }
    private var legacyURL: URL { directory.appendingPathComponent(Self.legacyName) }

    /// Install the per-account key. Until configured, load and save are no-ops.
    @discardableResult
    public func configure(accountUID: String, key: SymmetricKey) -> SessionLease {
        lock.withLock {
            sessionGeneration &+= 1
            nextWriteGeneration = 0
            lastAcceptedWriteGeneration = nil
            baseRewriteCount = 0
            journalAppendCount = 0
            validatedBaseGeneration = nil
            validatedJournalGeneration = nil
            self.accountUID = accountUID
            self.key = key
            try? FileManager.default.removeItem(at: legacyURL)
            return SessionLease(generation: sessionGeneration)
        }
    }

    public func captureSessionLease() -> SessionLease? {
        lock.withLock {
            guard key != nil, accountUID != nil else { return nil }
            return SessionLease(generation: sessionGeneration)
        }
    }

    public func isCurrentSessionLease(_ lease: SessionLease) -> Bool {
        lock.withLock {
            lease.generation == sessionGeneration && key != nil && accountUID != nil
        }
    }

    func captureWriteLease(ifCurrent lease: SessionLease) -> WriteLease? {
        lock.withLock {
            guard lease.generation == sessionGeneration, key != nil, accountUID != nil else { return nil }
            nextWriteGeneration &+= 1
            return WriteLease(
                sessionGeneration: sessionGeneration,
                writeGeneration: nextWriteGeneration
            )
        }
    }

    /// Persist a full coordinate set for the current session. Only tests call this; the index saves
    /// through `save(_:with:)`.
    public func save(_ coordinates: [PhotoCoordinate]) {
        guard let lease = captureSessionLease() else { return }
        save(coordinates, ifCurrent: lease)
    }

    public func save(_ coordinates: [PhotoCoordinate], ifCurrent lease: SessionLease) {
        guard let writeLease = captureWriteLease(ifCurrent: lease) else { return }
        save(PhotoLocationSnapshot(coordinates: coordinates), with: writeLease)
    }

    @discardableResult
    func save(_ snapshot: PhotoLocationSnapshot, with writeLease: WriteLease) -> Bool {
        guard let plain = try? JSONEncoder().encode(snapshot) else { return false }
        runBeforeWriteHook()
        return lock.withLock {
            guard isCurrentWriteLocked(writeLease),
                let key,
                let accountUID
            else { return false }
            return replaceSnapshotLocked(
                plain: plain,
                key: key,
                accountUID: accountUID,
                writeLease: writeLease
            )
        }
    }

    /// Append new probe results. The caller supplies the current full snapshot for bounded compaction.
    @discardableResult
    func append(
        _ delta: PhotoLocationDelta,
        compactionSnapshot: PhotoLocationSnapshot,
        with writeLease: WriteLease
    ) -> Bool {
        guard let deltaData = try? JSONEncoder().encode(delta) else { return false }
        runBeforeWriteHook()
        return lock.withLock {
            guard isCurrentWriteLocked(writeLease),
                let key,
                let accountUID
            else { return false }

            let manifest = loadManifestLocked(key: key, accountUID: accountUID)
            let hasValidBase =
                manifest.map { manifest in
                    if validatedBaseGeneration == manifest.generation,
                        FileManager.default.fileExists(atPath: baseURL(for: manifest.generation).path)
                    {
                        return true
                    }
                    guard loadBaseLocked(manifest.generation, key: key, accountUID: accountUID) != nil else {
                        return false
                    }
                    validatedBaseGeneration = manifest.generation
                    return true
                } ?? false

            if let manifest, hasValidBase,
                let journalBytes =
                    (try? FileManager.default.attributesOfItem(
                        atPath: journalURL(for: manifest.generation).path
                    )[.size]) as? NSNumber,
                journalBytes.intValue + framedSize(deltaData) <= journalCompactionThresholdBytes
            {
                return appendFrameLocked(
                    deltaData,
                    to: journalURL(for: manifest.generation),
                    generation: manifest.generation,
                    key: key,
                    accountUID: accountUID,
                    writeLease: writeLease
                )
            }

            if manifest != nil {
                guard let plain = try? JSONEncoder().encode(compactionSnapshot) else { return false }
                return replaceSnapshotLocked(
                    plain: plain,
                    key: key,
                    accountUID: accountUID,
                    writeLease: writeLease
                )
            }

            // First append creates the current derived-store generation directly.
            let merged = applying(delta, to: PhotoLocationSnapshot())
            guard let plain = try? JSONEncoder().encode(merged) else { return false }
            return replaceSnapshotLocked(
                plain: plain,
                key: key,
                accountUID: accountUID,
                writeLease: writeLease
            )
        }
    }

    #if DEBUG
        func setBeforeWriteHook(_ hook: (@Sendable () -> Void)?) {
            lock.withLock { beforeWriteHook = hook }
        }

        func persistenceMetrics() -> PersistenceMetrics {
            lock.withLock {
                PersistenceMetrics(baseRewrites: baseRewriteCount, journalAppends: journalAppendCount)
            }
        }
    #endif

    /// Decrypt the persisted coordinates. Empty means absent, tampered, incompatible, or unconfigured.
    public func load() -> [PhotoCoordinate] {
        loadSnapshot().coordinates
    }

    /// Decrypt the persisted coordinate and negative-result snapshot.
    public func loadSnapshot() -> PhotoLocationSnapshot {
        lock.withLock {
            guard let key, let accountUID else { return PhotoLocationSnapshot() }
            return loadSnapshotLocked(key: key, accountUID: accountUID)
        }
    }

    /// Sign-out / master reset: erase the exact encrypted location files and forget the key. The next account
    /// prewarms map tiles only after it opened the Map itself.
    public func clear() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKey.libraryMapViewportSize)
        lock.withLock {
            sessionGeneration &+= 1
            nextWriteGeneration = 0
            lastAcceptedWriteGeneration = nil
            key = nil
            accountUID = nil
            baseRewriteCount = 0
            journalAppendCount = 0
            validatedBaseGeneration = nil
            validatedJournalGeneration = nil
            removePersistedFilesLocked()
        }
    }

    private func runBeforeWriteHook() {
        #if DEBUG
            let hook = lock.withLock { beforeWriteHook }
            hook?()
        #endif
    }

    private func isCurrentWriteLocked(_ lease: WriteLease) -> Bool {
        lease.sessionGeneration == sessionGeneration
            && lastAcceptedWriteGeneration.map { lease.writeGeneration > $0 } ?? true
    }

    @discardableResult
    private func replaceSnapshotLocked(
        plain: Data,
        key: SymmetricKey,
        accountUID: String,
        writeLease: WriteLease
    ) -> Bool {
        let generation = UUID().uuidString
        guard isCurrentWriteLocked(writeLease),
            let base = seal(plain, key: key, accountUID: accountUID, purpose: "base"),
            let manifestPlain = try? JSONEncoder().encode(Manifest(generation: generation)),
            let manifest = seal(manifestPlain, key: key, accountUID: accountUID, purpose: "manifest"),
            let emptyDelta = try? JSONEncoder().encode(PhotoLocationDelta()),
            let emptyFrame = seal(
                emptyDelta,
                key: key,
                accountUID: accountUID,
                purpose: "journal|gen=\(generation)"
            )
        else { return false }

        let baseURL = baseURL(for: generation)
        let journalURL = journalURL(for: generation)
        do {
            try base.write(to: baseURL, options: .atomic)
            try frameData(emptyFrame).write(to: journalURL, options: .atomic)
            try manifest.write(to: manifestURL, options: .atomic)
            lastAcceptedWriteGeneration = writeLease.writeGeneration
            baseRewriteCount += 1
            validatedBaseGeneration = generation
            validatedJournalGeneration = generation
            removeOrphanedGenerationFilesLocked(keeping: generation)
            try? FileManager.default.removeItem(at: legacyURL)
            return true
        } catch {
            // The manifest still names the previous complete generation until its atomic replacement succeeds.
            // Remove this unreferenced candidate now so repeated storage failures cannot leak disk space.
            removeGenerationFilesLocked(generation)
            return false
        }
    }

    @discardableResult
    private func appendFrameLocked(
        _ deltaData: Data,
        to journalURL: URL,
        generation: String,
        key: SymmetricKey,
        accountUID: String,
        writeLease: WriteLease
    ) -> Bool {
        guard isCurrentWriteLocked(writeLease),
            let sealed = seal(deltaData, key: key, accountUID: accountUID, purpose: "journal|gen=\(generation)")
        else { return false }
        let frame = frameData(sealed)
        let needsValidation = validatedJournalGeneration != generation
        let validLength =
            needsValidation
            ? validJournalPrefixLengthLocked(generation, key: key, accountUID: accountUID)
            : nil
        do {
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try Data().write(to: journalURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            if let validLength {
                try handle.truncate(atOffset: UInt64(validLength))
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: frame)
            try handle.synchronize()
            lastAcceptedWriteGeneration = writeLease.writeGeneration
            validatedJournalGeneration = generation
            journalAppendCount += 1
            return true
        } catch {
            validatedJournalGeneration = nil
            // A later checkpoint receives a newer write generation and can retry or compact.
            return false
        }
    }

    private func loadSnapshotLocked(key: SymmetricKey, accountUID: String) -> PhotoLocationSnapshot {
        if let manifest = loadManifestLocked(key: key, accountUID: accountUID),
            let base = loadBaseLocked(manifest.generation, key: key, accountUID: accountUID)
        {
            validatedBaseGeneration = manifest.generation
            var snapshot = base
            for delta in loadDeltasLocked(manifest.generation, key: key, accountUID: accountUID) {
                snapshot = applying(delta, to: snapshot)
            }
            return normalized(snapshot)
        }

        return PhotoLocationSnapshot()
    }

    private func loadManifestLocked(key: SymmetricKey, accountUID: String) -> Manifest? {
        guard let blob = try? Data(contentsOf: manifestURL),
            let plain = open(blob, key: key, accountUID: accountUID, purpose: "manifest")
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: plain)
    }

    private func loadBaseLocked(_ generation: String, key: SymmetricKey, accountUID: String) -> PhotoLocationSnapshot? {
        guard let blob = try? Data(contentsOf: baseURL(for: generation)),
            let plain = open(blob, key: key, accountUID: accountUID, purpose: "base"),
            let snapshot = try? JSONDecoder().decode(PhotoLocationSnapshot.self, from: plain)
        else { return nil }
        return snapshot
    }

    private func loadDeltasLocked(_ generation: String, key: SymmetricKey, accountUID: String) -> [PhotoLocationDelta] {
        readJournalLocked(generation, key: key, accountUID: accountUID).deltas
    }

    private func validJournalPrefixLengthLocked(
        _ generation: String,
        key: SymmetricKey,
        accountUID: String
    ) -> Int {
        readJournalLocked(generation, key: key, accountUID: accountUID).validLength
    }

    private func readJournalLocked(
        _ generation: String,
        key: SymmetricKey,
        accountUID: String
    ) -> (deltas: [PhotoLocationDelta], validLength: Int) {
        guard let data = try? Data(contentsOf: journalURL(for: generation)), !data.isEmpty else {
            return ([], 0)
        }
        let prefixSize = MemoryLayout<UInt64>.size
        var offset = 0
        var result: [PhotoLocationDelta] = []
        while offset + prefixSize <= data.count {
            let frameStart = offset
            let lengthData = data[frameStart..<frameStart + prefixSize]
            let length = lengthData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let payloadStart = frameStart + prefixSize
            guard length > 0,
                length <= UInt64(data.count - payloadStart),
                let end = Int(exactly: UInt64(payloadStart) + length)
            else { break }
            let frame = Data(data[payloadStart..<end])
            offset = end
            guard
                let plain = open(
                    frame,
                    key: key,
                    accountUID: accountUID,
                    purpose: "journal|gen=\(generation)"
                ), let delta = try? JSONDecoder().decode(PhotoLocationDelta.self, from: plain)
            else {
                offset = frameStart
                break
            }
            result.append(delta)
        }
        return (result, offset)
    }

    private func applying(_ delta: PhotoLocationDelta, to snapshot: PhotoLocationSnapshot) -> PhotoLocationSnapshot {
        var coordinates = snapshot.coordinates
        var indexByUID = Dictionary(uniqueKeysWithValues: coordinates.enumerated().map { ($0.element.uid, $0.offset) })
        var negatives = snapshot.noLocationUIDs
        for coordinate in delta.coordinates {
            if let index = indexByUID[coordinate.uid] {
                coordinates[index] = coordinate
            } else {
                indexByUID[coordinate.uid] = coordinates.count
                coordinates.append(coordinate)
            }
            negatives.remove(coordinate.uid)
        }
        for uid in delta.noLocationUIDs where indexByUID[uid] == nil {
            negatives.insert(uid)
        }
        return PhotoLocationSnapshot(coordinates: coordinates, noLocationUIDs: negatives)
    }

    private func normalized(_ snapshot: PhotoLocationSnapshot) -> PhotoLocationSnapshot {
        var coordinates: [PhotoCoordinate] = []
        var indexByUID: [PhotoUID: Int] = [:]
        for coordinate in snapshot.coordinates {
            if let index = indexByUID[coordinate.uid] {
                coordinates[index] = coordinate
            } else {
                indexByUID[coordinate.uid] = coordinates.count
                coordinates.append(coordinate)
            }
        }
        return PhotoLocationSnapshot(
            coordinates: coordinates,
            noLocationUIDs: snapshot.noLocationUIDs.subtracting(indexByUID.keys)
        )
    }

    private func seal(_ plain: Data, key: SymmetricKey, accountUID: String, purpose: String) -> Data? {
        try? AES.GCM.seal(
            plain,
            using: key,
            authenticating: aad(accountUID: accountUID, purpose: purpose)
        ).combined
    }

    private func open(_ blob: Data, key: SymmetricKey, accountUID: String, purpose: String) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: blob) else { return nil }
        return try? AES.GCM.open(
            box,
            using: key,
            authenticating: aad(accountUID: accountUID, purpose: purpose)
        )
    }

    private func aad(accountUID: String, purpose: String) -> Data {
        Data("encryptedmemories.locations.v\(Self.version)|acct=\(accountUID)|\(purpose)".utf8)
    }

    private func baseURL(for generation: String) -> URL {
        directory.appendingPathComponent("locations.v2.\(generation).base.enc")
    }

    private func journalURL(for generation: String) -> URL {
        directory.appendingPathComponent("locations.v2.\(generation).journal.log")
    }

    private func framedSize(_ payload: Data) -> Int {
        payload.count + 16 + 12 + MemoryLayout<UInt64>.size
    }

    private func frameData(_ sealed: Data) -> Data {
        var frame = Data()
        frame.append(contentsOf: UInt64(sealed.count).bigEndianBytes)
        frame.append(sealed)
        return frame
    }

    private func removeGenerationFilesLocked(_ generation: String) {
        try? FileManager.default.removeItem(at: baseURL(for: generation))
        try? FileManager.default.removeItem(at: journalURL(for: generation))
    }

    private func removeOrphanedGenerationFilesLocked(keeping generation: String) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return }
        let retainedNames = Set([
            baseURL(for: generation).lastPathComponent,
            journalURL(for: generation).lastPathComponent,
        ])
        for file in files
        where file.lastPathComponent.hasPrefix("locations.v2.")
            && file.lastPathComponent != Self.manifestName
            && !retainedNames.contains(file.lastPathComponent)
        {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removePersistedFilesLocked() {
        try? FileManager.default.removeItem(at: manifestURL)
        try? FileManager.default.removeItem(at: legacyURL)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return }
        for file in files where file.lastPathComponent.hasPrefix("locations.v2.") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
